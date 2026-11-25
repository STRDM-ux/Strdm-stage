import SwiftUI
import SceneKit
import AppKit
import Metal
import AVFoundation

enum CameraPreset: String, CaseIterable, Identifiable {
    case foh, crowd, frontRow, artist, drone, top, side
    var id: String { rawValue }
    var label: String {
        switch self {
        case .foh: return "FOH"
        case .crowd: return "Back of crowd"
        case .frontRow: return "Front row"
        case .drone: return "Drone orbit"
        case .artist: return "Artist view"
        case .top: return "Top down"
        case .side: return "Side stage"
        }
    }
    var symbol: String {
        switch self {
        case .foh: return "slider.horizontal.3"
        case .crowd: return "person.3.fill"
        case .frontRow: return "person.fill.viewfinder"
        case .drone: return "airplane"
        case .artist: return "music.mic"
        case .top: return "square.grid.3x3"
        case .side: return "arrow.left.and.right"
        }
    }
}

/// 3D venue: stage, rig, live beams, LED wall, performers, gear and crowd. Drag to orbit, scroll/pinch to zoom.
struct Stage3DView: NSViewRepresentable {
    enum Mode { case live, plot }
    let mode: Mode
    var camera: CameraPreset
    var showCrowd: Bool
    @EnvironmentObject var store: ShowStore
    @EnvironmentObject var lighting: LightingEngine
    @EnvironmentObject var screens: ScreenManager
    @EnvironmentObject var visuals: VisualEngine
    @EnvironmentObject var crowdCtl: CrowdController

    func makeCoordinator() -> Stage3DController { Stage3DController(mode: mode) }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.allowsCameraControl = true
        view.backgroundColor = mode == .live ? .black : NSColor(white: 0.07, alpha: 1)
        view.antialiasingMode = Viewer3DSettings.shared.quality.antialias
        view.preferredFramesPerSecond = 60
        context.coordinator.screens = screens
        context.coordinator.visuals = visuals
        context.coordinator.crowdCtl = crowdCtl
        view.delegate = context.coordinator.frames
        view.rendersContinuously = mode == .live && Viewer3DSettings.shared.quality == .ultra
        Viewer3DSettings.shared.activeController = context.coordinator
        context.coordinator.attach(view: view, store: store, lighting: lighting)
        context.coordinator.apply(camera: camera, animated: false)
        context.coordinator.showCrowd = showCrowd
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.apply(camera: camera, animated: true)
        context.coordinator.showCrowd = showCrowd
    }

    static func dismantleNSView(_ view: SCNView, coordinator: Stage3DController) {
        coordinator.stop()
    }
}

@MainActor
final class Stage3DController: NSObject {
    let mode: Stage3DView.Mode
    private weak var view: SCNView?
    private var store: ShowStore?
    private var lighting: LightingEngine?
    let scene = SCNScene()
    let effects3D = Stage3DEffects()
    let lasers3D = Stage3DLasers()
    private var timer: Timer?
    private var signature = ""
    private var tickCount = 0
    private var appliedCamera: CameraPreset?
    private var requestedCamera: CameraPreset = .foh
    private var cameras: [CameraPreset: SCNNode] = [:]
    weak var screens: ScreenManager?
    weak var visuals: VisualEngine?
    weak var crowdCtl: CrowdController?
    let frames = FrameCounter()
    private let settings = Viewer3DSettings.shared
    private var phoneMats: [SCNMaterial] = []
    private var droneAngle = 0.0
    private var lastDaylight: Bool?
    private var appliedQuality: Viewer3DSettings.Quality?
    private var lastVisualsGrab = 0.0
    private var scenicMats: ScenicMaterials?
    private var scenicLights: [SCNLight] = []
    private var scenicTop = 0.0          // tallest scenic piece (0 = no festival scenery)
    private var fogScale = 1.0
    private var lastFireworkBar = -1
    private var skyApplied: Bool?
    private var visualsRenderer: SCNRenderer?
    private var wallMediaIDs: [Int: ObjectIdentifier] = [:]
    private var visualsFrame: (tick: Int, image: NSImage)?

    var showCrowd = true {
        didSet { crowdRoot.isHidden = !showCrowd }
    }

    // Built geometry
    private let staticRoot = SCNNode()
    private let crowdRoot = SCNNode()
    private var crowdGroups: [SCNNode] = []
    private var fixtureRigs: [UUID: FixtureRig] = [:]
    private var performerNodes: [UUID: SCNNode] = [:]
    /// Every LED wall in the stage design, each fed by its own screen output.
    private var ledWalls: [(item: StageItem, mat: SCNMaterial)] = []
    private let strobeLight = SCNLight()
    private let houseLight = SCNLight()

    private struct FixtureRig {
        let pivot: SCNNode
        let light: SCNLight
        let cone: SCNCone
        let coneNode: SCNNode
        let beamMaterial: SCNMaterial
        let lens: SCNMaterial
        let isMover: Bool
        let isEffect: Bool
        let isHaze: Bool
        let lightNode: SCNNode
    }

    static let deckHeight = 1.2
    /// The show's stage height (Stage Design → Height).
    private var deckH: Double { store?.show.stagePlot.deck ?? Self.deckHeight }

    init(mode: Stage3DView.Mode) {
        self.mode = mode
        super.init()
    }

    func attach(view: SCNView, store: ShowStore, lighting: LightingEngine) {
        self.view = view
        self.store = store
        self.lighting = lighting
        view.scene = scene
        scene.rootNode.addChildNode(staticRoot)
        scene.rootNode.addChildNode(crowdRoot)
        scene.rootNode.addChildNode(effects3D.root)
        scene.rootNode.addChildNode(lasers3D.root)

        // Ambient + house light
        houseLight.type = .ambient
        houseLight.color = NSColor(white: 1, alpha: 1)
        houseLight.intensity = mode == .live ? 60 : 450
        let house = SCNNode(); house.light = houseLight
        scene.rootNode.addChildNode(house)
        if mode == .plot {
            let key = SCNLight(); key.type = .directional; key.intensity = 900; key.castsShadow = true
            key.shadowMode = .deferred; key.shadowColor = NSColor(white: 0, alpha: 0.5)
            let keyNode = SCNNode(); keyNode.light = key
            keyNode.eulerAngles = SCNVector3(-1.0, 0.5, 0)
            scene.rootNode.addChildNode(keyNode)
        }
        strobeLight.type = .omni
        strobeLight.intensity = 0
        strobeLight.color = NSColor.white
        let strobe = SCNNode(); strobe.light = strobeLight
        strobe.position = SCNVector3(0, 8, 2)
        scene.rootNode.addChildNode(strobe)

        rebuild()
        appliedQuality = settings.quality
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / (mode == .live ? settings.quality.tickRate : 20), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let t = timer { RunLoop.main.add(t, forMode: .common) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Cameras

    func apply(camera preset: CameraPreset, animated: Bool) {
        requestedCamera = preset
        guard preset != appliedCamera, let view, let node = cameras[preset] else { return }
        appliedCamera = preset
        if animated, let current = view.pointOfView {
            // Fly from where the user is to the preset.
            let target = node.clone()
            node.position = current.position
            node.orientation = current.orientation
            view.pointOfView = node
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.9
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            node.position = target.position
            node.orientation = target.orientation
            SCNTransaction.commit()
        } else {
            view.pointOfView = node
        }
    }

    private func buildCameras(width w: Double, depth d: Double) {
        cameras.values.forEach { $0.removeFromParentNode() }
        cameras.removeAll()
        func cam(_ preset: CameraPreset, _ pos: SCNVector3, lookAt: SCNVector3, fov: CGFloat = 55) {
            let c = SCNCamera()
            c.fieldOfView = fov
            c.zNear = 0.05
            c.zFar = 900
            c.wantsHDR = settings.quality != .fast
            c.bloomIntensity = mode == .live ? (settings.quality == .fast ? 0 : 1.4) : 0.2
            c.bloomThreshold = 0.55
            c.bloomBlurRadius = 10
            c.wantsExposureAdaptation = false
            c.exposureOffset = mode == .live ? 0.4 : 0
            let n = SCNNode()
            n.camera = c
            n.position = pos
            n.look(at: lookAt)
            scene.rootNode.addChildNode(n)
            cameras[preset] = n
        }
        // Tall festival scenery: stand further back and look higher so the whole set is in frame.
        let tall = max(0, scenicTop - 9)
        let stageCentre = SCNVector3(0, CGFloat(deckH + 1.2 + tall * 0.32), CGFloat(-d / 2))
        cam(.foh, SCNVector3(0, CGFloat(4.2 + tall * 0.12), CGFloat(14 + w * 0.3 + tall * 1.0)), lookAt: stageCentre, fov: tall > 0 ? 62 : 55)
        cam(.crowd, SCNVector3(-2, 2.4, CGFloat(26 + w * 0.3 + tall * 1.3)), lookAt: stageCentre, fov: tall > 0 ? 52 : 45)
        cam(.frontRow, SCNVector3(1, 1.7, 3.2), lookAt: SCNVector3(0, CGFloat(deckH + 2.2), CGFloat(-d / 2)), fov: 78)
        cam(.drone, SCNVector3(CGFloat(w * 0.8), CGFloat(14 + tall * 0.6), CGFloat(10 + w * 0.4 + tall)), lookAt: stageCentre, fov: 55)
        cam(.artist, SCNVector3(0, CGFloat(deckH + 1.75), CGFloat(-d * 0.35)),
            lookAt: SCNVector3(0, 1.8, 14), fov: 75)
        cam(.top, SCNVector3(0, CGFloat(max(w, d) * 1.6 + 6), CGFloat(-d / 2 + 0.01)),
            lookAt: SCNVector3(0, 0, CGFloat(-d / 2)), fov: 50)
        cam(.side, SCNVector3(CGFloat(w / 2 + 9 + tall * 0.8), CGFloat(5 + tall * 0.2), CGFloat(6 + tall * 0.9)), lookAt: stageCentre)
        appliedCamera = nil
    }

    // MARK: Build

    /// Coordinates: stage x (0…W from stage left) → scene x centred; stage y (0 front … D back) → scene −z; height → y.
    private func pt(_ x: Double, _ y: Double, _ h: Double, width w: Double) -> SCNVector3 {
        SCNVector3(CGFloat(x - w / 2), CGFloat(h), CGFloat(-y))
    }

    private func computeSignature() -> String {
        guard let store else { return "" }
        let s = store.show
        var parts = ["\(s.stagePlot.stageWidth)x\(s.stagePlot.stageDepth)x\(s.stagePlot.deck)"]
        parts += s.stagePlot.items.map { "\($0.id)\($0.kind.rawValue)\($0.x),\($0.y),\($0.width),\($0.depth),\($0.rotation),\($0.label),\($0.height ?? -1),\($0.elevation ?? 0)\($0.scenic ?? "")" }
        parts.append("\(s.stagePlot.venueModelPath ?? "")\(s.stagePlot.venueModelScale ?? 1)\(s.stagePlot.venueModelOffsetY ?? 0)")
        parts += s.lighting.fixtures.map { "\($0.id)\($0.profile.name)\($0.stageX ?? -99),\($0.stageY ?? -99),\($0.stageZ ?? -99)" }
        parts.append("\(settings.crowdSize.rawValue)\(settings.roof)\(settings.quality.rawValue)\(s.stagePlot.festivalTheme ?? "")")
        return parts.joined(separator: "|")
    }

    /// Writes the whole venue (stage, rig, crowd, sparks) as a 3D file — .usdz opens in Blender, Reality Composer and most CAD/previs tools.
    func export(to url: URL) -> Bool {
        scene.write(to: url, options: nil, delegate: nil, progressHandler: nil)
    }

    private func rebuild() {
        guard let store, let lighting else { return }
        signature = computeSignature()
        staticRoot.childNodes.forEach { $0.removeFromParentNode() }
        crowdRoot.childNodes.forEach { $0.removeFromParentNode() }
        crowdGroups.removeAll()
        fixtureRigs.removeAll()
        performerNodes.removeAll()
        ledWalls = []
        wallMediaIDs = [:]

        let w = store.show.stagePlot.stageWidth
        let d = store.show.stagePlot.stageDepth
        let deck = deckH
        let scenicItems = store.show.stagePlot.items.filter { $0.kind == .scenic }
        scenicTop = scenicItems.map(\.topHeight).max() ?? 0
        scenicMats = scenicItems.isEmpty ? nil : ScenicMaterials(theme: FestivalTheme.named(store.show.stagePlot.festivalTheme))
        scenicLights = []
        // Big stages are viewed from further away: push the haze back so the set doesn't vanish.
        fogScale = max(1, (w + max(0, scenicTop - 8) * 1.5) / 18)

        // Haze / atmosphere
        if mode == .live {
            scene.fogColor = NSColor(white: 0.02, alpha: 1)
            scene.fogStartDistance = CGFloat(10 * fogScale)
            scene.fogEndDistance = CGFloat(70 * fogScale)
        } else {
            scene.fogEndDistance = 0
        }

        // Venue / stage-set model from Blender (USDZ, USDC, OBJ, SCN, DAE)
        if let path = store.show.stagePlot.venueModelPath, let model = try? SCNScene(url: URL(fileURLWithPath: path), options: [.convertToYUp: true]) {
            let holder = SCNNode()
            for child in model.rootNode.childNodes { holder.addChildNode(child) }
            let s = CGFloat(store.show.stagePlot.venueModelScale ?? 1)
            holder.scale = SCNVector3(s, s, s)
            holder.position = SCNVector3(0, CGFloat(store.show.stagePlot.venueModelOffsetY ?? 0), 0)
            holder.name = "venueModel"
            staticRoot.addChildNode(holder)
        }

        // Venue floor
        let floor = SCNFloor()
        floor.reflectivity = mode == .live ? 0.08 : 0.02
        floor.firstMaterial?.diffuse.contents = NSColor(white: mode == .live ? 0.05 : 0.16, alpha: 1)
        staticRoot.addChildNode(SCNNode(geometry: floor))

        // Stage deck
        let deckBox = SCNBox(width: CGFloat(w), height: CGFloat(max(0.03, deck)), length: CGFloat(d), chamferRadius: 0.01)
        deckBox.firstMaterial = material(NSColor(white: 0.13, alpha: 1), roughness: 0.6)
        let deckNode = SCNNode(geometry: deckBox)
        deckNode.position = SCNVector3(0, CGFloat(max(0.03, deck) / 2), CGFloat(-d / 2))
        staticRoot.addChildNode(deckNode)
        // Front edge strip
        let edge = SCNBox(width: CGFloat(w), height: 0.03, length: 0.05, chamferRadius: 0)
        edge.firstMaterial = emissive(NSColor(red: 1, green: 0.1, blue: 0.6, alpha: 1), strength: 0.8)
        let edgeNode = SCNNode(geometry: edge)
        edgeNode.position = SCNVector3(0, CGFloat(deck), 0.02)
        staticRoot.addChildNode(edgeNode)

        // Barrier
        let barrier = SCNBox(width: CGFloat(w + 2), height: 1.1, length: 0.08, chamferRadius: 0)
        barrier.firstMaterial = material(NSColor(white: 0.35, alpha: 1), metalness: 0.8)
        let barrierNode = SCNNode(geometry: barrier)
        barrierNode.position = SCNVector3(0, 0.55, 1.5)
        staticRoot.addChildNode(barrierNode)

        // FOH desk riser
        let foh = SCNBox(width: 4, height: 1.3, length: 2.5, chamferRadius: 0.05)
        foh.firstMaterial = material(NSColor(white: 0.18, alpha: 1))
        let fohNode = SCNNode(geometry: foh)
        fohNode.position = SCNVector3(0, 0.65, CGFloat(13 + w * 0.3 - 3))
        staticRoot.addChildNode(fohNode)
        staticRoot.addChildNode(label("FOH", at: SCNVector3(0, 1.6, CGFloat(13 + w * 0.3 - 3)), size: 0.35, color: .gray))

        // Trusses (front, mid, back) + side towers — unless the stage design has its own rigging
        let trussHeight = deck + 6
        let customRig = store.show.stagePlot.items.contains { $0.kind == .truss || $0.kind == .trussTower }
        for (y, len) in (customRig ? [] : [(-0.8, w + 1), (d * 0.55, w), (d - 1.2, w)]) {
            let n = latticeTruss(length: len)
            n.position = pt(w / 2, y, trussHeight + 0.1, width: w)
            staticRoot.addChildNode(n)
        }
        for x in (customRig ? [] : [-0.3, w + 0.3]) {
            for y in [-0.8, d - 1.2] {
                let n = latticeTruss(length: trussHeight + 0.4, vertical: true)
                n.position = pt(x, y, (trussHeight + 0.4) / 2, width: w)
                staticRoot.addChildNode(n)
            }
        }

        // Open-air festival sets have no roof (the scenery is taller than it).
        if settings.roof && scenicItems.isEmpty { buildRoof(width: w, depth: d, height: trussHeight + 2.2) }

        // Architectural uplighting on the scenery, in the theme's colours
        if let mats = scenicMats, settings.quality.fixtureLights {
            for (i, x) in [-0.32, 0.0, 0.32].enumerated() {
                let l = SCNLight()
                l.type = .omni
                l.color = (i == 1 ? mats.theme.glowB : mats.theme.glowA).nsColor
                l.intensity = 2600
                l.attenuationStartDistance = CGFloat(scenicTop * 0.5)
                l.attenuationEndDistance = CGFloat(scenicTop * 2.2 + w * 0.5)
                l.categoryBitMask = 1
                let n = SCNNode(); n.light = l
                n.position = pt(w / 2 + x * (w + 8), d * 0.55, deck + 2.5, width: w)
                staticRoot.addChildNode(n)
                scenicLights.append(l)
            }
        }

        // Stage-plot gear at real heights
        for item in store.show.stagePlot.items where item.kind != .person && item.kind != .vocalMic {
            if let node = gearNode(item, deck: deck) {
                // Scenery outside the deck stands on the ground; on the deck it stands on the stage.
                let offDeck = item.x < 0 || item.x > w || item.y < 0 || item.y > d
                let base = item.kind.isFloorDeck || item.kind == .trussTower || item.kind == .lineArray || (item.kind == .scenic && offDeck)
                    ? 0 : deck + (item.elevation ?? 0)
                node.position = pt(item.x, item.y, base, width: w)
                node.eulerAngles.y = CGFloat(-item.rotation * .pi / 180)
                staticRoot.addChildNode(node)
                if mode == .plot && item.kind != .label && !item.kind.isRigging && item.kind != .scenic {
                    staticRoot.addChildNode(label(item.label, at: pt(item.x, item.y, base + gearHeight(item) + 0.35, width: w), size: 0.22, color: .white))
                }
            }
        }

        // Performers (mics become performers with a mic stand)
        for p in lighting.performers {
            let n = performerNode(p)
            performerNodes[p.id] = n
            staticRoot.addChildNode(n)
        }

        // Fixtures
        for f in lighting.fixtures where lighting.role(f) != .laser {
            let rig = makeRig(f)
            let pos = lighting.position(f)
            rig.pivot.position = pt(pos.x, pos.y, deck + pos.z, width: w)
            staticRoot.addChildNode(rig.pivot)
            fixtureRigs[f.id] = rig
        }

        if mode == .live || showCrowd { buildCrowd(width: w) }
        crowdRoot.isHidden = !showCrowd
        buildCameras(width: w, depth: d)
        apply(camera: requestedCamera, animated: false)
    }

    private func gearHeight(_ item: StageItem) -> Double {
        if let h = item.height { return h }
        switch item.kind {
        case .ledWall: return 4.5
        case .drums: return 1.3
        case .drumRiser, .riser: return 0.4
        case .bassAmp, .guitarAmp: return 1.1
        case .keys, .djBooth, .playback: return 1.0
        case .sideFill: return 1.6
        case .sub: return 0.6
        case .monitorWedge: return 0.35
        case .iem: return 1.0
        case .percussion: return 0.9
        case .horns: return 1.2
        case .diBox, .powerDrop: return 0.15
        case .label: return 0.2
        case .vocalMic, .person: return 1.8
        default: return item.kind.defaultHeight
        }
    }

    private func gearNode(_ item: StageItem, deck: Double) -> SCNNode? {
        let w = CGFloat(max(0.1, item.width)), l = CGFloat(max(0.1, item.depth))
        let h = CGFloat(gearHeight(item))
        let node = SCNNode()
        func box(_ bw: CGFloat, _ bh: CGFloat, _ bl: CGFloat, _ m: SCNMaterial, y: CGFloat? = nil, z: CGFloat = 0) {
            let b = SCNBox(width: bw, height: bh, length: bl, chamferRadius: min(0.03, bw / 10))
            b.firstMaterial = m
            let n = SCNNode(geometry: b)
            n.position = SCNVector3(0, y ?? bh / 2, z)
            node.addChildNode(n)
        }
        let black = material(NSColor(white: 0.08, alpha: 1), roughness: 0.7)
        let grey = material(NSColor(white: 0.3, alpha: 1), metalness: 0.5)
        switch item.kind {
        case .ledWall:
            let screen = emissive(NSColor(red: 0.6, green: 0, blue: 1, alpha: 1), strength: 1)
            ledWalls.append((item, screen))
            box(w, h, 0.15, screen, y: 0.4 + h / 2)
        case .drumRiser, .riser:
            box(w, h, l, material(NSColor(white: 0.15, alpha: 1)))
        case .drums:
            box(w * 0.9, 0.4, l * 0.9, material(NSColor(white: 0.12, alpha: 1)), y: 0.2)
            let kick = SCNCylinder(radius: 0.28, height: 0.45)
            kick.firstMaterial = material(NSColor(red: 0.6, green: 0.1, blue: 0.15, alpha: 1), roughness: 0.3)
            let k = SCNNode(geometry: kick); k.eulerAngles.x = .pi / 2; k.position = SCNVector3(0, 0.68, 0.1)
            node.addChildNode(k)
            for (dx, dz, r) in [(-0.45, -0.2, 0.25), (0.45, -0.2, 0.28), (-0.7, 0.2, 0.22)] as [(CGFloat, CGFloat, CGFloat)] {
                let cym = SCNCylinder(radius: r, height: 0.01)
                cym.firstMaterial = material(NSColor(red: 0.85, green: 0.7, blue: 0.3, alpha: 1), metalness: 1, roughness: 0.25)
                let c = SCNNode(geometry: cym); c.position = SCNVector3(dx, 1.35, dz)
                node.addChildNode(c)
            }
        case .bassAmp, .guitarAmp, .sideFill, .sub:
            box(w, h, l, black)
            let grille = SCNBox(width: w * 0.9, height: h * 0.8, length: 0.01, chamferRadius: 0)
            grille.firstMaterial = material(NSColor(white: 0.2, alpha: 1), roughness: 0.9)
            let g = SCNNode(geometry: grille); g.position = SCNVector3(0, h / 2, l / 2 + 0.005)
            node.addChildNode(g)
        case .monitorWedge:
            box(w, h, l, black)
            node.childNodes.first?.eulerAngles.x = -0.45
        case .keys, .playback, .djBooth:
            box(w, h - 0.08, l, material(NSColor(white: 0.1, alpha: 1)), y: (h - 0.08) / 2)
            let top = SCNBox(width: w * 0.95, height: 0.06, length: l * 0.7, chamferRadius: 0.01)
            top.firstMaterial = item.kind == .keys ? material(.white, roughness: 0.3)
                : emissive(NSColor(red: 0.2, green: 0.6, blue: 1, alpha: 1), strength: 0.6)
            let t = SCNNode(geometry: top); t.position = SCNVector3(0, h - 0.03, 0)
            node.addChildNode(t)
        case .iem:
            box(0.25, 0.25, 0.25, black, y: 0.9)
            box(0.03, 0.8, 0.03, grey, y: 0.4)
        case .percussion:
            for dx in [-0.3, 0.3] as [CGFloat] {
                let c = SCNCylinder(radius: 0.17, height: 0.85)
                c.firstMaterial = material(NSColor(red: 0.6, green: 0.4, blue: 0.2, alpha: 1))
                let n = SCNNode(geometry: c); n.position = SCNVector3(dx, 0.43, 0)
                node.addChildNode(n)
            }
        case .horns:
            for dx in [-0.6, 0, 0.6] as [CGFloat] {
                let stand = SCNCylinder(radius: 0.015, height: 1.2)
                stand.firstMaterial = grey
                let n = SCNNode(geometry: stand); n.position = SCNVector3(dx, 0.6, 0)
                node.addChildNode(n)
            }
        case .diBox:
            box(0.15, 0.08, 0.2, material(NSColor(red: 0.2, green: 0.3, blue: 0.7, alpha: 1)))
        case .powerDrop:
            box(0.3, 0.15, 0.3, material(NSColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1)))
        case .label:
            node.addChildNode(label(item.label, at: SCNVector3(0, 0.3, 0), size: 0.3, color: .white))
        case .truss:
            // box truss hanging at trim height, with a ladder of cross-braces
            let metal = material(NSColor(white: 0.6, alpha: 1), metalness: 0.9, roughness: 0.35)
            for (dy, dz) in [(0.0, -0.13), (0.0, 0.13), (0.26, -0.13), (0.26, 0.13)] as [(CGFloat, CGFloat)] {
                let chord = SCNCylinder(radius: 0.025, height: w)
                chord.firstMaterial = metal
                let c = SCNNode(geometry: chord); c.eulerAngles.z = .pi / 2
                c.position = SCNVector3(0, h + dy, dz)
                node.addChildNode(c)
            }
            var x = -w / 2
            while x <= w / 2 {
                let brace = SCNBox(width: 0.03, height: 0.28, length: 0.28, chamferRadius: 0)
                brace.firstMaterial = metal
                let b = SCNNode(geometry: brace); b.position = SCNVector3(x, h + 0.13, 0)
                node.addChildNode(b)
                x += 0.5
            }
        case .trussTower:
            let metal = material(NSColor(white: 0.55, alpha: 1), metalness: 0.9, roughness: 0.4)
            box(0.3, h + CGFloat(deck), 0.3, metal)
            box(0.8, 0.05, 0.8, metal)
        case .lineArray:
            let cab = material(NSColor(white: 0.06, alpha: 1), roughness: 0.6)
            for k in 0..<8 {
                let b = SCNBox(width: w, height: 0.22, length: 0.5, chamferRadius: 0.01)
                b.firstMaterial = cab
                let n = SCNNode(geometry: b)
                n.position = SCNVector3(0, h + CGFloat(deck) - CGFloat(k) * 0.23, 0)
                n.eulerAngles.x = CGFloat(k) * 0.04
                node.addChildNode(n)
            }
        case .catwalk, .bStage, .roundRiser:
            let top = CGFloat(item.kind.isFloorDeck ? deck : 0) + h
            let deckMat = material(NSColor(white: 0.14, alpha: 1), roughness: 0.6)
            if item.kind.isRound {
                let c = SCNCylinder(radius: w / 2, height: max(0.05, top))
                c.firstMaterial = deckMat
                let n = SCNNode(geometry: c); n.position = SCNVector3(0, max(0.05, top) / 2, 0)
                node.addChildNode(n)
                let ring = SCNTorus(ringRadius: w / 2, pipeRadius: 0.02)
                ring.firstMaterial = emissive(NSColor(red: 1, green: 0.1, blue: 0.6, alpha: 1), strength: 0.8)
                let r = SCNNode(geometry: ring); r.position = SCNVector3(0, top, 0)
                node.addChildNode(r)
            } else {
                box(w, max(0.05, top), l, deckMat)
            }
        case .stairs:
            let steps = max(2, Int((h / 0.18).rounded()))
            for k in 0..<steps {
                let sh = h * CGFloat(k + 1) / CGFloat(steps)
                let depth = l / CGFloat(steps)
                box(w, sh, depth, material(NSColor(white: 0.16, alpha: 1)), y: sh / 2, z: l / 2 - depth * (CGFloat(k) + 0.5))
            }
        case .ramp:
            let len = (l * l + h * h).squareRoot()
            let b = SCNBox(width: w, height: 0.05, length: len, chamferRadius: 0)
            b.firstMaterial = material(NSColor(white: 0.16, alpha: 1))
            let n = SCNNode(geometry: b)
            n.eulerAngles.x = atan2(h, l)
            n.position = SCNVector3(0, h / 2, 0)
            node.addChildNode(n)
        case .scenic:
            let mats = scenicMats ?? ScenicMaterials(theme: FestivalTheme.all[0])
            return ScenicFactory.node(item.scenicStyle, width: item.width, depth: item.depth, height: gearHeight(item),
                                      mats: mats, skyBeam: mode == .live && settings.quality != .fast)
        case .setPiece:
            box(w, h, l, material(NSColor(red: 0.2, green: 0.25, blue: 0.3, alpha: 1), metalness: 0.2, roughness: 0.5))
        case .scrim:
            let m = SCNMaterial()
            m.diffuse.contents = NSColor(white: 0.9, alpha: 1)
            m.transparency = 0.25
            m.isDoubleSided = true
            let p = SCNPlane(width: w, height: h)
            p.firstMaterial = m
            let n = SCNNode(geometry: p); n.position = SCNVector3(0, h / 2, 0)
            node.addChildNode(n)
        case .ledFloor:
            let screen = emissive(NSColor(red: 0.5, green: 0, blue: 1, alpha: 1), strength: 0.6)
            box(w, 0.03, l, screen, y: 0.015)
        case .person, .vocalMic:
            return nil
        }
        return node
    }

    private func performerNode(_ item: StageItem) -> SCNNode {
        let root = SCNNode()
        let skin = material(NSColor(red: 1, green: 0.1, blue: 0.55, alpha: 1), roughness: 0.5)
        let body = SCNCapsule(capRadius: 0.2, height: 1.35)
        body.firstMaterial = skin
        let b = SCNNode(geometry: body); b.position = SCNVector3(0, 0.68, 0)
        root.addChildNode(b)
        let head = SCNSphere(radius: 0.13)
        head.firstMaterial = skin
        let hNode = SCNNode(geometry: head); hNode.position = SCNVector3(0, 1.55, 0)
        root.addChildNode(hNode)
        if item.kind == .vocalMic {
            let stand = SCNCylinder(radius: 0.012, height: 1.5)
            stand.firstMaterial = material(NSColor(white: 0.25, alpha: 1), metalness: 0.8)
            let s = SCNNode(geometry: stand); s.position = SCNVector3(0, 0.75, 0.32)
            root.addChildNode(s)
        }
        root.addChildNode(label(item.label, at: SCNVector3(0, 2.05, 0), size: 0.2, color: .white))
        return root
    }

    private func makeRig(_ f: Fixture) -> FixtureRig {
        let role = lighting?.role(f) ?? .color
        let pivot = SCNNode()
        let isMover = role == .mover
        // Body
        let bodyGeo: SCNGeometry = isMover ? SCNBox(width: 0.35, height: 0.4, length: 0.35, chamferRadius: 0.05)
                                            : SCNCylinder(radius: 0.16, height: 0.3)
        bodyGeo.firstMaterial = material(NSColor(white: 0.12, alpha: 1), metalness: 0.6, roughness: 0.4)
        let body = SCNNode(geometry: bodyGeo)
        if !isMover { body.eulerAngles.x = .pi / 2 }
        pivot.addChildNode(body)
        // Lens (glows the fixture's colour)
        let lensGeo = SCNCylinder(radius: isMover ? 0.12 : 0.14, height: 0.02)
        let lens = emissive(.black, strength: 1)
        lensGeo.firstMaterial = lens
        let lensNode = SCNNode(geometry: lensGeo)
        lensNode.eulerAngles.x = .pi / 2
        lensNode.position = SCNVector3(0, 0, isMover ? -0.19 : -0.16)
        pivot.addChildNode(lensNode)
        // Light
        let light = SCNLight()
        light.type = .spot
        light.spotInnerAngle = isMover ? 6 : 14
        light.spotOuterAngle = isMover ? 14 : 34
        light.attenuationStartDistance = 2
        light.attenuationEndDistance = 30
        light.attenuationFalloffExponent = 1
        light.intensity = 0
        light.castsShadow = false
        light.categoryBitMask = 1          // lights the stage only — never the crowd (huge GPU saving)
        let lightNode = SCNNode(); lightNode.light = light
        lightNode.isHidden = !settings.quality.fixtureLights
        pivot.addChildNode(lightNode)
        // Volumetric beam
        let cone = SCNCone(topRadius: 1, bottomRadius: 0.08, height: 5)
        cone.radialSegmentCount = 32
        let beam = SCNMaterial()
        beam.lightingModel = .constant
        beam.diffuse.contents = NSColor.black
        beam.emission.contents = NSColor.white
        beam.blendMode = .add
        beam.isDoubleSided = true
        beam.writesToDepthBuffer = false
        beam.transparency = 0
        cone.firstMaterial = beam
        let coneNode = SCNNode(geometry: cone)
        coneNode.eulerAngles.x = -.pi / 2
        coneNode.castsShadow = false
        coneNode.isHidden = mode == .plot
        pivot.addChildNode(coneNode)
        return FixtureRig(pivot: pivot, light: light, cone: cone, coneNode: coneNode, beamMaterial: beam, lens: lens,
                          isMover: isMover, isEffect: role == .effect, isHaze: role == .haze, lightNode: lightNode)
    }

    private func buildCrowd(width w: Double) {
        // Deterministic pseudo-random so the crowd doesn't reshuffle on rebuild.
        var seed: UInt64 = 0x5EED_1234
        func rnd() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(1 << 31)
        }
        let groups = (0..<4).map { _ in SCNNode() }
        groups.forEach { crowdRoot.addChildNode($0) }
        crowdGroups = groups

        let tones: [NSColor] = [NSColor(white: 0.14, alpha: 1), NSColor(white: 0.2, alpha: 1),
                                NSColor(red: 0.2, green: 0.12, blue: 0.1, alpha: 1), NSColor(red: 0.1, green: 0.1, blue: 0.16, alpha: 1)]
        let mats = tones.map { c -> SCNMaterial in let m = SCNMaterial(); m.lightingModel = .lambert; m.diffuse.contents = c; return m }
        let bodies = mats.map { m -> SCNGeometry in let g = SCNCapsule(capRadius: 0.2, height: 1.3); g.firstMaterial = m; return g }
        let head = SCNSphere(radius: 0.12)
        let headMat = SCNMaterial(); headMat.lightingModel = .lambert
        headMat.diffuse.contents = NSColor(red: 0.3, green: 0.2, blue: 0.16, alpha: 1)
        head.firstMaterial = headMat
        let phones = (0..<groups.count).map { g -> SCNGeometry in
            let p = SCNBox(width: 0.08, height: 0.15, length: 0.012, chamferRadius: 0.006)
            let m = emissive(NSColor(white: 0.9, alpha: 1), strength: 1.6)
            m.name = "phone\(g)"
            p.firstMaterial = m
            return p
        }

        let phoneGroups = (0..<groups.count).map { _ in SCNNode() }
        let rows = settings.crowdSize.rows
        for r in 0..<rows {
            let spanX = w + settings.crowdSize.extraWidth + Double(max(0, r - 20)) * 0.6
            let z = 2.2 + Double(r) * 0.62
            let perRow = Int(spanX / 0.62)
            for c in 0..<perRow {
                guard rnd() < 0.88 else { continue }
                let x = -spanX / 2 + (Double(c) + rnd() * 0.6) * (spanX / Double(perRow))
                let height = 0.9 + rnd() * 0.18
                let person = SCNNode()
                let body = SCNNode(geometry: bodies[Int(rnd() * Double(bodies.count)) % bodies.count])
                body.position = SCNVector3(0, CGFloat(0.65 * height), 0)
                body.scale = SCNVector3(1, CGFloat(height), 1)
                person.addChildNode(body)
                let h = SCNNode(geometry: head)
                h.position = SCNVector3(0, CGFloat(1.43 * height + 0.05), 0)
                person.addChildNode(h)
                let g = (r + c) % groups.count
                let pz = z + (rnd() - 0.5) * 0.3
                if rnd() < 0.22 {   // phones up
                    let p = SCNNode(geometry: phones[g])
                    p.position = SCNVector3(CGFloat(x) + 0.18, CGFloat(1.75 * height), CGFloat(pz) - 0.15)
                    phoneGroups[g].addChildNode(p)
                }
                person.position = SCNVector3(CGFloat(x), 0, CGFloat(pz))
                groups[g].addChildNode(person)
            }
        }
        // Merge each group into one mesh so thousands of people stay smooth.
        phoneMats = []
        crowdGroups = groups.enumerated().map { g, node in
            let flat = node.flattenedClone()
            flat.categoryBitMask = 2
            node.removeFromParentNode()
            crowdRoot.addChildNode(flat)
            // Phones are their own mesh with a material we keep hold of, so their colour can be driven live.
            if !phoneGroups[g].childNodes.isEmpty, let m = phones[g].firstMaterial {
                let phoneFlat = phoneGroups[g].flattenedClone()
                phoneFlat.geometry?.materials = [m]
                phoneFlat.categoryBitMask = 2
                flat.addChildNode(phoneFlat)
                phoneMats.append(m)
            }
            return flat
        }
    }

    /// Box-section lattice truss (4 chords + zig-zag diagonals), along x — or y when vertical.
    private func latticeTruss(length: Double, vertical: Bool = false, size: CGFloat = 0.3) -> SCNNode {
        let metal = SCNMaterial()
        metal.lightingModel = .blinn
        metal.diffuse.contents = NSColor(white: 0.55, alpha: 1)
        metal.specular.contents = NSColor(white: 0.6, alpha: 1)
        let node = SCNNode()
        let L = CGFloat(length), half = size / 2
        for (a, b) in [(-half, -half), (-half, half), (half, -half), (half, half)] {
            let chord = SCNCylinder(radius: 0.024, height: L)
            chord.firstMaterial = metal
            let c = SCNNode(geometry: chord)
            c.eulerAngles.z = .pi / 2
            c.position = SCNVector3(0, a, b)
            node.addChildNode(c)
        }
        let step: CGFloat = 0.5
        let n = max(1, Int(L / step))
        let diag = (step * step + size * size).squareRoot()
        for k in 0..<n {
            let x = -L / 2 + (CGFloat(k) + 0.5) * step
            for (face, flip) in [(-half, 1.0), (half, -1.0), (CGFloat(0), 1.0), (CGFloat(0), -1.0)] as [(CGFloat, Double)] {
                let rod = SCNCylinder(radius: 0.012, height: diag)
                rod.firstMaterial = metal
                let r = SCNNode(geometry: rod)
                let angle = atan2(size, step) * CGFloat(k % 2 == 0 ? flip : -flip)
                if face == 0 {
                    // top / bottom faces
                    r.eulerAngles = SCNVector3(.pi / 2, 0, .pi / 2 - angle)
                    r.position = SCNVector3(x, flip > 0 ? half : -half, 0)
                } else {
                    r.eulerAngles.z = .pi / 2 - angle
                    r.position = SCNVector3(x, 0, face)
                }
                node.addChildNode(r)
            }
        }
        let flat = node.flattenedClone()
        if vertical { flat.eulerAngles.z = .pi / 2 }
        return flat
    }

    /// Ground-support roof: four lattice towers, a perimeter + cross grid, a dark roof skin and side wings.
    private func buildRoof(width w: Double, depth d: Double, height h: Double) {
        let over = 1.0
        let rw = w + over * 2, rd = d + over * 1.5
        let x0 = -over, x1 = w + over, yFront = -over * 0.8, yBack = d + over * 0.7
        let roof = SCNNode()
        for (x, y) in [(x0, yFront), (x1, yFront), (x0, yBack), (x1, yBack)] {
            let tower = latticeTruss(length: h, vertical: true, size: 0.52)
            tower.position = pt(x, y, h / 2, width: w)
            roof.addChildNode(tower)
            let base = SCNBox(width: 1.4, height: 0.08, length: 1.4, chamferRadius: 0)
            base.firstMaterial = material(NSColor(white: 0.3, alpha: 1), metalness: 0.7)
            let b = SCNNode(geometry: base); b.position = pt(x, y, 0.04, width: w)
            roof.addChildNode(b)
        }
        for y in stride(from: yFront, through: yBack + 0.01, by: (yBack - yFront) / 4) {
            let t = latticeTruss(length: rw, size: 0.52)
            t.position = pt(w / 2, y, h, width: w)
            roof.addChildNode(t)
        }
        for x in [x0, x1, w / 2] {
            let t = latticeTruss(length: rd, size: 0.52)
            t.eulerAngles.y = .pi / 2
            t.position = pt(x, (yFront + yBack) / 2, h, width: w)
            roof.addChildNode(t)
        }
        let skinMat = SCNMaterial()
        skinMat.lightingModel = .physicallyBased
        skinMat.diffuse.contents = NSColor(white: 0.1, alpha: 1)
        skinMat.roughness.contents = 0.9
        skinMat.isDoubleSided = true
        let skin = SCNNode(geometry: SCNPlane(width: CGFloat(rw + 0.6), height: CGFloat(rd + 0.6)))
        skin.geometry?.firstMaterial = skinMat
        skin.eulerAngles.x = -.pi / 2 + 0.04
        skin.position = pt(w / 2, (yFront + yBack) / 2, h + 0.55, width: w)
        roof.addChildNode(skin)
        // Mesh side wings (scrim) that frame the stage
        let wingMat = SCNMaterial()
        wingMat.lightingModel = .physicallyBased
        wingMat.diffuse.contents = NSColor(white: 0.18, alpha: 1)
        wingMat.transparency = 0.85
        wingMat.isDoubleSided = true
        for x in [x0 - 0.3, x1 + 0.3] {
            let wing = SCNNode(geometry: SCNPlane(width: CGFloat(rd * 0.85), height: CGFloat(h)))
            wing.geometry?.firstMaterial = wingMat
            wing.eulerAngles.y = .pi / 2
            wing.position = pt(x, (yFront + yBack) / 2 + rd * 0.07, h / 2, width: w)
            roof.addChildNode(wing)
        }
        roof.name = "roof"
        staticRoot.addChildNode(roof)
    }

    // MARK: Per-frame update

    private func tick() {
        guard let store, let lighting else { return }
        tickCount += 1
        if tickCount % 30 == 0 {
            let sig = computeSignature()
            if sig != signature { rebuild() }
        }
        if settings.quality != appliedQuality { applyQuality() }
        let w = store.show.stagePlot.stageWidth
        let d = store.show.stagePlot.stageDepth
        let deck = deckH
        if mode == .live {
            lasers3D.update(lighting: lighting, stageWidth: w, deck: deck, t: Double(tickCount) / 30)
        }
        if let sfx = lighting.sfx {
            effects3D.update(devices: store.show.effects.devices, sfx: sfx, stageWidth: w, stageDepth: d, deck: deck)
        }

        var washSum = RGB.black
        var washLevel = 0.0
        var washCount = 0.0
        var strobe = 0.0
        var haze = 0.0

        for f in lighting.fixtures {
            guard let rig = fixtureRigs[f.id] else { continue }
            let level = mode == .plot ? 0 : lighting.outputLevel(f)
            let rgb = LightingEngine.emittedRGB(f, lighting.live[f.id] ?? [])
            if rig.isEffect { strobe = max(strobe, level); continue }
            if rig.isHaze { haze = max(haze, level); continue }

            let target: SCNVector3
            if rig.isMover, let dir = moverDirection(f) {
                // True 3D aim from pan/tilt, so fans and air looks shoot over the crowd instead of hitting the floor.
                let p = rig.pivot.position
                var reach = 38.0
                if dir.y < -0.03 {
                    reach = Double(p.y - CGFloat(deck)) / Double(-dir.y)
                    let lx = Double(p.x + dir.x * CGFloat(reach)) + w / 2, ly = -Double(p.z + dir.z * CGFloat(reach))
                    if !(lx >= 0 && lx <= w && ly >= 0 && ly <= d) { reach = Double(p.y) / Double(-dir.y) }
                }
                reach = min(38, max(0.5, reach))
                target = SCNVector3(p.x + dir.x * CGFloat(reach), p.y + dir.y * CGFloat(reach), p.z + dir.z * CGFloat(reach))
            } else {
                let target2D = lighting.beamTarget(f)
                let onStage = target2D.x >= 0 && target2D.x <= w && target2D.y >= 0 && target2D.y <= d
                target = pt(Double(target2D.x), Double(target2D.y), onStage ? deck : 0, width: w)
            }
            rig.pivot.look(at: target)

            let p = rig.pivot.position
            let dx = Double(target.x - p.x), dy = Double(target.y - p.y), dz = Double(target.z - p.z)
            let dist = max(0.5, (dx * dx + dy * dy + dz * dz).squareRoot())
            let spread = tan((rig.isMover ? 7.0 : 17.0) * .pi / 180)
            rig.cone.height = CGFloat(dist)
            rig.cone.topRadius = CGFloat(dist * spread)
            rig.coneNode.position = SCNVector3(0, 0, CGFloat(-dist / 2))

            let color = NSColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
            rig.light.color = color
            rig.light.intensity = CGFloat(level * (rig.isMover ? 5200 : 3600))
            let lit = settings.quality.fixtureLights && level > 0.03
            if rig.lightNode.isHidden == lit { rig.lightNode.isHidden = !lit }
            rig.beamMaterial.emission.contents = color
            rig.beamMaterial.transparency = CGFloat(level * (rig.isMover ? 0.32 : 0.16) * (0.55 + settings.haze * 1.1) * (settings.daylight ? 0.35 : 1))
            rig.lens.emission.contents = NSColor(red: rgb.r * level, green: rgb.g * level, blue: rgb.b * level, alpha: 1)
            rig.coneNode.isHidden = level < 0.02 || mode == .plot

            if !rig.isMover {
                washSum = RGB(r: washSum.r + rgb.r * level, g: washSum.g + rgb.g * level, b: washSum.b + rgb.b * level)
                washLevel += level
                washCount += 1
            }
        }

        // Strobes flash the whole room
        strobeLight.intensity = CGFloat(strobe > 0.5 ? 9000 * strobe : 0)

        // Haze thickens the air so beams read
        if mode == .live {
            let air = min(1, haze + settings.haze * 0.6)
            scene.fogEndDistance = settings.daylight ? 0 : CGFloat((80 - air * 45) * fogScale)
            scene.fogColor = NSColor(white: 0.02 + air * 0.05, alpha: 1)
        }
        if settings.daylight != lastDaylight {
            lastDaylight = settings.daylight
            // Night: a starry sky with a glow on the horizon. Day: clear blue.
            if settings.daylight {
                scene.background.contents = NSColor(red: 0.55, green: 0.68, blue: 0.85, alpha: 1)
            } else if mode == .live {
                scene.background.contents = ScenicFactory.nightSky
            } else {
                scene.background.contents = NSColor(white: 0.07, alpha: 1)
            }
        }
        updateScenery(lighting: lighting, width: w, depth: d)

        // Crowd phones show what STRDM Live is putting on the audience's phones right now.
        if !phoneMats.isEmpty {
            let beat = lighting.songBeatNow ?? Date().timeIntervalSinceReferenceDate * 2
            for (g, m) in phoneMats.enumerated() {
                let c = settings.phoneLights ? (crowdCtl?.previewColor(beat: beat, seed: Double(g) / Double(phoneMats.count)) ?? RGB(r: 0.9, g: 0.9, b: 0.9)) : RGB(r: 0.03, g: 0.03, b: 0.04)
                m.emission.contents = NSColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
            }
        }

        // FPS readout + drone orbit
        if settings.activeController === self, tickCount % Int(mode == .live ? settings.quality.tickRate : 20) == 0 {
            settings.fps = frames.take()
        }
        if appliedCamera == .drone, let cam = cameras[.drone], view?.pointOfView === cam {
            droneAngle += 0.0025
            let r = 16 + w * 0.55 + scenicTop
            cam.position = SCNVector3(CGFloat(r * sin(droneAngle + 0.7)), CGFloat(12 + w * 0.15 + scenicTop * 0.5), CGFloat(-d / 2 + r * cos(droneAngle + 0.7)))
            cam.look(at: SCNVector3(0, CGFloat(deck + 1.5 + scenicTop * 0.3), CGFloat(-d / 2)))
        }

        // LED wall shows what the real screen shows: video, still, or the generated visuals.
        var beatPulse = 1.0
        if let b = lighting.songBeatNow {
            let phase = b.truncatingRemainder(dividingBy: 1)
            beatPulse = 0.65 + 0.35 * pow(1 - phase, 2)
        }
        for (i, wall) in ledWalls.enumerated() {
            let screenID = screens?.screenID(forWall: wall.item, index: i)
            if updateWallMedia(wall.mat, screenID: screenID, index: i) { continue }
            if washLevel > 0.01 {
                let k = beatPulse / max(washLevel, 0.0001)
                wall.mat.emission.contents = NSColor(red: min(1, washSum.r * k), green: min(1, washSum.g * k), blue: min(1, washSum.b * k), alpha: 1)
            } else {
                wall.mat.emission.contents = mode == .plot ? NSColor(red: 0.3, green: 0, blue: 0.5, alpha: 1) : NSColor(white: 0.03, alpha: 1)
            }
        }
        houseLight.intensity = settings.daylight ? 900 : (mode == .live ? CGFloat(40 + min(1, washLevel / max(1, washCount)) * 60) : 450)

        // Performers follow their live-map positions
        for p in lighting.performers {
            guard let n = performerNodes[p.id] else { continue }
            let pos = lighting.performerPosition(p)
            n.position = pt(Double(pos.x), Double(pos.y), deck, width: w)
        }

        // Crowd bounces on the beat when a song show is running
        if let s = lighting.songStatus, let beat = lighting.songBeatNow, !crowdGroups.isEmpty {
            let energy = s.section.lowercased().hasPrefix("drop") || s.section.lowercased().hasPrefix("chorus") ? 0.14 : 0.06
            for (i, g) in crowdGroups.enumerated() {
                let phase = (beat + Double(i) * 0.12).truncatingRemainder(dividingBy: 1)
                g.position = SCNVector3(0, CGFloat(energy * pow(sin(phase * .pi), 2)), 0)
            }
        } else {
            crowdGroups.forEach { $0.position = SCNVector3Zero }
        }
    }

    /// Festival scenery: LED tape and neon follow the song's palette and pulse on the beat; fireworks on the drops.
    private func updateScenery(lighting: LightingEngine, width w: Double, depth d: Double) {
        guard let mats = scenicMats else { return }
        var a = mats.theme.glowA, b = mats.theme.glowB
        var pulseA = 1.0, pulseB = 1.0
        if mode == .live {
            if let run = lighting.songRun {
                let pal = Palette.named(run.show.paletteName)
                a = pal.a; b = pal.b
            }
            if let beat = lighting.songBeatNow {
                let ph = beat.truncatingRemainder(dividingBy: 1)
                pulseA = 0.55 + 0.45 * pow(1 - ph, 2)
                let off = (beat + 0.5).truncatingRemainder(dividingBy: 1)
                pulseB = 0.5 + 0.5 * pow(1 - off, 2)
                // Fireworks over the set every 8 beats of a drop or chorus
                let section = lighting.songStatus?.section.lowercased() ?? ""
                let bar = Int(beat / 8)
                if bar != lastFireworkBar, settings.quality != .fast, !settings.daylight,
                   section.hasPrefix("drop") || section.hasPrefix("chorus") {
                    lastFireworkBar = bar
                    for k in 0..<3 {
                        let fx = (Double((bar * 37 + k * 53) % 100) / 100 - 0.5) * (w + 16)
                        let fy = scenicTop + 8 + Double((bar * 17 + k * 29) % 10)
                        scene.rootNode.addChildNode(ScenicFactory.firework(at: SCNVector3(CGFloat(fx), CGFloat(fy), CGFloat(-d - 6)),
                                                                           color: k == 1 ? b : (k == 2 ? .white : a)))
                    }
                }
            } else {
                let t = Date().timeIntervalSinceReferenceDate
                pulseA = 0.8 + 0.2 * sin(t * 1.3)
                pulseB = 0.8 + 0.2 * sin(t * 1.3 + 2)
            }
            if lighting.blackout { pulseA = 0.04; pulseB = 0.04 }
        }
        mats.glowA.emission.contents = a.scaled(pulseA).nsColor
        mats.glowB.emission.contents = b.scaled(pulseB).nsColor
        mats.beam.emission.contents = a.scaled(lighting.blackout ? 0 : 1).nsColor
        for (i, l) in scenicLights.enumerated() {
            l.color = (i == 1 ? b : a).nsColor
            l.intensity = CGFloat(2600 * (i == 1 ? pulseB : pulseA))
        }
    }

    /// Switch render quality live: anti-aliasing, frame rate, bloom and per-fixture lights.
    private func applyQuality() {
        let q = settings.quality
        appliedQuality = q
        guard let view else { return }
        view.antialiasingMode = q.antialias
        view.rendersContinuously = mode == .live && q == .ultra
        for c in cameras.values {
            c.camera?.wantsHDR = q != .fast
            c.camera?.bloomIntensity = mode == .live ? (q == .fast ? 0 : 1.4) : 0.2
        }
        if !q.fixtureLights { fixtureRigs.values.forEach { $0.lightNode.isHidden = true } }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / (mode == .live ? q.tickRate : 20), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let t = timer { RunLoop.main.add(t, forMode: .common) }
    }

    /// Unit beam direction (scene space) from a mover's live pan/tilt.
    private func moverDirection(_ f: Fixture) -> SCNVector3? {
        guard let lighting, let values = lighting.live[f.id] else { return nil }
        var pan = 0.5, tilt = 0.5, hasPan = false
        for (i, ch) in f.profile.channels.enumerated() where i < values.count {
            if ch.kind == .pan { pan = values[i] / 255; hasPan = true }
            if ch.kind == .panFine { pan += values[i] / 65535 }
            if ch.kind == .tilt { tilt = values[i] / 255 }
            if ch.kind == .tiltFine { tilt += values[i] / 65535 }
        }
        guard hasPan else { return nil }
        let (panDeg, tiltDeg) = lighting.angles(pan: pan, tilt: tilt)
        let a = panDeg * .pi / 180, t = tiltDeg * .pi / 180
        return SCNVector3(CGFloat(sin(t) * sin(a)), CGFloat(-cos(t)), CGFloat(sin(t) * cos(a)))
    }

    // MARK: LED wall media

    /// Returns true when real media (video / image / visuals) is on this wall.
    private func updateWallMedia(_ wall: SCNMaterial, screenID: UUID?, index: Int) -> Bool {
        guard let screens, let screenID else { return false }
        if let media = screens.currentMedia(for: screenID) {
            let id = ObjectIdentifier(media as AnyObject)
            if wallMediaIDs[index] != id {
                wallMediaIDs[index] = id
                wall.emission.contents = media      // SceneKit plays an AVPlayer as a live texture
                wall.emission.intensity = 1.4
            }
            return true
        }
        if screens.visualsShowing(on: screenID) {
            // Render the generated visuals once per frame pair and share it across every wall showing them.
            let now = CACurrentMediaTime()
            if let visuals, now - lastVisualsGrab > 1.0 / 12, visualsFrame?.tick != tickCount {
                lastVisualsGrab = now
                if visualsRenderer == nil {
                    visualsRenderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
                }
                if let r = visualsRenderer {
                    r.scene = visuals.scene
                    r.pointOfView = visuals.cameraNode
                    visualsFrame = (tickCount, r.snapshot(atTime: now, with: CGSize(width: 480, height: 270), antialiasingMode: .none))
                }
            }
            if let frame = visualsFrame {
                wall.emission.contents = frame.image
                wall.emission.intensity = 1.4
                wallMediaIDs[index] = nil
            }
            return true
        }
        if wallMediaIDs[index] != nil {
            wallMediaIDs[index] = nil
            wall.emission.intensity = 1
        }
        return false
    }

    // MARK: Materials & labels

    private func material(_ color: NSColor, metalness: Double = 0, roughness: Double = 0.5) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.metalness.contents = metalness
        m.roughness.contents = roughness
        return m
    }

    private func emissive(_ color: NSColor, strength: Double) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor.black
        m.emission.contents = color
        m.emission.intensity = CGFloat(strength)
        return m
    }

    private func label(_ text: String, at position: SCNVector3, size: CGFloat, color: NSColor) -> SCNNode {
        let t = SCNText(string: text, extrusionDepth: 0.01)
        t.font = NSFont.systemFont(ofSize: 1, weight: .bold)
        t.flatness = 0.05
        t.firstMaterial = emissive(color, strength: 1)
        let node = SCNNode(geometry: t)
        let (minB, maxB) = node.boundingBox
        node.pivot = SCNMatrix4MakeTranslation((maxB.x - minB.x) / 2 + minB.x, minB.y, 0)
        node.scale = SCNVector3(size, size, size)
        node.position = position
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .Y
        node.constraints = [billboard]
        return node
    }
}

extension LightingEngine {
    /// The colour a fixture emits, normalised (brightness is carried separately by outputLevel).
    nonisolated static func emittedRGB(_ f: Fixture, _ values: [Double]) -> RGB {
        var r = 0.0, g = 0.0, b = 0.0, hasColor = false
        for (i, ch) in f.profile.channels.enumerated() where i < values.count {
            let v = values[i] / 255
            switch ch.kind {
            case .red: r += v; hasColor = true
            case .green: g += v; hasColor = true
            case .blue: b += v; hasColor = true
            case .white: r += v * 0.8; g += v * 0.8; b += v * 0.8; hasColor = true
            case .amber: r += v; g += v * 0.55; hasColor = true
            case .uv: r += v * 0.35; b += v * 0.9; hasColor = true
            default: break
            }
        }
        if !hasColor { return RGB(r: 1, g: 0.93, b: 0.8) }
        let m = max(r, g, b)
        return m > 0.001 ? RGB(r: r / m, g: g / m, b: b / m) : RGB(r: 0, g: 0, b: 0)
    }
}

/// Row of camera preset buttons shared by the Live Map and Stage Plot 3D views.
struct CameraPresetBar: View {
    @Binding var camera: CameraPreset
    var body: some View {
        HStack(spacing: 4) {
            ForEach(CameraPreset.allCases) { preset in
                Button {
                    camera = preset
                } label: {
                    if camera == preset {
                        Label(preset.label, systemImage: preset.symbol).labelStyle(.titleAndIcon).font(.caption)
                    } else {
                        Image(systemName: preset.symbol).font(.caption)
                    }
                }
                .help(preset.label)
                .buttonStyle(.bordered)
                .tint(camera == preset ? .pink : .gray)
            }
        }
    }
}
