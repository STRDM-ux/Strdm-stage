import SwiftUI
import AppKit
import AVFoundation

// MARK: - Mixer

struct MixerPanel: View {
    @EnvironmentObject var daw: DAWEngine

    var body: some View {
        let p = daw.project
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 6) {
                ForEach(p.tracks) { t in
                    ChannelStrip(name: t.name, color: t.color.color, volume: t.volumeDB, pan: t.pan,
                                 level: daw.levels[t.id] ?? 0, mute: t.mute, solo: t.solo,
                                 selected: daw.selectedTrackID == t.id,
                                 setVolume: { v in daw.updateTrack(t.id) { $0.volumeDB = v } },
                                 setPan: { v in daw.updateTrack(t.id) { $0.pan = v } },
                                 toggleMute: { daw.updateTrack(t.id) { $0.mute.toggle() } },
                                 toggleSolo: { daw.updateTrack(t.id) { $0.solo.toggle() } }) {
                        sends(for: t)
                    }
                    .onTapGesture { daw.selectedTrackID = t.id }
                }
                Divider()
                ForEach(Array(p.buses.enumerated()), id: \.element.id) { i, bus in
                    ChannelStrip(name: bus.name, color: .gray, volume: bus.volumeDB, pan: nil, level: 0,
                                 mute: bus.mute, solo: nil, selected: false,
                                 setVolume: { v in daw.edit { $0.buses[i].volumeDB = v } },
                                 setPan: { _ in },
                                 toggleMute: { daw.edit { $0.buses[i].mute.toggle() } },
                                 toggleSolo: {}) {
                        Text(bus.effects.map(\.name).joined(separator: " · ")).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Divider()
                ChannelStrip(name: "MASTER", color: .white, volume: p.master.volumeDB, pan: nil,
                             level: daw.masterLevel, mute: false, solo: nil, selected: false,
                             setVolume: { v in daw.edit { $0.master.volumeDB = v } },
                             setPan: { _ in }, toggleMute: {}, toggleSolo: {}) {
                    if let l = daw.lastLUFS { Text(String(format: "%.1f LUFS", l)).font(.caption2.monospacedDigit()) }
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func sends(for t: DAWTrack) -> some View {
        let p = daw.project
        VStack(spacing: 2) {
            ForEach(Array(p.buses.enumerated()), id: \.element.id) { bi, bus in
                let si = t.sends.firstIndex { $0.busIndex == bi }
                HStack(spacing: 2) {
                    Text(String(bus.name.prefix(3))).font(.system(size: 9)).frame(width: 20, alignment: .leading)
                    Slider(value: Binding(get: { si.map { t.sends[$0].levelDB } ?? -60 }, set: { v in
                        daw.updateTrack(t.id) { tr in
                            if let k = tr.sends.firstIndex(where: { $0.busIndex == bi }) {
                                if v <= -59 { tr.sends.remove(at: k) } else { tr.sends[k].levelDB = v }
                            } else if v > -59 {
                                tr.sends.append(DAWSend(busIndex: bi, levelDB: v))
                            }
                        }
                    }), in: -60...0)
                    .controlSize(.mini)
                }
            }
        }
    }
}

struct ChannelStrip<Extra: View>: View {
    let name: String
    let color: Color
    let volume: Double
    let pan: Double?
    let level: Float
    let mute: Bool
    let solo: Bool?
    let selected: Bool
    var setVolume: (Double) -> Void
    var setPan: (Double) -> Void
    var toggleMute: () -> Void
    var toggleSolo: () -> Void
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        VStack(spacing: 5) {
            Text(name).font(.caption.weight(.semibold)).lineLimit(1).frame(maxWidth: .infinity)
                .padding(.vertical, 3).background(color.opacity(0.35))
            extra().frame(height: 34)
            if let pan {
                HStack(spacing: 2) {
                    Text("L").font(.system(size: 8))
                    Slider(value: Binding(get: { pan }, set: setPan), in: -1...1).controlSize(.mini)
                    Text("R").font(.system(size: 8))
                }
                .onTapGesture(count: 2) { setPan(0) }
            } else { Spacer().frame(height: 16) }
            HStack(alignment: .bottom, spacing: 5) {
                VerticalFader(value: volume, range: -60...6, set: setVolume)
                VerticalMeter(level: level)
            }
            .frame(height: 130)
            Text(volume <= -59.5 ? "-∞" : String(format: "%+.1f", volume)).font(.caption2.monospacedDigit())
            HStack(spacing: 4) {
                if solo != nil || name != "MASTER" {
                    Button(action: toggleMute) { Text("M").font(.caption2.bold()).frame(width: 20) }
                        .tint(mute ? .orange : nil).buttonStyle(.bordered).controlSize(.mini)
                }
                if let solo {
                    Button(action: toggleSolo) { Text("S").font(.caption2.bold()).frame(width: 20) }
                        .tint(solo ? .yellow : nil).buttonStyle(.bordered).controlSize(.mini)
                }
            }
        }
        .padding(6)
        .frame(width: 92)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(selected ? 0.12 : 0.05)))
    }
}

struct VerticalFader: View {
    let value: Double
    let range: ClosedRange<Double>
    var set: (Double) -> Void

    var body: some View {
        GeometryReader { g in
            let h = g.size.height
            let f = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let zeroF = (0 - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.black.opacity(0.5)).frame(width: 4)
                Rectangle().fill(Color.white.opacity(0.3)).frame(width: 14, height: 1)
                    .offset(y: -CGFloat(zeroF) * h)
                RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.75))
                    .frame(width: 24, height: 12)
                    .offset(y: -CGFloat(f) * (h - 12))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let nf = 1 - max(0, min(1, Double(v.location.y - 6) / Double(h - 12)))
                var db = range.lowerBound + nf * (range.upperBound - range.lowerBound)
                if abs(db) < 0.6 { db = 0 }
                set((db * 10).rounded() / 10)
            })
            .onTapGesture(count: 2) { set(0) }
        }
        .frame(width: 30)
    }
}

struct VerticalMeter: View {
    let level: Float
    var body: some View {
        GeometryReader { g in
            let db = 20 * log10(Double(max(level, 0.00001)))
            let f = max(0, min(1, (db + 60) / 66))
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.5))
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: .bottom, endPoint: .top))
                    .frame(height: g.size.height * f)
            }
        }
        .frame(width: 7)
    }
}

// MARK: - Devices (instrument + effect chains)

struct DevicesPanel: View {
    @EnvironmentObject var daw: DAWEngine
    @State private var target: ChainTarget? = nil

    var body: some View {
        let p = daw.project
        let current = target ?? daw.selectedTrackID.map { .track($0) } ?? .master
        HStack(alignment: .top, spacing: 0) {
            List(selection: Binding<ChainTarget?>(get: { current }, set: { target = $0 })) {
                Section("Tracks") {
                    ForEach(p.tracks) { t in
                        Label(t.name, systemImage: t.kind == .audio ? "waveform" : "pianokeys").tag(ChainTarget.track(t.id))
                    }
                }
                Section("Buses") {
                    ForEach(Array(p.buses.enumerated()), id: \.element.id) { i, b in
                        Label(b.name, systemImage: "arrow.triangle.branch").tag(ChainTarget.bus(i))
                    }
                }
                Section { Label("Master", systemImage: "dial.high").tag(ChainTarget.master) }
            }
            .listStyle(.sidebar)
            .frame(width: 190)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if case .track(let id) = current, let t = daw.track(id), t.kind == .midi {
                        InstrumentSection(track: t)
                    }
                    EffectChainSection(target: current)
                    if case .master = current {
                        MasterTargetSection()
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: daw.selectedTrackID) { _, _ in target = nil }
    }
}

struct InstrumentSection: View {
    @EnvironmentObject var daw: DAWEngine
    let track: DAWTrack

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(track.instrument?.label ?? "None").font(.headline)
                    Spacer()
                    Button("Open Window") { daw.openInstrumentEditor(trackID: track.id) }
                }
                switch track.instrument {
                case .synth(let preset)?:
                    Picker("Preset", selection: Binding(get: { preset }, set: { v in daw.updateTrack(track.id) { $0.instrument = .synth(preset: v) } })) {
                        ForEach(SynthPreset.library) { Text($0.name).tag($0.name) }
                    }
                    .frame(maxWidth: 300)
                case .drumMachine(let kit)?:
                    Picker("Kit", selection: Binding(get: { kit }, set: { v in daw.updateTrack(track.id) { $0.instrument = .drumMachine(kit: v) } })) {
                        ForEach(DrumKits.names, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(maxWidth: 300)
                    Text("Load your own samples per pad from the step sequencer (… next to each pad).").font(.caption).foregroundStyle(.secondary)
                case .generalMIDI(let prog)?:
                    Picker("Sound", selection: Binding(get: { prog }, set: { v in daw.updateTrack(track.id) { $0.instrument = .generalMIDI(program: v) } })) {
                        ForEach(0..<GeneralMIDI.names.count, id: \.self) { i in Text("\(i + 1). \(GeneralMIDI.names[i])").tag(i) }
                    }
                    .frame(maxWidth: 340)
                case .sampler(let path)?:
                    HStack {
                        Text(URL(fileURLWithPath: path).lastPathComponent).font(.caption)
                        Button("Replace…") { if let u = pickAudio() { daw.updateTrack(track.id) { $0.instrument = .sampler(path: u.path) } } }
                    }
                    Text("The sample plays at its original pitch on C3 (MIDI 60) and is transposed across the keyboard.").font(.caption).foregroundStyle(.secondary)
                default:
                    EmptyView()
                }
                Menu("Change Instrument") {
                    Button("STRDM Synth") { daw.updateTrack(track.id) { $0.instrument = .synth(preset: "Lead") } }
                    Button("STRDM Drum Machine") { daw.updateTrack(track.id) { $0.instrument = .drumMachine(kit: "Dancehall") } }
                    Button("Piano & GM Sounds") { daw.updateTrack(track.id) { $0.instrument = .generalMIDI(program: 0) } }
                    Button("Sampler from File…") { if let u = pickAudio() { daw.updateTrack(track.id) { $0.instrument = .sampler(path: u.path) } } }
                    if !daw.instrumentComponents.isEmpty {
                        Menu("Plug-ins") {
                            ForEach(daw.instrumentComponents, id: \.self) { c in
                                Button("\(c.manufacturerName) — \(c.name)") { daw.updateTrack(track.id) { $0.instrument = .audioUnit(PluginSlot(component: c)) } }
                            }
                        }
                    }
                }
                .fixedSize()
            }
        } label: { Label("Instrument", systemImage: "pianokeys") }
    }
}

struct EffectChainSection: View {
    @EnvironmentObject var daw: DAWEngine
    let target: ChainTarget

    var body: some View {
        let slots = daw.effects(of: target)
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if slots.isEmpty {
                    Text("No effects yet").foregroundStyle(.secondary).font(.callout)
                }
                ForEach(Array(slots.enumerated()), id: \.element.id) { i, slot in
                    HStack(spacing: 8) {
                        Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 14)
                        Toggle("", isOn: Binding(get: { !slot.bypassed }, set: { on in daw.updateEffects(target) { $0[i].bypassed = !on } }))
                            .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                        VStack(alignment: .leading, spacing: 0) {
                            Text(slot.name).font(.callout.weight(.medium))
                            Text(slot.manufacturer).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { daw.openEditor(for: slot) }
                        Button { daw.updateEffects(target) { if i > 0 { $0.swapAt(i, i - 1) } } } label: { Image(systemName: "chevron.up") }
                            .disabled(i == 0)
                        Button { daw.updateEffects(target) { if i < $0.count - 1 { $0.swapAt(i, i + 1) } } } label: { Image(systemName: "chevron.down") }
                            .disabled(i == slots.count - 1)
                        Button(role: .destructive) { daw.updateEffects(target) { $0.remove(at: i) } } label: { Image(systemName: "trash") }
                    }
                    .buttonStyle(.borderless)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(slot.bypassed ? 0.02 : 0.07)))
                }
                Menu {
                    Section("STRDM Essentials") {
                        ForEach(StockEffect.allCases) { e in Button(e.label) { daw.addEffect(.stock(e), to: target) } }
                    }
                    let groups = Dictionary(grouping: daw.effectComponents, by: \.manufacturerName)
                    ForEach(groups.keys.sorted(), id: \.self) { m in
                        Menu(m) {
                            ForEach(groups[m] ?? [], id: \.self) { c in Button(c.name) { daw.addEffect(PluginSlot(component: c), to: target) } }
                        }
                    }
                    Divider()
                    Button("Rescan Plug-ins") { daw.refreshComponents() }
                } label: { Label("Add Effect", systemImage: "plus") }
                .fixedSize()
            }
        } label: { Label("Effects", systemImage: "fx") }
    }
}

struct MasterTargetSection: View {
    @EnvironmentObject var daw: DAWEngine
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Loudness target")
                    Slider(value: Binding(get: { daw.project.master.targetLUFS }, set: { v in daw.edit { $0.master.targetLUFS = v.rounded() } }), in: -18...(-6))
                        .frame(width: 180)
                    Text("\(Int(daw.project.master.targetLUFS)) LUFS").font(.callout.monospacedDigit())
                }
                Text("Auto-master (Export tab) measures the mix and drives the master limiter to hit this target. -14 for streaming, -9 to -10 for loud club/stage playback.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } label: { Label("Mastering", systemImage: "dial.high") }
    }
}

// MARK: - Export

struct ExportPanel: View {
    @EnvironmentObject var daw: DAWEngine
    @State private var name = ""
    @State private var autoMaster = true
    @State private var format: DAWEngine.ExportFormat = .wav
    @State private var lastURL: URL?

    var body: some View {
        let p = daw.project
        Form {
            Section("Bounce") {
                TextField("Name", text: Binding(get: { name.isEmpty ? p.name : name }, set: { name = $0 }))
                Picker("Format", selection: $format) {
                    ForEach(DAWEngine.ExportFormat.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Auto-master to \(Int(p.master.targetLUFS)) LUFS (uses the master limiter)", isOn: $autoMaster)
                LabeledContent("Length") {
                    Text("\(Music.barsBeats(p.contentEnd, beatsPerBar: p.beatsPerBar)) · \(String(format: "%.0f", p.contentEnd * daw.secondsPerBeat)) s")
                        .font(.callout.monospacedDigit())
                }
                HStack {
                    Button("Export Mix") { run { await daw.exportMix(name: exportName, loopOnly: false, autoMaster: autoMaster, format: format)?.url } }
                        .buttonStyle(.borderedProminent)
                    Button("Export Loop Range") { run { await daw.exportMix(name: exportName + " loop", loopOnly: true, autoMaster: autoMaster, format: format)?.url } }
                        .disabled(!p.loopEnabled)
                    Button("Export Stems") { run { await daw.exportStems(name: exportName) } }
                }
                .disabled(daw.isExporting)
            }
            Section("Send to the show") {
                Text("Bounces the mix, adds it to the Cue List as an audio cue, and builds its light show automatically in the Set Builder.")
                    .font(.callout).foregroundStyle(.secondary)
                Button {
                    Task { await daw.exportToShow(name: exportName, autoMaster: autoMaster) }
                } label: { Label("Export to Show", systemImage: "music.note.list") }
                .buttonStyle(.borderedProminent).tint(.pink)
                .disabled(daw.isExporting)
            }
            Section("Result") {
                if daw.isExporting { ProgressView().controlSize(.small) }
                Text(daw.status).font(.callout)
                if let l = daw.lastLUFS { Text(String(format: "Integrated loudness: %.1f LUFS", l)).font(.callout.monospacedDigit()) }
                HStack {
                    if let u = lastURL { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
                    Button("Open Exports Folder") { NSWorkspace.shared.open(DAWEngine.exportFolder()) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var exportName: String { name.isEmpty ? daw.project.name : name }

    private func run(_ job: @escaping @MainActor () async -> URL?) {
        Task { @MainActor in lastURL = await job() }
    }
}
