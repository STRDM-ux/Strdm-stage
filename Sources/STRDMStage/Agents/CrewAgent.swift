import Foundation
import SwiftUI

/// AI crew: a Production Manager and a Creative Director that read and change the show through tools.
/// They never arm or fire special effects, and every run can be undone in one click.
@MainActor
final class CrewAgent: ObservableObject {
    enum Role: String, CaseIterable, Identifiable {
        case creative, production
        var id: String { rawValue }
        var title: String { self == .creative ? "Creative Director" : "Production Manager" }
        var symbol: String { self == .creative ? "paintpalette.fill" : "clipboard.fill" }
    }
    struct Entry: Identifiable, Hashable {
        enum Kind { case user, agent, action, error }
        let id = UUID()
        let role: Role
        let kind: Kind
        let text: String
    }

    @Published var entries: [Entry] = []
    @Published var running: Role? = nil
    @Published var canUndo = false
    @Published var issues: [AuditIssue] = []

    private let store: ShowStore
    private let lighting: LightingEngine
    private let builder: LightSetBuilder
    private let screens: ScreenManager
    private var history: [Role: [[String: Any]]] = [:]
    private var snapshot: Show?
    private var task: Task<Void, Never>?

    init(store: ShowStore, lighting: LightingEngine, builder: LightSetBuilder, screens: ScreenManager) {
        self.store = store; self.lighting = lighting; self.builder = builder; self.screens = screens
    }

    // MARK: Offline (no AI needed)

    func runAudit() { issues = ProductionAudit.run(store: store, lighting: lighting, screens: screens) }

    func fix(_ issue: AuditIssue) {
        guard let f = issue.fix else { return }
        takeSnapshot()
        let msg = ProductionAudit.apply(f, issueID: issue.id, store: store, lighting: lighting, builder: builder)
        entries.append(Entry(role: .production, kind: .action, text: msg))
        runAudit()
    }

    func fixAll() {
        takeSnapshot()
        var done = Set<AuditIssue.Fix>()
        for i in issues {
            guard let f = i.fix, !done.contains(f) else { continue }
            let msg = ProductionAudit.apply(f, issueID: f == .dynamics ? "" : i.id, store: store, lighting: lighting, builder: builder)
            entries.append(Entry(role: .production, kind: .action, text: msg))
            done.insert(f)
        }
        runAudit()
    }

    func undo() {
        guard let s = snapshot else { return }
        store.show = s
        lighting.syncPatch()
        snapshot = nil
        canUndo = false
        entries.append(Entry(role: .production, kind: .action, text: "Undid the crew's changes"))
        runAudit()
    }

    private func takeSnapshot() {
        if snapshot == nil { snapshot = store.show }
        canUndo = true
    }

    // MARK: AI

    func stop() { task?.cancel(); task = nil; running = nil }

    func clear(_ role: Role) {
        history[role] = []
        entries.removeAll { $0.role == role }
    }

    func ask(_ role: Role, _ text: String) {
        guard running == nil, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        takeSnapshot()
        entries.append(Entry(role: role, kind: .user, text: text))
        task = Task { await self.loop(role, text) }
    }

    /// Creative Director designs, then the Production Manager checks and fixes.
    func autopilot(brief: String) {
        guard running == nil else { return }
        takeSnapshot()
        let cd = "Design the whole show. " + (brief.isEmpty ? "" : "Brief: \(brief). ") +
            "Give every song a clear identity, real contrast (quiet verses, big choruses/drops), save effects and lasers for the biggest moments, and make the night flow as one arc."
        let pm = "Audit the show and fix everything you safely can (patch, cue chain, missing light shows, stage layout). Then give me a short show-readiness report with anything I must do by hand."
        entries.append(Entry(role: .creative, kind: .user, text: cd))
        task = Task {
            await self.loop(.creative, cd)
            guard !Task.isCancelled else { return }
            self.entries.append(Entry(role: .production, kind: .user, text: pm))
            await self.loop(.production, pm)
        }
    }

    private func loop(_ role: Role, _ text: String) async {
        running = role
        defer { running = nil; runAudit() }
        var msgs = history[role] ?? []
        msgs.append(["role": "user", "content": text])
        for _ in 0..<14 {
            if Task.isCancelled { return }
            let resp: [String: Any]
            do {
                resp = try await ClaudeClient.send(system: Self.system(role, store: store), messages: msgs, tools: CrewTools.schemas(for: role))
            } catch {
                entries.append(Entry(role: role, kind: .error, text: error.localizedDescription))
                history[role] = Array(msgs.dropLast())
                return
            }
            let content = resp["content"] as? [[String: Any]] ?? []
            msgs.append(["role": "assistant", "content": content])
            var results: [[String: Any]] = []
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if let t = block["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        entries.append(Entry(role: role, kind: .agent, text: t))
                    }
                case "tool_use":
                    let name = block["name"] as? String ?? ""
                    let input = block["input"] as? [String: Any] ?? [:]
                    let out = CrewTools.run(name, input, store: store, lighting: lighting, builder: builder, screens: screens)
                    if out.summary != nil { entries.append(Entry(role: role, kind: .action, text: out.summary!)) }
                    results.append(["type": "tool_result", "tool_use_id": block["id"] as? String ?? "", "content": out.result])
                default: break
                }
            }
            if results.isEmpty { history[role] = msgs; return }
            msgs.append(["role": "user", "content": results])
        }
        history[role] = msgs
        entries.append(Entry(role: role, kind: .error, text: "Stopped after 14 steps — ask me to continue."))
    }

    private static func system(_ role: Role, store: ShowStore) -> String {
        let common = """
        You work inside STRDM Stage, a macOS live-show control app used on tour by dancehall artist Armanii's team. \
        You change the show only through the tools. Be decisive: make the changes, don't ask permission for design choices. \
        Keep replies short (a few lines), plain language, no markdown headers. Never arm or fire special effects — the crew does that.
        Options — vibes: \(Vibe.allCases.map(\.rawValue).joined(separator: ", ")). \
        Palettes: \(Palette.library.map(\.name).joined(separator: " | ")). \
        Chases: \(ChaseKind.allCases.map(\.rawValue).joined(separator: ", ")). \
        Mover moves: \(MoverMode.allCases.map(\.rawValue).joined(separator: ", ")). \
        Lasers: \(LaserLook.allCases.map(\.rawValue).joined(separator: ", ")). \
        Screen visuals: \(VisualStyle.allCases.map(\.rawValue).joined(separator: ", ")). \
        Effects: \(SFXKind.allCases.map(\.rawValue).joined(separator: ", ")), or none. \
        Accents: \(AccentKind.allCases.map(\.rawValue).joined(separator: ", ")). \
        Stage templates: \(StageTemplates.all.map(\.name).joined(separator: " | ")).
        Stage item kinds: \(StageItemKind.allCases.map(\.rawValue).joined(separator: ", ")).
        """
        switch role {
        case .creative:
            return common + """

            You are the show's Creative Director (arena lighting designer + set designer). Start by reading the show summary and the songs. \
            Principles: every song has its own colour identity that fits its mood; the set has an arc (open strong, breathe in the middle, biggest finish); \
            contrast beats brightness — verses 40–65% intensity with slower, tighter looks, choruses/drops 85–100% with wider movement; \
            white and strobes only as accents; lasers and effects only on the biggest moments (max ~3 effect hits per song); \
            build tension into drops; vary screen visuals between songs; keep the artist lit (movers followLead on vocal-heavy sections). \
            You fully control the stage design and stage size (get_stage, set_stage_size, stage_items, layout_stage, build_rig). \
            Design it like a real production designer: read get_stage first; size the stage to the venue and lineup; \
            artist downstage centre with clear space around them (≥2 m), hype either side, dancers with room to move (≥1.5 m each), \
            band on risers upstage spread across the stage (≥0.5 m between backline pods), DJ on a riser centre or offset, \
            LED walls behind the band, PA and side fills offstage, keep walkways and stairs to risers clear, nothing overlapping. \
            Use labels to name every item. After designing, check the overlaps list and fix them, then rebuild the rig (build_rig rehang or new). \
            For a dancehall set, warm/hot palettes for party tunes, deep blues/purples for dark or slow ones, Yaad green & gold for big Jamaican moments.
            """
        case .production:
            return common + """

            You are the Production Manager. You make sure the show runs safely and on time: DMX patch, cue chain, media, songs analysed, \
            stage layout and lineup, rig, screens, set length vs slot, safety (lasers above the audience, effects only when armed by a licensed operator). \
            Run audit_show first, fix what can be fixed with fix_issues or other tools, then report what still needs a human (cables, displays, permits).
            """
        }
    }
}

// MARK: - Tools

enum CrewTools {
    struct Output { let result: String; let summary: String? }

    static func schemas(for role: CrewAgent.Role) -> [[String: Any]] {
        func t(_ name: String, _ desc: String, _ props: [String: Any] = [:], required: [String] = []) -> [String: Any] {
            ["name": name, "description": desc, "input_schema": ["type": "object", "properties": props, "required": required]]
        }
        let str: [String: Any] = ["type": "string"]
        let num: [String: Any] = ["type": "number"]
        let int: [String: Any] = ["type": "integer"]
        let bool: [String: Any] = ["type": "boolean"]
        let song: [String: Any] = ["type": "string", "description": "Song number (1-based, from get_show_summary) or part of its name, or \"all\""]
        let changes: [String: Any] = ["type": "object", "description": "Only the fields to change", "properties": [
            "colorA": ["type": "string", "description": "main colour #RRGGBB"], "colorB": ["type": "string", "description": "second colour #RRGGBB"],
            "colorC": ["type": "string", "description": "accent colour #RRGGBB"], "intensity": ["type": "number", "description": "0–1"],
            "chase": str, "variations": ["type": "array", "items": str, "description": "chases to rotate per phrase"],
            "mover": str, "beats_per_step": num, "strobe_beats": ["type": "number", "description": "strobe burst length at section start, 0 = none"],
            "haze": ["type": "number", "description": "0–1"], "laser": str, "sfx_hit": ["type": "string", "description": "effect at section start, or none"],
            "sfx_every_bars": int, "visual": str, "accent": str, "build_up": bool, "fills": bool]]
        var tools: [[String: Any]] = [
            t("get_show_summary", "Overview: artist, venue, stage, lineup, rig, effects, screens, cue list and every song with its style."),
            t("get_song", "One song's sections (time, energy, vocal amount, repeat group) with their full looks.", ["song": song], required: ["song"]),
            t("audit_show", "Production checklist: returns issues with ids, severity and whether they can be fixed automatically."),
            t("fix_issues", "Apply automatic fixes from audit_show.", ["ids": ["type": "array", "items": str, "description": "issue ids, or [\"all\"]"]], required: ["ids"]),
            t("set_song_style", "Re-style a whole song from a vibe and/or palette (regenerates every section look).",
              ["song": song, "vibe": str, "palette": str], required: ["song"]),
            t("edit_sections", "Change looks of chosen sections in a song. Pick sections by index list and/or label text (e.g. \"chorus\").",
              ["song": song, "sections": ["type": "array", "items": int, "description": "0-based section indexes"],
               "label_contains": str, "changes": changes], required: ["song", "changes"]),
            t("polish_dynamics", "Rule-based pass: contrast, builds into drops, lasers/effects only on big moments.", ["song": song], required: ["song"]),
            t("layout_stage", "Lay out performers and backline on the stage design (optionally apply a stage template first).",
              ["artist": str, "lead_vocals": int, "hype": int, "dancers": int, "dj": bool, "playback": bool, "drums": bool, "bass": bool,
               "guitars": int, "keys": int, "percussion": bool, "horns": int, "backing_vocals": int, "wedges": bool,
               "template": ["type": "string", "description": "stage template name, or omit to keep the design"],
               "input_list": ["type": "boolean", "description": "also write the input list (default true)"]]),
            t("get_stage", "The stage design: size, deck height and every item with its position (metres). x runs 0→width across the stage as drawn (DSL on the left), y is depth from the downstage edge (0 = front edge by the audience, negative = in front of the stage, e.g. catwalk / B-stage). Also lists overlaps."),
            t("set_stage_size", "Set the stage size. Items stay where they are (move them afterwards if needed).",
              ["width": num, "depth": num, "deck_height": ["type": "number", "description": "deck height above the venue floor, metres"]]),
            t("stage_items", "Full control of the stage design: remove, add and move items. Done in that order. Returns overlaps afterwards.",
              ["remove": ["type": "array", "items": str, "description": "item labels, or groups: \"performers\" (people + mics + wedges + backline), \"structure\" (trusses, risers, screens, set pieces), \"all\""],
               "add": ["type": "array", "items": ["type": "object", "properties": [
                    "kind": str, "label": str, "x": num, "y": num, "width": num, "depth": num, "height": num,
                    "elevation": ["type": "number", "description": "lift above the deck, e.g. 0.4 for something standing on a 40 cm riser"],
                    "rotation": num], "required": ["kind", "x", "y"]]],
               "move": ["type": "array", "items": ["type": "object", "properties": [
                    "label": str, "x": num, "y": num, "width": num, "depth": num, "height": num, "elevation": num, "rotation": num],
                    "required": ["label"]]]]),
            t("build_rig", "Design a new lighting rig for the stage, or re-hang the existing fixtures to fit it.",
              ["mode": ["type": "string", "enum": ["new", "rehang"]], "size": ["type": "string", "enum": ["small", "medium", "large"]]], required: ["mode"])
        ]
        if role == .production {
            tools.append(t("set_cue", "Change a cue by its number.", ["number": str, "name": str, "pre_wait": num,
                "continue_mode": ["type": "string", "enum": ["none", "autoContinue", "autoFollow"]]], required: ["number"]))
            tools.append(t("set_venue_info", "Update the venue advance sheet.", ["fields": ["type": "object", "description":
                "any of: venueName, city, tourName, loadIn, soundcheck, doors, setTime, setLength, capacity, stageDimensions, power, paSystem, lightingDesk, videoNotes, productionContact, promoterContact, hospitality, notes"]],
                required: ["fields"]))
        }
        return tools
    }

    // MARK: Run

    @MainActor
    static func run(_ name: String, _ input: [String: Any], store: ShowStore, lighting: LightingEngine,
                    builder: LightSetBuilder, screens: ScreenManager) -> Output {
        switch name {
        case "get_show_summary": return Output(result: summary(store, lighting), summary: nil)
        case "get_song":
            guard let i = songIndexes(input["song"], store).first else { return notFound }
            return Output(result: songDetail(store.show.lightShows[i]), summary: nil)
        case "audit_show":
            let issues = ProductionAudit.run(store: store, lighting: lighting, screens: screens)
            let lines = issues.map { "[\($0.id)] \($0.severity.label) · \($0.area): \($0.title) — \($0.detail)\($0.fix == nil ? " (manual)" : " (auto-fixable)")" }
            return Output(result: lines.isEmpty ? "No issues found." : lines.joined(separator: "\n"), summary: "Ran the production checklist (\(issues.count) items)")
        case "fix_issues":
            let ids = input["ids"] as? [String] ?? []
            let issues = ProductionAudit.run(store: store, lighting: lighting, screens: screens)
            var done: [String] = []
            var fixedKinds = Set<AuditIssue.Fix>()
            for i in issues where ids.contains("all") || ids.contains(i.id) {
                guard let f = i.fix else { continue }
                if f != .dynamics && fixedKinds.contains(f) { continue }
                done.append(ProductionAudit.apply(f, issueID: i.id, store: store, lighting: lighting, builder: builder))
                fixedKinds.insert(f)
            }
            return Output(result: done.isEmpty ? "Nothing auto-fixable matched." : done.joined(separator: "\n"),
                          summary: done.isEmpty ? nil : done.joined(separator: " · "))
        case "set_song_style":
            let idx = songIndexes(input["song"], store)
            guard !idx.isEmpty else { return notFound }
            let vibe = (input["vibe"] as? String).flatMap { Vibe(rawValue: $0) }
            let palette = (input["palette"] as? String).flatMap { p in Palette.library.first { $0.name.lowercased() == p.lowercased() }?.name }
            for i in idx {
                var s = store.show.lightShows[i]
                if let vibe { s.vibe = vibe }
                if let palette { s.paletteName = palette }
                s.sections = LookGenerator.looks(for: s.sections, vibe: s.vibe, palette: Palette.named(s.paletteName),
                                                 hasDrums: (s.analysis.kicks?.count ?? 0) > 30)
                store.show.lightShows[i] = s
            }
            let names = idx.map { store.show.lightShows[$0].name }.joined(separator: ", ")
            return Output(result: "Restyled: \(names)", summary: "Restyled \(names) → \(vibe?.label ?? "same vibe"), \(palette ?? "same colours")")
        case "edit_sections":
            let idx = songIndexes(input["song"], store)
            guard !idx.isEmpty else { return notFound }
            let changes = input["changes"] as? [String: Any] ?? [:]
            let wanted = input["sections"] as? [Int]
            let label = (input["label_contains"] as? String)?.lowercased()
            var count = 0
            for i in idx {
                for j in store.show.lightShows[i].sections.indices {
                    let sec = store.show.lightShows[i].sections[j]
                    if let wanted, !wanted.contains(j) { continue }
                    if let label, !label.isEmpty, !sec.label.lowercased().contains(label) { continue }
                    store.show.lightShows[i].sections[j].look = apply(changes, to: sec.look)
                    count += 1
                }
            }
            let what = changes.keys.sorted().joined(separator: ", ")
            let song = idx.count == 1 ? store.show.lightShows[idx[0]].name : "\(idx.count) songs"
            return Output(result: "Changed \(count) sections (\(what)).",
                          summary: count == 0 ? nil : "\(song): \(count) section\(count == 1 ? "" : "s") — \(what)")
        case "polish_dynamics":
            let idx = songIndexes(input["song"], store)
            for i in idx { store.show.lightShows[i] = CreativePolish.dynamics(store.show.lightShows[i]) }
            return Output(result: "Polished \(idx.count) songs.", summary: "Added contrast & builds to \(idx.count) song\(idx.count == 1 ? "" : "s")")
        case "layout_stage":
            var l = store.show.lineup ?? Lineup()
            if let v = input["artist"] as? String { l.artistName = v }
            if let v = input["lead_vocals"] as? Int { l.leadVocals = v }
            if let v = input["hype"] as? Int { l.hypeVocals = v }
            if let v = input["dancers"] as? Int { l.dancers = v }
            if let v = input["dj"] as? Bool { l.dj = v }
            if let v = input["playback"] as? Bool { l.playback = v }
            if let v = input["drums"] as? Bool { l.drums = v }
            if let v = input["bass"] as? Bool { l.bass = v }
            if let v = input["guitars"] as? Int { l.guitars = v }
            if let v = input["keys"] as? Int { l.keys = v }
            if let v = input["percussion"] as? Bool { l.percussion = v }
            if let v = input["horns"] as? Int { l.horns = v }
            if let v = input["backing_vocals"] as? Int { l.backingVocals = v }
            if let v = input["wedges"] as? Bool { l.wedges = v }
            var plot = store.show.stagePlot
            if let name = input["template"] as? String, let t = StageTemplates.all.first(where: { $0.name.lowercased() == name.lowercased() }) {
                plot = StageTemplate(name: t.name, width: plot.stageWidth, depth: plot.stageDepth, build: t.build).apply(plot)
            }
            let r = StageSetBuilder.layout(plot, lineup: l)
            store.show.stagePlot = r.plot
            store.show.lineup = l
            if input["input_list"] as? Bool ?? true { store.show.inputList = StageSetBuilder.inputList(for: l) }
            return Output(result: "Placed \(l.headcount) people, \(r.placed) items. \(r.notes.joined(separator: " "))",
                          summary: "Laid out the stage: \(l.headcount) on stage")
        case "build_rig":
            let plot = store.show.stagePlot
            if (input["mode"] as? String) == "rehang" {
                store.show.lighting.fixtures = RigDesigner.replace(store.show.lighting.fixtures, plot: plot, trim: 6, role: lighting.role)
            } else {
                var o = RigDesigner.Options()
                o.size = RigDesigner.Size(rawValue: input["size"] as? String ?? "") ??
                    (plot.stageWidth < 10 ? .small : (plot.stageWidth < 16 ? .medium : .large))
                store.show.lighting.fixtures = RigDesigner.design(plot: plot, options: o).fixtures
            }
            if !store.show.effects.devices.isEmpty {
                store.show.effects.devices = RigDesigner.placeEffects(store.show.effects.devices, plot: plot)
            }
            lighting.syncPatch()
            return Output(result: "Rig now \(store.show.lighting.fixtures.count) fixtures.", summary: "Rig: \(store.show.lighting.fixtures.count) fixtures")
        case "get_stage":
            return Output(result: stageDetail(store.show.stagePlot), summary: nil)
        case "set_stage_size":
            func n(_ k: String) -> Double? { (input[k] as? Double) ?? (input[k] as? Int).map(Double.init) }
            if let w = n("width") { store.show.stagePlot.stageWidth = max(2, min(200, w)) }
            if let d = n("depth") { store.show.stagePlot.stageDepth = max(2, min(100, d)) }
            if let h = n("deck_height") { store.show.stagePlot.deckHeight = max(0, min(5, h)) }
            let p = store.show.stagePlot
            return Output(result: "Stage is now \(p.stageWidth) × \(p.stageDepth) m, deck \(p.deck) m.",
                          summary: "Stage size \(fmt(p.stageWidth)) × \(fmt(p.stageDepth)) m, deck \(fmt(p.deck)) m")
        case "stage_items":
            var p = store.show.stagePlot
            var log: [String] = []
            for r in input["remove"] as? [String] ?? [] {
                let before = p.items.count
                switch r.lowercased() {
                case "all": p.items.removeAll()
                case "performers": p.items.removeAll { StageItemKind.band.contains($0.kind) }
                case "structure": p.items.removeAll { $0.kind.isStructure }
                default: p.items.removeAll { $0.label.lowercased() == r.lowercased() }
                }
                if p.items.count != before { log.append("removed \(before - p.items.count) (\(r))") }
            }
            func d(_ o: [String: Any], _ k: String) -> Double? { (o[k] as? Double) ?? (o[k] as? Int).map(Double.init) }
            var added = 0
            for a in input["add"] as? [[String: Any]] ?? [] {
                guard let ks = a["kind"] as? String, let kind = StageItemKind(rawValue: ks), let x = d(a, "x"), let y = d(a, "y") else {
                    log.append("skipped an item with unknown kind \(a["kind"] ?? "?")"); continue
                }
                var it = StageItem(kind: kind, label: a["label"] as? String ?? kind.label, x: x, y: y,
                                   width: d(a, "width") ?? kind.defaultSize.width, depth: d(a, "depth") ?? kind.defaultSize.height)
                it.height = d(a, "height")
                it.elevation = d(a, "elevation")
                it.rotation = d(a, "rotation") ?? 0
                p.items.append(it); added += 1
            }
            if added > 0 { log.append("added \(added)") }
            var moved = 0, missing: [String] = []
            for m in input["move"] as? [[String: Any]] ?? [] {
                guard let label = m["label"] as? String,
                      let i = p.items.firstIndex(where: { $0.label.lowercased() == label.lowercased() }) else { missing.append(m["label"] as? String ?? "?"); continue }
                if let v = d(m, "x") { p.items[i].x = v }
                if let v = d(m, "y") { p.items[i].y = v }
                if let v = d(m, "width") { p.items[i].width = v }
                if let v = d(m, "depth") { p.items[i].depth = v }
                if let v = d(m, "height") { p.items[i].height = v }
                if let v = d(m, "elevation") { p.items[i].elevation = v }
                if let v = d(m, "rotation") { p.items[i].rotation = v }
                moved += 1
            }
            if moved > 0 { log.append("moved \(moved)") }
            if !missing.isEmpty { log.append("not found: \(missing.joined(separator: ", "))") }
            store.show.stagePlot = p
            let o = overlaps(p)
            return Output(result: log.joined(separator: "; ") + (o.isEmpty ? ". No overlaps." : ". Overlaps: " + o.joined(separator: "; ")),
                          summary: "Stage design: " + log.joined(separator: ", "))
        case "set_cue":
            guard let n = input["number"] as? String, let i = store.show.cues.firstIndex(where: { $0.number == n }) else { return notFound }
            if let v = input["name"] as? String { store.show.cues[i].name = v }
            if let v = input["pre_wait"] as? Double { store.show.cues[i].preWait = v }
            if let v = (input["continue_mode"] as? String).flatMap({ ContinueMode(rawValue: $0) }) { store.show.cues[i].continueMode = v }
            return Output(result: "Cue \(n) updated.", summary: "Cue \(n) updated")
        case "set_venue_info":
            let f = input["fields"] as? [String: Any] ?? [:]
            var v = store.show.venue
            let map: [String: WritableKeyPath<VenueInfo, String>] = [
                "venueName": \.venueName, "city": \.city, "tourName": \.tourName, "loadIn": \.loadIn, "soundcheck": \.soundcheck,
                "doors": \.doors, "setTime": \.setTime, "setLength": \.setLength, "capacity": \.capacity,
                "stageDimensions": \.stageDimensions, "power": \.power, "paSystem": \.paSystem, "lightingDesk": \.lightingDesk,
                "videoNotes": \.videoNotes, "productionContact": \.productionContact, "promoterContact": \.promoterContact,
                "hospitality": \.hospitality, "notes": \.notes]
            var changed: [String] = []
            for (k, val) in f { if let kp = map[k], let s = val as? String { v[keyPath: kp] = s; changed.append(k) } }
            store.show.venue = v
            return Output(result: "Updated \(changed.joined(separator: ", ")).", summary: changed.isEmpty ? nil : "Advance: \(changed.joined(separator: ", "))")
        default:
            return Output(result: "Unknown tool \(name).", summary: nil)
        }
    }

    private static let notFound = Output(result: "Not found — check get_show_summary for numbers and names.", summary: nil)

    @MainActor
    private static func songIndexes(_ v: Any?, _ store: ShowStore) -> [Int] {
        let shows = store.show.lightShows
        if let n = v as? Int, shows.indices.contains(n - 1) { return [n - 1] }
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return [] }
        if s.lowercased() == "all" { return Array(shows.indices) }
        if let n = Int(s), shows.indices.contains(n - 1) { return [n - 1] }
        return shows.indices.filter { shows[$0].name.lowercased().contains(s.lowercased()) }.prefix(1).map { $0 }
    }

    private static func apply(_ c: [String: Any], to l: SectionLook) -> SectionLook {
        var l = l
        func num(_ k: String) -> Double? { (c[k] as? Double) ?? (c[k] as? Int).map(Double.init) }
        if let v = (c["colorA"] as? String).flatMap(RGB.init(hexString:)) { l.colorA = v }
        if let v = (c["colorB"] as? String).flatMap(RGB.init(hexString:)) { l.colorB = v }
        if let v = (c["colorC"] as? String).flatMap(RGB.init(hexString:)) { l.colorC = v }
        if let v = num("intensity") { l.intensity = max(0, min(1, v)) }
        if let v = (c["chase"] as? String).flatMap(ChaseKind.init(rawValue:)) {
            l.chase = v
            if var vars = l.variations { vars.removeAll { $0 == v }; vars.insert(v, at: 0); l.variations = vars }
        }
        if let v = c["variations"] as? [String] { let k = v.compactMap(ChaseKind.init(rawValue:)); if !k.isEmpty { l.variations = k } }
        if let v = (c["mover"] as? String).flatMap(MoverMode.init(rawValue:)) {
            l.mover = v
            if var vars = l.moverVariations { vars.removeAll { $0 == v }; vars.insert(v, at: 0); l.moverVariations = vars }
        }
        if let v = num("beats_per_step") { l.beatsPerStep = max(0.25, v) }
        if let v = num("strobe_beats") { l.strobeBeats = max(0, v) }
        if let v = num("haze") { l.haze = max(0, min(1, v)) }
        if let v = (c["laser"] as? String).flatMap(LaserLook.init(rawValue:)) { l.laser = v == .off ? nil : v }
        if let s = c["sfx_hit"] as? String { l.sfxHit = SFXKind(rawValue: s); if l.sfxHit == nil { l.sfxEveryBars = nil } }
        if let v = c["sfx_every_bars"] as? Int { l.sfxEveryBars = v > 0 ? v : nil }
        if let v = (c["visual"] as? String).flatMap(VisualStyle.init(rawValue:)) { l.visual = v }
        if let v = (c["accent"] as? String).flatMap(AccentKind.init(rawValue:)) { l.accent = v }
        if let v = c["build_up"] as? Bool { l.buildUp = v }
        if let v = c["fills"] as? Bool { l.fills = v }
        return l
    }

    // MARK: Read-outs

    private static func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }

    /// Items whose footprints collide on the same level (ignores things standing on risers / decks and rigging overhead).
    static func overlaps(_ p: StagePlot) -> [String] {
        let floor = p.items.filter { !$0.kind.isRigging && !$0.kind.isDeck && $0.kind != .ledFloor && $0.kind != .label }
        var out: [String] = []
        for i in floor.indices {
            for j in floor.indices where j > i {
                let a = floor[i], b = floor[j]
                guard abs((a.elevation ?? 0) - (b.elevation ?? 0)) < 0.2 else { continue }
                let ra = CGRect(x: a.x - a.width / 2, y: a.y - a.depth / 2, width: a.width, height: a.depth).insetBy(dx: 0.05, dy: 0.05)
                let rb = CGRect(x: b.x - b.width / 2, y: b.y - b.depth / 2, width: b.width, height: b.depth).insetBy(dx: 0.05, dy: 0.05)
                if ra.intersects(rb) { out.append("\(a.label) × \(b.label)") }
                if out.count >= 25 { return out }
            }
        }
        return out
    }

    private static func stageDetail(_ p: StagePlot) -> String {
        var o = ["Stage \(fmt(p.stageWidth)) × \(fmt(p.stageDepth)) m, deck height \(fmt(p.deck)) m. Items (label | kind | x, y | w × d | height | elevation | rotation):"]
        for it in p.items {
            o.append("\(it.label) | \(it.kind.rawValue) | \(fmt(it.x)), \(fmt(it.y)) | \(fmt(it.width)) × \(fmt(it.depth)) | h \(fmt(it.topHeight)) | e \(fmt(it.elevation ?? 0)) | r \(fmt(it.rotation))")
        }
        let ov = overlaps(p)
        o.append(ov.isEmpty ? "No overlaps." : "Overlaps: " + ov.joined(separator: "; "))
        return o.joined(separator: "\n")
    }

    @MainActor
    private static func summary(_ store: ShowStore, _ lighting: LightingEngine) -> String {
        let s = store.show
        var o: [String] = []
        o.append("Show: \(s.name) · artist \(s.venue.artist) · venue \(s.venue.venueName) \(s.venue.city) · slot \(s.venue.setLength)")
        o.append("Stage: \(s.stagePlot.stageWidth)×\(s.stagePlot.stageDepth) m, deck \(s.stagePlot.deck) m; structure: " +
                 s.stagePlot.items.filter { $0.kind.isStructure }.map(\.label).joined(separator: ", "))
        if let l = s.lineup {
            o.append("Lineup: artist \(l.artistName), leads \(l.leadVocals), hype \(l.hypeVocals), dancers \(l.dancers), DJ \(l.dj), drums \(l.drums), bass \(l.bass), guitars \(l.guitars), keys \(l.keys), perc \(l.percussion), horns \(l.horns), BGVs \(l.backingVocals)")
        }
        let groups = Dictionary(grouping: s.lighting.fixtures) { "\(lighting.role($0))" }.map { "\($0.value.count) \($0.key)" }
        o.append("Rig: \(s.lighting.fixtures.count) fixtures (\(groups.sorted().joined(separator: ", ")))")
        o.append("Effects units: " + (s.effects.devices.isEmpty ? "none" : Dictionary(grouping: s.effects.devices, by: \.kind).map { "\($0.value.count) \($0.key.rawValue)" }.joined(separator: ", ")))
        o.append("Screens: " + s.screens.map { "\($0.name)\($0.displayID == nil ? " (no display)" : "")" }.joined(separator: ", "))
        o.append("Cues:")
        for c in s.cues {
            let ls = c.lightShowID.flatMap { id in s.lightShows.firstIndex { $0.id == id } }.map { " → song \($0 + 1)" } ?? ""
            o.append("  \(c.number) [\(c.kind.rawValue)] \(c.name) \(c.continueMode == .none ? "" : c.continueMode.rawValue)\(ls)")
        }
        o.append("Songs:")
        for (i, l) in s.lightShows.enumerated() {
            let a = l.analysis
            o.append("  \(i + 1). \(l.name) — \(Int(a.bpm)) BPM, \(a.key), \(Int(a.duration / 60)):\(String(format: "%02d", Int(a.duration) % 60)), vibe \(l.vibe.rawValue), palette \(l.paletteName), \(l.sections.count) sections\(a.structure.map { ", form \($0)" } ?? "")")
        }
        return o.joined(separator: "\n")
    }

    private static func songDetail(_ s: LightShow) -> String {
        var o = ["\(s.name): \(Int(s.analysis.bpm)) BPM, \(s.analysis.key), vibe \(s.vibe.rawValue), palette \(s.paletteName)"]
        for (i, sec) in s.sections.enumerated() {
            let l = sec.look
            o.append("[\(i)] \(sec.label) \(Int(sec.start))–\(Int(sec.end))s energy \(String(format: "%.2f", sec.energy)) vocal \(String(format: "%.2f", sec.vocal ?? 0)) group \(sec.group ?? "-") | " +
                     "A \(l.colorA.hex) B \(l.colorB.hex) C \(l.colorC?.hex ?? "-") int \(String(format: "%.2f", l.intensity)) chase \(l.chase.rawValue) mover \(l.mover.rawValue) " +
                     "strobe \(l.strobeBeats) haze \(String(format: "%.2f", l.haze)) laser \((l.laser ?? .off).rawValue) sfx \(l.sfxHit?.rawValue ?? "none")\(l.sfxEveryBars.map { "/\($0)bars" } ?? "") " +
                     "visual \(l.visual?.rawValue ?? "auto") accent \(l.accent?.rawValue ?? "-") build \(l.buildUp == true)")
        }
        return o.joined(separator: "\n")
    }
}
