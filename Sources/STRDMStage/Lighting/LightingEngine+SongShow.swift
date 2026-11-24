import Foundation
import SwiftUI

struct SongShowStatus: Equatable {
    var name: String
    var section: String
    var bpm: Double
    var beat: Int
    var vibe: Vibe
    var elapsed: Double
    var duration: Double
    var pattern: String = ""
    var moverMove: String = ""
}

enum FixtureRole { case mover, color, dimmer, effect, haze, laser }

/// Beat-synced song shows, moving-head aiming and stage positions for the live map.
extension LightingEngine {

    // MARK: Roles & positions

    func role(_ f: Fixture) -> FixtureRole {
        let kinds = Set(f.profile.channels.map(\.kind))
        if kinds.contains(.laserMode) || kinds.contains(.laserPattern) { return .laser }
        if kinds.contains(.pan) || kinds.contains(.tilt) { return .mover }
        if kinds.contains(.haze) { return .haze }
        if kinds.contains(where: { $0.isColor }) { return .color }
        let name = (f.profile.name + " " + f.name).lowercased()
        if name.contains("strobe") || name.contains("blinder") { return .effect }
        return .dimmer
    }

    /// Where a fixture hangs (metres). Uses the saved position, else an automatic rig layout.
    func position(_ f: Fixture) -> SIMD3<Double> {
        if let x = f.stageX, let y = f.stageY { return SIMD3(x, y, f.stageZ ?? 6) }
        return defaultPositions[f.id] ?? SIMD3(store.show.stagePlot.stageWidth / 2, 0, 6)
    }

    /// Default rig: colour wash on the front truss, movers on the back truss, effects mid-stage, haze upstage.
    func computeDefaultPositions() {
        let w = store.show.stagePlot.stageWidth
        let d = store.show.stagePlot.stageDepth
        var result: [UUID: SIMD3<Double>] = [:]
        let groups: [(FixtureRole, Double, Double)] = [
            (.color, -0.8, 6), (.dimmer, -0.8, 6), (.mover, d - 1.2, 6.5), (.effect, d * 0.55, 6), (.haze, d - 0.4, 0.5),
            (.laser, d - 0.6, 4)
        ]
        for (r, y, z) in groups {
            let list = fixtures.filter { role($0) == r }
            for (i, f) in list.enumerated() {
                let x = w * (Double(i) + 1) / (Double(list.count) + 1)
                result[f.id] = SIMD3(r == .haze ? w - 0.8 : x, y, z)
            }
        }
        defaultPositions = result
    }

    /// Saves the automatic layout into the patch so it can be fine-tuned by dragging on the map.
    func autoPlaceFixtures() {
        store.show.lighting.fixtures = RigDesigner.replace(store.show.lighting.fixtures, plot: store.show.stagePlot,
                                                           trim: 6, role: role)
        computeDefaultPositions()
        return
        for i in store.show.lighting.fixtures.indices {
            let f = store.show.lighting.fixtures[i]
            if let p = defaultPositions[f.id] {
                store.show.lighting.fixtures[i].stageX = (p.x * 10).rounded() / 10
                store.show.lighting.fixtures[i].stageY = (p.y * 10).rounded() / 10
                store.show.lighting.fixtures[i].stageZ = p.z
            }
        }
    }

    func moveFixture(_ id: UUID, to point: CGPoint) {
        guard let i = store.show.lighting.fixtures.firstIndex(where: { $0.id == id }) else { return }
        let z = position(store.show.lighting.fixtures[i]).z
        store.show.lighting.fixtures[i].stageX = (point.x * 10).rounded() / 10
        store.show.lighting.fixtures[i].stageY = (point.y * 10).rounded() / 10
        store.show.lighting.fixtures[i].stageZ = z
    }

    // MARK: Performers

    var performers: [StageItem] {
        store.show.stagePlot.items.filter { $0.kind == .person || $0.kind == .vocalMic }
    }

    func performerPosition(_ item: StageItem) -> CGPoint {
        performerPositions[item.id] ?? CGPoint(x: item.x, y: item.y)
    }

    var leadPerformerID: UUID? { followTargetID ?? performers.first?.id }

    // MARK: Aiming

    /// Pan/tilt (0…1 of full range) that point a moving head at a spot. Assumes the common 540° pan / 270° tilt,
    /// fixture hung facing down, pan centre = facing the audience. Approximate — tweak per rig.
    func aim(_ f: Fixture, at target: SIMD3<Double>) -> (pan: Double, tilt: Double) {
        let p = position(f)
        let dx = target.x - p.x
        let dy = target.y - p.y
        let horizontal = (dx * dx + dy * dy).squareRoot()
        let drop = max(0.3, p.z - target.z)
        let panDeg = atan2(dx, -dy) * 180 / .pi
        let tiltDeg = atan2(horizontal, drop) * 180 / .pi
        return (clamp((panDeg + 270) / 540), clamp((tiltDeg + 135) / 270))
    }

    func angles(pan: Double, tilt: Double) -> (Double, Double) {
        (pan * 540 - 270, tilt * 270 - 135)
    }

    private func write(pan: Double, tilt: Double, into values: inout [Double], for f: Fixture) {
        let p16 = pan * 65535, t16 = tilt * 65535
        for (i, ch) in f.profile.channels.enumerated() where i < values.count {
            switch ch.kind {
            case .pan: values[i] = floor(p16 / 256)
            case .panFine: values[i] = p16.truncatingRemainder(dividingBy: 256)
            case .tilt: values[i] = floor(t16 / 256)
            case .tiltFine: values[i] = t16.truncatingRemainder(dividingBy: 256)
            default: break
            }
        }
    }

    /// Where the beam lands on the floor, for the live map.
    func beamTarget(_ f: Fixture) -> CGPoint {
        let p = position(f)
        guard role(f) == .mover, let values = live[f.id] else {
            // Fixed wash lights: front truss points upstage onto the performers, the rest point straight down-stage-ish.
            let y = p.y < 1 ? p.y + 2.5 : max(0.4, p.y - 2.0)
            return CGPoint(x: p.x, y: y)
        }
        var pan = 0.5, tilt = 0.5
        for (i, ch) in f.profile.channels.enumerated() where i < values.count {
            if ch.kind == .pan { pan = values[i] / 255 }
            if ch.kind == .tilt { tilt = values[i] / 255 }
        }
        let (panDeg, tiltDeg) = angles(pan: pan, tilt: tilt)
        let t = max(-80, min(80, tiltDeg)) * .pi / 180
        let distance = max(-14, min(14, p.z * tan(t)))
        let a = panDeg * .pi / 180
        return CGPoint(x: p.x + distance * sin(a), y: p.y - distance * cos(a))
    }

    /// 0…1 brightness of a fixture after grand master / blackout (for the map).
    func outputLevel(_ f: Fixture) -> Double {
        guard let values = live[f.id], !blackout else { return 0 }
        var dim: Double? = nil
        var colorMax = 0.0
        for (i, ch) in f.profile.channels.enumerated() where i < values.count {
            if ch.kind == .intensity || ch.kind == .haze { dim = max(dim ?? 0, values[i] / 255) }
            if ch.kind.isColor { colorMax = max(colorMax, values[i] / 255) }
        }
        let hasColor = f.profile.channels.contains { $0.kind.isColor }
        let level: Double
        if let dim { level = hasColor ? dim * colorMax : dim } else { level = colorMax }
        return level * grandMaster
    }

    // MARK: Follow

    func applyFollow() {
        let lookWantsFollow = songRun.map { run in
            run.sectionIndex >= 0 && run.sectionIndex < run.show.sections.count
                ? run.show.sections[run.sectionIndex].look.mover == .followLead : false
        } ?? false
        guard followTargetID != nil || lookWantsFollow,
              let targetID = leadPerformerID,
              let item = performers.first(where: { $0.id == targetID }) else { return }
        let pos = performerPosition(item)
        let target = SIMD3<Double>(Double(pos.x), Double(pos.y), 1.4)
        var next = live
        for f in fixtures where role(f) == .mover && (followFixtures.isEmpty || followFixtures.contains(f.id)) {
            guard var values = next[f.id] else { continue }
            let a = aim(f, at: target)
            write(pan: a.pan, tilt: a.tilt, into: &values, for: f)
            next[f.id] = values
        }
        if next != live { live = next }
    }

    // MARK: Song shows

    func startSongShow(_ show: LightShow, instanceID: UUID, offset: Double = 0) {
        fade = nil
        songRun = SongRun(show: show, start: Date(), offset: offset, instanceID: instanceID)
        activeSceneID = nil
    }

    func stopSongShow(instanceID: UUID? = nil) {
        guard let run = songRun else { return }
        if let instanceID, run.instanceID != instanceID { return }
        songRun = nil
        songStatus = nil
    }

    var songShowInstanceID: UUID? { songRun?.instanceID }

    func applySongShow() {
        guard var run = songRun else { return }
        let show = run.show
        let a = show.analysis
        let t = Date().timeIntervalSince(run.start) + run.offset
        guard !show.sections.isEmpty, t <= a.duration + 0.25 else {
            stopSongShow()
            return
        }
        let index = show.sections.lastIndex { $0.start <= t } ?? 0
        if index != run.sectionIndex {
            run.previousLook = run.sectionIndex >= 0 ? show.sections[run.sectionIndex].look : nil
            let firstFrame = run.sectionIndex < 0
            run.sectionIndex = index
            run.sectionChangedAt = Date()
            run.lastSFXBar = 0
            if !firstFrame || t > 0.5, let hit = show.sections[index].look.sfxHit, let sfx, sfx.masterArmed {
                sfx.fire(kind: hit, pattern: hit == .flame ? .leftToRight : .all, source: .songShow)
            }
        }
        songRun = run

        let section = show.sections[index]
        let look = section.look
        // Tracked beat grid (follows tempo drift); falls back to a steady BPM for older analyses
        let beat = max(0, a.beatPosition(t))
        let sectionStartBeat = max(0, a.beatPosition(section.start))
        var master = 1.0
        if show.fadeOutAtEnd > 0 && t > a.duration - show.fadeOutAtEnd {
            master = clamp((a.duration - t) / show.fadeOutAtEnd)
        }
        // Short cross-fade between sections; drops with a strobe hit snap instantly.
        let blend = look.strobeBeats > 0 ? 1 : clamp(Date().timeIntervalSince(run.sectionChangedAt) / 0.6)
        let previous = run.previousLook

        let washes = fixtures.filter { [.color, .dimmer].contains(role($0)) }.sorted { position($0).x < position($1).x }
        let movers = fixtures.filter { role($0) == .mover }.sorted { position($0).x < position($1).x }
        var next = live

        // Local energy vs. the section's average (from the analysed energy curve, ~2 values/s).
        var energyDelta = 0.0
        let curve = a.energyCurve
        if !curve.isEmpty {
            let k = max(0, min(curve.count - 1, Int(t * 2)))
            let lo = max(0, k - 2), hi = min(curve.count - 1, k + 1)
            let localE = curve[lo...hi].reduce(0, +) / Double(hi - lo + 1)
            energyDelta = (localE - section.energy) * 2.5
        }
        let sectionEndBeat = max(sectionStartBeat + 1, a.beatPosition(section.end))
        var ctx = PatternContext(beat: beat, sectionStartBeat: sectionStartBeat, sectionEndBeat: sectionEndBeat,
                                 energyDelta: energyDelta)
        ctx.kick = SongAnalysis.hitPulse(a.kicks, at: t, decay: 0.11)
        ctx.snare = SongAnalysis.hitPulse(a.snares, at: t, decay: 0.09)
        ctx.hats = SongAnalysis.curveValue(a.hatCurve, at: t)
        ctx.vocal = SongAnalysis.curveValue(a.vocalCurve, at: t)
        ctx.bass = SongAnalysis.curveValue(a.bassCurve, at: t)
        let resolved = PatternEngine.resolve(look, ctx)
        var prevCtx = ctx
        prevCtx.sectionStartBeat = 0
        prevCtx.sectionEndBeat = .greatestFiniteMagnitude
        let prevResolved = previous.map { PatternEngine.resolve($0, prevCtx) }
        run.currentPattern = resolved.chase
        run.currentMover = resolved.mover
        songRun = run

        func blended(_ i: Int, _ n: Int, isMover: Bool) -> (RGB, Double) {
            let now = PatternEngine.evaluate(look, resolved, ctx, index: i, count: n, isMover: isMover)
            guard blend < 1, let previous, let prevResolved else { return now }
            let before = PatternEngine.evaluate(previous, prevResolved, prevCtx, index: i, count: n, isMover: isMover)
            return (before.0.mix(now.0, blend), before.1 + (now.1 - before.1) * blend)
        }

        for (i, f) in washes.enumerated() {
            guard var values = next[f.id] else { continue }
            let (c, intensity) = blended(i, washes.count, isMover: false)
            Self.writeColor(c, intensity: intensity * master, into: &values, for: f)
            next[f.id] = values
        }

        let w = store.show.stagePlot.stageWidth, d = store.show.stagePlot.stageDepth
        let lead = leadPerformerID.flatMap { id in performers.first { $0.id == id } }.map(performerPosition)
        for (j, f) in movers.enumerated() {
            guard var values = next[f.id] else { continue }
            let (c, intensity) = blended(j, movers.count, isMover: true)
            Self.writeColor(c, intensity: intensity * master, into: &values, for: f)
            var mode = resolved.mover
            if resolved.buildProgress != nil { mode = (resolved.buildProgress ?? 0) < 0.6 ? .circle : .tiltWave }
            if let target = PatternEngine.moverTarget(mode, resolved, ctx, index: j, count: movers.count, stageWidth: w, stageDepth: d) {
                let p = aim(f, at: target)
                write(pan: p.pan, tilt: p.tilt, into: &values, for: f)
            } else {
                let pos = lead ?? CGPoint(x: w / 2, y: d / 2)
                let p = aim(f, at: SIMD3(Double(pos.x), Double(pos.y), 1.4))
                write(pan: p.pan, tilt: p.tilt, into: &values, for: f)
            }
            next[f.id] = values
        }

        // Repeating effect hits through the section (e.g. CO₂ every 8 bars in a drop).
        if let every = look.sfxEveryBars, every > 0, let hit = look.sfxHit, let sfx, sfx.masterArmed {
            let local = beat - sectionStartBeat
            let bar = Int(local / 4)
            if bar > 0, bar % every == 0, bar != run.lastSFXBar, local - Double(bar) * 4 < 0.5,
               sectionEndBeat - beat > 2 {
                run.lastSFXBar = bar
                songRun = run
                sfx.fire(kind: hit, pattern: phraseFlip(bar, every) ? .rightToLeft : .leftToRight, source: .songShow)
            }
        }

        // Lasers: pattern per section, palette colour per phrase, motion locked to the beat.
        let lasers = fixtures.filter { role($0) == .laser }.sorted { position($0).x < position($1).x }
        let laserLook: LaserLook = resolved.buildProgress != nil ? .chase : (look.laser ?? .off)
        let laserOn = laserLook != .off && !resolved.breath && master > 0.05
        let palette = [look.colorA, look.colorB, look.colorC ?? look.colorA]
        for (j, f) in lasers.enumerated() {
            guard var values = next[f.id] else { continue }
            let c = palette[(resolved.colorShift + j) % 3]
            let speedMul = resolved.buildProgress.map { 1 + 3 * $0 } ?? 1
            let dir = (resolved.reversed ? -1.0 : 1.0) * (j % 2 == 0 ? 1 : -1)
            let phase = beat * speedMul
            let pulse = pow(1 - (beat - floor(beat)), 3)
            for (i, ch) in f.profile.channels.enumerated() where i < values.count {
                switch ch.kind {
                case .laserMode: values[i] = laserOn ? 255 : 0
                case .laserPattern: values[i] = laserLook.patternValue
                case .laserColor: values[i] = Self.laserColorValue(c)
                case .laserZoom: values[i] = laserLook == .tunnel ? 40 + 50 * pulse : 64
                case .laserRotate:
                    values[i] = laserLook == .tunnel ? min(255, 128 + a.bpm / 2 * speedMul)
                        : (64 + 60 * sin(2 * .pi * phase / 8 * dir)).rounded()
                case .laserX:
                    values[i] = laserLook == .scan || laserLook == .chase
                        ? 64 + 60 * sin(2 * .pi * phase / (laserLook == .chase ? 2 : 4) * dir)
                        : 64 + 25 * sin(2 * .pi * phase / 16 * dir)
                case .laserY:
                    values[i] = laserLook == .sheet ? 64 + 18 * sin(2 * .pi * phase / 16) : 64 + 10 * cos(2 * .pi * phase / 8)
                case .laserSpeed: values[i] = 200
                case .strobe: values[i] = 0
                default: break
                }
            }
            next[f.id] = values
        }

        // Strobes / blinders: only on drop hits; hazers follow the look.
        let inStrobe = look.strobeBeats > 0 && beat >= sectionStartBeat && beat - sectionStartBeat < look.strobeBeats
        let flash = inStrobe && (beat * 4).truncatingRemainder(dividingBy: 1) < 0.5
        for f in fixtures {
            let r = role(f)
            guard r == .effect || r == .haze, var values = next[f.id] else { continue }
            for (i, ch) in f.profile.channels.enumerated() where i < values.count {
                if r == .effect && ch.kind == .intensity { values[i] = flash ? 255 * master : 0 }
                if r == .haze && ch.kind == .haze { values[i] = look.haze * 255 }
            }
            next[f.id] = values
        }
        live = next

        let beatInt = Int(beat)
        if songStatus?.beat != beatInt || songStatus?.section != section.label {
            songStatus = SongShowStatus(name: show.name, section: section.label, bpm: a.bpm, beat: beatInt,
                                        vibe: show.vibe, elapsed: t, duration: a.duration,
                                        pattern: resolved.buildProgress != nil ? "Build-up" : (resolved.inFill ? "Fill" : resolved.chase.label),
                                        moverMove: resolved.mover.label)
        }
    }

    // MARK: Look maths

    private func phraseFlip(_ bar: Int, _ every: Int) -> Bool { (bar / max(1, every)) % 2 == 1 }

    /// Nearest laser colour slot (red, green, blue, yellow, cyan, magenta, white) for an RGB colour.
    nonisolated static func laserColorValue(_ c: RGB) -> Double {
        let slots: [(RGB, Double)] = [
            (RGB(r: 1, g: 0, b: 0), 16), (RGB(r: 0, g: 1, b: 0), 48), (RGB(r: 0, g: 0, b: 1), 80),
            (RGB(r: 1, g: 1, b: 0), 112), (RGB(r: 0, g: 1, b: 1), 144), (RGB(r: 1, g: 0, b: 1), 176), (RGB(r: 1, g: 1, b: 1), 208)
        ]
        let m = max(0.001, max(c.r, c.g, c.b))
        let n = RGB(r: c.r / m, g: c.g / m, b: c.b / m)
        return slots.min { a, b in
            let da = pow(a.0.r - n.r, 2) + pow(a.0.g - n.g, 2) + pow(a.0.b - n.b, 2)
            let db = pow(b.0.r - n.r, 2) + pow(b.0.g - n.g, 2) + pow(b.0.b - n.b, 2)
            return da < db
        }!.1
    }

    nonisolated static func laserRGB(_ value: Double) -> RGB {
        switch Int(value / 32) {
        case 0: return RGB(r: 1, g: 0.05, b: 0.05)
        case 1: return RGB(r: 0.1, g: 1, b: 0.2)
        case 2: return RGB(r: 0.15, g: 0.3, b: 1)
        case 3: return RGB(r: 1, g: 0.9, b: 0.1)
        case 4: return RGB(r: 0.1, g: 1, b: 1)
        case 5: return RGB(r: 1, g: 0.1, b: 1)
        default: return RGB(r: 1, g: 1, b: 1)
        }
    }

    /// What a laser is showing right now, decoded from its live DMX values (for the map and 3D view).
    func laserState(_ f: Fixture) -> (on: Bool, look: LaserLook, color: RGB, rotation: Double, x: Double, zoom: Double) {
        guard let v = live[f.id] else { return (false, .off, .white, 0, 64, 64) }
        var on = false, look = LaserLook.beams, color = RGB.white, rot = 0.0, x = 64.0, zoom = 64.0
        for (i, ch) in f.profile.channels.enumerated() where i < v.count {
            switch ch.kind {
            case .laserMode: on = v[i] > 0 && !blackout && grandMaster > 0.05
            case .laserPattern: look = LaserLook.fromPattern(v[i])
            case .laserColor: color = Self.laserRGB(v[i])
            case .laserRotate: rot = v[i]
            case .laserX: x = v[i]
            case .laserZoom: zoom = v[i]
            default: break
            }
        }
        return (on, look, color, rot, x, zoom)
    }

    nonisolated static func hash(_ i: Int, _ step: Int) -> Double {
        let x = sin(Double(i) * 12.9898 + Double(step) * 78.233) * 43758.5453
        return x - floor(x)
    }

    nonisolated static func writeColor(_ c: RGB, intensity: Double, into values: inout [Double], for f: Fixture) {
        let colorIsIntensity = f.profile.colorIsIntensity
        let k = colorIsIntensity ? intensity : 1
        let white = min(c.r, c.g, c.b)
        for (i, ch) in f.profile.channels.enumerated() where i < values.count {
            switch ch.kind {
            case .intensity: values[i] = intensity * 255
            case .red: values[i] = c.r * 255 * k
            case .green: values[i] = c.g * 255 * k
            case .blue: values[i] = c.b * 255 * k
            case .white: values[i] = white * 0.8 * 255 * k
            case .amber, .uv, .strobe, .colorWheel, .gobo: values[i] = 0
            default: break
            }
        }
    }
}
