import SwiftUI
import UniformTypeIdentifiers
import AppKit

@MainActor
func pickFiles(_ types: [UTType], multiple: Bool = false) -> [URL] {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = types
    panel.allowsMultipleSelection = multiple
    panel.canChooseDirectories = false
    return panel.runModal() == .OK ? panel.urls : []
}

struct CueListView: View {
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var engine: ShowEngine

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                CueListToolbar()
                Divider()
                CueTable()
            }
            .frame(minWidth: 520)

            Group {
                if let id = engine.selectedCueID, let index = store.cueIndex(id) {
                    CueInspector(index: index)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "cursorarrow.click.2").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Select a cue to edit it").foregroundStyle(.secondary)
                        Text("Drag audio or video files from Finder onto the list to create cues.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 320, idealWidth: 380, maxWidth: 520)
        }
    }
}

private struct CueListToolbar: View {
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var engine: ShowEngine
    @State private var showAuto = false

    var body: some View {
        HStack {
            Menu {
                ForEach(CueKind.allCases) { kind in
                    Button {
                        let cue = store.addCue(kind, after: store.cueIndex(engine.selectedCueID))
                        engine.selectedCueID = cue.id
                    } label: {
                        Label(kind.label, systemImage: kind.symbol)
                    }
                }
            } label: {
                Label("Add Cue", systemImage: "plus")
            }
            .fixedSize()

            Button {
                let urls = pickFiles(MediaSupport.audioTypes + MediaSupport.videoTypes + MediaSupport.imageTypes, multiple: true)
                if !urls.isEmpty { store.addAudioCues(from: urls, at: store.cueIndex(engine.selectedCueID)) }
            } label: {
                Label("Add Media…", systemImage: "square.and.arrow.down")
            }

            Button(role: .destructive) {
                deleteSelected()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(engine.selectedCueID == nil)

            Button { showAuto = true } label: { Label("Full Auto Show…", systemImage: "sparkles.tv.fill") }
                .tint(.purple)
                .help("Upload songs — it builds the stage, rig and the whole show start to end")
                .sheet(isPresented: $showAuto) { AutoShowSheet() }

            Spacer()

            Button {
                if let id = engine.selectedCueID { engine.setStandby(cueID: id) }
            } label: {
                Label("Set Standby", systemImage: "arrow.right.to.line")
            }
            .disabled(engine.selectedCueID == nil)
            .help("Move the GO pointer to the selected cue")

            Toggle(isOn: $store.show.playback.autoStopPrevious) {
                Label("Auto-stop previous", systemImage: "forward.end.alt")
            }
            .toggleStyle(.button)
            .help("When GO starts a new track or video, fade out the one already playing")
            if store.show.playback.autoStopPrevious {
                Picker("", selection: $store.show.playback.stopFade) {
                    Text("Cut").tag(0.0); Text("1s fade").tag(1.0); Text("2s fade").tag(2.0)
                    Text("4s fade").tag(4.0); Text("8s fade").tag(8.0)
                }
                .labelsHidden().frame(width: 90)
            }
            Text("\(store.show.cues.count) cues").font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
    }

    private func deleteSelected() {
        guard let id = engine.selectedCueID, let i = store.cueIndex(id) else { return }
        store.show.cues.remove(at: i)
        if engine.standbyIndex > i { engine.moveStandby(by: -1) }
        engine.selectedCueID = store.show.cues.indices.contains(i) ? store.show.cues[i].id : store.show.cues.last?.id
    }
}

private struct CueTable: View {
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var engine: ShowEngine

    var body: some View {
        List(selection: $engine.selectedCueID) {
            ForEach(Array(store.show.cues.enumerated()), id: \.element.id) { index, cue in
                CueRow(cue: cue, index: index,
                       isStandby: index == engine.standbyIndex,
                       isRunning: engine.running.contains { $0.cueID == cue.id })
                    .tag(cue.id)
                    .contextMenu {
                        Button("Set Standby Here") { engine.setStandby(index) }
                        Button("Fire This Cue Only") { engine.fireOnly(cueID: cue.id) }
                        Button("Duplicate") {
                            var copy = cue
                            copy.id = UUID()
                            copy.number = store.nextCueNumber()
                            store.show.cues.insert(copy, at: index + 1)
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            store.show.cues.removeAll { $0.id == cue.id }
                        }
                    }
            }
            .onMove { from, to in
                store.show.cues.move(fromOffsets: from, toOffset: to)
            }

            if engine.standbyIndex >= store.show.cues.count {
                HStack {
                    Image(systemName: "arrowtriangle.right.fill").foregroundStyle(.green)
                    Text("End of list").foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .dropDestination(for: URL.self) { urls, _ in
            store.addAudioCues(from: urls, at: store.cueIndex(engine.selectedCueID))
            return !urls.isEmpty
        }
        .onDeleteCommand {
            if let id = engine.selectedCueID { store.show.cues.removeAll { $0.id == id } }
        }
    }
}

private struct CueRow: View {
    let cue: Cue
    let index: Int
    let isStandby: Bool
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrowtriangle.right.fill")
                .foregroundStyle(isStandby ? Color.green : Color.clear)
                .frame(width: 14)
            Text(cue.number.isEmpty ? "–" : cue.number)
                .font(.body.monospacedDigit().weight(.semibold))
                .frame(width: 42, alignment: .leading)
            Image(systemName: cue.kind.symbol)
                .foregroundStyle(cue.kind.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(cue.displayName).fontWeight(isStandby ? .bold : .regular).lineLimit(1)
                    if cue.kind == .layered {
                        ForEach(Array((cue.layers ?? []).enumerated()), id: \.offset) { _, l in
                            Image(systemName: l.kind.symbol).font(.caption).foregroundStyle(l.kind.tint)
                        }
                    }
                }
                if !cue.notes.isEmpty {
                    Text(cue.notes).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if cue.preWait > 0 {
                Text("pre \(cue.preWait, specifier: "%.1f")s").font(.caption.monospacedDigit()).foregroundStyle(.orange)
            }
            if !cue.continueMode.shortLabel.isEmpty {
                Text(cue.continueMode.shortLabel).font(.caption.weight(.bold)).foregroundStyle(.cyan)
            }
            if isRunning {
                Image(systemName: "play.circle.fill").foregroundStyle(.green)
            }
        }
        .padding(.vertical, 3)
        .background(isStandby ? Color.green.opacity(0.12) : Color.clear)
    }
}

// MARK: - Inspector

struct CueInspector: View {
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var engine: ShowEngine
    let index: Int

    var body: some View {
        if store.show.cues.indices.contains(index) {
            let cue = $store.show.cues[index]
            Form {
                Section {
                    HStack {
                        Image(systemName: cue.wrappedValue.kind.symbol).foregroundStyle(cue.wrappedValue.kind.tint)
                        Text(cue.wrappedValue.kind.label).font(.headline)
                        Spacer()
                        Button("Fire") { engine.fireOnly(cueID: cue.wrappedValue.id) }
                    }
                    TextField("Number", text: cue.number)
                    TextField("Name", text: cue.name, prompt: Text(cue.wrappedValue.displayName))
                    TextField("Notes (shown on standby)", text: cue.notes, axis: .vertical)
                        .lineLimit(2...5)
                }
                Section("Timing") {
                    SecondsField(title: "Pre-wait", value: cue.preWait)
                    Picker("Continue", selection: cue.continueMode) {
                        ForEach(ContinueMode.allCases) { Text($0.label).tag($0) }
                    }
                    if cue.wrappedValue.kind == .audio || cue.wrappedValue.kind == .video {
                        Picker("Stop what's playing", selection: cue.stopPrevious) {
                            Text("Show default (\(store.show.playback.autoStopPrevious ? "yes" : "no"))").tag(Bool?.none)
                            Text("Yes — fade out previous").tag(Bool?.some(true))
                            Text("No — play on top").tag(Bool?.some(false))
                        }
                    }
                }
                KindSpecificSection(cue: cue)
            }
            .formStyle(.grouped)
        }
    }
}

struct SecondsField: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...3600

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: $value, format: .number.precision(.fractionLength(0...2)))
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
                .labelsHidden()
            Text("s").foregroundStyle(.secondary)
            Stepper(title, value: $value, in: range, step: 0.5).labelsHidden()
        }
    }
}

private struct KindSpecificSection: View {
    @EnvironmentObject var store: ShowStore
    @Binding var cue: Cue

    var body: some View {
        switch cue.kind {
        case .audio: AudioCueSection(cue: $cue)
        case .lights: LightsCueSection(cue: $cue)
        case .video: VideoCueSection(cue: $cue)
        case .videoBlack:
            Section("Screens") { SecondsField(title: "Fade to black", value: $cue.videoFade) }
        case .fade: FadeCueSection(cue: $cue)
        case .vocalFX: VocalCueSection(cue: $cue)
        case .wait:
            Section("Wait") { SecondsField(title: "Duration", value: $cue.waitDuration) }
        case .effect: EffectCueSection(cue: $cue)
        case .layered: LayeredCueSection(cue: $cue)
        case .memo:
            Section { Text("Memo cues do nothing — use them as standby notes for the crew.").foregroundStyle(.secondary) }
        }
    }
}

private struct AudioCueSection: View {
    @Binding var cue: Cue
    var body: some View {
        Section("Audio") {
            FilePickerRow(path: $cue.audioPath, types: MediaSupport.audioTypes + MediaSupport.videoTypes)
            HStack {
                Text("Level")
                Slider(value: $cue.gainDB, in: -60...12)
                Text("\(cue.gainDB, specifier: "%+.1f") dB").font(.caption.monospacedDigit()).frame(width: 64, alignment: .trailing)
            }
            SecondsField(title: "Fade in", value: $cue.fadeIn)
            SecondsField(title: "Start at", value: $cue.startOffset)
            Toggle("Loop until faded / stopped", isOn: $cue.loop)
            AutoLightsPicker(cue: $cue)
        }
    }
}

private struct AutoLightsPicker: View {
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var builder: LightSetBuilder
    @Binding var cue: Cue

    var body: some View {
        Picker("Auto light show", selection: $cue.lightShowID) {
            Text("None").tag(UUID?.none)
            ForEach(store.show.lightShows) { show in
                Label("\(show.name) — \(show.vibe.label)", systemImage: show.vibe.symbol).tag(Optional(show.id))
            }
        }
        if cue.lightShowID == nil, let path = cue.audioPath {
            Button {
                builder.analyze(url: URL(fileURLWithPath: path), linkTo: cue.id)
            } label: { Label("Analyse this song & build its lights", systemImage: "wand.and.stars") }
        }
    }
}

private struct LightsCueSection: View {
    @EnvironmentObject var store: ShowStore
    @Binding var cue: Cue
    var body: some View {
        Section("Lighting") {
            Picker("Scene", selection: $cue.sceneID) {
                Text("None").tag(UUID?.none)
                ForEach(store.show.lighting.scenes) { Text($0.name).tag(Optional($0.id)) }
            }
            SecondsField(title: "Fade time", value: $cue.lightFade)
            if store.show.lighting.scenes.isEmpty {
                Text("Record scenes on the Lighting page first.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct VideoCueSection: View {
    @EnvironmentObject var store: ShowStore
    @Binding var cue: Cue
    var body: some View {
        Section("Video / Image") {
            FilePickerRow(path: $cue.videoPath, types: MediaSupport.videoTypes + MediaSupport.imageTypes)
            Toggle("Play the video's sound through the show audio", isOn: Binding(get: { cue.videoSound != false }, set: { cue.videoSound = $0 }))
            VideoStatusRow(path: cue.videoPath)
            ScreenTargetPicker(cue: $cue)
            SecondsField(title: "Cross-fade", value: $cue.videoFade)
            Toggle("Loop", isOn: $cue.videoLoop)
        }
    }
}

private struct FadeCueSection: View {
    @EnvironmentObject var store: ShowStore
    @Binding var cue: Cue
    var body: some View {
        Section("Fade & Stop") {
            Picker("Target", selection: $cue.fadeTarget) {
                ForEach(FadeTarget.allCases) { Text($0.label).tag($0) }
            }
            if cue.fadeTarget == .specificCue {
                Picker("Cue", selection: $cue.fadeTargetCueID) {
                    Text("Choose…").tag(UUID?.none)
                    ForEach(store.show.cues.filter { $0.kind == .audio || $0.kind == .video }) { c in
                        Text("\(c.number) \(c.displayName)").tag(Optional(c.id))
                    }
                }
            }
            SecondsField(title: "Fade duration", value: $cue.fadeDuration)
        }
    }
}

private struct VocalCueSection: View {
    @EnvironmentObject var store: ShowStore
    @Binding var cue: Cue
    var body: some View {
        Section("Vocal FX") {
            Picker("Rack", selection: $cue.vocalBypass) {
                Text("FX ON (e.g. Auto-Tune in)").tag(false)
                Text("Bypass (dry vocal)").tag(true)
            }
            .pickerStyle(.radioGroup)
            Picker("Recall preset", selection: $cue.vocalPresetID) {
                Text("Keep current settings").tag(UUID?.none)
                ForEach(store.show.vocalRack.presets) { Text($0.name).tag(Optional($0.id)) }
            }
        }
    }
}

/// Tells the operator whether a video will play and whether its sound is ready.
struct VideoStatusRow: View {
    let path: String?
    @State private var playable: Bool?
    @State private var soundReady = false

    var body: some View {
        HStack(spacing: 6) {
            if let playable {
                Image(systemName: playable ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(playable ? Color.green : Color.red)
                Text(playable ? (soundReady ? "Plays on screens · sound ready" : "Plays on screens · preparing sound…")
                              : "macOS can't play this file. Use .mp4 (H.264/HEVC) or .mov (ProRes).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: path) {
            guard let path, !MediaSupport.isImage(URL(fileURLWithPath: path)) else { playable = nil; return }
            let url = URL(fileURLWithPath: path)
            playable = await MediaSupport.canPlayVideo(url)
            for _ in 0..<120 {
                soundReady = MediaSupport.readyAudio(for: url) != nil
                if soundReady || playable == false { break }
                MediaSupport.prepare(url)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}

struct FilePickerRow: View {
    @Binding var path: String?
    let types: [UTType]

    var body: some View {
        HStack {
            Image(systemName: exists ? "doc.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(exists ? Color.secondary : Color.orange)
            Text(path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No file")
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(path == nil ? .secondary : .primary)
            Spacer()
            Button("Choose…") {
                if let url = pickFiles(types).first { path = url.path }
            }
            if let path {
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var exists: Bool {
        guard let path else { return false }
        return FileManager.default.fileExists(atPath: path)
    }
}


/// Layered cue editor: sound, lights, video, effects and vocal FX on one GO, each with its own delay.
private struct LayeredCueSection: View {
    @EnvironmentObject var store: ShowStore
    @Binding var cue: Cue

    private var layers: Binding<[Cue]> {
        Binding(get: { cue.layers ?? [] }, set: { cue.layers = $0 })
    }
    private static let layerKinds: [CueKind] = [.audio, .lights, .video, .effect, .vocalFX, .videoBlack, .fade]

    var body: some View {
        Section("Layers — all fire on one GO") {
            if layers.wrappedValue.isEmpty {
                Text("Add a track, a lighting look, a video and an effect — they all go together. Use each layer's delay to time hits (e.g. CO₂ 0.5 s after the drop).")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Menu {
                    ForEach(Self.layerKinds) { k in
                        Button { addLayer(Cue(kind: k)) } label: { Label(k.label, systemImage: k.symbol) }
                    }
                } label: { Label("Add layer", systemImage: "plus") }
                .fixedSize()
                Menu {
                    ForEach(store.show.cues.filter { $0.kind != .layered && $0.id != cue.id }) { c in
                        Button("\(c.number)  \(c.displayName)") {
                            var copy = c
                            copy.id = UUID()
                            copy.preWait = 0
                            copy.continueMode = .none
                            addLayer(copy)
                        }
                    }
                } label: { Label("Copy from cue list", systemImage: "doc.on.doc") }
                .fixedSize()
            }
            if !layers.wrappedValue.isEmpty {
                Picker("Stop what's playing", selection: $cue.stopPrevious) {
                    Text("Show default (\(store.show.playback.autoStopPrevious ? "yes" : "no"))").tag(Bool?.none)
                    Text("Yes — fade out previous").tag(Bool?.some(true))
                    Text("No — play on top").tag(Bool?.some(false))
                }
            }
        }
        ForEach(Array(layers.wrappedValue.indices), id: \.self) { i in
            if layers.wrappedValue.indices.contains(i) {
                let layer = layers[i]
                Section {
                    HStack {
                        Image(systemName: layer.wrappedValue.kind.symbol).foregroundStyle(layer.wrappedValue.kind.tint)
                        TextField("Layer name", text: layer.name, prompt: Text(layer.wrappedValue.displayName))
                        Spacer()
                        Button { move(i, -1) } label: { Image(systemName: "chevron.up") }.disabled(i == 0)
                        Button { move(i, 1) } label: { Image(systemName: "chevron.down") }.disabled(i == layers.wrappedValue.count - 1)
                        Button(role: .destructive) { layers.wrappedValue.remove(at: i) } label: { Image(systemName: "trash") }
                    }
                    .buttonStyle(.borderless)
                    SecondsField(title: "Delay after GO", value: layer.preWait)
                } header: {
                    Text("Layer \(i + 1) · \(layer.wrappedValue.kind.label)")
                }
                KindSpecificSection(cue: layer)
            }
        }
    }

    private func addLayer(_ c: Cue) {
        var list = layers.wrappedValue
        list.append(c)
        layers.wrappedValue = list
    }

    private func move(_ i: Int, _ d: Int) {
        var list = layers.wrappedValue
        let j = i + d
        guard list.indices.contains(j) else { return }
        list.swapAt(i, j)
        layers.wrappedValue = list
    }
}


/// Which screens, which area of the screen, how it's resized, and whether it layers on top.
struct ScreenTargetPicker: View {
    @EnvironmentObject var store: ShowStore
    @Binding var cue: Cue

    private enum Mode: Hashable { case one, several, all }
    private var mode: Mode {
        if cue.allScreens == true { return .all }
        if (cue.screenIDs?.count ?? 0) > 0 { return .several }
        return .one
    }

    var body: some View {
        Picker("Send to", selection: Binding(get: { mode }, set: { m in
            switch m {
            case .all: cue.allScreens = true; cue.screenIDs = nil
            case .several: cue.allScreens = nil; cue.screenIDs = store.show.screens.map(\.id)
            case .one: cue.allScreens = nil; cue.screenIDs = nil
            }
        })) {
            Text("One screen").tag(Mode.one)
            Text("Several screens").tag(Mode.several)
            Text("All screens").tag(Mode.all)
        }
        .pickerStyle(.segmented)
        switch mode {
        case .one:
            Picker("Screen", selection: $cue.screenID) {
                ForEach(store.show.screens) { Text($0.name).tag(Optional($0.id)) }
            }
        case .several:
            ForEach(store.show.screens) { sc in
                Toggle(sc.name, isOn: Binding(get: { cue.screenIDs?.contains(sc.id) ?? false }, set: { on in
                    var ids = cue.screenIDs ?? []
                    if on { if !ids.contains(sc.id) { ids.append(sc.id) } } else { ids.removeAll { $0 == sc.id } }
                    cue.screenIDs = ids
                }))
            }
        case .all:
            Text("Goes to all \(store.show.screens.count) screens, perfectly in sync.").font(.caption).foregroundStyle(.secondary)
        }
        HStack(alignment: .top) {
            Picker("Area", selection: Binding(get: { cue.region ?? .full }, set: { cue.region = $0 == .full ? nil : $0 })) {
                ForEach(ScreenRegion.allCases) { Text($0.label).tag($0) }
            }
            RegionThumb(region: cue.region ?? .full).frame(width: 64, height: 36)
        }
        Picker("Resize", selection: Binding(get: { cue.effectiveFit }, set: { cue.fitMode = $0; cue.videoFill = $0 == .fill })) {
            ForEach(FitMode.allCases) { Text($0.label).tag($0) }
        }
        AutoFitSummary(cue: cue)
        Toggle("Layer on top (keep what's already showing)", isOn: Binding(get: { cue.overlay == true }, set: { cue.overlay = $0 ? true : nil }))
        if cue.overlay == true {
            HStack {
                Text("Opacity")
                Slider(value: Binding(get: { cue.mediaOpacity ?? 1 }, set: { cue.mediaOpacity = $0 }), in: 0.1...1)
                Text("\(Int((cue.mediaOpacity ?? 1) * 100))%").font(.caption.monospacedDigit()).frame(width: 40)
            }
        }
    }
}

/// Little screen diagram showing the chosen area.
struct RegionThumb: View {
    let region: ScreenRegion
    var body: some View {
        GeometryReader { g in
            let r = region.rect
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.black).overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.gray))
                Rectangle().fill(Color.purple.opacity(0.8))
                    .frame(width: g.size.width * r.width, height: g.size.height * r.height)
                    .offset(x: g.size.width * r.minX, y: g.size.height * r.minY)
            }
        }
    }
}
