import SwiftUI
import AppKit
import Combine

/// Creates every engine once and wires them together (save hooks, MIDI/OSC → cue engine, keyboard GO).
@MainActor
final class AppModel: ObservableObject {
    let store: ShowStore
    let audio: AudioEngine
    let lighting: LightingEngine
    let screens: ScreenManager
    let engine: ShowEngine
    let midi: MIDIControl
    let osc: OSCControl
    let builder: LightSetBuilder
    let remote: RemoteServer
    let visuals: VisualEngine
    let blender: BlenderBridge
    let daw: DAWEngine
    let sfx: SFXEngine
    let crew: CrewAgent
    let crowd: CrowdController
    let live: LiveMode
    @Published var section: AppSection? = .cues
    private var keyMonitor: Any?

    init() {
        let store = ShowStore()
        let audio = AudioEngine(store: store)
        let lighting = LightingEngine(store: store)
        let screens = ScreenManager(store: store)
        let engine = ShowEngine(store: store, audio: audio, lighting: lighting, screens: screens)
        self.store = store
        self.audio = audio
        self.lighting = lighting
        self.screens = screens
        self.engine = engine
        self.midi = MIDIControl(store: store)
        self.osc = OSCControl()
        self.builder = LightSetBuilder(store: store, engine: engine, lighting: lighting)
        let remote = RemoteServer(store: store, engine: engine, lighting: lighting, audio: audio)
        self.remote = remote
        self.visuals = VisualEngine(lighting: lighting, audio: audio)
        self.blender = BlenderBridge(store: store, lighting: lighting, screens: screens)
        self.daw = DAWEngine(store: store)
        self.sfx = SFXEngine(store: store)
        self.crew = CrewAgent(store: store, lighting: lighting, builder: self.builder, screens: screens)
        self.crowd = CrowdController(lighting: lighting, store: store, cache: remote.crowdCache)
        self.live = LiveMode(lighting: lighting, store: store)
        remote.screens = screens
        remote.visuals = visuals
        remote.crew = crew
        remote.crowd = crowd
        remote.live = live
        screens.visuals = visuals
        if let saved = store.show.titleSettings {
            visuals.title = saved
        } else {
            visuals.titleText = store.show.venue.artist.isEmpty ? store.show.name : store.show.venue.artist
        }
        visuals.onTitleChange = { [weak store] t in store?.show.titleSettings = t }
        // Pull the sound out of any video cues ahead of the show.
        for cue in store.show.cues where cue.kind == .video {
            if let p = cue.videoPath { MediaSupport.prepare(URL(fileURLWithPath: p)) }
        }

        store.willSave = { [weak audio, weak daw] in
            audio?.captureVocalStates()
            daw?.captureStates()
        }
        midi.onMessage = { [weak daw] s, d1, d2 in
            let type = s & 0xF0
            if type == 0x90 || type == 0x80 || type == 0xB0 || type == 0xE0 { daw?.liveMIDI(s, d1, d2) }
        }
        daw.onExportToShow = { [weak self] url, name in self?.addStudioExportToShow(url, name: name) }
        lighting.sfx = sfx
        sfx.flush = { [weak lighting] in lighting?.flushOutput() }
        sfx.onNote = { [weak engine] s in engine?.note("SFX: " + s) }
        let upgradedShows = store.show.lightShows.map { LookGenerator.addLasersAndEffects(LookGenerator.upgrade($0)) }
        if upgradedShows != store.show.lightShows { store.show.lightShows = upgradedShows }
        NotificationCenter.default.addObserver(forName: .studioAnalyzeFile, object: nil, queue: .main) { [weak self] note in
            guard let url = note.object as? URL else { return }
            MainActor.assumeIsolated {
                self?.builder.analyze(url: url)
                self?.section = .setBuilder
            }
        }
        midi.onAction = { [weak engine] action in engine?.perform(action) }
        osc.onMessage = { [weak self] address, args in self?.handleOSC(address, args) }

        if store.show.control.oscEnabled { osc.start(port: store.show.control.oscPort) }
        if store.show.vocalRack.enabled, audio.micPermission == .authorized { audio.loadVocalRack() }
        installKeyboardShortcuts()
        followStudioWithLights()
    }

    /// Reload engines after opening a different show file.
    func showDidLoad() {
        let upgraded = store.show.lightShows.map { LookGenerator.addLasersAndEffects(LookGenerator.upgrade($0)) }
        if upgraded != store.show.lightShows { store.show.lightShows = upgraded }
        engine.stopAll()
        engine.setStandby(0)
        lighting.syncPatch()
        audio.applyDeviceSettings()
        if store.show.vocalRack.enabled, audio.micPermission == .authorized { audio.loadVocalRack() }
        if store.show.control.oscEnabled { osc.start(port: store.show.control.oscPort) } else { osc.stop() }
    }

    private func handleOSC(_ address: String, _ args: [Any]) {
        let parts = address.split(separator: "/").map(String.init)
        switch parts.first ?? "" {
        case "go": engine.go()
        case "stop": engine.stopAll()
        case "panic": engine.panic()
        case "blackout": lighting.blackout.toggle()
        case "standby":
            if parts.count > 1 { engine.moveStandby(by: parts[1] == "prev" ? -1 : 1) }
        case "vocal":
            if parts.count > 1, parts[1] == "bypass" {
                if let on = args.first as? Bool { audio.setVocalBypass(on) }
                else if let n = args.first as? Int { audio.setVocalBypass(n != 0) }
                else if let f = args.first as? Float { audio.setVocalBypass(f > 0.5) }
                else { audio.setVocalBypass(!store.show.vocalRack.bypassAll) }
            }
        case "cue":
            if parts.count >= 3, ["start", "go"].contains(parts[2]) { engine.fire(cueNumber: parts[1]) }
        case "lights":
            if parts.count > 1, parts[1] == "gm" {
                if let f = args.first as? Float { lighting.grandMaster = Double(max(0, min(1, f))) }
                else if let i = args.first as? Int { lighting.grandMaster = Double(max(0, min(100, i))) / 100 }
            }
        default:
            break
        }
    }

    /// Studio bounce → new audio cue in the show, with its light show built automatically.
    func addStudioExportToShow(_ url: URL, name: String) {
        var cue = Cue(kind: .audio, number: store.nextCueNumber(), name: name)
        cue.audioPath = url.path
        // A Show Mix keeps the exact looks, transitions and light-level lane you built in the Studio.
        if let mixShow = ShowMixer.lightShow(for: daw.project, store: store, songPath: url.path) {
            store.show.lightShows.append(mixShow)
            cue.lightShowID = mixShow.id
            store.show.cues.append(cue)
            engine.note("Show Mix exported to the cue list with its full light show: \(name)")
            return
        }
        store.show.cues.append(cue)
        builder.analyze(url: url, linkTo: cue.id)
        engine.note("Studio export added to cue list: \(name)")
    }

    // MARK: Show Mix (cue list → Studio)

    private var studioLightsID = UUID()
    private var cancellables = Set<AnyCancellable>()

    /// Sends song cues to the Studio as one continuous, auto-mixed session with matching light transitions.
    func sendCuesToStudio(_ ids: [UUID], overrides: [Int: MixTransition] = [:]) {
        let chosen = ids.isEmpty ? store.show.cues.filter { $0.kind == .audio && $0.lightShowID != nil }.map(\.id) : ids
        guard let project = ShowMixer.build(cueIDs: chosen, store: store, overrides: overrides) else {
            engine.note("Nothing to mix — songs need a light show (analyse them in Light Set Builder first)")
            return
        }
        if daw.isPlaying { daw.stop() }
        daw.edit { $0 = project }
        daw.seek(to: 0)
        section = .studio
        engine.note("Show Mix built in the Studio: \(project.mix?.songs.count ?? 0) songs, \(project.mix?.transitions.count ?? 0) transitions")
    }

    func changeTransition(_ index: Int, to kind: MixTransition) {
        guard let mix = daw.project.mix else { return }
        var overrides: [Int: MixTransition] = [:]
        for (i, t) in mix.transitions.enumerated() where !t.auto { overrides[i] = t.kind }
        overrides[index] = kind
        sendCuesToStudio(mix.cueIDs, overrides: overrides)
    }

    func exportMixToShow() {
        section = .studio
        Task { await daw.exportToShow(name: daw.project.name, autoMaster: true) }
    }

    /// While the Studio plays a Show Mix, the rig plays its lights in sync.
    private func followStudioWithLights() {
        daw.$isPlaying.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] playing in
            MainActor.assumeIsolated {
                guard let self else { return }
                if playing, self.daw.project.mix != nil,
                   let show = ShowMixer.lightShow(for: self.daw.project, store: self.store) {
                    self.studioLightsID = UUID()
                    self.lighting.startSongShow(show, instanceID: self.studioLightsID, offset: self.daw.currentBeat() * self.daw.secondsPerBeat)
                } else {
                    self.lighting.stopSongShow(instanceID: self.studioLightsID)
                }
            }
        }
        .store(in: &cancellables)
    }

    /// Typing keyboard → notes in the Studio (A W S E D F T G Y H U J K, Z/X octave).
    private var keyboardOctave = 4
    private var heldKeys: Set<UInt16> = []
    private static let keyNotes: [UInt16: Int] = [0: 0, 13: 1, 1: 2, 14: 3, 2: 4, 3: 5, 17: 6, 5: 7, 16: 8, 4: 9, 32: 10, 38: 11, 40: 12, 31: 13, 37: 14]

    private func studioKey(_ keyCode: UInt16, down: Bool) -> Bool {
        if keyCode == 6 && down { keyboardOctave = max(1, keyboardOctave - 1); return true }   // Z
        if keyCode == 7 && down { keyboardOctave = min(7, keyboardOctave + 1); return true }   // X
        guard let offset = Self.keyNotes[keyCode] else { return false }
        let note = UInt8(max(0, min(127, (keyboardOctave + 1) * 12 + offset)))
        if down {
            guard !heldKeys.contains(keyCode) else { return true }
            heldKeys.insert(keyCode)
            daw.liveMIDI(0x90, note, 100)
        } else {
            heldKeys.remove(keyCode)
            daw.liveMIDI(0x80, note, 0)
        }
        return true
    }

    /// Space = GO, Esc = Panic — like QLab — unless you're typing in a text field.
    private func installKeyboardShortcuts() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let keyCode = event.keyCode
            let isDown = event.type == .keyDown
            let isRepeat = isDown && event.isARepeat
            let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            let handled: Bool = MainActor.assumeIsolated {
                guard let self, plain else { return false }
                let isTyping = NSApp.keyWindow?.firstResponder is NSText
                guard !isTyping else { return false }
                if self.section == .studio {
                    if keyCode == 49 { if isDown && !isRepeat { self.daw.togglePlay() }; return true }   // space
                    if keyCode == 15 { if isDown && !isRepeat { self.daw.toggleRecord() }; return true } // R
                    if keyCode == 36 { if isDown { self.daw.returnToStart() }; return true }               // return
                    if isRepeat { return Self.keyNotes[keyCode] != nil }
                    return self.studioKey(keyCode, down: isDown)
                }
                guard isDown else { return false }
                switch keyCode {
                case 49: self.engine.go(); return true          // space
                case 53: self.engine.panic(); return true       // escape
                default: return false
                }
            }
            return handled ? nil : event
        }
    }
}

@main
struct STRDMStageApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("STRDM Stage") {
            ContentView()
                .modifier(AppEnvironment(model: model))
                .frame(minWidth: 1180, minHeight: 720)
                .preferredColorScheme(.dark)
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            STRDMCommands(model: model)
        }

        // Big pop-out of the live map (drag it to a second display or make it full screen).
        Window("Live Stage Map", id: "liveMapPopout") {
            LiveStageMapView(isPopout: true)
                .modifier(AppEnvironment(model: model))
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1600, height: 1000)
    }
}

/// Every engine the views need, injected once for each window.
struct AppEnvironment: ViewModifier {
    let model: AppModel
    func body(content: Content) -> some View {
        content
                .environmentObject(model)
                .environmentObject(model.store)
                .environmentObject(model.audio)
                .environmentObject(model.lighting)
                .environmentObject(model.screens)
                .environmentObject(model.engine)
                .environmentObject(model.midi)
                .environmentObject(model.osc)
                .environmentObject(model.builder)
                .environmentObject(model.remote)
                .environmentObject(model.visuals)
                .environmentObject(model.blender)
                .environmentObject(model.daw)
                .environmentObject(model.sfx)
                .environmentObject(model.crew)
                .environmentObject(model.crowd)
                .environmentObject(model.live)
    }
}

struct STRDMCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Pop Out Live Stage Map") { openWindow(id: "liveMapPopout") }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
            CommandGroup(replacing: .newItem) {
                Button("New Show") { model.store.newShow(); model.showDidLoad() }
                    .keyboardShortcut("n")
                Button("Open Show…") { if model.store.openWithPanel() { model.showDidLoad() } }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.store.save() }.keyboardShortcut("s")
                Button("Save As…") { model.store.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Collect Media Next to Show File") { model.store.collectMedia() }
            }
            CommandGroup(after: .undoRedo) {
                Button("Undo Studio Edit") { model.daw.undo() }.keyboardShortcut("z", modifiers: [.command, .option])
                Button("Redo Studio Edit") { model.daw.redo() }.keyboardShortcut("z", modifiers: [.command, .option, .shift])
            }
            CommandMenu("Show") {
                Button("GO") { model.engine.go() }
                Button("Standby Next") { model.engine.moveStandby(by: 1) }.keyboardShortcut(.downArrow, modifiers: [.command])
                Button("Standby Previous") { model.engine.moveStandby(by: -1) }.keyboardShortcut(.upArrow, modifiers: [.command])
                Divider()
                Button("Stop All") { model.engine.stopAll() }.keyboardShortcut(".", modifiers: [.command])
                Button("Panic (fade everything)") { model.engine.panic() }
                Divider()
                Button("Lighting Blackout") { model.lighting.blackout.toggle() }.keyboardShortcut("b", modifiers: [.command])
                Button("Open All Screen Outputs") { model.screens.openAllOutputs() }
                Button("Close All Screen Outputs") { model.screens.closeAllOutputs() }
            }
        }
    }
