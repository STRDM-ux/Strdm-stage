import SwiftUI

/// Sculpted scenic pieces for festival mega-stages (drawn procedurally in the 3D venue).
enum ScenicStyle: String, Codable, CaseIterable, Identifiable {
    case spire, facade, arch, crown, sunDisc, fin, petal, crystal, tree, mushroom, pylon, portal, palm, plume, lantern
    var id: String { rawValue }
    var label: String {
        switch self {
        case .spire: return "Castle Spire"
        case .facade: return "Castle Wall"
        case .arch: return "Grand Arch"
        case .crown: return "Crown Centrepiece"
        case .sunDisc: return "Sun Disc"
        case .fin: return "Blade Fin"
        case .petal: return "Lotus Petal"
        case .crystal: return "Crystal Cluster"
        case .tree: return "Giant Tree"
        case .mushroom: return "Giant Mushroom"
        case .pylon: return "Light Pylon"
        case .portal: return "Portal Ring"
        case .palm: return "Neon Palm"
        case .plume: return "Feather Plume"
        case .lantern: return "Lantern Post"
        }
    }
    /// Tall pieces that carry a searchlight on top in the live view.
    var hasSkyBeam: Bool { self == .spire || self == .pylon || self == .crown }
}

/// Colours and piece choices for one festival world.
struct FestivalTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let blurb: String
    let stone: RGB      // sculpted body
    let trim: RGB       // metal / foliage detail
    let glowA: RGB      // main LED-tape / neon colour
    let glowB: RGB      // second glow colour
    let centre: ScenicStyle
    let flanks: [ScenicStyle]
    let gate: ScenicStyle        // frames the DJ / artist riser
    let outer: ScenicStyle
    let foreground: ScenicStyle

    static let all: [FestivalTheme] = [
        FestivalTheme(id: "kingdom", name: "Enchanted Kingdom", blurb: "Fairytale castle — spires, battlements and a glowing crown",
                      stone: RGB(r: 0.30, g: 0.27, b: 0.42), trim: RGB(r: 0.95, g: 0.74, b: 0.28),
                      glowA: RGB(hex: 0xFF3D81), glowB: RGB(hex: 0x00E5FF),
                      centre: .crown, flanks: [.spire, .facade], gate: .arch, outer: .spire, foreground: .lantern),
        FestivalTheme(id: "lotus", name: "Lotus Temple", blurb: "Blooming petals around a radiant sun disc",
                      stone: RGB(r: 0.72, g: 0.40, b: 0.58), trim: RGB(r: 0.98, g: 0.80, b: 0.36),
                      glowA: RGB(hex: 0xFF7AC8), glowB: RGB(hex: 0xFFD36B),
                      centre: .sunDisc, flanks: [.petal, .fin], gate: .arch, outer: .petal, foreground: .lantern),
        FestivalTheme(id: "crystal", name: "Crystal Cavern", blurb: "Glowing crystal shards and a giant portal ring",
                      stone: RGB(r: 0.10, g: 0.12, b: 0.22), trim: RGB(r: 0.78, g: 0.84, b: 0.95),
                      glowA: RGB(hex: 0x4DE1FF), glowB: RGB(hex: 0xB36BFF),
                      centre: .portal, flanks: [.crystal, .pylon], gate: .arch, outer: .crystal, foreground: .crystal),
        FestivalTheme(id: "solar", name: "Solar Citadel", blurb: "Sci-fi sun temple — pylons, blades and floating rings",
                      stone: RGB(r: 0.13, g: 0.13, b: 0.16), trim: RGB(r: 0.85, g: 0.48, b: 0.22),
                      glowA: RGB(hex: 0xFF8A00), glowB: RGB(hex: 0xFFE14D),
                      centre: .sunDisc, flanks: [.pylon, .fin], gate: .portal, outer: .pylon, foreground: .lantern),
        FestivalTheme(id: "forest", name: "Ancient Forest", blurb: "Giant glowing trees and mushrooms",
                      stone: RGB(r: 0.30, g: 0.20, b: 0.12), trim: RGB(r: 0.10, g: 0.45, b: 0.20),
                      glowA: RGB(hex: 0x7CFF6B), glowB: RGB(hex: 0xFFC84D),
                      centre: .tree, flanks: [.tree, .mushroom], gate: .arch, outer: .tree, foreground: .mushroom),
        FestivalTheme(id: "carnival", name: "Island Carnival", blurb: "Caribbean carnival — feather plumes and neon palms",
                      stone: RGB(r: 0.08, g: 0.24, b: 0.30), trim: RGB(r: 0.98, g: 0.78, b: 0.20),
                      glowA: RGB(hex: 0xFF2E93), glowB: RGB(hex: 0xFFD400),
                      centre: .plume, flanks: [.palm, .plume], gate: .arch, outer: .palm, foreground: .lantern)
    ]
    static func named(_ id: String?) -> FestivalTheme { all.first { $0.id == id || $0.name == id } ?? all[0] }
}

enum FestivalScale: String, CaseIterable, Identifiable {
    case compact, main, mega
    var id: String { rawValue }
    var label: String {
        switch self {
        case .compact: return "Compact — 24 m wide"
        case .main: return "Main stage — 36 m wide"
        case .mega: return "Mega stage — 50 m wide"
        }
    }
    var width: Double { switch self { case .compact: return 24; case .main: return 36; case .mega: return 50 } }
    var depth: Double { switch self { case .compact: return 12; case .main: return 14; case .mega: return 16 } }
    var peak: Double { switch self { case .compact: return 16; case .main: return 23; case .mega: return 31 } }
    var towersPerSide: Int { switch self { case .compact: return 3; case .main: return 4; case .mega: return 6 } }
}

/// Designs a themed festival mega-stage: scenic façade sweeping round the stage, LED walls between the towers,
/// a raised DJ / artist riser under a gate, trusses and PA. Screens come from ScreenRigger.
enum FestivalStageBuilder {
    static let tag = "festival-set"

    static func build(_ plot: StagePlot, theme: FestivalTheme, scale: FestivalScale) -> StagePlot {
        var p = plot
        let oldW = max(1, plot.stageWidth), oldD = max(1, plot.stageDepth)
        let W = scale.width, D = scale.depth, H = scale.peak
        p.items.removeAll { $0.kind.isStructure }
        p.stageWidth = W
        p.stageDepth = D
        p.deckHeight = 2.0
        p.festivalTheme = theme.id
        // Keep the band where it was relative to the stage centre, in the downstage half.
        for i in p.items.indices {
            let dx = p.items[i].x - oldW / 2, fy = p.items[i].y / oldD
            p.items[i].x = min(max(1, W / 2 + dx), W - 1)
            p.items[i].y = min(max(0.8, fy * D * 0.5), D * 0.5)
        }

        var out: [StageItem] = []
        func add(_ k: StageItemKind, _ label: String, x: Double, y: Double, w: Double, d: Double, h: Double? = nil,
                 rot: Double = 0, lift: Double? = nil, style: ScenicStyle? = nil) {
            var it = StageItem(kind: k, label: label, x: (x * 100).rounded() / 100, y: (y * 100).rounded() / 100,
                               width: (w * 10).rounded() / 10, depth: d, rotation: rot.rounded())
            it.height = h.map { ($0 * 10).rounded() / 10 }
            it.elevation = lift
            it.scenic = style?.rawValue
            it.notes = tag
            out.append(it)
        }

        // Centrepiece behind the stage + the main screen in front of it
        let centreW = W * 0.28
        add(.scenic, theme.centre.label, x: W / 2, y: D + 3, w: centreW, d: 3, h: H, style: theme.centre)

        // Façade: towers sweeping forward on both sides, LED panels between them
        let n = scale.towersPerSide
        let reach = W / 2 + 4
        func tower(_ i: Int) -> (dx: Double, y: Double, h: Double, rot: Double) {
            let t = Double(i) / Double(n)
            return (centreW / 2 + 1 + (reach - centreW / 2 - 1) * t, D + 2.5 - D * 0.7 * t * t, H * (0.84 - 0.46 * t), 30 * t)
        }
        let towerW = min(6, max(2.6, (reach - centreW / 2) / Double(n) * 0.5))
        for side in [-1.0, 1.0] {
            let s = side < 0 ? "L" : "R"
            for i in 1...n {
                let t = tower(i)
                let style = theme.flanks[(i - 1) % theme.flanks.count]
                add(.scenic, "\(style.label) \(s)\(i)", x: W / 2 + side * t.dx, y: t.y, w: towerW, d: 2.6, h: t.h,
                    rot: side * t.rot, style: style)
            }
            // Outer landmark + IMAG screen + foreground dressing
            add(.scenic, "\(theme.outer.label) \(s) outer", x: W / 2 + side * (reach + 6), y: D * 0.05, w: towerW * 1.1, d: 2.6,
                h: H * 0.5, rot: side * 38, style: theme.outer)
            for k in 0..<2 {
                add(.scenic, "\(theme.foreground.label) \(s)\(k + 1)", x: W / 2 + side * (W * 0.5 + 1.5 + Double(k) * 3.5), y: -3.5,
                    w: 1.6, d: 1.6, h: 4.5 + Double(k), style: theme.foreground)
            }
            // Flown rig
            add(.trussTower, "Tower D\(s)", x: W / 2 + side * W * 0.37, y: -2, w: 0.6, d: 0.6, h: 13.5)
            add(.trussTower, "Tower U\(s)", x: W / 2 + side * W * 0.33, y: D - 1.6, w: 0.6, d: 0.6, h: 14.5)
            add(.lineArray, "PA \(s)", x: W / 2 + side * W * 0.44, y: -2.8, w: 1, d: 1, h: 12)
            add(.truss, "Ladder \(s)", x: W / 2 + side * W * 0.3, y: D * 0.45, w: D * 0.7, d: 0.3, h: 11, rot: 90)
        }
        add(.truss, "Front truss", x: W / 2, y: -2, w: W * 0.74, d: 0.4, h: 13)
        add(.truss, "Mid truss", x: W / 2, y: D * 0.38, w: W * 0.62, d: 0.4, h: 13.5)
        add(.truss, "Back truss", x: W / 2, y: D - 1.6, w: W * 0.66, d: 0.4, h: 14)

        // DJ / artist riser under the gate
        let riserY = D * 0.64, riserH = 1.6
        add(.riser, "Artist riser", x: W / 2, y: riserY, w: 9, d: 3.6, h: riserH)
        add(.stairs, "Riser stairs L", x: W / 2 - 5.3, y: riserY, w: 1.4, d: 2, h: riserH, rot: 90)
        add(.stairs, "Riser stairs R", x: W / 2 + 5.3, y: riserY, w: 1.4, d: 2, h: riserH, rot: -90)
        add(.scenic, theme.gate.label + " gate", x: W / 2, y: riserY + 2.6, w: 13, d: 1.2, h: H * 0.4, style: theme.gate)
        if let i = p.items.firstIndex(where: { $0.kind == .djBooth }) {
            p.items[i].x = W / 2; p.items[i].y = riserY; p.items[i].elevation = riserH
        } else {
            add(.djBooth, "DJ booth", x: W / 2, y: riserY, w: 2.4, d: 1, lift: riserH)
        }
        add(.ledFloor, "LED floor", x: W / 2, y: D * 0.28, w: W * 0.3, d: 4)
        add(.catwalk, "Thrust", x: W / 2, y: -3.5, w: 3, d: 7)

        p.items += out
        // Screens are laid out to fit the scenery (same engine as the Auto Rig Screens button).
        return ScreenRigger.rig(p).plot
    }
}

/// Stage Design → Festival Stage Designer.
struct FestivalStageSheet: View {
    var onWillApply: () -> Void = {}
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var lighting: LightingEngine
    @Environment(\.dismiss) private var dismiss
    @State private var theme = FestivalTheme.all[0]
    @State private var scale: FestivalScale = .main
    @State private var rig = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "sparkles").font(.title2).foregroundStyle(.pink)
                VStack(alignment: .leading) {
                    Text("Festival Stage Designer").font(.title2.weight(.heavy))
                    Text("Builds a themed 3D mega-stage: sculpted scenery, LED wings, artist riser, trusses, PA and IMAG screens.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], spacing: 10) {
                ForEach(FestivalTheme.all) { t in
                    Button { theme = t } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 4) {
                                ForEach([t.stone, t.trim, t.glowA, t.glowB], id: \.self) { c in
                                    RoundedRectangle(cornerRadius: 3).fill(c.color).frame(height: 16)
                                }
                            }
                            Text(t.name).font(.headline)
                            Text(t.blurb).font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(theme == t ? 0.12 : 0.04)))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme == t ? t.glowA.color : .white.opacity(0.1), lineWidth: theme == t ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            Picker("Size", selection: $scale) {
                ForEach(FestivalScale.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(String(format: "%.0f × %.0f m stage · scenery up to %.0f m tall · %d towers a side", scale.width, scale.depth, scale.peak, scale.towersPerSide))
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Design and patch a lighting rig to fit (replaces the current rig)", isOn: $rig)
            Text("Replaces trusses, decks, screens and set pieces. Keeps your performers, mics and backline. Undo with ⌘Z in Stage Design.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Build Stage") { apply(); dismiss() }.keyboardShortcut(.defaultAction).tint(.pink)
            }
        }
        .padding(22)
        .frame(width: 780)
        .onAppear { theme = FestivalTheme.named(store.show.stagePlot.festivalTheme) }
    }

    private func apply() {
        onWillApply()
        FestivalStageBuilder.install(theme: theme, scale: scale, rig: rig, store: store, lighting: lighting)
    }
}

extension FestivalStageBuilder {
    /// Builds the stage into the show and (optionally) hangs a rig on it. Shared by the sheet and the AI Creative Director.
    @MainActor
    static func install(theme: FestivalTheme, scale: FestivalScale, rig: Bool, store: ShowStore, lighting: LightingEngine) {
        store.show.stagePlot = build(store.show.stagePlot, theme: theme, scale: scale)
        ScreenRigger.install(store: store)
        let plot = store.show.stagePlot
        if rig {
            var o = RigDesigner.Options()
            o.size = .large
            o.trimHeight = 13
            store.show.lighting.fixtures = RigDesigner.design(plot: plot, options: o).fixtures
        } else if !store.show.lighting.fixtures.isEmpty {
            store.show.lighting.fixtures = RigDesigner.replace(store.show.lighting.fixtures, plot: plot, trim: 13, role: lighting.role)
        }
        if !store.show.effects.devices.isEmpty {
            store.show.effects.devices = RigDesigner.placeEffects(store.show.effects.devices, plot: plot)
        }
        lighting.syncPatch()
        if Viewer3DSettings.shared.crowdSize == .club || Viewer3DSettings.shared.crowdSize == .arena {
            Viewer3DSettings.shared.crowdSize = .festival
        }
    }
}
