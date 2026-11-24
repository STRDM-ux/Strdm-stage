import Foundation
import AppKit
import AVFoundation
import QuartzCore
import SceneKit

struct DisplayInfo: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let frame: CGRect
    let isMain: Bool
    /// Real signal resolution (what the projector / LED processor receives).
    let pixelSize: CGSize
}

/// A media layer that re-fits itself whenever its screen or area changes size.
/// Auto mode compares the media's shape with the area's shape: close shapes fill (tiny crop, no bars);
/// very different shapes (portrait flyer on a wide LED wall) fit fully with a blurred copy filling the rest.
final class AutoFitLayer: CALayer {
    let fg: CALayer
    let bg: CALayer?
    var mode: FitMode = .auto
    var blurEdges = true
    /// width / height of the media, once known.
    var mediaAspect: CGFloat? { didSet { setNeedsLayout() } }

    init(fg: CALayer, bg: CALayer?) {
        self.fg = fg; self.bg = bg
        super.init()
        masksToBounds = true
        backgroundColor = NSColor.black.cgColor
        if let bg {
            bg.opacity = 0.5
            if let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 30]) { bg.filters = [blur] }
            addSublayer(bg)
        }
        addSublayer(fg)
    }
    override init(layer: Any) {
        let o = layer as? AutoFitLayer
        fg = o?.fg ?? CALayer(); bg = o?.bg
        super.init(layer: layer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSublayers() {
        super.layoutSublayers()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fg.frame = bounds
        bg?.frame = bounds.insetBy(dx: -bounds.width * 0.08, dy: -bounds.height * 0.08)
        let resolved = Self.resolve(mode: mode, media: mediaAspect, area: bounds.size)
        Self.setGravity(fg, resolved)
        if let bg {
            Self.setGravity(bg, .fill)
            bg.isHidden = !(mode == .auto && resolved == .fit && blurEdges)
        }
        CATransaction.commit()
    }

    /// Auto → fill when the media would lose ≤ 18 % to cropping, otherwise fit.
    static func resolve(mode: FitMode, media: CGFloat?, area: CGSize) -> FitMode {
        guard mode == .auto else { return mode }
        guard let media, media > 0, area.width > 1, area.height > 1 else { return .fill }
        return cropFraction(media: media, area: area.width / area.height) <= 0.18 ? .fill : .fit
    }
    static func cropFraction(media: CGFloat, area: CGFloat) -> CGFloat {
        let r = media / area
        return 1 - min(r, 1 / r)
    }
    static func setGravity(_ l: CALayer, _ mode: FitMode) {
        if let p = l as? AVPlayerLayer {
            p.videoGravity = mode == .fill ? .resizeAspectFill : (mode == .stretch ? .resize : .resizeAspect)
        } else {
            l.contentsGravity = mode == .fill ? .resizeAspectFill : (mode == .stretch ? .resize : .resizeAspect)
        }
    }
}

/// Drives video/image content on external displays (projectors, LED processors, confidence monitors).
@MainActor
final class ScreenManager: ObservableObject {
    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var openOutputIDs: Set<UUID> = []
    /// screen output id → what is on it now
    @Published private(set) var nowShowing: [UUID: String] = [:]
    /// Every layer on each screen (title + area), newest last.
    @Published private(set) var layers: [UUID: [String]] = [:]
    @Published var testPatternOn = false

    /// Called when a layer is replaced or stopped, so the cue list can clear it without auto-following.
    var onInstanceRemoved: ((UUID) -> Void)?

    private let store: ShowStore

    private final class Surface {
        let window: NSWindow
        let root: CALayer
        let visualsView: SCNView
        var testLayer: CALayer?
        init(window: NSWindow, root: CALayer, visualsView: SCNView) {
            self.window = window; self.root = root; self.visualsView = visualsView
        }
    }

    /// Generated visuals (set by the app once created).
    var visuals: VisualEngine? {
        didSet { for s in surfaces.values { s.visualsView.scene = visuals?.scene } }
    }
    @Published private(set) var visualsOnScreens: Set<UUID> = []
    private var visualsTimer: Timer?

    private final class Content {
        let key = UUID()
        let instanceID: UUID
        let screenID: UUID
        let layer: CALayer
        let title: String
        var region: ScreenRegion = .full
        var player: AVPlayer?
        var looper: AVPlayerLooper?
        var endObserver: NSObjectProtocol?
        var completion: (() -> Void)?
        var image: NSImage?
        init(instanceID: UUID, screenID: UUID, layer: CALayer, title: String) {
            self.instanceID = instanceID; self.screenID = screenID; self.layer = layer; self.title = title
        }
    }

    private var surfaces: [UUID: Surface] = [:]
    private var contents: [UUID: Content] = [:]
    private var screenObserver: NSObjectProtocol?

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "tif", "tiff", "bmp"]

    init(store: ShowStore) {
        self.store = store
        refreshDisplays()
        visualsTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateVisuals() }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDisplays() }
        }
    }

    // MARK: Displays

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    func refreshDisplays() {
        let main = NSScreen.screens.first
        displays = NSScreen.screens.compactMap { s in
            guard let id = Self.displayID(of: s) else { return nil }
            let mode = CGDisplayCopyDisplayMode(id)
            let px = mode.map { CGSize(width: $0.pixelWidth, height: $0.pixelHeight) }
                ?? CGSize(width: s.frame.width * s.backingScaleFactor, height: s.frame.height * s.backingScaleFactor)
            return DisplayInfo(id: id, name: s.localizedName, frame: s.frame, isMain: s == main, pixelSize: px)
        }
        // A display changed (resolution switched, processor re-plugged): re-seat full-screen outputs.
        // Media layers re-fit on their own as their areas resize.
        for output in store.show.screens {
            guard let surface = surfaces[output.id], let id = output.displayID,
                  let screen = NSScreen.screens.first(where: { Self.displayID(of: $0) == id }) else { continue }
            if output.windowed {
                surface.window.contentAspectRatio = screen.frame.size
            } else if surface.window.frame != screen.frame {
                surface.window.setFrame(screen.frame, display: true)
            }
        }
    }

    /// The real resolution an output feeds: its display's signal, else the preview window's size.
    func pixelSize(for outputID: UUID) -> CGSize? {
        guard let output = store.show.screens.first(where: { $0.id == outputID }) else { return nil }
        if let id = output.displayID, let d = displays.first(where: { $0.id == id }) { return d.pixelSize }
        if let w = surfaces[outputID]?.window {
            let sz = w.contentLayoutRect.size, sc = w.backingScaleFactor
            return CGSize(width: sz.width * sc, height: sz.height * sc)
        }
        return nil
    }

    static func aspectLabel(_ s: CGSize) -> String {
        guard s.width > 0, s.height > 0 else { return "?" }
        let r = s.width / s.height
        let known: [(CGFloat, String)] = [(16.0/9, "16:9"), (16.0/10, "16:10"), (4.0/3, "4:3"), (5.0/4, "5:4"), (21.0/9, "21:9"),
                                          (32.0/9, "32:9"), (3, "3:1"), (4, "4:1"), (1, "1:1"), (9.0/16, "9:16"), (3.0/4, "3:4"), (2, "2:1")]
        if let k = known.first(where: { abs($0.0 - r) / r < 0.02 }) { return k.1 }
        return r >= 1 ? String(format: "%.2f:1", r) : String(format: "1:%.2f", 1 / r)
    }

    private var aspectCache: [String: CGFloat] = [:]
    /// width / height of an image or video file (rotation-aware), cached.
    func mediaAspect(path: String) -> CGFloat? {
        if let a = aspectCache[path] { return a }
        let url = URL(fileURLWithPath: path)
        var a: CGFloat?
        if Self.imageExtensions.contains(url.pathExtension.lowercased()) {
            if let rep = NSImageRep(contentsOf: url), rep.pixelsWide > 0, rep.pixelsHigh > 0 {
                a = CGFloat(rep.pixelsWide) / CGFloat(rep.pixelsHigh)
            } else if let img = NSImage(contentsOf: url), img.size.height > 0 {
                a = img.size.width / img.size.height
            }
        } else if let track = AVURLAsset(url: url).tracks(withMediaType: .video).first {
            let r = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
            if r.height != 0 { a = abs(r.width / r.height) }
        }
        if let a { aspectCache[path] = a }
        return a
    }

    /// One line per target screen describing what Auto fit will do.
    func autoFitSummary(for cue: Cue) -> [String] {
        guard let path = cue.videoPath, let media = mediaAspect(path: path) else { return [] }
        let region = (cue.region ?? .full).rect
        return targets(for: cue).compactMap { id in
            guard let output = store.show.screens.first(where: { $0.id == id }),
                  let px = pixelSize(for: id) else { return nil }
            let area = CGSize(width: px.width * region.width, height: px.height * region.height)
            let res = AutoFitLayer.resolve(mode: .auto, media: media, area: area)
            let what: String
            if res == .fill {
                let crop = Int((AutoFitLayer.cropFraction(media: media, area: area.width / area.height) * 100).rounded())
                what = crop == 0 ? "fills exactly" : "fills (trims \(crop)%)"
            } else {
                what = output.blurEdges != false ? "fits whole, blurred edges" : "fits whole, black bars"
            }
            return "\(output.name) \(Int(area.width))×\(Int(area.height)) → \(what)"
        }
    }

    // MARK: Output windows

    func isOpen(_ outputID: UUID) -> Bool { surfaces[outputID] != nil }

    func openAllOutputs() {
        for output in store.show.screens { openOutput(output.id) }
    }

    func openOutput(_ outputID: UUID) {
        guard let output = store.show.screens.first(where: { $0.id == outputID }) else { return }
        if surfaces[outputID] != nil { closeOutput(outputID) }

        let screen = output.displayID.flatMap { id in NSScreen.screens.first { Self.displayID(of: $0) == id } }
        let window: NSWindow
        if !output.windowed, let screen {
            window = NSWindow(contentRect: NSRect(origin: .zero, size: screen.frame.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: true)
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.hidesOnDeactivate = false
            window.ignoresMouseEvents = true
        } else {
            window = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 960, height: 540),
                              styleMask: [.titled, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "\(output.name) — preview window"
            // Preview window takes the real output's shape when a display is assigned.
            window.contentAspectRatio = screen?.frame.size ?? NSSize(width: 16, height: 9)
        }
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black

        let bounds = NSRect(origin: .zero, size: window.contentLayoutRect.size)
        let container = NSView(frame: bounds)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        let view = NSView(frame: bounds)
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        root.layoutManager = CAConstraintLayoutManager()
        view.layer = root          // layer-hosting view: set the layer, then wantsLayer
        view.wantsLayer = true
        view.layerUsesCoreImageFilters = true   // blurred edges for Auto fit
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        // Generated 3D visuals sit above the media layer and only show while a song show runs.
        let scn = SCNView(frame: bounds)
        scn.autoresizingMask = [.width, .height]
        scn.scene = visuals?.scene
        scn.backgroundColor = .black
        scn.antialiasingMode = .multisampling4X
        scn.rendersContinuously = true
        scn.isHidden = true
        container.addSubview(scn)
        window.contentView = container
        window.orderFrontRegardless()

        surfaces[outputID] = Surface(window: window, root: root, visualsView: scn)
        openOutputIDs.insert(outputID)
        if testPatternOn { showTestPattern(on: outputID) }
    }

    func closeOutput(_ outputID: UUID) {
        for c in contents.values where c.screenID == outputID { remove(c, notify: true) }
        surfaces[outputID]?.window.orderOut(nil)
        surfaces[outputID]?.window.close()
        surfaces[outputID] = nil
        openOutputIDs.remove(outputID)
        nowShowing[outputID] = nil
    }

    func closeAllOutputs() {
        for id in Array(surfaces.keys) { closeOutput(id) }
    }

    // MARK: What's on screen (for the 3D venue's LED wall)

    /// The newest video player or still showing on a screen, or nil.
    func currentMedia(for screenID: UUID) -> Any? {
        let latest = contents.values.filter { $0.screenID == screenID && $0.layer.opacity > 0.05 }
            .max { $0.layer.zPosition < $1.layer.zPosition }
        if let player = latest?.player { return player }
        return latest?.image
    }

    /// The output that feeds the LED wall: one named like "LED", else the first.
    var wallScreenID: UUID? {
        store.show.screens.first { $0.name.lowercased().contains("led") }?.id ?? store.show.screens.first?.id
    }

    /// Which screen output feeds an LED wall in the stage design: a screen whose name matches the wall's label
    /// (e.g. "IMAG L"), otherwise the walls take the outputs in order (main wall first). Spare walls mirror the main output.
    func screenID(forWall wall: StageItem, index: Int) -> UUID? {
        let outputs = store.show.screens
        guard !outputs.isEmpty else { return nil }
        let label = wall.label.lowercased()
        if let named = outputs.first(where: { o in
            let n = o.name.lowercased()
            return !n.isEmpty && (n == label || label.contains(n) || n.contains(label))
        }) { return named.id }
        // Walls without a name match, ordered: widest (main) first, then left to right.
        let walls = store.show.stagePlot.items.filter { $0.kind == .ledWall }
        let unnamed = walls.filter { w in
            !outputs.contains { o in let n = o.name.lowercased(), l = w.label.lowercased(); return !n.isEmpty && (n == l || l.contains(n) || n.contains(l)) }
        }.sorted { ($0.width, -$0.x) > ($1.width, -$1.x) }
        let free = outputs.filter { o in
            !walls.contains { w in let n = o.name.lowercased(), l = w.label.lowercased(); return !n.isEmpty && (n == l || l.contains(n) || n.contains(l)) }
        }
        if let k = unnamed.firstIndex(where: { $0.id == wall.id }), k < free.count { return free[k].id }
        return wallScreenID
    }

    func visualsShowing(on screenID: UUID) -> Bool { visualsOnScreens.contains(screenID) }

    // MARK: Generated visuals

    /// Shows the 3D visuals on screens set to Auto Visuals while a song show (or a manual visual) runs,
    /// unless a video/image cue is currently on that screen.
    private func updateVisuals() {
        guard let visuals else { return }
        let active = visuals.isLive || visuals.manualStyle != nil
        var on = Set<UUID>()
        for output in store.show.screens {
            guard let surface = surfaces[output.id] else { continue }
            let hasMedia = contents.values.contains { $0.screenID == output.id }
            let show = active && output.autoVisuals != false && !hasMedia
            if surface.visualsView.isHidden == show { surface.visualsView.isHidden = !show }
            if show { on.insert(output.id) }
        }
        if on != visualsOnScreens { visualsOnScreens = on }
    }

    // MARK: Cues

    /// Screens a cue goes to: all screens, a chosen set, or one.
    func targets(for cue: Cue) -> [UUID] {
        let all = store.show.screens.map(\.id)
        if cue.allScreens == true { return all }
        if let ids = cue.screenIDs?.filter({ all.contains($0) }), !ids.isEmpty { return ids }
        if let id = cue.screenID, all.contains(id) { return [id] }
        return all.first.map { [$0] } ?? []
    }

    /// Pins a layer to a normalised area of its screen so it re-fits when the output resizes.
    static func constrain(_ layer: CALayer, to r: CGRect) {
        layer.autoresizingMask = []
        layer.constraints = [
            CAConstraint(attribute: .minX, relativeTo: "superlayer", attribute: .maxX, scale: r.minX, offset: 0),
            CAConstraint(attribute: .width, relativeTo: "superlayer", attribute: .width, scale: r.width, offset: 0),
            // layer coordinates run bottom-up
            CAConstraint(attribute: .minY, relativeTo: "superlayer", attribute: .maxY, scale: 1 - r.maxY, offset: 0),
            CAConstraint(attribute: .height, relativeTo: "superlayer", attribute: .height, scale: r.height, offset: 0)
        ]
    }

    /// Starts a video or still on the cue's screen(s) and area, cross-fading over whatever was in that area
    /// (or layering on top). One player drives every screen so they stay in sync.
    /// Returns duration in seconds (nil for stills, which hold until replaced).
    func play(cue: Cue, instanceID: UUID, completion: @escaping () -> Void) -> Double? {
        guard let path = cue.videoPath, FileManager.default.fileExists(atPath: path) else { return nil }
        let screenIDs = targets(for: cue)
        guard !screenIDs.isEmpty else { return nil }
        for id in screenIDs where surfaces[id] == nil { openOutput(id) }

        let url = URL(fileURLWithPath: path)
        let title = url.deletingPathExtension().lastPathComponent
        let isImage = Self.imageExtensions.contains(url.pathExtension.lowercased())
        let region = cue.region ?? .full
        let fit = cue.effectiveFit
        let aspect = mediaAspect(path: path)
        var duration: Double? = nil
        var image: NSImage?
        var player: AVPlayer?
        var looper: AVPlayerLooper?
        var item: AVPlayerItem?

        if isImage {
            guard let img = NSImage(contentsOf: url) else { return nil }
            image = img
        } else {
            let asset = AVURLAsset(url: url)
            let it = AVPlayerItem(asset: asset)
            item = it
            if cue.videoLoop {
                let queue = AVQueuePlayer()
                looper = AVPlayerLooper(player: queue, templateItem: it)
                player = queue
            } else {
                player = AVPlayer(playerItem: it)
                let seconds = asset.duration.seconds
                duration = seconds.isFinite ? seconds : nil
            }
            player?.isMuted = true   // show audio lives in audio cues so it runs through the main outputs
        }

        let fadeTime = max(0, cue.videoFade)
        var first: Content?
        for screenID in screenIDs {
            guard let surface = surfaces[screenID] else { continue }
            let blur = fit == .auto && store.show.screens.first(where: { $0.id == screenID })?.blurEdges != false
            let fgLayer: CALayer, bgLayer: CALayer?
            if let image {
                let l = CALayer(); l.contents = image; fgLayer = l
                if blur { let b = CALayer(); b.contents = image; bgLayer = b } else { bgLayer = nil }
            } else {
                fgLayer = AVPlayerLayer(player: player)
                bgLayer = blur ? AVPlayerLayer(player: player) : nil
            }
            let fitLayer = AutoFitLayer(fg: fgLayer, bg: bgLayer)
            fitLayer.mode = fit
            fitLayer.blurEdges = blur
            fitLayer.mediaAspect = aspect
            let layer: CALayer = fitLayer
            let content = Content(instanceID: instanceID, screenID: screenID, layer: layer, title: title)
            content.region = region
            content.image = image
            if first == nil {
                content.player = player
                content.looper = looper
                content.completion = completion
                first = content
            }
            layer.frame = surface.root.bounds
            Self.constrain(layer, to: region.rect)
            layer.opacity = 0
            layer.zPosition = CGFloat(contents.count + 1)
            if let test = surface.testLayer {
                surface.root.insertSublayer(layer, below: test)
            } else {
                surface.root.addSublayer(layer)
            }
            surface.root.setNeedsLayout()
            surface.root.layoutIfNeeded()
            animate(layer, opacity: Float(cue.overlay == true ? (cue.mediaOpacity ?? 1) : 1), duration: fadeTime)

            // Cross-fade out whatever was in the same area (unless layering on top).
            if cue.overlay != true {
                let previous = contents.values.filter { $0.screenID == screenID && $0.region.rect.intersects(region.rect.insetBy(dx: 0.001, dy: 0.001)) }
                for old in previous {
                    animate(old.layer, opacity: 0, duration: fadeTime) { [weak self] in
                        self?.remove(old, notify: true)
                    }
                }
            }
            contents[content.key] = content
            nowShowing[screenID] = title
        }
        if let item, !cue.videoLoop, let first {
            first.endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.contentEnded(instanceID) }
            }
        }
        player?.play()
        refreshLayers()
        return duration
    }

    private func refreshLayers() {
        var out: [UUID: [String]] = [:]
        for c in contents.values.sorted(by: { $0.layer.zPosition < $1.layer.zPosition }) {
            out[c.screenID, default: []].append(c.region == .full ? c.title : "\(c.title) (\(c.region.label))")
        }
        if out != layers { layers = out }
    }

    /// Clears one screen (all layers) with a fade.
    func clear(screenID: UUID, fade: Double = 0.5) {
        for c in contents.values where c.screenID == screenID {
            animate(c.layer, opacity: 0, duration: fade) { [weak self] in self?.remove(c, notify: true) }
        }
    }

    /// Natural end of a non-looping video: hold the last frame, tell the cue list it finished.
    private func contentEnded(_ instanceID: UUID) {
        guard let c = contents.values.first(where: { $0.instanceID == instanceID && $0.completion != nil }) else { return }
        let done = c.completion
        c.completion = nil
        done?()
    }

    func fadeAndStop(instanceID: UUID, duration: Double) {
        for c in contents.values where c.instanceID == instanceID {
            animate(c.layer, opacity: 0, duration: duration) { [weak self] in
                guard let self else { return }
                let done = c.completion
                c.completion = nil
                self.remove(c, notify: false)
                done?()
            }
        }
    }

    func stopAll(fade: Double) {
        for c in Array(contents.values) {
            animate(c.layer, opacity: 0, duration: fade) { [weak self] in
                self?.remove(c, notify: true)
            }
        }
    }

    private func remove(_ c: Content, notify: Bool) {
        guard contents[c.key] != nil else { return }
        contents[c.key] = nil
        let siblings = contents.values.filter { $0.instanceID == c.instanceID }
        if siblings.isEmpty {
            c.player?.pause()
            c.looper?.disableLooping()
        } else if let next = siblings.first, c.player != nil {
            // hand the shared player / end-of-video duties to a sibling screen
            next.player = c.player; next.looper = c.looper
            next.completion = c.completion; next.endObserver = c.endObserver
            c.endObserver = nil
        }
        if let obs = c.endObserver { NotificationCenter.default.removeObserver(obs) }
        c.layer.removeFromSuperlayer()
        if let latest = contents.values.filter({ $0.screenID == c.screenID }).max(by: { $0.layer.zPosition < $1.layer.zPosition }) {
            nowShowing[c.screenID] = latest.title
        } else {
            nowShowing[c.screenID] = nil
        }
        refreshLayers()
        if notify && siblings.isEmpty { onInstanceRemoved?(c.instanceID) }
    }

    private func animate(_ layer: CALayer, opacity: Float, duration: Double, completion: (() -> Void)? = nil) {
        CATransaction.begin()
        if duration <= 0.01 {
            CATransaction.setDisableActions(true)
        } else {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        }
        if let completion {
            CATransaction.setCompletionBlock {
                MainActor.assumeIsolated { completion() }
            }
        }
        layer.opacity = opacity
        CATransaction.commit()
    }

    // MARK: Test pattern / identify

    func setTestPattern(_ on: Bool) {
        testPatternOn = on
        for id in surfaces.keys {
            if on { showTestPattern(on: id) } else {
                surfaces[id]?.testLayer?.removeFromSuperlayer()
                surfaces[id]?.testLayer = nil
            }
        }
    }

    private func showTestPattern(on outputID: UUID) {
        guard let surface = surfaces[outputID] else { return }
        surface.testLayer?.removeFromSuperlayer()
        let name = store.show.screens.first { $0.id == outputID }?.name ?? "Output"
        let size = surface.root.bounds.size.width > 10 ? surface.root.bounds.size : CGSize(width: 1920, height: 1080)
        let layer = CALayer()
        layer.frame = surface.root.bounds
        Self.constrain(layer, to: ScreenRegion.full.rect)
        layer.zPosition = 10_000
        layer.contents = Self.testCard(size: size, name: name)
        layer.contentsGravity = .resize
        surface.root.addSublayer(layer)
        surface.testLayer = layer
    }

    private static func testCard(size: CGSize, name: String) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            let bars: [NSColor] = [.white, .yellow, .cyan, .green, .magenta, .red, .blue, .black]
            let w = rect.width / CGFloat(bars.count)
            for (i, c) in bars.enumerated() {
                c.setFill()
                NSRect(x: CGFloat(i) * w, y: 0, width: w + 1, height: rect.height).fill()
            }
            NSColor.white.withAlphaComponent(0.6).setStroke()
            let grid = NSBezierPath()
            let step = rect.height / 9
            var x: CGFloat = 0
            while x <= rect.width { grid.move(to: NSPoint(x: x, y: 0)); grid.line(to: NSPoint(x: x, y: rect.height)); x += step }
            var y: CGFloat = 0
            while y <= rect.height { grid.move(to: NSPoint(x: 0, y: y)); grid.line(to: NSPoint(x: rect.width, y: y)); y += step }
            grid.lineWidth = 2
            grid.stroke()
            let d = rect.height * 0.8
            let circle = NSBezierPath(ovalIn: NSRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d))
            circle.lineWidth = 6
            NSColor.white.setStroke()
            circle.stroke()
            let label = "\(name)\n\(Int(rect.width)) × \(Int(rect.height))" as NSString
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: rect.height * 0.07),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.black.withAlphaComponent(0.7),
                .paragraphStyle: style
            ]
            let textRect = NSRect(x: 0, y: rect.midY - rect.height * 0.1, width: rect.width, height: rect.height * 0.2)
            label.draw(in: textRect, withAttributes: attrs)
            return true
        }
    }
}
