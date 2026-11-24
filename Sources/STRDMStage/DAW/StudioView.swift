import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

enum StudioPanel: String, CaseIterable, Identifiable {
    case editor = "Editor", mixer = "Mixer", devices = "Devices", export = "Export"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .editor: return "pianokeys"
        case .mixer: return "slider.vertical.3"
        case .devices: return "cable.connector"
        case .export: return "square.and.arrow.up"
        }
    }
}

/// The Studio: arrangement on top, editor / mixer / devices / export below.
struct StudioView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case arrange = "Arrange & Mix", audio = "Audio & Vocals"
        var id: String { rawValue }
        var icon: String { self == .arrange ? "pianokeys.inverse" : "waveform.and.mic" }
    }
    var openAudio = false
    @EnvironmentObject var daw: DAWEngine
    @State private var panel: StudioPanel = .editor
    @State private var zoom: Double = 22   // pixels per beat
    @AppStorage("STRDMStage.studioMode") private var mode: Mode = .arrange

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { m in Label(m.rawValue, systemImage: m.icon).tag(m) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 330)
                .help("⌥⌘1 Arrange & Mix · ⌥⌘2 Audio & Vocals (interface, master EQ, live vocal rack)")
                Button("") { mode = .arrange }.keyboardShortcut("1", modifiers: [.command, .option]).hidden().frame(width: 0)
                Button("") { mode = .audio }.keyboardShortcut("2", modifiers: [.command, .option]).hidden().frame(width: 0)
                Spacer()
                if mode == .audio {
                    Text("Live rack, interface and EQ are shared with the show — what you set here is what plays live.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color(white: 0.07))
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                StudioTransportBar(zoom: $zoom).fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity)
            Divider()
            if mode == .audio {
                StudioVocalsPanel(onAdded: { mode = .arrange })
            } else {
                arrangeAndMix
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipped()
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { if openAudio { mode = .audio } }
    }

    private var arrangeAndMix: some View {
            VSplitView {
                ArrangementView(zoom: zoom, onOpenClip: { panel = .editor })
                    .frame(minHeight: 200, idealHeight: 340)
                VStack(spacing: 0) {
                    HStack {
                        Picker("", selection: $panel) {
                            ForEach(StudioPanel.allCases) { p in Label(p.rawValue, systemImage: p.icon).tag(p) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(minWidth: 260, maxWidth: 420)
                        Spacer(minLength: 4)
                        Text(daw.status).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    Divider()
                    Group {
                        switch panel {
                        case .editor: ClipEditorPanel()
                        case .mixer: MixerPanel()
                        case .devices: DevicesPanel()
                        case .export: ExportPanel()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minHeight: 220, idealHeight: 300)
            }
    }
}

// MARK: - Transport

struct StudioTransportBar: View {
    @EnvironmentObject var daw: DAWEngine
    @EnvironmentObject var store: ShowStore
    @Binding var zoom: Double

    private var p: DAWProject { daw.project }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                Button { daw.returnToStart() } label: { Image(systemName: "backward.end.fill") }
                    .help("Return to start (Return)")
                Button { daw.togglePlay() } label: {
                    Image(systemName: daw.isPlaying ? "stop.fill" : "play.fill").frame(width: 18)
                }
                .help("Play / Stop (Space)")
                Button { daw.toggleRecord() } label: {
                    Image(systemName: "record.circle").foregroundStyle(daw.isRecording ? .red : .primary)
                }
                .help("Record (R) — arm a track first")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !daw.isPlaying)) { _ in
                let beat = daw.currentBeat()
                VStack(alignment: .leading, spacing: 0) {
                    Text(Music.barsBeats(beat, beatsPerBar: p.beatsPerBar))
                        .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    Text(timeString(beat * daw.secondsPerBeat)).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                .frame(width: 92, alignment: .leading)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))

            HStack(spacing: 4) {
                TextField("BPM", value: Binding(get: { p.bpm }, set: { v in daw.edit { $0.bpm = max(40, min(240, v)) } }),
                          format: .number.precision(.fractionLength(0...1)))
                    .frame(width: 50).textFieldStyle(.roundedBorder)
                Text("BPM").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { p.beatsPerBar }, set: { v in daw.edit { $0.beatsPerBar = v } })) {
                    ForEach([3, 4, 6, 7], id: \.self) { Text("\($0)/4").tag($0) }
                }
                .labelsHidden().frame(width: 62)
            }

            Divider().frame(height: 26)

            Toggle(isOn: Binding(get: { p.loopEnabled }, set: { v in daw.edit { $0.loopEnabled = v } })) {
                Image(systemName: "repeat")
            }
            .toggleStyle(.button).help("Loop")
            if p.loopEnabled {
                barField("From", value: p.loopStart) { b in daw.edit { $0.loopStart = b; if $0.loopEnd <= b { $0.loopEnd = b + $0.barLength } } }
                barField("To", value: p.loopEnd) { b in daw.edit { $0.loopEnd = max($0.loopStart + 1, b) } }
            }
            Toggle(isOn: Binding(get: { p.metronome }, set: { v in daw.edit { $0.metronome = v } })) {
                Image(systemName: "metronome")
            }
            .toggleStyle(.button).help("Click")
            Toggle(isOn: Binding(get: { p.countIn }, set: { v in daw.edit { $0.countIn = v } })) {
                Text("1 bar")
            }
            .toggleStyle(.button).help("Count-in before recording")

            Picker("Snap", selection: Binding(get: { p.snap }, set: { v in daw.edit { $0.snap = v } })) {
                Text("1 bar").tag(Double(p.beatsPerBar))
                Text("1/4").tag(1.0)
                Text("1/8").tag(0.5)
                Text("1/16").tag(0.25)
                Text("1/32").tag(0.125)
            }
            .frame(width: 112)

            Picker("Key", selection: Binding(get: { p.keyRoot * 2 + (p.keyIsMinor ? 1 : 0) },
                                             set: { v in daw.edit { $0.keyRoot = v / 2; $0.keyIsMinor = v % 2 == 1 } })) {
                ForEach(0..<24, id: \.self) { i in
                    Text("\(Music.noteNames[i / 2]) \(i % 2 == 1 ? "min" : "maj")").tag(i)
                }
            }
            .frame(width: 118)

            Spacer(minLength: 4)

            Button { daw.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!daw.canUndo).help("Undo (⌥⌘Z)")
            Button { daw.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!daw.canRedo).help("Redo (⇧⌥⌘Z)")

            Menu {
                Button("Audio Track") { daw.addTrack(kind: .audio) }
                Menu("Vocal Track (with your live Auto-Tune rack)") {
                    ForEach(VocalTrackPreset.allCases) { v in
                        Button { daw.addVocalTrack(v, rack: store.show.vocalRack) } label: { Label(v.rawValue, systemImage: v.symbol) }
                    }
                }
                Divider()
                Button("Synth") { daw.addTrack(kind: .midi, instrument: .synth(preset: "Lead"), name: "Synth") }
                Button("Drum Machine") { daw.addTrack(kind: .midi, instrument: .drumMachine(kit: "Dancehall"), name: "Drums") }
                Button("Piano & Instruments (GM)") { daw.addTrack(kind: .midi, instrument: .generalMIDI(program: 0), name: "Piano") }
                Button("Sampler from File…") {
                    if let url = pickAudio() { daw.addTrack(kind: .midi, instrument: .sampler(path: url.path), name: url.deletingPathExtension().lastPathComponent) }
                }
                if !daw.instrumentComponents.isEmpty {
                    Menu("Plug-in Instrument") {
                        ForEach(daw.instrumentComponents, id: \.self) { c in
                            Button("\(c.manufacturerName) — \(c.name)") {
                                daw.addTrack(kind: .midi, instrument: .audioUnit(PluginSlot(component: c)), name: c.name)
                            }
                        }
                    }
                }
            } label: { Label("Track", systemImage: "plus") }
            .fixedSize()

            Button { if let url = pickAudio() { daw.addAudioClip(url: url, trackID: daw.track(daw.selectedTrackID)?.kind == .audio ? daw.selectedTrackID : nil, at: daw.snap(daw.playhead)) } } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .help("Import audio or video at the playhead")

            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: $zoom, in: 6...80).frame(width: 80)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .overlay(alignment: .topLeading) {
            if daw.isRecording { Rectangle().fill(.red).frame(height: 2) }
        }
    }

    private func barField(_ label: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("", value: Binding(get: { Int(value / Double(p.beatsPerBar)) + 1 },
                                         set: { v in set(Double(max(1, v) - 1) * Double(p.beatsPerBar)) }),
                      format: .number)
                .frame(width: 34).textFieldStyle(.roundedBorder)
        }
    }

    private func timeString(_ s: Double) -> String {
        let t = max(0, s)
        return String(format: "%d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }
}

func pickAudio() -> URL? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = MediaSupport.audioTypes + MediaSupport.videoTypes
    panel.allowsMultipleSelection = false
    return panel.runModal() == .OK ? panel.url : nil
}

// MARK: - Arrangement

struct ArrangementView: View {
    @EnvironmentObject var daw: DAWEngine
    let zoom: Double
    var onOpenClip: () -> Void

    static let rowHeight: CGFloat = 66
    static let headerWidth: CGFloat = 230
    static let rulerHeight: CGFloat = 24

    var body: some View {
        let p = daw.project
        let totalBeats = max(64 * Double(p.beatsPerBar) / 4, (p.contentEnd + Double(p.beatsPerBar) * 16))
        let width = CGFloat(totalBeats * zoom)
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: Self.rulerHeight)
                    if p.mix != nil {
                        ShowMixHeader().frame(height: ShowMixLanes.total)
                        Divider()
                    }
                    ForEach(p.tracks) { t in
                        TrackHeader(track: t).frame(height: Self.rowHeight)
                        Divider()
                    }
                    addRow
                }
                .frame(width: Self.headerWidth)
                .background(Color(nsColor: .controlBackgroundColor))
                Divider()
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        TimelineRuler(zoom: zoom, totalBeats: totalBeats).frame(width: width, height: Self.rulerHeight)
                        if p.mix != nil {
                            ShowMixLanes(zoom: zoom, width: width).frame(width: width, height: ShowMixLanes.total, alignment: .topLeading)
                            Divider()
                        }
                        ForEach(p.tracks) { t in
                            TrackLane(track: t, zoom: zoom, width: width, onOpenClip: onOpenClip)
                                .frame(width: width, height: Self.rowHeight)
                            Divider()
                        }
                        Color.clear.frame(width: width, height: 44)
                    }
                    .overlay(alignment: .topLeading) { PlayheadLine(zoom: zoom).allowsHitTesting(false) }
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .onDeleteCommand { daw.deleteSelectedClip() }
        .background {
            Group {
                Button("") { daw.deleteSelectedClip() }.keyboardShortcut(.delete, modifiers: [])
                Button("") { daw.duplicateSelectedClip() }.keyboardShortcut("d", modifiers: [.command])
                Button("") { daw.splitSelectedAtPlayhead() }.keyboardShortcut("e", modifiers: [.command])
            }
            .opacity(0).allowsHitTesting(false)
        }
    }

    private var addRow: some View {
        HStack {
            Button { daw.addTrack(kind: .audio) } label: { Label("Audio", systemImage: "waveform") }
            Button { daw.addTrack(kind: .midi, instrument: .synth(preset: "Lead"), name: "Synth") } label: { Label("Synth", systemImage: "pianokeys") }
            Button { daw.addTrack(kind: .midi, instrument: .drumMachine(kit: "Dancehall"), name: "Drums") } label: { Label("Drums", systemImage: "square.grid.4x3.fill") }
        }
        .buttonStyle(.borderless).font(.caption)
        .frame(height: 44)
    }
}

struct PlayheadLine: View {
    @EnvironmentObject var daw: DAWEngine
    let zoom: Double
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !daw.isPlaying)) { _ in
            let x = CGFloat(daw.currentBeat() * zoom)
            Rectangle().fill(daw.isRecording ? Color.red : Color.white)
                .frame(width: 1.5)
                .frame(maxHeight: .infinity)
                .offset(x: x)
        }
    }
}

struct TimelineRuler: View {
    @EnvironmentObject var daw: DAWEngine
    let zoom: Double
    let totalBeats: Double

    var body: some View {
        let p = daw.project
        Canvas { ctx, size in
            let bpb = Double(p.beatsPerBar)
            if p.loopEnabled {
                let r = CGRect(x: p.loopStart * zoom, y: 0, width: (p.loopEnd - p.loopStart) * zoom, height: size.height)
                ctx.fill(Path(r), with: .color(.yellow.opacity(0.25)))
            }
            let barStep = zoom * bpb < 28 ? (zoom * bpb < 14 ? 4 : 2) : 1
            var bar = 0
            while Double(bar) * bpb < totalBeats {
                let x = Double(bar) * bpb * zoom
                ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: size.height * 0.45)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                           with: .color(.secondary), lineWidth: 1)
                if bar % barStep == 0 {
                    ctx.draw(Text("\(bar + 1)").font(.caption2).foregroundColor(.secondary), at: CGPoint(x: x + 3, y: 7), anchor: .leading)
                }
                bar += 1
            }
        }
        .background(Color.black.opacity(0.25))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onEnded { v in
            daw.seek(to: daw.snap(max(0, Double(v.location.x) / zoom)))
        })
        .help("Click to move the playhead")
    }
}

struct TrackHeader: View {
    @EnvironmentObject var daw: DAWEngine
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var audio: AudioEngine
    let track: DAWTrack

    var body: some View {
        let selected = daw.selectedTrackID == track.id
        HStack(spacing: 6) {
            Rectangle().fill(track.color.color).frame(width: 5)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: track.kind == .audio ? "waveform" : (track.instrument?.isDrums == true ? "square.grid.4x3.fill" : "pianokeys"))
                        .foregroundStyle(track.color.color).font(.caption)
                    TextField("Name", text: Binding(get: { track.name }, set: { v in daw.updateTrack(track.id) { $0.name = v } }))
                        .textFieldStyle(.plain).font(.callout.weight(.semibold))
                }
                HStack(spacing: 3) {
                    small("M", on: track.mute, color: .orange) { daw.updateTrack(track.id) { $0.mute.toggle() } }
                    small("S", on: track.solo, color: .yellow) { daw.updateTrack(track.id) { $0.solo.toggle() } }
                    small("R", on: track.armed, color: .red) { daw.updateTrack(track.id) { $0.armed.toggle() } }
                    Slider(value: Binding(get: { track.volumeDB }, set: { v in daw.updateTrack(track.id) { $0.volumeDB = v } }), in: -60...6)
                        .controlSize(.mini)
                }
                LevelBar(level: daw.levels[track.id] ?? 0).frame(height: 3)
                Text(track.kind == .audio ? "Audio · In \(track.inputChannel + 1)" : (track.instrument?.label ?? "Instrument"))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.vertical, 5).padding(.trailing, 6)
        }
        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { daw.selectedTrackID = track.id }
        .contextMenu {
            Button("Duplicate Track") { daw.duplicateTrack(track.id) }
            Menu("Color") {
                ForEach(TrackColor.allCases, id: \.self) { c in Button(c.rawValue.capitalized) { daw.updateTrack(track.id) { $0.color = c } } }
            }
            if track.kind == .audio {
                Button(track.monitor ? "Input Monitoring Off" : "Input Monitoring On") { daw.updateTrack(track.id) { $0.monitor.toggle() } }
                Button("Load Live Vocal Rack chain") {
                    let rack = store.show.vocalRack
                    daw.updateTrack(track.id) { t in
                        t.effects = rack.plugins.map { var p = $0; p.id = UUID(); return p } + t.effects.filter { $0.componentManufacturer == kAudioUnitManufacturer_Apple }
                        t.inputChannel = rack.inputChannel
                    }
                }
                Button("Send this chain to the Live Vocal Rack") {
                    store.show.vocalRack.plugins = track.effects.map { var p = $0; p.id = UUID(); return p }
                    audio.loadVocalRack()
                }
                if let n = track.takes?.count, n > 0 { Text("\(n) earlier take\(n == 1 ? "" : "s") — right-click a clip to swap") }
                Menu("Record Input") {
                    ForEach(0..<16, id: \.self) { i in Button("Input \(i + 1)") { daw.updateTrack(track.id) { $0.inputChannel = i } } }
                }
            } else {
                Button("Open Instrument Window") { daw.openInstrumentEditor(trackID: track.id) }
            }
            Divider()
            Button("Delete Track", role: .destructive) { daw.deleteTrack(track.id) }
        }
    }

    private func small(_ t: String, on: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.caption2.weight(.bold)).frame(width: 16, height: 15)
                .background(RoundedRectangle(cornerRadius: 3).fill(on ? color : Color.gray.opacity(0.25)))
                .foregroundStyle(on ? Color.black : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

struct LevelBar: View {
    let level: Float
    var body: some View {
        GeometryReader { g in
            let db = 20 * log10(Double(max(level, 0.00001)))
            let f = max(0, min(1, (db + 60) / 60))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.4))
                Capsule().fill(LinearGradient(colors: [.green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                    .frame(width: g.size.width * f)
            }
        }
    }
}

struct TrackLane: View {
    @EnvironmentObject var daw: DAWEngine
    let track: DAWTrack
    let zoom: Double
    let width: CGFloat
    var onOpenClip: () -> Void
    @State private var dropHover = false

    var body: some View {
        let p = daw.project
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                let bpb = Double(p.beatsPerBar)
                var bar = 0
                while Double(bar) * bpb * zoom < Double(size.width) {
                    let x = Double(bar) * bpb * zoom
                    ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                               with: .color(.white.opacity(bar % 4 == 0 ? 0.12 : 0.05)), lineWidth: 1)
                    bar += 1
                }
            }
            .background(daw.selectedTrackID == track.id ? Color.white.opacity(0.04) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, coordinateSpace: .local) { loc in
                if track.kind == .midi {
                    daw.newMIDIClip(trackID: track.id, at: Double(loc.x) / zoom)
                    onOpenClip()
                }
            }
            .onTapGesture { daw.selectedTrackID = track.id; daw.selectedClipID = nil }

            ForEach(track.midiClips) { c in
                ClipView(clipID: c.id, start: c.start, length: c.length, name: c.name, color: track.color.color,
                         zoom: zoom, height: ArrangementView.rowHeight, trackID: track.id, onOpen: onOpenClip) {
                    MIDIClipPreview(clip: c)
                }
            }
            ForEach(track.audioClips) { c in
                let alts = (track.takes ?? []).filter { $0.start < c.start + c.length && $0.start + $0.length > c.start }
                ClipView(clipID: c.id, start: c.start, length: c.length, name: c.name, color: track.color.color,
                         zoom: zoom, height: ArrangementView.rowHeight, trackID: track.id, onOpen: onOpenClip) {
                    WaveformPreview(clip: c, zoom: zoom)
                        .overlay(alignment: .topTrailing) {
                            if !alts.isEmpty {
                                Text("\(alts.count + 1) takes").font(.system(size: 8, weight: .bold)).padding(2)
                                    .background(Capsule().fill(Color.black.opacity(0.5))).padding(3)
                            }
                        }
                }
            }
            if dropHover { Rectangle().stroke(Color.accentColor, lineWidth: 2) }
        }
        .clipped()
        .dropDestination(for: URL.self) { urls, loc in
            guard track.kind == .audio || track.instrument?.isDrums == false else { return false }
            var beat = daw.snap(Double(loc.x) / zoom)
            for url in urls {
                daw.addAudioClip(url: url, trackID: track.kind == .audio ? track.id : nil, at: beat)
                beat += Double(daw.project.beatsPerBar) * 4
            }
            return true
        } isTargeted: { dropHover = $0 }
    }
}

struct ClipView<Content: View>: View {
    @EnvironmentObject var daw: DAWEngine
    let clipID: UUID
    let start: Double
    let length: Double
    let name: String
    let color: Color
    let zoom: Double
    let height: CGFloat
    let trackID: UUID
    var onOpen: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var dragBeats: Double = 0
    @State private var resizeBeats: Double = 0

    var body: some View {
        let selected = daw.selectedClipID == clipID
        let len = max(0.25, length + resizeBeats)
        let w = CGFloat(len * zoom)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.32))
            content().padding(.top, 15).padding(.horizontal, 2).padding(.bottom, 2)
            Text(name).font(.caption2.weight(.semibold)).lineLimit(1).padding(.horizontal, 5).padding(.top, 2)
            RoundedRectangle(cornerRadius: 5).stroke(selected ? Color.white : color, lineWidth: selected ? 2 : 1)
            // resize handle
            HStack { Spacer(); Rectangle().fill(Color.white.opacity(0.001)).frame(width: 8) }
                .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { v in resizeBeats = daw.snap(Double(v.translation.width) / zoom) }
                    .onEnded { _ in
                        daw.resizeClip(clipID, length: max(daw.project.snap, length + resizeBeats))
                        resizeBeats = 0
                    })
        }
        .frame(width: max(6, w), height: height - 6)
        .offset(x: CGFloat((start + dragBeats) * zoom), y: 3)
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { v in
                daw.selectedClipID = clipID
                dragBeats = daw.snap(Double(v.translation.width) / zoom)
            }
            .onEnded { _ in
                daw.moveClip(clipID, toStart: max(0, start + dragBeats))
                dragBeats = 0
            })
        .onTapGesture(count: 2) { daw.selectedClipID = clipID; daw.selectedTrackID = trackID; onOpen() }
        .onTapGesture { daw.selectedClipID = clipID; daw.selectedTrackID = trackID }
        .contextMenu {
            let track = daw.project.tracks.first { $0.id == trackID }
            let alts = (track?.takes ?? []).filter { $0.start < start + length && $0.start + $0.length > start }
            if !alts.isEmpty {
                Section("Takes (playlists)") {
                    ForEach(Array(alts.enumerated()), id: \.element.id) { i, t in
                        Button("Use take \(i + 1): \(t.name)") { daw.useTake(t.id, replacing: clipID, trackID: trackID) }
                    }
                }
                Divider()
            }
            Button("Edit") { daw.selectedClipID = clipID; onOpen() }
            Button("Duplicate (⌘D)") { daw.selectedClipID = clipID; daw.duplicateSelectedClip() }
            Button("Split at Playhead (⌘E)") { daw.selectedClipID = clipID; daw.splitSelectedAtPlayhead() }
            Button("Set Loop to Clip") { daw.edit { $0.loopStart = start; $0.loopEnd = start + length; $0.loopEnabled = true } }
            Divider()
            Button("Delete", role: .destructive) { daw.selectedClipID = clipID; daw.deleteSelectedClip() }
        }
    }
}

struct MIDIClipPreview: View {
    let clip: MIDIClip
    var body: some View {
        Canvas { ctx, size in
            guard !clip.notes.isEmpty, clip.length > 0 else { return }
            let lo = clip.notes.map(\.pitch).min() ?? 60, hi = max(lo + 6, clip.notes.map(\.pitch).max() ?? 72)
            let range = Double(hi - lo + 1)
            let rowH = max(1.5, Double(size.height) / range)
            for n in clip.notes where n.start < clip.length {
                let x = n.start / clip.length * Double(size.width)
                let w = max(2, min(n.length, clip.length - n.start) / clip.length * Double(size.width))
                let y = Double(size.height) - Double(n.pitch - lo + 1) * Double(size.height) / range
                ctx.fill(Path(CGRect(x: x, y: y, width: w, height: rowH)), with: .color(.white.opacity(0.85)))
            }
        }
    }
}

struct WaveformPreview: View {
    @EnvironmentObject var daw: DAWEngine
    let clip: AudioClip
    let zoom: Double
    var body: some View {
        Canvas { ctx, size in
            guard let peaks = daw.peaks(path: clip.path), !peaks.isEmpty else { return }
            let sr = daw.sampleRate
            let framesPerPeak = 512.0
            let mid = Double(size.height) / 2
            var path = Path()
            let cols = Int(size.width)
            for x in 0..<max(1, cols) {
                let beat = Double(x) / zoom
                let frame = clip.fileOffset * sr + beat * daw.samplesPerBeat
                let i = Int(frame / framesPerPeak)
                guard i >= 0, i < peaks.count else { continue }
                let a = Double(peaks[i]) * mid * AudioEngine.linearD(clip.gainDB)
                path.addRect(CGRect(x: Double(x), y: mid - a, width: 1, height: max(0.5, a * 2)))
            }
            ctx.fill(path, with: .color(.white.opacity(0.75)))
        }
    }
}

extension AudioEngine {
    nonisolated static func linearD(_ db: Double) -> Double { pow(10, db / 20) }
}


/// Pro Tools-style I/O + vocal setup inside the Studio: interface, buffer, master EQ and the live vocal rack.
struct StudioVocalsPanel: View {
    var onAdded: () -> Void = {}
    @EnvironmentObject var daw: DAWEngine
    @EnvironmentObject var store: ShowStore
    @State private var showPTImport = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("New vocal track:").font(.caption.weight(.semibold))
                ForEach(VocalTrackPreset.allCases) { v in
                    Button { daw.addVocalTrack(v, rack: store.show.vocalRack); onAdded() } label: { Label(v.rawValue, systemImage: v.symbol) }
                        .controlSize(.small)
                }
                Button { showPTImport = true } label: { Label("Import chain from Pro Tools…", systemImage: "square.and.arrow.down.on.square") }
                    .controlSize(.small).tint(.pink)
                Spacer()
                Text("Opens in Arrange armed and monitoring, with your live rack (Auto-Tune…) then HPF / comp / EQ.")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(8)
            Divider()
            AudioView()
        }
        .sheet(isPresented: $showPTImport) { ProToolsImportSheet() }
    }
}
