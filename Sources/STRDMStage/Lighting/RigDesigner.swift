import Foundation
import SwiftUI
import simd

/// Designs a lighting rig for the stage: reads the trusses, towers, decks, screens and performers in the
/// stage design and hangs washes, spots, beams, strobes, blinders, side light, uplights, lasers and haze
/// where a lighting designer would, then patches DMX addresses.
enum RigDesigner {
    enum Size: String, CaseIterable, Identifiable {
        case small, medium, large
        var id: String { rawValue }
        var label: String {
            switch self {
            case .small: return "Small (club / venue)"
            case .medium: return "Medium (concert)"
            case .large: return "Large (festival / arena)"
            }
        }
    }

    struct Options {
        var size: Size = .medium
        var trimHeight: Double = 6
        var movers = true
        var lasers = true
        var strobes = true
        var blinders = true
        var sideLight = true
        var uplights = true
        var haze = true
        var placeEffects = true
        var startUniverse = 0
    }

    struct Line: Hashable { let group: String; let count: Int; let profile: String }
    struct Plan {
        var fixtures: [Fixture]
        var summary: [Line]
        var universes: Int
        var trussesUsed: [String]
    }

    /// A horizontal pipe fixtures can hang on (metres; z = height above the deck).
    struct Pipe {
        var name: String
        var a: SIMD2<Double>
        var b: SIMD2<Double>
        var z: Double
        var y: Double { (a.y + b.y) / 2 }
        var length: Double { simd_length(b - a) }
        func point(_ t: Double) -> SIMD2<Double> { a + (b - a) * t }
    }

    static func profile(_ name: String) -> FixtureProfile {
        FixtureProfile.library.first { $0.name.hasPrefix(name) } ?? FixtureProfile.library[0]
    }

    /// Trusses from the stage design, or a standard front / mid / back rig if none are drawn.
    static func pipes(_ plot: StagePlot, trim: Double) -> (pipes: [Pipe], fromDesign: Bool) {
        let trusses = plot.items.filter { $0.kind == .truss }
        if !trusses.isEmpty {
            let list = trusses.map { t -> Pipe in
                let r = t.rotation * .pi / 180
                let half = t.width / 2
                let dx = cos(r) * half, dy = -sin(r) * half
                return Pipe(name: t.label, a: SIMD2(t.x - dx, t.y - dy), b: SIMD2(t.x + dx, t.y + dy), z: t.topHeight)
            }
            return (list, true)
        }
        let w = plot.stageWidth, d = plot.stageDepth
        return ([
            Pipe(name: "Front truss", a: SIMD2(-0.5, -1), b: SIMD2(w + 0.5, -1), z: trim),
            Pipe(name: "Mid truss", a: SIMD2(0, d * 0.5), b: SIMD2(w, d * 0.5), z: trim + 0.3),
            Pipe(name: "Back truss", a: SIMD2(0, d - 0.8), b: SIMD2(w, d - 0.8), z: trim + 0.6)
        ], false)
    }

    static func design(plot: StagePlot, options o: Options) -> Plan {
        let w = plot.stageWidth, d = plot.stageDepth
        let (allPipes, fromDesign) = pipes(plot, trim: o.trimHeight)
        // Pipes across the stage, front to back; "ladders" (running up/down stage) handled separately.
        let across = allPipes.filter { abs($0.b.x - $0.a.x) >= abs($0.b.y - $0.a.y) }.sorted { $0.y < $1.y }
        let ladders = allPipes.filter { abs($0.b.x - $0.a.x) < abs($0.b.y - $0.a.y) }
        let mainStage = across.filter { $0.y > -3 && $0.y < d + 2 }
        let front = mainStage.first ?? across.first ?? allPipes[0]
        let back = mainStage.last ?? front
        let mids = mainStage.dropFirst().dropLast()
        let extraPipes = across.filter { $0.y <= -3 }       // B-stage / runway trusses

        let k: Double = o.size == .small ? 0.6 : (o.size == .medium ? 1 : 1.6)
        func count(_ base: Double, max m: Int) -> Int { max(1, min(m, Int((base * k).rounded()))) }

        var out: [Fixture] = []
        var summary: [Line] = []
        func add(_ group: String, _ prof: FixtureProfile, _ points: [SIMD3<Double>], name: String) {
            guard !points.isEmpty else { return }
            for (i, p) in points.enumerated() {
                var f = Fixture(name: points.count > 1 ? "\(name) \(i + 1)" : name, profile: prof, group: group)
                f.stageX = (p.x * 100).rounded() / 100
                f.stageY = (p.y * 100).rounded() / 100
                f.stageZ = (p.z * 100).rounded() / 100
                out.append(f)
            }
            summary.append(Line(group: group, count: points.count, profile: prof.name))
        }
        func along(_ pipe: Pipe, _ n: Int, inset: Double = 0.08, dz: Double = -0.3) -> [SIMD3<Double>] {
            guard n > 0 else { return [] }
            return (0..<n).map { i in
                let t = n == 1 ? 0.5 : inset + (1 - 2 * inset) * Double(i) / Double(n - 1)
                let p = pipe.point(t)
                return SIMD3(p.x, p.y, pipe.z + dz)
            }
        }

        let wash = profile("LED Par RGBWAUV")
        let spot = profile("Moving Head Spot")
        let beamWash = profile("Moving Head Wash")
        let strobeP = profile("Strobe")
        let blinderP = profile("Blinder")
        let hazeP = profile("Hazer")
        let laserP = profile("Laser")
        let parP = profile("LED Par Dim+RGBW")

        // Front light: key light on the performers from the front truss
        add("Front Wash", wash, along(front, count(max(4, w / 1.4), max: 16)), name: "Front Wash")
        // Spots on the mid truss (or front, alternating) for specials, gobos and follow
        if o.movers {
            let spotPipe = mids.first ?? front
            add("Spots", spot, along(spotPipe, count(w / 2.2, max: 10), inset: 0.12, dz: -0.45), name: "Spot")
            // Beams / wash movers on the back truss — the big looks
            add("Back Movers", beamWash, along(back, count(w / 1.6, max: 14), inset: 0.06, dz: -0.45), name: "Back Mover")
            // Extra mid trusses (festival) get more movers
            for (i, m) in mids.dropFirst().enumerated() {
                add("Mid Movers \(i + 2)", beamWash, along(m, count(w / 2.4, max: 10), inset: 0.1, dz: -0.45), name: "Mid Mover \(i + 2)")
            }
            // Ladders (trusses running up/down stage) → side movers
            for (i, l) in ladders.enumerated() where l.y > -3 {
                add("Ladder \(i + 1)", beamWash, along(l, count(3, max: 5), inset: 0.15, dz: -0.45), name: "Ladder \(i + 1) Mover")
            }
            // B-stage / runway: spots overhead
            for (i, p) in extraPipes.enumerated() {
                add("B-Stage \(i + 1)", spot, along(p, count(3, max: 6), inset: 0.15, dz: -0.45), name: "B-Stage Spot \(i + 1)")
            }
        }
        // Strobes spread through the rig
        if o.strobes {
            let pipe = mids.first ?? back
            add("Strobes", strobeP, along(pipe, count(w / 3, max: 8), inset: 0.15, dz: -0.2), name: "Strobe")
        }
        // Blinders at the ends of the front truss, pointing at the crowd
        if o.blinders && o.size != .small {
            let pts = along(front, 2, inset: 0.02, dz: -0.2)
                + (o.size == .large ? along(back, 2, inset: 0.02, dz: -0.2) : [])
            add("Blinders", blinderP, pts, name: "Blinder")
        }
        // Side light from towers (or virtual booms at the stage edges)
        if o.sideLight {
            let towers = plot.items.filter { $0.kind == .trussTower && $0.y > -3 && $0.y < d + 2 }
            var pts: [SIMD3<Double>] = []
            let levels: [Double] = o.size == .small ? [2] : (o.size == .medium ? [1.5, 3] : [1.2, 2.6, 4])
            if !towers.isEmpty {
                for t in towers { for z in levels { pts.append(SIMD3(t.x, t.y, z)) } }
            } else {
                for x in [-0.4, w + 0.4] { for y in [d * 0.3, d * 0.65] { for z in levels { pts.append(SIMD3(x, y, z)) } } }
            }
            add("Side Light", parP, pts, name: "Side")
        }
        // Uplights: floor line upstage (in front of the LED wall if there is one) to silhouette the band
        if o.uplights {
            let wall = plot.items.first { $0.kind == .ledWall && $0.y > 0 && $0.y <= d + 1 }
            let y = max(0.3, (wall?.y ?? d) - 0.5)
            let span = wall.map { min(w, $0.width + 2) } ?? w * 0.9
            let n = count(span / 1.3, max: 12)
            let pts = (0..<n).map { i -> SIMD3<Double> in
                SIMD3(w / 2 - span / 2 + span * (Double(i) + 0.5) / Double(n), y, 0.15)
            }
            add("Uplights", parP, pts, name: "Uplight")
        }
        // Lasers: upstage on the back truss / floor corners, aimed over the crowd
        if o.lasers {
            let n = o.size == .small ? 1 : (o.size == .medium ? 2 : 4)
            var pts: [SIMD3<Double>]
            switch n {
            case 1: pts = [SIMD3(w / 2, back.y, back.z - 0.4)]
            case 2: pts = [SIMD3(w * 0.15, d - 0.4, 0.3), SIMD3(w * 0.85, d - 0.4, 0.3)]
            default: pts = [SIMD3(w * 0.12, d - 0.4, 0.3), SIMD3(w * 0.88, d - 0.4, 0.3),
                            SIMD3(w * 0.35, back.y, back.z - 0.4), SIMD3(w * 0.65, back.y, back.z - 0.4)]
            }
            add("Lasers", laserP, pts, name: "Laser")
        }
        // Haze upstage, out of sight lines
        if o.haze {
            let pts = o.size == .small ? [SIMD3(w - 0.6, d - 0.3, 0)] : [SIMD3(0.6, d - 0.3, 0), SIMD3(w - 0.6, d - 0.3, 0)]
            add("Haze", hazeP, pts, name: "Hazer")
        }

        // Patch: consecutive addresses, never splitting a fixture across universes
        var universe = o.startUniverse, address = 1
        for i in out.indices {
            let fp = out[i].footprint
            if address + fp - 1 > 512 { universe += 1; address = 1 }
            out[i].universe = universe
            out[i].address = address
            address += fp
        }
        var used = fromDesign ? allPipes.map(\.name) : []
        if !fromDesign { used = ["Standard front / mid / back trusses at \(String(format: "%.1f", o.trimHeight)) m"] }
        return Plan(fixtures: out, summary: summary, universes: universe - o.startUniverse + 1, trussesUsed: used)
    }

    /// Re-hangs the fixtures you already have on the best positions for this stage design (keeps patch).
    static func replace(_ fixtures: [Fixture], plot: StagePlot, trim: Double, role: (Fixture) -> FixtureRole) -> [Fixture] {
        let w = plot.stageWidth, d = plot.stageDepth
        let (allPipes, _) = pipes(plot, trim: trim)
        let across = allPipes.filter { abs($0.b.x - $0.a.x) >= abs($0.b.y - $0.a.y) && $0.y > -3 }.sorted { $0.y < $1.y }
        let front = across.first ?? allPipes[0]
        let back = across.last ?? front
        let mid = across.count > 2 ? across[1] : back
        var out = fixtures
        func place(_ ids: [Int], on pipe: Pipe, dz: Double) {
            for (k, i) in ids.enumerated() {
                let t = ids.count == 1 ? 0.5 : 0.08 + 0.84 * Double(k) / Double(ids.count - 1)
                let p = pipe.point(t)
                out[i].stageX = (p.x * 100).rounded() / 100
                out[i].stageY = (p.y * 100).rounded() / 100
                out[i].stageZ = pipe.z + dz
            }
        }
        let idx = Array(out.indices)
        let washes = idx.filter { [.color, .dimmer].contains(role(out[$0])) }
        let movers = idx.filter { role(out[$0]) == .mover }
        let effects = idx.filter { role(out[$0]) == .effect }
        // Split washes: most on the front truss, the rest as uplights
        let frontCount = max(1, Int(Double(washes.count) * 0.65))
        place(Array(washes.prefix(frontCount)), on: front, dz: -0.3)
        let ups = Array(washes.dropFirst(frontCount))
        for (k, i) in ups.enumerated() {
            out[i].stageX = w * (Double(k) + 0.5) / Double(max(1, ups.count))
            out[i].stageY = d - 0.5
            out[i].stageZ = 0.15
        }
        // Movers: half mid, half back (all back on a two-truss rig)
        let half = across.count > 2 ? movers.count / 2 : 0
        place(Array(movers.prefix(half)), on: mid, dz: -0.45)
        place(Array(movers.dropFirst(half)), on: back, dz: -0.45)
        place(effects, on: mid, dz: -0.2)
        for (k, i) in idx.filter({ role(out[$0]) == .laser }).enumerated() {
            out[i].stageX = k % 2 == 0 ? w * 0.15 : w * 0.85
            out[i].stageY = d - 0.4
            out[i].stageZ = 0.3
        }
        for (k, i) in idx.filter({ role(out[$0]) == .haze }).enumerated() {
            out[i].stageX = k % 2 == 0 ? 0.6 : w - 0.6
            out[i].stageY = d - 0.3
            out[i].stageZ = 0
        }
        return out
    }

    /// Puts special effects where they belong: flames and sparks on the downstage edge, CO₂ on the front
    /// truss ends and stage lip, confetti on the front corners, pyro upstage.
    static func placeEffects(_ devices: [SFXDevice], plot: StagePlot) -> [SFXDevice] {
        let w = plot.stageWidth, d = plot.stageDepth
        var out = devices
        for kind in SFXKind.allCases {
            let ids = out.indices.filter { out[$0].kind == kind }
            let n = ids.count
            for (k, i) in ids.enumerated() {
                let t = n == 1 ? 0.5 : Double(k) / Double(n - 1)
                switch kind {
                case .flame, .coldSpark:
                    out[i].stageX = n == 1 ? w / 2 : 0.6 + (w - 1.2) * t
                    out[i].stageY = kind == .flame ? 0.4 : 0.25
                case .co2:
                    out[i].stageX = n == 1 ? w / 2 : 0.4 + (w - 0.8) * t
                    out[i].stageY = 0.3
                case .confetti:
                    out[i].stageX = k % 2 == 0 ? 0.5 : w - 0.5
                    out[i].stageY = 0.5
                case .fireworks:
                    out[i].stageX = n == 1 ? w / 2 : w * (0.1 + 0.8 * t)
                    out[i].stageY = d
                }
            }
        }
        return out
    }
}

/// "Light this stage" — preview and apply an automatic rig.
struct AutoRigSheet: View {
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var lighting: LightingEngine
    @Environment(\.dismiss) private var dismiss
    @State private var options = RigDesigner.Options()
    @State private var mode = 0     // 0 = new rig, 1 = add, 2 = re-hang existing

    var body: some View {
        let plan = RigDesigner.design(plot: store.show.stagePlot, options: options)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "wand.and.rays").font(.title2).foregroundStyle(.pink)
                VStack(alignment: .leading) {
                    Text("Auto Rig").font(.title2.bold())
                    Text("Builds the best lighting layout for this stage design and patches it.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding()
            Divider()
            HStack(alignment: .top, spacing: 0) {
                Form {
                    Picker("What to do", selection: $mode) {
                        Text("Design a new rig (replace mine)").tag(0)
                        Text("Add this rig to mine").tag(1)
                        Text("Re-hang my existing fixtures").tag(2)
                    }
                    if mode != 2 {
                        Picker("Rig size", selection: $options.size) {
                            ForEach(RigDesigner.Size.allCases) { Text($0.label).tag($0) }
                        }
                    }
                    LabeledContent("Trim height") {
                        HStack {
                            Slider(value: $options.trimHeight, in: 3...14, step: 0.5)
                            Text(String(format: "%.1f m", options.trimHeight)).frame(width: 50)
                        }
                    }
                    if mode != 2 {
                        Section("Include") {
                            Toggle("Moving heads (spots, beams)", isOn: $options.movers)
                            Toggle("Lasers", isOn: $options.lasers)
                            Toggle("Strobes", isOn: $options.strobes)
                            Toggle("Audience blinders", isOn: $options.blinders)
                            Toggle("Side light", isOn: $options.sideLight)
                            Toggle("Uplights", isOn: $options.uplights)
                            Toggle("Haze", isOn: $options.haze)
                        }
                        Stepper("Start at universe \(options.startUniverse + 1)", value: $options.startUniverse, in: 0...31)
                    }
                    Toggle("Also position special effects", isOn: $options.placeEffects)
                }
                .formStyle(.grouped)
                .frame(width: 360)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    if mode == 2 {
                        Text("Your \(lighting.fixtures.count) fixtures will be moved to:").font(.headline)
                        Text("• Washes on the front truss, the rest as uplights\n• Moving heads split across the mid and back trusses\n• Strobes mid-rig, lasers and haze upstage\n\nDMX addresses don't change.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("\(plan.fixtures.count) fixtures · \(plan.universes) universe\(plan.universes == 1 ? "" : "s")").font(.headline)
                        ForEach(plan.summary, id: \.group) { s in
                            HStack {
                                Text("\(s.count)×").font(.callout.monospacedDigit()).frame(width: 34, alignment: .trailing)
                                Text(s.group).font(.callout.weight(.semibold))
                                Spacer()
                                Text(s.profile).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                        Text("Hung on").font(.caption.bold())
                        Text(plan.trussesUsed.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                        if !store.show.stagePlot.items.contains(where: { $0.kind == .truss }) {
                            Text("Tip: draw your real trusses in Stage Design (or pick a Stage Template) and the rig will hang on them.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                }
                .padding()
                .frame(width: 380)
            }
            Divider()
            HStack {
                Text("Check the patch against your real fixtures in Lighting before the show.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button(mode == 2 ? "Re-hang Rig" : "Build Rig") { apply(plan) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 740, height: 560)
    }

    private func apply(_ plan: RigDesigner.Plan) {
        switch mode {
        case 0:
            store.show.lighting.fixtures = plan.fixtures
        case 1:
            // shift the new rig past the highest universe in use
            let start = (store.show.lighting.fixtures.map(\.universe).max() ?? -1) + 1
            var opts = options
            opts.startUniverse = max(options.startUniverse, start)
            store.show.lighting.fixtures += RigDesigner.design(plot: store.show.stagePlot, options: opts).fixtures
        default:
            store.show.lighting.fixtures = RigDesigner.replace(store.show.lighting.fixtures, plot: store.show.stagePlot,
                                                               trim: options.trimHeight, role: lighting.role)
        }
        if options.placeEffects {
            store.show.effects.devices = RigDesigner.placeEffects(store.show.effects.devices, plot: store.show.stagePlot)
        }
        lighting.syncPatch()
        dismiss()
    }
}
