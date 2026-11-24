import Foundation

/// Who is on stage. Drives the automatic stage set layout and the input list.
struct Lineup: Codable, Equatable {
    var artistName: String = "Armanii"
    var leadVocals = 1
    var hypeVocals = 1
    var backingVocals = 0
    var dancers = 0
    var dj = true
    var playback = true
    var drums = false
    var bass = false
    var guitars = 0
    var keys = 0
    var percussion = false
    var horns = 0
    /// Wedges in front of performers (off = in-ears only).
    var wedges = true

    var hasBand: Bool { drums || bass || guitars > 0 || keys > 0 || percussion || horns > 0 }
    var headcount: Int {
        leadVocals + hypeVocals + backingVocals + dancers + (dj ? 1 : 0) + (drums ? 1 : 0) + (bass ? 1 : 0)
            + guitars + keys + (percussion ? 1 : 0) + horns
    }

    struct Preset: Identifiable { let id: String; let lineup: Lineup }
    static func presets(artist: String) -> [Preset] {
        var a = Lineup(); a.artistName = artist; a.hypeVocals = 0
        var b = Lineup(); b.artistName = artist
        var c = Lineup(); c.artistName = artist; c.dancers = 4
        var d = Lineup(); d.artistName = artist; d.dj = false; d.drums = true; d.bass = true; d.guitars = 1; d.keys = 1; d.backingVocals = 2
        var e = d; e.dj = true; e.keys = 2; e.percussion = true; e.horns = 3; e.backingVocals = 3; e.dancers = 4
        return [Preset(id: "Artist + DJ", lineup: a),
                Preset(id: "Artist + DJ + Hype", lineup: b),
                Preset(id: "Artist + DJ + Hype + 4 Dancers", lineup: c),
                Preset(id: "Live band (drums, bass, guitar, keys, 2 BGVs)", lineup: d),
                Preset(id: "Full production (band, DJ, horns, BGVs, dancers)", lineup: e)]
    }
}

/// Automatic stage set: places the artist, hype, dancers, band, DJ and backline on the current stage design,
/// working around trusses, LED walls and risers that are already there.
enum StageSetBuilder {
    static let tag = "auto-set"

    struct Result { var plot: StagePlot; var placed: Int; var notes: [String] }

    static func layout(_ plot: StagePlot, lineup l: Lineup) -> Result {
        var p = plot
        let W = p.stageWidth, D = p.stageDepth
        let cx = W / 2
        var notes: [String] = []
        // Lineup is the source of truth: clear previous performers/backline and our own risers.
        p.items.removeAll { $0.notes == tag || (StageItemKind.band.contains($0.kind) && $0.kind != .label) }

        // Upstage limit: the front face of any LED wall / scrim in the back half of the stage.
        let backFaces = p.items.filter { ($0.kind == .ledWall || $0.kind == .scrim) && $0.y > D * 0.45 && $0.y < D + 0.5 }
            .map { $0.y - $0.depth / 2 }
        let back = min(D - 0.4, (backFaces.min() ?? D) - 0.5)
        // Spacing grows with the stage so big stages don't end up with everyone in a huddle.
        let k = min(2.5, max(1, W / 14))
        let artistY = min(3.0, max(1.0, D * 0.15))
        let bandY = max(artistY + 2.6, min(back - 1.3, artistY + max(4, D * 0.45)))
        let margin = 0.6
        var items: [StageItem] = []

        func add(_ k: StageItemKind, _ label: String, _ x: Double, _ y: Double, w: Double? = nil, d: Double? = nil,
                 h: Double? = nil, elev: Double? = nil) {
            var i = StageItem(kind: k, label: label, x: x, y: y,
                              width: w ?? k.defaultSize.width, depth: d ?? k.defaultSize.height)
            i.height = h
            i.elevation = elev
            i.notes = tag
            items.append(i)
        }
        func wedge(_ x: Double, _ y: Double, _ who: String) {
            if l.wedges { add(.monitorWedge, "Wedge – \(who)", x, max(0.3, y - 0.9)) } else { add(.iem, "IEM – \(who)", x + 0.45, y) }
        }

        // ── Downstage: lead artist(s) centre, hype either side, dancers behind.
        let leads = max(1, l.leadVocals)
        let leadSpan = Double(leads - 1) * 1.8 * k
        for i in 0..<leads {
            let x = cx - leadSpan / 2 + Double(i) * 1.8 * k
            let name = leads == 1 ? l.artistName : "\(l.artistName) \(i + 1)"
            add(.person, name, x, artistY)
            add(.vocalMic, "Mic – \(name)", x, artistY - 0.5)
            if l.wedges {
                add(.monitorWedge, "Wedge L – \(name)", x - 0.45, 0.35)
                add(.monitorWedge, "Wedge R – \(name)", x + 0.45, 0.35)
            }
            add(.iem, "IEM – \(name)", x + 0.5, artistY + 0.3)
        }
        for i in 0..<l.hypeVocals {
            let side: Double = i % 2 == 0 ? -1 : 1
            let step = Double(i / 2)
            let x = min(W - margin, max(margin, cx + side * (leadSpan / 2 + 2.2 * k + step * 1.6 * k)))
            let name = l.hypeVocals == 1 ? "Hype" : "Hype \(i + 1)"
            add(.person, name, x, artistY + 0.5)
            add(.vocalMic, "Mic – \(name)", x, artistY)
            wedge(x, artistY + 0.5, name)
        }
        if l.dancers > 0 {
            let rowY = min(bandY - 1.8, artistY + 1.7 * min(k, 1.6))
            var slots: [Double] = []
            var kk = 0.0
            while slots.count < l.dancers && kk < 20 {
                for side in [-1.0, 1.0] {
                    let x = cx + side * (1.4 * k + kk * 1.3 * k)
                    if x > margin && x < W - margin && slots.count < l.dancers { slots.append(x) }
                }
                kk += 1
            }
            var row2 = 0
            for (i, x) in slots.enumerated() { add(.person, "Dancer \(i + 1)", x, rowY) }
            for i in slots.count..<l.dancers {   // didn't fit across: second row
                let x = cx + (row2 % 2 == 0 ? -1 : 1) * (0.8 * k + Double(row2 / 2) * 1.3 * k)
                add(.person, "Dancer \(i + 1)", x, rowY + 1.0); row2 += 1
            }
        }

        // ── Upstage: pods from the centre outwards.
        struct Pod { var width: Double; var build: (Double) -> Void }
        // Reuse a riser the stage design already has upstage centre (e.g. a template's band riser).
        let designRiser = p.items.first {
            ($0.kind == .drumRiser || $0.kind == .riser || $0.kind == .roundRiser) &&
                abs($0.x - cx) < W * 0.2 && $0.y > D * 0.45 && $0.notes != tag
        }
        let centreRiserH = designRiser?.topHeight ?? 0.4
        let centreY = designRiser?.y ?? bandY

        var centre: Pod?
        var left: [Pod] = [], right: [Pod] = []
        func riser(_ label: String, _ x: Double, _ w: Double, _ d: Double) {
            add(.riser, label, x, bandY, w: w, d: d, h: 0.4)
        }

        let drumsPod = Pod(width: 2.6) { x in
            if designRiser == nil { add(.drumRiser, "Drum riser", x, centreY, w: 2.4, d: 2.4, h: 0.4) }
            add(.drums, "Drum kit", x, centreY - 0.1, elev: centreRiserH)
            add(.person, "Drummer", x, centreY + 0.6, elev: centreRiserH)
            add(.powerDrop, "Power – drums", x + 1.0, centreY + 1.0)
            if l.wedges { add(.sideFill, "Drum fill", x + 1.1, centreY + 0.3, w: 0.6, d: 0.6, elev: centreRiserH) }
        }
        let djPod = Pod(width: 2.4) { x in
            let onDesign = designRiser != nil && abs(x - cx) < 0.01
            let y = onDesign ? centreY : bandY
            if !onDesign { add(.riser, "DJ riser", x, y, w: 2.4, d: 1.8, h: 0.4) }
            let e = onDesign ? centreRiserH : 0.4
            add(.djBooth, "DJ / Selector", x, y - 0.1, elev: e)
            add(.person, "DJ", x, y + 0.55, elev: e)
            add(.diBox, "DI – DJ L/R", x + 1.0, y + 0.6)
            add(.powerDrop, "Power – DJ", x - 1.0, y + 0.8)
            if l.wedges { add(.monitorWedge, "Wedge – DJ", x + 0.9, y - 0.5, elev: e) }
        }
        if l.drums { centre = drumsPod } else if l.dj { centre = djPod }

        if l.bass {
            left.append(Pod(width: 1.6) { x in
                add(.bassAmp, "Bass rig", x, bandY + 0.5)
                add(.person, "Bass", x, bandY - 0.2)
                add(.diBox, "DI – bass", x + 0.5, bandY + 0.2)
                wedge(x, bandY - 0.2, "Bass")
            })
        }
        for g in 0..<l.guitars {
            let name = l.guitars == 1 ? "Guitar" : "Guitar \(g + 1)"
            right.append(Pod(width: 1.6) { x in
                add(.guitarAmp, "Amp – \(name)", x, bandY + 0.5)
                add(.person, name, x, bandY - 0.2)
                wedge(x, bandY - 0.2, name)
            })
        }
        for k in 0..<l.keys {
            let name = l.keys == 1 ? "Keys" : "Keys \(k + 1)"
            right.append(Pod(width: 2.0) { x in
                add(.keys, name, x, bandY)
                add(.person, "\(name) player", x, bandY + 0.6)
                add(.diBox, "DI – \(name) L/R", x + 0.9, bandY + 0.5)
                wedge(x, bandY - 0.1, name)
            })
        }
        if l.percussion {
            left.append(Pod(width: 1.8) { x in
                add(.percussion, "Percussion", x, bandY)
                add(.person, "Percussionist", x, bandY + 0.6)
                wedge(x, bandY - 0.1, "Perc")
            })
        }
        if l.drums && l.dj { left.append(Pod(width: 2.4) { x in djPod.build(x) }) }
        if l.backingVocals > 0 {
            let n = l.backingVocals
            left.append(Pod(width: Double(n) * 0.9 + 0.6) { x in
                riser("BGV riser", x, Double(n) * 0.9 + 0.4, 1.6)
                for i in 0..<n {
                    let px = x - Double(n - 1) * 0.45 + Double(i) * 0.9
                    add(.person, "BGV \(i + 1)", px, bandY + 0.2, elev: 0.4)
                    add(.vocalMic, "Mic – BGV \(i + 1)", px, bandY - 0.3, elev: 0.4)
                }
                if l.wedges { add(.monitorWedge, "Wedge – BGVs", x, bandY - 0.95) }
            })
        }
        if l.horns > 0 {
            let n = l.horns
            right.append(Pod(width: Double(n) * 0.9 + 0.6) { x in
                riser("Horn riser", x, Double(n) * 0.9 + 0.4, 1.6)
                add(.horns, "Horns", x, bandY - 0.3, w: Double(n) * 0.8, d: 0.6, elev: 0.4)
                for i in 0..<n { add(.person, "Horn \(i + 1)", x - Double(n - 1) * 0.45 + Double(i) * 0.9, bandY + 0.3, elev: 0.4) }
            })
        }

        // Spread pods outwards from the centre; overflow goes to a second row nearer the front at the wings.
        let centreW = centre?.width ?? 0
        centre?.build(cx)
        func lay(_ pods: [Pod], dir: Double) {
            // Spread the band across ~75 % of the stage width, never tighter than 0.4 m between pods.
            let halfRoom = W * 0.375 - centreW / 2
            let used = pods.map(\.width).reduce(0, +)
            let gap = max(0.4, min(3.0, (halfRoom - used) / Double(max(1, pods.count))))
            var edge = cx + dir * centreW / 2
            for pod in pods {
                let x = edge + dir * (gap + pod.width / 2)
                if x - pod.width / 2 < margin - 0.01 || x + pod.width / 2 > W - margin + 0.01 {
                    notes.append("Not enough width for everything upstage — check the wings.")
                    let wingX = dir < 0 ? margin + pod.width / 2 : W - margin - pod.width / 2
                    let before = items.count
                    pod.build(wingX)
                    for i in before..<items.count { items[i].y -= 1.9 }   // second row
                    continue
                }
                pod.build(x)
                edge = x + dir * pod.width / 2
            }
        }
        // Balance: if one side is much heavier, move the outermost pod across.
        while left.map(\.width).reduce(0, +) > right.map(\.width).reduce(0, +) + 2.2, let last = left.popLast() { right.append(last) }
        while right.map(\.width).reduce(0, +) > left.map(\.width).reduce(0, +) + 2.2, let last = right.popLast() { left.append(last) }
        lay(left, dir: -1)
        lay(right, dir: 1)

        // ── Offstage world.
        if l.playback {
            add(.playback, "Playback rig", min(W - 0.6, W - margin), max(bandY + 0.6, back - 0.2))
            add(.powerDrop, "Power – playback", W - 0.35, back)
        }
        if l.wedges && W >= 9 {
            add(.sideFill, "Side fill L", 0.45, artistY + 0.4)
            add(.sideFill, "Side fill R", W - 0.45, artistY + 0.4)
        }
        if l.leadVocals > 0 { add(.powerDrop, "Power – DSL", 0.35, back) }

        // Keep everything on the deck (or on catwalks in front).
        for i in items.indices {
            items[i].x = min(W - items[i].width / 2 + 0.3, max(items[i].width / 2 - 0.3, items[i].x))
            items[i].y = min(D, max(0.2, items[i].y))
        }
        p.items += items
        if back - artistY < 4 && l.hasBand { notes.append("Shallow stage: band and front line are close — consider a smaller lineup or a deeper stage.") }
        return Result(plot: p, placed: items.count, notes: Array(Set(notes)))
    }

    /// Input list matching the lineup (vocals first, then band, DJ and playback).
    static func inputList(for l: Lineup) -> [InputChannel] {
        var list: [(String, String, String, Bool, String)] = []
        for i in 0..<max(1, l.leadVocals) {
            list.append(("Lead Vocal\(l.leadVocals > 1 ? " \(i + 1)" : "") – \(l.artistName)", "Wireless SM58 / Beta 58", "Tall boom", false, "Auto-Tune insert from playback rig"))
        }
        for i in 0..<l.hypeVocals { list.append(("Hype Vocal\(l.hypeVocals > 1 ? " \(i + 1)" : "")", "Wireless SM58", "Tall boom", false, "")) }
        for i in 0..<l.backingVocals { list.append(("BGV \(i + 1)", "SM58", "Tall boom", false, "")) }
        if l.drums {
            list += [("Kick In", "Beta 91A", "", false, ""), ("Kick Out", "Beta 52", "Short boom", false, ""),
                     ("Snare Top", "SM57", "Short boom", false, ""), ("Snare Bottom", "SM57", "Short boom", false, "Phase flip"),
                     ("Hi-Hat", "SM81", "Short boom", true, ""), ("Rack Tom", "e604", "Clip", false, ""),
                     ("Floor Tom", "e604", "Clip", false, ""), ("OH L", "KM184", "Tall boom", true, ""),
                     ("OH R", "KM184", "Tall boom", true, "")]
        }
        if l.bass { list.append(("Bass DI", "Active DI", "", true, "Post-amp DI if available")) }
        for g in 0..<l.guitars { list.append(("Guitar\(l.guitars > 1 ? " \(g + 1)" : "")", "SM57 / e906", "Short boom", false, "")) }
        for k in 0..<l.keys {
            let n = l.keys > 1 ? " \(k + 1)" : ""
            list.append(("Keys\(n) L", "DI", "", false, "")); list.append(("Keys\(n) R", "DI", "", false, ""))
        }
        if l.percussion { list.append(("Percussion L", "SM57", "Short boom", false, "")); list.append(("Percussion R", "SM57", "Short boom", false, "")) }
        for h in 0..<l.horns { list.append(("Horn \(h + 1)", "Clip-on condenser", "", true, "")) }
        if l.dj { list.append(("DJ L", "DI (stereo)", "", false, "")); list.append(("DJ R", "DI (stereo)", "", false, "")) }
        if l.playback {
            list.append(("Playback Stems L", "DI (stereo)", "", false, "")); list.append(("Playback Stems R", "DI (stereo)", "", false, ""))
            list.append(("Click / Talkback", "DI", "", false, "IEM only — never to FOH"))
        }
        return list.enumerated().map { i, c in
            InputChannel(channel: i + 1, source: c.0, micOrDI: c.1, stand: c.2, phantom: c.3, notes: c.4)
        }
    }
}
