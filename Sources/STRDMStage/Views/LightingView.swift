import SwiftUI
import AppKit

struct LightingView: View {
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            LightingOutputBar()
            Divider()
            Picker("", selection: $tab) {
                Text("Programmer & Scenes").tag(0)
                Text("Patch").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            .padding(8)
            if tab == 0 {
                HSplitView {
                    VStack(spacing: 0) {
                        FixtureGrid()
                        Divider()
                        ProgrammerPanel().frame(minHeight: 220)
                    }
                    .frame(minWidth: 480)
                    ScenesPanel().frame(minWidth: 300, idealWidth: 340, maxWidth: 440)
                }
            } else {
                PatchView()
            }
        }
    }
}

private struct LightingOutputBar: View {
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var lighting: LightingEngine

    var body: some View {
        HStack(spacing: 14) {
            Toggle("DMX Output", isOn: $store.show.lighting.outputEnabled)
                .toggleStyle(.switch)
            Picker("Protocol", selection: $store.show.lighting.dmxProtocol) {
                ForEach(DMXProtocol.allCases) { Text($0.label).tag($0) }
            }
            .frame(width: 190)
            if store.show.lighting.dmxProtocol == .artNet {
                TextField("Art-Net IP", text: $store.show.lighting.artNetDestination)
                    .frame(width: 140)
                    .help("Broadcast (2.255.255.255, 10.255.255.255, 192.168.1.255) or the node's IP")
            } else {
                TextField("Unicast IP (blank = multicast)", text: $store.show.lighting.sACNUnicast)
                    .frame(width: 200)
            }
            Text(store.show.lighting.outputEnabled ? "● \(Int(LightingEngine.frameRate)) fps" : "○ off")
                .font(.caption.monospacedDigit())
                .foregroundStyle(store.show.lighting.outputEnabled ? Color.green : Color.secondary)
            Spacer()
            GMControl(width: 240)
            Toggle("Blackout", isOn: $lighting.blackout).toggleStyle(.button).tint(.yellow)
        }
        .padding(10)
    }
}

private struct FixtureGrid: View {
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var lighting: LightingEngine

    private var groups: [String] {
        Array(Set(store.show.lighting.fixtures.map(\.group).filter { !$0.isEmpty })).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Fixtures").font(.headline)
                Spacer()
                Menu("Select group") {
                    ForEach(groups, id: \.self) { g in
                        Button(g) {
                            lighting.selected = Set(store.show.lighting.fixtures.filter { $0.group == g }.map(\.id))
                        }
                    }
                }
                .fixedSize()
                Button("All") { lighting.selected = Set(store.show.lighting.fixtures.map(\.id)) }
                Button("None") { lighting.selected.removeAll() }
            }
            .padding(8)
            ScrollView {
                if store.show.lighting.fixtures.isEmpty {
                    Text("No fixtures patched yet — open the Patch tab.").foregroundStyle(.secondary).padding(30)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                    ForEach(store.show.lighting.fixtures) { f in
                        FixtureTile(fixture: f, isSelected: lighting.selected.contains(f.id))
                            .onTapGesture {
                                if lighting.selected.contains(f.id) { lighting.selected.remove(f.id) }
                                else { lighting.selected.insert(f.id) }
                            }
                    }
                }
                .padding(8)
            }
        }
    }
}

private struct FixtureTile: View {
    @EnvironmentObject var lighting: LightingEngine
    let fixture: Fixture
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            Circle()
                .fill(lighting.previewColor(fixture))
                .overlay(Circle().stroke(.white.opacity(0.25)))
                .frame(width: 34, height: 34)
                .shadow(color: lighting.previewColor(fixture), radius: 8)
            Text(fixture.name).font(.caption.weight(.semibold)).lineLimit(1)
            Text("U\(fixture.universe + 1).\(fixture.address)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2))
    }
}

private struct ProgrammerPanel: View {
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var lighting: LightingEngine
    @State private var color: Color = .purple

    private var selectedFixtures: [Fixture] {
        store.show.lighting.fixtures.filter { lighting.selected.contains($0.id) }
    }

    var body: some View {
        let fixtures = selectedFixtures
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Programmer").font(.headline)
                Text(fixtures.isEmpty ? "select fixtures above" : "\(fixtures.count) selected")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                ColorPicker("Colour", selection: Binding(get: { color }, set: { color = $0; lighting.setColor($0) }))
                    .disabled(fixtures.isEmpty)
                ForEach(QuickColor.all) { qc in
                    Button { color = qc.color; lighting.setColor(qc.color) } label: {
                        Circle().fill(qc.color).frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .help(qc.name)
                    .disabled(fixtures.isEmpty)
                }
                Button("Clear") { lighting.clearSelected() }.disabled(fixtures.isEmpty)
            }
            if let first = fixtures.first {
                ScrollView(.horizontal) {
                    HStack(alignment: .bottom, spacing: 10) {
                        ForEach(Array(first.profile.channels.enumerated()), id: \.offset) { i, ch in
                            ChannelFader(name: ch.name, value: Binding(
                                get: { lighting.value(first.id, i) },
                                set: { v in
                                    for f in fixtures where f.profile == first.profile {
                                        lighting.setValue(f.id, channel: i, value: v)
                                    }
                                }))
                        }
                    }
                    .padding(.vertical, 4)
                }
                if fixtures.contains(where: { $0.profile != first.profile }) {
                    Text("Mixed fixture types selected — faders apply to fixtures matching \(first.profile.name); colour picker applies to all.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Spacer()
            }
        }
        .padding(10)
    }
}

private struct QuickColor: Identifiable {
    let id = UUID()
    let name: String
    let color: Color
    static let all: [QuickColor] = [
        QuickColor(name: "Red", color: .red), QuickColor(name: "Pink", color: Color(red: 1, green: 0.08, blue: 0.58)),
        QuickColor(name: "Purple", color: Color(red: 0.47, green: 0, blue: 1)), QuickColor(name: "Blue", color: .blue),
        QuickColor(name: "Cyan", color: .cyan), QuickColor(name: "Green", color: .green),
        QuickColor(name: "Amber", color: .orange), QuickColor(name: "White", color: .white)
    ]
}

private struct ChannelFader: View {
    let name: String
    @Binding var value: Double

    var body: some View {
        VStack(spacing: 4) {
            Text("\(Int(value))").font(.caption2.monospacedDigit())
            Slider(value: $value, in: 0...255)
                .rotationEffect(.degrees(-90))
                .frame(width: 120, height: 24)
                .frame(width: 30, height: 120)
            Text(name).font(.caption2).lineLimit(1).frame(width: 58)
        }
    }
}

private struct ScenesPanel: View {
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var lighting: LightingEngine
    @State private var newName = ""
    @State private var onlySelected = false
    @State private var fade: Double = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Scenes").font(.headline)
                Spacer()
                if let p = lighting.fadeProgress {
                    ProgressView(value: p).frame(width: 80)
                }
            }
            HStack {
                Text("Manual fade")
                Slider(value: $fade, in: 0...10)
                Text("\(fade, specifier: "%.1f")s").font(.caption.monospacedDigit()).frame(width: 36)
            }
            List {
                ForEach($store.show.lighting.scenes) { $scene in
                    HStack {
                        Circle().fill(lighting.activeSceneID == scene.id ? Color.green : Color.clear).frame(width: 8, height: 8)
                        TextField("Scene", text: $scene.name).textFieldStyle(.plain)
                        Spacer()
                        Button("Go") { lighting.goToScene(scene.id, fade: fade) }
                        Menu {
                            Button("Update from live look") { lighting.updateScene(scene.id) }
                            Button("Add cue for this scene") {
                                var cue = Cue(kind: .lights, number: store.nextCueNumber(), name: scene.name)
                                cue.sceneID = scene.id
                                cue.lightFade = fade
                                store.show.cues.append(cue)
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                store.show.lighting.scenes.removeAll { $0.id == scene.id }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                .onMove { store.show.lighting.scenes.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.inset)
            Divider()
            TextField("New scene name", text: $newName)
            HStack {
                Toggle("Only selected fixtures", isOn: $onlySelected)
                Spacer()
                Button("Record") {
                    lighting.recordScene(named: newName.isEmpty ? "Scene \(store.show.lighting.scenes.count + 1)" : newName,
                                         onlySelected: onlySelected)
                    newName = ""
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(10)
    }
}

// MARK: - Patch

private struct PatchView: View {
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var lighting: LightingEngine
    @State private var showingAdd = false
    @State private var selection = Set<UUID>()

    var body: some View {
        let conflicts = lighting.conflicts
        VStack(spacing: 0) {
            HStack {
                Button { showingAdd = true } label: { Label("Add Fixtures…", systemImage: "plus") }
                Button(role: .destructive) { lighting.removeFixtures(selection); selection.removeAll() } label: {
                    Label("Remove", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
                Spacer()
                if !conflicts.isEmpty {
                    Label("\(conflicts.count) fixtures overlap or exceed 512", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .padding(8)
            HStack {
                Text("Name").frame(width: 180, alignment: .leading)
                Text("Type").frame(width: 230, alignment: .leading)
                Text("Univ").frame(width: 60, alignment: .leading)
                Text("Address").frame(width: 80, alignment: .leading)
                Text("Ch").frame(width: 40, alignment: .leading)
                Text("Group").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            List(selection: $selection) {
                ForEach($store.show.lighting.fixtures) { $f in
                    HStack {
                        TextField("Name", text: $f.name).frame(width: 180)
                        Text(f.profile.name).frame(width: 230, alignment: .leading).lineLimit(1)
                        TextField("U", value: Binding(get: { $f.wrappedValue.universe + 1 }, set: { $f.wrappedValue.universe = max(0, $0 - 1) }), format: .number)
                            .frame(width: 60)
                        TextField("Addr", value: $f.address, format: .number).frame(width: 80)
                        Text("\(f.footprint)").frame(width: 40, alignment: .leading)
                        TextField("Group", text: $f.group)
                        if conflicts.contains(f.id) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                    .tag(f.id)
                }
                .onMove { store.show.lighting.fixtures.move(fromOffsets: $0, toOffset: $1) }
            }
            .onChange(of: store.show.lighting.fixtures) { _, _ in lighting.syncPatch() }
        }
        .sheet(isPresented: $showingAdd) { AddFixtureSheet() }
    }
}

private struct AddFixtureSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var lighting: LightingEngine
    @State private var profile = FixtureProfile.library[3]
    @State private var count = 4
    @State private var name = "Par"
    @State private var universe = 1
    @State private var address = 1
    @State private var group = ""

    var body: some View {
        Form {
            Picker("Fixture type", selection: $profile) {
                ForEach(FixtureProfile.library) { Text("\($0.name)").tag($0) }
            }
            Text(profile.channels.map(\.name).joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            Stepper("Quantity: \(count)", value: $count, in: 1...64)
            TextField("Base name", text: $name)
            Stepper("Universe: \(universe)", value: $universe, in: 1...64)
            HStack {
                TextField("Start address", value: $address, format: .number)
                Button("Next free") { address = lighting.nextFreeAddress(universe: universe - 1) }
            }
            TextField("Group (e.g. Front Wash, Movers)", text: $group)
            Text("Uses addresses \(address)–\(address + profile.channels.count * count - 1)")
                .font(.caption).foregroundStyle(address + profile.channels.count * count - 1 > 512 ? Color.red : Color.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    lighting.addFixtures(profile: profile, count: count, baseName: name, universe: universe - 1,
                                         startAddress: address, group: group)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { address = lighting.nextFreeAddress(universe: universe - 1) }
    }
}

/// Grand master with a big slider, live percentage you can type into, fine ±1 % steps and quick presets.
struct GMControl: View {
    @EnvironmentObject var lighting: LightingEngine
    var width: CGFloat = 220
    @State private var text = ""
    @FocusState private var editing: Bool

    private var pct: Int { Int((lighting.grandMaster * 100).rounded()) }
    private func set(_ p: Double) { lighting.grandMaster = max(0, min(100, p.rounded())) / 100 }

    var body: some View {
        HStack(spacing: 6) {
            Text("GM").font(.caption.weight(.bold))
            Button { set(Double(pct) - (NSEvent.modifierFlags.contains(.shift) ? 10 : 1)) } label: { Image(systemName: "minus") }
                .buttonStyle(.borderless).help("−1 % (⇧ −10 %)")
            VStack(spacing: 0) {
                Slider(value: Binding(get: { lighting.grandMaster * 100 }, set: { set($0) }), in: 0...100, step: 1)
                HStack {
                    ForEach([0, 25, 50, 75, 100], id: \.self) { v in
                        Button("\(v)") { set(Double(v)) }
                            .buttonStyle(.plain).font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(pct == v ? Color.yellow : Color.secondary)
                        if v != 100 { Spacer(minLength: 0) }
                    }
                }
                .padding(.horizontal, 4)
            }
            .frame(width: width)
            Button { set(Double(pct) + (NSEvent.modifierFlags.contains(.shift) ? 10 : 1)) } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless).help("+1 % (⇧ +10 %)")
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .multilineTextAlignment(.trailing)
                .frame(width: 52)
                .focused($editing)
                .onSubmit { if let v = Double(text.filter { $0.isNumber || $0 == "." }) { set(v) }; text = "\(pct)"; editing = false }
                .help("Type a level and press Return")
            Text("%").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { text = "\(pct)" }
        .onChange(of: pct) { _, v in if !editing { text = "\(v)" } }
    }
}
