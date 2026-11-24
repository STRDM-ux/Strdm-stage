import Foundation
import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Sends the live stage to Blender: builds the venue, rig (live colours + aim), haze, LED wall content,
/// performers and crowd as a .blend, and renders a photoreal still in the background.
@MainActor
final class BlenderBridge: ObservableObject {
    @Published private(set) var isRendering = false
    @Published private(set) var lastRender: NSImage?
    @Published private(set) var lastRenderURL: URL?
    @Published private(set) var lastBlendURL: URL?
    @Published private(set) var log = ""
    @Published var quality: Quality = .preview

    enum Quality: String, CaseIterable, Identifiable {
        case preview, final
        var id: String { rawValue }
        var label: String { self == .preview ? "Fast preview" : "Final (slower)" }
        var samples: Int { self == .preview ? 24 : 128 }
        var scale: Int { self == .preview ? 50 : 100 }
    }

    private let store: ShowStore
    private let lighting: LightingEngine
    private let screens: ScreenManager

    init(store: ShowStore, lighting: LightingEngine, screens: ScreenManager) {
        self.store = store
        self.lighting = lighting
        self.screens = screens
    }

    // MARK: Finding Blender

    static var blenderApp: URL? {
        let candidates = ["/Applications/Blender.app",
                          NSHomeDirectory() + "/Applications/Blender.app"]
        if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return URL(fileURLWithPath: found)
        }
        if let id = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.blenderfoundation.blender") { return id }
        return nil
    }

    static var isInstalled: Bool { blenderApp != nil }

    static func openDownloadPage() {
        if let url = URL(string: "https://www.blender.org/download/") { NSWorkspace.shared.open(url) }
    }

    private var outputFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = docs.appendingPathComponent("STRDM Stage Shows/Renders", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Render

    func render(camera: CameraPreset, crowd: Bool, openAfter: Bool = false) {
        guard let app = Self.blenderApp else { Self.openDownloadPage(); return }
        guard !isRendering else { return }
        isRendering = true
        log = "Building the scene…"
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "-")
        let base = outputFolder.appendingPathComponent("\(store.show.name.replacingOccurrences(of: "/", with: "-")) \(camera.label) \(stamp)")
        let png = base.appendingPathExtension("png")
        let blend = base.appendingPathExtension("blend")
        let wallImage = outputFolder.appendingPathComponent("led-wall-frame.png")
        let hasWall = saveWallFrame(to: wallImage)
        let description = sceneDescription(camera: camera, crowd: crowd, png: png, blend: blend,
                                           wallImage: hasWall ? wallImage.path : nil)
        guard let json = try? JSONSerialization.data(withJSONObject: description) else { isRendering = false; return }
        let script = Self.pythonScript(base64JSON: json.base64EncodedString())
        let scriptURL = outputFolder.appendingPathComponent("strdm_stage_render.py")
        do { try script.write(to: scriptURL, atomically: true, encoding: .utf8) } catch {
            log = "Couldn't write the Blender script: \(error.localizedDescription)"
            isRendering = false
            return
        }
        let exe = app.appendingPathComponent("Contents/MacOS/Blender")
        log = "Rendering in Blender (\(quality.label.lowercased()))…"
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (Int32, String) in
                let p = Process()
                p.executableURL = exe
                p.arguments = ["-b", "--factory-startup", "-P", scriptURL.path]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() } catch { return (-1, error.localizedDescription) }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return (p.terminationStatus, String(decoding: data.suffix(4000), as: UTF8.self))
            }.value
            isRendering = false
            if FileManager.default.fileExists(atPath: png.path), let img = NSImage(contentsOf: png) {
                lastRender = img
                lastRenderURL = png
                lastBlendURL = FileManager.default.fileExists(atPath: blend.path) ? blend : nil
                log = "Rendered \(png.lastPathComponent)"
                if openAfter, let b = lastBlendURL { openInBlender(b) }
            } else {
                log = "Blender finished with code \(result.0). Last output:\n" + result.1
            }
        }
    }

    func openInBlender(_ url: URL? = nil) {
        guard let app = Self.blenderApp, let file = url ?? lastBlendURL else { return }
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func revealLastRender() {
        if let u = lastRenderURL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }

    // MARK: Scene description (metres, Blender: X across, Y upstage, Z up)

    private func saveWallFrame(to url: URL) -> Bool {
        guard let id = screens.wallScreenID else { return false }
        var image: NSImage?
        if let player = screens.currentMedia(for: id) as? AVPlayer, let asset = player.currentItem?.asset {
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            if let cg = try? gen.copyCGImage(at: player.currentTime(), actualTime: nil) {
                image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        } else if let still = screens.currentMedia(for: id) as? NSImage {
            image = still
        }
        guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    private func sceneDescription(camera: CameraPreset, crowd: Bool, png: URL, blend: URL, wallImage: String?) -> [String: Any] {
        let plot = store.show.stagePlot
        let w = plot.stageWidth, d = plot.stageDepth, deck = plot.deck
        func sx(_ x: Double) -> Double { x - w / 2 }

        var items: [[String: Any]] = []
        for item in plot.items where item.kind != .person && item.kind != .vocalMic && item.kind != .label {
            let rgb = RGB(item.kind.color)
            items.append(["name": item.label, "kind": item.kind.rawValue,
                          "x": sx(item.x), "y": item.y, "w": max(0.1, item.width), "d": max(0.1, item.depth),
                          "h": Self.height(item.kind), "rot": -item.rotation * .pi / 180,
                          "color": [rgb.r, rgb.g, rgb.b]])
        }
        var fixtures: [[String: Any]] = []
        var haze = 0.0
        for f in lighting.fixtures {
            let role = lighting.role(f)
            let level = lighting.outputLevel(f)
            if role == .haze { haze = max(haze, level); continue }
            if role == .effect { continue }
            let p = lighting.position(f)
            let t = lighting.beamTarget(f)
            let onStage = t.x >= 0 && t.x <= w && t.y >= 0 && t.y <= d
            let rgb = LightingEngine.emittedRGB(f, lighting.live[f.id] ?? [])
            fixtures.append(["name": f.name, "mover": role == .mover,
                             "pos": [sx(p.x), p.y, deck + p.z],
                             "target": [sx(Double(t.x)), Double(t.y), onStage ? deck : 0],
                             "color": [rgb.r, rgb.g, rgb.b], "level": level])
        }
        var performers: [[String: Any]] = []
        for p in lighting.performers {
            let pos = lighting.performerPosition(p)
            performers.append(["name": p.label, "x": sx(Double(pos.x)), "y": Double(pos.y)])
        }
        let wall = plot.items.first { $0.kind == .ledWall }
        let cam: [String: Any]
        switch camera {
        case .foh: cam = ["pos": [0, -(14 + w * 0.3), 4.2], "look": [0, d / 2, deck + 1.2], "lens": 32]
        case .crowd: cam = ["pos": [-2, -(26 + w * 0.3), 2.4], "look": [0, d / 2, deck + 1.2], "lens": 40]
        case .artist: cam = ["pos": [0, d * 0.35, deck + 1.75], "look": [0, -14, 1.8], "lens": 22]
        case .top: cam = ["pos": [0, d / 2 - 0.01, max(w, d) * 1.6 + 6], "look": [0, d / 2, 0], "lens": 30]
        case .frontRow: cam = ["pos": [1, -3.5, 1.7], "look": [0, d / 2, deck + 2], "lens": 20]
        case .drone: cam = ["pos": [w * 0.8, -(10 + w * 0.4), 14], "look": [0, d / 2, deck + 1.2], "lens": 28]
        case .side: cam = ["pos": [w / 2 + 9, -6, 5], "look": [0, d / 2, deck + 1.2], "lens": 32]
        }
        var desc: [String: Any] = [
            "stage": ["w": w, "d": d, "deck": deck],
            "items": items, "fixtures": fixtures, "performers": performers,
            "crowd": crowd, "haze": max(0.25, haze),
            "camera": cam, "png": png.path, "blend": blend.path,
            "samples": quality.samples, "scale": quality.scale,
            "artist": store.show.venue.artist
        ]
        if let wall {
            desc["wall"] = ["x": sx(wall.x), "y": wall.y, "w": wall.width, "h": 4.5, "image": wallImage ?? ""]
        }
        if let model = plot.venueModelPath { desc["venueModel"] = model; desc["venueScale"] = plot.venueModelScale ?? 1 }
        return desc
    }

    private static func height(_ k: StageItemKind) -> Double {
        switch k {
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
        default: return 0.2
        }
    }

    // MARK: Blender Python

    static func pythonScript(base64JSON: String) -> String {
        """
        # Generated by STRDM Stage — builds the live stage in Blender and renders it.
        import bpy, json, math, base64, os
        from mathutils import Vector

        D = json.loads(base64.b64decode("\(base64JSON)").decode("utf-8"))
        bpy.ops.wm.read_factory_settings(use_empty=True)
        scene = bpy.context.scene
        coll = scene.collection

        def material(name, color, emission=None, strength=0.0, rough=0.5, metal=0.0):
            m = bpy.data.materials.new(name)
            m.use_nodes = True
            b = m.node_tree.nodes.get("Principled BSDF")
            b.inputs["Base Color"].default_value = (color[0], color[1], color[2], 1)
            b.inputs["Roughness"].default_value = rough
            b.inputs["Metallic"].default_value = metal
            if emission is not None:
                key = "Emission Color" if "Emission Color" in b.inputs else "Emission"
                b.inputs[key].default_value = (emission[0], emission[1], emission[2], 1)
                b.inputs["Emission Strength"].default_value = strength
            return m

        def box(name, sx, sy, sz, x, y, z, mat, rot=0.0):
            bpy.ops.mesh.primitive_cube_add(size=1, location=(x, y, z))
            o = bpy.context.active_object
            o.name = name
            o.scale = (sx, sy, sz)
            o.rotation_euler[2] = rot
            o.data.materials.append(mat)
            return o

        st = D["stage"]; W = st["w"]; Dp = st["d"]; deck = st["deck"]

        # Floor, deck, trusses
        bpy.ops.mesh.primitive_plane_add(size=200, location=(0, 0, 0))
        bpy.context.active_object.data.materials.append(material("Floor", (0.02, 0.02, 0.022), rough=0.35))
        box("Deck", W, Dp, deck, 0, Dp / 2, deck / 2, material("Deck", (0.05, 0.05, 0.05), rough=0.6))
        box("Edge", W, 0.05, 0.03, 0, 0, deck, material("Edge", (0, 0, 0), (1.0, 0.1, 0.6), 8))
        truss = material("Truss", (0.6, 0.6, 0.62), rough=0.3, metal=1.0)
        th = deck + 6
        for ty in (-0.8, Dp * 0.55, Dp - 1.2):
            box("Truss", W + 1, 0.3, 0.3, 0, ty, th + 0.25, truss)
        for tx in (-W / 2 - 0.3, W / 2 + 0.3):
            for ty in (-0.8, Dp - 1.2):
                box("Leg", 0.3, 0.3, th + 0.4, tx, ty, (th + 0.4) / 2, truss)
        box("Barrier", W + 2, 0.08, 1.1, 0, -1.5, 0.55, material("Barrier", (0.35, 0.35, 0.35), rough=0.3, metal=0.8))

        # Gear from the stage plot
        for it in D["items"]:
            if it["kind"] == "ledWall":
                continue
            c = it["color"]
            box(it["name"], it["w"], it["d"], it["h"], it["x"], it["y"], deck + it["h"] / 2,
                material(it["name"], (0.05 + c[0] * 0.15, 0.05 + c[1] * 0.15, 0.05 + c[2] * 0.15), rough=0.55), it["rot"])

        # LED wall with the real screen content
        if "wall" in D:
            wl = D["wall"]
            bpy.ops.mesh.primitive_plane_add(size=1, location=(wl["x"], wl["y"], deck + 0.4 + wl["h"] / 2))
            wall = bpy.context.active_object
            wall.name = "LED Wall"
            wall.scale = (wl["w"], wl["h"], 1)
            wall.rotation_euler[0] = math.pi / 2
            m = bpy.data.materials.new("LED")
            m.use_nodes = True
            nt = m.node_tree
            for n in list(nt.nodes):
                nt.nodes.remove(n)
            out = nt.nodes.new("ShaderNodeOutputMaterial")
            em = nt.nodes.new("ShaderNodeEmission")
            em.inputs["Strength"].default_value = 4.0
            if wl.get("image") and os.path.exists(wl["image"]):
                tex = nt.nodes.new("ShaderNodeTexImage")
                tex.image = bpy.data.images.load(wl["image"])
                nt.links.new(tex.outputs["Color"], em.inputs["Color"])
            else:
                em.inputs["Color"].default_value = (0.5, 0.0, 1.0, 1)
            nt.links.new(em.outputs["Emission"], out.inputs["Surface"])
            wall.data.materials.append(m)

        # Optional venue model from Blender / USD
        if D.get("venueModel") and os.path.exists(D["venueModel"]):
            path = D["venueModel"]
            ext = os.path.splitext(path)[1].lower()
            try:
                if ext in (".usd", ".usda", ".usdc", ".usdz"):
                    bpy.ops.wm.usd_import(filepath=path)
                elif ext == ".obj":
                    bpy.ops.wm.obj_import(filepath=path)
                elif ext in (".glb", ".gltf"):
                    bpy.ops.import_scene.gltf(filepath=path)
            except Exception as e:
                print("venue model import failed", e)

        # Performers
        skin = material("Performer", (0.9, 0.1, 0.45), rough=0.45)
        for p in D["performers"]:
            bpy.ops.mesh.primitive_cylinder_add(radius=0.2, depth=1.4, location=(p["x"], p["y"], deck + 0.7))
            bpy.context.active_object.data.materials.append(skin)
            bpy.ops.mesh.primitive_uv_sphere_add(radius=0.13, location=(p["x"], p["y"], deck + 1.55))
            bpy.context.active_object.data.materials.append(skin)

        # Crowd (instanced meshes keep it light)
        if D["crowd"]:
            bpy.ops.mesh.primitive_cylinder_add(radius=0.2, depth=1.3, location=(0, 0, -50))
            body = bpy.context.active_object.data
            bpy.ops.mesh.primitive_uv_sphere_add(radius=0.12, location=(0, 0, -50))
            head = bpy.context.active_object.data
            cm = material("Crowd", (0.06, 0.05, 0.06), rough=0.6)
            body.materials.append(cm); head.materials.append(cm)
            bpy.ops.mesh.primitive_plane_add(size=1, location=(0, 0, -50))
            phone_mesh = bpy.context.active_object.data
            phone_mesh.materials.append(material("Phone", (0, 0, 0), (0.9, 0.95, 1.0), 25))
            for v in phone_mesh.vertices:
                v.co.x *= 0.07; v.co.y *= 0.13
            import random
            random.seed(7)
            rows = 22
            span = W + 8
            for r in range(rows):
                y = -2.2 - r * 0.62
                per = int(span / 0.62)
                for c in range(per):
                    if random.random() > 0.88:
                        continue
                    x = -span / 2 + (c + random.random() * 0.6) * (span / per)
                    hgt = 0.9 + random.random() * 0.18
                    ob = bpy.data.objects.new("p", body); coll.objects.link(ob)
                    ob.location = (x, y, 0.65 * hgt); ob.scale = (1, 1, hgt)
                    oh = bpy.data.objects.new("h", head); coll.objects.link(oh)
                    oh.location = (x, y, 1.43 * hgt + 0.05)
                    if random.random() < 0.12:
                        ph = bpy.data.objects.new("phone", phone_mesh); coll.objects.link(ph)
                        ph.location = (x + 0.15, y + 0.12, 1.8 * hgt)
                        ph.rotation_euler = (math.radians(80), 0, 0)

        # Lights: live colours, levels and aim from STRDM Stage
        for f in D["fixtures"]:
            lvl = f["level"]
            if lvl < 0.02:
                continue
            ld = bpy.data.lights.new(f["name"], type="SPOT")
            ld.color = f["color"]
            ld.energy = (9000 if f["mover"] else 5500) * lvl
            ld.spot_size = math.radians(14 if f["mover"] else 34)
            ld.spot_blend = 0.25 if f["mover"] else 0.5
            ld.shadow_soft_size = 0.05
            if hasattr(ld, "volume_factor"):
                ld.volume_factor = 4.0
            lo = bpy.data.objects.new(f["name"], ld)
            coll.objects.link(lo)
            lo.location = f["pos"]
            direction = Vector(f["target"]) - Vector(f["pos"])
            lo.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
            # glowing lens
            bpy.ops.mesh.primitive_cylinder_add(radius=0.15, depth=0.05, location=f["pos"])
            lens = bpy.context.active_object
            lens.rotation_euler = lo.rotation_euler
            lens.data.materials.append(material("Lens", (0, 0, 0), f["color"], 30 * lvl))

        # House fill so the room isn't pitch black
        fill = bpy.data.lights.new("Fill", type="AREA"); fill.energy = 600; fill.size = 20
        fo = bpy.data.objects.new("Fill", fill); coll.objects.link(fo); fo.location = (0, -10, 12)
        # Back light spilling over the crowd so heads read as silhouettes
        rim = bpy.data.lights.new("CrowdRim", type="AREA"); rim.energy = 4000; rim.size = W + 6
        rim.color = (1.0, 0.3, 0.75)
        ro = bpy.data.objects.new("CrowdRim", rim); coll.objects.link(ro); ro.location = (0, 1.0, deck + 6.5)
        ro.rotation_euler = (Vector((0, -12, 0)) - Vector((0, 1.0, deck + 6.5))).to_track_quat("-Z", "Y").to_euler()

        # Haze: world volume so beams show
        world = bpy.data.worlds.new("Venue"); scene.world = world; world.use_nodes = True
        wnt = world.node_tree
        bg = wnt.nodes.get("Background")
        if bg:
            bg.inputs["Color"].default_value = (0.002, 0.002, 0.003, 1)
        scatter = wnt.nodes.new("ShaderNodeVolumeScatter")
        scatter.inputs["Density"].default_value = 0.02 + 0.06 * D["haze"]
        wout = wnt.nodes.get("World Output")
        wnt.links.new(scatter.outputs["Volume"], wout.inputs["Volume"])

        # Camera
        cd = bpy.data.cameras.new("Cam"); cd.lens = D["camera"]["lens"]
        co = bpy.data.objects.new("Cam", cd); coll.objects.link(co)
        co.location = D["camera"]["pos"]
        co.rotation_euler = (Vector(D["camera"]["look"]) - Vector(D["camera"]["pos"])).to_track_quat("-Z", "Y").to_euler()
        scene.camera = co

        # Render settings (EEVEE: fast, with volumetric beams)
        engines = [e.identifier for e in bpy.types.RenderSettings.bl_rna.properties["engine"].enum_items]
        scene.render.engine = "BLENDER_EEVEE_NEXT" if "BLENDER_EEVEE_NEXT" in engines else "BLENDER_EEVEE"
        ee = scene.eevee
        if hasattr(ee, "taa_render_samples"): ee.taa_render_samples = D["samples"]
        if hasattr(ee, "use_bloom"): ee.use_bloom = True
        if hasattr(ee, "volumetric_tile_size"): ee.volumetric_tile_size = "4"
        if hasattr(ee, "use_volumetric_shadows"): ee.use_volumetric_shadows = True
        if hasattr(ee, "volumetric_end"): ee.volumetric_end = 120
        scene.render.resolution_x = 1920
        scene.render.resolution_y = 1080
        scene.render.resolution_percentage = D["scale"]
        scene.render.image_settings.file_format = "PNG"
        scene.render.filepath = D["png"]
        try:
            scene.view_settings.look = "AgX - Punchy"
        except Exception:
            pass

        bpy.ops.wm.save_as_mainfile(filepath=D["blend"])
        bpy.ops.render.render(write_still=True)
        print("STRDM render done:", D["png"])
        """
    }
}

/// Buttons shown in both 3D views: render / open in Blender, import a venue model.
struct Blender3DToolbar: View {
    @EnvironmentObject var blender: BlenderBridge
    @EnvironmentObject var store: ShowStore
    let camera: CameraPreset
    let crowd: Bool
    @State private var showRender = false

    var body: some View {
        HStack(spacing: 8) {
            if BlenderBridge.isInstalled {
                Button {
                    blender.render(camera: camera, crowd: crowd)
                    showRender = true
                } label: {
                    Label(blender.isRendering ? "Rendering…" : "Render in Blender", systemImage: "camera.aperture")
                }
                .disabled(blender.isRendering)
                Picker("", selection: $blender.quality) {
                    ForEach(BlenderBridge.Quality.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
                if blender.lastBlendURL != nil {
                    Button("Open in Blender") { blender.openInBlender() }
                }
            } else {
                Button { BlenderBridge.openDownloadPage() } label: {
                    Label("Install Blender (free) for photoreal renders", systemImage: "arrow.down.circle")
                }
            }
            Menu {
                Button("Import venue / stage-set model…") {
                    let types = ["usdz", "usd", "usdc", "usda", "obj", "scn", "dae"].compactMap { UTType(filenameExtension: $0) }
                    if let url = pickFiles(types).first {
                        store.show.stagePlot.venueModelPath = url.path
                        if store.show.stagePlot.venueModelScale == nil { store.show.stagePlot.venueModelScale = 1 }
                    }
                }
                if store.show.stagePlot.venueModelPath != nil {
                    Button("Scale ×2") { store.show.stagePlot.venueModelScale = (store.show.stagePlot.venueModelScale ?? 1) * 2 }
                    Button("Scale ÷2") { store.show.stagePlot.venueModelScale = (store.show.stagePlot.venueModelScale ?? 1) / 2 }
                    Button("Raise 0.5 m") { store.show.stagePlot.venueModelOffsetY = (store.show.stagePlot.venueModelOffsetY ?? 0) + 0.5 }
                    Button("Lower 0.5 m") { store.show.stagePlot.venueModelOffsetY = (store.show.stagePlot.venueModelOffsetY ?? 0) - 0.5 }
                    Divider()
                    Button("Remove model", role: .destructive) { store.show.stagePlot.venueModelPath = nil }
                }
            } label: {
                Label("Venue model", systemImage: "cube.transparent")
            }
            .fixedSize()
            .help("Model the venue in Blender, export File → Export → Universal Scene Description (.usdz), then import it here.")
        }
        .sheet(isPresented: $showRender) { BlenderRenderSheet() }
    }
}

private struct BlenderRenderSheet: View {
    @EnvironmentObject var blender: BlenderBridge
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Blender render").font(.headline)
                Spacer()
                if blender.isRendering { ProgressView().controlSize(.small) }
            }
            ZStack {
                Rectangle().fill(Color.black)
                if let img = blender.lastRender, !blender.isRendering {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Text(blender.isRendering ? "Blender is building and rendering your stage…" : "No render yet")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 880, height: 495)
            ScrollView { Text(blender.log).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 60)
            HStack {
                Button("Show in Finder") { blender.revealLastRender() }.disabled(blender.lastRenderURL == nil)
                Button("Open scene in Blender") { blender.openInBlender() }.disabled(blender.lastBlendURL == nil)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}
