import Foundation
import Network
import AppKit
import CoreImage
import Darwin
import SystemConfiguration

/// Serves the iPhone remote (a home-screen web app) and its JSON API on the local network.
///
///   GET  /                 remote app (HTML)
///   GET  /manifest.json    web-app manifest
///   GET  /icon.png         home-screen icon
///   GET  /api/state        show state            (needs PIN)
///   POST /api/action       {"action": "...", …}  (needs PIN)
@MainActor
final class RemoteServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var error: String? = nil
    @Published private(set) var addresses: [String] = []
    @Published private(set) var connectedDevices: [String] = []
    @Published private(set) var pin: String
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            enabled ? start() : stop()
        }
    }
    let port: UInt16 = 8686

    private let store: ShowStore
    private let engine: ShowEngine
    private let lighting: LightingEngine
    private let audio: AudioEngine
    /// Set by the app after creation (STRDM Live pages for screens, visuals and the AI crew).
    weak var screens: ScreenManager?
    weak var visuals: VisualEngine?
    weak var crew: CrewAgent?
    weak var crowd: CrowdController?
    weak var live: LiveMode?
    /// Audience phones are served straight from this cache, off the main thread.
    nonisolated let crowdCache = CrowdCache()
    private var listener: NWListener?
    private var lastSeen: [String: Date] = [:]
    private var lastGo = Date.distantPast
    private var housekeeping: Timer?
    private lazy var iconPNG: Data = Bundle.main.url(forResource: "touch-icon", withExtension: "png").flatMap { try? Data(contentsOf: $0) } ?? Self.makeIcon()
    private lazy var brandPNG: Data? = Bundle.main.url(forResource: "BrandMark", withExtension: "png").flatMap { try? Data(contentsOf: $0) }

    private static let enabledKey = "STRDMStage.remote.enabled"
    private static let pinKey = "STRDMStage.remote.pin"

    init(store: ShowStore, engine: ShowEngine, lighting: LightingEngine, audio: AudioEngine) {
        self.store = store
        self.engine = engine
        self.lighting = lighting
        self.audio = audio
        let savedPIN = UserDefaults.standard.string(forKey: Self.pinKey)
        let initialPIN = (savedPIN?.count == 4 ? savedPIN : nil) ?? Self.randomPIN()
        UserDefaults.standard.set(initialPIN, forKey: Self.pinKey)
        pin = initialPIN
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        if enabled { start() }
        housekeeping = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPresence() }
        }
    }

    // MARK: Lifecycle

    func start() {
        stop()
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            // Bonjour: the native STRDM Live iPhone/iPad app finds this Mac automatically.
            l.service = NWListener.Service(name: Host.current().localizedName ?? "STRDM Stage", type: "_strdmlive._tcp")
            l.newConnectionHandler = { @Sendable [weak self] connection in
                connection.start(queue: .global(qos: .userInteractive))
                RemoteServer.readRequest(connection, buffer: Data()) { raw in
                    guard let raw, let request = HTTPRequest(raw: raw, connection: connection) else {
                        connection.cancel()
                        return
                    }
                    if request.path.hasPrefix("/crowd"), let self, let reply = self.crowdCache.respond(request) {
                        connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
                        return
                    }
                    Task { @MainActor in
                        let response = self?.handle(request) ?? HTTPResponse.text(503, "Unavailable").data
                        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                    }
                }
            }
            l.stateUpdateHandler = { @Sendable [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.error = nil
                    case .failed(let e):
                        self?.isRunning = false
                        self?.error = "Remote server stopped: \(e.localizedDescription)"
                    case .cancelled:
                        self?.isRunning = false
                    default: break
                    }
                }
            }
            l.start(queue: .global(qos: .userInitiated))
            listener = l
            addresses = Self.lanURLs(port: port)
        } catch {
            self.error = "Couldn't start the remote server on port \(port): \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    func newPIN() {
        pin = Self.randomPIN()
        UserDefaults.standard.set(pin, forKey: Self.pinKey)
    }

    func refreshAddresses() { addresses = Self.lanURLs(port: port) }

    var pairingURL: String? {
        addresses.first.map { "\($0)/?t=\(pin)" }
    }

    private func refreshPresence() {
        let cutoff = Date().addingTimeInterval(-6)
        lastSeen = lastSeen.filter { $0.value > cutoff }
        let devices = lastSeen.keys.sorted()
        if devices != connectedDevices { connectedDevices = devices }
    }

    // MARK: Routing

    private func handle(_ r: HTTPRequest) -> Data {
        switch (r.method, r.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return HTTPResponse(status: 200, contentType: "text/html; charset=utf-8", body: Data(RemoteWebApp.html.utf8)).data
        case ("GET", "/manifest.json"):
            return HTTPResponse(status: 200, contentType: "application/manifest+json", body: Data(RemoteWebApp.manifest.utf8)).data
        case ("GET", "/icon.png"), ("GET", "/apple-touch-icon.png"):
            return HTTPResponse(status: 200, contentType: "image/png", body: iconPNG, cache: true).data
        case ("GET", "/brand.png"):
            return HTTPResponse(status: 200, contentType: "image/png", body: brandPNG ?? iconPNG, cache: true).data
        case ("GET", "/api/state"):
            guard authorized(r) else { return HTTPResponse.text(401, "PIN required").data }
            return HTTPResponse.json(stateJSON())
        case ("GET", "/api/crowd"):
            guard authorized(r) else { return HTTPResponse.text(401, "PIN required").data }
            return HTTPResponse.json(crowdJSON())
        case ("POST", "/api/crowd"):
            guard authorized(r) else { return HTTPResponse.text(401, "PIN required").data }
            if let obj = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any] { crowd?.perform(obj) }
            return HTTPResponse.json(crowdJSON())
        case ("POST", "/api/crowd/upload"):
            guard authorized(r) else { return HTTPResponse.text(401, "PIN required").data }
            guard !r.body.isEmpty, let crowd else { return HTTPResponse.text(400, "Empty upload").data }
            if let m = crowd.addMedia(data: r.body, name: r.query["name"] ?? "upload.jpg"), r.query["show"] != "0" { crowd.show(m) }
            return HTTPResponse.json(crowdJSON())
        case ("POST", "/api/action"):
            guard authorized(r) else { return HTTPResponse.text(401, "PIN required").data }
            perform(r.body)
            return HTTPResponse.json(stateJSON())
        default:
            return HTTPResponse.text(404, "Not found").data
        }
    }

    private func authorized(_ r: HTTPRequest) -> Bool {
        let token = r.headers["x-remote-token"] ?? r.query["t"]
        guard token == pin else { return false }
        lastSeen[r.clientIP] = Date()
        if !connectedDevices.contains(r.clientIP) { refreshPresence() }
        return true
    }

    // MARK: Actions

    private func perform(_ body: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let action = obj["action"] as? String else { return }
        let id = (obj["id"] as? String).flatMap(UUID.init(uuidString:))
        switch action {
        case "go":
            // Debounce double-taps so one press can never fire two cues.
            guard Date().timeIntervalSince(lastGo) > 0.35 else { return }
            lastGo = Date()
            engine.go()
            engine.note("GO from iPhone remote")
        case "stop": engine.stopAll()
        case "panic": engine.panic()
        case "sfxStop": lighting.sfx?.emergencyStop(reason: "E-STOP from phone")
        case "next": engine.moveStandby(by: 1)
        case "prev": engine.moveStandby(by: -1)
        case "standby": if let id { engine.setStandby(cueID: id) }
        case "fire": if let id { engine.fireOnly(cueID: id) }
        case "blackout": lighting.blackout = (obj["on"] as? Bool) ?? !lighting.blackout
        case "gm":
            if let v = obj["value"] as? Double { lighting.grandMaster = max(0, min(1, v)) }
        case "scene":
            if let id { lighting.goToScene(id, fade: (obj["fade"] as? Double) ?? 2) }
        case "follow":
            lighting.followTargetID = id
        case "vocalBypass":
            audio.setVocalBypass((obj["on"] as? Bool) ?? !store.show.vocalRack.bypassAll)
        case "vocalPreset":
            if let id { audio.applyVocalPreset(id) }
        // Sound
        case "eqBand":
            if let b = obj["band"] as? Int, let g = obj["gain"] as? Double, (0..<10).contains(b) {
                audio.setEQ { $0.gains[b] = max(-12, min(12, g)); $0.preset = "Custom" }
            }
        case "eqPreset": if let n = obj["name"] as? String { audio.setEQPreset(n) }
        case "eqEnabled": audio.setEQ { $0.enabled = (obj["on"] as? Bool) ?? !$0.enabled }
        case "eqLowCut": if let v = obj["value"] as? Double { audio.setEQ { $0.highPassHz = max(0, min(150, v)) } }
        case "masterGain": if let v = obj["value"] as? Double { audio.setMasterGain(max(-60, min(6, v))) }
        // Screens
        case "visual":
            visuals?.manualStyle = (obj["style"] as? String).flatMap(VisualStyle.init(rawValue:))
        case "screensBlack": screens?.stopAll(fade: 1)
        case "testPattern": screens.map { $0.setTestPattern(!$0.testPatternOn) }
        case "openOutputs": screens?.openAllOutputs()
        // Effects — the phone can only make things SAFER (disarm / E-stop), never arm or fire.
        case "sfxDisarm": lighting.sfx?.disarmMaster(reason: "Disarmed from phone")
        // AI crew checklist
        case "liveMode":
            if let on = obj["on"] as? Bool { if on != (live?.running ?? false) { live?.toggle() } } else { live?.toggle() }
        case "crewCheck": crew?.runAudit()
        case "crewFixAll": crew?.runAudit(); crew?.fixAll()
        default:
            break
        }
    }

    // MARK: State

    private struct RemoteState: Encodable {
        struct CueItem: Encodable { let id: String; let number: String; let name: String; let kind: String; let notes: String; let running: Bool; let auto: String }
        struct Running: Encodable { let title: String; let number: String; let kind: String; let progress: Double?; let remaining: Double?; let elapsed: Double; let phase: String }
        struct Song: Encodable { let name: String; let section: String; let bpm: Double; let beat: Int; let vibe: String; let elapsed: Double; let duration: Double }
        struct Named: Encodable { let id: String; let name: String }
        let show: String
        let standbyIndex: Int
        let standby: CueItem?
        let cues: [CueItem]
        let running: [Running]
        let blackout: Bool
        let gm: Double
        let scenes: [Named]
        let activeScene: String?
        let performers: [Named]
        let follow: String?
        let song: Song?
        let vocalEnabled: Bool
        let vocalBypass: Bool
        let vocalPlugins: [String]
        let vocalPresets: [Named]
        let outputLevel: Double
        let clock: String
        // STRDM Live additions
        struct EQ: Encodable { let enabled: Bool; let gains: [Double]; let labels: [String]; let lowCut: Double; let preset: String; let presets: [String] }
        struct Dot: Encodable { let x: Double; let y: Double; let c: String; let l: Double; let kind: String }
        struct Person: Encodable { let x: Double; let y: Double; let name: String }
        struct MapState: Encodable { let w: Double; let d: Double; let lights: [Dot]; let people: [Person]; let items: [Dot] }
        struct Screen: Encodable { let name: String; let showing: String; let open: Bool }
        struct Crew: Encodable { let critical: Int; let warnings: Int; let fixable: Int; let top: [String] }
        let eq: EQ
        let masterGain: Double
        let sfxArmed: Bool
        let sfxUnits: Int
        let visualStyles: [Named]
        let visualStyle: String?
        let screens: [Screen]
        let map: MapState
        let crew: Crew?
        let liveOn: Bool
        let liveBPM: Double
        let liveSection: String
    }

    private func stateJSON() -> Data {
        let runningCueIDs = Set(engine.running.map(\.cueID))
        func item(_ c: Cue) -> RemoteState.CueItem {
            RemoteState.CueItem(id: c.id.uuidString, number: c.number, name: c.displayName, kind: c.kind.rawValue,
                                notes: c.notes, running: runningCueIDs.contains(c.id), auto: c.continueMode.shortLabel)
        }
        let now = Date()
        let running = engine.running.map { r -> RemoteState.Running in
            let elapsed = now.timeIntervalSince(r.startedAt)
            let progress = r.duration.flatMap { $0 > 0 ? min(1, elapsed / $0) : nil }
            let remaining = r.duration.map { max(0, $0 - elapsed) }
            let phase: String
            switch r.phase {
            case .preWait: phase = "pre-wait"
            case .running: phase = "running"
            case .fading: phase = "fading"
            }
            return RemoteState.Running(title: r.title, number: r.cueNumber, kind: r.kind.rawValue, progress: progress,
                                       remaining: remaining, elapsed: elapsed, phase: phase)
        }
        let song = lighting.songStatus.map {
            RemoteState.Song(name: $0.name, section: $0.section, bpm: $0.bpm, beat: $0.beat, vibe: $0.vibe.label,
                             elapsed: $0.elapsed, duration: $0.duration)
        }
        let rack = store.show.vocalRack
        let state = RemoteState(
            show: store.show.name,
            standbyIndex: engine.standbyIndex,
            standby: engine.standbyCue.map(item),
            cues: store.show.cues.map(item),
            running: running,
            blackout: lighting.blackout,
            gm: lighting.grandMaster,
            scenes: store.show.lighting.scenes.map { .init(id: $0.id.uuidString, name: $0.name) },
            activeScene: lighting.activeSceneID?.uuidString,
            performers: lighting.performers.map { .init(id: $0.id.uuidString, name: $0.label) },
            follow: lighting.followTargetID?.uuidString,
            song: song,
            vocalEnabled: rack.enabled,
            vocalBypass: rack.bypassAll,
            vocalPlugins: rack.plugins.map(\.name),
            vocalPresets: rack.presets.map { .init(id: $0.id.uuidString, name: $0.name) },
            outputLevel: Double(audio.outputLevel),
            clock: now.formatted(date: .omitted, time: .standard),
            eq: {
                let e = store.show.audioSettings.eq ?? MasterEQ()
                return .init(enabled: e.enabled, gains: e.gains, labels: MasterEQ.labels, lowCut: e.highPassHz,
                             preset: e.preset, presets: MasterEQ.presets.map(\.name))
            }(),
            masterGain: store.show.audioSettings.masterGainDB,
            sfxArmed: lighting.sfx?.masterArmed ?? false,
            sfxUnits: store.show.effects.devices.count,
            visualStyles: VisualStyle.allCases.map { .init(id: $0.rawValue, name: $0.label) },
            visualStyle: visuals?.manualStyle?.rawValue,
            screens: store.show.screens.map { s in
                .init(name: s.name, showing: screens?.nowShowing[s.id] ?? "", open: screens?.isOpen(s.id) ?? false)
            },
            map: mapState(),
            crew: crew.map { c in
                .init(critical: c.issues.filter { $0.severity == .critical }.count,
                      warnings: c.issues.filter { $0.severity == .warning }.count,
                      fixable: c.issues.filter { $0.fix != nil }.count,
                      top: c.issues.prefix(5).map { "\($0.severity.label): \($0.title)" })
            },
            liveOn: live?.running ?? false,
            liveBPM: live?.bpm ?? 0,
            liveSection: live?.section ?? "")
        return (try? JSONEncoder().encode(state)) ?? Data("{}".utf8)
    }

    var crowdJoinURL: String? { crowd?.cloudJoinURL ?? addresses.first.map { "\($0)/crowd" } }

    private func crowdJSON() -> Data {
        var obj = crowd?.controlState ?? [:]
        obj["joinURL"] = crowdJoinURL ?? ""
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    }

    private func mapState() -> RemoteState.MapState {
        let plot = store.show.stagePlot
        let lights = lighting.fixtures.map { f -> RemoteState.Dot in
            let p = lighting.position(f)
            let role = lighting.role(f)
            let c: RGB = role == .laser ? lighting.laserState(f).color : RGB(lighting.previewColor(f))
            let level = role == .laser ? (lighting.laserState(f).on ? 1 : 0) : lighting.outputLevel(f)
            return .init(x: p.x, y: p.y, c: c.hex, l: (level * 100).rounded() / 100, kind: "\(role)")
        }
        let people = plot.items.filter { $0.kind == .person }.map { RemoteState.Person(x: $0.x, y: $0.y, name: $0.label) }
        let items = plot.items.filter { [.ledWall, .riser, .drumRiser, .djBooth, .catwalk, .bStage, .truss].contains($0.kind) }
            .map { RemoteState.Dot(x: $0.x, y: $0.y, c: String(format: "%.1f,%.1f,%.0f", $0.width, $0.depth, $0.rotation), l: 0, kind: $0.kind.rawValue) }
        return .init(w: plot.stageWidth, d: plot.stageDepth, lights: lights, people: people, items: items)
    }

    // MARK: Networking helpers

    nonisolated static func readRequest(_ connection: NWConnection, buffer: Data,
                                        completion: @escaping @Sendable (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            var buf = buffer
            if let data { buf.append(data) }
            if let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[buf.startIndex..<headerEnd.lowerBound], as: UTF8.self).lowercased()
                var contentLength = 0
                for line in head.split(separator: "\r\n") where line.hasPrefix("content-length:") {
                    contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
                }
                if buf.distance(from: headerEnd.upperBound, to: buf.endIndex) >= contentLength {
                    completion(buf)
                    return
                }
            }
            // Headers must arrive in the first 64 KB; bodies (crowd media uploads) may be up to 300 MB.
            let headerDone = buf.range(of: Data("\r\n\r\n".utf8)) != nil
            if isComplete || error != nil || (!headerDone && buf.count > 65_536) || buf.count > 300_000_000 {
                completion(buf.isEmpty ? nil : buf)
                return
            }
            RemoteServer.readRequest(connection, buffer: buf, completion: completion)
        }
    }

    nonisolated static func lanURLs(port: UInt16) -> [String] {
        var ips: [(String, String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let name = String(decoding: Data(bytes: ptr.pointee.ifa_name, count: strlen(ptr.pointee.ifa_name)), as: UTF8.self)
            if ip.hasPrefix("169.254.") { continue }
            ips.append((name, ip))
        }
        // Wi-Fi / Ethernet first
        ips.sort { ($0.0.hasPrefix("en") ? 0 : 1, $0.0) < ($1.0.hasPrefix("en") ? 0 : 1, $1.0) }
        var urls = ips.map { "http://\($0.1):\(port)" }
        if let local = SCDynamicStoreCopyLocalHostName(nil) as String? {
            urls.append("http://\(local).local:\(port)")
        }
        return urls
    }

    static func randomPIN() -> String { String(format: "%04d", Int.random(in: 0...9999)) }

    static func qrImage(_ text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    private static func makeIcon() -> Data {
        let size = 180
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        NSGradient(colors: [NSColor(red: 1, green: 0.08, blue: 0.58, alpha: 1),
                            NSColor(red: 0.42, green: 0, blue: 1, alpha: 1)])?.draw(in: rect, angle: -45)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let go: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 72, weight: .black),
                                                 .foregroundColor: NSColor.white, .paragraphStyle: style]
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22, weight: .heavy),
                                                    .foregroundColor: NSColor.white.withAlphaComponent(0.85), .paragraphStyle: style]
        ("GO" as NSString).draw(in: NSRect(x: 0, y: 58, width: size, height: 90), withAttributes: go)
        ("STRDM" as NSString).draw(in: NSRect(x: 0, y: 26, width: size, height: 30), withAttributes: label)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}

// MARK: - Minimal HTTP

struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data
    let clientIP: String

    init?(raw: Data, connection: NWConnection) {
        guard let headerEnd = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: raw[raw.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        method = String(requestLine[0]).uppercased()
        let target = String(requestLine[1])
        let comps = URLComponents(string: "http://remote" + target)
        path = comps?.path.isEmpty == false ? comps!.path : "/"
        var q: [String: String] = [:]
        for item in comps?.queryItems ?? [] { q[item.name] = item.value ?? "" }
        query = q
        var h: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            h[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        headers = h
        body = Data(raw[headerEnd.upperBound...])
        if case let .hostPort(host, _) = connection.endpoint {
            clientIP = "\(host)".components(separatedBy: "%").first ?? "\(host)"
        } else {
            clientIP = "unknown"
        }
    }
}

struct HTTPResponse {
    let status: Int
    let contentType: String
    let body: Data
    var cache = false

    var data: Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        default: reason = "Error"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += cache ? "Cache-Control: max-age=86400\r\n" : "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func text(_ status: Int, _ message: String) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(message.utf8))
    }

    static func json(_ body: Data) -> Data {
        HTTPResponse(status: 200, contentType: "application/json", body: body).data
    }
}
