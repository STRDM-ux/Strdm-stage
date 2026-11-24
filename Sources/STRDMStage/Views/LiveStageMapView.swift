import SwiftUI

/// Real-time top-down view of the stage: every fixture's beam, colour and level, plus draggable performers.
struct LiveStageMapView: View {
    var isPopout = false
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var lighting: LightingEngine
    @Environment(\.openWindow) private var openWindow
    @State private var editRig = false
    @AppStorage("STRDMStage.map3D") private var show3D = false
    @AppStorage("STRDMStage.popoutLayout") private var popoutLayout = 2   // 0 = 2D, 1 = 3D, 2 = split
    @State private var camera: CameraPreset = .foh
    @State private var crowd = true

    var body: some View {
        VStack(spacing: 0) {
            MapControls(editRig: $editRig)
            Divider()
            if !store.show.effects.devices.isEmpty {
                MapEffectsStrip()
                Divider()
            }
            HStack(spacing: 10) {
                if isPopout {
                    Picker("", selection: $popoutLayout) {
                        Text("2D Map").tag(0)
                        Text("3D Venue").tag(1)
                        Text("2D + 3D").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 280)
                } else {
                    Picker("", selection: $show3D) {
                        Text("2D Map").tag(false)
                        Text("3D Venue").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                }
                if !isPopout {
                    Button { openWindow(id: "liveMapPopout") } label: { Label("Pop Out", systemImage: "macwindow.on.rectangle") }
                        .help("Open the live map in its own big window — drag it to another screen or make it full screen (⇧⌘L)")
                }
                if wants3D {
                    CameraPresetBar(camera: $camera)
                    Toggle("Crowd", isOn: $crowd).toggleStyle(.button)
                    Spacer()
                    Blender3DToolbar(camera: camera, crowd: crowd)
                } else {
                    Spacer()
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color(white: 0.08))
            if wants3D { Viewer3DBar() }
            if isPopout && popoutLayout == 2 {
                HSplitView {
                    StageMapCanvas(editRig: editRig)
                        .padding(12)
                        .frame(minWidth: 300)
                    Stage3DView(mode: .live, camera: camera, showCrowd: crowd)
                        .frame(minWidth: 400)
                }
            } else if wants3D {
                Stage3DView(mode: .live, camera: camera, showCrowd: crowd)
            } else {
                StageMapCanvas(editRig: editRig)
                    .padding(12)
            }
        }
        .background(Color.black)
    }

    private var wants3D: Bool { isPopout ? popoutLayout != 0 : show3D }
}

private struct MapControls: View {
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var lighting: LightingEngine
    @Binding var editRig: Bool
    @State private var showRig = false

    var body: some View {
        HStack(spacing: 14) {
            SongHUD()
            Spacer()
            Picker("Movers follow", selection: $lighting.followTargetID) {
                Text("Nobody").tag(UUID?.none)
                ForEach(lighting.performers) { p in Text(p.label).tag(Optional(p.id)) }
            }
            .frame(width: 220)
            .help("Aim every moving head at a performer. Drag the performer and the beams follow.")
            Toggle("Edit rig", isOn: $editRig).toggleStyle(.button)
                .help("Drag fixtures to where they really hang")
            Button("Auto Rig…") { showRig = true }
                .help("Design, place and patch a rig that fits the stage design")
                .sheet(isPresented: $showRig) { AutoRigSheet() }
            Divider().frame(height: 22)
            LiveModeBar()
            GMControl(width: 170)
            Toggle("Blackout", isOn: $lighting.blackout).toggleStyle(.button).tint(.yellow)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(white: 0.08))
    }
}

private struct SongHUD: View {
    @EnvironmentObject var lighting: LightingEngine

    var body: some View {
        if let s = lighting.songStatus {
            HStack(spacing: 10) {
                Image(systemName: s.vibe.symbol).font(.title2).foregroundStyle(.pink)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name).font(.headline).lineLimit(1)
                    Text("\(s.section) · \(s.pattern) · \(s.moverMove) · \(Int(s.bpm.rounded())) BPM · \(formatTime(s.elapsed)) / \(formatTime(s.duration))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    ForEach(0..<4, id: \.self) { b in
                        Circle()
                            .fill(s.beat % 4 == b ? (b == 0 ? Color.pink : Color.white) : Color.white.opacity(0.15))
                            .frame(width: 10, height: 10)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("Live Stage Map").font(.headline)
                Text("No song show running. Fire a song cue, or preview one in Light Set Builder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct EffectSnapshot: Identifiable {
    let id: UUID
    let name: String
    let kind: SFXKind
    let position: CGPoint
    let firing: Bool
    let age: Double
    let armed: Bool
}

/// Effects controls on the live map: arm state, fire, 3D/map preview and E-stop.
private struct MapEffectsStrip: View {
    @EnvironmentObject var sfx: SFXEngine
    @EnvironmentObject var store: ShowStore
    @State private var pattern: SFXPattern = .leftToRight

    var body: some View {
        let kinds = SFXKind.allCases.filter { k in store.show.effects.devices.contains { $0.kind == k } }
        HStack(spacing: 10) {
            Text(sfx.masterArmed ? "SFX ARMED" : "SFX SAFE")
                .font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(sfx.masterArmed ? Color.red : Color.gray.opacity(0.4)))
            Picker("", selection: $pattern) {
                ForEach(SFXPattern.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden().frame(width: 170)
            if sfx.masterArmed {
                ForEach(kinds) { k in
                    Button { sfx.fire(kind: k, pattern: pattern, source: .manual) } label: { Label(k.plural, systemImage: k.symbol) }
                        .buttonStyle(.borderedProminent).tint(k.tint).controlSize(.small)
                }
            }
            Text("Preview:").font(.caption).foregroundStyle(.secondary)
            ForEach(kinds) { k in
                Button { sfx.preview(kind: k, pattern: pattern) } label: { Image(systemName: k.symbol) }
                    .help("Preview \(k.plural) on the map and in 3D — no DMX")
                    .controlSize(.small)
            }
            Button("All") { for k in kinds { sfx.preview(kind: k, pattern: pattern) } }.controlSize(.small)
            Spacer()
            Button("E-STOP") { sfx.emergencyStop() }
                .buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(sfx.masterArmed ? Color.red.opacity(0.15) : Color(white: 0.06))
    }
}

/// Plain values copied out of the engine each frame so the Canvas can draw without touching the main actor.
private struct BeamSnapshot: Identifiable {
    let id: UUID
    let name: String
    let role: FixtureRole
    let position: CGPoint
    let target: CGPoint
    let rgb: RGB
    let level: Double
    var laserLook: LaserLook = .off
    var laserRotation: Double = 0
    var laserX: Double = 64
}

private struct StageMapCanvas: View {
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var lighting: LightingEngine
    @EnvironmentObject var sfx: SFXEngine
    let editRig: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            GeometryReader { geo in
                let w = store.show.stagePlot.stageWidth
                let d = store.show.stagePlot.stageDepth
                var geometry = MapGeometry(stageWidth: w, stageDepth: d, size: geo.size)
                let _ = {
                    let ys = store.show.stagePlot.items.map { $0.y - max($0.width, $0.depth) / 2 }
                    let xs = store.show.stagePlot.items.flatMap { [$0.x - $0.width / 2, w - ($0.x + $0.width / 2)] }
                    geometry.front = max(2.5, -(ys.min() ?? 0) + 1)
                    geometry.marginX = max(1, -(xs.min() ?? 0) + 0.5)
                }()
                let beams = snapshot()
                let props = store.show.stagePlot.items.filter { $0.kind != .person && $0.kind != .vocalMic }
                let fx = effectSnapshot(w: w, d: d)
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in
                        Self.drawStage(&ctx, geometry, props)
                        Self.drawBeams(&ctx, geometry, beams)
                        Self.drawEffects(&ctx, geometry, fx)
                    }
                    ForEach(lighting.performers) { p in
                        PerformerMarker(item: p, followed: lighting.followTargetID == p.id)
                            .position(geometry.point(lighting.performerPosition(p)))
                            .gesture(DragGesture().onChanged { v in
                                lighting.performerPositions[p.id] = geometry.stage(v.location)
                            })
                            .onTapGesture(count: 2) {
                                lighting.followTargetID = lighting.followTargetID == p.id ? nil : p.id
                            }
                    }
                    if editRig {
                        ForEach(fx) { e in
                            Circle()
                                .stroke(Color.orange, lineWidth: 2)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                                .position(geometry.point(e.position))
                                .gesture(DragGesture().onChanged { v in
                                    sfx.moveDevice(e.id, to: geometry.stage(v.location))
                                })
                        }
                        ForEach(beams) { b in
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.yellow, lineWidth: 2)
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                                .position(geometry.point(b.position))
                                .gesture(DragGesture().onChanged { v in
                                    lighting.moveFixture(b.id, to: geometry.stage(v.location))
                                })
                        }
                    }
                }
            }
        }
    }

    private func effectSnapshot(w: Double, d: Double) -> [EffectSnapshot] {
        let now = Date()
        return sfx.devices.map { dev in
            let firing = sfx.isVisuallyFiring(dev, now: now)
            let age = sfx.visualStart[dev.id].map { now.timeIntervalSince($0) } ?? 999
            return EffectSnapshot(id: dev.id, name: dev.name, kind: dev.kind,
                                  position: sfx.stagePosition(dev, stageWidth: w, stageDepth: d),
                                  firing: firing, age: age,
                                  armed: sfx.masterArmed && sfx.armedDevices.contains(dev.id))
        }
    }

    /// Top-down effect drawing: flame/CO₂/spark plumes while firing, confetti/firework bursts for a few seconds after.
    nonisolated private static func drawEffects(_ ctx: inout GraphicsContext, _ g: MapGeometry, _ fx: [EffectSnapshot]) {
        var lit = ctx
        lit.blendMode = .plusLighter
        for e in fx {
            let c = g.point(e.position)
            let s = g.scale
            let t = e.age
            switch e.kind {
            case .flame where e.firing, .coldSpark where e.firing, .co2 where e.firing:
                let flick = 0.85 + 0.15 * sin(t * 40)
                let r = s * (e.kind == .co2 ? 1.6 : 1.1) * min(1, t * 6) * flick
                let colors: [Color] = e.kind == .flame ? [.white, .yellow, .orange, Color.red.opacity(0.6), .clear]
                    : e.kind == .co2 ? [Color.white.opacity(0.9), Color.white.opacity(0.45), Color.cyan.opacity(0.15), .clear]
                    : [.white, Color.yellow.opacity(0.8), Color.orange.opacity(0.3), .clear]
                let layer = e.kind == .co2 ? ctx : lit
                layer.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                           with: .radialGradient(Gradient(colors: colors), center: c, startRadius: 0, endRadius: r))
                if e.kind == .coldSpark {
                    for k in 0..<24 {
                        let a = Double(k) * 0.261 + t * 3
                        let dist = r * (0.3 + 0.7 * abs(sin(Double(k) * 7.1 + t * 9)))
                        let p = CGPoint(x: c.x + cos(a) * dist, y: c.y + sin(a) * dist)
                        lit.fill(Path(ellipseIn: CGRect(x: p.x - 1.2, y: p.y - 1.2, width: 2.4, height: 2.4)), with: .color(.white))
                    }
                }
            case .confetti where t < 4:
                let spread = s * (1 + 5 * min(1, t / 1.2))
                let fade = max(0, 1 - t / 4)
                for k in 0..<90 {
                    let a = Double(k) * 2.399 + Double(e.id.hashValue % 7)
                    let rr = spread * sqrt(Double((k * 37) % 90) / 90)
                    let drift = t * s * 0.3 * sin(Double(k))
                    let p = CGPoint(x: c.x + cos(a) * rr + drift, y: c.y - abs(sin(a)) * rr - s * 1.5 * min(1, t))
                    let hue = Double((k * 53) % 100) / 100
                    ctx.fill(Path(CGRect(x: p.x - 2, y: p.y - 1.2, width: 4, height: 2.4)),
                             with: .color(Color(hue: hue, saturation: 0.85, brightness: 1).opacity(fade)))
                }
            case .fireworks where t < 3:
                let r = s * 4 * min(1, t / 0.6)
                let fade = max(0, 1 - t / 3)
                for k in 0..<60 {
                    let a = Double(k) * .pi * 2 / 60
                    let p = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r * 0.8)
                    lit.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)),
                             with: .color(Color(hue: Double(k % 3) * 0.33 + 0.05, saturation: 0.7, brightness: 1).opacity(fade)))
                }
                lit.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.5, y: c.y - r * 0.5, width: r, height: r)),
                         with: .radialGradient(Gradient(colors: [Color.white.opacity(0.6 * fade), .clear]), center: c, startRadius: 0, endRadius: r * 0.5))
            default:
                break
            }
            // The unit itself
            let rect = CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(Color(white: 0.12)))
            ctx.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(e.armed ? .red : e.kind.tint.opacity(0.7)), lineWidth: e.armed ? 2 : 1)
            var icon = ctx.resolve(Image(systemName: e.kind.symbol))
            icon.shading = .color(e.kind.tint)
            ctx.draw(icon, in: rect.insetBy(dx: 3, dy: 3))
            ctx.draw(Text(e.name).font(.system(size: 8)).foregroundColor(e.kind.tint.opacity(0.8)), at: CGPoint(x: c.x, y: c.y + 15))
        }
    }

    private func snapshot() -> [BeamSnapshot] {
        lighting.fixtures.map { f in
            let p = lighting.position(f)
            if lighting.role(f) == .laser {
                let s = lighting.laserState(f)
                return BeamSnapshot(id: f.id, name: f.name, role: .laser, position: CGPoint(x: p.x, y: p.y),
                                    target: CGPoint(x: p.x, y: -6), rgb: s.color, level: s.on ? 1 : 0,
                                    laserLook: s.look, laserRotation: s.rotation, laserX: s.x)
            }
            return BeamSnapshot(id: f.id, name: f.name, role: lighting.role(f), position: CGPoint(x: p.x, y: p.y),
                                target: lighting.beamTarget(f), rgb: Self.lightRGB(f, lighting.live[f.id] ?? []),
                                level: lighting.outputLevel(f))
        }
    }

    /// The colour a fixture is emitting, normalised so brightness is carried by `level`.
    nonisolated static func lightRGB(_ f: Fixture, _ values: [Double]) -> RGB {
        var r = 0.0, g = 0.0, b = 0.0, hasColor = false
        for (i, ch) in f.profile.channels.enumerated() where i < values.count {
            let v = values[i] / 255
            switch ch.kind {
            case .red: r += v; hasColor = true
            case .green: g += v; hasColor = true
            case .blue: b += v; hasColor = true
            case .white: r += v * 0.8; g += v * 0.8; b += v * 0.8; hasColor = true
            case .amber: r += v; g += v * 0.55; hasColor = true
            case .uv: r += v * 0.35; b += v * 0.9; hasColor = true
            default: break
            }
        }
        if !hasColor { return f.profile.channels.contains { $0.kind == .haze } ? RGB(r: 0.6, g: 0.6, b: 0.7) : RGB(r: 1, g: 0.93, b: 0.8) }
        let m = max(r, g, b)
        return m > 0.001 ? RGB(r: r / m, g: g / m, b: b / m) : RGB(r: 0, g: 0, b: 0)
    }

    nonisolated private static func drawStage(_ ctx: inout GraphicsContext, _ g: MapGeometry, _ props: [StageItem]) {
        let stage = g.rect(x: 0, y: 0, width: g.stageWidth, depth: g.stageDepth)
        ctx.fill(Path(roundedRect: stage, cornerRadius: 4), with: .color(Color(white: 0.11)))
        var grid = Path()
        var m = 1.0
        while m < g.stageWidth { grid.move(to: g.point(CGPoint(x: m, y: 0))); grid.addLine(to: g.point(CGPoint(x: m, y: g.stageDepth))); m += 1 }
        m = 1
        while m < g.stageDepth { grid.move(to: g.point(CGPoint(x: 0, y: m))); grid.addLine(to: g.point(CGPoint(x: g.stageWidth, y: m))); m += 1 }
        ctx.stroke(grid, with: .color(.white.opacity(0.05)), lineWidth: 1)
        ctx.stroke(Path(roundedRect: stage, cornerRadius: 4), with: .color(.white.opacity(0.35)), lineWidth: 1.5)

        // Trusses
        let hasTrusses = props.contains { $0.kind == .truss }
        for y in (hasTrusses ? [] : [-0.8, g.stageDepth * 0.55, g.stageDepth - 1.2]) {
            var truss = Path()
            truss.move(to: g.point(CGPoint(x: 0.3, y: y)))
            truss.addLine(to: g.point(CGPoint(x: g.stageWidth - 0.3, y: y)))
            ctx.stroke(truss, with: .color(.gray.opacity(0.35)), style: StrokeStyle(lineWidth: 3, dash: [4, 3]))
        }

        for item in props where item.kind == .truss {
            let r = item.rotation * .pi / 180
            let dx = cos(r) * item.width / 2, dy = -sin(r) * item.width / 2
            var truss = Path()
            truss.move(to: g.point(CGPoint(x: item.x - dx, y: item.y - dy)))
            truss.addLine(to: g.point(CGPoint(x: item.x + dx, y: item.y + dy)))
            ctx.stroke(truss, with: .color(.gray.opacity(0.5)), style: StrokeStyle(lineWidth: 4, dash: [5, 3]))
        }
        for item in props where item.kind != .truss {
            let r = g.rect(x: item.x - item.width / 2, y: item.y - item.depth / 2, width: item.width, depth: item.depth)
            ctx.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(item.kind.color.opacity(0.45)), lineWidth: 1)
            ctx.draw(Text(item.label).font(.system(size: 9)).foregroundColor(.white.opacity(0.45)),
                     at: CGPoint(x: r.midX, y: r.midY))
        }
        ctx.draw(Text("▼  AUDIENCE  ▼").font(.caption.weight(.bold)).foregroundColor(.white.opacity(0.4)),
                 at: g.point(CGPoint(x: g.stageWidth / 2, y: -1.9)))
    }

    nonisolated private static func drawBeams(_ ctx: inout GraphicsContext, _ g: MapGeometry, _ beams: [BeamSnapshot]) {
        var lit = ctx
        lit.blendMode = .plusLighter
        var strobeFlash = 0.0

        for b in beams where b.level > 0.01 {
            let color = Color(red: b.rgb.r, green: b.rgb.g, blue: b.rgb.b)
            if b.role == .effect { strobeFlash = max(strobeFlash, b.level); continue }
            if b.role == .laser {
                // Thin beams fanned out over the crowd, steered by pattern / X move / rotation.
                let from = g.point(b.position)
                let count: Int
                let spread: Double
                switch b.laserLook {
                case .beams: count = 7; spread = 0.9
                case .fan: count = 14; spread = 1.4
                case .tunnel: count = 18; spread = 0.5
                case .sheet: count = 40; spread = 1.6
                case .scan: count = 3; spread = 0.25
                case .chase: count = 5; spread = 0.6
                case .off: count = 0; spread = 0
                }
                let steer = (b.laserX - 64) / 64 * 0.7 + (b.laserLook == .tunnel ? b.laserRotation / 40 : 0)
                let len = g.scale * (g.stageDepth + 12)
                for k in 0..<count {
                    let f = count > 1 ? Double(k) / Double(count - 1) - 0.5 : 0
                    let a = -Double.pi / 2 + steer + f * spread * 2
                    // map's "up" is upstage, so beams into the audience point down the screen
                    let to = CGPoint(x: from.x + cos(a) * len * 0.6, y: from.y - sin(a) * len)
                    var p = Path(); p.move(to: from); p.addLine(to: to)
                    lit.stroke(p, with: .color(color.opacity(b.laserLook == .sheet ? 0.22 : 0.8)), lineWidth: b.laserLook == .sheet ? 1 : 1.6)
                }
                continue
            }
            if b.role == .haze {
                let c = g.point(b.position)
                let r = g.scale * 2.5
                lit.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                         with: .radialGradient(Gradient(colors: [color.opacity(0.25 * b.level), .clear]),
                                               center: c, startRadius: 0, endRadius: r))
                continue
            }
            let from = g.point(b.position)
            let to = g.point(b.target)
            let poolRadius = g.scale * (b.role == .mover ? 0.55 : 1.0)
            // Beam cone (top-down projection)
            let dx = to.x - from.x, dy = to.y - from.y
            let len = max(1, (dx * dx + dy * dy).squareRoot())
            let nx = -dy / len * poolRadius, ny = dx / len * poolRadius
            var cone = Path()
            cone.move(to: from)
            cone.addLine(to: CGPoint(x: to.x + nx, y: to.y + ny))
            cone.addLine(to: CGPoint(x: to.x - nx, y: to.y - ny))
            cone.closeSubpath()
            lit.fill(cone, with: .linearGradient(Gradient(colors: [color.opacity(0.35 * b.level), color.opacity(0.08 * b.level)]),
                                                 startPoint: from, endPoint: to))
            // Pool of light on the floor
            lit.fill(Path(ellipseIn: CGRect(x: to.x - poolRadius, y: to.y - poolRadius, width: 2 * poolRadius, height: 2 * poolRadius)),
                     with: .radialGradient(Gradient(colors: [color.opacity(0.9 * b.level), color.opacity(0.3 * b.level), .clear]),
                                           center: to, startRadius: 0, endRadius: poolRadius))
        }
        if strobeFlash > 0.5 {
            let stage = g.rect(x: 0, y: 0, width: g.stageWidth, depth: g.stageDepth)
            lit.fill(Path(stage), with: .color(.white.opacity(0.35 * strobeFlash)))
        }

        // Fixture bodies + labels on top
        for b in beams {
            let p = g.point(b.position)
            let color = Color(red: b.rgb.r, green: b.rgb.g, blue: b.rgb.b)
            let size: CGFloat = b.role == .mover ? 14 : 11
            let rect = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
            let shape = b.role == .mover ? Path(roundedRect: rect, cornerRadius: 3) : Path(ellipseIn: rect)
            ctx.fill(shape, with: .color(Color(white: 0.15)))
            ctx.fill(shape, with: .color(color.opacity(max(0.08, b.level))))
            ctx.stroke(shape, with: .color(.white.opacity(0.6)), lineWidth: 1)
            ctx.draw(Text(b.name).font(.system(size: 8)).foregroundColor(.white.opacity(0.55)),
                     at: CGPoint(x: p.x, y: p.y - size / 2 - 7))
        }
    }
}

/// Maps stage metres to view points. Stage x runs left→right, stage y runs from the front edge (bottom) upstage (top).
private struct MapGeometry {
    let stageWidth: Double
    let stageDepth: Double
    let size: CGSize
    var marginX = 1.0, front = 2.5, back = 1.0

    var scale: Double {
        min(size.width / (stageWidth + 2 * marginX), size.height / (stageDepth + front + back))
    }
    var origin: CGPoint {
        let contentW = (stageWidth + 2 * marginX) * scale, contentH = (stageDepth + front + back) * scale
        return CGPoint(x: (size.width - contentW) / 2, y: (size.height - contentH) / 2)
    }
    func point(_ s: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + (s.x + marginX) * scale, y: origin.y + (stageDepth + back - s.y) * scale)
    }
    func stage(_ p: CGPoint) -> CGPoint {
        let x = (p.x - origin.x) / scale - marginX
        let y = stageDepth + back - (p.y - origin.y) / scale
        return CGPoint(x: max(-marginX, min(stageWidth + marginX, x)), y: max(-front, min(stageDepth + back, y)))
    }
    func rect(x: Double, y: Double, width: Double, depth: Double) -> CGRect {
        let topLeft = point(CGPoint(x: x, y: y + depth))
        return CGRect(x: topLeft.x, y: topLeft.y, width: width * scale, height: depth * scale)
    }
}

private struct PerformerMarker: View {
    let item: StageItem
    let followed: Bool

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle().fill(Color.pink.opacity(0.85)).frame(width: 26, height: 26)
                Image(systemName: "figure.stand").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                if followed {
                    Circle().stroke(Color.yellow, lineWidth: 2).frame(width: 34, height: 34)
                }
            }
            Text(item.label).font(.caption2.weight(.bold)).foregroundStyle(.white)
                .padding(.horizontal, 4).background(Capsule().fill(.black.opacity(0.6)))
        }
        .help("Drag to move · double-click to have the moving heads follow")
    }
}
