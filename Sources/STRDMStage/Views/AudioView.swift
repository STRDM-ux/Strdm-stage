import SwiftUI
import AVFoundation

struct AudioView: View {
    var body: some View {
        HSplitView {
            AudioDeviceSettings()
                .frame(minWidth: 340, idealWidth: 380, maxWidth: 460)
            VocalRackView()
                .frame(minWidth: 480)
        }
    }
}

private struct AudioDeviceSettings: View {
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var audio: AudioEngine

    var body: some View {
        Form {
            Section("Interface") {
                Picker("Output", selection: $store.show.audioSettings.outputDeviceUID) {
                    Text("System default").tag(String?.none)
                    ForEach(audio.outputDevices) { d in
                        Text("\(d.name) (\(d.outputChannels) out)").tag(Optional(d.uid))
                    }
                }
                Picker("Input (vocal rack)", selection: $store.show.audioSettings.inputDeviceUID) {
                    Text("System default").tag(String?.none)
                    ForEach(audio.inputDevices) { d in
                        Text("\(d.name) (\(d.inputChannels) in)").tag(Optional(d.uid))
                    }
                }
                Picker("Buffer size", selection: $store.show.audioSettings.bufferFrames) {
                    ForEach([32, 64, 128, 256, 512, 1024], id: \.self) { n in
                        Text("\(n) samples").tag(n)
                    }
                }
                HStack {
                    Button("Apply") { audio.applyDeviceSettings() }
                        .buttonStyle(.borderedProminent)
                    Button("Rescan devices") { audio.refreshDevices() }
                }
                Text("Use the same interface for input and output, at 64–128 samples, so live vocals through Auto-Tune stay under ~5 ms.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Master") {
                HStack {
                    Slider(value: Binding(get: { store.show.audioSettings.masterGainDB },
                                          set: { audio.setMasterGain($0) }), in: -60...6)
                    Text("\(store.show.audioSettings.masterGainDB, specifier: "%+.1f") dB")
                        .font(.caption.monospacedDigit()).frame(width: 64, alignment: .trailing)
                }
                LevelMeter(level: audio.outputLevel).frame(height: 10)
            }
            Section("Master EQ") { MasterEQView() }
            Section("Status") {
                Text(audio.status).font(.caption).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }
}

private struct VocalRackView: View {
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var audio: AudioEngine
    @State private var search = ""
    @State private var presetName = ""
    @State private var showPTImport = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { store.show.vocalRack.enabled },
                                     set: { audio.setVocalEnabled($0) })) {
                    VStack(alignment: .leading) {
                        Text("Live vocal rack").font(.headline)
                        Text("Mic → plugins (Auto-Tune etc.) → main outputs").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                if audio.micPermission == .denied {
                    Label("Microphone access denied. Enable STRDM Stage in System Settings → Privacy & Security → Microphone.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else if audio.micPermission == .notDetermined {
                    Button("Allow microphone access") { audio.requestMicAccess() }
                }

                Stepper(value: Binding(get: { store.show.vocalRack.inputChannel },
                                       set: { audio.setVocalInputChannel(max(0, $0)) }), in: 0...63) {
                    Text("Hardware input: \(store.show.vocalRack.inputChannel + 1)")
                }
                HStack {
                    Text("Rack output")
                    Slider(value: Binding(get: { store.show.vocalRack.gainDB },
                                          set: { audio.setVocalGain($0) }), in: -60...12)
                    Text("\(store.show.vocalRack.gainDB, specifier: "%+.1f") dB")
                        .font(.caption.monospacedDigit()).frame(width: 64, alignment: .trailing)
                }
                HStack {
                    Text("Input level")
                    LevelMeter(level: audio.vocalLevel).frame(height: 10)
                }
                Toggle("Bypass whole rack (dry vocal)", isOn: Binding(get: { store.show.vocalRack.bypassAll },
                                                                      set: { audio.setVocalBypass($0) }))
            }

            Section("Plugin chain") {
                if store.show.vocalRack.plugins.isEmpty {
                    Text("No plugins yet. Add Auto-Tune (or any Audio Unit) below.").foregroundStyle(.secondary)
                }
                ForEach(store.show.vocalRack.plugins) { slot in
                    PluginSlotRow(slot: slot, loaded: audio.loadedPluginIDs.contains(slot.id))
                }
                .onMove { audio.movePlugin(from: $0, to: $1) }
                Button { showPTImport = true } label: {
                    Label("Import vocal chain from a Pro Tools session…", systemImage: "square.and.arrow.down.on.square")
                }
                .help("Reads the inserts on your vocal track and vocal bus in a .ptx session and rebuilds them here")
                PluginBrowser(search: $search)
            }

            Section("Vocal presets (recall from Vocal FX cues)") {
                ForEach(store.show.vocalRack.presets) { preset in
                    HStack {
                        Text(preset.name)
                        Spacer()
                        Button("Recall") { audio.applyVocalPreset(preset.id) }
                        Button(role: .destructive) {
                            store.show.vocalRack.presets.removeAll { $0.id == preset.id }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Preset name, e.g. “Hard tune — Song 3”", text: $presetName)
                    Button("Save current") {
                        audio.savePreset(named: presetName.isEmpty ? "Preset \(store.show.vocalRack.presets.count + 1)" : presetName)
                        presetName = ""
                    }
                    .disabled(store.show.vocalRack.plugins.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showPTImport) { ProToolsImportSheet() }
    }
}

private struct PluginSlotRow: View {
    @EnvironmentObject var audio: AudioEngine
    let slot: PluginSlot
    let loaded: Bool

    var body: some View {
        HStack {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            Circle().fill(loaded ? (slot.bypassed ? Color.orange : Color.green) : Color.gray).frame(width: 8, height: 8)
            VStack(alignment: .leading) {
                Text(slot.name).fontWeight(.semibold)
                Text(slot.manufacturer).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Bypass", isOn: Binding(get: { slot.bypassed }, set: { audio.setSlotBypass(slot.id, $0) }))
                .toggleStyle(.button)
            Button("Edit…") { audio.openPluginWindow(slot.id) }
                .disabled(!loaded)
            Button(role: .destructive) { audio.removePlugin(slot.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
    }
}

private struct PluginBrowser: View {
    @EnvironmentObject var audio: AudioEngine
    @Binding var search: String

    private var filtered: [AVAudioUnitComponent] {
        let q = search.lowercased()
        let list = audio.availablePlugins
        guard !q.isEmpty else {
            // Float pitch-correction plugins to the top so Auto-Tune is easy to find.
            return list.filter { Self.isTuner($0) } + list.filter { !Self.isTuner($0) }
        }
        return list.filter { $0.name.lowercased().contains(q) || $0.manufacturerName.lowercased().contains(q) }
    }

    static func isTuner(_ c: AVAudioUnitComponent) -> Bool {
        let s = (c.name + " " + c.manufacturerName).lowercased()
        return ["auto-tune", "autotune", "antares", "melodyne", "waves tune", "metatune", "graillon", "pitch"].contains { s.contains($0) }
    }

    var body: some View {
        DisclosureGroup("Add plugin (\(audio.availablePlugins.count) Audio Units found)") {
            HStack {
                TextField("Search plugins", text: $search)
                Button("Rescan") { audio.refreshPluginList() }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(filtered.prefix(200).enumerated()), id: \.offset) { _, component in
                        Button {
                            audio.addPlugin(component)
                        } label: {
                            HStack {
                                Image(systemName: Self.isTuner(component) ? "tuningfork" : "slider.horizontal.3")
                                    .foregroundStyle(Self.isTuner(component) ? Color.pink : Color.secondary)
                                Text(component.name)
                                Text(component.manufacturerName).foregroundStyle(.secondary)
                                Spacer()
                                Image(systemName: "plus.circle")
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 3)
                    }
                }
            }
            .frame(height: 220)
        }
    }
}


/// 10-band graphic EQ on the master output, with presets and a low-cut.
struct MasterEQView: View {
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var audio: AudioEngine

    var body: some View {
        let eq = store.show.audioSettings.eq ?? MasterEQ()
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("EQ on", isOn: Binding(get: { eq.enabled }, set: { v in audio.setEQ { $0.enabled = v } }))
                Spacer()
                Picker("Preset", selection: Binding(get: { eq.preset }, set: { audio.setEQPreset($0) })) {
                    ForEach(MasterEQ.presets, id: \.name) { Text($0.name).tag($0.name) }
                    if !MasterEQ.presets.contains(where: { $0.name == eq.preset }) { Text(eq.preset).tag(eq.preset) }
                }
                .frame(width: 260)
                Button("Flat") { audio.setEQPreset("Flat") }
            }
            HStack(alignment: .bottom, spacing: 14) {
                ForEach(0..<10, id: \.self) { i in
                    VStack(spacing: 4) {
                        Text(String(format: "%+.0f", eq.gains[safe: i] ?? 0)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        Slider(value: Binding(get: { eq.gains[safe: i] ?? 0 },
                                              set: { v in audio.setEQ { $0.gains[i] = (v * 2).rounded() / 2; $0.preset = "Custom" } }),
                               in: -12...12)
                            .rotationEffect(.degrees(-90))
                            .frame(width: 130, height: 24)
                            .frame(width: 28, height: 130)
                        Text(MasterEQ.labels[i]).font(.caption2.weight(.semibold))
                    }
                }
            }
            .opacity(eq.enabled ? 1 : 0.4)
            .frame(maxWidth: .infinity)
            HStack {
                Text("Low cut")
                Slider(value: Binding(get: { eq.highPassHz }, set: { v in audio.setEQ { $0.highPassHz = v.rounded() } }), in: 0...150)
                Text(eq.highPassHz < 20 ? "Off" : "\(Int(eq.highPassHz)) Hz").font(.caption.monospacedDigit()).frame(width: 54)
            }
            Text("Shapes everything the Mac sends to the PA. Also on the STRDM Live phone/iPad app under Sound.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
