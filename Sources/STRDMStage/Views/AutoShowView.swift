import SwiftUI
import AppKit

// MARK: - Full Auto: songs in → whole show out

enum RigPlan: String, CaseIterable, Identifiable {
    case build, rehang, keep
    var id: String { rawValue }
    var label: String {
        switch self {
        case .build: return "Design a new lighting rig for this stage"
        case .rehang: return "Re-hang my existing fixtures to fit"
        case .keep: return "Keep my rig as it is"
        }
    }
}

@MainActor
enum AutoShowDirector {
    struct Plan {
        var songs: [URL] = []
        var lineup = Lineup()
        var template: String? = nil          // nil = keep my stage design
        var layoutStage = true
        var writeInputs = true
        var rig: RigPlan = .build
        var vibe: Vibe? = nil
        var palette: String? = nil
        var bookends = true
        var playThrough = true
        var replaceCues = false
        var city = ""
    }

    // ── Stage + rig (instant)
    static func buildStage(_ plan: Plan, store: ShowStore, lighting: LightingEngine) -> [String] {
        var log: [String] = []
        var plot = store.show.stagePlot
        if let name = plan.template, let t = StageTemplates.all.first(where: { $0.name == name }) {
            // Template structure, sized to my stage.
            plot = StageTemplate(name: t.name, width: plot.stageWidth, depth: plot.stageDepth, build: t.build).apply(plot)
            log.append("Stage design: \(t.name) at \(fmt(plot.stageWidth)) × \(fmt(plot.stageDepth)) m")
        }
        if plan.layoutStage {
            let r = StageSetBuilder.layout(plot, lineup: plan.lineup)
            plot = r.plot
            log.append("Stage set: placed \(plan.lineup.headcount) people and \(r.placed) items")
            log += r.notes
        }
        store.show.stagePlot = plot
        store.show.lineup = plan.lineup
        if plan.writeInputs {
            store.show.inputList = StageSetBuilder.inputList(for: plan.lineup)
            log.append("Input list: \(store.show.inputList.count) channels")
        }
        if plan.lineup.artistName.trimmingCharacters(in: .whitespaces).isEmpty == false {
            store.show.venue.artist = plan.lineup.artistName
        }
        if !plan.city.isEmpty { store.show.venue.city = plan.city }

        let trim = plot.items.filter { $0.kind == .truss }.map(\.topHeight).max() ?? 6
        switch plan.rig {
        case .build:
            var o = RigDesigner.Options()
            o.size = plot.stageWidth < 10 ? .small : (plot.stageWidth < 16 ? .medium : .large)
            o.trimHeight = trim
            let rig = RigDesigner.design(plot: plot, options: o)
            store.show.lighting.fixtures = rig.fixtures
            log.append("Lighting rig: \(rig.fixtures.count) fixtures on \(rig.universes) universe\(rig.universes == 1 ? "" : "s") (\(o.size.label))")
        case .rehang:
            store.show.lighting.fixtures = RigDesigner.replace(store.show.lighting.fixtures, plot: plot, trim: trim, role: lighting.role)
            log.append("Lighting rig: re-hung \(store.show.lighting.fixtures.count) fixtures")
        case .keep:
            log.append("Lighting rig: kept as is")
        }
        if !store.show.effects.devices.isEmpty {
            store.show.effects.devices = RigDesigner.placeEffects(store.show.effects.devices, plot: plot)
            log.append("Special effects: \(store.show.effects.devices.count) units placed")
        }
        lighting.syncPatch()
        return log
    }

    // ── Cues around the analysed songs
    static func buildCues(_ plan: Plan, shows: [LightShow], store: ShowStore, builder: LightSetBuilder) -> [String] {
        var log: [String] = []
        if plan.replaceCues { store.show.cues.removeAll() }
        let fixtures = store.show.lighting.fixtures
        let palette = Palette.named(plan.palette ?? shows.first?.paletteName ?? Palette.library[0].name)
        let artist = plan.lineup.artistName.isEmpty ? store.show.name : plan.lineup.artistName
        if store.show.screens.isEmpty { store.show.screens = [ScreenOutput(name: "LED Wall")] }

        func sceneCue(_ name: String, _ scene: LightScene, fade: Double, cont: ContinueMode = .none) -> Cue {
            store.show.lighting.scenes.removeAll { $0.name == scene.name }
            store.show.lighting.scenes.append(scene)
            var c = Cue(kind: .lights, number: store.nextCueNumber(), name: name)
            c.sceneID = scene.id
            c.lightFade = fade
            c.continueMode = cont
            return c
        }
        func cardCue(_ name: String, _ url: URL?, cont: ContinueMode = .none) -> Cue? {
            guard let url else { return nil }
            var c = Cue(kind: .video, number: store.nextCueNumber(), name: name)
            c.videoPath = url.path
            c.allScreens = true
            c.fitMode = .auto
            c.videoFade = 2
            c.videoSound = false
            c.continueMode = cont
            return c
        }
        func append(_ c: Cue?) { if let c { store.show.cues.append(c) } }

        if plan.bookends {
            append(sceneCue("Walk-in — house look", scene("Auto: Walk-in", fixtures, palette.b, dim: 90, haze: 70), fade: 4, cont: .autoContinue))
            append(cardCue("Walk-in — \(artist) title", TitleCard.make(title: artist, subtitle: store.show.venue.tourName.isEmpty ? "LIVE" : store.show.venue.tourName, palette: palette, file: "walkin")))
            append(sceneCue("Showtime — blackout", scene("Auto: Blackout", fixtures, .black, dim: 0, haze: 0), fade: 1.5, cont: .autoContinue))
            var black = Cue(kind: .videoBlack, number: store.nextCueNumber(), name: "Screens to black")
            black.videoFade = 1.5
            black.continueMode = .autoContinue
            store.show.cues.append(black)
            log.append("Intro: walk-in look + title on all screens, then blackout into the first song")
        }

        var songCueIDs: [UUID] = []
        for (i, show) in shows.enumerated() {
            let before = store.show.cues.count
            builder.addCue(for: show)
            let added = store.show.cues[before...].map(\.id)
            if i == 0, plan.bookends, let first = added.first, let k = store.cueIndex(first) {
                store.show.cues[k].preWait = 2     // a beat of darkness before the first song hits
            }
            songCueIDs += added.filter { id in store.cueIndex(id).map { store.show.cues[$0].kind == .audio } ?? false }
        }
        if plan.playThrough {
            for id in songCueIDs.dropLast() {
                if let k = store.cueIndex(id) { store.show.cues[k].continueMode = .autoFollow }
            }
            if plan.bookends, let last = songCueIDs.last, let k = store.cueIndex(last) { store.show.cues[k].continueMode = .autoFollow }
        }
        log.append("Songs: \(shows.count) cues, each with its own full light / laser / effects / visuals show")

        if plan.bookends {
            let place = plan.city.isEmpty ? store.show.venue.city : plan.city
            append(sceneCue("Outro — thank you look", scene("Auto: Outro", fixtures, palette.a, dim: 160, haze: 40), fade: 3, cont: .autoContinue))
            append(cardCue("Outro — Thank you", TitleCard.make(title: place.isEmpty ? "THANK YOU" : "THANK YOU \(place)", subtitle: artist, palette: palette, file: "outro")))
            var fade = Cue(kind: .fade, number: store.nextCueNumber(), name: "End — fade everything")
            fade.fadeTarget = .everything
            fade.fadeDuration = 5
            fade.continueMode = .autoContinue
            store.show.cues.append(fade)
            append(sceneCue("End — blackout", scene("Auto: End", fixtures, .black, dim: 0, haze: 0), fade: 5))
            log.append("Outro: thank-you look + title, then fade everything to black (fire it when you're ready)")
        }
        return log
    }

    static func scene(_ name: String, _ fixtures: [Fixture], _ c: RGB, dim: Int, haze: Int) -> LightScene {
        var s = LightScene(name: name)
        let r = Int(c.r * 255), g = Int(c.g * 255), b = Int(c.b * 255)
        for f in fixtures {
            s.levels[f.id.uuidString] = f.profile.channels.map { ch in
                switch ch.kind {
                case .intensity: return dim
                case .red: return r
                case .green: return g
                case .blue: return b
                case .haze: return haze
                case .pan, .tilt: return 128
                default: return 0
                }
            }
        }
        return s
    }

    private static func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
}

/// Renders a 1920×1080 title card for the screens (Auto fit adapts it to any screen shape).
enum TitleCard {
    static func make(title: String, subtitle: String, palette: Palette, file: String) -> URL? {
        let size = NSSize(width: 1920, height: 1080)
        let image = NSImage(size: size, flipped: false) { rect in
            let a = NSColor(red: palette.a.r, green: palette.a.g, blue: palette.a.b, alpha: 1)
            let b = NSColor(red: palette.b.r, green: palette.b.g, blue: palette.b.b, alpha: 1)
            NSColor.black.setFill(); rect.fill()
            NSGradient(colors: [b.blended(withFraction: 0.75, of: .black) ?? b, .black, a.blended(withFraction: 0.7, of: .black) ?? a])?
                .draw(in: rect, angle: -30)
            NSGradient(colors: [a.withAlphaComponent(0.45), .clear])?
                .draw(fromCenter: NSPoint(x: rect.midX, y: rect.midY), radius: 0,
                      toCenter: NSPoint(x: rect.midX, y: rect.midY), radius: rect.width * 0.45, options: [])
            let style = NSMutableParagraphStyle(); style.alignment = .center
            let shadow = NSShadow(); shadow.shadowColor = a; shadow.shadowBlurRadius = 40
            var fontSize: CGFloat = 230
            let t = title.uppercased() as NSString
            var attrs: [NSAttributedString.Key: Any] = [:]
            repeat {
                attrs = [.font: NSFont.systemFont(ofSize: fontSize, weight: .black), .foregroundColor: NSColor.white,
                         .paragraphStyle: style, .shadow: shadow, .kern: fontSize * 0.04]
                if t.size(withAttributes: attrs).width < rect.width * 0.86 { break }
                fontSize -= 10
            } while fontSize > 60
            let th = t.size(withAttributes: attrs).height
            t.draw(in: NSRect(x: 0, y: rect.midY - th / 2 + 40, width: rect.width, height: th), withAttributes: attrs)
            let sub = subtitle.uppercased() as NSString
            let sAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 64, weight: .semibold),
                                                         .foregroundColor: b.blended(withFraction: 0.4, of: .white) ?? .white,
                                                         .paragraphStyle: style, .kern: 18]
            sub.draw(in: NSRect(x: 0, y: rect.midY - th / 2 - 70, width: rect.width, height: 90), withAttributes: sAttrs)
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]),
              let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let dir = docs.appendingPathComponent("STRDM Stage Shows/Generated", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = title.replacingOccurrences(of: "/", with: "-").prefix(40)
        let url = dir.appendingPathComponent("\(file) – \(safe).png")
        do { try png.write(to: url); return url } catch { return nil }
    }
}

// MARK: - Lineup editor (shared)

struct LineupEditor: View {
    @Binding var lineup: Lineup

    var body: some View {
        Section("Who's on stage") {
            Menu("Quick lineups") {
                ForEach(Lineup.presets(artist: lineup.artistName)) { p in
                    Button(p.id) { lineup = p.lineup }
                }
            }
            TextField("Artist", text: $lineup.artistName)
            Stepper("Lead vocals: \(lineup.leadVocals)", value: $lineup.leadVocals, in: 1...4)
            Stepper("Hype / host: \(lineup.hypeVocals)", value: $lineup.hypeVocals, in: 0...4)
            Stepper("Dancers: \(lineup.dancers)", value: $lineup.dancers, in: 0...12)
            Toggle("DJ / selector", isOn: $lineup.dj)
            Toggle("Playback rig (tracks, Auto-Tune)", isOn: $lineup.playback)
        }
        Section("Live band") {
            Toggle("Drums", isOn: $lineup.drums)
            Toggle("Bass", isOn: $lineup.bass)
            Stepper("Guitars: \(lineup.guitars)", value: $lineup.guitars, in: 0...3)
            Stepper("Keys: \(lineup.keys)", value: $lineup.keys, in: 0...3)
            Toggle("Percussion", isOn: $lineup.percussion)
            Stepper("Horns: \(lineup.horns)", value: $lineup.horns, in: 0...5)
            Stepper("Backing vocals: \(lineup.backingVocals)", value: $lineup.backingVocals, in: 0...6)
            Toggle("Wedges (off = in-ears only)", isOn: $lineup.wedges)
        }
    }
}

// MARK: - Stage Set Builder (layout only)

struct StageSetSheet: View {
    @EnvironmentObject var store: ShowStore
    @Environment(\.dismiss) private var dismiss
    @State private var lineup = Lineup()
    @State private var writeInputs = true
    var onApply: (() -> Void)? = nil

    var body: some View {
        let preview = StageSetBuilder.layout(store.show.stagePlot, lineup: lineup)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "person.3.sequence.fill").font(.title2).foregroundStyle(.pink)
                VStack(alignment: .leading) {
                    Text("Stage Set Builder").font(.title2.bold())
                    Text("Tell it who's performing — it lays out the artist, hype, dancers, band, DJ, mics, wedges and backline on your stage design.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding()
            Divider()
            HStack(alignment: .top, spacing: 0) {
                Form {
                    LineupEditor(lineup: $lineup)
                    Section { Toggle("Write a matching input list", isOn: $writeInputs) }
                }
                .formStyle(.grouped)
                .frame(width: 330)
                VStack(alignment: .leading, spacing: 6) {
                    StagePlotCanvas(plot: .constant(preview.plot), selection: .constant([]), editable: false)
                        .padding(8)
                    ForEach(preview.notes, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    Text("\(lineup.headcount) people · \(preview.placed) items. Your trusses, screens and risers stay; performers and backline are replaced. Everything stays editable.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Lay Out Stage") {
                    store.show.stagePlot = preview.plot
                    store.show.lineup = lineup
                    if writeInputs { store.show.inputList = StageSetBuilder.inputList(for: lineup) }
                    onApply?()
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 960, height: 660)
        .onAppear {
            if let l = store.show.lineup { lineup = l } else { lineup.artistName = store.show.venue.artist }
        }
    }
}

// MARK: - Full Auto Show

struct AutoShowSheet: View {
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var builder: LightSetBuilder
    @EnvironmentObject var lighting: LightingEngine
    @EnvironmentObject var engine: ShowEngine
    @Environment(\.dismiss) private var dismiss
    @State private var plan = AutoShowDirector.Plan()
    @State private var step = 0          // 0 songs, 1 stage, 2 show, 3 building/done
    @State private var log: [String] = []
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "sparkles.tv.fill").font(.largeTitle).foregroundStyle(.linearGradient(colors: [.pink, .purple], startPoint: .top, endPoint: .bottom))
                VStack(alignment: .leading) {
                    Text("Full Auto Show").font(.title.bold())
                    Text("Upload the songs. It lays out the stage, rigs the lights, analyses every song and builds the whole show start to end: walk-in, every song's lights, lasers, effects and visuals, the outro and the end.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding()
            if step < 3 {
                Picker("", selection: $step) {
                    Text("1  Songs").tag(0); Text("2  Stage & band").tag(1); Text("3  Show").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal)
            }
            Divider().padding(.top, 8)
            Group {
                switch step {
                case 0: songsStep
                case 1: stageStep
                case 2: showStep
                default: buildStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                if step == 3 {
                    Spacer()
                    Button("Done") { dismiss() }.buttonStyle(.borderedProminent).disabled(running)
                } else {
                    Text("\(plan.songs.count) song\(plan.songs.count == 1 ? "" : "s") · \(plan.lineup.headcount) on stage")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { dismiss() }
                    if step > 0 { Button("Back") { step -= 1 } }
                    if step < 2 {
                        Button("Next") { step += 1 }.disabled(plan.songs.isEmpty)
                    } else {
                        Button { build() } label: { Label("Build Entire Show", systemImage: "wand.and.stars") }
                            .buttonStyle(.borderedProminent).tint(.pink).keyboardShortcut(.defaultAction)
                            .disabled(plan.songs.isEmpty || builder.batch.running)
                    }
                }
            }
            .padding()
        }
        .frame(width: 900, height: 700)
        .onAppear {
            if let l = store.show.lineup { plan.lineup = l } else { plan.lineup.artistName = store.show.venue.artist }
            plan.city = store.show.venue.city
            plan.rig = store.show.lighting.fixtures.isEmpty ? .build : .rehang
        }
    }

    private var songsStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    let picked = pickFiles(MediaSupport.audioTypes + MediaSupport.videoTypes, multiple: true)
                    plan.songs = Array((plan.songs + picked).prefix(LightSetBuilder.batchLimit))
                } label: { Label("Upload Songs…", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Text("\(plan.songs.count)/\(LightSetBuilder.batchLimit) · audio or music videos · drag to set the running order")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                if !plan.songs.isEmpty { Button("Clear") { plan.songs.removeAll() } }
            }
            List {
                ForEach(Array(plan.songs.enumerated()), id: \.offset) { i, url in
                    HStack {
                        Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22)
                        Image(systemName: MediaSupport.isVideo(url) ? "film" : "music.note")
                        Text(url.deletingPathExtension().lastPathComponent).lineLimit(1)
                    }
                }
                .onMove { plan.songs.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { plan.songs.remove(atOffsets: $0) }
            }
            .dropDestination(for: URL.self) { urls, _ in
                plan.songs = Array((plan.songs + urls).prefix(LightSetBuilder.batchLimit)); return true
            }
            .overlay {
                if plan.songs.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "music.note.list").font(.system(size: 44)).foregroundStyle(.secondary)
                        Text("Drop songs here").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
    }

    private var stageStep: some View {
        HStack(alignment: .top, spacing: 0) {
            Form {
                Section("Stage design") {
                    Picker("Structure", selection: $plan.template) {
                        Text("Keep my stage design").tag(String?.none)
                        ForEach(StageTemplates.all, id: \.name) { Text($0.name).tag(Optional($0.name)) }
                    }
                    Text("Stage size stays \(Int(store.show.stagePlot.stageWidth)) × \(Int(store.show.stagePlot.stageDepth)) m — change it in Stage Plot.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Auto lay out performers & backline", isOn: $plan.layoutStage)
                    Toggle("Write a matching input list", isOn: $plan.writeInputs)
                }
                if plan.layoutStage { LineupEditor(lineup: $plan.lineup) }
                Section("Lights") {
                    Picker("Rig", selection: $plan.rig) {
                        ForEach(RigPlan.allCases) { Text($0.label).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 360)
            VStack(alignment: .leading) {
                Text("Preview").font(.headline)
                StagePlotCanvas(plot: .constant(previewPlot), selection: .constant([]), editable: false)
            }
            .padding()
        }
    }

    private var previewPlot: StagePlot {
        var plot = store.show.stagePlot
        if let name = plan.template, let t = StageTemplates.all.first(where: { $0.name == name }) {
            plot = StageTemplate(name: t.name, width: plot.stageWidth, depth: plot.stageDepth, build: t.build).apply(plot)
        }
        return plan.layoutStage ? StageSetBuilder.layout(plot, lineup: plan.lineup).plot : plot
    }

    private var showStep: some View {
        Form {
            Section("Look") {
                Picker("Vibe", selection: $plan.vibe) {
                    Text("Auto-detect per song").tag(Vibe?.none)
                    ForEach(Vibe.allCases) { Text($0.label).tag(Optional($0)) }
                }
                Picker("Colours", selection: $plan.palette) {
                    Text("Auto per song").tag(String?.none)
                    ForEach(Palette.library) { p in
                        HStack {
                            Text(p.name)
                        }.tag(Optional(p.name))
                    }
                }
                Text("Pick one palette to brand the whole night (e.g. Pink & Purple), or let each song choose.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Running order") {
                Toggle("Walk-in, intro blackout, outro and end cues", isOn: $plan.bookends)
                TextField("City (for the thank-you screen)", text: $plan.city)
                Toggle("Play straight through (each song follows the last)", isOn: $plan.playThrough)
                Toggle("Replace my current cue list", isOn: $plan.replaceCues)
                if !plan.replaceCues {
                    Text("New cues are added after your \(store.show.cues.count) existing cues.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Label("Special effects are cued in every song but only fire when you arm them and allow auto-fire on each unit.", systemImage: "flame")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
    }

    private var buildStep: some View {
        let b = builder.batch
        return VStack(alignment: .leading, spacing: 10) {
            if b.total > 0 {
                ProgressView(value: Double(b.done), total: Double(max(1, b.total))) {
                    Text(b.running ? "Listening to song \(min(b.done + 1, b.total)) of \(b.total)…" : "All songs analysed")
                }
            }
            List {
                ForEach(log, id: \.self) { Label($0, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                ForEach(b.working, id: \.self) { n in HStack { ProgressView().controlSize(.small); Text("Analysing \(n)…") } }
                ForEach(b.failed, id: \.self) { n in Label("\(n) — couldn't analyse", systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
                if !running && !log.isEmpty {
                    Label("Show ready — press GO. Save it with ⌘S.", systemImage: "play.circle.fill").font(.headline).foregroundStyle(.pink)
                }
            }
        }
        .padding()
    }

    private func build() {
        step = 3
        running = true
        log = AutoShowDirector.buildStage(plan, store: store, lighting: lighting)
        let plan = self.plan
        Task {
            let shows = await builder.runBatch(plan.songs, vibe: plan.vibe, paletteName: plan.palette).compactMap { $0 }
            let start = plan.replaceCues ? 0 : store.show.cues.count
            log += AutoShowDirector.buildCues(plan, shows: shows, store: store, builder: builder)
            if store.show.cues.indices.contains(start) { engine.standbyIndex = start }
            if let first = shows.first { builder.selectedShowID = first.id }
            running = false
        }
    }
}
