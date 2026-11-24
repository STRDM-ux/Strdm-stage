import SwiftUI

// MARK: - Venue advance

struct VenueAdvanceView: View {
    @EnvironmentObject var store: ShowStore

    var body: some View {
        Form {
            Section("Show") {
                TextField("Artist", text: $store.show.venue.artist)
                TextField("Tour", text: $store.show.venue.tourName)
                TextField("Venue", text: $store.show.venue.venueName)
                TextField("City", text: $store.show.venue.city)
                DatePicker("Show date", selection: $store.show.venue.showDate, displayedComponents: .date)
                TextField("Capacity", text: $store.show.venue.capacity)
            }
            Section("Schedule") {
                TextField("Load-in", text: $store.show.venue.loadIn)
                TextField("Soundcheck", text: $store.show.venue.soundcheck)
                TextField("Doors", text: $store.show.venue.doors)
                TextField("Set time", text: $store.show.venue.setTime)
                TextField("Set length", text: $store.show.venue.setLength)
            }
            Section("Production") {
                TextField("Stage dimensions", text: $store.show.venue.stageDimensions)
                TextField("Power", text: $store.show.venue.power, prompt: Text("e.g. 2 × 20A circuits USL, 1 × 32A 3-phase"))
                TextField("PA / FOH desk", text: $store.show.venue.paSystem)
                TextField("Lighting desk / rig", text: $store.show.venue.lightingDesk, prompt: Text("e.g. house desk, Art-Net node on 2.x"))
                TextField("Video / LED", text: $store.show.venue.videoNotes, prompt: Text("e.g. LED processor HDMI input at USC"))
            }
            Section("Contacts") {
                TextField("Production contact", text: $store.show.venue.productionContact, axis: .vertical)
                TextField("Promoter contact", text: $store.show.venue.promoterContact, axis: .vertical)
            }
            Section("Rider extras") {
                TextField("Hospitality", text: $store.show.venue.hospitality, axis: .vertical).lineLimit(3...8)
                TextField("Notes", text: $store.show.venue.notes, axis: .vertical).lineLimit(3...8)
            }
            Section {
                Text("These details print on the tech rider PDF (Stage Plot page → Export Tech Rider PDF). Save a copy of the show file per city to keep each advance.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Control (MIDI / OSC / log)

struct ControlView: View {
    var body: some View {
        HSplitView {
            ControlSettingsForm().frame(minWidth: 460)
            ShowLogView().frame(minWidth: 300, idealWidth: 360)
        }
    }
}

private struct ControlSettingsForm: View {
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var midi: MIDIControl
    @EnvironmentObject var osc: OSCControl

    var body: some View {
        Form {
            RemotePairingSection()
            Section("OSC (Stream Deck via Companion, TouchOSC, QLab, Ableton)") {
                Toggle("Listen for OSC", isOn: Binding(get: { store.show.control.oscEnabled }, set: { on in
                    store.show.control.oscEnabled = on
                    if on { osc.start(port: store.show.control.oscPort) } else { osc.stop() }
                }))
                HStack {
                    TextField("UDP port", value: $store.show.control.oscPort, format: .number.grouping(.never))
                        .frame(width: 100)
                    Button("Restart") { osc.start(port: store.show.control.oscPort) }
                    Spacer()
                    Text(osc.isListening ? "● listening" : "○ stopped")
                        .foregroundStyle(osc.isListening ? Color.green : Color.secondary)
                }
                if let error = osc.error { Text(error).foregroundStyle(.red).font(.caption) }
                LabeledContent("Last message", value: osc.lastMessage)
                Text("""
                /go   /stop   /panic   /standby/next   /standby/prev
                /cue/{number}/start   /blackout   /vocal/bypass [0|1]
                /lights/gm [0.0–1.0]
                """)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }

            Section("MIDI (footswitch, pads, SPD-SX, MIDI controller)") {
                Toggle("Respond to MIDI", isOn: $store.show.control.midiEnabled)
                LabeledContent("Inputs", value: midi.sourceNames.isEmpty ? "None found" : midi.sourceNames.joined(separator: ", "))
                LabeledContent("Last message", value: midi.lastMessage)
                Button("Rescan MIDI devices") { midi.connectSources() }
                ForEach(ControlAction.allCases) { action in
                    HStack {
                        Text(action.label)
                        Spacer()
                        let mapping = store.show.control.midiMappings.first { $0.action == action }
                        Text(mapping?.description ?? "—").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        if midi.learning == action {
                            Button("Cancel") { midi.learning = nil }
                            Text("press a pad / pedal…").font(.caption).foregroundStyle(.orange)
                        } else {
                            Button("Learn") { midi.learning = action }
                        }
                        if mapping != nil {
                            Button { store.show.control.midiMappings.removeAll { $0.action == action } } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Section("Keyboard") {
                LabeledContent("Space", value: "GO")
                LabeledContent("Esc", value: "Panic (2 s fade)")
                LabeledContent("⌘ .", value: "Stop all")
                LabeledContent("⌘ ↑ / ⌘ ↓", value: "Move standby")
                LabeledContent("⌘ B", value: "Lighting blackout")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShowLogView: View {
    @EnvironmentObject var engine: ShowEngine
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Show log").font(.headline)
                Spacer()
                Button("Clear") { engine.log.removeAll() }
            }
            .padding(8)
            ScrollViewReader { proxy in
                List(Array(engine.log.enumerated()), id: \.offset) { i, line in
                    Text(line).font(.system(.caption, design: .monospaced)).id(i)
                }
                .onChange(of: engine.log.count) { _, count in
                    if count > 0 { proxy.scrollTo(count - 1) }
                }
            }
        }
    }
}
