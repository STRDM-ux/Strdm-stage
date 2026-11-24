import SwiftUI
import AppKit

/// Bottom "Editor" tab: piano roll, drum step sequencer or audio clip settings.
struct ClipEditorPanel: View {
    @EnvironmentObject var daw: DAWEngine

    var body: some View {
        if let track = daw.selectedClipTrack, let id = daw.selectedClipID {
            if let clip = track.midiClips.first(where: { $0.id == id }) {
                if track.instrument?.isDrums == true {
                    StepSequencerView(track: track, clip: clip)
                } else {
                    PianoRollView(track: track, clip: clip)
                }
            } else if let clip = track.audioClips.first(where: { $0.id == id }) {
                AudioClipInspector(track: track, clip: clip)
            }
        } else if let t = daw.track(daw.selectedTrackID), t.kind == .midi {
            VStack(spacing: 10) {
                Text("No clip selected on \(t.name)").font(.headline)
                Text("Double-click the track lane to draw a clip, or press R to record from your MIDI keyboard / computer keys (A–K, Z/X octave).")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("New 4-bar Clip at Playhead") { daw.newMIDIClip(trackID: t.id, at: daw.playhead) }
                    .buttonStyle(.borderedProminent)
            }
            .padding().frame(maxWidth: 520)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "pianokeys").font(.largeTitle).foregroundStyle(.secondary)
                Text("Select a clip to edit it").font(.headline)
                Text("Drop audio or video onto an audio track · double-click an instrument lane for a new clip")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Piano roll

struct PianoRollView: View {
    @EnvironmentObject var daw: DAWEngine
    let track: DAWTrack
    let clip: MIDIClip

    @State private var zoom: Double = 70        // px per beat
    @State private var drag: DragState?
    @State private var newLength: Double = 0.5
    @State private var scaleOnly = false

    private let rowH: CGFloat = 13
    private let keysW: CGFloat = 46
    private let lowPitch = 24
    private let highPitch = 108

    struct DragState {
        var noteID: UUID?
        var mode: Mode
        var original: MIDINote
        var current: MIDINote
        enum Mode { case create, move, resize }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView([.horizontal, .vertical]) {
                HStack(spacing: 0) {
                    keyboard
                    grid
                }
            }
            .defaultScrollAnchor(UnitPoint(x: 0, y: 0.55))
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(track.name).font(.headline)
            TextField("Clip", text: Binding(get: { clip.name }, set: { v in daw.updateClip(clip.id) { $0.name = v } }))
                .frame(width: 110).textFieldStyle(.roundedBorder)
            Text("\(clip.notes.count) notes").font(.caption).foregroundStyle(.secondary)
            Picker("Draw", selection: $newLength) {
                Text("1/16").tag(0.25); Text("1/8").tag(0.5); Text("1/4").tag(1.0); Text("1/2").tag(2.0); Text("1 bar").tag(4.0)
            }
            .frame(width: 120)
            Toggle("Scale only", isOn: $scaleOnly).toggleStyle(.checkbox)
                .help("Highlight and snap new notes to \(Music.noteNames[daw.project.keyRoot]) \(daw.project.keyIsMinor ? "minor" : "major")")
            Button("Quantize") { daw.quantize(clipID: clip.id) }
            Button { daw.updateClip(clip.id) { c in for i in c.notes.indices { c.notes[i].pitch = min(127, c.notes[i].pitch + 12) } } } label: { Text("+8va") }
            Button { daw.updateClip(clip.id) { c in for i in c.notes.indices { c.notes[i].pitch = max(0, c.notes[i].pitch - 12) } } } label: { Text("−8va") }
            Button("Clear") { daw.updateClip(clip.id) { $0.notes.removeAll() } }
            Spacer()
            Text("Click: add · click note: delete · drag: move · drag end: length").font(.caption).foregroundStyle(.secondary)
            Slider(value: $zoom, in: 20...200).frame(width: 90)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
    }

    private var rows: Int { highPitch - lowPitch + 1 }
    private func y(for pitch: Int) -> CGFloat { CGFloat(highPitch - pitch) * rowH }
    private func pitch(at y: CGFloat) -> Int { max(lowPitch, min(highPitch, highPitch - Int(y / rowH))) }

    private var keyboard: some View {
        VStack(spacing: 0) {
            ForEach((lowPitch...highPitch).reversed(), id: \.self) { p in
                let black = [1, 3, 6, 8, 10].contains(p % 12)
                ZStack(alignment: .trailing) {
                    Rectangle().fill(black ? Color.black : Color.white.opacity(0.85))
                    if p % 12 == 0 { Text(Music.name(p)).font(.system(size: 8)).foregroundStyle(.black).padding(.trailing, 2) }
                }
                .frame(width: keysW, height: rowH)
                .overlay(Rectangle().stroke(Color.gray.opacity(0.4), lineWidth: 0.5))
                .onTapGesture { daw.audition(pitch: p) }
            }
        }
    }

    private var grid: some View {
        let p = daw.project
        let width = CGFloat(clip.length * zoom)
        let height = CGFloat(rows) * rowH
        return Canvas { ctx, size in
            // rows
            for pitch in lowPitch...highPitch {
                let black = [1, 3, 6, 8, 10].contains(pitch % 12)
                let inKey = Music.inScale(pitch, root: p.keyRoot, minor: p.keyIsMinor)
                let r = CGRect(x: 0, y: y(for: pitch), width: size.width, height: rowH)
                var c = black ? Color.black.opacity(0.35) : Color.white.opacity(0.04)
                if scaleOnly && inKey { c = Color.accentColor.opacity(0.12) }
                ctx.fill(Path(r), with: .color(c))
                if pitch % 12 == 0 {
                    ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: r.maxY)); $0.addLine(to: CGPoint(x: size.width, y: r.maxY)) },
                               with: .color(.white.opacity(0.2)), lineWidth: 1)
                }
            }
            // beat lines
            let snap = max(0.125, p.snap)
            var b = 0.0
            while b <= clip.length + 0.001 {
                let x = b * zoom
                let isBar = abs(b.truncatingRemainder(dividingBy: Double(p.beatsPerBar))) < 0.001
                let isBeat = abs(b - b.rounded()) < 0.001
                ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                           with: .color(.white.opacity(isBar ? 0.35 : (isBeat ? 0.15 : 0.05))), lineWidth: 1)
                b += snap
            }
            // notes
            let shown: [MIDINote] = clip.notes.compactMap { n in
                if let d = drag, d.noteID == n.id { return d.current }
                return n
            } + ((drag?.mode == .create) ? [drag!.current] : [])
            for n in shown {
                let r = CGRect(x: n.start * zoom, y: y(for: n.pitch) + 1, width: max(3, n.length * zoom - 1), height: rowH - 2)
                ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(track.color.color.opacity(0.4 + 0.6 * Double(n.velocity) / 127)))
                ctx.stroke(Path(roundedRect: r, cornerRadius: 2), with: .color(.white.opacity(0.7)), lineWidth: 0.5)
            }
            // playhead
            let local = daw.currentBeat() - clip.start
            if local >= 0 && local <= clip.length {
                ctx.fill(Path(CGRect(x: local * zoom, y: 0, width: 1.5, height: size.height)), with: .color(.white))
            }
        }
        .frame(width: max(width, 200), height: height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged(changed).onEnded(ended))
        .overlay {
            if daw.isPlaying {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                    let local = daw.currentBeat() - clip.start
                    Rectangle().fill(Color.white).frame(width: 1.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .offset(x: CGFloat(max(0, min(clip.length, local)) * zoom))
                        .opacity(local >= 0 && local <= clip.length ? 1 : 0)
                }
                .allowsHitTesting(false)
            }
        }
    }

    private func snapBeat(_ b: Double) -> Double { daw.snap(b) }
    private func floorSnap(_ b: Double) -> Double { let s = max(0.0625, daw.project.snap); return floor(b / s) * s }

    private func hit(_ loc: CGPoint) -> (MIDINote, Bool)? {
        let beat = Double(loc.x) / zoom
        let p = pitch(at: loc.y)
        for n in clip.notes.reversed() where n.pitch == p && beat >= n.start && beat <= n.start + n.length {
            let nearEnd = (n.start + n.length - beat) * zoom < 7
            return (n, nearEnd)
        }
        return nil
    }

    private func changed(_ v: DragGesture.Value) {
        if drag == nil {
            if let (n, nearEnd) = hit(v.startLocation) {
                drag = DragState(noteID: n.id, mode: nearEnd ? .resize : .move, original: n, current: n)
            } else {
                var pitch = pitch(at: v.startLocation.y)
                if scaleOnly {
                    let pr = daw.project
                    while !Music.inScale(pitch, root: pr.keyRoot, minor: pr.keyIsMinor) && pitch > lowPitch { pitch -= 1 }
                }
                let start = min(clip.length - 0.0625, max(0, floorSnap(Double(v.startLocation.x) / zoom)))
                let n = MIDINote(pitch: pitch, start: start, length: newLength, velocity: 100)
                drag = DragState(noteID: nil, mode: .create, original: n, current: n)
                daw.audition(pitch: pitch, length: 0.15)
            }
        }
        guard var d = drag else { return }
        let dx = Double(v.translation.width) / zoom
        switch d.mode {
        case .create, .resize:
            d.current.length = max(max(0.0625, daw.project.snap), snapBeat(d.original.length + dx))
        case .move:
            d.current.start = max(0, min(clip.length - 0.0625, snapBeat(d.original.start + dx)))
            let newPitch = pitch(at: y(for: d.original.pitch) + v.translation.height + rowH / 2)
            if newPitch != d.current.pitch { daw.audition(pitch: newPitch, length: 0.12) }
            d.current.pitch = newPitch
        }
        drag = d
    }

    private func ended(_ v: DragGesture.Value) {
        guard let d = drag else { return }
        drag = nil
        let moved = abs(v.translation.width) > 2 || abs(v.translation.height) > 2
        switch d.mode {
        case .create:
            let note = d.current
            daw.updateClip(clip.id) { $0.notes.append(note) }
        case .move, .resize:
            guard let id = d.noteID else { return }
            if !moved && d.mode == .move {
                daw.updateClip(clip.id) { $0.notes.removeAll { $0.id == id } }
            } else {
                let note = d.current
                daw.updateClip(clip.id) { c in if let i = c.notes.firstIndex(where: { $0.id == id }) { c.notes[i] = note } }
            }
        }
    }
}

// MARK: - Drum step sequencer

struct StepSequencerView: View {
    @EnvironmentObject var daw: DAWEngine
    let track: DAWTrack
    let clip: MIDIClip
    @State private var stepSize: Double = 0.25

    var body: some View {
        let steps = min(128, max(1, Int((clip.length / stepSize).rounded())))
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(track.name).font(.headline)
                Picker("Kit", selection: Binding(get: {
                    if case .drumMachine(let k)? = track.instrument { return k }
                    return DrumKits.names[0]
                }, set: { k in daw.updateTrack(track.id) { $0.instrument = .drumMachine(kit: k) } })) {
                    ForEach(DrumKits.names, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 170)
                Picker("Steps", selection: $stepSize) {
                    Text("1/16").tag(0.25); Text("1/8").tag(0.5); Text("1/32").tag(0.125)
                }
                .frame(width: 120)
                Picker("Length", selection: Binding(get: { clip.length }, set: { v in daw.resizeClip(clip.id, length: v) })) {
                    Text("1 bar").tag(Double(daw.project.beatsPerBar))
                    Text("2 bars").tag(Double(daw.project.beatsPerBar * 2))
                    Text("4 bars").tag(Double(daw.project.beatsPerBar * 4))
                    Text("8 bars").tag(Double(daw.project.beatsPerBar * 8))
                }
                .frame(width: 130)
                Menu("Patterns") {
                    Button("One Drop (Dancehall/Reggae)") { applyPattern(.oneDrop) }
                    Button("Dembow") { applyPattern(.dembow) }
                    Button("Trap Hats") { applyPattern(.trap) }
                    Button("Afrobeats") { applyPattern(.afro) }
                    Button("Four on the Floor") { applyPattern(.house) }
                }
                .fixedSize()
                Button("Clear") { daw.updateClip(clip.id) { $0.notes.removeAll() } }
                Spacer()
                Text("Click a step · ⇧-click for accent · click a pad name to hear it").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !daw.isPlaying)) { _ in
                    let local = daw.currentBeat() - clip.start
                    let playStep = daw.isPlaying && local >= 0 && local < clip.length ? Int(local / stepSize) : -1
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(DrumKits.pads, id: \.note) { pad in
                            HStack(spacing: 3) {
                                padLabel(pad.note, pad.name)
                                ForEach(0..<steps, id: \.self) { s in
                                    cell(note: pad.note, step: s, playing: s == playStep)
                                }
                            }
                        }
                    }
                    .padding(8)
                }
            }
        }
    }

    private func padLabel(_ note: Int, _ name: String) -> some View {
        let custom = track.padSamples[note]
        return HStack(spacing: 4) {
            Text(custom.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? name)
                .font(.caption).lineLimit(1)
                .foregroundStyle(custom == nil ? Color.primary : Color.accentColor)
            Spacer(minLength: 0)
            Menu {
                Button("Load Sample…") {
                    if let url = pickAudio() { daw.updateTrack(track.id) { $0.padSamples[note] = url.path } }
                }
                if custom != nil { Button("Use Kit Sound") { daw.updateTrack(track.id) { $0.padSamples[note] = nil } } }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).frame(width: 18)
        }
        .frame(width: 118, height: 22)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06)))
        .contentShape(Rectangle())
        .onTapGesture { daw.audition(pitch: note, velocity: 115, length: 0.1) }
    }

    private func cell(note: Int, step: Int, playing: Bool) -> some View {
        let beat = Double(step) * stepSize
        let hitNote = clip.notes.first { $0.pitch == note && abs($0.start - beat) < stepSize / 2 }
        let downbeat = step % Int((1 / stepSize).rounded() * 1) == 0
        let barStart = Int((Double(daw.project.beatsPerBar) / stepSize).rounded())
        return RoundedRectangle(cornerRadius: 3)
            .fill(hitNote != nil ? track.color.color.opacity(0.45 + 0.55 * Double(hitNote!.velocity) / 127)
                  : Color.white.opacity(downbeat ? 0.13 : 0.06))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(playing ? Color.white : Color.clear, lineWidth: 1.5))
            .frame(width: 20, height: 22)
            .padding(.leading, barStart > 0 && step % barStart == 0 && step > 0 ? 5 : 0)
            .contentShape(Rectangle())
            .onTapGesture {
                let accent = NSEvent.modifierFlags.contains(.shift)
                if hitNote == nil { daw.audition(pitch: note, velocity: accent ? 127 : 100, length: 0.08) }
                daw.updateClip(clip.id) { c in
                    if let i = c.notes.firstIndex(where: { $0.pitch == note && abs($0.start - beat) < stepSize / 2 }) {
                        c.notes.remove(at: i)
                    } else {
                        c.notes.append(MIDINote(pitch: note, start: beat, length: stepSize, velocity: accent ? 127 : 100))
                    }
                }
            }
    }

    enum Pattern { case oneDrop, dembow, trap, afro, house }

    private func applyPattern(_ pattern: Pattern) {
        let bars = max(1, Int(clip.length / Double(daw.project.beatsPerBar)))
        var notes: [MIDINote] = []
        func add(_ pitch: Int, _ beats: [Double], vel: Int = 100) {
            for bar in 0..<bars {
                for b in beats { notes.append(MIDINote(pitch: pitch, start: Double(bar * daw.project.beatsPerBar) + b, length: 0.25, velocity: vel)) }
            }
        }
        switch pattern {
        case .oneDrop:
            add(36, [2]); add(37, [2], vel: 110)
            add(42, stride(from: 0.0, to: 4, by: 0.5).map { $0 + 0.5 }.filter { $0 < 4 }, vel: 80)
        case .dembow:
            add(36, [0, 1, 2, 3]); add(38, [0.75, 1.5, 2.75, 3.5], vel: 112)
            add(42, stride(from: 0.0, to: 4, by: 0.5).map { $0 }, vel: 75)
        case .trap:
            add(35, [0, 2.5]); add(39, [1, 3], vel: 115)
            add(42, stride(from: 0.0, to: 4, by: 0.25).map { $0 }, vel: 78)
            add(46, [3.5], vel: 90)
        case .afro:
            add(36, [0, 1.5, 2, 3.5]); add(37, [1, 2.75], vel: 105)
            add(54, stride(from: 0.0, to: 4, by: 0.25).map { $0 }, vel: 70)
            add(56, [0.5, 2.5], vel: 85)
        case .house:
            add(36, [0, 1, 2, 3]); add(39, [1, 3], vel: 108)
            add(46, [0.5, 1.5, 2.5, 3.5], vel: 88)
        }
        notes = notes.filter { $0.start < clip.length }
        daw.updateClip(clip.id) { $0.notes = notes }
    }
}

// MARK: - Audio clip

struct AudioClipInspector: View {
    @EnvironmentObject var daw: DAWEngine
    let track: DAWTrack
    let clip: AudioClip

    var body: some View {
        Form {
            Section("\(clip.name) on \(track.name)") {
                LabeledContent("File") {
                    HStack {
                        Text(clip.path).font(.caption).lineLimit(1).truncationMode(.middle)
                        Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: clip.path)]) }
                    }
                }
                slider("Gain", clip.gainDB, -24...12, "dB") { v in set { $0.gainDB = v } }
                slider("Fade in", clip.fadeIn, 0...8, "beats") { v in set { $0.fadeIn = v } }
                slider("Fade out", clip.fadeOut, 0...8, "beats") { v in set { $0.fadeOut = v } }
                slider("Start offset", clip.fileOffset, 0...max(1, (daw.audioDuration(path: clip.path) ?? 60) - 0.1), "s") { v in set { $0.fileOffset = v } }
                HStack {
                    Button("Fit Length to File") {
                        if let d = daw.audioDuration(path: clip.path) { set { $0.length = max(0.25, (d - $0.fileOffset) / daw.secondsPerBeat) } }
                    }
                    Button("Split at Playhead") { daw.splitSelectedAtPlayhead() }
                    Button("Duplicate") { daw.duplicateSelectedClip() }
                    Button("Analyze for Lights…") {
                        NotificationCenter.default.post(name: .studioAnalyzeFile, object: URL(fileURLWithPath: clip.path))
                    }
                    .help("Build a light show for this audio in the Set Builder")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func set(_ change: @escaping (inout AudioClip) -> Void) {
        let id = clip.id
        daw.edit { p in
            for t in p.tracks.indices { if let i = p.tracks[t].audioClips.firstIndex(where: { $0.id == id }) { change(&p.tracks[t].audioClips[i]) } }
        }
    }

    private func slider(_ label: String, _ value: Double, _ range: ClosedRange<Double>, _ unit: String, set: @escaping (Double) -> Void) -> some View {
        LabeledContent(label) {
            HStack {
                Slider(value: Binding(get: { value }, set: set), in: range)
                Text(String(format: "%.1f %@", value, unit)).font(.caption.monospacedDigit()).frame(width: 70, alignment: .trailing)
            }
        }
    }
}

extension Notification.Name {
    static let studioAnalyzeFile = Notification.Name("studioAnalyzeFile")
}
