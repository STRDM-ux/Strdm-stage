import SceneKit
import AppKit

/// Particle previews of special effects in the 3D venue: flames, CO₂, cold sparks, confetti and fireworks.
@MainActor
final class Stage3DEffects {
    let root = SCNNode()
    private struct Unit {
        let node: SCNNode
        let system: SCNParticleSystem?
        let glow: SCNNode?
        var wasFiring = false
    }
    private var units: [UUID: Unit] = [:]
    private var signature = ""

    private static let dot: NSImage = {
        let size = 64
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        let g = NSGradient(colors: [NSColor.white, NSColor.white.withAlphaComponent(0.6), NSColor.white.withAlphaComponent(0)])
        g?.draw(in: NSRect(x: 0, y: 0, width: size, height: size), relativeCenterPosition: .zero)
        img.unlockFocus()
        return img
    }()

    private static let square: NSImage = {
        let img = NSImage(size: NSSize(width: 16, height: 10))
        img.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 16, height: 10).fill()
        img.unlockFocus()
        return img
    }()

    func update(devices: [SFXDevice], sfx: SFXEngine, stageWidth w: Double, stageDepth d: Double, deck: Double) {
        let sig = devices.map { "\($0.id)\($0.kind.rawValue)\($0.stageX ?? -1)\($0.stageY ?? -1)" }.joined() + "\(w)\(d)"
        if sig != signature { rebuild(devices: devices, sfx: sfx, w: w, d: d, deck: deck); signature = sig }
        let now = Date()
        for dev in devices {
            guard var u = units[dev.id] else { continue }
            let firing = sfx.isVisuallyFiring(dev, now: now)
            if dev.kind.isOneShot {
                if firing && !u.wasFiring { u.node.addParticleSystem(Self.burst(dev.kind)) }
            } else {
                u.system?.birthRate = firing ? Self.rate(dev.kind) : 0
            }
            u.glow?.light?.intensity = firing ? (dev.kind == .flame ? 2500 : 900) : 0
            u.wasFiring = firing
            units[dev.id] = u
        }
    }

    private func rebuild(devices: [SFXDevice], sfx: SFXEngine, w: Double, d: Double, deck: Double) {
        root.childNodes.forEach { $0.removeFromParentNode() }
        units.removeAll()
        let ordered = sfx.order(devices)
        for (i, dev) in ordered.enumerated() {
            let sameKind = ordered.filter { $0.kind == dev.kind }
            let k = sameKind.firstIndex(of: dev) ?? i
            let x = dev.stageX ?? w * (Double(k) + 1) / (Double(sameKind.count) + 1)
            let y = dev.stageY ?? (dev.kind == .fireworks ? d : 0.5)
            let node = SCNNode()
            let height = dev.kind == .fireworks ? deck + 16 : deck
            node.position = SCNVector3(CGFloat(x - w / 2), CGFloat(height), CGFloat(-y))
            // The unit itself
            if dev.kind != .fireworks {
                let box = SCNBox(width: 0.35, height: 0.3, length: 0.35, chamferRadius: 0.03)
                box.firstMaterial?.diffuse.contents = NSColor(white: 0.12, alpha: 1)
                let b = SCNNode(geometry: box)
                b.position = SCNVector3(0, 0.15, 0)
                let base = SCNNode(); base.position = SCNVector3(CGFloat(x - w / 2), CGFloat(deck), CGFloat(-y))
                base.addChildNode(b)
                root.addChildNode(base)
            }
            var system: SCNParticleSystem?
            if !dev.kind.isOneShot {
                let s = Self.stream(dev.kind)
                s.birthRate = 0
                node.addParticleSystem(s)
                system = s
            }
            var glow: SCNNode?
            if dev.kind == .flame || dev.kind == .coldSpark || dev.kind == .fireworks {
                let l = SCNLight()
                l.type = .omni
                l.color = dev.kind == .flame ? NSColor.orange : NSColor(calibratedRed: 1, green: 0.9, blue: 0.6, alpha: 1)
                l.intensity = 0
                l.attenuationEndDistance = 12
                let ln = SCNNode(); ln.light = l
                ln.position = SCNVector3(0, dev.kind == .fireworks ? 0 : 2, 0)
                node.addChildNode(ln)
                glow = ln
            }
            root.addChildNode(node)
            units[dev.id] = Unit(node: node, system: system, glow: glow)
        }
    }

    private static func rate(_ k: SFXKind) -> CGFloat {
        switch k {
        case .flame: return 500
        case .co2: return 350
        case .coldSpark: return 900
        default: return 0
        }
    }

    /// Continuous effects (flame, CO₂, sparks).
    private static func stream(_ k: SFXKind) -> SCNParticleSystem {
        let s = SCNParticleSystem()
        s.particleImage = dot
        s.emitterShape = SCNSphere(radius: 0.08)
        s.emittingDirection = SCNVector3(0, 1, 0)
        s.loops = true
        s.isAffectedByGravity = false
        switch k {
        case .flame:
            s.particleColor = NSColor(calibratedRed: 1, green: 0.55, blue: 0.1, alpha: 1)
            s.particleColorVariation = SCNVector4(0.04, 0.2, 0.2, 0)
            s.particleLifeSpan = 0.55
            s.particleLifeSpanVariation = 0.2
            s.particleVelocity = 9
            s.particleVelocityVariation = 2
            s.spreadingAngle = 7
            s.particleSize = 0.55
            s.particleSizeVariation = 0.2
            s.blendMode = .additive
            s.acceleration = SCNVector3(0, 3, 0)
            let fade = CAKeyframeAnimation()
            fade.values = [1.0, 0.9, 0.0]
            s.propertyControllers = [.opacity: SCNParticlePropertyController(animation: fade),
                                     .size: SCNParticlePropertyController(animation: { let a = CAKeyframeAnimation(); a.values = [0.6, 1.4, 0.4]; return a }())]
        case .co2:
            s.particleColor = NSColor(white: 0.9, alpha: 0.12)
            s.particleLifeSpan = 1.4
            s.particleLifeSpanVariation = 0.4
            s.particleVelocity = 11
            s.particleVelocityVariation = 3
            s.spreadingAngle = 9
            s.particleSize = 0.45
            s.blendMode = .alpha
            s.dampingFactor = 1.6
            let a = CAKeyframeAnimation(); a.values = [0.3, 1.4, 2.2]
            let f = CAKeyframeAnimation(); f.values = [0.6, 0.3, 0.0]
            s.propertyControllers = [.size: SCNParticlePropertyController(animation: a), .opacity: SCNParticlePropertyController(animation: f)]
        default:   // cold spark
            s.particleColor = NSColor(calibratedRed: 1, green: 0.92, blue: 0.65, alpha: 1)
            s.particleLifeSpan = 1.4
            s.particleLifeSpanVariation = 0.5
            s.particleVelocity = 7
            s.particleVelocityVariation = 2.5
            s.spreadingAngle = 8
            s.particleSize = 0.05
            s.blendMode = .additive
            s.isAffectedByGravity = true
            s.acceleration = SCNVector3(0, -6, 0)
        }
        return s
    }

    /// One-shot effects (confetti, fireworks).
    private static func burst(_ k: SFXKind) -> SCNParticleSystem {
        let s = SCNParticleSystem()
        s.loops = false
        s.emissionDuration = 0.15
        s.emitterShape = SCNSphere(radius: 0.1)
        if k == .confetti {
            s.particleImage = square
            s.birthRate = 6000
            s.particleLifeSpan = 6
            s.particleLifeSpanVariation = 2
            s.emittingDirection = SCNVector3(0, 1, -0.6)
            s.spreadingAngle = 28
            s.particleVelocity = 16
            s.particleVelocityVariation = 5
            s.particleSize = 0.07
            s.particleColor = NSColor(calibratedHue: CGFloat.random(in: 0...1), saturation: 0.9, brightness: 1, alpha: 1)
            s.particleColorVariation = SCNVector4(1, 0.2, 0.1, 0)
            s.isAffectedByGravity = true
            s.acceleration = SCNVector3(0, 7.5, 0)     // flutter: partly cancels gravity
            s.dampingFactor = 1.4
            s.particleAngularVelocity = 400
            s.particleAngularVelocityVariation = 300
            s.blendMode = .alpha
        } else {
            s.particleImage = dot
            s.birthRate = 9000
            s.particleLifeSpan = 2.2
            s.particleLifeSpanVariation = 0.6
            s.emittingDirection = SCNVector3(0, 1, 0)
            s.spreadingAngle = 180
            s.particleVelocity = 9
            s.particleVelocityVariation = 1.5
            s.particleSize = 0.12
            s.particleColor = NSColor(calibratedHue: CGFloat.random(in: 0...1), saturation: 0.75, brightness: 1, alpha: 1)
            s.particleColorVariation = SCNVector4(0.08, 0.2, 0, 0)
            s.isAffectedByGravity = true
            s.acceleration = SCNVector3(0, 6, 0)
            s.dampingFactor = 0.9
            s.blendMode = .additive
            let f = CAKeyframeAnimation(); f.values = [1.0, 1.0, 0.0]
            s.propertyControllers = [.opacity: SCNParticlePropertyController(animation: f)]
        }
        return s
    }
}

/// Laser beams in the 3D venue, decoded from each laser's live DMX values.
@MainActor
final class Stage3DLasers {
    let root = SCNNode()
    private var units: [UUID: (node: SCNNode, beams: [SCNNode], material: SCNMaterial)] = [:]
    private var signature = ""
    private let maxBeams = 24

    func update(lighting: LightingEngine, stageWidth w: Double, deck: Double, t: Double) {
        let lasers = lighting.fixtures.filter { lighting.role($0) == .laser }
        let sig = lasers.map { f -> String in let p = lighting.position(f); return "\(f.id)\(p.x)\(p.y)\(p.z)" }.joined()
        if sig != signature {
            signature = sig
            root.childNodes.forEach { $0.removeFromParentNode() }
            units.removeAll()
            for f in lasers {
                let p = lighting.position(f)
                let node = SCNNode()
                node.position = SCNVector3(CGFloat(p.x - w / 2), CGFloat(deck + p.z), CGFloat(-p.y))
                let body = SCNBox(width: 0.35, height: 0.18, length: 0.3, chamferRadius: 0.02)
                body.firstMaterial?.diffuse.contents = NSColor(white: 0.1, alpha: 1)
                node.addChildNode(SCNNode(geometry: body))
                let m = SCNMaterial()
                m.lightingModel = .constant
                m.diffuse.contents = NSColor.black
                m.emission.contents = NSColor.green
                m.blendMode = .add
                m.writesToDepthBuffer = false
                m.isDoubleSided = true
                var beams: [SCNNode] = []
                for _ in 0..<maxBeams {
                    let cyl = SCNCylinder(radius: 0.012, height: 40)
                    cyl.firstMaterial = m
                    let holder = SCNNode()
                    let b = SCNNode(geometry: cyl)
                    b.position = SCNVector3(0, 20, 0)      // cylinder grows out from the aperture
                    holder.addChildNode(b)
                    holder.isHidden = true
                    node.addChildNode(holder)
                    beams.append(holder)
                }
                root.addChildNode(node)
                units[f.id] = (node, beams, m)
            }
        }
        for f in lasers {
            guard let u = units[f.id] else { continue }
            let s = lighting.laserState(f)
            u.material.emission.contents = NSColor(red: s.color.r, green: s.color.g, blue: s.color.b, alpha: 1)
            let count: Int
            let spread: Double
            switch s.look {
            case .beams: count = 7; spread = 0.5
            case .fan: count = 12; spread = 0.9
            case .tunnel: count = 18; spread = 0.25
            case .sheet: count = 24; spread = 1.0
            case .scan: count = 3; spread = 0.15
            case .chase: count = 5; spread = 0.35
            case .off: count = 0; spread = 0
            }
            let steer = (s.x - 64) / 64 * 0.6
            for (k, holder) in u.beams.enumerated() {
                guard s.on, k < count else { holder.isHidden = true; continue }
                holder.isHidden = false
                let f = count > 1 ? Double(k) / Double(count - 1) - 0.5 : 0
                if s.look == .tunnel {
                    // cone: beams around a circle, spinning
                    let a = Double(k) / Double(count) * 2 * .pi + t * (s.rotation - 128) / 30
                    holder.eulerAngles = SCNVector3(CGFloat(Double.pi / 2 - 0.12 - 0.2 * sin(a)), 0, CGFloat(0.25 * cos(a) - steer))
                } else {
                    let tilt = s.look == .sheet ? 0.18 : 0.08 + 0.05 * sin(t * 2 + Double(k))
                    // pointing out over the audience (+z), fanned left/right
                    holder.eulerAngles = SCNVector3(CGFloat(Double.pi / 2 - tilt), 0, CGFloat(-(f * spread * 2 + steer)))
                }
            }
        }
    }
}
