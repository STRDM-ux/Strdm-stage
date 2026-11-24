import Foundation
import AppKit
import UniformTypeIdentifiers

/// Owns the open show document and handles new / open / save.
@MainActor
final class ShowStore: ObservableObject {
    @Published var show: Show {
        didSet { if show != oldValue { isDirty = true } }
    }
    @Published private(set) var fileURL: URL? = nil
    @Published var isDirty = false
    @Published var lastError: String? = nil

    static let fileExtension = "strdmshow"
    private static let lastFileKey = "STRDMStage.lastShowFile"
    private var autosaveTimer: Timer?
    /// Called right before writing, so engines can push live state (e.g. plugin settings) into the show.
    var willSave: (() -> Void)?

    init() {
        self.show = Show()
        if let path = UserDefaults.standard.string(forKey: Self.lastFileKey),
           FileManager.default.fileExists(atPath: path) {
            load(from: URL(fileURLWithPath: path))
        } else {
            self.show = Self.demoShow()
            self.isDirty = false
        }
        // Never lose work on quit (including updates and restarts).
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isDirty else { return }
                self.save()
            }
        }
        // Autosave every 60 s when the show has a file and unsaved changes — protects against a crash mid-tour.
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isDirty else { return }
                self.save()
            }
        }
    }

    var windowTitle: String {
        let base = fileURL?.deletingPathExtension().lastPathComponent ?? show.name
        return isDirty ? "\(base) — edited" : base
    }

    // MARK: File operations

    func newShow() {
        show = Show()
        fileURL = nil
        isDirty = false
    }

    @discardableResult
    func openWithPanel() -> Bool {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: Self.fileExtension) ?? .json, .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        load(from: url)
        return fileURL == url
    }

    func load(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let loaded = try decoder.decode(Show.self, from: data)
            show = loaded
            fileURL = url
            isDirty = false
            UserDefaults.standard.set(url.path, forKey: Self.lastFileKey)
        } catch {
            lastError = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Saves to the show's file. A show that has never been saved goes straight into
    /// Documents/STRDM Stage Shows (no dialog), so nothing is lost mid-rehearsal.
    func save() {
        if let url = fileURL { write(to: url); return }
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { saveAs(); return }
        let folder = docs.appendingPathComponent("STRDM Stage Shows", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let safeName = show.name.replacingOccurrences(of: "/", with: "-")
        var url = folder.appendingPathComponent("\(safeName).\(Self.fileExtension)")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(safeName) \(n).\(Self.fileExtension)")
            n += 1
        }
        write(to: url)
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: Self.fileExtension) ?? .json]
        panel.nameFieldStringValue = "\(show.name).\(Self.fileExtension)"
        if panel.runModal() == .OK, let url = panel.url { write(to: url) }
    }

    private func write(to url: URL) {
        willSave?()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(show)
            try data.write(to: url, options: .atomic)
            fileURL = url
            isDirty = false
            UserDefaults.standard.set(url.path, forKey: Self.lastFileKey)
        } catch {
            lastError = "Couldn't save: \(error.localizedDescription)"
        }
    }

    /// Copies every referenced media file into a "Media" folder next to the show file and rewrites paths,
    /// so the whole show can be zipped and carried to the next city.
    func collectMedia() {
        guard let showURL = fileURL else { lastError = "Save the show first, then collect media."; return }
        let mediaDir = showURL.deletingLastPathComponent().appendingPathComponent("\(showURL.deletingPathExtension().lastPathComponent) Media")
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
            var copied = 0
            func collect(_ path: String?) -> String? {
                guard let path, fm.fileExists(atPath: path) else { return path }
                let src = URL(fileURLWithPath: path)
                if src.deletingLastPathComponent().standardizedFileURL == mediaDir.standardizedFileURL { return path }
                let dst = mediaDir.appendingPathComponent(src.lastPathComponent)
                if !fm.fileExists(atPath: dst.path) {
                    try? fm.copyItem(at: src, to: dst)
                    copied += 1
                }
                return dst.path
            }
            for i in show.cues.indices {
                show.cues[i].audioPath = collect(show.cues[i].audioPath)
                show.cues[i].videoPath = collect(show.cues[i].videoPath)
            }
            save()
            lastError = "Collected \(copied) file(s) into \(mediaDir.lastPathComponent)."
        } catch {
            lastError = "Couldn't collect media: \(error.localizedDescription)"
        }
    }

    // MARK: Cue helpers

    func nextCueNumber() -> String {
        let numbers = show.cues.compactMap { Double($0.number) }
        let next = (numbers.max() ?? 0).rounded(.down) + 1
        return String(Int(next))
    }

    @discardableResult
    func addCue(_ kind: CueKind, after index: Int?) -> Cue {
        var cue = Cue(kind: kind, number: nextCueNumber())
        if kind == .video { cue.screenID = show.screens.first?.id }
        if kind == .lights { cue.sceneID = show.lighting.scenes.first?.id }
        let insertAt = index.map { min($0 + 1, show.cues.count) } ?? show.cues.count
        show.cues.insert(cue, at: insertAt)
        return cue
    }

    func addAudioCues(from urls: [URL], at index: Int?) {
        var insertAt = index.map { min($0 + 1, show.cues.count) } ?? show.cues.count
        for url in urls {
            let isVideo = MediaSupport.isVideo(url) || MediaSupport.isImage(url)
            if MediaSupport.isVideo(url) { MediaSupport.prepare(url) }
            var cue = Cue(kind: isVideo ? .video : .audio, number: nextCueNumber())
            if isVideo {
                cue.videoPath = url.path
                cue.screenID = show.screens.first?.id
            } else {
                cue.audioPath = url.path
            }
            show.cues.insert(cue, at: insertAt)
            insertAt += 1
        }
    }

    func cueIndex(_ id: UUID?) -> Int? {
        guard let id else { return nil }
        return show.cues.firstIndex { $0.id == id }
    }

    // MARK: Demo

    static func demoShow() -> Show {
        var show = Show()
        show.name = "Armanii — Tour Set"
        let par = FixtureProfile.library[3]
        let mover = FixtureProfile.library[5]
        var fixtures: [Fixture] = []
        for i in 0..<6 {
            fixtures.append(Fixture(name: "Par \(i + 1)", profile: par, universe: 0, address: 1 + i * par.channels.count, group: "Front Wash"))
        }
        for i in 0..<4 {
            fixtures.append(Fixture(name: "Wash Mover \(i + 1)", profile: mover, universe: 0, address: 101 + i * mover.channels.count, group: "Movers"))
        }
        fixtures.append(Fixture(name: "Hazer", profile: FixtureProfile.library[8], universe: 0, address: 200, group: "Atmos"))
        show.lighting.fixtures = fixtures

        func scene(_ name: String, r: Int, g: Int, b: Int, w: Int, dim: Int, haze: Int = -1) -> LightScene {
            var s = LightScene(name: name)
            for f in fixtures {
                s.levels[f.id.uuidString] = f.profile.channels.map { ch in
                    switch ch.kind {
                    case .intensity: return dim
                    case .red: return r
                    case .green: return g
                    case .blue: return b
                    case .white: return w
                    case .haze: return haze
                    case .pan, .tilt: return 128
                    default: return 0
                    }
                }
            }
            return s
        }
        let preshow = scene("Preshow Purple", r: 120, g: 0, b: 255, w: 0, dim: 90, haze: 60)
        let walkon = scene("Walk-on Pink Blast", r: 255, g: 20, b: 147, w: 60, dim: 255, haze: 120)
        let ballad = scene("Ballad Warm", r: 255, g: 120, b: 40, w: 80, dim: 140)
        let black = scene("Blackout", r: 0, g: 0, b: 0, w: 0, dim: 0, haze: 0)
        show.lighting.scenes = [preshow, walkon, ballad, black]

        var c1 = Cue(kind: .lights, number: "1", name: "House to preshow look")
        c1.sceneID = preshow.id; c1.lightFade = 5
        var c2 = Cue(kind: .memo, number: "2", name: "Standby: DJ intro — wait for hype man")
        c2.notes = "Drag the intro track onto the cue list, then set this cue to auto-continue."
        var c3 = Cue(kind: .lights, number: "3", name: "Walk-on blast")
        c3.sceneID = walkon.id; c3.lightFade = 0.2; c3.continueMode = .autoContinue
        var c4 = Cue(kind: .vocalFX, number: "4", name: "Auto-Tune ON")
        c4.vocalBypass = false
        var c5 = Cue(kind: .lights, number: "5", name: "Ballad look")
        c5.sceneID = ballad.id; c5.lightFade = 4
        var c6 = Cue(kind: .fade, number: "6", name: "Fade out everything")
        c6.fadeTarget = .everything; c6.fadeDuration = 4; c6.continueMode = .autoContinue
        var c7 = Cue(kind: .lights, number: "7", name: "Blackout")
        c7.sceneID = black.id; c7.lightFade = 4
        show.cues = [c1, c2, c3, c4, c5, c6, c7]

        show.stagePlot.items = [
            StageItem(kind: .ledWall, label: "LED Wall", x: 6, y: 7.6, width: 8, depth: 0.4),
            StageItem(kind: .djBooth, label: "DJ", x: 6, y: 5.6, width: 1.8, depth: 0.9),
            StageItem(kind: .playback, label: "Playback + Auto-Tune Rig", x: 8.6, y: 5.6, width: 1.0, depth: 0.7),
            StageItem(kind: .vocalMic, label: "Armanii", x: 6, y: 1.6, width: 0.5, depth: 0.5),
            StageItem(kind: .vocalMic, label: "Hype", x: 3.6, y: 2.2, width: 0.5, depth: 0.5),
            StageItem(kind: .monitorWedge, label: "Wedge 1", x: 5.4, y: 0.5, width: 0.7, depth: 0.5),
            StageItem(kind: .monitorWedge, label: "Wedge 2", x: 6.6, y: 0.5, width: 0.7, depth: 0.5),
            StageItem(kind: .sideFill, label: "SF L", x: 0.8, y: 3, width: 0.8, depth: 0.8),
            StageItem(kind: .sideFill, label: "SF R", x: 11.2, y: 3, width: 0.8, depth: 0.8),
            StageItem(kind: .powerDrop, label: "Power", x: 7.4, y: 6.4, width: 0.4, depth: 0.4)
        ]
        show.venue.tourName = "Tour 2026"
        return show
    }
}
