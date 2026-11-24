import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Undo history for stage design edits.
@MainActor
final class StageHistory: ObservableObject {
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private var undoStack: [StagePlot] = []
    private var redoStack: [StagePlot] = []

    func push(_ plot: StagePlot) {
        if undoStack.last == plot { return }
        undoStack.append(plot)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        canUndo = true; canRedo = false
    }
    func undo(_ plot: inout StagePlot) {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(plot); plot = prev
        canUndo = !undoStack.isEmpty; canRedo = true
    }
    func redo(_ plot: inout StagePlot) {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(plot); plot = next
        canUndo = true; canRedo = !redoStack.isEmpty
    }
}

struct StagePlotView: View {
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var crew: CrewAgent
    @EnvironmentObject var model: AppModel
    @StateObject private var history = StageHistory()
    @State private var selection: Set<UUID> = []
    @State private var tab = 0
    @State private var camera: CameraPreset = .foh
    @State private var crowd = false
    @State private var snap: Double = 0.25
    @State private var showRig = false
    @State private var showSet = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    Text("Stage Design").tag(0)
                    Text("3D View").tag(2)
                    Text("Input List").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 320)
                if tab == 2 {
                    CameraPresetBar(camera: $camera)
                    Toggle("Crowd", isOn: $crowd).toggleStyle(.button)
                    Blender3DToolbar(camera: camera, crowd: crowd)
                }
                Spacer()
                Button {
                    crew.ask(.creative, "Design my stage set from scratch for this lineup and venue. Choose the right stage size, place the artist, hype, dancers, DJ, band, risers, LED walls and PA so nothing overlaps and everyone has room, then rebuild the lighting rig to fit.")
                    model.section = .crew
                } label: { Label("Creative Director: Design Stage", systemImage: "paintpalette.fill") }
                    .tint(.purple).buttonStyle(.borderedProminent)
                    .disabled(crew.running != nil)
                    .help("The AI Creative Director designs and lays out the whole stage (needs the API key in AI Crew)")
                Button { showSet = true } label: { Label("Stage Set Builder…", systemImage: "person.3.sequence.fill") }
                    .help("Auto lay out the artist, hype, dancers, band, DJ and backline")
                Button { showRig = true } label: { Label("Light This Stage…", systemImage: "wand.and.rays") }
                    .help("Design and patch a lighting rig that fits this stage")
                Button {
                    RiderExporter.export(show: store.show)
                } label: {
                    Label("Export Tech Rider PDF", systemImage: "doc.richtext")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(8)
            Divider()
            if tab == 0 {
                StageToolsBar(selection: $selection, snap: $snap, history: history)
                Divider()
                HSplitView {
                    StagePalette(selection: $selection, history: history).frame(minWidth: 170, idealWidth: 190, maxWidth: 230)
                    VStack(spacing: 0) {
                        StageSizeBar(history: history)
                        StagePlotCanvas(plot: $store.show.stagePlot, selection: $selection, editable: true, snap: snap,
                                        onBeginEdit: { history.push(store.show.stagePlot) })
                            .padding(16)
                    }
                    .frame(minWidth: 480)
                    StageItemInspector(selection: $selection, history: history).frame(minWidth: 250, idealWidth: 270, maxWidth: 330)
                }
            } else if tab == 2 {
                Stage3DView(mode: .plot, camera: camera, showCrowd: crowd)
                    .overlay(alignment: .bottomLeading) {
                        Text("Edit in the Stage Design tab · drag to orbit · scroll to zoom")
                            .font(.caption).padding(8).background(.black.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 6)).padding(10)
                    }
            } else {
                InputListEditor()
            }
        }
        .sheet(isPresented: $showRig) { AutoRigSheet() }
        .sheet(isPresented: $showSet) { StageSetSheet() }
    }
}

// MARK: - Tools

private struct StageToolsBar: View {
    @EnvironmentObject var store: ShowStore
    @Binding var selection: Set<UUID>
    @Binding var snap: Double
    @ObservedObject var history: StageHistory

    private var plot: StagePlot { store.show.stagePlot }
    private var selected: [StageItem] { plot.items.filter { selection.contains($0.id) } }

    var body: some View {
        HStack(spacing: 8) {
            Button { history.undo(&store.show.stagePlot) } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!history.canUndo).help("Undo (⌘Z)").keyboardShortcut("z", modifiers: .command)
            Button { history.redo(&store.show.stagePlot) } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!history.canRedo).help("Redo (⇧⌘Z)").keyboardShortcut("z", modifiers: [.command, .shift])
            Divider().frame(height: 20)
            Picker("Snap", selection: $snap) {
                Text("Off").tag(0.01); Text("10 cm").tag(0.1); Text("25 cm").tag(0.25); Text("50 cm").tag(0.5); Text("1 m").tag(1.0)
            }
            .frame(width: 120)
            Divider().frame(height: 20)
            Group {
                Button { duplicate() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                    .keyboardShortcut("d", modifiers: .command)
                Button { mirror() } label: { Label("Mirror", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    .help("Add a mirrored copy on the other side of the centre line")
                Button { rotate(-15) } label: { Image(systemName: "rotate.left") }.help("Rotate −15°")
                Button { rotate(15) } label: { Image(systemName: "rotate.right") }.help("Rotate +15°")
                Menu {
                    Button("Left edges") { align(.left) }
                    Button("Centres (across)") { align(.centerX) }
                    Button("Right edges") { align(.right) }
                    Divider()
                    Button("Front edges") { align(.front) }
                    Button("Centres (depth)") { align(.centerY) }
                    Button("Back edges") { align(.back) }
                    Divider()
                    Button("Centre on stage") { align(.stageCenter) }
                    Divider()
                    Button("Distribute across") { distribute(horizontal: true) }.disabled(selected.count < 3)
                    Button("Distribute front-to-back") { distribute(horizontal: false) }.disabled(selected.count < 3)
                } label: { Label("Align", systemImage: "align.horizontal.center") }
                .fixedSize()
                Button { toggleLock() } label: {
                    Image(systemName: selected.allSatisfy { $0.locked == true } && !selected.isEmpty ? "lock.fill" : "lock.open")
                }
                .help("Lock / unlock (locked items can't be dragged)")
                Button(role: .destructive) { deleteSelected() } label: { Image(systemName: "trash") }
                    .keyboardShortcut(.delete, modifiers: [])
            }
            .disabled(selection.isEmpty)
            Divider().frame(height: 20)
            Button("Select All") { selection = Set(plot.items.map(\.id)) }.keyboardShortcut("a", modifiers: .command)
            Spacer()
            Menu {
                ForEach(StageTemplates.all, id: \.name) { t in
                    Button(t.name) {
                        history.push(store.show.stagePlot)
                        store.show.stagePlot = t.apply(store.show.stagePlot)
                        selection = []
                    }
                }
            } label: { Label("Stage Templates", systemImage: "square.on.square.dashed") }
            .fixedSize()
            .help("Replaces trusses, decks, screens and set pieces — keeps your band, mics and backline")
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func edit(_ change: (inout StagePlot) -> Void) {
        history.push(store.show.stagePlot)
        change(&store.show.stagePlot)
    }

    private func duplicate() {
        var new: Set<UUID> = []
        edit { p in
            for item in p.items where selection.contains(item.id) {
                var c = item; c.id = UUID(); c.x += 0.5; c.y -= 0.5; c.locked = nil
                p.items.append(c); new.insert(c.id)
            }
        }
        selection = new
    }

    private func mirror() {
        var new: Set<UUID> = []
        edit { p in
            for item in p.items where selection.contains(item.id) {
                var c = item; c.id = UUID(); c.x = p.stageWidth - item.x; c.rotation = -item.rotation
                p.items.append(c); new.insert(c.id)
            }
        }
        selection.formUnion(new)
    }

    private func rotate(_ d: Double) {
        edit { p in for i in p.items.indices where selection.contains(p.items[i].id) && p.items[i].locked != true {
            var r = p.items[i].rotation + d
            if r > 180 { r -= 360 }; if r < -180 { r += 360 }
            p.items[i].rotation = r
        } }
    }

    enum AlignMode { case left, centerX, right, front, centerY, back, stageCenter }

    private func align(_ m: AlignMode) {
        let items = selected
        guard !items.isEmpty else { return }
        let minX = items.map { $0.x - $0.width / 2 }.min()!, maxX = items.map { $0.x + $0.width / 2 }.max()!
        let minY = items.map { $0.y - $0.depth / 2 }.min()!, maxY = items.map { $0.y + $0.depth / 2 }.max()!
        edit { p in
            for i in p.items.indices where selection.contains(p.items[i].id) && p.items[i].locked != true {
                let it = p.items[i]
                switch m {
                case .left: p.items[i].x = minX + it.width / 2
                case .right: p.items[i].x = maxX - it.width / 2
                case .centerX: p.items[i].x = items.count == 1 ? p.stageWidth / 2 : (minX + maxX) / 2
                case .front: p.items[i].y = minY + it.depth / 2
                case .back: p.items[i].y = maxY - it.depth / 2
                case .centerY: p.items[i].y = items.count == 1 ? p.stageDepth / 2 : (minY + maxY) / 2
                case .stageCenter: p.items[i].x = p.stageWidth / 2
                }
            }
        }
    }

    private func distribute(horizontal: Bool) {
        let items = selected.sorted { horizontal ? $0.x < $1.x : $0.y < $1.y }
        guard items.count >= 3, let first = items.first, let last = items.last else { return }
        let a = horizontal ? first.x : first.y, b = horizontal ? last.x : last.y
        edit { p in
            for (k, it) in items.enumerated() {
                guard let i = p.items.firstIndex(where: { $0.id == it.id }), p.items[i].locked != true else { continue }
                let v = a + (b - a) * Double(k) / Double(items.count - 1)
                if horizontal { p.items[i].x = (v * 100).rounded() / 100 } else { p.items[i].y = (v * 100).rounded() / 100 }
            }
        }
    }

    private func toggleLock() {
        let lock = !selected.allSatisfy { $0.locked == true }
        edit { p in for i in p.items.indices where selection.contains(p.items[i].id) { p.items[i].locked = lock ? true : nil } }
    }

    private func deleteSelected() {
        edit { p in p.items.removeAll { selection.contains($0.id) && $0.locked != true } }
        selection = []
    }
}

private struct StageSizeBar: View {
    @EnvironmentObject var store: ShowStore
    @ObservedObject var history: StageHistory
    var body: some View {
        HStack {
            Text("Stage")
            TextField("W", value: $store.show.stagePlot.stageWidth, format: .number).frame(width: 50)
            Text("m wide ×")
            TextField("D", value: $store.show.stagePlot.stageDepth, format: .number).frame(width: 50)
            Text("m deep ·")
            Text("Height")
            TextField("H", value: Binding(get: { store.show.stagePlot.deck },
                                          set: { store.show.stagePlot.deckHeight = max(0, min(5, $0)) }), format: .number)
                .frame(width: 44)
            Stepper("", value: Binding(get: { store.show.stagePlot.deck },
                                       set: { history.push(store.show.stagePlot); store.show.stagePlot.deckHeight = max(0, min(5, ($0 * 10).rounded() / 10)) }),
                    in: 0...5, step: 0.1)
                .labelsHidden()
            Text("m")
            Menu("Presets") {
                Button("Floor level (0 m)") { setDeck(0) }
                Button("Club riser (0.6 m)") { setDeck(0.6) }
                Button("Venue stage (1.0 m)") { setDeck(1.0) }
                Button("Concert stage (1.2 m)") { setDeck(1.2) }
                Button("Festival stage (1.8 m)") { setDeck(1.8) }
                Button("Arena / stadium (2.2 m)") { setDeck(2.2) }
            }
            .fixedSize()
            Spacer()
            Text("Drag to move · ⇧-click to multi-select · arrows nudge · audience at the bottom")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }

    private func setDeck(_ h: Double) {
        history.push(store.show.stagePlot)
        store.show.stagePlot.deckHeight = h
    }
}

/// Region shown around the stage (metres) so front trusses, catwalks and B-stages fit.
struct PlotRegion {
    let minX: Double, maxX: Double, minY: Double, maxY: Double
    init(_ plot: StagePlot) {
        var lo = -1.5, hi = plot.stageWidth + 1.5, front = -2.0, back = plot.stageDepth + 1.0
        for it in plot.items {
            let r = max(it.width, it.depth) / 2 + 0.6
            lo = min(lo, it.x - r); hi = max(hi, it.x + r)
            front = min(front, it.y - r); back = max(back, it.y + r)
        }
        minX = lo; maxX = hi; minY = front; maxY = back
    }
    var width: Double { maxX - minX }
    var depth: Double { maxY - minY }
}

/// Draws the stage to scale with everything around it. Used in the editor and in the PDF rider.
struct StagePlotCanvas: View {
    @Binding var plot: StagePlot
    @Binding var selection: Set<UUID>
    var editable: Bool
    var printMode = false
    var snap: Double = 0.1
    var onBeginEdit: (() -> Void)? = nil
    @State private var dragOrigins: [UUID: CGPoint] = [:]
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geo in
            let region = PlotRegion(plot)
            let scale = min(geo.size.width / max(region.width, 1), (geo.size.height - 24) / max(region.depth, 1))
            let size = CGSize(width: region.width * scale, height: region.depth * scale)
            VStack(spacing: 4) {
                ZStack(alignment: .topLeading) {
                    StageGrid(plot: plot, region: region, scale: scale, printMode: printMode)
                        .frame(width: size.width, height: size.height)
                        .contentShape(Rectangle())
                        .onTapGesture { if editable { selection = [] } }
                    ForEach(plot.items) { item in
                        StageItemView(item: item, scale: scale, selected: selection.contains(item.id), printMode: printMode)
                            .position(x: (item.x - region.minX) * scale, y: (region.maxY - item.y) * scale)
                            .gesture(drag(item, scale: scale, region: region), including: editable ? .all : .subviews)
                            .onTapGesture { if editable { tap(item.id) } }
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipped()
                Text("▼  AUDIENCE / FOH  ▼")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(printMode ? Color.black : Color.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .focusable(editable)
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            guard editable, !selection.isEmpty else { return .ignored }
            let step = press.modifiers.contains(.shift) ? 1.0 : max(0.05, snap)
            onBeginEdit?()
            for i in plot.items.indices where selection.contains(plot.items[i].id) && plot.items[i].locked != true {
                switch press.key {
                case .leftArrow: plot.items[i].x -= step
                case .rightArrow: plot.items[i].x += step
                case .upArrow: plot.items[i].y += step
                case .downArrow: plot.items[i].y -= step
                default: break
                }
            }
            return .handled
        }
    }

    private func tap(_ id: UUID) {
        focused = true
        if NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
    }

    private func snapped(_ v: Double) -> Double { snap <= 0.011 ? (v * 100).rounded() / 100 : (v / snap).rounded() * snap }

    private func drag(_ item: StageItem, scale: Double, region: PlotRegion) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                focused = true
                if dragOrigins.isEmpty {
                    if !selection.contains(item.id) { selection = [item.id] }
                    onBeginEdit?()
                    for it in plot.items where selection.contains(it.id) { dragOrigins[it.id] = CGPoint(x: it.x, y: it.y) }
                }
                let dx = value.translation.width / scale
                let dy = -value.translation.height / scale
                for i in plot.items.indices {
                    guard let o = dragOrigins[plot.items[i].id], plot.items[i].locked != true else { continue }
                    plot.items[i].x = max(region.minX - 3, min(region.maxX + 3, snapped(o.x + dx)))
                    plot.items[i].y = max(region.minY - 3, min(region.maxY + 3, snapped(o.y + dy)))
                }
            }
            .onEnded { _ in dragOrigins.removeAll() }
    }
}

private struct StageGrid: View {
    let plot: StagePlot
    let region: PlotRegion
    let scale: Double
    let printMode: Bool

    var body: some View {
        Canvas { ctx, size in
            func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: (x - region.minX) * scale, y: (region.maxY - y) * scale) }
            let line = printMode ? Color.black.opacity(0.08) : Color.white.opacity(0.05)
            var m = floor(region.minX)
            while m <= region.maxX {
                var p = Path(); p.move(to: pt(m, region.minY)); p.addLine(to: pt(m, region.maxY))
                ctx.stroke(p, with: .color(line), lineWidth: 1); m += 1
            }
            m = floor(region.minY)
            while m <= region.maxY {
                var p = Path(); p.move(to: pt(region.minX, m)); p.addLine(to: pt(region.maxX, m))
                ctx.stroke(p, with: .color(line), lineWidth: 1); m += 1
            }
            // Stage deck
            let tl = pt(0, plot.stageDepth)
            let deck = CGRect(x: tl.x, y: tl.y, width: plot.stageWidth * scale, height: plot.stageDepth * scale)
            ctx.fill(Path(deck), with: .color(printMode ? Color.black.opacity(0.04) : Color(white: 0.15)))
            var g = Path()
            var x = 1.0
            while x < plot.stageWidth { g.move(to: pt(x, 0)); g.addLine(to: pt(x, plot.stageDepth)); x += 1 }
            var y = 1.0
            while y < plot.stageDepth { g.move(to: pt(0, y)); g.addLine(to: pt(plot.stageWidth, y)); y += 1 }
            ctx.stroke(g, with: .color(printMode ? .black.opacity(0.15) : .white.opacity(0.08)), lineWidth: 1)
            ctx.stroke(Path(deck), with: .color(printMode ? .black : .white.opacity(0.6)), lineWidth: 2)
            // Centre line
            var centre = Path()
            centre.move(to: pt(plot.stageWidth / 2, region.minY)); centre.addLine(to: pt(plot.stageWidth / 2, region.maxY))
            ctx.stroke(centre, with: .color(.red.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
            ctx.draw(Text("DSL").font(.system(size: 9)).foregroundColor(.secondary), at: pt(0.4, 0.3))
            ctx.draw(Text("DSR").font(.system(size: 9)).foregroundColor(.secondary), at: pt(plot.stageWidth - 0.4, 0.3))
        }
        .background(printMode ? Color.white : Color(white: 0.08))
    }
}

private struct StageItemView: View {
    let item: StageItem
    let scale: Double
    let selected: Bool
    let printMode: Bool

    var body: some View {
        let w = max(item.kind.isRigging ? 8 : 18, item.width * scale)
        let h = max(item.kind == .truss ? 8 : 18, item.depth * scale)
        let stroke = selected ? Color.white : item.kind.color
        ZStack {
            switch item.kind {
            case .truss:
                TrussShape().fill(item.kind.color.opacity(0.25))
                TrussShape().stroke(stroke, lineWidth: selected ? 2 : 1)
            case .trussTower:
                Rectangle().stroke(stroke, lineWidth: selected ? 2 : 1.2)
                Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: w, y: h)); p.move(to: CGPoint(x: w, y: 0)); p.addLine(to: CGPoint(x: 0, y: h)) }
                    .stroke(stroke, lineWidth: 1)
            case .scrim:
                Rectangle().stroke(stroke, style: StrokeStyle(lineWidth: selected ? 2 : 1.2, dash: [4, 3]))
            default:
                if item.kind.isRound {
                    Circle().fill(item.kind.color.opacity(printMode ? 0.15 : 0.28))
                    Circle().stroke(stroke, lineWidth: selected ? 2.5 : 1.2)
                } else {
                    RoundedRectangle(cornerRadius: item.kind.isDeck ? 2 : 4).fill(item.kind.color.opacity(printMode ? 0.18 : 0.3))
                    RoundedRectangle(cornerRadius: item.kind.isDeck ? 2 : 4).stroke(stroke, lineWidth: selected ? 2.5 : 1.2)
                }
            }
            if !item.kind.isRigging || w > 60 {
                VStack(spacing: 1) {
                    if item.kind != .label && min(w, h) > 22 {
                        Image(systemName: item.kind.symbol).font(.system(size: min(18, max(9, min(w, h) * 0.35))))
                    }
                    Text(item.label)
                        .font(.system(size: max(8, min(12, w / 7)), weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    if item.kind.isRigging || item.kind.isDeck {
                        Text(String(format: "%.1f m", item.topHeight)).font(.system(size: 8)).opacity(0.7)
                    }
                }
                .foregroundStyle(printMode ? Color.black : Color.white)
                .padding(2)
            }
            if item.locked == true {
                Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(.yellow)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(2)
            }
        }
        .frame(width: w, height: h)
        .rotationEffect(.degrees(item.rotation))
    }
}

private struct TrussShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addRect(r)
        let step = max(6, r.height)
        var x = r.minX
        var up = true
        while x < r.maxX {
            let nx = min(r.maxX, x + step)
            p.move(to: CGPoint(x: x, y: up ? r.maxY : r.minY))
            p.addLine(to: CGPoint(x: nx, y: up ? r.minY : r.maxY))
            x = nx; up.toggle()
        }
        return p
    }
}

private struct StagePalette: View {
    @EnvironmentObject var store: ShowStore
    @Binding var selection: Set<UUID>
    @ObservedObject var history: StageHistory

    var body: some View {
        List {
            Section("Structure & set") { ForEach(StageItemKind.structure) { row($0) } }
            Section("Band & backline") { ForEach(StageItemKind.band) { row($0) } }
        }
    }

    private func row(_ kind: StageItemKind) -> some View {
        Button {
            history.push(store.show.stagePlot)
            let size = kind.defaultSize
            let p = store.show.stagePlot
            var y = p.stageDepth / 2
            var width = size.width
            switch kind {
            case .truss: y = p.stageDepth - 1; width = p.stageWidth
            case .catwalk: y = -size.height / 2
            case .bStage: y = -7
            case .ledWall, .scrim: y = p.stageDepth - 0.4
            case .lineArray: y = -1
            default: break
            }
            var item = StageItem(kind: kind, label: kind.label, x: p.stageWidth / 2, y: y, width: width, depth: size.height)
            if kind == .lineArray { item.x = -1.5 }
            store.show.stagePlot.items.append(item)
            selection = [item.id]
        } label: {
            Label(kind.label, systemImage: kind.symbol).foregroundStyle(kind.color)
        }
        .buttonStyle(.plain)
    }
}

private struct StageItemInspector: View {
    @EnvironmentObject var store: ShowStore
    @Binding var selection: Set<UUID>
    @ObservedObject var history: StageHistory

    var body: some View {
        if selection.count == 1, let id = selection.first, let i = store.show.stagePlot.items.firstIndex(where: { $0.id == id }) {
            let item = $store.show.stagePlot.items[i]
            Form {
                Section(item.wrappedValue.kind.label) {
                    TextField("Label", text: item.label)
                    Picker("Type", selection: item.kind) {
                        ForEach(StageItemKind.allCases) { Text($0.label).tag($0) }
                    }
                    LabeledContent("Width (m)") { TextField("", value: item.width, format: .number) }
                    LabeledContent("Depth (m)") { TextField("", value: item.depth, format: .number) }
                    LabeledContent("Across (m)") { TextField("", value: item.x, format: .number) }
                    LabeledContent("From front (m)") { TextField("", value: item.y, format: .number) }
                    HStack {
                        Text("Rotate")
                        Slider(value: item.rotation, in: -180...180, step: 15)
                        Text("\(Int(item.wrappedValue.rotation))°").frame(width: 40)
                    }
                }
                Section("Height") {
                    LabeledContent(item.wrappedValue.kind.isRigging ? "Trim height (m)" : "Height (m)") {
                        HStack {
                            Slider(value: Binding(get: { item.wrappedValue.topHeight }, set: { item.wrappedValue.height = ($0 * 10).rounded() / 10 }),
                                   in: 0...(item.wrappedValue.kind.isRigging ? 18 : 8))
                            Text(String(format: "%.1f", item.wrappedValue.topHeight)).frame(width: 34)
                        }
                    }
                    if !item.wrappedValue.kind.isRigging && !item.wrappedValue.kind.isFloorDeck {
                        LabeledContent("Lift above deck (m)") {
                            HStack {
                                Slider(value: Binding(get: { item.wrappedValue.elevation ?? 0 }, set: { item.wrappedValue.elevation = $0 == 0 ? nil : ($0 * 10).rounded() / 10 }), in: 0...4)
                                Text(String(format: "%.1f", item.wrappedValue.elevation ?? 0)).frame(width: 34)
                            }
                        }
                    }
                    Toggle("Locked", isOn: Binding(get: { item.wrappedValue.locked == true }, set: { item.wrappedValue.locked = $0 ? true : nil }))
                }
                Section {
                    TextField("Notes", text: item.notes, axis: .vertical).lineLimit(2...4)
                }
            }
            .formStyle(.grouped)
        } else if selection.count > 1 {
            VStack(spacing: 10) {
                Text("\(selection.count) items selected").font(.headline)
                Text("Drag any of them to move the group. Use Align in the toolbar to line them up, or Mirror to make a symmetric copy.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Set same height…") {
                    let h = store.show.stagePlot.items.first { selection.contains($0.id) }?.topHeight ?? 1
                    history.push(store.show.stagePlot)
                    for k in store.show.stagePlot.items.indices where selection.contains(store.show.stagePlot.items[k].id) {
                        store.show.stagePlot.items[k].height = h
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Text("Select something on the stage").foregroundStyle(.secondary)
                Text("Start from a Stage Template, or add trusses, decks and screens from the list on the left.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Templates

struct StageTemplate {
    let name: String
    let width: Double
    let depth: Double
    let build: (Double, Double) -> [StageItem]

    func apply(_ plot: StagePlot) -> StagePlot {
        var p = plot
        p.items.removeAll { $0.kind.isStructure }
        p.stageWidth = width
        p.stageDepth = depth
        // keep band items on the (possibly smaller) stage
        for i in p.items.indices {
            p.items[i].x = min(max(0.3, p.items[i].x), width - 0.3)
            p.items[i].y = min(max(0.3, p.items[i].y), depth - 0.3)
        }
        p.items += build(width, depth)
        return p
    }
}

enum StageTemplates {
    static func item(_ k: StageItemKind, _ label: String, x: Double, y: Double, w: Double, d: Double,
                     h: Double? = nil, rot: Double = 0) -> StageItem {
        var i = StageItem(kind: k, label: label, x: x, y: y, width: w, depth: d, rotation: rot)
        i.height = h
        return i
    }

    static let all: [StageTemplate] = [
        StageTemplate(name: "Club stage", width: 8, depth: 5) { w, d in [
            item(.truss, "Front truss", x: w / 2, y: -1, w: w + 1, d: 0.3, h: 4.5),
            item(.truss, "Back truss", x: w / 2, y: d - 0.6, w: w, d: 0.3, h: 4.5),
            item(.ledWall, "LED wall", x: w / 2, y: d - 0.25, w: w * 0.75, d: 0.3, h: 3),
            item(.djBooth, "DJ booth", x: w / 2, y: d * 0.6, w: 1.8, d: 0.9)
        ] },
        StageTemplate(name: "Proscenium concert", width: 12, depth: 8) { w, d in [
            item(.truss, "Front truss", x: w / 2, y: -1, w: w + 1, d: 0.3, h: 6),
            item(.truss, "Mid truss", x: w / 2, y: d * 0.5, w: w, d: 0.3, h: 6.5),
            item(.truss, "Back truss", x: w / 2, y: d - 0.8, w: w, d: 0.3, h: 7),
            item(.trussTower, "Tower SL", x: -0.6, y: -1, w: 0.5, d: 0.5, h: 7),
            item(.trussTower, "Tower SR", x: w + 0.6, y: -1, w: 0.5, d: 0.5, h: 7),
            item(.trussTower, "Tower USL", x: -0.6, y: d - 0.8, w: 0.5, d: 0.5, h: 7),
            item(.trussTower, "Tower USR", x: w + 0.6, y: d - 0.8, w: 0.5, d: 0.5, h: 7),
            item(.ledWall, "LED wall", x: w / 2, y: d - 0.3, w: w * 0.7, d: 0.3, h: 5),
            item(.drumRiser, "Band riser", x: w / 2, y: d * 0.7, w: 3, d: 2.4, h: 0.6),
            item(.stairs, "Stairs", x: w / 2 - 2.2, y: d * 0.7, w: 1.2, d: 1.2, h: 0.6),
            item(.lineArray, "PA L", x: -2, y: -1.2, w: 0.8, d: 0.8, h: 7),
            item(.lineArray, "PA R", x: w + 2, y: -1.2, w: 0.8, d: 0.8, h: 7)
        ] },
        StageTemplate(name: "Festival main stage", width: 18, depth: 12) { w, d in [
            item(.truss, "Front truss", x: w / 2, y: -1.2, w: w + 2, d: 0.4, h: 9),
            item(.truss, "Mid truss 1", x: w / 2, y: d * 0.35, w: w, d: 0.4, h: 9.5),
            item(.truss, "Mid truss 2", x: w / 2, y: d * 0.65, w: w, d: 0.4, h: 10),
            item(.truss, "Back truss", x: w / 2, y: d - 1, w: w, d: 0.4, h: 10.5),
            item(.truss, "Ladder SL", x: 1.5, y: d * 0.5, w: d * 0.8, d: 0.3, h: 8, rot: 90),
            item(.truss, "Ladder SR", x: w - 1.5, y: d * 0.5, w: d * 0.8, d: 0.3, h: 8, rot: 90),
            item(.trussTower, "Tower SL", x: -1, y: -1.2, w: 0.6, d: 0.6, h: 10),
            item(.trussTower, "Tower SR", x: w + 1, y: -1.2, w: 0.6, d: 0.6, h: 10),
            item(.ledWall, "Main LED", x: w / 2, y: d - 0.4, w: w * 0.6, d: 0.3, h: 7),
            item(.ledWall, "IMAG L", x: -3.5, y: 1, w: 4, d: 0.3, h: 5),
            item(.ledWall, "IMAG R", x: w + 3.5, y: 1, w: 4, d: 0.3, h: 5),
            item(.lineArray, "PA L", x: -2.2, y: -1.5, w: 1, d: 1, h: 9),
            item(.lineArray, "PA R", x: w + 2.2, y: -1.5, w: 1, d: 1, h: 9),
            item(.riser, "Band riser L", x: w * 0.3, y: d * 0.72, w: 4, d: 2.4, h: 0.8),
            item(.riser, "Band riser R", x: w * 0.7, y: d * 0.72, w: 4, d: 2.4, h: 0.8),
            item(.ledFloor, "LED floor", x: w / 2, y: d * 0.35, w: 6, d: 3)
        ] },
        StageTemplate(name: "Thrust + B-stage", width: 12, depth: 8) { w, d in [
            item(.truss, "Front truss", x: w / 2, y: -1, w: w + 1, d: 0.3, h: 6),
            item(.truss, "Back truss", x: w / 2, y: d - 0.8, w: w, d: 0.3, h: 7),
            item(.ledWall, "LED wall", x: w / 2, y: d - 0.3, w: w * 0.7, d: 0.3, h: 5),
            item(.catwalk, "Catwalk", x: w / 2, y: -4, w: 2, d: 8),
            item(.bStage, "B-stage", x: w / 2, y: -9.5, w: 4.5, d: 4.5),
            item(.truss, "B-stage truss A", x: w / 2, y: -9.5, w: 5.5, d: 0.3, h: 6),
            item(.truss, "B-stage truss B", x: w / 2, y: -9.5, w: 5.5, d: 0.3, h: 6, rot: 90),
            item(.ledFloor, "Catwalk LED", x: w / 2, y: -4, w: 1.6, d: 7.6)
        ] },
        StageTemplate(name: "In the round", width: 10, depth: 10) { w, d in [
            item(.roundRiser, "Centre stage", x: w / 2, y: d / 2, w: 9, d: 9, h: 0.6),
            item(.truss, "Truss N", x: w / 2, y: d + 0.6, w: w + 1.4, d: 0.3, h: 7),
            item(.truss, "Truss S", x: w / 2, y: -0.6, w: w + 1.4, d: 0.3, h: 7),
            item(.truss, "Truss W", x: -0.6, y: d / 2, w: d + 1.4, d: 0.3, h: 7, rot: 90),
            item(.truss, "Truss E", x: w + 0.6, y: d / 2, w: d + 1.4, d: 0.3, h: 7, rot: 90),
            item(.lineArray, "PA NW", x: -1.5, y: d + 1.5, w: 0.8, d: 0.8, h: 8),
            item(.lineArray, "PA NE", x: w + 1.5, y: d + 1.5, w: 0.8, d: 0.8, h: 8),
            item(.lineArray, "PA SW", x: -1.5, y: -1.5, w: 0.8, d: 0.8, h: 8),
            item(.lineArray, "PA SE", x: w + 1.5, y: -1.5, w: 0.8, d: 0.8, h: 8)
        ] },
        StageTemplate(name: "T-stage runway", width: 12, depth: 6) { w, d in [
            item(.truss, "Front truss", x: w / 2, y: -1, w: w + 1, d: 0.3, h: 5.5),
            item(.truss, "Back truss", x: w / 2, y: d - 0.6, w: w, d: 0.3, h: 6),
            item(.truss, "Runway truss", x: w / 2, y: -5.5, w: 10, d: 0.3, h: 5.5, rot: 90),
            item(.catwalk, "Runway", x: w / 2, y: -5.5, w: 2.4, d: 11),
            item(.ledFloor, "Runway LED", x: w / 2, y: -5.5, w: 2, d: 10.6),
            item(.scrim, "Gauze", x: w / 2, y: d - 0.2, w: w, d: 0.1, h: 5)
        ] }
    ]
}


// MARK: - Input list

private struct InputListEditor: View {
    @EnvironmentObject var store: ShowStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    let next = (store.show.inputList.map(\.channel).max() ?? 0) + 1
                    store.show.inputList.append(InputChannel(channel: next, source: "", micOrDI: ""))
                } label: { Label("Add channel", systemImage: "plus") }
                Button("Renumber 1…n") {
                    for i in store.show.inputList.indices { store.show.inputList[i].channel = i + 1 }
                }
                Spacer()
            }
            .padding(8)
            HStack {
                Text("Ch").frame(width: 44, alignment: .leading)
                Text("Source").frame(width: 190, alignment: .leading)
                Text("Mic / DI").frame(width: 190, alignment: .leading)
                Text("Stand").frame(width: 120, alignment: .leading)
                Text("48V").frame(width: 40)
                Text("Notes").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            List {
                ForEach($store.show.inputList) { $ch in
                    HStack {
                        TextField("#", value: $ch.channel, format: .number).frame(width: 44)
                        TextField("Source", text: $ch.source).frame(width: 190)
                        TextField("Mic / DI", text: $ch.micOrDI).frame(width: 190)
                        TextField("Stand", text: $ch.stand).frame(width: 120)
                        Toggle("", isOn: $ch.phantom).labelsHidden().frame(width: 40)
                        TextField("Notes", text: $ch.notes)
                        Button(role: .destructive) {
                            let id = ch.id
                            store.show.inputList.removeAll { $0.id == id }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                .onMove { store.show.inputList.move(fromOffsets: $0, toOffset: $1) }
            }
        }
    }
}

// MARK: - PDF rider

@MainActor
enum RiderExporter {
    static let pageSize = CGSize(width: 612, height: 792)   // US Letter

    static func export(show: Show) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let artist = show.venue.artist.isEmpty ? show.name : show.venue.artist
        panel.nameFieldStringValue = "\(artist) Tech Rider\(show.venue.venueName.isEmpty ? "" : " — \(show.venue.venueName)").pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var box = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        let pages: [AnyView] = [
            AnyView(RiderPlotPage(show: show)),
            AnyView(RiderInputPage(show: show))
        ]
        for page in pages {
            let renderer = ImageRenderer(content: page.frame(width: pageSize.width, height: pageSize.height).background(Color.white))
            renderer.render { _, draw in
                context.beginPDFPage(nil)
                draw(context)
                context.endPDFPage()
            }
        }
        context.closePDF()
        NSWorkspace.shared.open(url)
    }
}

private struct RiderHeader: View {
    let show: Show
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(show.venue.artist.isEmpty ? show.name : show.venue.artist).font(.system(size: 24, weight: .black))
                Spacer()
                Text(title).font(.system(size: 14, weight: .bold)).foregroundStyle(Color(red: 0.55, green: 0.1, blue: 0.6))
            }
            Text([show.venue.tourName, show.venue.venueName, show.venue.city,
                  show.venue.showDate.formatted(date: .long, time: .omitted)]
                    .filter { !$0.isEmpty }.joined(separator: "  ·  "))
                .font(.system(size: 10)).foregroundStyle(Color.gray)
            Rectangle().fill(Color.black).frame(height: 2).padding(.top, 4)
        }
    }
}

private struct RiderPlotPage: View {
    let show: Show
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RiderHeader(show: show, title: "STAGE PLOT")
            StagePlotCanvas(plot: .constant(show.stagePlot), selection: .constant([]), editable: false, printMode: true)
                .frame(height: 400)
            Text("Stage: \(show.stagePlot.stageWidth, specifier: "%.1f") m wide × \(show.stagePlot.stageDepth, specifier: "%.1f") m deep × \(show.stagePlot.deck, specifier: "%.1f") m high (grid = 1 m)")
                .font(.system(size: 9)).foregroundStyle(Color.gray)
            RiderFacts(venue: show.venue)
            Spacer()
            Text("Generated by STRDM Stage · Stardom Records LLC").font(.system(size: 8)).foregroundStyle(Color.gray)
        }
        .padding(36)
        .foregroundStyle(Color.black)
    }
}

private struct Fact { let label: String; let value: String }

private struct RiderFacts: View {
    let venue: VenueInfo
    var body: some View {
        let all: [Fact] = [
            Fact(label: "Load-in", value: venue.loadIn), Fact(label: "Soundcheck", value: venue.soundcheck),
            Fact(label: "Doors", value: venue.doors), Fact(label: "Set time", value: venue.setTime),
            Fact(label: "Set length", value: venue.setLength), Fact(label: "Power", value: venue.power),
            Fact(label: "PA", value: venue.paSystem), Fact(label: "Lighting", value: venue.lightingDesk),
            Fact(label: "Video", value: venue.videoNotes), Fact(label: "Production contact", value: venue.productionContact)
        ]
        let facts = all.filter { !$0.value.isEmpty }
        VStack(alignment: .leading, spacing: 3) {
            ForEach(facts, id: \.label) { f in
                HStack(alignment: .top) {
                    Text(f.label).font(.system(size: 9, weight: .bold)).frame(width: 110, alignment: .leading)
                    Text(f.value).font(.system(size: 9))
                }
            }
        }
    }
}

private struct RiderInputPage: View {
    let show: Show
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RiderHeader(show: show, title: "INPUT LIST")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                GridRow {
                    Text("CH"); Text("SOURCE"); Text("MIC / DI"); Text("STAND"); Text("48V"); Text("NOTES")
                }
                .font(.system(size: 9, weight: .bold))
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(show.inputList) { ch in
                    GridRow {
                        Text("\(ch.channel)").font(.system(size: 10, weight: .bold))
                        Text(ch.source)
                        Text(ch.micOrDI)
                        Text(ch.stand)
                        Text(ch.phantom ? "✓" : "")
                        Text(ch.notes).foregroundStyle(Color.gray)
                    }
                    .font(.system(size: 10))
                }
            }
            if !show.venue.hospitality.isEmpty || !show.venue.notes.isEmpty {
                Rectangle().fill(Color.black).frame(height: 1).padding(.top, 8)
                if !show.venue.hospitality.isEmpty {
                    Text("HOSPITALITY").font(.system(size: 10, weight: .bold))
                    Text(show.venue.hospitality).font(.system(size: 10))
                }
                if !show.venue.notes.isEmpty {
                    Text("NOTES").font(.system(size: 10, weight: .bold))
                    Text(show.venue.notes).font(.system(size: 10))
                }
            }
            Spacer()
        }
        .padding(36)
        .foregroundStyle(Color.black)
    }
}
