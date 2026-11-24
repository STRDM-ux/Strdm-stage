import SwiftUI

// MARK: - Cues

struct CuesPane: View {
    @EnvironmentObject var client: LiveClient
    @State private var picked: LiveState.CueItem?

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array((client.state?.cues ?? []).enumerated()), id: \.element.id) { i, c in
                    let sb = i == client.state?.standbyIndex
                    Button { picked = c } label: {
                        HStack(spacing: 12) {
                            Text(sb ? "▶" : c.number).font(.body.monospacedDigit().weight(.bold))
                                .foregroundStyle(sb ? Color.goGreen : .secondary).frame(width: 34, alignment: .leading)
                            Image(systemName: CueKind.symbol(c.kind)).foregroundStyle(CueKind.color(c.kind)).frame(width: 22)
                            Text(c.name).lineLimit(1)
                            Spacer()
                            if !c.auto.isEmpty { Text(c.auto).font(.caption2.weight(.heavy)).foregroundStyle(.cyan) }
                            if c.running { Circle().fill(Color.goGreen).frame(width: 8, height: 8) }
                        }
                        .padding(.vertical, 6)
                    }
                    .listRowBackground(sb ? Color.goGreen.opacity(0.14) : Color.card)
                    .id(i)
                }
            }
            .scrollContentBackground(.hidden)
            .onChange(of: client.state?.standbyIndex) { _, i in if let i { withAnimation { proxy.scrollTo(i, anchor: .center) } } }
        }
        .confirmationDialog(picked.map { "\($0.number)  \($0.name)" } ?? "", isPresented: Binding(get: { picked != nil }, set: { if !$0 { picked = nil } }),
                            titleVisibility: .visible) {
            if let c = picked {
                Button("Set as standby") { client.act("standby", ["id": c.id]) }
                Button("Fire this cue now") { client.act("fire", ["id": c.id]) }
            }
        }
    }
}

// MARK: - Lights

struct LightsPane: View {
    @EnvironmentObject var client: LiveClient
    @State private var gm: Double? = nil

    var body: some View {
        let s = client.state
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let song = s?.song {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(song.name).font(.headline)
                        Text("\(song.section) · \(Int(song.bpm)) BPM · \(song.vibe) · \(timeString(song.elapsed)) / \(timeString(song.duration))")
                            .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            ForEach(0..<4) { b in
                                Circle().fill(b == song.beat % 4 ? (b == 0 ? Color.strdmPink : .white) : Color.white.opacity(0.15)).frame(width: 16, height: 16)
                            }
                        }
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [.strdmPink.opacity(0.25), .strdmPurple.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                // Live mode: the Mac listens and runs the lights from the sound in the room.
                Button { client.act("liveMode", ["on": !(s?.liveOn ?? false)]) } label: {
                    HStack {
                        Image(systemName: s?.liveOn == true ? "mic.fill" : "mic")
                        Text(s?.liveOn == true ? "LIVE MIC ON" : "Live Mic — lights follow the sound").font(.headline)
                        Spacer()
                        if s?.liveOn == true {
                            Text("\(Int(s?.liveBPM ?? 0)) BPM · \(s?.liveSection ?? "")").font(.subheadline.monospacedDigit())
                        }
                    }
                    .padding(.horizontal, 16).frame(height: 56)
                    .background(s?.liveOn == true ? Color.red.opacity(0.75) : Color.card)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(PressStyle())
                Button { client.act("blackout", ["on": !(s?.blackout ?? false)]) } label: {
                    Text(s?.blackout == true ? "BLACKOUT ON" : "Blackout")
                        .font(.title3.weight(.heavy)).frame(maxWidth: .infinity).frame(height: 60)
                        .background(s?.blackout == true ? Color.red : Color.card).clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(PressStyle())

                // Grand master with numbers
                let value = gm ?? (s?.gm ?? 1) * 100
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("GRAND MASTER").font(.caption.weight(.heavy)).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(value.rounded()))%").font(.system(size: 34, weight: .heavy, design: .rounded).monospacedDigit())
                    }
                    Slider(value: Binding(get: { value }, set: { gm = $0; client.act("gm", ["value": $0 / 100]) }), in: 0...100, step: 1) { editing in
                        if !editing { gm = nil }
                    }
                    HStack(spacing: 6) {
                        ForEach([-10, -1], id: \.self) { d in step(d, value) }
                        ForEach([0, 25, 50, 75, 100], id: \.self) { v in
                            Button("\(v)") { client.act("gm", ["value": Double(v) / 100]) }
                                .buttonStyle(.bordered).tint(Int(value.rounded()) == v ? .strdmPink : nil)
                        }
                        ForEach([1, 10], id: \.self) { d in step(d, value) }
                    }
                    .font(.subheadline.weight(.bold).monospacedDigit())
                }
                .padding(14).background(Color.card).clipShape(RoundedRectangle(cornerRadius: 16))

                if let scenes = s?.scenes, !scenes.isEmpty {
                    section("SCENES")
                    grid(scenes.map { ($0.id, $0.name, $0.id == s?.activeScene) }) { client.act("scene", ["id": $0, "fade": 2]) }
                }
                if let people = s?.performers, !people.isEmpty {
                    section("MOVING HEADS FOLLOW")
                    grid([("", "Nobody", s?.follow == nil)] + people.map { ($0.id, "🎯 " + $0.name, $0.id == s?.follow) }) { id in
                        client.act("follow", id.isEmpty ? [:] : ["id": id])
                    }
                }
            }
            .padding()
        }
    }

    private func step(_ d: Int, _ value: Double) -> some View {
        Button(d > 0 ? "+\(d)" : "\(d)") { client.act("gm", ["value": max(0, min(100, value.rounded() + Double(d))) / 100]) }
            .buttonStyle(.bordered)
    }
}

func section(_ t: String) -> some View {
    Text(t).font(.caption.weight(.heavy)).foregroundStyle(.secondary).padding(.top, 4)
}

func grid(_ items: [(String, String, Bool)], action: @escaping (String) -> Void) -> some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
        ForEach(items, id: \.0) { item in
            Button { action(item.0) } label: {
                Text(item.1).font(.body.weight(.semibold)).lineLimit(2).frame(maxWidth: .infinity).frame(minHeight: 58)
                    .background(item.2 ? Color.strdmPink.opacity(0.3) : Color.card)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(item.2 ? Color.strdmPink : .clear, lineWidth: 1.5))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(PressStyle())
        }
    }
}

// MARK: - Live map

struct MapPane: View {
    @EnvironmentObject var client: LiveClient

    var body: some View {
        VStack {
            if let m = client.state?.map {
                Canvas { ctx, size in draw(m, ctx: &ctx, size: size) }
                    .background(Color(white: 0.02))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding()
            } else {
                ContentUnavailableView("Live map needs the latest STRDM Stage on the Mac", systemImage: "map")
            }
        }
    }

    private func draw(_ m: LiveState.MapState, ctx: inout GraphicsContext, size: CGSize) {
        let xs = m.lights.map(\.x) + m.items.map(\.x) + [0, m.w]
        let ys = m.lights.map(\.y) + [-1, m.d]
        let minX = (xs.min() ?? 0) - 1, maxX = (xs.max() ?? m.w) + 1
        let minY = (ys.min() ?? 0) - 1, maxY = (ys.max() ?? m.d) + 1
        let pad: CGFloat = 20
        let sc = min((size.width - pad * 2) / (maxX - minX), (size.height - pad * 2) / (maxY - minY))
        let ox = (size.width - (maxX - minX) * sc) / 2
        func X(_ x: Double) -> CGFloat { ox + (x - minX) * sc }
        func Y(_ y: Double) -> CGFloat { size.height - pad - (y - minY) * sc }
        ctx.fill(Path(CGRect(x: X(0), y: Y(m.d), width: m.w * sc, height: m.d * sc)), with: .color(Color(white: 0.09)))
        ctx.stroke(Path(CGRect(x: X(0), y: Y(m.d), width: m.w * sc, height: m.d * sc)), with: .color(Color(white: 0.2)))
        for it in m.items {
            let p = it.c.split(separator: ",").compactMap { Double($0) }
            guard p.count == 3 else { continue }
            var c = ctx
            c.translateBy(x: X(it.x), y: Y(it.y))
            c.rotate(by: .degrees(-p[2]))
            let color: Color = it.kind == "ledWall" ? .blue.opacity(0.55) : (it.kind == "truss" ? .white.opacity(0.2) : .brown.opacity(0.4))
            c.fill(Path(CGRect(x: -p[0] * sc / 2, y: -p[1] * sc / 2, width: p[0] * sc, height: max(2, p[1] * sc))), with: .color(color))
        }
        for l in m.lights {
            let r = max(4, sc * 0.35)
            let pt = CGPoint(x: X(l.x), y: Y(l.y))
            let col = Color(hex: l.c)
            if l.l > 0.02 {
                ctx.fill(Path(ellipseIn: CGRect(x: pt.x - r * 4, y: pt.y - r * 4, width: r * 8, height: r * 8)),
                         with: .radialGradient(Gradient(colors: [col.opacity(min(1, l.l)), col.opacity(0)]), center: pt, startRadius: 0, endRadius: r * 4))
            }
            let shape = l.kind == "laser"
                ? Path { p in p.move(to: CGPoint(x: pt.x, y: pt.y - r)); p.addLine(to: CGPoint(x: pt.x + r, y: pt.y + r)); p.addLine(to: CGPoint(x: pt.x - r, y: pt.y + r)); p.closeSubpath() }
                : Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2))
            ctx.fill(shape, with: .color(l.l > 0.02 ? col : Color(white: 0.18)))
        }
        for p in m.people {
            let pt = CGPoint(x: X(p.x), y: Y(p.y))
            ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 6, y: pt.y - 6, width: 12, height: 12)), with: .color(.strdmPink))
            ctx.draw(Text(p.name).font(.caption2.weight(.semibold)).foregroundColor(.white), at: CGPoint(x: pt.x, y: pt.y + 16))
        }
        ctx.draw(Text("▼ AUDIENCE").font(.caption2.weight(.bold)).foregroundColor(.gray), at: CGPoint(x: size.width / 2, y: size.height - 8))
    }
}

// MARK: - Screens

struct ScreensPane: View {
    @EnvironmentObject var client: LiveClient

    var body: some View {
        let s = client.state
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("OUTPUTS")
                ForEach(s?.screens ?? [], id: \.self) { sc in
                    HStack {
                        Circle().fill(sc.open ? Color.goGreen : .gray).frame(width: 8, height: 8)
                        Text(sc.name).font(.headline)
                        Spacer()
                        Text(sc.showing.isEmpty ? "—" : sc.showing).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(12).background(Color.card).clipShape(RoundedRectangle(cornerRadius: 12))
                }
                HStack {
                    Button("Open outputs") { client.act("openOutputs") }.buttonStyle(.bordered)
                    Button("Test pattern") { client.act("testPattern") }.buttonStyle(.bordered)
                    Button("Screens to black") { client.act("screensBlack") }.buttonStyle(.borderedProminent).tint(.red)
                }
                section("VISUALS")
                grid([("", "Auto (follow the song)", s?.visualStyle == nil)] + (s?.visualStyles ?? []).map { ($0.id, $0.name, $0.id == s?.visualStyle) }) { id in
                    client.act("visual", id.isEmpty ? [:] : ["style": id])
                }
            }
            .padding()
        }
    }
}

// MARK: - Effects

struct EffectsPane: View {
    @EnvironmentObject var client: LiveClient

    var body: some View {
        let s = client.state
        VStack(spacing: 16) {
            if (s?.sfxUnits ?? 0) == 0 {
                ContentUnavailableView("No effects units patched", systemImage: "flame")
            } else {
                Text(s?.sfxArmed == true ? "ARMED" : "SAFE")
                    .font(.system(size: 44, weight: .black))
                    .foregroundStyle(s?.sfxArmed == true ? .red : Color.goGreen)
                Text("\(s?.sfxUnits ?? 0) units").foregroundStyle(.secondary)
                Button { client.act("sfxStop") } label: {
                    Text("E-STOP — kill all effects").font(.title2.weight(.heavy)).frame(maxWidth: .infinity).frame(height: 80)
                        .background(Color.red).clipShape(RoundedRectangle(cornerRadius: 18))
                }
                .buttonStyle(PressStyle())
                if s?.sfxArmed == true {
                    Button("Disarm") { client.act("sfxDisarm") }.buttonStyle(.bordered).controlSize(.large)
                }
                Text("For safety the phone can only stop and disarm. Arming and firing stay on the Mac with the licensed operator.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding()
    }
}

// MARK: - Crew

struct CrewPane: View {
    @EnvironmentObject var client: LiveClient
    @State private var confirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let c = client.state?.crew {
                    HStack(spacing: 12) {
                        stat(c.critical, "critical", .red)
                        stat(c.warnings, "warnings", .orange)
                    }
                    if c.top.isEmpty { Label("All clear", systemImage: "checkmark.seal.fill").foregroundStyle(Color.goGreen) }
                    ForEach(c.top, id: \.self) { t in
                        Text(t).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.card).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    HStack {
                        Button("Run check") { client.act("crewCheck") }.buttonStyle(.bordered)
                        Button("Fix all (\(c.fixable))") { confirm = true }.buttonStyle(.borderedProminent).disabled(c.fixable == 0)
                    }
                    Text("The Creative Director and Production Manager chat live on the Mac under AI Crew.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView("Open AI Crew on the Mac once", systemImage: "checklist")
                }
            }
            .padding()
        }
        .confirmationDialog("Apply all automatic fixes?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Fix all") { client.act("crewFixAll") }
        }
    }

    private func stat(_ n: Int, _ label: String, _ c: Color) -> some View {
        VStack { Text("\(n)").font(.system(size: 36, weight: .black)).foregroundStyle(c); Text(label).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity).padding().background(Color.card).clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
