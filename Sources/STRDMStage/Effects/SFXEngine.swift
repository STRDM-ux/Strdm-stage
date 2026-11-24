import Foundation
import AppKit

/// Arming, firing, burst limits, cooldowns, loads and E-stop for special effects.
/// DMX for effects is merged into the lighting output every frame (not affected by grand master/blackout).
@MainActor
final class SFXEngine: ObservableObject {
    enum Source { case manual, cue, songShow }

    struct Runtime: Equatable {
        var fireUntil: Date?
        var holdStarted: Date?
        var cooldownUntil: Date?
        var loadsUsed = 0
    }

    @Published private(set) var masterArmed = false
    @Published var armedDevices: Set<UUID> = []
    @Published var pyroClear = false
    @Published private(set) var runtime: [UUID: Runtime] = [:]
    @Published private(set) var log: [String] = []
    @Published private(set) var lastFired = Date()
    /// Visual-only previews for the 3D view (never sent to DMX, no arming needed).
    private(set) var previewUntil: [UUID: Date] = [:]
    /// When each unit last started firing (real or preview) — drives map animations.
    private(set) var visualStart: [UUID: Date] = [:]

    private let store: ShowStore
    private var generation = 0
    private var watchdog: Timer?
    /// Fired on every refusal / action so the show log can show it.
    var onNote: ((String) -> Void)?

    init(store: ShowStore) {
        self.store = store
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.emergencyStop(reason: "App quitting") }
        }
    }

    var devices: [SFXDevice] { store.show.effects.devices }

    // MARK: Arming

    func armMaster() {
        masterArmed = true
        lastFired = Date()
        note("⚠️ EFFECTS ARMED")
    }

    func disarmMaster(reason: String = "Disarmed") {
        generation += 1
        masterArmed = false
        pyroClear = false
        for id in runtime.keys {
            runtime[id]?.fireUntil = nil
            runtime[id]?.holdStarted = nil
        }
        note("Effects safe — \(reason)")
    }

    /// Kills every effect output immediately and disarms everything.
    func emergencyStop(reason: String = "E-STOP") {
        generation += 1
        masterArmed = false
        pyroClear = false
        armedDevices.removeAll()
        for id in runtime.keys {
            runtime[id]?.fireUntil = nil
            runtime[id]?.holdStarted = nil
        }
        note("🛑 \(reason): all effects off and disarmed")
        flush?()
    }
    /// Lighting engine hook to push a frame immediately (used by E-stop and quit).
    var flush: (() -> Void)?

    func toggleArm(_ id: UUID) {
        if armedDevices.contains(id) {
            armedDevices.remove(id)
            runtime[id]?.fireUntil = nil
            runtime[id]?.holdStarted = nil
        } else {
            armedDevices.insert(id)
        }
    }

    func armAll(kind: SFXKind? = nil) {
        for d in devices where kind == nil || d.kind == kind { armedDevices.insert(d.id) }
    }

    func reload(_ id: UUID) { runtime[id, default: Runtime()].loadsUsed = 0 }
    func reloadAll() { for d in devices { runtime[d.id, default: Runtime()].loadsUsed = 0 } }

    // MARK: Status

    enum Status: Equatable { case safe, armed, firing, cooling(Double), empty, notArmedMaster }

    func status(_ d: SFXDevice, now: Date = Date()) -> Status {
        let r = runtime[d.id] ?? Runtime()
        if isOutputOn(d, r, now) { return .firing }
        if !masterArmed { return .notArmedMaster }
        if !armedDevices.contains(d.id) { return .safe }
        if let loads = d.loads, r.loadsUsed >= loads { return .empty }
        if let c = r.cooldownUntil, c > now { return .cooling(c.timeIntervalSince(now)) }
        return .armed
    }

    func loadsLeft(_ d: SFXDevice) -> Int? {
        guard let loads = d.loads else { return nil }
        return max(0, loads - (runtime[d.id]?.loadsUsed ?? 0))
    }

    private func isOutputOn(_ d: SFXDevice, _ r: Runtime, _ now: Date) -> Bool {
        guard masterArmed, armedDevices.contains(d.id) else { return false }
        if let u = r.fireUntil, u > now { return true }
        if let h = r.holdStarted, now.timeIntervalSince(h) < d.maxBurst { return true }
        return false
    }

    // MARK: Firing

    /// Checks every interlock. Returns a reason when the device may not fire.
    func refusal(_ d: SFXDevice, source: Source) -> String? {
        if !store.show.lighting.outputEnabled { return "DMX output is off (Lighting → Output)" }
        if !masterArmed { return "effects not armed" }
        if !armedDevices.contains(d.id) { return "\(d.name) not armed" }
        if d.kind == .fireworks && !pyroClear { return "pyro area not confirmed clear" }
        if source == .songShow && !d.allowAuto { return "\(d.name) not allowed to auto-fire" }
        let r = runtime[d.id] ?? Runtime()
        if let loads = d.loads, r.loadsUsed >= loads { return "\(d.name) is empty — reload" }
        if let c = r.cooldownUntil, c > Date() { return String(format: "%@ cooling down (%.1fs)", d.name, c.timeIntervalSinceNow) }
        return nil
    }

    @discardableResult
    func fire(_ id: UUID, duration: Double? = nil, source: Source = .manual) -> Bool {
        guard let d = devices.first(where: { $0.id == id }) else { return false }
        if let why = refusal(d, source: source) {
            note("\(d.name) did not fire: \(why)")
            return false
        }
        let now = Date()
        let length = d.kind.isOneShot ? 0.5 : min(d.maxBurst, max(0.1, duration ?? d.kind.defaultBurst))
        var r = runtime[d.id] ?? Runtime()
        r.fireUntil = now.addingTimeInterval(length)
        r.cooldownUntil = now.addingTimeInterval(length + d.cooldown)
        if d.loads != nil { r.loadsUsed += 1 }
        runtime[d.id] = r
        visualStart[d.id] = now
        lastFired = now
        if source != .manual || d.kind.isOneShot { note("🔥 \(d.name) fired" + (d.kind.isOneShot ? "" : String(format: " %.1fs", length))) }
        return true
    }

    /// Hold-to-fire (flames, CO₂, sparks): output while held, capped at the device's max burst.
    func beginHold(_ id: UUID) {
        guard let d = devices.first(where: { $0.id == id }) else { return }
        if d.kind.isOneShot { fire(id); return }
        if let why = refusal(d, source: .manual) { note("\(d.name) did not fire: \(why)"); return }
        runtime[id, default: Runtime()].holdStarted = Date()
        visualStart[id] = Date()
        lastFired = Date()
    }

    func endHold(_ id: UUID) {
        guard var r = runtime[id], let start = r.holdStarted,
              let d = devices.first(where: { $0.id == id }) else { return }
        let held = min(d.maxBurst, Date().timeIntervalSince(start))
        r.holdStarted = nil
        r.cooldownUntil = Date().addingTimeInterval(d.cooldown)
        runtime[id] = r
        note(String(format: "%@ %.1fs", d.name, held))
    }

    /// Fires a set of devices in a pattern (ordered left → right on stage).
    func fire(_ ids: [UUID], pattern: SFXPattern, duration: Double? = nil, source: Source = .manual) {
        let list = order(devices.filter { ids.contains($0.id) })
        guard !list.isEmpty else { return }
        let step = max(0.03, store.show.effects.chaseStep)
        let n = list.count
        var delays: [(SFXDevice, Double)] = []
        switch pattern {
        case .all:
            delays = list.map { ($0, 0) }
        case .leftToRight:
            delays = list.enumerated().map { ($1, Double($0) * step) }
        case .rightToLeft:
            delays = list.enumerated().map { ($1, Double(n - 1 - $0) * step) }
        case .centerOut:
            let c = Double(n - 1) / 2
            delays = list.enumerated().map { ($1, (abs(Double($0) - c)).rounded(.down) * step) }
        case .outsideIn:
            let c = Double(n - 1) / 2
            delays = list.enumerated().map { ($1, (c - abs(Double($0) - c)).rounded(.down) * step) }
        case .alternate:
            delays = list.enumerated().map { ($1, $0 % 2 == 0 ? 0 : step * 3) }
        case .random:
            delays = list.shuffled().enumerated().map { ($1, Double($0) * step) }
        }
        let gen = generation
        for (d, delay) in delays {
            if delay <= 0 { fire(d.id, duration: duration, source: source); continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == gen else { return }   // E-stop cancels pending shots
                    self.fire(d.id, duration: duration, source: source)
                }
            }
        }
    }

    func fire(kind: SFXKind, pattern: SFXPattern, duration: Double? = nil, source: Source) {
        fire(devices.filter { $0.kind == kind }.map(\.id), pattern: pattern, duration: duration, source: source)
    }

    func order(_ list: [SFXDevice]) -> [SFXDevice] {
        let indexed = list.enumerated().map { ($0, $1) }
        return indexed.sorted { a, b in
            (a.1.stageX ?? Double(a.0)) < (b.1.stageX ?? Double(b.0))
        }.map(\.1)
    }

    // MARK: 3D preview

    /// True while the 3D view should show this unit firing (real output or a preview).
    func isVisuallyFiring(_ d: SFXDevice, now: Date = Date()) -> Bool {
        if let p = previewUntil[d.id], p > now { return true }
        return isOutputOn(d, runtime[d.id] ?? Runtime(), now)
    }

    /// Plays effects in the 3D view only — nothing is sent to the hardware.
    func preview(_ ids: [UUID], pattern: SFXPattern, duration: Double? = nil) {
        let list = order(devices.filter { ids.contains($0.id) })
        let step = max(0.03, store.show.effects.chaseStep)
        let n = list.count
        for (i, d) in list.enumerated() {
            var delay = 0.0
            switch pattern {
            case .all: delay = 0
            case .leftToRight: delay = Double(i) * step
            case .rightToLeft: delay = Double(n - 1 - i) * step
            case .centerOut: delay = abs(Double(i) - Double(n - 1) / 2).rounded(.down) * step
            case .outsideIn: let c = Double(n - 1) / 2; delay = (c - abs(Double(i) - c)).rounded(.down) * step
            case .alternate: delay = i % 2 == 0 ? 0 : step * 3
            case .random: delay = Double.random(in: 0...(step * Double(n)))
            }
            let length = d.kind.isOneShot ? 0.5 : min(d.maxBurst, duration ?? d.kind.defaultBurst)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    self?.previewUntil[d.id] = Date().addingTimeInterval(length)
                    self?.visualStart[d.id] = Date()
                    self?.objectWillChange.send()
                }
            }
        }
    }

    func preview(kind: SFXKind, pattern: SFXPattern, duration: Double? = nil) {
        preview(devices.filter { $0.kind == kind }.map(\.id), pattern: pattern, duration: duration)
    }

    func moveDevice(_ id: UUID, to p: CGPoint) {
        guard let i = store.show.effects.devices.firstIndex(where: { $0.id == id }) else { return }
        store.show.effects.devices[i].stageX = (p.x * 10).rounded() / 10
        store.show.effects.devices[i].stageY = (p.y * 10).rounded() / 10
    }

    /// Where a unit sits on stage (metres), with a default spread when it hasn't been placed.
    func stagePosition(_ d: SFXDevice, stageWidth w: Double, stageDepth depth: Double) -> CGPoint {
        if let x = d.stageX, let y = d.stageY { return CGPoint(x: x, y: y) }
        let same = order(devices.filter { $0.kind == d.kind })
        let k = same.firstIndex(of: d) ?? 0
        return CGPoint(x: w * (Double(k) + 1) / (Double(same.count) + 1), y: d.kind == .fireworks ? depth : 0.5)
    }

    // MARK: DMX

    /// Writes effect channels into the universes (after lighting, so effects win any overlap).
    func apply(to universes: inout [Int: [UInt8]]) {
        let now = Date()
        for d in devices {
            var slots = universes[d.universe] ?? [UInt8](repeating: 0, count: 512)
            let r = runtime[d.id] ?? Runtime()
            let armed = masterArmed && armedDevices.contains(d.id)
            func put(_ offset: Int?, _ value: Int) {
                guard let offset else { return }
                let slot = d.address - 1 + offset - 1
                guard slot >= 0, slot < 512 else { return }
                slots[slot] = UInt8(max(0, min(255, value)))
            }
            put(d.safetyChannel, armed ? d.safetyValue : 0)
            put(d.heightChannel, armed ? d.height : 0)
            put(d.fireChannel, isOutputOn(d, r, now) ? d.fireValue : 0)
            universes[d.universe] = slots
        }
    }

    // MARK: Housekeeping

    private func tick() {
        let now = Date()
        // Release holds that hit their max burst.
        for d in devices {
            if let h = runtime[d.id]?.holdStarted, now.timeIntervalSince(h) >= d.maxBurst {
                endHold(d.id)
                note("\(d.name): max burst reached")
            }
        }
        let mins = store.show.effects.autoDisarmMinutes
        if masterArmed && mins > 0 && now.timeIntervalSince(lastFired) > mins * 60 {
            disarmMaster(reason: "auto-disarmed after \(Int(mins)) min idle")
        }
        // Redraw cooldown/firing states a few times a second.
        if runtime.values.contains(where: { ($0.cooldownUntil ?? .distantPast) > now.addingTimeInterval(-0.3) || $0.holdStarted != nil }) {
            objectWillChange.send()
        }
    }

    func note(_ s: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        log.insert("\(stamp)  \(s)", at: 0)
        if log.count > 80 { log.removeLast() }
        onNote?(s)
    }

    /// Effect devices that share DMX addresses with each other or with lighting fixtures.
    func conflicts(fixtures: [Fixture]) -> Set<UUID> {
        var out = Set<UUID>()
        for (i, a) in devices.enumerated() {
            if a.address < 1 || a.lastAddress > 512 { out.insert(a.id) }
            for b in devices[(i + 1)...] where a.universe == b.universe && a.address <= b.lastAddress && b.address <= a.lastAddress {
                out.insert(a.id); out.insert(b.id)
            }
            for f in fixtures where f.universe == a.universe && a.address <= f.lastAddress && f.address <= a.lastAddress {
                out.insert(a.id)
            }
        }
        return out
    }
}
