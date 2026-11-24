import SwiftUI

/// Special Effects: arm, fire and patch flames, CO₂, confetti, pyro and cold sparks.
struct EffectsView: View {
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var sfx: SFXEngine
    @EnvironmentObject var lighting: LightingEngine
    @State private var selectedID: UUID?
    @State private var pattern: SFXPattern = .leftToRight
    @State private var burst: Double = 1.0
    @State private var camera3D: CameraPreset = .foh

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                SafetyBar()
                Divider()
                if store.show.effects.devices.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            groupControls
                            ForEach(SFXKind.allCases) { kind in
                                let list = sfx.order(store.show.effects.devices.filter { $0.kind == kind })
                                if !list.isEmpty {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Label(kind.plural, systemImage: kind.symbol).font(.headline).foregroundStyle(kind.tint)
                                            Spacer()
                                            Button("Arm all \(kind.plural)") { sfx.armAll(kind: kind) }.controlSize(.small)
                                        }
                                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                                            ForEach(list) { d in
                                                DeviceCard(device: d, selected: selectedID == d.id)
                                                    .onTapGesture { selectedID = d.id }
                                                    .contextMenu {
                                                        Button("Preview in 3D") { sfx.preview([d.id], pattern: .all) }
                                                    }
                                            }
                                        }
                                    }
                                }
                            }
                            logView
                        }
                        .padding(14)
                    }
                }
            }
            .frame(minWidth: 560)

            VSplitView {
                ZStack(alignment: .topLeading) {
                    Stage3DView(mode: .live, camera: camera3D, showCrowd: true)
                    Picker("", selection: $camera3D) {
                        ForEach(CameraPreset.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(width: 140).padding(8)
                }
                .frame(minHeight: 220, idealHeight: 300)
                DeviceInspector(selectedID: $selectedID)
            }
            .frame(minWidth: 300, idealWidth: 380, maxWidth: 520)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "flame.fill").font(.system(size: 44)).foregroundStyle(.orange)
            Text("No effects patched").font(.title3.bold())
            Text("Add your flame units, CO₂ jets, confetti cannons, pyro firing system or cold spark machines. Each one is controlled over DMX through the same Art-Net/sACN output as the lights.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
            AddDeviceMenu(selectedID: $selectedID).controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var groupControls: some View {
        GroupBox {
            HStack(spacing: 12) {
                Picker("Pattern", selection: $pattern) {
                    ForEach(SFXPattern.allCases) { Text($0.label).tag($0) }
                }
                .frame(width: 220)
                .fixedSize()
                HStack(spacing: 4) {
                    Text("Burst").fixedSize()
                    Slider(value: $burst, in: 0.2...3).frame(width: 90)
                    Text(String(format: "%.1fs", burst)).font(.caption.monospacedDigit()).frame(width: 34)
                }
                Spacer()
                ForEach(SFXKind.allCases.filter { k in store.show.effects.devices.contains { $0.kind == k } }) { k in
                    Button {
                        sfx.fire(kind: k, pattern: pattern, duration: burst, source: .manual)
                    } label: { Label(k.plural, systemImage: k.symbol) }
                    .tint(k.tint)
                    .buttonStyle(.borderedProminent)
                    .disabled(!sfx.masterArmed)
                }
            }
            HStack(spacing: 8) {
                Label("Preview in 3D (no DMX, no arming):", systemImage: "cube.transparent").font(.caption).foregroundStyle(.secondary)
                ForEach(SFXKind.allCases.filter { k in store.show.effects.devices.contains { $0.kind == k } }) { k in
                    Button { sfx.preview(kind: k, pattern: pattern, duration: burst) } label: { Label(k.plural, systemImage: k.symbol) }
                        .controlSize(.small)
                }
                Button("Everything") {
                    for k in SFXKind.allCases { sfx.preview(kind: k, pattern: pattern, duration: burst) }
                }
                .controlSize(.small)
                Spacer()
            }
            .padding(.top, 4)
        } label: { Text("Fire a group") }
    }

    private var logView: some View {
        GroupBox("Effects log") {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(sfx.log.prefix(12).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if sfx.log.isEmpty { Text("Nothing yet").font(.caption).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Safety bar

struct SafetyBar: View {
    @EnvironmentObject var sfx: SFXEngine
    @EnvironmentObject var store: ShowStore
    @State private var holding = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(sfx.masterArmed ? Color.red : Color.gray.opacity(0.3))
                    .shadow(color: sfx.masterArmed ? .red : .clear, radius: 10)
                VStack(spacing: 2) {
                    Text(sfx.masterArmed ? "ARMED" : (holding ? "HOLD…" : "SAFE"))
                        .font(.system(size: 18, weight: .black, design: .rounded))
                    Text(sfx.masterArmed ? "click to make safe" : "hold 1.5 s to arm").font(.caption2)
                }
                .foregroundStyle(.white)
            }
            .frame(width: 140, height: 52)
            .contentShape(Rectangle())
            .onTapGesture { if sfx.masterArmed { sfx.disarmMaster() } }
            .onLongPressGesture(minimumDuration: 1.5, perform: {
                if !sfx.masterArmed { sfx.armMaster() }
            }, onPressingChanged: { holding = $0 })
            .help("Master arm. Nothing fires unless the master AND the device are armed.")

            if store.show.effects.devices.contains(where: { $0.kind == .fireworks }) {
                Toggle(isOn: Binding(get: { sfx.pyroClear }, set: { sfx.pyroClear = $0 && sfx.masterArmed })) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Pyro area clear").font(.callout.bold())
                        Text("Shooter confirms fallout zone is clear").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(!sfx.masterArmed)
            }

            VStack(alignment: .leading, spacing: 2) {
                if !store.show.lighting.outputEnabled {
                    Label("DMX output is OFF — effects can't fire", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                }
                Text("Auto-safe after \(Int(store.show.effects.autoDisarmMinutes)) min idle · Panic, Stop All and quitting make everything safe")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .font(.caption)

            Spacer()

            Button {
                sfx.emergencyStop()
            } label: {
                Text("E-STOP").font(.system(size: 20, weight: .black, design: .rounded)).frame(width: 110, height: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .keyboardShortcut(.escape, modifiers: [.shift])
            .help("Kill all effect outputs and disarm everything (⇧Esc)")
        }
        .padding(12)
        .background(sfx.masterArmed ? Color.red.opacity(0.12) : Color.black.opacity(0.2))
    }
}

// MARK: - Device card

struct DeviceCard: View {
    @EnvironmentObject var sfx: SFXEngine
    let device: SFXDevice
    let selected: Bool
    @State private var pressed = false

    var body: some View {
        let status = sfx.status(device)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: device.kind.symbol).foregroundStyle(device.kind.tint)
                Text(device.name).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
                Toggle("", isOn: Binding(get: { sfx.armedDevices.contains(device.id) }, set: { _ in sfx.toggleArm(device.id) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .help("Arm this unit")
            }
            HStack {
                Text(statusText(status)).font(.caption.bold()).foregroundStyle(statusColor(status))
                Spacer()
                Text("U\(device.universe)·\(device.address)").font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            fireButton(status)
            if let left = sfx.loadsLeft(device) {
                HStack {
                    Text("\(left)/\(device.loads ?? 0) loaded").font(.caption2)
                    Spacer()
                    Button("Reloaded") { sfx.reload(device.id) }.controlSize(.mini)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(status == .firing ? device.kind.tint.opacity(0.45) : Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : (sfx.armedDevices.contains(device.id) && sfx.masterArmed ? Color.red : .clear), lineWidth: 2))
    }

    @ViewBuilder
    private func fireButton(_ status: SFXEngine.Status) -> some View {
        let enabled = status == .armed || status == .firing
        let label = device.kind.isOneShot ? "FIRE" : "HOLD TO FIRE"
        Text(label)
            .font(.system(size: 13, weight: .black, design: .rounded))
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 8).fill(enabled ? device.kind.tint.opacity(pressed ? 1 : 0.75) : Color.gray.opacity(0.25)))
            .foregroundStyle(enabled ? .black : .secondary)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true
                    sfx.beginHold(device.id)
                }
                .onEnded { _ in
                    pressed = false
                    sfx.endHold(device.id)
                })
    }

    private func statusText(_ s: SFXEngine.Status) -> String {
        switch s {
        case .safe: return "SAFE"
        case .notArmedMaster: return "Master safe"
        case .armed: return "ARMED · READY"
        case .firing: return "FIRING"
        case .cooling(let t): return String(format: "Cooling %.1fs", t)
        case .empty: return "EMPTY — reload"
        }
    }
    private func statusColor(_ s: SFXEngine.Status) -> Color {
        switch s {
        case .armed, .firing: return .red
        case .cooling: return .orange
        case .empty: return .yellow
        default: return .secondary
        }
    }
}

// MARK: - Patch / inspector

struct AddDeviceMenu: View {
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var lighting: LightingEngine
    @Binding var selectedID: UUID?

    var body: some View {
        Menu {
            ForEach(SFXKind.allCases) { k in
                Menu(k.label) {
                    ForEach([1, 2, 4, 6, 8], id: \.self) { n in
                        Button("\(n) unit\(n == 1 ? "" : "s")") { add(k, count: n) }
                    }
                }
            }
        } label: { Label("Add Effects", systemImage: "plus") }
        .fixedSize()
    }

    private func add(_ kind: SFXKind, count: Int) {
        let universe = 1
        var address = nextFree(universe)
        let existing = store.show.effects.devices.filter { $0.kind == kind }.count
        let w = store.show.stagePlot.stageWidth
        for i in 0..<count {
            var d = SFXDevice.make(kind, number: existing + i + 1, universe: universe, address: address)
            d.stageX = w * (Double(i) + 1) / (Double(count) + 1)
            d.stageY = kind == .fireworks ? store.show.stagePlot.stageDepth : 0.5
            store.show.effects.devices.append(d)
            address += d.footprint
            selectedID = d.id
        }
    }

    private func nextFree(_ u: Int) -> Int {
        let lights = lighting.fixtures.filter { $0.universe == u }.map(\.lastAddress).max() ?? 0
        let fx = store.show.effects.devices.filter { $0.universe == u }.map(\.lastAddress).max() ?? 0
        return min(510, max(lights, fx) + 1)
    }
}

struct DeviceInspector: View {
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var sfx: SFXEngine
    @EnvironmentObject var lighting: LightingEngine
    @Binding var selectedID: UUID?

    var body: some View {
        let conflicts = sfx.conflicts(fixtures: lighting.fixtures)
        Form {
            Section {
                HStack {
                    AddDeviceMenu(selectedID: $selectedID)
                    Spacer()
                    Button("Reload all") { sfx.reloadAll() }
                }
            }
            if let i = store.show.effects.devices.firstIndex(where: { $0.id == selectedID }) {
                let d = $store.show.effects.devices[i]
                Section(d.wrappedValue.kind.label) {
                    TextField("Name", text: d.name)
                    Stepper("Universe \(d.wrappedValue.universe)", value: d.universe, in: 1...64)
                    Stepper("Address \(d.wrappedValue.address)", value: d.address, in: 1...512)
                    if conflicts.contains(d.wrappedValue.id) {
                        Label("Address overlaps another device or light", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    }
                }
                Section("DMX channels (1 = start address)") {
                    Stepper("Fire channel \(d.wrappedValue.fireChannel)", value: d.fireChannel, in: 1...16)
                    Stepper("Fire value \(d.wrappedValue.fireValue)", value: d.fireValue, in: 1...255, step: 5)
                    optionalChannel("Safety / enable channel", d.safetyChannel)
                    if d.wrappedValue.safetyChannel != nil {
                        Stepper("Safety value \(d.wrappedValue.safetyValue)", value: d.safetyValue, in: 1...255, step: 5)
                    }
                    optionalChannel("Height channel", d.heightChannel)
                    if d.wrappedValue.heightChannel != nil {
                        Stepper("Height \(d.wrappedValue.height)", value: d.height, in: 0...255, step: 5)
                    }
                    Text("Check your unit's manual — flame units usually need the safety channel held at a set value before the fire channel works.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Limits") {
                    if !d.wrappedValue.kind.isOneShot {
                        LabeledContent("Max burst") {
                            HStack {
                                Slider(value: d.maxBurst, in: 0.2...(d.wrappedValue.kind == .coldSpark ? 30 : 6))
                                Text(String(format: "%.1fs", d.wrappedValue.maxBurst)).font(.caption.monospacedDigit()).frame(width: 40)
                            }
                        }
                    }
                    LabeledContent("Cooldown") {
                        HStack {
                            Slider(value: d.cooldown, in: 0...10)
                            Text(String(format: "%.1fs", d.wrappedValue.cooldown)).font(.caption.monospacedDigit()).frame(width: 40)
                        }
                    }
                    if d.wrappedValue.kind.isOneShot {
                        Stepper("Loads per refill: \(d.wrappedValue.loads ?? 1)",
                                value: Binding(get: { d.wrappedValue.loads ?? 1 }, set: { d.wrappedValue.loads = $0 }), in: 1...99)
                    }
                    Toggle("Allow song shows to auto-fire on drops", isOn: d.allowAuto)
                }
                Section {
                    Button("Delete \(d.wrappedValue.name)", role: .destructive) {
                        let id = d.wrappedValue.id
                        sfx.armedDevices.remove(id)
                        store.show.effects.devices.removeAll { $0.id == id }
                        selectedID = nil
                    }
                }
            } else {
                Section { Text("Select a device to patch it").foregroundStyle(.secondary) }
            }
            Section("Safety settings") {
                Stepper("Auto-safe after \(Int(store.show.effects.autoDisarmMinutes)) min idle",
                        value: $store.show.effects.autoDisarmMinutes, in: 0...120, step: 5)
                LabeledContent("Chase spacing") {
                    HStack {
                        Slider(value: $store.show.effects.chaseStep, in: 0.05...0.6)
                        Text(String(format: "%.2fs", store.show.effects.chaseStep)).font(.caption.monospacedDigit()).frame(width: 44)
                    }
                }
                Text("Set your Art-Net/sACN node to output zero if it loses signal, and keep each unit's own hardware safety and timeout on. Pyro must only be fired by a licensed operator with the system's own key switch armed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func optionalChannel(_ title: String, _ binding: Binding<Int?>) -> some View {
        Toggle(isOn: Binding(get: { binding.wrappedValue != nil }, set: { binding.wrappedValue = $0 ? 1 : nil })) {
            if let v = binding.wrappedValue {
                Stepper("\(title) \(v)", value: Binding(get: { v }, set: { binding.wrappedValue = $0 }), in: 1...16)
            } else {
                Text(title)
            }
        }
    }
}

// MARK: - Cue section

struct EffectCueSection: View {
    @EnvironmentObject var store: ShowStore
    @Binding var cue: Cue

    var body: some View {
        Section("Special effect") {
            Picker("Effect", selection: Binding(get: { cue.sfxKind ?? .co2 }, set: { cue.sfxKind = $0; cue.sfxDeviceIDs = nil })) {
                ForEach(SFXKind.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
            }
            let kind = cue.sfxKind ?? .co2
            let units = store.show.effects.devices.filter { $0.kind == kind }
            if units.isEmpty {
                Text("No \(kind.label.lowercased()) units patched — add them in Special Effects.").foregroundStyle(.secondary)
            } else {
                ForEach(units) { u in
                    Toggle(u.name, isOn: Binding(get: { cue.sfxDeviceIDs?.contains(u.id) ?? true }, set: { on in
                        var ids = cue.sfxDeviceIDs ?? units.map(\.id)
                        if on { if !ids.contains(u.id) { ids.append(u.id) } } else { ids.removeAll { $0 == u.id } }
                        cue.sfxDeviceIDs = ids
                    }))
                }
            }
            Picker("Pattern", selection: Binding(get: { cue.sfxPattern ?? .all }, set: { cue.sfxPattern = $0 })) {
                ForEach(SFXPattern.allCases) { Text($0.label).tag($0) }
            }
            if !kind.isOneShot {
                SecondsField(title: "Burst", value: Binding(get: { cue.sfxDuration ?? kind.defaultBurst }, set: { cue.sfxDuration = $0 }))
            }
            Text("Fires only when effects are armed. If they're not, the cue is skipped and logged.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Small armed/safe indicator + E-stop in the top bar (only when effects are patched).
struct SFXStatusPill: View {
    @EnvironmentObject var sfx: SFXEngine
    @EnvironmentObject var store: ShowStore
    var body: some View {
        if !store.show.effects.devices.isEmpty {
            HStack(spacing: 6) {
                Text(sfx.masterArmed ? "SFX ARMED" : "SFX SAFE")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(sfx.masterArmed ? Color.red : Color.gray.opacity(0.4)))
                if sfx.masterArmed {
                    Button("E-STOP") { sfx.emergencyStop() }
                        .font(.caption2.bold()).tint(.red).buttonStyle(.borderedProminent).controlSize(.mini)
                }
            }
        }
    }
}
