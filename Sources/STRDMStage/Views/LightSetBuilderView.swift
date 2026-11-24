import SwiftUI
import UniformTypeIdentifiers

/// Analyses songs and turns them into beat-synced light shows.
@MainActor
final class LightSetBuilder: ObservableObject {
    @Published private(set) var analyzing: [String] = []
    @Published var selectedShowID: UUID? = nil
    @Published var previewRunID: UUID? = nil
    @Published var previewShowID: UUID? = nil

    private let store: ShowStore
    private let engine: ShowEngine
    private let lighting: LightingEngine

    init(store: ShowStore, engine: ShowEngine, lighting: LightingEngine) {
        self.store = store
        self.engine = engine
        self.lighting = lighting
    }

    /// Batch import (up to 20 songs): progress for the import sheet.
    struct Batch: Equatable {
        var total = 0
        var done = 0
        var working: [String] = []
        var finished: [String] = []
        var failed: [String] = []
        var running: Bool { done < total }
    }
    @Published var batch = Batch()
    static let batchLimit = 20

    /// Listens to one file (audio or music video) and builds its complete show: lights, lasers,
    /// effect hits and screen visuals per section. Returns the new light show (already saved in the show).
    func analyzeCore(url: URL, vibe: Vibe? = nil, paletteName: String? = nil) async -> LightShow? {
        let name = url.deletingPathExtension().lastPathComponent
        analyzing.append(name)
        defer { analyzing.removeAll { $0 == name } }
        // Music videos: pull the soundtrack out first so the song can also play as a normal audio cue.
        var songURL = url
        var videoPath: String? = nil
        if MediaSupport.isVideo(url) {
            videoPath = url.path
            do { songURL = try await MediaSupport.extractAudio(from: url) } catch {
                store.lastError = "\(name): \(error.localizedDescription)"
                return nil
            }
        }
        let analyseURL = songURL
        let result = await Task.detached(priority: .userInitiated) { () -> Result<SongAnalyzer.Result, Error> in
            do { return .success(try SongAnalyzer.analyze(url: analyseURL)) } catch { return .failure(error) }
        }.value
        switch result {
        case .success(let r):
            var show = LookGenerator.makeShow(name: name, path: songURL.path, analysis: r.analysis, sections: r.sections, vibe: vibe, paletteName: paletteName)
            show.videoPath = videoPath
            store.show.lightShows.removeAll { $0.songPath == songURL.path }
            store.show.lightShows.append(show)
            return show
        case .failure(let error):
            store.lastError = "\(name): \(error.localizedDescription)"
            return nil
        }
    }


    /// Analyses up to 20 files two at a time with progress in `batch`. Results keep the input order.
    func runBatch(_ picked: [URL], vibe: Vibe? = nil, paletteName: String? = nil) async -> [LightShow?] {
        let urls = Array(picked.prefix(Self.batchLimit))
        batch = Batch(total: urls.count)
        var shows = [LightShow?](repeating: nil, count: urls.count)
            var i = 0
            while i < urls.count {
                let chunk = Array(i..<min(i + 2, urls.count))
                for k in chunk { batch.working.append(urls[k].deletingPathExtension().lastPathComponent) }
                await withTaskGroup(of: (Int, LightShow?).self) { group in
                    for k in chunk {
                        let url = urls[k]
                        group.addTask { @MainActor in (k, await self.analyzeCore(url: url, vibe: vibe, paletteName: paletteName)) }
                    }
                    for await (k, show) in group {
                        shows[k] = show
                        let name = urls[k].deletingPathExtension().lastPathComponent
                        batch.working.removeAll { $0 == name }
                        if show != nil { batch.finished.append(name) } else { batch.failed.append(name) }
                        batch.done += 1
                    }
                }
                i += 2
            }
        return shows
    }

    /// Imports up to 20 songs: analyses them (two at a time), builds every show start to finish and adds the
    /// cues to the cue list in the order you picked them.
    func importSongs(_ picked: [URL], addCues: Bool = true, playThrough: Bool = false, vibe: Vibe? = nil) {
        let urls = Array(picked.prefix(Self.batchLimit))
        guard !urls.isEmpty, !batch.running else { return }
        Task {
            let shows = await runBatch(urls, vibe: vibe)
            if addCues {
                var added: [UUID] = []
                for show in shows.compactMap({ $0 }) {
                    let before = store.show.cues.count
                    addCue(for: show)
                    added += store.show.cues[before...].map(\.id)
                }
                if playThrough {
                    // Each song follows the last one automatically (video+audio pairs stay chained).
                    for id in added.dropLast() {
                        if let k = store.cueIndex(id), store.show.cues[k].kind == .audio { store.show.cues[k].continueMode = .autoFollow }
                    }
                }
            }
            if let first = shows.compactMap({ $0 }).first { selectedShowID = first.id }
        }
    }

    /// Analyses one song file and adds its light show. Optionally links it to an audio cue.
    func analyze(url: URL, linkTo cueID: UUID? = nil) {
        Task {
            guard let show = await analyzeCore(url: url) else { return }
            let songPath = show.songPath
            do {
                selectedShowID = show.id
                if let cueID, let i = store.cueIndex(cueID) {
                    store.show.cues[i].lightShowID = show.id
                } else {
                    for i in store.show.cues.indices where store.show.cues[i].audioPath == url.path || store.show.cues[i].audioPath == songPath {
                        store.show.cues[i].lightShowID = show.id
                    }
                }
            }
        }
    }

    /// Analyses every audio cue in the cue list that doesn't have a light show yet and links them up.
    func buildFromCueList(replaceExisting: Bool = false) {
        var seen = Set<String>()
        for cue in store.show.cues where cue.kind == .audio {
            guard let path = cue.audioPath, FileManager.default.fileExists(atPath: path), !seen.contains(path) else { continue }
            seen.insert(path)
            if !replaceExisting, let id = cue.lightShowID, store.show.lightShows.contains(where: { $0.id == id }) { continue }
            analyze(url: URL(fileURLWithPath: path), linkTo: cue.id)
        }
        if seen.isEmpty {
            store.lastError = "No audio cues with files found. Drag your tracks onto the Cue List first, or use “Analyse song…”."
        }
    }

    /// Runs the deep analyser again on an existing show, keeping its id (cue links), vibe and colours.
    func reanalyse(_ showID: UUID) {
        guard let old = store.show.lightShows.first(where: { $0.id == showID }) else { return }
        let name = old.name
        analyzing.append(name)
        let url = URL(fileURLWithPath: old.songPath)
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<SongAnalyzer.Result, Error> in
                do { return .success(try SongAnalyzer.analyze(url: url)) } catch { return .failure(error) }
            }.value
            analyzing.removeAll { $0 == name }
            guard let i = store.show.lightShows.firstIndex(where: { $0.id == showID }) else { return }
            switch result {
            case .success(let r):
                var show = store.show.lightShows[i]
                show.analysis = r.analysis
                show.sections = LookGenerator.looks(for: r.sections, vibe: show.vibe, palette: Palette.named(show.paletteName),
                                                    hasDrums: (r.analysis.kicks?.count ?? 0) > 30)
                store.show.lightShows[i] = show
            case .failure(let error):
                store.lastError = "\(name): \(error.localizedDescription)"
            }
        }
    }

    /// Re-analyses every show made with the older analyser.
    func reanalyseAllOld() {
        for show in store.show.lightShows where show.analysis.beats == nil { reanalyse(show.id) }
    }

    func regenerate(_ showID: UUID, vibe: Vibe? = nil, paletteName: String? = nil) {
        guard let i = store.show.lightShows.firstIndex(where: { $0.id == showID }) else { return }
        var show = store.show.lightShows[i]
        if let vibe {
            show.vibe = vibe
            if paletteName == nil { show.paletteName = vibe.defaultPalette }
        }
        if let paletteName { show.paletteName = paletteName }
        show.sections = LookGenerator.looks(for: show.sections, vibe: show.vibe, palette: Palette.named(show.paletteName),
                                            hasDrums: (show.analysis.kicks?.count ?? 0) > 30)
        store.show.lightShows[i] = show
    }

    func addCue(for show: LightShow) {
        // A song analysed from a music video also gets its video on the first screen, fired together.
        if let video = show.videoPath {
            var v = Cue(kind: .video, number: store.nextCueNumber(), name: "\(show.name) — video")
            v.videoPath = video
            v.screenID = store.show.screens.first?.id
            v.videoSound = false
            v.continueMode = .autoContinue
            store.show.cues.append(v)
        }
        var cue = Cue(kind: .audio, number: store.nextCueNumber(), name: show.name)
        cue.audioPath = show.songPath
        cue.lightShowID = show.id
        store.show.cues.append(cue)
    }

    func preview(_ show: LightShow, from seconds: Double = 0) {
        stopPreview()
        var cue = Cue(kind: .audio, number: "▶", name: "Preview: \(show.name)")
        cue.audioPath = show.songPath
        cue.lightShowID = show.id
        cue.startOffset = seconds
        // Use the latest edits to the show.
        previewRunID = engine.fireAdHoc(cue)
        previewShowID = show.id
    }

    func stopPreview() {
        if let id = previewRunID { engine.stopInstance(id) }
        previewRunID = nil
        previewShowID = nil
    }
}

// MARK: - View

struct LightSetBuilderView: View {
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var builder: LightSetBuilder
    @State private var showImport = false
    @State private var showAuto = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Button { showAuto = true } label: {
                        Label("Full Auto Show — upload songs, get the whole show", systemImage: "sparkles.tv.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.purple).controlSize(.large)
                    Button {
                        for url in pickFiles(MediaSupport.audioTypes + MediaSupport.videoTypes, multiple: true) { builder.analyze(url: url) }
                    } label: { Label("Analyse song…", systemImage: "waveform.badge.magnifyingglass") }
                        .buttonStyle(.borderedProminent)
                    Button { showImport = true } label: {
                        Label("Import Set (up to 20 songs)…", systemImage: "square.stack.3d.down.right.fill")
                    }
                    .buttonStyle(.borderedProminent).tint(.pink)
                    Button { builder.buildFromCueList() } label: {
                        Label("Auto-build whole set from cue list", systemImage: "wand.and.stars")
                    }
                    if store.show.lightShows.contains(where: { $0.analysis.beats == nil }) {
                        Button { builder.reanalyseAllOld() } label: {
                            Label("Re-analyse older songs (deep)", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .help("Upgrade songs analysed before the deep analyser: beat tracking, drums, vocals and structure")
                    }
                    ForEach(builder.analyzing, id: \.self) { name in
                        HStack { ProgressView().controlSize(.small); Text("Listening to \(name)…").font(.caption) }
                    }
                }
                .padding(10)
                Divider()
                List(selection: $builder.selectedShowID) {
                    ForEach(store.show.lightShows) { show in
                        HStack {
                            Image(systemName: show.vibe.symbol)
                                .foregroundStyle(Palette.named(show.paletteName).a.color)
                                .frame(width: 20)
                            VStack(alignment: .leading) {
                                Text(show.name).lineLimit(1)
                                Text("\(Int(show.analysis.bpm.rounded())) BPM · \(show.vibe.label)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(show.id)
                    }
                }
            }
            .frame(minWidth: 220, idealWidth: 250, maxWidth: 320)

            Group {
                if let id = builder.selectedShowID, store.show.lightShows.contains(where: { $0.id == id }) {
                    LightShowDetail(showID: id)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "wand.and.stars").font(.system(size: 44)).foregroundStyle(.pink)
                        Text("Match lights to the vibe of every song").font(.title2.weight(.semibold))
                        Text("Analyse a song and STRDM Stage listens for tempo, beat, key, bass, brightness and the energy of each section, picks a vibe and builds a beat-synced light show. Link it to the song’s cue and it runs automatically when you press GO.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity)
        }
        .sheet(isPresented: $showImport) { ImportSetSheet() }
        .sheet(isPresented: $showAuto) { AutoShowSheet() }
    }
}

/// Import up to 20 songs, analyse them and build a complete show for each (lights, lasers, effects, screens).
struct ImportSetSheet: View {
    @EnvironmentObject var builder: LightSetBuilder
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var addCues = true
    @State private var playThrough = false
    @State private var vibe: Vibe? = nil
    @State private var started = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "square.stack.3d.down.right.fill").font(.title).foregroundStyle(.pink)
                VStack(alignment: .leading) {
                    Text("Import a Set").font(.title2.bold())
                    Text("Up to \(LightSetBuilder.batchLimit) songs or music videos. Each one is analysed and gets a complete show from the first beat to the last: lights, movers, lasers, special-effect hits, strobes, haze and screen visuals per section.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if !started {
                HStack {
                    Button {
                        let picked = pickFiles(MediaSupport.audioTypes + MediaSupport.videoTypes, multiple: true)
                        files = Array((files + picked).prefix(LightSetBuilder.batchLimit))
                    } label: { Label("Choose Songs…", systemImage: "plus") }
                    Text("\(files.count)/\(LightSetBuilder.batchLimit)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    if !files.isEmpty { Button("Clear") { files.removeAll() } }
                }
                List {
                    ForEach(Array(files.enumerated()), id: \.offset) { i, url in
                        HStack {
                            Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22)
                            Image(systemName: MediaSupport.isVideo(url) ? "film" : "music.note")
                            Text(url.deletingPathExtension().lastPathComponent).lineLimit(1)
                        }
                    }
                    .onMove { files.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { files.remove(atOffsets: $0) }
                }
                .frame(minHeight: 220)
                Form {
                    Picker("Vibe", selection: $vibe) {
                        Text("Auto-detect per song").tag(Vibe?.none)
                        ForEach(Vibe.allCases) { Text($0.label).tag(Optional($0)) }
                    }
                    Toggle("Add every song to the cue list in this order", isOn: $addCues)
                    Toggle("Play straight through (each song follows the last)", isOn: $playThrough).disabled(!addCues)
                    Text("Special effects only fire when you arm them and allow auto-fire on each unit. Lasers need a laser fixture patched (Auto Rig adds them).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .formStyle(.grouped)
            } else {
                let b = builder.batch
                ProgressView(value: Double(b.done), total: Double(max(1, b.total))) {
                    Text(b.running ? "Analysing \(b.done + 1) of \(b.total)…" : "Done — \(b.finished.count) shows built")
                }
                List {
                    ForEach(b.working, id: \.self) { n in HStack { ProgressView().controlSize(.small); Text(n) } }
                    ForEach(b.finished, id: \.self) { n in Label(n, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    ForEach(b.failed, id: \.self) { n in Label(n, systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
                }
                .frame(minHeight: 260)
            }
            HStack {
                Spacer()
                if !started {
                    Button("Cancel") { dismiss() }
                    Button("Build \(files.count) Show\(files.count == 1 ? "" : "s")") {
                        started = true
                        builder.importSongs(files, addCues: addCues, playThrough: playThrough, vibe: vibe)
                    }
                    .buttonStyle(.borderedProminent).disabled(files.isEmpty)
                } else {
                    Button(builder.batch.running ? "Hide" : "Done") { dismiss() }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
        .frame(width: 620, height: 640)
    }
}

private struct LightShowDetail: View {
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var builder: LightSetBuilder
    @EnvironmentObject var lighting: LightingEngine
    let showID: UUID

    private var index: Int? { store.show.lightShows.firstIndex { $0.id == showID } }

    var body: some View {
        if let i = index {
            let show = store.show.lightShows[i]
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ShowHeader(show: show, index: i)
                    ShowTimeline(show: show)
                        .frame(height: 120)
                    HStack(alignment: .top, spacing: 12) {
                        VisualPreview()
                            .frame(width: 284, height: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("SCREENS").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                            Text("Each section gets a matching 3D visual in the song's colours. Preview the song to watch it follow the lights; pick a different visual per section below.")
                                .font(.caption).foregroundStyle(.secondary)
                            if let v = show.videoPath {
                                Label("From music video: \(URL(fileURLWithPath: v).lastPathComponent)", systemImage: "film")
                                    .font(.caption)
                            }
                        }
                    }
                    HStack {
                        if builder.previewShowID == show.id {
                            Button { builder.stopPreview() } label: { Label("Stop preview", systemImage: "stop.fill") }
                                .tint(.red)
                        } else {
                            Button { builder.preview(show) } label: { Label("Preview song + lights", systemImage: "play.fill") }
                                .tint(.green)
                        }
                        Button { builder.addCue(for: show) } label: { Label("Add to cue list", systemImage: "plus.rectangle.on.rectangle") }
                        Menu("Link to existing cue") {
                            ForEach(store.show.cues.filter { $0.kind == .audio }) { cue in
                                Button("\(cue.number) \(cue.displayName)") {
                                    if let c = store.cueIndex(cue.id) { store.show.cues[c].lightShowID = show.id }
                                }
                            }
                        }
                        .fixedSize()
                        Spacer()
                        Button(role: .destructive) {
                            builder.stopPreview()
                            store.show.lightShows.removeAll { $0.id == show.id }
                            for c in store.show.cues.indices where store.show.cues[c].lightShowID == show.id {
                                store.show.cues[c].lightShowID = nil
                            }
                        } label: { Image(systemName: "trash") }
                    }
                    .buttonStyle(.borderedProminent)

                    Text("SECTIONS").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    ForEach(Array(show.sections.indices), id: \.self) { s in
                        SectionEditor(showIndex: i, sectionIndex: s, bpm: show.analysis.bpm)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct ShowHeader: View {
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var builder: LightSetBuilder
    let show: LightShow
    let index: Int

    var body: some View {
        let a = show.analysis
        VStack(alignment: .leading, spacing: 10) {
            TextField("Name", text: $store.show.lightShows[index].name)
                .font(.title2.weight(.bold)).textFieldStyle(.plain)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), alignment: .leading)], alignment: .leading, spacing: 8) {
                Stat(title: "Tempo", value: "\(String(format: "%.1f", a.bpm)) BPM")
                Stat(title: "Key", value: a.key)
                Stat(title: "Length", value: formatTime(a.duration))
                Stat(title: "Energy", value: "\(Int(a.arousal * 100))%")
                Stat(title: "Mood", value: a.valence > 0.55 ? "Bright" : (a.valence < 0.35 ? "Dark" : "Mixed"))
                Stat(title: "Bass", value: "\(Int(a.bassWeight * 100))%")
            }
            Text("Heard: \(a.reasoning)").font(.caption).foregroundStyle(.secondary)
            if let st = a.structure {
                Text("Structure (bars): \(st)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if a.beats == nil {
                Text("Analysed with the older analyser — click Re-analyse for beat tracking, drums, vocals and real song structure.")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                HStack(spacing: 10) {
                    Label("bass", systemImage: "circle.fill").foregroundStyle(.red)
                    Label("mids", systemImage: "circle.fill").foregroundStyle(.green)
                    Label("highs", systemImage: "circle.fill").foregroundStyle(.cyan)
                    Label("vocals", systemImage: "square.fill").foregroundStyle(.pink.opacity(0.6))
                    Label("kick", systemImage: "line.diagonal").foregroundStyle(.orange)
                    Label("snare", systemImage: "line.diagonal").foregroundStyle(.yellow)
                }
                .font(.caption2).labelStyle(.titleAndIcon)
            }
            ViewThatFits(in: .horizontal) {
                HStack { vibePicker; palettePicker; PaletteSwatch(palette: Palette.named(show.paletteName)); rebuild }
                VStack(alignment: .leading) {
                    HStack { vibePicker; rebuild }
                    HStack { palettePicker; PaletteSwatch(palette: Palette.named(show.paletteName)) }
                }
            }
        }
    }
}

extension ShowHeader {
    private var vibePicker: some View {
        Picker("Vibe", selection: Binding(get: { show.vibe }, set: { builder.regenerate(show.id, vibe: $0) })) {
            ForEach(Vibe.allCases) { v in
                Label(v == show.analysis.suggestedVibe ? "\(v.label) (detected)" : v.label, systemImage: v.symbol).tag(v)
            }
        }
        .frame(maxWidth: 300)
    }
    private var palettePicker: some View {
        Picker("Colours", selection: Binding(get: { show.paletteName },
                                             set: { builder.regenerate(show.id, paletteName: $0) })) {
            ForEach(Palette.library) { p in Text(p.name).tag(p.name) }
        }
        .frame(maxWidth: 260)
    }
    private var rebuild: some View {
        HStack {
            Button("Rebuild looks") { builder.regenerate(show.id) }
            Button { builder.reanalyse(show.id) } label: { Label("Re-analyse", systemImage: "waveform.badge.magnifyingglass") }
                .disabled(builder.analyzing.contains(show.name))
                .help("Listen again with the deep analyser (beat tracking, drums, vocals, song structure). Keeps the vibe, colours and cue link.")
        }
    }
}

private struct Stat: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
        }
    }
}

private struct PaletteSwatch: View {
    let palette: Palette
    var body: some View {
        HStack(spacing: 3) {
            ForEach([palette.a, palette.b, palette.accent], id: \.self) { c in
                RoundedRectangle(cornerRadius: 3).fill(c.color).frame(width: 18, height: 18)
            }
        }
    }
}

/// Energy curve with the generated sections drawn underneath and a live playhead.
private struct ShowTimeline: View {
    @EnvironmentObject var lighting: LightingEngine
    @EnvironmentObject var builder: LightSetBuilder
    let show: LightShow

    var body: some View {
        let isPlaying = lighting.songStatus?.name == show.name && builder.previewShowID == show.id
            || lighting.songRun?.show.id == show.id
        let elapsed = lighting.songStatus?.elapsed ?? 0
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let dur = max(1, show.analysis.duration)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    for s in show.sections {
                        let x0 = s.start / dur * size.width, x1 = s.end / dur * size.width
                        let rect = CGRect(x: x0, y: size.height - 34, width: max(1, x1 - x0 - 1), height: 34)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 4),
                                 with: .linearGradient(Gradient(colors: [s.look.colorA.color, s.look.colorB.color]),
                                                       startPoint: rect.origin, endPoint: CGPoint(x: rect.maxX, y: rect.minY)))
                        let tag = [s.group.map { "(\($0))" }, (s.vocal ?? 0) > 0.5 ? "🎤" : nil].compactMap { $0 }.joined(separator: " ")
                        ctx.draw(Text(s.label + (tag.isEmpty ? "" : " " + tag)).font(.caption2.weight(.bold)).foregroundColor(.black),
                                 at: CGPoint(x: rect.midX, y: rect.midY))
                    }
                    let a = show.analysis
                    let graphH = size.height - 40
                    // Bar lines (every 4 bars stronger) from the tracked beat grid
                    if let beats = a.beats, let first = a.firstDownbeat {
                        var k = first, bar = 0
                        while k < beats.count {
                            let x = beats[k] / dur * size.width
                            var p = Path(); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: graphH))
                            ctx.stroke(p, with: .color(.white.opacity(bar % 4 == 0 ? 0.12 : 0.04)), lineWidth: 1)
                            k += 4; bar += 1
                        }
                    }
                    // Vocal presence (shaded), then bass / mids / highs lines
                    func line(_ c: [Double]?, rate: Double, color: Color, width: CGFloat, fill: Bool = false) {
                        guard let c, c.count > 1 else { return }
                        var path = Path()
                        for (k, v) in c.enumerated() {
                            let x = Double(k) / rate / dur * size.width
                            let y = graphH - v * graphH * 0.95
                            if k == 0 { path.move(to: CGPoint(x: x, y: fill ? graphH : y)); if fill { path.addLine(to: CGPoint(x: x, y: y)) } }
                            else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                        if fill {
                            path.addLine(to: CGPoint(x: Double(c.count - 1) / rate / dur * size.width, y: graphH))
                            path.closeSubpath()
                            ctx.fill(path, with: .color(color))
                        } else {
                            ctx.stroke(path, with: .color(color), lineWidth: width)
                        }
                    }
                    line(a.vocalCurve, rate: 4, color: .pink.opacity(0.18), width: 0, fill: true)
                    line(a.bassCurve, rate: 4, color: .red.opacity(0.55), width: 1)
                    line(a.midCurve, rate: 4, color: .green.opacity(0.45), width: 1)
                    line(a.highCurve, rate: 4, color: .cyan.opacity(0.45), width: 1)
                    // Drum hits along the bottom of the graph
                    for k in a.kicks ?? [] {
                        let x = k / dur * size.width
                        ctx.fill(Path(CGRect(x: x, y: graphH - 6, width: 1, height: 6)), with: .color(.orange.opacity(0.8)))
                    }
                    for k in a.snares ?? [] {
                        let x = k / dur * size.width
                        ctx.fill(Path(CGRect(x: x, y: graphH - 11, width: 1, height: 4)), with: .color(.yellow.opacity(0.7)))
                    }
                    let curve = show.analysis.energyCurve
                    if curve.count > 1 {
                        var path = Path()
                        for (k, e) in curve.enumerated() {
                            let x = Double(k) / Double(curve.count - 1) * size.width
                            let y = graphH - e * graphH
                            if k == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                        ctx.stroke(path, with: .color(.white.opacity(0.8)), lineWidth: 1.5)
                    }
                }
                if isPlaying {
                    Rectangle().fill(.white).frame(width: 2, height: h)
                        .offset(x: min(w, elapsed / dur * w))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                builder.preview(show, from: max(0, location.x / w * dur))
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
        .help("Click anywhere on the timeline to preview from that point")
    }
}

private struct SectionEditor: View {
    @EnvironmentObject var store: ShowStore
    let showIndex: Int
    let sectionIndex: Int
    let bpm: Double

    var body: some View {
        if store.show.lightShows.indices.contains(showIndex),
           store.show.lightShows[showIndex].sections.indices.contains(sectionIndex) {
            let section = $store.show.lightShows[showIndex].sections[sectionIndex]
            let s = section.wrappedValue
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Section", text: section.label).font(.headline).frame(maxWidth: 140)
                    Text("\(formatTime(s.start)) – \(formatTime(s.end))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text("energy \(Int(s.energy * 100))%").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    ColorPicker("A", selection: Binding(get: { s.look.colorA.color }, set: { section.wrappedValue.look.colorA = RGB($0) }))
                    ColorPicker("B", selection: Binding(get: { s.look.colorB.color }, set: { section.wrappedValue.look.colorB = RGB($0) }))
                    ColorPicker("C", selection: Binding(get: { (s.look.colorC ?? .white).color }, set: { section.wrappedValue.look.colorC = RGB($0) }))
                }
                HStack(spacing: 14) {
                    Picker("Change pattern every", selection: Binding(get: { s.look.phraseBars ?? 0 },
                                                                     set: { section.wrappedValue.look.phraseBars = $0 })) {
                        Text("Never").tag(0); Text("2 bars").tag(2); Text("4 bars").tag(4); Text("8 bars").tag(8); Text("16 bars").tag(16)
                    }
                    .frame(maxWidth: 250)
                    if (s.look.phraseBars ?? 0) > 0 {
                        Menu("Patterns (\(s.look.variations?.count ?? 1))") {
                            ForEach(ChaseKind.allCases) { k in
                                Toggle(k.label, isOn: Binding(get: { (s.look.variations ?? [s.look.chase]).contains(k) }, set: { on in
                                    var v = s.look.variations ?? [s.look.chase]
                                    if on { if !v.contains(k) { v.append(k) } } else if v.count > 1 { v.removeAll { $0 == k } }
                                    section.wrappedValue.look.variations = v
                                }))
                            }
                        }
                        .fixedSize()
                        Menu("Moves (\(s.look.moverVariations?.count ?? 1))") {
                            ForEach(MoverMode.allCases) { k in
                                Toggle(k.label, isOn: Binding(get: { (s.look.moverVariations ?? [s.look.mover]).contains(k) }, set: { on in
                                    var v = s.look.moverVariations ?? [s.look.mover]
                                    if on { if !v.contains(k) { v.append(k) } } else if v.count > 1 { v.removeAll { $0 == k } }
                                    section.wrappedValue.look.moverVariations = v
                                }))
                            }
                        }
                        .fixedSize()
                    }
                    Spacer()
                }
                HStack(spacing: 14) {
                    Picker("Accent", selection: Binding(get: { s.look.accent ?? AccentKind.none }, set: { section.wrappedValue.look.accent = $0 })) {
                        ForEach(AccentKind.allCases) { Text($0.label).tag($0) }
                    }
                    .frame(maxWidth: 230)
                    Toggle("Fills", isOn: Binding(get: { s.look.fills ?? false }, set: { section.wrappedValue.look.fills = $0 }))
                        .help("Quick run on the last two beats of every phrase")
                    Spacer()
                }
                .font(.callout)
                HStack(spacing: 14) {
                    Picker("Effect hit", selection: Binding(get: { s.look.sfxHit }, set: { section.wrappedValue.look.sfxHit = $0 })) {
                        Text("None").tag(SFXKind?.none)
                        ForEach(SFXKind.allCases) { Label($0.label, systemImage: $0.symbol).tag(Optional($0)) }
                    }
                    .frame(maxWidth: 220)
                    .help("Fires when this section starts — only if effects are armed and the unit allows auto-fire")
                    Picker("Lasers", selection: Binding(get: { s.look.laser ?? .off }, set: { section.wrappedValue.look.laser = $0 })) {
                        ForEach(LaserLook.allCases) { Text($0.label).tag($0) }
                    }
                    .frame(maxWidth: 210)
                    if s.look.sfxHit != nil {
                        Picker("Repeat", selection: Binding(get: { s.look.sfxEveryBars ?? 0 }, set: { section.wrappedValue.look.sfxEveryBars = $0 == 0 ? nil : $0 })) {
                            Text("Once").tag(0); Text("Every 4 bars").tag(4); Text("Every 8 bars").tag(8); Text("Every 16 bars").tag(16)
                        }
                        .frame(maxWidth: 190)
                    }
                    Toggle("Build into next", isOn: Binding(get: { s.look.buildUp ?? false }, set: { section.wrappedValue.look.buildUp = $0 }))
                        .help("Speed up and brighten into the next section, with a breath of darkness right before it lands")
                    Spacer()
                }
                .font(.callout)
                HStack(spacing: 14) {
                    Picker((s.look.phraseBars ?? 0) > 0 && s.look.variations != nil ? "Main pattern" : "Chase", selection: section.look.chase) {
                        ForEach(ChaseKind.allCases) { Text($0.label).tag($0) }
                    }
                    .frame(maxWidth: 210)
                    Picker("Every", selection: section.look.beatsPerStep) {
                        Text("½ beat").tag(0.5); Text("1 beat").tag(1.0); Text("2 beats").tag(2.0)
                        Text("4 beats").tag(4.0); Text("8 beats").tag(8.0)
                    }
                    .frame(maxWidth: 140)
                }
                HStack(spacing: 14) {
                    Picker("Movers", selection: section.look.mover) {
                        ForEach(MoverMode.allCases) { Text($0.label).tag($0) }
                    }
                    .frame(maxWidth: 250)
                    Picker("Screens", selection: section.look.visual) {
                        Text("Auto").tag(VisualStyle?.none)
                        ForEach(VisualStyle.allCases) { Text($0.label).tag(Optional($0)) }
                    }
                    .frame(maxWidth: 220)
                    Spacer()
                }
                HStack(spacing: 14) {
                    Text("Level")
                    Slider(value: section.look.intensity, in: 0...1).frame(minWidth: 80, maxWidth: 160)
                    Text("Haze")
                    Slider(value: section.look.haze, in: 0...1).frame(minWidth: 60, maxWidth: 110)
                    Toggle("Strobe hit", isOn: Binding(get: { s.look.strobeBeats > 0 },
                                                       set: { section.wrappedValue.look.strobeBeats = $0 ? 4 : 0 }))
                    Spacer()
                }
                .font(.callout)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(
                LinearGradient(colors: [s.look.colorA.color.opacity(0.18), s.look.colorB.color.opacity(0.08)],
                               startPoint: .leading, endPoint: .trailing)))
        }
    }
}
