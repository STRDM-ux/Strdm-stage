import SceneKit
import AppKit
import QuartzCore

/// Shared materials for all scenic pieces in one 3D view (the controller animates the glow colours).
final class ScenicMaterials {
    let stone = SCNMaterial(), trim = SCNMaterial(), glowA = SCNMaterial(), glowB = SCNMaterial(), beam = SCNMaterial()
    let theme: FestivalTheme

    init(theme: FestivalTheme) {
        self.theme = theme
        stone.lightingModel = .physicallyBased
        stone.diffuse.contents = theme.stone.nsColor
        stone.roughness.contents = 0.75
        // A little self-illumination so the sculpture still reads in a dark look.
        stone.emission.contents = theme.stone.scaled(0.22).nsColor
        trim.lightingModel = .physicallyBased
        trim.diffuse.contents = theme.trim.nsColor
        trim.metalness.contents = 0.8
        trim.roughness.contents = 0.3
        trim.emission.contents = theme.trim.scaled(0.25).nsColor
        for (m, c) in [(glowA, theme.glowA), (glowB, theme.glowB)] {
            m.lightingModel = .constant
            m.diffuse.contents = NSColor.black
            m.emission.contents = c.nsColor
        }
        beam.lightingModel = .constant
        beam.diffuse.contents = NSColor.black
        beam.emission.contents = theme.glowA.nsColor
        beam.transparency = 0.07
        beam.blendMode = .add
        beam.writesToDepthBuffer = false
        beam.isDoubleSided = true
    }
}

extension RGB {
    var nsColor: NSColor { NSColor(red: CGFloat(min(1, r)), green: CGFloat(min(1, g)), blue: CGFloat(min(1, b)), alpha: 1) }
}

/// Procedural sculptures for festival stages. Local space: origin at the base centre, x across, y up, +z towards the audience.
enum ScenicFactory {
    private enum Part: Int { case stone, trim, glowA, glowB }

    private final class Kit {
        var groups = (0..<4).map { _ in SCNNode() }
        func put(_ g: SCNGeometry, _ part: Part, at p: SCNVector3, euler: SCNVector3 = SCNVector3Zero, scale: SCNVector3 = SCNVector3(1, 1, 1)) {
            let n = SCNNode(geometry: g)
            n.position = p
            n.eulerAngles = euler
            n.scale = scale
            groups[part.rawValue].addChildNode(n)
        }
        func box(_ w: CGFloat, _ h: CGFloat, _ l: CGFloat, _ part: Part, at p: SCNVector3, euler: SCNVector3 = SCNVector3Zero) {
            put(SCNBox(width: w, height: h, length: l, chamferRadius: 0), part, at: p, euler: euler)
        }
        func cone(top: CGFloat, bottom: CGFloat, height: CGFloat, sides: Int = 8, _ part: Part, at p: SCNVector3, euler: SCNVector3 = SCNVector3Zero) {
            let c = SCNCone(topRadius: top, bottomRadius: bottom, height: height)
            c.radialSegmentCount = sides
            put(c, part, at: p, euler: euler)
        }
        func cyl(_ r: CGFloat, _ h: CGFloat, sides: Int = 12, _ part: Part, at p: SCNVector3, euler: SCNVector3 = SCNVector3Zero) {
            let c = SCNCylinder(radius: r, height: h)
            c.radialSegmentCount = sides
            put(c, part, at: p, euler: euler)
        }
        func sphere(_ r: CGFloat, _ part: Part, at p: SCNVector3, scale: SCNVector3 = SCNVector3(1, 1, 1)) {
            let s = SCNSphere(radius: r)
            s.segmentCount = 14
            put(s, part, at: p, scale: scale)
        }
        func ring(_ radius: CGFloat, pipe: CGFloat, _ part: Part, at p: SCNVector3, upright: Bool = false) {
            let t = SCNTorus(ringRadius: radius, pipeRadius: pipe)
            t.ringSegmentCount = 28
            t.pipeSegmentCount = 8
            put(t, part, at: p, euler: upright ? SCNVector3(CGFloat.pi / 2, 0, 0) : SCNVector3Zero)
        }
    }

    /// Builds one piece `w` wide, `l` deep and `h` tall. Each material group is merged into a single mesh.
    static func node(_ style: ScenicStyle, width: Double, depth: Double, height: Double, mats: ScenicMaterials, skyBeam: Bool) -> SCNNode {
        let w = CGFloat(max(0.5, width)), l = CGFloat(max(0.5, depth)), h = CGFloat(max(1, height))
        let k = Kit()
        var top = h          // where a sky beam would start
        switch style {
        case .spire: spire(k, w, l, h)
        case .facade: facade(k, w, l, h)
        case .arch: arch(k, w, l, h)
        case .crown: crown(k, w, l, h)
        case .sunDisc: sunDisc(k, w, l, h)
        case .fin: fin(k, w, l, h)
        case .petal: petal(k, w, l, h)
        case .crystal: crystal(k, w, l, h)
        case .tree: tree(k, w, l, h)
        case .mushroom: mushroom(k, w, l, h)
        case .pylon: pylon(k, w, l, h)
        case .portal: portal(k, w, l, h)
        case .palm: palm(k, w, l, h)
        case .plume: plume(k, w, l, h); top = h * 0.9
        case .lantern: lantern(k, w, l, h)
        }
        let out = SCNNode()
        let materials = [mats.stone, mats.trim, mats.glowA, mats.glowB]
        for (i, g) in k.groups.enumerated() where !g.childNodes.isEmpty {
            let flat = g.flattenedClone()
            flat.geometry?.materials = [materials[i]]
            out.addChildNode(flat)
        }
        if skyBeam && style.hasSkyBeam {
            // Searchlight sweeping the sky from the top of the piece.
            let pivot = SCNNode()
            pivot.position = SCNVector3(0, top, 0)
            let len: CGFloat = 70
            let cone = SCNCone(topRadius: 1.6, bottomRadius: 0.08, height: len)
            cone.radialSegmentCount = 12
            cone.firstMaterial = mats.beam
            let c = SCNNode(geometry: cone)
            c.position = SCNVector3(0, len / 2, 0)
            pivot.addChildNode(c)
            let seed = CGFloat(abs(width * 7.3 + height * 3.1).truncatingRemainder(dividingBy: 1))
            pivot.eulerAngles = SCNVector3(0.25, 0, -0.5 + seed)
            let sway = SCNAction.sequence([
                .rotateBy(x: 0.35, y: 0, z: 0.9, duration: 5 + Double(seed) * 3),
                .rotateBy(x: -0.35, y: 0, z: -0.9, duration: 5 + Double(seed) * 3)
            ])
            sway.timingMode = .easeInEaseOut
            pivot.runAction(.repeatForever(sway))
            out.addChildNode(pivot)
        }
        return out
    }

    // MARK: Pieces

    private static func spire(_ k: Kit, _ w: CGFloat, _ l: CGFloat, _ h: CGFloat) {
        let r = min(w, l) / 2 * 0.85
        let baseH = h * 0.1, shaftH = h * 0.56, roofH = h * 0.28
        k.box(w, baseH, l, .stone, at: SCNVector3(0, baseH / 2, 0))
        k.box(w * 1.04, 0.18, l * 1.04, .trim, at: SCNVector3(0, baseH, 0))
        k.cone(top: r * 0.72, bottom: r, height: shaftH, .stone, at: SCNVector3(0, baseH + shaftH / 2, 0))
        let y1 = baseH + shaftH
        k.cyl(r * 0.95, h * 0.03, sides: 8, .trim, at: SCNVector3(0, y1, 0))
        k.ring(r * 0.98, pipe: 0.07, .glowA, at: SCNVector3(0, y1 + h * 0.02, 0))
        k.cone(top: 0, bottom: r * 0.9, height: roofH, .stone, at: SCNVector3(0, y1 + h * 0.03 + roofH / 2, 0))
        k.sphere(r * 0.16, .glowA, at: SCNVector3(0, y1 + h * 0.03 + roofH, 0))
        // glowing seams + windows on four faces
        for a in stride(from: CGFloat(0), to: 2 * .pi, by: .pi / 2) {
            let rr = r * 0.9
            k.box(0.1, shaftH * 0.9, 0.1, .glowA, at: SCNVector3(sin(a + .pi / 4) * rr, baseH + shaftH / 2, cos(a + .pi / 4) * rr),
                  euler: SCNVector3(0, 0, 0))
            for level in 0..<3 {
                let y = baseH + shaftH * (0.25 + 0.25 * CGFloat(level))
                let wr = r * (0.97 - 0.09 * CGFloat(level))
                k.box(r * 0.28, shaftH * 0.1, 0.08, .glowB, at: SCNVector3(sin(a) * wr, y, cos(a) * wr), euler: SCNVector3(0, a, 0))
            }
        }
    }

    private static func facade(_ k: Kit, _ w: CGFloat, _ l: CGFloat, _ h: CGFloat) {
        let wallH = h * 0.82
        k.box(w, wallH, l * 0.7, .stone, at: SCNVector3(0, wallH / 2, 0))
        k.box(w * 1.02, h * 0.03, l * 0.78, .trim, at: SCNVector3(0, wallH * 0.12, 0))
        k.box(w, 0.14, 0.1, .glowA, at: SCNVector3(0, wallH * 0.93, l * 0.36))
        let n = max(3, Int(w / 0.9))
        for i in 0..<n where i % 2 == 0 {
            let x = -w / 2 + (CGFloat(i) + 0.5) * w / CGFloat(n)
            k.box(w / CGFloat(n), h * 0.1, l * 0.7, .stone, at: SCNVector3(x, wallH + h * 0.05, 0))
        }
        let cols = max(2, Int(w / 1.6))
        for c in 0..<cols {
            let x = -w / 2 + (CGFloat(c) + 0.5) * w / CGFloat(cols)
            for row in 0..<3 {
                let y = wallH * (0.3 + 0.2 * CGFloat(row))
                k.box(w / CGFloat(cols) * 0.34, wallH * 0.11, 0.08, .glowB, at: SCNVector3(x, y, l * 0.36))
                k.cyl(w / CGFloat(cols) * 0.17, 0.08, .glowB, at: SCNVector3(x, y + wallH * 0.055, l * 0.36), euler: SCNVector3(CGFloat.pi / 2, 0, 0))
            }
        }
    }

    private static func arch(_ k: Kit, _ w: CGFloat, _ l: CGFloat, _ h: CGFloat) {
        let thick = max(0.5, w * 0.1)
        let R = min(w / 2 - thick / 2, h * 0.6)
        let legH = max(0.5, h - R - thick / 2)
        for side in [-1, 1] as [CGFloat] {
            k.box(thick, legH, l, .stone, at: SCNVector3(side * R, legH / 2, 0))
            k.box(thick * 1.25, 0.25, l * 1.15, .trim, at: SCNVector3(side * R, 0.12, 0))
            k.box(thick * 1.2, 0.2, l * 1.1, .trim, at: SCNVector3(side * R, legH, 0))
            k.box(0.12, legH * 0.85, 0.1, .glowB, at: SCNVector3(side * R, legH / 2, l / 2 + 0.03))
        }
        let segs = 14
        for i in 0..<segs {
            let a = CGFloat.pi * (CGFloat(i) + 0.5) / CGFloat(segs)
            let len = CGFloat.pi * R / CGFloat(segs) * 1.12
            k.box(len, thick, l, .stone, at: SCNVector3(cos(a) * R, legH + sin(a) * R, 0), euler: SCNVector3(0, 0, a + .pi / 2))
            let ri = R - thick / 2 - 0.06
            k.box(len * 0.9, 0.12, 0.12, .glowA, at: SCNVector3(cos(a) * ri, legH + sin(a) * ri, l / 2), euler: SCNVector3(0, 0, a + .pi / 2))
        }
        k.cone(top: 0, bottom: thick * 0.6, height: thick * 1.6, sides: 4, .trim, at: SCNVector3(0, legH + R + thick * 1.1, 0))
        k.sphere(thick * 0.3, .glowA, at: SCNVector3(0, legH + R + thick * 0.2, l / 2 + 0.1))
    }

    private static func crown(_ k: Kit, _ w: CGFloat, _ l: CGFloat, _ h: CGFloat) {
        // stepped plinth
        var y: CGFloat = 0
        for (i, f) in ([1.0, 0.8, 0.62] as [CGFloat]).enumerated() {
            let sh = h * 0.1
            k.cyl(w / 2 * f, sh, sides: 8, .stone, at: SCNVector3(0, y + sh / 2, 0))
            k.ring(w / 2 * f * 0.98, pipe: 0.08, i % 2 == 0 ? .glowA : .glowB, at: SCNVector3(0, y + sh, 0))
            y += sh
        }
        // drum + dome
        k.cyl(w * 0.24, h * 0.2, sides: 12, .stone, at: SCNVector3(0, y + h * 0.1, 0))
        for a in stride(from: CGFloat(0), to: 2 * .pi, by: .pi / 4) {
            k.box(0.14, h * 0.16, 0.1, .glowB, at: SCNVector3(sin(a) * w * 0.245, y + h * 0.1, cos(a) * w * 0.245), euler: SCNVector3(0, a, 0))
        }
        y += h * 0.2
        k.sphere(w * 0.25, .trim, at: SCNVector3(0, y, 0), scale: SCNVector3(1, 0.75, 1))
        // halo + rays facing the audience
        let cy = h * 0.66, R = min(w * 0.46, h * 0.3)
        k.ring(R, pipe: R * 0.045, .glowA, at: SCNVector3(0, cy, 0), upright: true)
        k.ring(R * 0.72, pipe: R * 0.03, .glowB, at: SCNVector3(0, cy, 0.05), upright: true)
        for i in 0..<16 {
            let a = CGFloat(i) / 16 * 2 * .pi
            let len = R * (i % 2 == 0 ? 0.55 : 0.3)
            let rr = R * 1.08 + len / 2
            k.box(R * 0.05, len, 0.12, i % 2 == 0 ? .trim : .glowB, at: SCNVector3(sin(a) * rr, cy + cos(a) * rr, 0), euler: SCNVector3(0, 0, -a))
        }
        // spire through the halo
        let spH = h - y
        k.cone(top: 0, bottom: w * 0.07, height: spH, .stone, at: SCNVector3(0, y + spH / 2, -0.2))
        k.sphere(w * 0.035, .glowA, at: SCNVector3(0, h, -0.2))
    }

    private static func sunDisc(_ k: Kit, _ w: CGFloat, _ l: CGFloat, _ h: CGFloat) {
        let R = min(w / 2 * 0.8, h * 0.4)
        let cy = h - R * 1.25
        // pedestal
        k.cone(top: R * 0.3, bottom: min(w / 2, R * 0.9), height: max(0.5, cy - R * 0.6), sides: 6, .stone, at: SCNVector3(0, max(0.5, cy - R * 0.6) / 2, -0.3))
        k.cyl(R, 0.5, sides: 32, .stone, at: SCNVector3(0, cy, 0), euler: SCNVector3(CGFloat.pi / 2, 0, 0))
        k.ring(R * 0.97, pipe: R * 0.04, .glowA, at: SCNVector3(0, cy, 0.25), upright: true)
        k.ring(R * 0.66, pipe: R * 0.03, .glowB, at: SCNVector3(0, cy, 0.28), upright: true)
        k.ring(R * 0.36, pipe: R * 0.03, .glowA, at: SCNVector3(0, cy, 0.28), upright: true)
        k.sphere(R * 0.16, .trim, at: SCNVector3(0, cy, 0.3), scale: SCNVector3(1, 1, 0.4))
        for i in 0..<18 {
            let a = CGFloat(i) / 18 * 2 * .pi
            let len = R * (i % 2 == 0 ? 0.25 : 0.15)
            let rr = R + len / 2
            k.cone(top: 0, bottom: R * 0.07, height: len, sides: 4, i % 3 == 0 ? .glowB : .trim,
                   at: SCNVector3(sin(a) * rr, cy + cos(a) * rr, 0), euler: SCNVector3(0, 0, -a))
        }
        for i in 0..<8 {      // spokes
            let a = CGFloat(i) / 8 * 2 * .pi
            k.box(0.08, R * 0.28, 0.06, .glowB, at: SCNVector3(sin(a) * R * 0.51, cy + cos(a) * R * 0.51, 0.27), euler: SCNVector3(0, 0, -a))
        }
    }

    private static func fin(_ k: Kit, _ w: CGFloat, _ l: CGFloat, _ h: CGFloat) {
        let bw = w * 0.8, bodyH = h * 0.78
        k.box(bw, bodyH, l * 0.5, .stone, at: SCNVector3(0, bodyH / 2, 0))
        let tip = SCNPyramid(width: bw, height: h - bodyH, length: l * 0.5)
        k.put(tip, .stone, at: SCNVector3(0, bodyH, 0))
        k.box(bw * 0.12, h * 0.9, 0.1, .glowA, at: SCNVector3(0, h * 0.45, l * 0.26))
        for side in [-1, 1] as [CGFloat] {
            k.box(0.1, bodyH, 0.1, .glowB, at: SCNVector3(side * bw / 2, bodyH / 2, l * 0.26))
            k.box(bw * 0.3, 0.1, 0.1, .glowB, at: SCNVector3(side * bw * 0.3, bodyH * 0.5, l * 0.26), euler: SCNVector3(0, 0, side * 0.6))
        }
        k.box(w, 0.3, l, .trim, at: SCNVector3(0, 0.15, 0))
    }

    private static func petal(_ k: Kit, _ w: CGFloat, _ l: CGFloat, _ h: CGFloat) {
        for (i, f) in ([1.0, 0.72] as [CGFloat]).enumerated() {
            let ph = h * f, pw = w * (i == 0 ? 1 : 0.7)
            k.sphere(1, .stone, at: SCNVector3(0, ph * 0.5, i == 0 ? -l * 0.15 : l * 0.2), scale: SCNVector3(pw / 2, ph / 2, l * 0.16))
            k.box(0.12, ph * 0.86, 0.08, i == 0 ? .glowA : .glowB, at: SCNVector3(0, ph * 0.5, (i == 0 ? -l * 0.15 : l * 0.2) + l * 0.17))
            k.sphere(pw * 0.05, .glowA, at: SCNVector3(0, ph, i == 0 ? -l * 0.15 : l * 0.2))
        }
        k.cyl(w * 0.45, 0.4, sides: 10, .trim, at: SCNVector3(0, 0.2, 0))
    }

    private static func crystal(_ k: Kit, _ w: CGFloat, _ l: CGFloat, _ h: CGFloat) {
        let shards: [(x: CGFloat, z: CGFloat, f: CGFloat, tilt: CGFloat, lean: CGFloat, part: Part)] = [
            (0, 0, 1, 0, 0, .glowA), (-0.3, 0.1, 0.68, 0.28, 0.1, .stone), (0.32, 0.05, 0.6, -0.3, 0.12, .glowB),
            (-0.12, 0.3, 0.42, 0.14, 0.35, .glowB), (0.16, 0.32, 0.34, -0.2, 0.4, .stone), (0.42, -0.2, 0.4, -0.45, -0.1, .glowA)
        ]
        for s in shards {
            let sh = h * s.f, r = w * 0.13 * (0.6 + s.f * 0.5)
            let holder = SCNNode()
            let body = SCNCylinder(radius: r, height: sh * 0.78); body.radialSegmentCount = 6
            let b = SCNNode(geometry: body); b.position = SCNVector3(0, sh * 0.39, 0)
            let tip = SCNCone(topRadius: 0, bottomRadius: r, height: sh * 0.22); tip.radialSegmentCount = 6
            let t = SCNNode(geometry: tip); t.position = SCNVector3(0, sh * 0.89, 0)
            holder.addChildNode(b); holder.addChildNode(t)
            holder.position = SCNVector3(s.x * w, 0, s.z * l)
            holder.eulerAngles = SCNVector3(s.lean, 0, s.tilt)
            k.groups[s.part.rawValue].addChildNode(holder)
        }
        k.cyl(w * 0.5, 0.35, sides: 7, .stone, at: SCNVector3(0, 0.17, 0))
    }

    private static func tree(_ k: Kit, _ w: CGFloat, _ l: CGFloat, _ h: CGFloat) {
        let trunkH = h * 0.6
        k.cone(top: w * 0.08, bottom: w * 0.17, height: trunkH, sides: 9, .stone, at: SCNVector3(0, trunkH / 2, 0))
        k.cone(top: w * 0.16, bottom: w * 0.3, height: h * 0.06, sides: 9, .stone, at: SCNVector3(0, h * 0.03, 0))
        let R = w * 0.5
        let blobs: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(0, 0.82, 0, 0.36), (-0.3, 0.72, 0.05, 0.3), (0.3, 0.72, 0.05, 0.3),
                                                             (0, 0.7, 0.28, 0.27), (-0.15, 0.9, -0.1, 0.24), (0.18, 0.9, 0.08, 0.24), (0, 0.7, -0.28, 0.27)]
        for b in blobs { k.sphere(w * b.3, .trim, at: SCNVector3(b.0 * w, h * b.1, b.2 * w), scale: SCNVector3(1, 0.8, 1)) }
        for i in 0..<5 {      // branches
            let a = CGFloat(i) / 5 * 2 * .pi
            k.cyl(w * 0.03, R * 0.9, sides: 6, .stone, at: SCNVector3(sin(a) * R * 0.3, trunkH + R * 0.2, cos(a) * R * 0.3),
                  euler: SCNVector3(cos(a) * 0.8, 0, -sin(a) * 0.8))
        }
        for i in 0..<10 {     // hanging lanterns
            let a = CGFloat(i) / 10 * 2 * .pi, rr = R * (0.45 + 0.35 * CGFloat(i % 3) / 2)
            let y = h * (0.52 + 0.05 * CGFloat(i % 2))
            k.sphere(w * 0.035, i % 2 == 0 ? .glowA : .glowB, at: SCNVector3(sin(a) * rr, y, cos(a) * rr))
            k.box(0.03, h * 0.12, 0.03, .glowB, at: SCNVector3(sin(a) * rr, y + h * 0.065, cos(a) * rr))
        }
        for a in [0.4, 2.2, 4.1] as [CGFloat] {   // glowing roots / vines
            k.box(0.08, trunkH * 0.8, 0.06, .glowA, at: SCNVector3(sin(a) * w * 0.125, trunkH * 0.42, cos(a) * w * 0.125), euler: SCNVector3(0, a, 0.05))
        }
    }

    private static func mushroom(_ k: Kit, _ w: CGFloat, _ l: CGFloat, _ h: CGFloat) {
        let stemH = h * 0.72, R = w / 2
        k.cone(top: R * 0.22, bottom: R * 0.36, height: stemH, sides: 10, .stone, at: SCNVector3(0, stemH / 2, 0))
        k.sphere(R, .trim, at: SCNVector3(0, stemH, 0), scale: SCNVector3(1, (h - stemH) / R, 1))
        k.cyl(R * 0.97, 0.12, sides: 20, .stone, at: SCNVector3(0, stemH - 0.02, 0))
        k.ring(R * 0.8, pipe: 0.07, .glowA, at: SCNVector3(0, stemH - 0.1, 0))
        k.ring(R * 0.5, pipe: 0.06, .glowB, at: SCNVector3(0, stemH - 0.1, 0))
        for i in 0..<9 {
            let a = CGFloat(i) / 9 * 2 * .pi + 0.3, rr = R * (i % 2 == 0 ? 0.6 : 0.3)
            let y = stemH + (h - stemH) * (i % 2 == 0 ? 0.72 : 0.93)
            k.sphere(R * 0.09, i % 2 == 0 ? .glowB : .glowA, at: SCNVector3(sin(a) * rr, y, cos(a) * rr), scale: SCNVector3(1, 0.4, 1))
        }
    }

    private static func pylon(_ k: Kit, _ w: CGFloat, _ l: CGFloat, _ h: CGFloat) {
        let r = min(w, l) / 2
        k.cone(top: r * 0.35, bottom: r, height: h * 0.92, sides: 4, .stone, at: SCNVector3(0, h * 0.46, 0), euler: SCNVector3(0, CGFloat.pi / 4, 0))
        for a in stride(from: CGFloat.pi / 4, to: 2 * .pi, by: .pi / 2) {
            // edge strips follow the taper
            let lean = atan2(r * 0.65, h * 0.92)
            k.box(0.1, h * 0.9, 0.1, .glowA, at: SCNVector3(sin(a) * r * 0.69, h * 0.46, cos(a) * r * 0.69),
                  euler: SCNVector3(-cos(a) * lean, 0, sin(a) * lean))
        }
        for (i, f) in ([0.55, 0.7, 0.85] as [CGFloat]).enumerated() {
            k.ring(r * (1.25 - 0.25 * CGFloat(i)), pipe: 0.07, .glowB, at: SCNVector3(0, h * f, 0))
        }
        k.sphere(r * 0.3, .glowA, at: SCNVector3(0, h * 0.96, 0))
        k.box(w * 1.1, 0.3, l * 1.1, .trim, at: SCNVector3(0, 0.15, 0))
    }

    private static func portal(_ k: Kit, _ w: CGFloat, _ l: CGFloat, _ h: CGFloat) {
        let R = min(w / 2, h / 2) * 0.86
        let cy = h - R * 1.14
        k.ring(R, pipe: R * 0.12, .stone, at: SCNVector3(0, cy, 0), upright: true)
        k.ring(R * 0.86, pipe: R * 0.035, .glowA, at: SCNVector3(0, cy, R * 0.06), upright: true)
        k.ring(R * 1.14, pipe: R * 0.02, .glowB, at: SCNVector3(0, cy, 0), upright: true)
        for i in 0..<12 {
            let a = CGFloat(i) / 12 * 2 * .pi
            k.box(R * 0.14, R * 0.2, R * 0.3, i % 3 == 0 ? .glowB : .trim, at: SCNVector3(sin(a) * R, cy + cos(a) * R, 0), euler: SCNVector3(0, 0, -a))
        }
        if cy - R > 0.3 {
            for side in [-1, 1] as [CGFloat] {
                k.box(R * 0.3, cy - R * 0.6, l * 0.8, .stone, at: SCNVector3(side * R * 0.75, (cy - R * 0.6) / 2, 0))
            }
        }
        k.box(min(w, R * 2.2), 0.4, l, .trim, at: SCNVector3(0, 0.2, 0))
    }

    private static func palm(_ k: Kit, _ w: CGFloat, _ l: CGFloat, _ h: CGFloat) {
        let trunkH = h * 0.8, segs = 7
        for i in 0..<segs {
            let t = CGFloat(i) / CGFloat(segs)
            let x = sin(t * 1.2) * w * 0.18
            k.cone(top: w * 0.05, bottom: w * 0.07, height: trunkH / CGFloat(segs) * 1.05, sides: 8, .stone,
                   at: SCNVector3(x, trunkH * (t + 0.5 / CGFloat(segs)), 0))
            if i % 2 == 1 { k.ring(w * 0.07, pipe: 0.04, .glowA, at: SCNVector3(x, trunkH * t, 0)) }
        }
        let tx = sin(1.2) * w * 0.18
        let frondL = max(w * 0.6, h * 0.24)
        for i in 0..<9 {
            let a = CGFloat(i) / 9 * 2 * .pi
            let holder = SCNNode()
            let f = SCNNode(geometry: SCNBox(width: frondL, height: 0.07, length: frondL * 0.16, chamferRadius: 0))
            f.position = SCNVector3(frondL / 2, 0, 0)
            let tipG = SCNNode(geometry: SCNBox(width: frondL * 0.5, height: 0.06, length: frondL * 0.1, chamferRadius: 0))
            tipG.position = SCNVector3(frondL * 1.15, -frondL * 0.16, 0)
            tipG.eulerAngles.z = -0.7
            holder.addChildNode(f); holder.addChildNode(tipG)
            holder.position = SCNVector3(tx, trunkH, 0)
            holder.eulerAngles = SCNVector3(0, a, 0.32 - 0.12 * CGFloat(i % 2))
            k.groups[(i % 3 == 0 ? Part.glowA : Part.glowB).rawValue].addChildNode(holder)
        }
        k.sphere(w * 0.09, .trim, at: SCNVector3(tx, trunkH, 0))
        k.cyl(w * 0.2, 0.3, sides: 8, .trim, at: SCNVector3(0, 0.15, 0))
    }

    private static func plume(_ k: Kit, _ w: CGFloat, _ l: CGFloat, _ h: CGFloat) {
        let n = 11
        let baseY = h * 0.12
        for i in 0..<n {
            let t = CGFloat(i) / CGFloat(n - 1) - 0.5           // −0.5…0.5
            let a = t * 2.2
            let len = h * 0.88 * (1 - abs(t) * 0.55)
            // keep the fan inside the piece's width
            let reach = min(len, a == 0 ? len : (w / 2) / max(0.05, abs(sin(a))))
            let holder = SCNNode()
            let feather = SCNSphere(radius: 1); feather.segmentCount = 12
            let f = SCNNode(geometry: feather)
            f.scale = SCNVector3(reach * 0.085, reach / 2, 0.12)
            f.position = SCNVector3(0, reach / 2, 0)
            let spine = SCNNode(geometry: SCNBox(width: 0.07, height: reach * 0.95, length: 0.3, chamferRadius: 0))
            spine.position = SCNVector3(0, reach / 2, 0)
            holder.addChildNode(f)
            holder.position = SCNVector3(0, baseY, CGFloat(i % 2) * 0.15)
            holder.eulerAngles.z = -a
            let part: Part = i % 3 == 0 ? .glowA : (i % 3 == 1 ? .glowB : .stone)
            k.groups[part.rawValue].addChildNode(holder)
            let sHolder = SCNNode()
            sHolder.addChildNode(spine)
            sHolder.position = holder.position
            sHolder.eulerAngles.z = -a
            k.groups[Part.trim.rawValue].addChildNode(sHolder)
        }
        k.sphere(min(w * 0.12, h * 0.09), .trim, at: SCNVector3(0, baseY, 0.3))
        k.cone(top: w * 0.1, bottom: min(w * 0.3, h * 0.2), height: baseY, sides: 8, .stone, at: SCNVector3(0, baseY / 2, 0))
        k.ring(min(w * 0.14, h * 0.1), pipe: 0.06, .glowA, at: SCNVector3(0, baseY, 0.3), upright: true)
    }

    private static func lantern(_ k: Kit, _ w: CGFloat, _ l: CGFloat, _ h: CGFloat) {
        let r = min(w, l) / 2
        k.cyl(r * 0.14, h * 0.8, sides: 8, .stone, at: SCNVector3(0, h * 0.4, 0))
        k.cyl(r * 0.6, 0.25, sides: 8, .trim, at: SCNVector3(0, 0.12, 0))
        k.sphere(r * 0.55, .glowA, at: SCNVector3(0, h * 0.86, 0))
        k.ring(r * 0.6, pipe: 0.05, .trim, at: SCNVector3(0, h * 0.86, 0))
        k.cone(top: 0, bottom: r * 0.45, height: h * 0.1, sides: 6, .trim, at: SCNVector3(0, h * 0.97, 0))
        k.ring(r * 0.2, pipe: 0.04, .glowB, at: SCNVector3(0, h * 0.5, 0))
    }

    // MARK: Sky + fireworks

    /// Night-sky cube map (stars, glow on the horizon). Order: +X, −X, +Y, −Y, +Z, −Z.
    @MainActor static let nightSky: [NSImage] = {
        func face(_ kind: Int, seed: UInt64) -> NSImage {
            let n = 768
            let img = NSImage(size: NSSize(width: n, height: n))
            img.lockFocus()
            let top = NSColor(red: 0.012, green: 0.012, blue: 0.045, alpha: 1)
            if kind == 0 {        // side: horizon runs through the middle
                NSGradient(colorsAndLocations: (NSColor.black, 0), (NSColor(red: 0.03, green: 0.01, blue: 0.05, alpha: 1), 0.46),
                           (NSColor(red: 0.13, green: 0.04, blue: 0.2, alpha: 1), 0.5), (NSColor(red: 0.04, green: 0.02, blue: 0.1, alpha: 1), 0.62),
                           (top, 1))?.draw(in: NSRect(x: 0, y: 0, width: n, height: n), angle: 90)
            } else {
                (kind == 1 ? top : NSColor.black).setFill()
                NSRect(x: 0, y: 0, width: n, height: n).fill()
            }
            if kind != 2 {
                var s = seed
                func rnd() -> CGFloat { s = s &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(s >> 33) / CGFloat(1 << 31) }
                for _ in 0..<(kind == 1 ? 520 : 300) {
                    let x = rnd() * CGFloat(n), y = kind == 0 ? CGFloat(n) * (0.52 + rnd() * 0.48) : rnd() * CGFloat(n)
                    let b = rnd(), size = b > 0.96 ? 2.6 : (b > 0.8 ? 1.6 : 1.0)
                    NSColor(red: 0.8 + rnd() * 0.2, green: 0.85, blue: 1, alpha: 0.35 + b * 0.65).setFill()
                    NSBezierPath(ovalIn: NSRect(x: x, y: y, width: size, height: size)).fill()
                }
            }
            img.unlockFocus()
            return img
        }
        return [face(0, seed: 11), face(0, seed: 23), face(1, seed: 37), face(2, seed: 0), face(0, seed: 51), face(0, seed: 67)]
    }()

    @MainActor private static let sparkImage: NSImage = {
        let img = NSImage(size: NSSize(width: 32, height: 32))
        img.lockFocus()
        NSGradient(colors: [.white, NSColor(white: 1, alpha: 0)])?.draw(in: NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 32, height: 32)), relativeCenterPosition: .zero)
        img.unlockFocus()
        return img
    }()

    /// One firework shell bursting at `position`; the node removes itself.
    @MainActor static func firework(at position: SCNVector3, color: RGB) -> SCNNode {
        let ps = SCNParticleSystem()
        ps.loops = false
        ps.birthRate = 2600
        ps.emissionDuration = 0.07
        ps.particleLifeSpan = 1.7
        ps.particleLifeSpanVariation = 0.5
        ps.emitterShape = SCNSphere(radius: 0.2)
        ps.birthLocation = .surface
        ps.birthDirection = .surfaceNormal
        ps.particleVelocity = 13
        ps.particleVelocityVariation = 4
        ps.acceleration = SCNVector3(0, -4.5, 0)
        ps.dampingFactor = 1.4
        ps.particleSize = 0.32
        ps.particleSizeVariation = 0.12
        ps.particleImage = sparkImage
        ps.particleColor = color.nsColor
        ps.particleColorVariation = SCNVector4(0.06, 0.1, 0.2, 0)
        ps.blendMode = .additive
        ps.isLightingEnabled = false
        ps.isAffectedByGravity = false
        let fade = CAKeyframeAnimation()
        fade.values = [1.0, 1.0, 0.0]
        fade.keyTimes = [0, 0.55, 1]
        ps.propertyControllers = [.opacity: SCNParticlePropertyController(animation: fade)]
        let n = SCNNode()
        n.position = position
        n.addParticleSystem(ps)
        n.runAction(.sequence([.wait(duration: 3), .removeFromParentNode()]))
        return n
    }
}
