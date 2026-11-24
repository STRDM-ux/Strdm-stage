import Foundation
import SceneKit
import AppKit

/// Settings for the 3D title on the screens (saved with the show).
struct TitleSettings: Codable, Equatable {
    var text = "ARMANII"
    var subtitle = ""
    /// Show the running song's name instead of the fixed text.
    var useSongName = false
    var material: TitleMaterial = .chrome
    var motion: TitleAnimation = .beatBounce
    /// Font family name ("" = heavy system font).
    var fontName = ""
    var depth: Double = 0.6
    var bevel: Double = 0.06
    /// AI / custom artwork behind the title (also used for chrome reflections).
    var backdropPath: String? = nil
    var backdropOpacity: Double = 0.85
    var showHalos = true
}

enum TitleMaterial: String, Codable, CaseIterable, Identifiable {
    case chrome, gold, neon, glass, fire, hologram, palette
    var id: String { rawValue }
    var label: String {
        switch self {
        case .chrome: return "Liquid chrome"
        case .gold: return "Gold"
        case .neon: return "Neon tube"
        case .glass: return "Glass"
        case .fire: return "Fire"
        case .hologram: return "Hologram"
        case .palette: return "Song colours (glow)"
        }
    }
}

enum TitleAnimation: String, Codable, CaseIterable, Identifiable {
    case float, beatBounce, wave, spinIn, explodeOnDrop, glitch, orbit
    var id: String { rawValue }
    var label: String {
        switch self {
        case .float: return "Float"
        case .beatBounce: return "Letters bounce on the beat"
        case .wave: return "Wave"
        case .spinIn: return "Fly in each section"
        case .explodeOnDrop: return "Explode on drops"
        case .glitch: return "Glitch"
        case .orbit: return "Orbit 360°"
        }
    }
}

/// Per-letter 3D title with PBR materials, reflections and beat-driven animation.
@MainActor
final class TitleRig {
    let root = SCNNode()
    private let holder = SCNNode()
    private var letters: [SCNNode] = []
    private var homes: [SCNVector3] = []
    private var scatter: [SCNVector3] = []
    private var subtitleNode: SCNNode?
    private let backdrop = SCNNode()
    private var halos: [SCNNode] = []
    private var builtKey = ""
    private var flyStart = Date.distantPast
    private var explodeStart = Date.distantPast
    private var lastDrop = false
    private var envKey = ""
    weak var scene: SCNScene?

    init() {
        root.addChildNode(backdrop)
        root.addChildNode(holder)
        for i in 0..<3 {
            let t = SCNTorus(ringRadius: CGFloat(5.5 + Double(i) * 1.1), pipeRadius: 0.035)
            let m = SCNMaterial(); m.lightingModel = .constant; m.diffuse.contents = NSColor.black
            t.firstMaterial = m
            let n = SCNNode(geometry: t)
            n.position = SCNVector3(0, 0, -2.5)
            root.addChildNode(n)
            halos.append(n)
        }
        // Key + rim lights so metals have something to reflect besides the environment.
        let key = SCNLight(); key.type = .spot; key.intensity = 1800; key.spotOuterAngle = 70
        let kn = SCNNode(); kn.light = key; kn.position = SCNVector3(-6, 7, 9); kn.look(at: SCNVector3(0, 0, 0))
        root.addChildNode(kn)
        let rim = SCNLight(); rim.type = .omni; rim.intensity = 900
        let rn = SCNNode(); rn.light = rim; rn.position = SCNVector3(6, -3, -3); rn.name = "rim"
        root.addChildNode(rn)
    }

    // MARK: Build

    func rebuildIfNeeded(_ s: TitleSettings, text: String) {
        let key = "\(text)|\(s.subtitle)|\(s.fontName)|\(s.depth)|\(s.bevel)|\(s.material.rawValue)|\(s.backdropPath ?? "")"
        guard key != builtKey else { return }
        builtKey = key
        holder.childNodes.forEach { $0.removeFromParentNode() }
        letters.removeAll(); homes.removeAll(); scatter.removeAll()
        subtitleNode = nil

        let font = Self.font(s.fontName, size: 2.4)
        var x: CGFloat = 0
        let chars = Array(text.uppercased())
        var nodes: [SCNNode] = []
        for ch in chars {
            if ch == " " { x += 0.9; continue }
            let t = SCNText(string: String(ch), extrusionDepth: CGFloat(s.depth))
            t.font = font
            t.flatness = 0.01
            t.chamferRadius = CGFloat(s.bevel)
            t.chamferProfile = Self.roundBevel
            t.materials = materials(s.material)
            let n = SCNNode(geometry: t)
            let (mn, mx) = n.boundingBox
            let w = mx.x - mn.x
            // pivot each letter around its own centre so it can spin in place
            n.pivot = SCNMatrix4MakeTranslation(mn.x + w / 2, (mx.y - mn.y) / 2 + mn.y, CGFloat(s.depth) / 2)
            n.position = SCNVector3(x + w / 2, 0, 0)
            x += w + 0.12
            nodes.append(n)
        }
        let total = max(1, x - 0.12)
        for n in nodes {
            n.position.x -= total / 2
            holder.addChildNode(n)
            letters.append(n)
            homes.append(n.position)
            scatter.append(SCNVector3(CGFloat.random(in: -14...14), CGFloat.random(in: -9...9), CGFloat.random(in: -25...6)))
        }
        if !s.subtitle.isEmpty {
            let t = SCNText(string: s.subtitle.uppercased(), extrusionDepth: 0.15)
            t.font = Self.font(s.fontName, size: 0.8)
            t.flatness = 0.02
            t.materials = materials(s.material == .neon || s.material == .hologram ? s.material : .palette)
            let n = SCNNode(geometry: t)
            let (mn, mx) = n.boundingBox
            n.pivot = SCNMatrix4MakeTranslation((mx.x - mn.x) / 2 + mn.x, (mx.y - mn.y) / 2 + mn.y, 0)
            n.position = SCNVector3(0, -2.3, 0.2)
            holder.addChildNode(n)
            subtitleNode = n
        }
        let fit = CGFloat(min(1.0, 14 / Double(total)))
        holder.scale = SCNVector3(fit, fit, fit)

        // Backdrop artwork
        backdrop.geometry = nil
        if let path = s.backdropPath, let img = NSImage(contentsOfFile: path) {
            let aspect = img.size.width / max(1, img.size.height)
            let h: CGFloat = 22
            let plane = SCNPlane(width: h * aspect, height: h)
            let m = SCNMaterial(); m.lightingModel = .constant
            m.diffuse.contents = img
            m.writesToDepthBuffer = false
            plane.firstMaterial = m
            backdrop.geometry = plane
            backdrop.position = SCNVector3(0, 0, -16)
        }
        envKey = ""
    }

    private static let roundBevel: NSBezierPath = {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 0, y: 1))
        p.curve(to: NSPoint(x: 1, y: 0), controlPoint1: NSPoint(x: 0.55, y: 1), controlPoint2: NSPoint(x: 1, y: 0.55))
        return p
    }()

    static func font(_ family: String, size: CGFloat) -> NSFont {
        if !family.isEmpty, let f = NSFontManager.shared.font(withFamily: family, traits: [.boldFontMask], weight: 11, size: size)
            ?? NSFont(name: family, size: size) {
            return f
        }
        return NSFont.systemFont(ofSize: size, weight: .black)
    }

    private func materials(_ kind: TitleMaterial) -> [SCNMaterial] {
        func pbr(_ color: NSColor, metal: Double, rough: Double) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = color
            m.metalness.contents = metal
            m.roughness.contents = rough
            return m
        }
        switch kind {
        case .chrome:
            let m = pbr(NSColor(white: 0.95, alpha: 1), metal: 1, rough: 0.06)
            return [m, m, m]
        case .gold:
            let m = pbr(NSColor(calibratedRed: 1, green: 0.78, blue: 0.34, alpha: 1), metal: 1, rough: 0.18)
            return [m, m, m]
        case .neon:
            let face = SCNMaterial(); face.lightingModel = .constant; face.diffuse.contents = NSColor.black
            face.emission.contents = NSColor.white
            let side = pbr(NSColor(white: 0.08, alpha: 1), metal: 0.3, rough: 0.5)
            return [face, side, face]
        case .glass:
            let m = pbr(NSColor(white: 1, alpha: 1), metal: 0, rough: 0.02)
            m.transparency = 0.35
            m.transparencyMode = .dualLayer
            m.fresnelExponent = 2.2
            m.isDoubleSided = true
            return [m, m, m]
        case .fire:
            let m = SCNMaterial(); m.lightingModel = .constant; m.diffuse.contents = NSColor.black
            m.emission.contents = Self.fireTexture
            m.emission.wrapT = .repeat; m.emission.wrapS = .repeat
            return [m, m, m]
        case .hologram:
            let m = SCNMaterial(); m.lightingModel = .constant; m.diffuse.contents = NSColor.black
            m.emission.contents = Self.scanlines
            m.emission.wrapT = .repeat
            m.transparency = 0.8
            m.blendMode = .add
            return [m, m, m]
        case .palette:
            let face = pbr(.white, metal: 0.85, rough: 0.2)
            let side = SCNMaterial(); side.lightingModel = .constant; side.diffuse.contents = NSColor.black
            side.emission.contents = NSColor.white
            return [face, side, side]
        }
    }

    private static let fireTexture: NSImage = {
        let img = NSImage(size: NSSize(width: 4, height: 256))
        img.lockFocus()
        NSGradient(colors: [.white, .yellow, .orange, .red, NSColor(calibratedRed: 0.4, green: 0, blue: 0, alpha: 1), .orange, .yellow, .white])?
            .draw(in: NSRect(x: 0, y: 0, width: 4, height: 256), angle: 90)
        img.unlockFocus()
        return img
    }()

    private static let scanlines: NSImage = {
        let img = NSImage(size: NSSize(width: 4, height: 64))
        img.lockFocus()
        for y in stride(from: 0, to: 64, by: 4) {
            NSColor(calibratedRed: 0.3, green: 1, blue: 1, alpha: 1).setFill()
            NSRect(x: 0, y: y, width: 4, height: 2).fill()
            NSColor(calibratedRed: 0.1, green: 0.4, blue: 0.8, alpha: 0.4).setFill()
            NSRect(x: 0, y: y + 2, width: 4, height: 2).fill()
        }
        img.unlockFocus()
        return img
    }()

    /// Reflection environment: the AI backdrop when there is one, else a studio gradient in the song colours.
    private func updateEnvironment(_ s: TitleSettings, _ a: RGB, _ b: RGB) {
        guard let scene else { return }
        let key = s.backdropPath ?? String(format: "%.1f%.1f%.1f-%.1f%.1f%.1f", a.r, a.g, a.b, b.r, b.g, b.b)
        guard key != envKey else { return }
        envKey = key
        if let path = s.backdropPath, let img = NSImage(contentsOfFile: path) {
            scene.lightingEnvironment.contents = img
        } else {
            let img = NSImage(size: NSSize(width: 512, height: 256))
            img.lockFocus()
            NSGradient(colors: [NSColor(calibratedRed: a.r, green: a.g, blue: a.b, alpha: 1), .black, .white, .black,
                                NSColor(calibratedRed: b.r, green: b.g, blue: b.b, alpha: 1)])?
                .draw(in: NSRect(x: 0, y: 0, width: 512, height: 256), angle: 90)
            NSColor.white.setFill()
            NSRect(x: 60, y: 170, width: 120, height: 14).fill()     // softbox highlights
            NSRect(x: 320, y: 150, width: 140, height: 10).fill()
            img.unlockFocus()
            scene.lightingEnvironment.contents = img
        }
        scene.lightingEnvironment.intensity = 1.6
    }

    // MARK: Animate

    func sectionChanged() { flyStart = Date() }

    func update(_ s: TitleSettings, t: Double, beat: Double, pulse: Double, drop: Bool,
                a: RGB, b: RGB, k: Double, color: (RGB, Double) -> NSColor) {
        updateEnvironment(s, a, b)
        if drop && !lastDrop { explodeStart = Date() }
        lastDrop = drop

        // Material colours that follow the song
        for (i, n) in letters.enumerated() {
            guard let mats = n.geometry?.materials, !mats.isEmpty else { continue }
            let c = i % 2 == 0 ? a : b
            switch s.material {
            case .neon:
                let flicker = s.motion == .glitch && PatternEngine.hash(i, Int(beat * 4)) < 0.08 ? 0.15 : 1.0
                mats[0].emission.contents = color(c, (1.2 + 0.9 * pulse) * k * flicker)
            case .palette:
                if mats.count > 1 { mats[1].emission.contents = color(c, k * (0.6 + 0.8 * pulse)) }
                mats[0].emission.contents = color(b, 0.2 * pulse)
            case .fire:
                mats[0].emission.contentsTransform = SCNMatrix4MakeTranslation(0, CGFloat(-t * 0.6 + Double(i) * 0.1), 0)
                mats[0].emission.intensity = CGFloat(0.9 + 0.6 * pulse)
            case .hologram:
                mats[0].emission.contentsTransform = SCNMatrix4MakeTranslation(0, CGFloat(t * 0.8), 0)
                mats[0].emission.intensity = CGFloat(0.8 + 0.5 * pulse)
            case .chrome, .gold, .glass:
                mats[0].emission.contents = color(c, 0.12 * pulse)
            }
        }

        let flyT = min(1, Date().timeIntervalSince(flyStart) / 1.6)
        let explodeT = Date().timeIntervalSince(explodeStart)
        let n = max(1, letters.count)
        for (i, node) in letters.enumerated() {
            guard i < homes.count else { break }
            var p = homes[i]
            var rx = 0.0, ry = 0.0, rz = 0.0
            let fi = Double(i) / Double(n)
            switch s.motion {
            case .float:
                p.y += CGFloat(0.12 * sin(t * 1.4 + Double(i) * 0.5))
                ry = 0.15 * sin(t * 0.7 + Double(i) * 0.3)
            case .beatBounce:
                let ph = (beat - fi * 0.5).truncatingRemainder(dividingBy: 1)
                let hop = ph >= 0 ? pow(max(0, 1 - ph * 2.2), 2) : 0
                p.y += CGFloat(0.55 * hop)
                rz = 0.12 * hop * (i % 2 == 0 ? 1 : -1)
            case .wave:
                p.y += CGFloat(0.45 * sin(t * 3 + Double(i) * 0.7))
                rx = 0.35 * cos(t * 3 + Double(i) * 0.7)
            case .spinIn:
                let local = max(0, min(1, flyT * 1.6 - fi * 0.6))
                let e = 1 - pow(1 - local, 3)
                let from = scatter[i]
                p = SCNVector3(from.x + (p.x - from.x) * CGFloat(e), from.y + (p.y - from.y) * CGFloat(e), from.z + (p.z - from.z) * CGFloat(e))
                ry = (1 - e) * 6
            case .explodeOnDrop:
                if explodeT < 2.2 {
                    let out = explodeT < 0.35 ? explodeT / 0.35 : max(0, 1 - (explodeT - 0.35) / 1.85)
                    let e = out * out
                    let d = scatter[i]
                    p = SCNVector3(p.x + d.x * CGFloat(e) * 0.6, p.y + d.y * CGFloat(e) * 0.6, p.z + d.z * CGFloat(e) * 0.3)
                    rx = 4 * e; ry = 3 * e
                } else {
                    p.y += CGFloat(0.08 * sin(t * 1.3 + Double(i)))
                }
            case .glitch:
                let k2 = Int(beat * 4)
                if PatternEngine.hash(i, k2) < 0.12 {
                    p.x += CGFloat((PatternEngine.hash(i + 3, k2) - 0.5) * 0.8)
                    p.y += CGFloat((PatternEngine.hash(i + 9, k2) - 0.5) * 0.4)
                }
            case .orbit:
                ry = 0
            }
            node.position = p
            node.eulerAngles = SCNVector3(CGFloat(rx), CGFloat(ry), CGFloat(rz))
        }

        // Whole title motion
        switch s.motion {
        case .orbit:
            holder.eulerAngles = SCNVector3(CGFloat(sin(t * 0.3) * 0.15), CGFloat(t * 0.6), 0)
        default:
            holder.eulerAngles = SCNVector3(CGFloat(sin(t * 0.4) * 0.1), CGFloat(sin(t * 0.5) * 0.35), 0)
        }
        let punch = 1 + 0.05 * pulse + (drop ? 0.04 * pulse : 0)
        root.scale = SCNVector3(punch, punch, punch)
        subtitleNode?.position.y = CGFloat(-2.3 + 0.06 * sin(t * 2))

        // Halos and rim light in the song colours
        for (i, h) in halos.enumerated() {
            h.isHidden = !s.showHalos
            h.eulerAngles = SCNVector3(CGFloat(t * (0.3 + Double(i) * 0.2)), CGFloat(t * 0.25 * Double(i + 1)), 0)
            h.geometry?.firstMaterial?.emission.contents = color(i % 2 == 0 ? a : b, k * (0.3 + 0.8 * pulse))
        }
        root.childNode(withName: "rim", recursively: false)?.light?.color = color(b, 1)
        backdrop.opacity = CGFloat(s.backdropOpacity * (0.85 + 0.15 * pulse))
    }
}
