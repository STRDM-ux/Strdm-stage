import Foundation
import SceneKit
import AppKit
import SwiftUI

/// Generated 3D visuals for the LED wall / projectors, locked to the running song show
/// (palette, section, beat, drops) so screens and lights tell the same story.
enum VisualStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case tunnel, shapes, bars, particles, starfield, text, waves
    var id: String { rawValue }
    var label: String {
        switch self {
        case .tunnel: return "Neon Tunnel"
        case .shapes: return "Bouncing Shapes"
        case .bars: return "Equaliser Bars"
        case .particles: return "Particle Burst"
        case .starfield: return "Warp Starfield"
        case .text: return "3D Artist Name"
        case .waves: return "Slow Waves"
        }
    }
}

@MainActor
final class VisualEngine: ObservableObject {
    @Published private(set) var activeStyle: VisualStyle = .tunnel
    @Published var manualStyle: VisualStyle? = nil       // preview/override when no song show
    @Published var title = TitleSettings() { didSet { if title != oldValue { onTitleChange?(title) } } }
    var onTitleChange: ((TitleSettings) -> Void)?
    var titleText: String {
        get { title.text }
        set { title.text = newValue }
    }
    let titleRig = TitleRig()
    private var lastSection = -2
    private var lastStyle: VisualStyle = .tunnel

    let scene = SCNScene()
    private let lighting: LightingEngine
    private let audio: AudioEngine
    private var timer: Timer?
    private let camera = SCNNode()
    var cameraNode: SCNNode { camera }
    private var rigs: [VisualStyle: SCNNode] = [:]
    private var lastBeatInt = -1
    private var startTime = Date()
    private var flash = SCNNode()

    // Current colours (smoothed)
    private var colorA = RGB(r: 1, g: 0.1, b: 0.6)
    private var colorB = RGB(r: 0.45, g: 0, b: 1)
    private var accent = RGB.white

    init(lighting: LightingEngine, audio: AudioEngine) {
        self.lighting = lighting
        self.audio = audio
        buildScene()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let t = timer { RunLoop.main.add(t, forMode: .common) }
    }

    /// True while a song show is running (screens with Auto Visuals switch on).
    var isLive: Bool { lighting.songStatus != nil }

    // MARK: Scene

    private func buildScene() {
        scene.background.contents = NSColor.black
        let cam = SCNCamera()
        cam.fieldOfView = 70
        cam.zFar = 500
        cam.wantsHDR = true
        cam.bloomIntensity = 1.6
        cam.bloomThreshold = 0.4
        cam.bloomBlurRadius = 14
        cam.wantsExposureAdaptation = false
        cam.vignettingIntensity = 0.6
        cam.vignettingPower = 1
        camera.camera = cam
        camera.position = SCNVector3(0, 0, 10)
        scene.rootNode.addChildNode(camera)

        let ambient = SCNLight(); ambient.type = .ambient; ambient.intensity = 200
        let an = SCNNode(); an.light = ambient
        scene.rootNode.addChildNode(an)
        let key = SCNLight(); key.type = .omni; key.intensity = 1200
        let kn = SCNNode(); kn.light = key; kn.position = SCNVector3(4, 6, 10)
        scene.rootNode.addChildNode(kn)

        rigs[.tunnel] = buildTunnel()
        rigs[.shapes] = buildShapes()
        rigs[.bars] = buildBars()
        rigs[.particles] = buildParticles()
        rigs[.starfield] = buildStarfield()
        titleRig.scene = scene
        rigs[.text] = titleRig.root
        rigs[.waves] = buildWaves()
        for (_, n) in rigs { n.isHidden = true; scene.rootNode.addChildNode(n) }
        rigs[activeStyle]?.isHidden = false

        // Full-frame flash plane for strobe hits
        let plane = SCNPlane(width: 60, height: 40)
        let m = SCNMaterial(); m.lightingModel = .constant; m.diffuse.contents = NSColor.white
        m.transparency = 0; m.writesToDepthBuffer = false
        plane.firstMaterial = m
        flash = SCNNode(geometry: plane)
        flash.position = SCNVector3(0, 0, 4)
        flash.renderingOrder = 100
        scene.rootNode.addChildNode(flash)
    }

    private func glow(_ c: RGB, _ k: Double = 1) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor.black
        m.emission.contents = NSColor(red: c.r * k, green: c.g * k, blue: c.b * k, alpha: 1)
        return m
    }

    private func buildTunnel() -> SCNNode {
        let root = SCNNode()
        for i in 0..<36 {
            let ring = SCNTorus(ringRadius: 4, pipeRadius: 0.05)
            ring.firstMaterial = glow(.white)
            let n = SCNNode(geometry: ring)
            n.eulerAngles.x = .pi / 2
            n.position = SCNVector3(0, 0, CGFloat(-Double(i) * 3))
            n.name = "ring\(i)"
            root.addChildNode(n)
        }
        return root
    }

    private func buildShapes() -> SCNNode {
        let root = SCNNode()
        let geos: [SCNGeometry] = [SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0.08), SCNPyramid(width: 1.2, height: 1.2, length: 1.2),
                                   SCNTorus(ringRadius: 0.55, pipeRadius: 0.18), SCNSphere(radius: 0.6)]
        var i = 0
        for row in -2...2 {
            for col in -4...4 {
                let g = geos[(i + row + 10) % geos.count].copy() as! SCNGeometry
                let m = SCNMaterial()
                m.lightingModel = .physicallyBased
                m.diffuse.contents = NSColor.white
                m.metalness.contents = 0.9
                m.roughness.contents = 0.25
                m.emission.contents = NSColor.black
                g.firstMaterial = m
                let n = SCNNode(geometry: g)
                n.position = SCNVector3(CGFloat(col) * 2.1, CGFloat(row) * 2.1, 0)
                n.name = "s\(i)"
                root.addChildNode(n)
                i += 1
            }
        }
        return root
    }

    private func buildBars() -> SCNNode {
        let root = SCNNode()
        for i in 0..<32 {
            let b = SCNBox(width: 0.42, height: 1, length: 0.42, chamferRadius: 0.05)
            b.firstMaterial = glow(.white)
            let n = SCNNode(geometry: b)
            n.position = SCNVector3(CGFloat(Double(i) - 15.5) * 0.55, -3, 0)
            n.pivot = SCNMatrix4MakeTranslation(0, -0.5, 0)
            n.name = "b\(i)"
            root.addChildNode(n)
            // reflection
            let r = SCNNode(geometry: b.copy() as? SCNGeometry)
            r.geometry?.firstMaterial = glow(.white, 0.25)
            r.position = SCNVector3(n.position.x, -3, 0)
            r.pivot = SCNMatrix4MakeTranslation(0, 0.5, 0)
            r.name = "r\(i)"
            root.addChildNode(r)
        }
        return root
    }

    private func buildParticles() -> SCNNode {
        let root = SCNNode()
        let ps = SCNParticleSystem()
        ps.birthRate = 400
        ps.particleLifeSpan = 2.5
        ps.particleVelocity = 6
        ps.particleVelocityVariation = 4
        ps.emittingDirection = SCNVector3(0, 0, 1)
        ps.spreadingAngle = 180
        ps.particleSize = 0.08
        ps.particleColor = NSColor.white
        ps.blendMode = .additive
        ps.isAffectedByGravity = false
        ps.emitterShape = SCNSphere(radius: 0.5)
        ps.particleColorVariation = SCNVector4(0.1, 0.2, 0.2, 0)
        let emitter = SCNNode()
        emitter.name = "emitter"
        emitter.addParticleSystem(ps)
        root.addChildNode(emitter)
        let core = SCNSphere(radius: 1.2)
        core.firstMaterial = glow(.white)
        let c = SCNNode(geometry: core); c.name = "core"
        root.addChildNode(c)
        return root
    }

    private func buildStarfield() -> SCNNode {
        let root = SCNNode()
        let ps = SCNParticleSystem()
        ps.birthRate = 900
        ps.particleLifeSpan = 3
        ps.emitterShape = SCNPlane(width: 60, height: 40)
        ps.emittingDirection = SCNVector3(0, 0, 1)
        ps.spreadingAngle = 0
        ps.particleVelocity = 30
        ps.particleSize = 0.05
        ps.stretchFactor = 0.06
        ps.blendMode = .additive
        ps.particleColor = NSColor.white
        let emitter = SCNNode(); emitter.name = "stars"
        emitter.position = SCNVector3(0, 0, -80)
        emitter.addParticleSystem(ps)
        root.addChildNode(emitter)
        return root
    }

    private func buildWaves() -> SCNNode {
        let root = SCNNode()
        for row in 0..<14 {
            for col in 0..<24 {
                let s = SCNSphere(radius: 0.09)
                s.firstMaterial = glow(.white)
                let n = SCNNode(geometry: s)
                n.position = SCNVector3(CGFloat(Double(col) - 11.5) * 0.9, -2.5, CGFloat(-Double(row) * 1.2))
                n.name = "w\(row)_\(col)"
                root.addChildNode(n)
            }
        }
        return root
    }

    // MARK: Animation

    private func setStyle(_ s: VisualStyle) {
        guard s != activeStyle else { return }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.25
        rigs[activeStyle]?.isHidden = true
        rigs[s]?.isHidden = false
        SCNTransaction.commit()
        activeStyle = s
    }

    private func tick() {
        let t = Date().timeIntervalSince(startTime)

        // Where are we in the song?
        var bpm = 100.0, beat = t * bpm / 60, intensity = 0.8, strobe = false
        var style = manualStyle ?? activeStyle
        var drop = false
        var drumPulse: Double? = nil
        var hats = 0.0
        if let run = lighting.songRun, let status = lighting.songStatus {
            let show = run.show
            let a = show.analysis
            bpm = a.bpm
            beat = max(0, a.beatPosition(status.elapsed))
            if let kicks = a.kicks, kicks.count > 30 {
                drumPulse = max(SongAnalysis.hitPulse(kicks, at: status.elapsed, decay: 0.14),
                                0.7 * SongAnalysis.hitPulse(a.snares, at: status.elapsed, decay: 0.1))
                hats = SongAnalysis.curveValue(a.hatCurve, at: status.elapsed)
            }
            if run.sectionIndex >= 0 && run.sectionIndex < show.sections.count {
                let section = show.sections[run.sectionIndex]
                let look = section.look
                style = manualStyle ?? look.visual ?? VisualDefaults.style(for: section.label, vibe: show.vibe)
                intensity = look.intensity
                let startBeat = max(0, (section.start - a.beatOffset) * bpm / 60)
                strobe = look.strobeBeats > 0 && beat >= startBeat && beat - startBeat < look.strobeBeats
                drop = section.label.lowercased().hasPrefix("drop")
                ease(to: look.colorA, look.colorB, Palette.named(show.paletteName).accent)
            }
        } else if manualStyle == nil {
            // No song: follow the live wash colour gently.
            ease(to: RGB(r: 1, g: 0.08, b: 0.58), RGB(r: 0.45, g: 0, b: 1), .white)
        }
        setStyle(style)

        let phase = beat.truncatingRemainder(dividingBy: 1)
        // 1 on the real kick/snare when the analyser found drums, else on every beat
        let pulse = drumPulse.map { max($0, 0.35 * pow(1 - phase, 3)) } ?? pow(1 - phase, 3)
        _ = hats
        let bar = beat / 4
        let level = Double(audio.outputLevel)
        let A = colorA, B = colorB
        let k = 0.6 + 0.6 * intensity

        // Strobe flash plane
        let on = strobe && (beat * 4).truncatingRemainder(dividingBy: 1) < 0.5
        flash.geometry?.firstMaterial?.transparency = on ? 0.85 : 0

        // Camera: gentle drift, shake on drops
        let shake = drop ? 0.08 * pulse : 0
        camera.position = SCNVector3(CGFloat(sin(t * 0.3) * 0.6 + shake * sin(t * 90)), CGFloat(cos(t * 0.23) * 0.4 + shake * cos(t * 77)), 10)
        camera.look(at: SCNVector3(0, 0, -6))

        switch style {
        case .tunnel:
            guard let root = rigs[.tunnel] else { break }
            let speed = bpm / 60 * 3 * (drop ? 2 : 1)
            for (i, n) in root.childNodes.enumerated() {
                var z = Double(n.position.z) + speed / 60
                if z > 9 { z -= 36 * 3 }
                n.position.z = CGFloat(z)
                let c = i % 2 == 0 ? A : B
                let near = max(0, min(1, (z + 60) / 70))
                n.geometry?.firstMaterial?.emission.contents = nsColor(c, k * (0.3 + 0.9 * near) * (0.6 + 0.8 * pulse))
                let s = 1 + 0.15 * pulse
                n.scale = SCNVector3(s, s, s)
                n.eulerAngles.z = CGFloat(t * 0.4 + Double(i) * 0.12)
            }
            root.eulerAngles.z = CGFloat(sin(bar * .pi / 4) * 0.3)
        case .shapes:
            guard let root = rigs[.shapes] else { break }
            for (i, n) in root.childNodes.enumerated() {
                let wave = sin(beat * .pi / 2 + Double(i % 9) * 0.6)
                n.position.z = CGFloat(wave * 0.8 + pulse * 0.6)
                n.eulerAngles = SCNVector3(CGFloat(t * 0.7 + Double(i)), CGFloat(t * 0.5 + Double(i) * 0.3), 0)
                let c = (i + Int(beat)) % 2 == 0 ? A : B
                n.geometry?.firstMaterial?.emission.contents = nsColor(c, k * (0.15 + 0.9 * pulse))
                n.geometry?.firstMaterial?.diffuse.contents = nsColor(c, 0.6)
            }
            root.eulerAngles.y = CGFloat(sin(t * 0.2) * 0.35)
        case .bars:
            guard let root = rigs[.bars] else { break }
            for i in 0..<32 {
                let x = Double(i) / 31
                let h = 0.4 + 5 * max(0, level * 1.4) * (0.6 + 0.4 * sin(t * 6 + Double(i) * 0.7))
                    + 2.2 * pulse * exp(-pow((x - 0.5) * 3, 2)) + 0.8 * sin(beat * .pi + x * 6)
                let height = max(0.2, h * k)
                let c = A.mix(B, x)
                if let bNode = root.childNode(withName: "b\(i)", recursively: false) {
                    bNode.scale = SCNVector3(1, CGFloat(height), 1)
                    bNode.geometry?.firstMaterial?.emission.contents = nsColor(c, 1.2 * k)
                }
                if let r = root.childNode(withName: "r\(i)", recursively: false) {
                    r.scale = SCNVector3(1, CGFloat(height * 0.6), 1)
                }
            }
        case .particles:
            guard let root = rigs[.particles] else { break }
            if let ps = root.childNode(withName: "emitter", recursively: false)?.particleSystems?.first {
                ps.particleColor = nsColor(Int(beat) % 2 == 0 ? A : B, 1.4)
                ps.birthRate = CGFloat(150 + 1200 * pulse * intensity)
                ps.particleVelocity = CGFloat(4 + 10 * pulse)
            }
            if let core = root.childNode(withName: "core", recursively: false) {
                let s = 0.6 + 0.8 * pulse
                core.scale = SCNVector3(s, s, s)
                core.geometry?.firstMaterial?.emission.contents = nsColor(accent.mix(A, 0.5), 1.5 * k * pulse + 0.2)
            }
        case .starfield:
            guard let root = rigs[.starfield] else { break }
            if let ps = root.childNode(withName: "stars", recursively: false)?.particleSystems?.first {
                ps.particleVelocity = CGFloat(20 + 70 * pulse * intensity + (drop ? 40 : 0))
                ps.stretchFactor = CGFloat(0.03 + 0.12 * pulse)
                ps.particleColor = nsColor(A.mix(.white, 0.5), 1.3)
            }
            scene.background.contents = nsColor(B, 0.06 + 0.12 * pulse)
        case .text:
            var text = title.text
            if title.useSongName, let name = lighting.songRun?.show.name, !name.isEmpty {
                text = name.components(separatedBy: " - ").last ?? name
            }
            titleRig.rebuildIfNeeded(title, text: text.isEmpty ? " " : text)
            let section = lighting.songRun?.sectionIndex ?? -1
            if section != lastSection || lastStyle != .text { titleRig.sectionChanged() }
            lastSection = section
            titleRig.update(title, t: t, beat: beat, pulse: pulse, drop: drop, a: A, b: B, k: k) { c, kk in self.nsColor(c, kk) }
        case .waves:
            guard let root = rigs[.waves] else { break }
            for n in root.childNodes {
                guard let name = n.name else { continue }
                let parts = name.dropFirst().split(separator: "_")
                guard parts.count == 2, let row = Double(parts[0]), let col = Double(parts[1]) else { continue }
                let y = -2.5 + 0.9 * sin(col * 0.45 + t * 1.2) * cos(row * 0.35 + t * 0.8) + 0.5 * pulse
                n.position.y = CGFloat(y)
                n.geometry?.firstMaterial?.emission.contents = nsColor(A.mix(B, col / 23), k * (0.5 + 0.5 * (y + 3.5) / 2))
            }
        }
        if style != .starfield { scene.background.contents = nsColor(B, 0.02 + 0.05 * pulse * intensity) }
        lastStyle = style
        lastBeatInt = Int(beat)
    }

    private func ease(to a: RGB, _ b: RGB, _ c: RGB) {
        colorA = colorA.mix(a, 0.08)
        colorB = colorB.mix(b, 0.08)
        accent = accent.mix(c, 0.08)
    }

    private func nsColor(_ c: RGB, _ k: Double) -> NSColor {
        NSColor(red: min(1, c.r * k), green: min(1, c.g * k), blue: min(1, c.b * k), alpha: 1)
    }
}

/// Picks a screen visual for each section so visuals match the light look automatically.
enum VisualDefaults {
    static func style(for section: String, vibe: Vibe) -> VisualStyle {
        let s = section.lowercased()
        if s.hasPrefix("intro") { return vibe == .romantic || vibe == .chill ? .waves : .text }
        if s.hasPrefix("outro") { return .text }
        if s.hasPrefix("break") { return .waves }
        if s.hasPrefix("drop") { return vibe == .romantic || vibe == .chill ? .particles : .tunnel }
        if s.hasPrefix("chorus") || s.hasPrefix("hook") {
            switch vibe {
            case .hype, .dark: return .tunnel
            case .dancehall: return .shapes
            case .euphoric: return .starfield
            case .romantic, .chill: return .particles
            }
        }
        // verses
        switch vibe {
        case .hype, .dancehall: return .bars
        case .dark: return .particles
        case .euphoric: return .starfield
        case .romantic, .chill: return .waves
        }
    }
}

/// SwiftUI preview of the visuals (Light Set Builder / Screens page).
struct VisualPreview: NSViewRepresentable {
    @EnvironmentObject var visuals: VisualEngine
    func makeNSView(context: Context) -> SCNView {
        let v = SCNView(frame: .zero)
        v.scene = visuals.scene
        v.backgroundColor = .black
        v.antialiasingMode = .multisampling4X
        v.rendersContinuously = true
        v.preferredFramesPerSecond = 60
        return v
    }
    func updateNSView(_ nsView: SCNView, context: Context) {}
}
