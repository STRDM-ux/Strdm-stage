import Foundation
import Network
import SwiftUI
import UIKit

/// Talks to STRDM Stage on the Mac: finds it with Bonjour, polls the show 4×/second and sends actions.
@MainActor
final class LiveClient: ObservableObject {
    struct FoundMac: Identifiable, Hashable { let id: String; let name: String; let endpoint: NWEndpoint }

    @Published var state: LiveState?
    @Published var crowd: CrowdState?
    @Published var connected = false
    @Published var needsPIN = false
    @Published var lastError: String?
    @Published var found: [FoundMac] = []
    @Published var baseURL: URL? { didSet { UserDefaults.standard.set(baseURL?.absoluteString, forKey: "liveBase") } }
    @Published var pin: String { didSet { UserDefaults.standard.set(pin, forKey: "livePIN") } }
    @Published var pollCrowd = false

    private var pollTask: Task<Void, Never>?
    private var browser: NWBrowser?
    private var failures = 0

    init() {
        pin = UserDefaults.standard.string(forKey: "livePIN") ?? ""
        baseURL = UserDefaults.standard.string(forKey: "liveBase").flatMap(URL.init(string:))
        startBrowsing()
        startPolling()
    }

    var isSetUp: Bool { baseURL != nil && !pin.isEmpty }

    // MARK: Pairing

    /// Accepts the Mac's pairing link (QR) — http://IP:8686/?t=PIN — or just an address.
    func pair(with text: String) -> Bool {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.lowercased().hasPrefix("http") { s = "http://" + s }
        guard var comps = URLComponents(string: s), comps.host != nil else { return false }
        if let t = comps.queryItems?.first(where: { $0.name == "t" })?.value { pin = t }
        if comps.port == nil { comps.port = 8686 }
        comps.path = ""; comps.query = nil
        baseURL = comps.url
        needsPIN = pin.isEmpty
        return true
    }

    func connect(to mac: FoundMac) {
        // Resolve the Bonjour service to an IP address (plain IPs are allowed over HTTP).
        let conn = NWConnection(to: mac.endpoint, using: .tcp)
        conn.stateUpdateHandler = { [weak self] st in
            guard case .ready = st, let path = conn.currentPath, case let .hostPort(host, port)? = path.remoteEndpoint else { return }
            var h = "\(host)"
            if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
            if h.contains(":") { h = "[\(h)]" }
            let url = URL(string: "http://\(h):\(port.rawValue)")
            conn.cancel()
            Task { @MainActor in self?.baseURL = url; self?.needsPIN = self?.pin.isEmpty ?? true }
        }
        conn.start(queue: .global())
    }

    func forget() { baseURL = nil; pin = ""; state = nil; connected = false }

    private func startBrowsing() {
        let b = NWBrowser(for: .bonjour(type: "_strdmlive._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let macs = results.compactMap { r -> FoundMac? in
                guard case let .service(name, _, _, _) = r.endpoint else { return nil }
                return FoundMac(id: name, name: name, endpoint: r.endpoint)
            }
            Task { @MainActor in self?.found = macs.sorted { $0.name < $1.name } }
        }
        b.start(queue: .main)
        browser = b
    }

    // MARK: Polling

    private func startPolling() {
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                if self.isSetUp && !self.needsPIN {
                    await self.refresh()
                    if self.pollCrowd && tick % 2 == 0 { await self.refreshCrowd() }
                }
                tick += 1
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func request(_ path: String, method: String = "GET", json: [String: Any]? = nil, body: Data? = nil,
                         query: [URLQueryItem] = []) -> URLRequest? {
        guard let base = baseURL, var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else { return nil }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { return nil }
        var r = URLRequest(url: url, timeoutInterval: body == nil ? 3 : 300)
        r.httpMethod = method
        r.cachePolicy = .reloadIgnoringLocalCacheData
        r.setValue(pin, forHTTPHeaderField: "X-Remote-Token")
        if let json { r.httpBody = try? JSONSerialization.data(withJSONObject: json); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let body { r.httpBody = body; r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type") }
        return r
    }

    private func load<T: Decodable>(_ r: URLRequest, type: T.Type) async -> T? {
        do {
            let (data, resp) = try await URLSession.shared.data(for: r)
            if let http = resp as? HTTPURLResponse, http.statusCode == 401 { needsPIN = true; connected = false; return nil }
            failures = 0
            connected = true
            lastError = nil
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            failures += 1
            if failures > 3 { connected = false; lastError = "Can't reach the Mac — same Wi-Fi? STRDM Stage open?" }
            return nil
        }
    }

    func refresh() async {
        guard let r = request("api/state") else { return }
        if let s = await load(r, type: LiveState.self), s != state { state = s }
    }

    func refreshCrowd() async {
        guard let r = request("api/crowd") else { return }
        if let c = await load(r, type: CrowdState.self), c != crowd { crowd = c }
    }

    // MARK: Actions

    func act(_ action: String, _ extra: [String: Any] = [:]) {
        var body = extra
        body["action"] = action
        guard let r = request("api/action", method: "POST", json: body) else { return }
        Task { if let s = await load(r, type: LiveState.self) { state = s } }
    }

    func go() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        act("go")
    }

    func crowdSet(_ fields: [String: Any]) {
        guard let r = request("api/crowd", method: "POST", json: fields) else { return }
        Task { if let c = await load(r, type: CrowdState.self) { crowd = c } }
    }

    func uploadCrowdMedia(_ data: Data, name: String) async -> Bool {
        guard let r = request("api/crowd/upload", method: "POST", body: data, query: [URLQueryItem(name: "name", value: name)]) else { return false }
        if let c = await load(r, type: CrowdState.self) { crowd = c; return true }
        return false
    }

    func mediaURL(_ path: String) -> URL? { baseURL.flatMap { URL(string: path, relativeTo: $0) } }
}

struct CrowdState: Decodable, Equatable {
    struct Media: Decodable, Equatable, Identifiable { let id: String; let name: String; let kind: String; let url: String }
    struct Mode: Decodable, Equatable, Identifiable { let id: String; let name: String }
    let mode: String
    let colors: [String]
    let speed: Double
    let bright: Double
    let text: String
    let current: String
    let phones: Int
    let media: [Media]
    let modes: [Mode]
    let joinURL: String
}
