import Foundation

/// "Auto Rig Screens": lays out LED walls to fit whatever stage design is there — a main wall upstage,
/// wing panels between scenic towers (or angled side walls), riser fascias and IMAG screens — fits LED panels
/// to each wall and makes sure every group has a screen output to feed it.
enum ScreenRigger {
    static let tag = "auto-screens"

    struct Result {
        var plot: StagePlot
        var outputs: [String]      // screen-output names the walls expect
        var summary: String
    }

    static func rig(_ plot: StagePlot, panel: LEDPanel? = nil) -> Result {
        var p = plot
        let W = p.stageWidth, D = p.stageDepth
        let panel = panel ?? p.items.first(where: { $0.kind == .ledWall })?.led?.panel ?? LEDPanel.library[0]
        p.items.removeAll { $0.kind == .ledWall }
        var walls: [StageItem] = []
        func add(_ label: String, x: Double, y: Double, w: Double, h: Double, rot: Double = 0, lift: Double? = nil) {
            // Snap to whole panels so the wall is buildable.
            let pw = panel.widthMM / 1000, ph = panel.heightMM / 1000
            let cols = max(1, Int((w / pw).rounded(.down))), rows = max(1, Int((h / ph).rounded(.down)))
            var it = StageItem(kind: .ledWall, label: label, x: (x * 100).rounded() / 100, y: (y * 100).rounded() / 100,
                               width: Double(cols) * pw, depth: 0.3, rotation: rot.rounded())
            it.height = Double(rows) * ph
            it.elevation = lift
            it.notes = tag
            var spec = LEDWallSpec()
            spec.panelName = panel.name
            spec.cols = cols
            spec.rows = rows
            it.led = spec
            walls.append(it)
        }
        func onStage(_ i: StageItem) -> Bool { i.x >= 0 && i.x <= W && i.y >= 0 && i.y <= D }

        let scenic = p.items.filter { $0.kind == .scenic && !onStage($0) && $0.topHeight >= 6 }
        let centre = scenic.first { abs($0.x - W / 2) < 1.5 && $0.y > D }
        let trusses = p.items.filter { $0.kind == .truss && abs($0.rotation.truncatingRemainder(dividingBy: 180)) < 20 }
        let backTrim = trusses.max(by: { $0.y < $1.y })?.topHeight ?? 6.5
        let upTowers = p.items.filter { $0.kind == .trussTower && $0.y > D * 0.6 && onStage($0) }.map(\.x).sorted()

        // Main wall
        var mainW = W * 0.6, mainH: Double
        if let c = centre {
            mainW = min(c.width, W * 0.4)
            mainH = min(c.topHeight * 0.34, backTrim - 1)
        } else {
            if upTowers.count >= 2, let lo = upTowers.first, let hi = upTowers.last, hi - lo > 4 { mainW = min(mainW, hi - lo - 1) }
            mainH = max(2.5, min(backTrim - 1.2, mainW * 9 / 16))
        }
        add("Main LED", x: W / 2, y: D - 0.4, w: mainW, h: mainH)
        mainW = walls[0].width; mainH = walls[0].topHeight

        var wingCount = 0
        if !scenic.isEmpty {
            // Wing panels between the towers of the façade, each side from the centre outwards.
            for side in [-1.0, 1.0] {
                let s = side < 0 ? "L" : "R"
                let towers = scenic.filter { ($0.x - W / 2) * side > 1.5 }.sorted { abs($0.x - W / 2) < abs($1.x - W / 2) }
                var prev = (dx: mainW / 2, y: centre.map { $0.y - 0.5 } ?? D + 2, h: towers.first?.topHeight ?? mainH * 2, w: 0.0)
                for (i, t) in towers.enumerated() {
                    let dx = abs(t.x - W / 2)
                    let gap = hypot(dx - prev.dx, t.y - prev.y) - (prev.w + t.width) / 2 - 0.3
                    if gap >= 1.5 && dx > prev.dx {
                        let ang = atan2(prev.y - t.y, dx - prev.dx) * 180 / .pi
                        add("Wing LED \(s)\(i + 1)", x: W / 2 + side * (dx + prev.dx + (prev.w - t.width) / 2) / 2, y: (t.y + prev.y) / 2 - 0.3,
                            w: gap, h: max(2, min(t.topHeight, prev.h) * 0.5), rot: side * ang, lift: 1.5)
                        wingCount += 1
                    }
                    prev = (dx, t.y, t.topHeight, t.width)
                }
            }
        } else if W >= 14 {
            // Angled side walls flanking the main wall.
            let sideW = (W - mainW) / 2 - 0.8
            if sideW >= 2 {
                for side in [-1.0, 1.0] {
                    add("Side LED \(side < 0 ? "L" : "R")", x: W / 2 + side * (mainW / 2 + 0.4 + sideW / 2), y: D - 0.9 - sideW * 0.13,
                        w: sideW, h: mainH * 0.8, rot: side * 15)
                    wingCount += 1
                }
            }
        }

        // Riser fascias (DJ / drum / artist risers tall enough to carry a strip)
        var fascias = 0
        for r in p.items where (r.kind == .riser || r.kind == .drumRiser) && r.topHeight >= 0.8 && r.width >= 3 && abs(r.rotation) < 10 {
            add(fascias == 0 ? "Riser LED" : "Riser LED \(fascias + 1)", x: r.x, y: r.y - r.depth / 2 - 0.15, w: r.width, h: max(0.5, r.topHeight - 0.1),
                lift: (r.elevation ?? 0) - 0.4)
            fascias += 1
        }

        // IMAG screens outside everything else, for big rooms
        var imag = 0
        if W >= 16 || !scenic.isEmpty {
            let others = p.items.filter { $0.kind.isRigging || $0.kind == .scenic }
            let left = min(0, others.map { $0.x - $0.width / 2 }.min() ?? 0)
            let right = max(W, others.map { $0.x + $0.width / 2 }.max() ?? W)
            let w = min(8, max(4, W * 0.22))
            add("IMAG L", x: left - w / 2 - 1.5, y: 0.5, w: w, h: w * 9 / 16, rot: -12, lift: scenic.isEmpty ? 1 : 3)
            add("IMAG R", x: right + w / 2 + 1.5, y: 0.5, w: w, h: w * 9 / 16, rot: 12, lift: scenic.isEmpty ? 1 : 3)
            imag = 2
        }

        p.items += walls
        var outputs = ["Main LED"]
        if walls.contains(where: { $0.label.hasPrefix("Wing LED") }) { outputs.append("Wing LED") }
        if walls.contains(where: { $0.label.hasPrefix("Side LED") }) { outputs.append("Side LED") }
        if fascias > 0 { outputs.append("Riser LED") }
        if imag > 0 { outputs.append("IMAG") }
        let area = walls.reduce(0) { $0 + $1.width * $1.topHeight }
        let panels = walls.reduce(0) { $0 + ($1.led?.panels ?? 0) }
        var parts = [String(format: "main %.1f × %.1f m", mainW, mainH)]
        if wingCount > 0 { parts.append("\(wingCount) wing/side") }
        if fascias > 0 { parts.append("\(fascias) riser") }
        if imag > 0 { parts.append("2 IMAG") }
        return Result(plot: p, outputs: outputs,
                      summary: "\(walls.count) screens (\(parts.joined(separator: ", "))) · \(panels) panels · \(Int(area.rounded())) m²")
    }

    /// Applies the layout to the show and adds any missing screen outputs (as preview windows until a display is assigned).
    @MainActor
    @discardableResult
    static func install(store: ShowStore) -> String {
        let r = rig(store.show.stagePlot)
        store.show.stagePlot = r.plot
        let added = ensureOutputs(r.outputs, store: store)
        return r.summary + (added > 0 ? " · added \(added) screen output\(added == 1 ? "" : "s")" : "")
    }

    /// Screen-output names a rigged plot expects (one per wall group).
    static func outputNames(for plot: StagePlot) -> [String] {
        let labels = plot.items.filter { $0.kind == .ledWall }.map(\.label)
        return ["Main LED", "Wing LED", "Side LED", "Riser LED", "IMAG"].filter { g in labels.contains { $0.hasPrefix(g) } }
    }

    @MainActor
    @discardableResult
    static func ensureOutputs(for plot: StagePlot, store: ShowStore) -> Int { ensureOutputs(outputNames(for: plot), store: store) }

    @MainActor
    @discardableResult
    static func ensureOutputs(_ names: [String], store: ShowStore) -> Int {
        var added = 0
        for name in names {
            let n = name.lowercased()
            let exists = store.show.screens.contains { o in
                let on = o.name.lowercased()
                return !on.isEmpty && (on == n || on.contains(n) || n.contains(on))
            }
            if !exists {
                // Re-use the untouched default output for the main wall rather than leaving it orphaned.
                if name == "Main LED", let i = store.show.screens.firstIndex(where: { $0.name == "LED Wall" }) {
                    store.show.screens[i].name = name
                } else {
                    store.show.screens.append(ScreenOutput(name: name)); added += 1
                }
            }
        }
        return added
    }
}
