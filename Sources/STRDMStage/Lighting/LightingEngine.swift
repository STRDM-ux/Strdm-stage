import Foundation
import SwiftUI
import AppKit

/// Live lighting state, scene recall with timed fades, grand master, blackout and 40 Hz DMX output.
@MainActor
final class LightingEngine: ObservableObject {
    /// Current output per fixture (before grand master / blackout).
    @Published var live: [UUID: [Double]] = [:]
    @Published var blackout = false
    @Published var grandMaster: Double = 1.0
    @Published var selected: Set<UUID> = []
    @Published var activeSceneID: UUID? = nil
    @Published private(set) var fadeProgress: Double? = nil
    private(set) var packetsSent = 0   // not @Published: would redraw the UI 40×/s

    // Song light shows (Light Set Builder) — see LightingEngine+SongShow.swift
    struct SongRun {
        let show: LightShow
        let start: Date
        let offset: Double
        let instanceID: UUID
        var sectionIndex = -1
        var previousLook: SectionLook?
        var sectionChangedAt = Date()
        var currentPattern: ChaseKind = .still
        var lastSFXBar = 0
        var currentMover: MoverMode = .still
    }
    var songRun: SongRun?
    @Published var songStatus: SongShowStatus? = nil

    // Live stage map: performer positions (metres) and moving-head follow
    @Published var performerPositions: [UUID: CGPoint] = [:]
    @Published var followTargetID: UUID? = nil
    @Published var followFixtures: Set<UUID> = []
    var defaultPositions: [UUID: SIMD3<Double>] = [:]

    let store: ShowStore
    /// Special effects merged into the DMX output.
    weak var sfx: SFXEngine?
    private let output = DMXOutput()
    private var timer: Timer?

    struct Fade {
        var from: [UUID: [Double]]
        var to: [UUID: [Double?]]
        var start: Date
        var duration: Double
        var completion: (() -> Void)?
    }
    var fade: Fade?

    static let frameRate = 40.0

    init(store: ShowStore) {
        self.store = store
        syncPatch()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / Self.frameRate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let t = timer { RunLoop.main.add(t, forMode: .common) }
    }

    var fixtures: [Fixture] { store.show.lighting.fixtures }
    var scenes: [LightScene] { store.show.lighting.scenes }

    // MARK: Patch

    /// Makes sure every patched fixture has a live value array of the right length.
    func syncPatch() {
        var changed = false
        var next = live
        let ids = Set(fixtures.map(\.id))
        for f in fixtures where next[f.id]?.count != f.footprint {
            next[f.id] = f.profile.channels.map { Double($0.defaultValue) }
            changed = true
        }
        for key in next.keys where !ids.contains(key) {
            next[key] = nil
            changed = true
        }
        if changed { live = next }
        computeDefaultPositions()
    }

    func addFixtures(profile: FixtureProfile, count: Int, baseName: String, universe: Int, startAddress: Int, group: String) {
        var address = startAddress
        for i in 0..<max(1, count) {
            let name = count > 1 ? "\(baseName) \(i + 1)" : baseName
            store.show.lighting.fixtures.append(Fixture(name: name, profile: profile, universe: universe, address: address, group: group))
            address += profile.channels.count
        }
        syncPatch()
    }

    func removeFixtures(_ ids: Set<UUID>) {
        store.show.lighting.fixtures.removeAll { ids.contains($0.id) }
        selected.subtract(ids)
        syncPatch()
    }

    /// Next free address after everything already patched on a universe.
    func nextFreeAddress(universe: Int) -> Int {
        let last = fixtures.filter { $0.universe == universe }.map(\.lastAddress).max() ?? 0
        return min(512, last + 1)
    }

    /// Fixtures that overlap another fixture's addresses or run past channel 512.
    var conflicts: Set<UUID> {
        var result = Set<UUID>()
        let list = fixtures
        for (i, a) in list.enumerated() {
            if a.lastAddress > 512 || a.address < 1 { result.insert(a.id) }
            for b in list[(i + 1)...] where a.universe == b.universe {
                if a.address <= b.lastAddress && b.address <= a.lastAddress {
                    result.insert(a.id); result.insert(b.id)
                }
            }
        }
        return result
    }

    // MARK: Programmer

    func value(_ fixtureID: UUID, _ channel: Int) -> Double {
        live[fixtureID]?[safe: channel] ?? 0
    }

    func setValue(_ fixtureID: UUID, channel: Int, value: Double) {
        guard var values = live[fixtureID], values.indices.contains(channel) else { return }
        fade = nil
        if songRun != nil { stopSongShow() }
        values[channel] = max(0, min(255, value))
        live[fixtureID] = values
        activeSceneID = nil
    }

    /// Sets a channel by kind on every selected fixture that has it (e.g. all dimmers to 80%).
    func setKind(_ kind: ChannelKind, value: Double, fixtures ids: Set<UUID>? = nil) {
        let targets = ids ?? selected
        for f in fixtures where targets.contains(f.id) {
            for (i, ch) in f.profile.channels.enumerated() where ch.kind == kind {
                setValue(f.id, channel: i, value: value)
            }
        }
    }

    func setColor(_ color: Color, fixtures ids: Set<UUID>? = nil) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        let r = Double(ns.redComponent) * 255, g = Double(ns.greenComponent) * 255, b = Double(ns.blueComponent) * 255
        setKind(.red, value: r, fixtures: ids)
        setKind(.green, value: g, fixtures: ids)
        setKind(.blue, value: b, fixtures: ids)
    }

    func clearSelected() {
        for f in fixtures where selected.contains(f.id) {
            live[f.id] = f.profile.channels.map { Double($0.defaultValue) }
        }
        activeSceneID = nil
    }

    // MARK: Scenes

    /// Records the current live look. If `onlySelected`, other fixtures are left out of the scene (they track).
    @discardableResult
    func recordScene(named name: String, onlySelected: Bool) -> LightScene {
        var scene = LightScene(name: name)
        for f in fixtures where !onlySelected || selected.contains(f.id) {
            scene.levels[f.id.uuidString] = (live[f.id] ?? []).map { Int($0.rounded()) }
        }
        store.show.lighting.scenes.append(scene)
        activeSceneID = scene.id
        return scene
    }

    func updateScene(_ id: UUID) {
        guard let i = store.show.lighting.scenes.firstIndex(where: { $0.id == id }) else { return }
        var levels: [String: [Int]] = [:]
        for f in fixtures {
            levels[f.id.uuidString] = (live[f.id] ?? []).map { Int($0.rounded()) }
        }
        store.show.lighting.scenes[i].levels = levels
    }

    func goToScene(_ id: UUID, fade seconds: Double, completion: (() -> Void)? = nil) {
        guard let scene = scenes.first(where: { $0.id == id }) else { completion?(); return }
        if songRun != nil { stopSongShow() }
        fade?.completion?()
        var to: [UUID: [Double?]] = [:]
        var snapped = live
        for f in fixtures {
            guard let levels = scene.levels[f.id.uuidString] else { continue }
            var targets: [Double?] = []
            for (i, ch) in f.profile.channels.enumerated() {
                let v = levels[safe: i] ?? -1
                if v < 0 { targets.append(nil); continue }
                // Wheels, gobos, strobe and macro channels jump instead of crawling through every slot.
                switch ch.kind {
                case .colorWheel, .gobo, .strobe, .other:
                    snapped[f.id]?[i] = Double(v)
                    targets.append(nil)
                default:
                    targets.append(Double(v))
                }
            }
            to[f.id] = targets
        }
        live = snapped
        activeSceneID = id
        if seconds <= 0.01 {
            apply(to, progress: 1, from: live)
            completion?()
        } else {
            fade = Fade(from: live, to: to, start: Date(), duration: seconds, completion: completion)
        }
    }

    private func apply(_ to: [UUID: [Double?]], progress t: Double, from: [UUID: [Double]]) {
        var next = live
        for (id, targets) in to {
            guard var values = next[id], let start = from[id] else { continue }
            for (i, target) in targets.enumerated() where i < values.count {
                guard let target else { continue }
                let a = start[safe: i] ?? 0
                values[i] = a + (target - a) * t
            }
            next[id] = values
        }
        live = next
    }

    // MARK: Output loop

    private func tick() {
        if let f = fade {
            let raw = min(1, Date().timeIntervalSince(f.start) / f.duration)
            let eased = raw * raw * (3 - 2 * raw)   // smoothstep
            apply(f.to, progress: eased, from: f.from)
            fadeProgress = raw
            if raw >= 1 {
                fade = nil
                fadeProgress = nil
                f.completion?()
            }
        }
        if songRun != nil { applySongShow() }
        applyFollow()
        let setup = store.show.lighting
        guard setup.outputEnabled else { return }
        output.send(universes: buildUniverses(), setup: setup)
        packetsSent &+= 1
    }

    func buildUniverses() -> [Int: [UInt8]] {
        var universes: [Int: [UInt8]] = [:]
        let gm = max(0, min(1, grandMaster))
        for f in fixtures {
            guard let values = live[f.id] else { continue }
            var slots = universes[f.universe] ?? [UInt8](repeating: 0, count: 512)
            let colorIsIntensity = f.profile.colorIsIntensity
            for (i, ch) in f.profile.channels.enumerated() {
                let slot = f.address - 1 + i
                guard slot >= 0, slot < 512, i < values.count else { continue }
                var v = values[i]
                let scaled = ch.kind.isIntensityLike || (colorIsIntensity && ch.kind.isColor)
                if scaled {
                    v *= gm
                    if blackout { v = 0 }
                }
                // Lasers can't dim: blackout or a near-zero grand master switches them off.
                if ch.kind == .laserMode && (blackout || gm < 0.05) { v = 0 }
                slots[slot] = UInt8(max(0, min(255, v.rounded())))
            }
            universes[f.universe] = slots
        }
        sfx?.apply(to: &universes)
        return universes
    }

    /// Sends a frame right now (E-stop / quit).
    func flushOutput() {
        let setup = store.show.lighting
        guard setup.outputEnabled else { return }
        output.send(universes: buildUniverses(), setup: setup)
    }

    /// Approximate preview colour of a fixture for the on-screen grid.
    func previewColor(_ f: Fixture) -> Color {
        guard let values = live[f.id] else { return .black }
        var r = 0.0, g = 0.0, b = 0.0, dim = 1.0, hasColor = false
        for (i, ch) in f.profile.channels.enumerated() where i < values.count {
            let v = values[i] / 255
            switch ch.kind {
            case .red: r += v; hasColor = true
            case .green: g += v; hasColor = true
            case .blue: b += v; hasColor = true
            case .white: r += v; g += v; b += v; hasColor = true
            case .amber: r += v; g += v * 0.6; hasColor = true
            case .uv: r += v * 0.3; b += v * 0.8; hasColor = true
            case .intensity, .haze: dim = v
            default: break
            }
        }
        if !hasColor { r = 1; g = 0.95; b = 0.85 }
        let master = blackout ? 0 : grandMaster
        let k = (f.profile.colorIsIntensity ? 1 : dim) * master
        return Color(red: min(1, r) * k, green: min(1, g) * k, blue: min(1, b) * k)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
