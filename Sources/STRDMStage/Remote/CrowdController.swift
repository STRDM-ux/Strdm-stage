import Foundation
import AppKit
import os

/// Crowd phones: the audience opens /crowd (QR on the screens) and every phone becomes a pixel —
/// solid colours, beat pulses, strobes, rainbow waves, the live light colour, images, videos or text.
/// Phones render effects locally from a shared beat clock, so hundreds of them stay in sync with light traffic.
enum CrowdMode: String, CaseIterable, Identifiable, Codable {
    case off, follow, color, pulse, strobe, rainbow, sparkle, wave, image, video, text
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off (logo)"
        case .follow: return "Follow the lights"
        case .color: return "Solid colour"
        case .pulse: return "Pulse on the beat"
        case .strobe: return "Strobe"
        case .rainbow: return "Rainbow"
        case .sparkle: return "Sparkle (random)"
        case .wave: return "Colour wave"
        case .image: return "Image"
        case .video: return "Video"
        case .text: return "Text"
        }
    }
    var symbol: String {
        switch self {
        case .off: return "moon.fill"
        case .follow: return "lightbulb.2.fill"
        case .color: return "circle.fill"
        case .pulse: return "heart.fill"
        case .strobe: return "bolt.fill"
        case .rainbow: return "rainbow"
        case .sparkle: return "sparkles"
        case .wave: return "water.waves"
        case .image: return "photo.fill"
        case .video: return "film.fill"
        case .text: return "textformat"
        }
    }
}

struct CrowdMedia: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var kind: String          // "image" | "video"
    var file: String          // file name in the media folder
    var cloudURL: String? = nil
}

@MainActor
final class CrowdController: ObservableObject {
    @Published var mode: CrowdMode = .follow { didSet { changed() } }
    @Published var colors: [String] = ["#FF1493", "#7A00FF", "#FFFFFF"] { didSet { changed() } }
    @Published var speed: Double = 1 { didSet { changed() } }          // ×beat (pulse) / Hz (strobe)
    @Published var brightness: Double = 1 { didSet { changed() } }
    @Published var text: String = "" { didSet { changed() } }
    @Published var currentMediaID: String? { didSet { changed() } }
    @Published private(set) var media: [CrowdMedia] = []
    @Published private(set) var phones = 0

    // STRDM Live Cloud: phones on any network (venue Wi-Fi or 4G/5G) via strdm-live-cloud.vercel.app
    @Published var cloudEnabled = UserDefaults.standard.bool(forKey: "crowdCloud") {
        didSet { UserDefaults.standard.set(cloudEnabled, forKey: "crowdCloud"); if cloudEnabled { cloudStart() } }
    }
    @Published var cloudURL = UserDefaults.standard.string(forKey: "crowdCloudURL") ?? "https://strdm-live-cloud.vercel.app" {
        didSet { UserDefaults.standard.set(cloudURL, forKey: "crowdCloudURL") }
    }
    @Published private(set) var room: String
    @Published private(set) var cloudStatus = "Off"
    @Published private(set) var cloudPhones = 0
    private let roomKey: String
    private var serverOffsetMs: Double = 0
    private var lastPush = Date.distantPast
    private var lastPushedSeq = -1
    private var lastClockSync = Date.distantPast
    private var pushing = false

    private let lighting: LightingEngine
    private let store: ShowStore
    private var seq = 0
    private var timer: Timer?
    private var beatEpochMs: Double = 0
    private var bpm: Double = 120
    private var lastBeat = -1

    /// Served off the main thread to every phone.
    let cache: CrowdCache

    static var mediaFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let dir = docs.appendingPathComponent("STRDM Stage Shows/Crowd Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init(lighting: LightingEngine, store: ShowStore, cache: CrowdCache) {
        self.lighting = lighting
        self.store = store
        self.cache = cache
        let d = UserDefaults.standard
        if let r = d.string(forKey: "crowdRoom") { room = r } else {
            let letters = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
            let code = String((0..<5).map { _ in letters.randomElement()! })
            d.set(code, forKey: "crowdRoom")
            room = code
        }
        if let k = d.string(forKey: "crowdRoomKey") { roomKey = k } else {
            roomKey = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
            d.set(roomKey, forKey: "crowdRoomKey")
        }
        loadMedia()
        cache.mediaFolder = Self.mediaFolder
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func changed() { seq += 1 }

    // MARK: Media

    private var indexURL: URL { Self.mediaFolder.appendingPathComponent("index.json") }

    private func loadMedia() {
        if let d = try? Data(contentsOf: indexURL), let m = try? JSONDecoder().decode([CrowdMedia].self, from: d) {
            media = m.filter { FileManager.default.fileExists(atPath: Self.mediaFolder.appendingPathComponent($0.file).path) }
        }
    }
    private func saveMedia() { try? JSONEncoder().encode(media).write(to: indexURL) }

    @discardableResult
    func addMedia(data: Data, name: String) -> CrowdMedia? {
        let ext = (name as NSString).pathExtension.lowercased()
        let kind = ["mp4", "mov", "m4v", "webm"].contains(ext) ? "video" : "image"
        let id = UUID().uuidString.prefix(8).lowercased()
        let file = "\(id).\(ext.isEmpty ? (kind == "video" ? "mp4" : "jpg") : ext)"
        do { try data.write(to: Self.mediaFolder.appendingPathComponent(file)) } catch { return nil }
        let m = CrowdMedia(id: String(id), name: (name as NSString).deletingPathExtension, kind: kind, file: file)
        media.append(m)
        saveMedia()
        if cloudEnabled { Task { await uploadToCloud(m.id) } }
        return m
    }

    func addMedia(from url: URL) {
        guard let d = try? Data(contentsOf: url) else { return }
        if let m = addMedia(data: d, name: url.lastPathComponent) { show(m) }
    }

    // MARK: Cloud

    var cloudJoinURL: String? { cloudEnabled ? "\(cloudURL)/r/\(room)" : nil }

    func newRoom() {
        let letters = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        room = String((0..<5).map { _ in letters.randomElement()! })
        UserDefaults.standard.set(room, forKey: "crowdRoom")
        lastPushedSeq = -1
    }

    private func cloudStart() {
        cloudStatus = "Connecting…"
        lastClockSync = .distantPast
        lastPushedSeq = -1
        Task {
            await uploadLogo()
            for m in media where m.cloudURL == nil { await uploadToCloud(m.id) }
        }
    }

    /// STRDM Live logo on the audience join screen (uploaded once to the cloud CDN).
    var logoURL: String? { UserDefaults.standard.string(forKey: "crowdLogoURL") }
    func uploadLogo() async {
        guard logoURL == nil, let file = Bundle.main.url(forResource: "BrandMark", withExtension: "png"),
              let data = try? Data(contentsOf: file),
              let url = URL(string: "\(cloudURL)/api/upload?room=\(room)&name=strdm-live-logo.png") else { return }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue(roomKey, forHTTPHeaderField: "x-room-key")
        guard let (d, resp) = try? await URLSession.shared.upload(for: req, from: data),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let u = j["url"] as? String else { return }
        UserDefaults.standard.set(u, forKey: "crowdLogoURL")
        changed()
    }

    private func syncClock() async {
        guard let url = URL(string: "\(cloudURL)/api/time") else { return }
        var best: (rtt: Double, off: Double)?
        for _ in 0..<3 {
            let t0 = Date().timeIntervalSince1970 * 1000
            guard let (d, _) = try? await URLSession.shared.data(from: url),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let now = j["now"] as? Double else { continue }
            let t1 = Date().timeIntervalSince1970 * 1000
            let rtt = t1 - t0, off = now - (t0 + t1) / 2
            if best == nil || rtt < best!.rtt { best = (rtt, off) }
        }
        if let best { serverOffsetMs = best.off }
        lastClockSync = Date()
    }

    /// Pushes the crowd state to the cloud: right away on any change, 4×/s while following the lights, else every 2 s.
    private func cloudTick(_ obj: [String: Any]) {
        guard cloudEnabled, !pushing else { return }
        let due = seq != lastPushedSeq || Date().timeIntervalSince(lastPush) > (mode == .follow ? 0.25 : 2)
        guard due, let url = URL(string: "\(cloudURL)/api/push?room=\(room)") else { return }
        var o = obj
        if let logo = logoURL { o["logo"] = logo }
        o["beatEpoch"] = (obj["beatEpoch"] as? Double ?? 0) + serverOffsetMs
        o["serverMs"] = (obj["serverMs"] as? Double ?? 0) + serverOffsetMs
        if let current = media.first(where: { $0.id == currentMediaID }) {
            if let c = current.cloudURL { o["media"] = ["url": c, "kind": current.kind] } else { o.removeValue(forKey: "media") }
        }
        guard let body = try? JSONSerialization.data(withJSONObject: o) else { return }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(roomKey, forHTTPHeaderField: "x-room-key")
        req.httpBody = body
        pushing = true
        let sentSeq = seq
        Task {
            defer { self.pushing = false }
            if Date().timeIntervalSince(self.lastClockSync) > 60 { await self.syncClock() }
            do {
                let (d, resp) = try await URLSession.shared.upload(for: req, from: body)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let j = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
                if code == 200 {
                    self.lastPush = Date(); self.lastPushedSeq = sentSeq
                    self.cloudPhones = j["phones"] as? Int ?? 0
                    self.cloudStatus = (j["shared"] as? Bool ?? false) ? "Live on the cloud" : "Live (test mode — add Redis for big crowds)"
                } else if code == 403 {
                    self.cloudStatus = "Room code taken — pick a new one"
                } else {
                    self.cloudStatus = "Cloud error \(code)"
                }
            } catch {
                self.cloudStatus = "Offline — retrying (\(error.localizedDescription))"
                self.lastPush = Date()
            }
        }
    }

    /// Sends one crowd image/video to the cloud CDN (images are shrunk to fit the 4 MB limit).
    func uploadToCloud(_ id: String) async {
        guard cloudEnabled, let i = media.firstIndex(where: { $0.id == id }) else { return }
        let m = media[i]
        let file = Self.mediaFolder.appendingPathComponent(m.file)
        guard var data = try? Data(contentsOf: file) else { return }
        var name = m.file
        if m.kind == "image" && data.count > 4_000_000, let img = NSImage(data: data) {
            let scale = min(1, 1600 / max(img.size.width, img.size.height))
            let size = NSSize(width: img.size.width * scale, height: img.size.height * scale)
            let small = NSImage(size: size, flipped: false) { r in img.draw(in: r); return true }
            if let tiff = small.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                data = jpg; name = (m.file as NSString).deletingPathExtension + ".jpg"
            }
        }
        guard data.count <= 4_400_000 else { cloudStatus = "“\(m.name)” is over 4 MB — use a shorter / smaller video for cloud phones"; return }
        guard let url = URL(string: "\(cloudURL)/api/upload?room=\(room)&name=\(name)") else { return }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue(roomKey, forHTTPHeaderField: "x-room-key")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        guard let (d, resp) = try? await URLSession.shared.upload(for: req, from: data),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let u = j["url"] as? String,
              let k = media.firstIndex(where: { $0.id == id }) else { cloudStatus = "Upload failed for “\(m.name)”"; return }
        media[k].cloudURL = u
        saveMedia()
        changed()
    }

    func removeMedia(_ id: String) {
        guard let m = media.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: Self.mediaFolder.appendingPathComponent(m.file))
        media.removeAll { $0.id == id }
        if currentMediaID == id { currentMediaID = nil; if mode == .image || mode == .video { mode = .off } }
        saveMedia()
    }

    func show(_ m: CrowdMedia) {
        currentMediaID = m.id
        mode = m.kind == "video" ? .video : .image
    }

    // MARK: State

    /// What the phones get (no PIN — it's the audience page).
    private func tick() {
        let now = Date().timeIntervalSince1970 * 1000
        if let s = lighting.songStatus, s.bpm > 0 {
            bpm = s.bpm
            if s.beat != lastBeat { lastBeat = s.beat; beatEpochMs = now - Double(s.beat) * 60_000 / s.bpm }
        } else if lastBeat != -1 {
            lastBeat = -1
        }
        if beatEpochMs == 0 { beatEpochMs = now }
        let wash = washColor()
        let current = media.first { $0.id == currentMediaID }
        var obj: [String: Any] = [
            "seq": seq, "mode": lighting.blackout ? "off" : mode.rawValue, "colors": colors, "speed": speed,
            "bright": brightness * (mode == .follow ? 1 : lighting.grandMaster), "bpm": bpm, "beatEpoch": beatEpochMs,
            "serverMs": now, "follow": wash, "text": text,
            "artist": store.show.venue.artist, "blackout": lighting.blackout
        ]
        if let current { obj["media"] = ["url": "/crowd/media/\(current.file)", "kind": current.kind] }
        if let d = try? JSONSerialization.data(withJSONObject: obj) { cache.state = d }
        cloudTick(obj)
        let count = cache.activePhones() + (cloudEnabled ? cloudPhones : 0)
        if count != phones { phones = count }
    }

    /// Average colour of the stage right now, weighted by how bright each fixture is.
    private func washColor() -> String {
        var r = 0.0, g = 0.0, b = 0.0, w = 0.0
        for f in lighting.fixtures {
            let role = lighting.role(f)
            guard role == .color || role == .mover || role == .dimmer else { continue }
            let level = lighting.outputLevel(f)
            guard level > 0.02 else { continue }
            let c = RGB(lighting.previewColor(f))
            r += c.r * level; g += c.g * level; b += c.b * level; w += level
        }
        guard w > 0 else { return "#000000" }
        let m = max(r, g, b, 0.0001)
        let k = min(1, (w / Double(max(1, lighting.fixtures.count))) * 3)   // overall brightness
        return RGB(r: r / m * k, g: g / m * k, b: b / m * k).hex
    }

    /// For the STRDM Live controller apps.
    var controlState: [String: Any] {
        ["mode": mode.rawValue, "colors": colors, "speed": speed, "bright": brightness, "text": text,
         "current": currentMediaID ?? "", "phones": phones,
         "media": media.map { ["id": $0.id, "name": $0.name, "kind": $0.kind, "url": "/crowd/media/\($0.file)"] },
         "modes": CrowdMode.allCases.map { ["id": $0.rawValue, "name": $0.label] }]
    }

    func perform(_ obj: [String: Any]) {
        if let m = (obj["mode"] as? String).flatMap(CrowdMode.init(rawValue:)) { mode = m }
        if let c = obj["colors"] as? [String], !c.isEmpty { colors = Array(c.prefix(4)) }
        if let s = obj["speed"] as? Double { speed = max(0.25, min(16, s)) }
        if let b = obj["bright"] as? Double { brightness = max(0, min(1, b)) }
        if let t = obj["text"] as? String { text = String(t.prefix(80)) }
        if let id = obj["media"] as? String, let m = media.first(where: { $0.id == id }) { show(m) }
        if let id = obj["removeMedia"] as? String { removeMedia(id) }
    }
}

/// Thread-safe cache the HTTP server reads without touching the main thread.
final class CrowdCache: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var _state = Data("{}".utf8)
    private var _seen: [String: Date] = [:]
    private var _folder: URL?

    var state: Data {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }
    var mediaFolder: URL? {
        get { lock.withLock { _folder } }
        set { lock.withLock { _folder = newValue } }
    }
    func seen(_ ip: String) { lock.withLock { _seen[ip] = Date() } }
    func activePhones() -> Int {
        lock.withLock {
            let cutoff = Date().addingTimeInterval(-10)
            _seen = _seen.filter { $0.value > cutoff }
            return _seen.count
        }
    }

    /// Handles /crowd, /crowd/state and /crowd/media/… (Range requests so iPhones can play video).
    func respond(_ r: HTTPRequest) -> Data? {
        switch r.path {
        case "/crowd", "/crowd/":
            return HTTPResponse(status: 200, contentType: "text/html; charset=utf-8", body: Data(CrowdWebApp.html.utf8)).data
        case "/crowd/brand.png":
            guard let u = Bundle.main.url(forResource: "BrandMark", withExtension: "png"), let d = try? Data(contentsOf: u) else { return nil }
            return HTTPResponse(status: 200, contentType: "image/png", body: d, cache: true).data
        case "/crowd/state":
            seen(r.clientIP)
            return HTTPResponse.json(state)
        default:
            guard r.path.hasPrefix("/crowd/media/"), let folder = mediaFolder else { return nil }
            let name = (r.path as NSString).lastPathComponent
            guard !name.contains(".."), let fh = try? FileHandle(forReadingFrom: folder.appendingPathComponent(name)) else {
                return HTTPResponse.text(404, "Not found").data
            }
            defer { try? fh.close() }
            let size = (try? fh.seekToEnd()) ?? 0
            let ext = (name as NSString).pathExtension.lowercased()
            let type = ["mp4": "video/mp4", "m4v": "video/mp4", "mov": "video/quicktime", "webm": "video/webm",
                        "png": "image/png", "gif": "image/gif", "heic": "image/heic"][ext] ?? "image/jpeg"
            if let range = r.headers["range"], range.hasPrefix("bytes="), size > 0 {
                let parts = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
                let start = UInt64(parts.first ?? "") ?? 0
                var end = parts.count > 1 ? (UInt64(parts[1]) ?? size - 1) : size - 1
                end = min(end, size - 1, start + 4_000_000)                   // 4 MB chunks
                guard start <= end else { return HTTPResponse.text(416, "Range").data }
                try? fh.seek(toOffset: start)
                let body = (try? fh.read(upToCount: Int(end - start + 1))) ?? Data()
                var head = "HTTP/1.1 206 Partial Content\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
                head += "Content-Range: bytes \(start)-\(end)/\(size)\r\nAccept-Ranges: bytes\r\nCache-Control: max-age=3600\r\nConnection: close\r\n\r\n"
                return Data(head.utf8) + body
            }
            try? fh.seek(toOffset: 0)
            let body = (try? fh.readToEnd()) ?? Data()
            var head = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            head += "Accept-Ranges: bytes\r\nCache-Control: max-age=3600\r\nConnection: close\r\n\r\n"
            return Data(head.utf8) + body
        }
    }
}

extension CrowdController {
    /// What a typical audience phone is showing right now — the 3D venue lights its crowd's phones with this.
    func previewColor(beat: Double, seed: Double) -> RGB {
        let cols = colors.compactMap { RGB(hexString: $0) }
        let first = cols.first ?? RGB(r: 1, g: 1, b: 1)
        if lighting.blackout { return .black }
        switch mode {
        case .off: return RGB(r: 0.05, g: 0.05, b: 0.08)
        case .follow: return RGB(hexString: washColor()) ?? .black
        case .color, .text: return first.scaled(brightness)
        case .pulse:
            let b = beat * speed
            let c = cols.isEmpty ? first : cols[Int(b) % cols.count]
            return c.scaled(brightness * pow(1 - (b - floor(b)), 2.2))
        case .strobe:
            return (Date().timeIntervalSinceReferenceDate * max(1, speed * 8)).truncatingRemainder(dividingBy: 1) < 0.35 ? first.scaled(brightness) : .black
        case .rainbow:
            let h = (Date().timeIntervalSinceReferenceDate * 60 * speed / 360 + seed).truncatingRemainder(dividingBy: 1)
            return RGB.hue(h).scaled(brightness)
        case .sparkle:
            let step = floor(beat * 2 * speed)
            let r = abs(sin((step + 1) * 12.9898 + seed * 78.233) * 43758.5453).truncatingRemainder(dividingBy: 1)
            return r > 0.82 ? (cols.isEmpty ? first : cols[Int(step) % cols.count]).scaled(brightness) : .black
        case .wave:
            let w = sin((beat * speed / 2 - seed) * 2 * .pi) * 0.5 + 0.5
            return (cols.isEmpty ? first : cols[Int(beat / 8) % cols.count]).scaled(brightness * w)
        case .image, .video: return RGB(r: 0.55, g: 0.55, b: 0.6)
        }
    }
}

extension RGB {
    func scaled(_ k: Double) -> RGB { RGB(r: r * k, g: g * k, b: b * k) }
    static func hue(_ h: Double) -> RGB {
        let x = h * 6, i = Int(x) % 6, f = x - floor(x)
        switch i {
        case 0: return RGB(r: 1, g: f, b: 0)
        case 1: return RGB(r: 1 - f, g: 1, b: 0)
        case 2: return RGB(r: 0, g: 1, b: f)
        case 3: return RGB(r: 0, g: 1 - f, b: 1)
        case 4: return RGB(r: f, g: 0, b: 1)
        default: return RGB(r: 1, g: 0, b: 1 - f)
        }
    }
}
