import Foundation

extension RGB {
    var hex: String {
        String(format: "#%02X%02X%02X", Int(max(0, min(1, r)) * 255), Int(max(0, min(1, g)) * 255), Int(max(0, min(1, b)) * 255))
    }
    init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(hex: v)
    }
}

/// Production Manager's checklist: finds what will go wrong on show night, and fixes what it safely can.
struct AuditIssue: Identifiable, Hashable {
    enum Severity: Int, Comparable { case info = 0, warning = 1, critical = 2
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
        var label: String { ["Note", "Warning", "Critical"][rawValue] }
    }
    enum Fix: String { case repatch, analyseMissing, reanalyseOld, dynamics, layoutStage, buildRig, endChain, placeEffects }
    let id: String
    let severity: Severity
    let area: String
    let title: String
    let detail: String
    let fix: Fix?
}

@MainActor
enum ProductionAudit {
    static func run(store: ShowStore, lighting: LightingEngine, screens: ScreenManager) -> [AuditIssue] {
        let show = store.show
        var out: [AuditIssue] = []
        let fm = FileManager.default

        // ── Lighting patch
        let fixtures = show.lighting.fixtures
        if fixtures.isEmpty {
            out.append(.init(id: "rig-empty", severity: .critical, area: "Lighting", title: "No lighting rig",
                             detail: "There are no fixtures patched, so nothing will light up.", fix: .buildRig))
        } else {
            var clashes: [String] = []
            var over512: [String] = []
            for u in Set(fixtures.map(\.universe)) {
                let list = fixtures.filter { $0.universe == u }.sorted { $0.address < $1.address }
                for (i, f) in list.enumerated() {
                    let end = f.address + f.profile.channels.count - 1
                    if end > 512 { over512.append(f.name) }
                    if i + 1 < list.count, list[i + 1].address <= end { clashes.append("\(f.name) / \(list[i + 1].name) (U\(u + 1))") }
                }
            }
            if !clashes.isEmpty {
                out.append(.init(id: "dmx-overlap", severity: .critical, area: "Lighting",
                                 title: "\(clashes.count) DMX address clash\(clashes.count == 1 ? "" : "es")",
                                 detail: clashes.prefix(6).joined(separator: ", ") + (clashes.count > 6 ? "…" : ""), fix: .repatch))
            }
            if !over512.isEmpty {
                out.append(.init(id: "dmx-512", severity: .critical, area: "Lighting", title: "Fixtures run past channel 512",
                                 detail: over512.prefix(6).joined(separator: ", "), fix: .repatch))
            }
            let roles = fixtures.map { lighting.role($0) }
            let usesLasers = show.lightShows.contains { $0.sections.contains { ($0.look.laser ?? .off) != .off } }
            if usesLasers && !roles.contains(.laser) {
                out.append(.init(id: "no-lasers", severity: .info, area: "Lighting", title: "Songs have laser looks but no laser is patched",
                                 detail: "Add lasers (Auto Rig adds them) or the laser parts of the show stay dark.", fix: nil))
            }
            if roles.contains(.laser) {
                out.append(.init(id: "laser-safety", severity: .warning, area: "Safety", title: "Lasers: keep beams above the audience",
                                 detail: "Aim lasers at least 3 m above the crowd unless the laser operator has an audience-scanning variance. Confirm with the venue.", fix: nil))
            }
            if !roles.contains(.haze) {
                out.append(.init(id: "no-haze", severity: .info, area: "Lighting", title: "No hazer in the rig",
                                 detail: "Beams and lasers won't show in the air without haze.", fix: nil))
            }
        }

        // ── Media + songs
        var missing: [String] = []
        for c in show.cues {
            if let p = c.audioPath, !fm.fileExists(atPath: p) { missing.append("\(c.number) \(c.name)") }
            if let p = c.videoPath, !fm.fileExists(atPath: p) { missing.append("\(c.number) \(c.name)") }
        }
        if !missing.isEmpty {
            out.append(.init(id: "missing-media", severity: .critical, area: "Media", title: "\(missing.count) cue\(missing.count == 1 ? "" : "s") point to missing files",
                             detail: missing.prefix(6).joined(separator: ", ") + ". Re-link them in the cue inspector, then use File › Collect Media.", fix: nil))
        }
        let unlit = show.cues.filter { c in
            c.kind == .audio && c.audioPath.map { fm.fileExists(atPath: $0) } == true &&
                !(c.lightShowID.map { id in show.lightShows.contains { $0.id == id } } ?? false)
        }
        if !unlit.isEmpty {
            out.append(.init(id: "songs-no-show", severity: .warning, area: "Lights", title: "\(unlit.count) song\(unlit.count == 1 ? " has" : "s have") no light show",
                             detail: unlit.prefix(6).map(\.name).joined(separator: ", "), fix: .analyseMissing))
        }
        let old = show.lightShows.filter { $0.analysis.beats == nil }
        if !old.isEmpty {
            out.append(.init(id: "old-analysis", severity: .warning, area: "Lights", title: "\(old.count) song\(old.count == 1 ? " was" : "s were") analysed with the old analyser",
                             detail: "Re-analyse for real drum hits, vocals and song structure.", fix: .reanalyseOld))
        }

        // ── Design (Creative Director's taste checks)
        for s in show.lightShows {
            let n = max(1, s.sections.count)
            let full = s.sections.filter { $0.look.intensity >= 0.9 }.count
            let strobes = s.sections.filter { $0.look.strobeBeats > 0 }.count
            let hits = s.sections.filter { $0.look.sfxHit != nil }.count
            let lasers = s.sections.filter { ($0.look.laser ?? .off) != .off }.count
            var problems: [String] = []
            if Double(full) / Double(n) > 0.55 { problems.append("\(full)/\(n) sections at full — no build or contrast") }
            if Double(strobes) / Double(n) > 0.4 { problems.append("strobe in \(strobes) sections") }
            if hits > 4 { problems.append("\(hits) effect hits (save them for the big moments)") }
            if Double(lasers) / Double(n) > 0.7 { problems.append("lasers almost the whole song") }
            if !problems.isEmpty {
                out.append(.init(id: "dyn-\(s.id.uuidString)", severity: .warning, area: "Design", title: "\(s.name): looks flat / overblown",
                                 detail: problems.joined(separator: "; "), fix: .dynamics))
            }
        }

        // ── Stage
        if !show.stagePlot.items.contains(where: { $0.kind == .person }) {
            out.append(.init(id: "no-performers", severity: .info, area: "Stage", title: "No performers on the stage plot",
                             detail: "Lay out the artist, hype, DJ and band so movers can follow and the rider is right.", fix: .layoutStage))
        }
        if !show.effects.devices.isEmpty && show.effects.devices.allSatisfy({ $0.stageX == nil }) {
            out.append(.init(id: "sfx-unplaced", severity: .info, area: "Effects", title: "Effects units aren't placed on stage",
                             detail: "Place them so chases run left-to-right and the map is accurate.", fix: .placeEffects))
        }

        // ── Screens
        if !show.screens.isEmpty && show.screens.allSatisfy({ $0.displayID == nil }) {
            out.append(.init(id: "screens-unassigned", severity: .warning, area: "Screens", title: "No screen is assigned to a real display",
                             detail: "Plug in the LED processor / projector and pick it under Screens → Outputs.", fix: nil))
        }

        // ── Running order
        if let last = show.cues.last, last.continueMode != .none {
            out.append(.init(id: "chain-end", severity: .warning, area: "Cues", title: "The last cue continues into nothing",
                             detail: "\(last.number) \(last.name) is set to continue — set it to stop.", fix: .endChain))
        }
        let setSeconds = show.cues.compactMap { c -> Double? in
            guard c.kind == .audio, let id = c.lightShowID else { return nil }
            return show.lightShows.first { $0.id == id }?.analysis.duration
        }.reduce(0, +)
        if let limit = minutes(show.venue.setLength), setSeconds > 0, setSeconds / 60 > limit + 1 {
            out.append(.init(id: "set-long", severity: .warning, area: "Cues",
                             title: "Set runs \(Int(setSeconds / 60)) min — slot is \(Int(limit)) min",
                             detail: "Cut or shorten songs, or confirm the longer slot with the promoter.", fix: nil))
        }
        return out.sorted { $0.severity > $1.severity }
    }

    private static func minutes(_ s: String) -> Double? {
        let digits = s.split(whereSeparator: { !$0.isNumber && $0 != "." }).compactMap { Double($0) }
        guard let v = digits.first else { return nil }
        return s.lowercased().contains("h") && v < 6 ? v * 60 : v
    }

    /// Applies one fix. Returns a short description of what changed.
    @discardableResult
    static func apply(_ fix: AuditIssue.Fix, issueID: String = "", store: ShowStore, lighting: LightingEngine,
                      builder: LightSetBuilder) -> String {
        switch fix {
        case .repatch:
            var next: [Int: Int] = [:]
            var fixtures = store.show.lighting.fixtures
            let order = fixtures.indices.sorted { (fixtures[$0].universe, fixtures[$0].address) < (fixtures[$1].universe, fixtures[$1].address) }
            for i in order {
                var u = fixtures[i].universe
                let size = fixtures[i].profile.channels.count
                var a = next[u] ?? 1
                if a + size - 1 > 512 { u += 1; a = next[u] ?? 1 }
                fixtures[i].universe = u
                fixtures[i].address = a
                next[u] = a + size
            }
            store.show.lighting.fixtures = fixtures
            lighting.syncPatch()
            return "Re-patched \(fixtures.count) fixtures with no overlaps"
        case .analyseMissing:
            builder.buildFromCueList()
            return "Analysing songs without a light show"
        case .reanalyseOld:
            builder.reanalyseAllOld()
            return "Re-analysing older songs with the deep analyser"
        case .dynamics:
            var n = 0
            for i in store.show.lightShows.indices {
                if issueID.hasPrefix("dyn-") && issueID != "dyn-\(store.show.lightShows[i].id.uuidString)" { continue }
                store.show.lightShows[i] = CreativePolish.dynamics(store.show.lightShows[i]); n += 1
            }
            return "Added contrast and builds to \(n) song\(n == 1 ? "" : "s")"
        case .layoutStage:
            var l = store.show.lineup ?? Lineup()
            if store.show.lineup == nil { l.artistName = store.show.venue.artist }
            store.show.stagePlot = StageSetBuilder.layout(store.show.stagePlot, lineup: l).plot
            store.show.lineup = l
            return "Laid out \(l.headcount) performers"
        case .buildRig:
            var o = RigDesigner.Options()
            let w = store.show.stagePlot.stageWidth
            o.size = w < 10 ? .small : (w < 16 ? .medium : .large)
            store.show.lighting.fixtures = RigDesigner.design(plot: store.show.stagePlot, options: o).fixtures
            lighting.syncPatch()
            return "Built a \(o.size.label) rig of \(store.show.lighting.fixtures.count) fixtures"
        case .endChain:
            if !store.show.cues.isEmpty { store.show.cues[store.show.cues.count - 1].continueMode = .none }
            return "Last cue now stops"
        case .placeEffects:
            store.show.effects.devices = RigDesigner.placeEffects(store.show.effects.devices, plot: store.show.stagePlot)
            return "Placed \(store.show.effects.devices.count) effects units"
        }
    }
}

/// Creative Director's rules of taste, usable without AI: contrast, builds, and saving the big moments.
enum CreativePolish {
    static func dynamics(_ show: LightShow) -> LightShow {
        var s = show
        guard !s.sections.isEmpty else { return s }
        let energies = s.sections.map(\.energy)
        let lo = energies.min() ?? 0, hi = max((energies.max() ?? 1), lo + 0.01)
        let peakIndex = s.sections.indices.max { s.sections[$0].energy < s.sections[$1].energy } ?? 0
        var hits = 0
        let n = s.sections.count
        for i in s.sections.indices {
            let sec = s.sections[i]
            let e = (sec.energy - lo) / (hi - lo)                      // 0 quietest … 1 biggest moment
            let label = sec.label.lowercased()
            let big = label.contains("drop") || label.contains("chorus") || label.contains("hook")
            let calm = label.contains("intro") || label.contains("verse") || label.contains("bridge")
                || label.contains("breakdown") || label.contains("outro")
            var look = sec.look
            var target = 0.4 + 0.6 * e
            if calm { target = min(target, 0.7) }
            if label.contains("breakdown") || label.contains("bridge") { target = min(target, 0.5) }
            if label.contains("outro") { target = min(target, 0.55) }
            look.intensity = (target * 100).rounded() / 100
            look.haze = ((0.25 + 0.45 * e) * 100).rounded() / 100
            look.strobeBeats = (big && e > 0.8) ? max(look.strobeBeats, 2) : 0
            // Lasers only where the song lifts.
            if e < 0.5 || calm { look.laser = .off } else if (look.laser ?? .off) == .off && e > 0.75 { look.laser = label.contains("drop") ? .tunnel : .fan }
            // Effects: the biggest moment, drops, and the last chorus — max 3.
            let lastChorus = label.contains("chorus") && !s.sections[(i + 1)...].contains { $0.label.lowercased().contains("chorus") }
            let wantsHit = (i == peakIndex || label.contains("drop") || lastChorus) && e > 0.7
            if wantsHit && hits < 3 {
                look.sfxHit = look.sfxHit ?? (label.contains("drop") ? .co2 : .coldSpark)
                look.sfxEveryBars = label.contains("drop") ? 8 : nil
                hits += 1
            } else {
                look.sfxHit = nil; look.sfxEveryBars = nil
            }
            // Build into big sections.
            if i + 1 < n, ["drop", "chorus"].contains(where: { s.sections[i + 1].label.lowercased().contains($0) }),
               s.sections[i + 1].energy > sec.energy + 0.1 {
                look.buildUp = true
            }
            s.sections[i].look = look
        }
        return s
    }
}
