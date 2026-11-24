import SwiftUI

/// Show-mix lanes at the top of the Studio arrangement: songs + transitions, the light looks on the
/// timeline, and an editable master light-level line. Everything lines up with the audio below.
struct ShowMixHeader: View {
    @EnvironmentObject var daw: DAWEngine
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles.tv.fill").foregroundStyle(.pink)
                Text("SHOW MIX").font(.caption.weight(.heavy))
                Spacer()
                Menu {
                    Button("Re-mix from the cue list") { model.sendCuesToStudio(daw.project.mix?.cueIDs ?? []) }
                    Button("Reset light level") {
                        daw.edit { p in
                            guard let m = p.mix else { return }
                            p.mix?.intensity = ShowMixer.defaultIntensity(m, spb: 60 / max(20, p.bpm))
                        }
                    }
                    Divider()
                    Button("Export Mix to Show (one cue, full light show)") { model.exportMixToShow() }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            .frame(height: ShowMixLanes.songsHeight)
            Divider()
            Label("Lights", systemImage: "lightbulb.2.fill").font(.caption).frame(height: ShowMixLanes.lightsHeight)
            Divider()
            VStack(alignment: .leading, spacing: 1) {
                Label("Light level", systemImage: "chart.xyaxis.line").font(.caption)
                Text("Click to add · drag · double-click to remove").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .frame(height: ShowMixLanes.levelHeight)
        }
        .padding(.horizontal, 8)
    }
}

struct ShowMixLanes: View {
    @EnvironmentObject var daw: DAWEngine
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var model: AppModel
    let zoom: Double
    let width: CGFloat
    @State private var editing: ShowMixer.TimelineSection?
    @State private var dragIndex: Int?

    static let songsHeight: CGFloat = 30
    static let lightsHeight: CGFloat = 34
    static let levelHeight: CGFloat = 50
    static var total: CGFloat { songsHeight + lightsHeight + levelHeight + 2 }

    var body: some View {
        let p = daw.project
        let spb = 60 / max(20, p.bpm)
        let px = zoom / spb                     // points per second
        let songs = ShowMixer.liveSongs(p)
        VStack(alignment: .leading, spacing: 0) {
            // Songs + transitions
            ZStack(alignment: .topLeading) {
                ForEach(Array(songs.enumerated()), id: \.element.id) { i, s in
                    let ls = store.show.lightShows.first { $0.id == s.lightShowID }
                    let c = ls?.sections.first?.look.colorA.color ?? .pink
                    RoundedRectangle(cornerRadius: 5).fill(c.opacity(0.35))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(c, lineWidth: 1))
                        .overlay(alignment: .leading) {
                            Text("\(i + 1). \(s.name)").font(.caption2.weight(.semibold)).lineLimit(1).padding(.leading, 5)
                        }
                        .frame(width: max(4, (s.end - s.start) * px), height: Self.songsHeight - 6)
                        .offset(x: s.start * px, y: 3)
                }
                ForEach(Array((p.mix?.transitions ?? []).enumerated()), id: \.element.id) { i, t in
                    Menu {
                        ForEach(MixTransition.allCases) { k in
                            Button { model.changeTransition(i, to: k) } label: {
                                Label("\(k.label)\(k == t.kind ? "  ✓" : "")", systemImage: k.symbol)
                            }
                        }
                        Divider()
                        Text(t.kind.detail)
                    } label: {
                        Label(t.kind.label, systemImage: t.kind.symbol).font(.system(size: 9, weight: .bold))
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(t.auto ? Color.purple.opacity(0.85) : Color.orange.opacity(0.9)))
                    .help(t.kind.detail)
                    .offset(x: t.at * px - 6, y: 6)
                }
            }
            .frame(width: width, height: Self.songsHeight, alignment: .topLeading)
            Divider()
            // Light looks
            ZStack(alignment: .topLeading) {
                ForEach(ShowMixer.timelineSections(p, store: store)) { sec in
                    let w = max(2, (sec.end - sec.start) * px)
                    Button { editing = sec } label: {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(LinearGradient(colors: [sec.look.colorA.color, sec.look.colorB.color], startPoint: .leading, endPoint: .trailing))
                            .opacity(0.25 + 0.75 * sec.look.intensity)
                            .overlay(alignment: .leading) {
                                if w > 46 {
                                    HStack(spacing: 2) {
                                        Text(sec.label).font(.system(size: 9, weight: .bold))
                                        if sec.look.strobeBeats > 0 { Image(systemName: "bolt.fill") }
                                        if (sec.look.laser ?? .off) != .off { Image(systemName: "rays") }
                                        if sec.look.sfxHit != nil { Image(systemName: "flame.fill") }
                                    }
                                    .font(.system(size: 8)).foregroundStyle(.white).shadow(radius: 2).padding(.leading, 3)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .frame(width: w, height: Self.lightsHeight - 6)
                    .offset(x: sec.start * px, y: 3)
                    .help("\(sec.label) — click to change the look")
                }
            }
            .frame(width: width, height: Self.lightsHeight, alignment: .topLeading)
            .popover(item: $editing) { sec in
                MixSectionEditor(songIndex: sec.songIndex, sectionID: sec.sectionID).padding().frame(width: 320)
            }
            Divider()
            // Master light level
            levelLane(p.mix?.intensity ?? [], zoom: zoom)
                .frame(width: width, height: Self.levelHeight)
        }
        .background(Color.black.opacity(0.25))
    }

    private func levelLane(_ pts: [AutomationPoint], zoom: Double) -> some View {
        let h = Self.levelHeight - 8
        return Canvas { ctx, size in
            ctx.fill(Path(CGRect(x: 0, y: 4 + h * 0.5, width: size.width, height: 0.5)), with: .color(.white.opacity(0.1)))
            guard !pts.isEmpty else { return }
            var path = Path()
            var fill = Path()
            fill.move(to: CGPoint(x: pts[0].beat * zoom, y: 4 + h))
            for (i, p) in pts.enumerated() {
                let pt = CGPoint(x: p.beat * zoom, y: 4 + h * (1 - p.value))
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                fill.addLine(to: pt)
            }
            fill.addLine(to: CGPoint(x: (pts.last?.beat ?? 0) * zoom, y: 4 + h)); fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(Gradient(colors: [.yellow.opacity(0.35), .orange.opacity(0.05)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(path, with: .color(.yellow), lineWidth: 1.5)
            for p in pts {
                let pt = CGPoint(x: p.beat * zoom, y: 4 + h * (1 - p.value))
                ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 3.5, y: pt.y - 3.5, width: 7, height: 7)), with: .color(.yellow))
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                let beat = max(0, v.location.x / zoom)
                let value = max(0, min(1, 1 - (v.location.y - 4) / h))
                daw.edit { proj in
                    guard var pts = proj.mix?.intensity else { return }
                    if dragIndex == nil {
                        if let near = pts.indices.min(by: { abs(pts[$0].beat - beat) < abs(pts[$1].beat - beat) }),
                           abs(pts[near].beat - beat) * zoom < 8 {
                            dragIndex = near
                        } else {
                            pts.append(AutomationPoint(beat: beat, value: value))
                            pts.sort { $0.beat < $1.beat }
                            dragIndex = pts.firstIndex { $0.beat == beat }
                        }
                    }
                    if let i = dragIndex, pts.indices.contains(i) {
                        pts[i].beat = beat; pts[i].value = value
                        let moved = pts[i]
                        pts.sort { $0.beat < $1.beat }
                        dragIndex = pts.firstIndex(of: moved)
                    }
                    proj.mix?.intensity = pts
                }
            }
            .onEnded { _ in dragIndex = nil })
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { v in
            let beat = v.location.x / zoom
            daw.edit { proj in
                guard var pts = proj.mix?.intensity, pts.count > 2,
                      let near = pts.indices.min(by: { abs(pts[$0].beat - beat) < abs(pts[$1].beat - beat) }),
                      abs(pts[near].beat - beat) * zoom < 10 else { return }
                pts.remove(at: near)
                proj.mix?.intensity = pts
            }
        })
    }
}

/// Edit one section's look right from the Studio timeline (changes the song's light show).
struct MixSectionEditor: View {
    @EnvironmentObject var daw: DAWEngine
    @EnvironmentObject var store: ShowStore
    let songIndex: Int
    let sectionID: UUID

    private var location: (Int, Int)? {
        let songs = ShowMixer.liveSongs(daw.project)
        guard songs.indices.contains(songIndex),
              let s = store.show.lightShows.firstIndex(where: { $0.id == songs[songIndex].lightShowID }),
              let k = store.show.lightShows[s].sections.firstIndex(where: { $0.id == sectionID }) else { return nil }
        return (s, k)
    }

    var body: some View {
        if let (s, k) = location {
            let look = Binding(get: { store.show.lightShows[s].sections[k].look },
                               set: { store.show.lightShows[s].sections[k].look = $0 })
            VStack(alignment: .leading, spacing: 10) {
                Text("\(store.show.lightShows[s].name) — \(store.show.lightShows[s].sections[k].label)").font(.headline).lineLimit(1)
                HStack {
                    ColorPicker("Colour A", selection: Binding(get: { look.wrappedValue.colorA.color }, set: { look.wrappedValue.colorA = RGB($0) }))
                    ColorPicker("B", selection: Binding(get: { look.wrappedValue.colorB.color }, set: { look.wrappedValue.colorB = RGB($0) }))
                }
                Menu("Palette") {
                    ForEach(Palette.library) { p in
                        Button(p.name) { look.wrappedValue.colorA = p.a; look.wrappedValue.colorB = p.b; look.wrappedValue.colorC = p.accent }
                    }
                }
                HStack { Text("Level"); Slider(value: look.intensity, in: 0...1); Text("\(Int(look.wrappedValue.intensity * 100))%").monospacedDigit().frame(width: 40) }
                Picker("Pattern", selection: look.chase) { ForEach(ChaseKind.allCases) { Text($0.label).tag($0) } }
                Picker("Movers", selection: look.mover) { ForEach(MoverMode.allCases) { Text($0.label).tag($0) } }
                Picker("Lasers", selection: Binding(get: { look.wrappedValue.laser ?? .off }, set: { look.wrappedValue.laser = $0 == .off ? nil : $0 })) {
                    ForEach(LaserLook.allCases) { Text($0.label).tag($0) }
                }
                Picker("Effect hit", selection: Binding(get: { look.wrappedValue.sfxHit }, set: { look.wrappedValue.sfxHit = $0 })) {
                    Text("None").tag(SFXKind?.none)
                    ForEach(SFXKind.allCases) { Text($0.label).tag(Optional($0)) }
                }
                Toggle("Strobe hit at the start", isOn: Binding(get: { look.wrappedValue.strobeBeats > 0 }, set: { look.wrappedValue.strobeBeats = $0 ? 2 : 0 }))
                Text("Changes apply to this song everywhere it plays.").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("This section isn't in the show any more.").padding()
        }
    }
}
