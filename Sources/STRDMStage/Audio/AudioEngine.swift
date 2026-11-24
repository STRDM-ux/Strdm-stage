import Foundation
import AVFoundation
import AppKit
import CoreAudioKit

/// Track playback (backing tracks, stems, intros, SFX) plus the live vocal rack that hosts
/// Audio Unit plugins such as Antares Auto-Tune on a hardware input.
@MainActor
final class AudioEngine: ObservableObject {
    // MARK: Published state
    @Published private(set) var devices: [AudioDevice] = []
    @Published private(set) var availablePlugins: [AVAudioUnitComponent] = []
    @Published private(set) var loadedPluginIDs: Set<UUID> = []
    @Published private(set) var micPermission: AVAuthorizationStatus = .notDetermined
    @Published private(set) var outputLevel: Float = 0
    @Published private(set) var vocalLevel: Float = 0
    @Published var status: String = "Audio idle"
    /// Called when playback is torn down by the system (interface unplugged), so the cue list can clear it.
    var onInstanceRemoved: ((UUID) -> Void)?

    let engine = AVAudioEngine()
    private let store: ShowStore

    private final class Playback {
        let player = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode()
        let file: AVAudioFile
        var fadeTimer: Timer?
        var completion: (() -> Void)?
        init(file: AVAudioFile) { self.file = file }
    }
    private var playbacks: [UUID: Playback] = [:]

    // Vocal rack graph
    private var vocalUnits: [UUID: AVAudioUnit] = [:]
    private let masterEQ = AVAudioUnitEQ(numberOfBands: 11)
    private var eqWired = false
    private let vocalIn = AVAudioMixerNode()
    private let vocalOut = AVAudioMixerNode()
    private var vocalWired = false
    private var pluginWindows: [UUID: NSWindow] = [:]
    private var configObserver: NSObjectProtocol?
    private var meterTapsInstalled = false

    init(store: ShowStore) {
        self.store = store
        engine.attach(vocalIn)
        engine.attach(vocalOut)
        engine.attach(masterEQ)
        applyEQ()
        refreshDevices()
        refreshPluginList()
        micPermission = AVCaptureDevice.authorizationStatus(for: .audio)
        applyDeviceSettings()
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        }
    }

    // MARK: Devices

    func refreshDevices() {
        devices = CoreAudioDevices.all()
    }

    var outputDevices: [AudioDevice] { devices.filter { $0.outputChannels > 0 } }
    var inputDevices: [AudioDevice] { devices.filter { $0.inputChannels > 0 } }

    /// Applies the show's chosen interface + buffer size. Stops the engine briefly.
    func applyDeviceSettings() {
        let settings = store.show.audioSettings
        let wasRunning = engine.isRunning
        engine.stop()

        let outID = CoreAudioDevices.device(uid: settings.outputDeviceUID)?.id ?? CoreAudioDevices.defaultDevice(input: false)
        if let outID {
            CoreAudioDevices.setCurrentDevice(engine.outputNode.audioUnit, outID)
            CoreAudioDevices.setBufferSize(outID, frames: settings.bufferFrames)
        }
        if store.show.vocalRack.enabled, micPermission == .authorized {
            let inID = CoreAudioDevices.device(uid: settings.inputDeviceUID)?.id ?? CoreAudioDevices.defaultDevice(input: true)
            if let inID {
                CoreAudioDevices.setCurrentDevice(engine.inputNode.audioUnit, inID)
                CoreAudioDevices.setBufferSize(inID, frames: settings.bufferFrames)
            }
        }
        engine.mainMixerNode.outputVolume = Self.linear(settings.masterGainDB)
        if wasRunning || vocalWired { startEngine() }
        let outName = devices.first { $0.id == outID }?.name ?? "default output"
        status = "Output: \(outName) · \(settings.bufferFrames) samples"
    }

    func setMasterGain(_ db: Double) {
        store.show.audioSettings.masterGainDB = db
        engine.mainMixerNode.outputVolume = Self.linear(db)
    }

    private func startEngine() {
        guard !engine.isRunning else { return }
        // The engine needs at least one connection to the main mixer to start cleanly.
        _ = engine.mainMixerNode
        wireMasterEQ()
        engine.prepare()
        do {
            try engine.start()
            installMeters()
        } catch {
            status = "Audio engine failed to start: \(error.localizedDescription)"
        }
    }

    // MARK: Master EQ

    /// main mixer → EQ → output. Re-wired whenever the engine (re)starts so device changes keep the EQ.
    private func wireMasterEQ() {
        engine.disconnectNodeOutput(engine.mainMixerNode)
        engine.disconnectNodeOutput(masterEQ)
        let format = engine.outputNode.outputFormat(forBus: 0)
        let ok = format.sampleRate > 0 && format.channelCount > 0
        engine.connect(engine.mainMixerNode, to: masterEQ, format: ok ? format : nil)
        engine.connect(masterEQ, to: engine.outputNode, format: ok ? format : nil)
        eqWired = true
    }

    func applyEQ() {
        let eq = store.show.audioSettings.eq ?? MasterEQ()
        for (i, f) in MasterEQ.frequencies.enumerated() {
            let b = masterEQ.bands[i]
            b.filterType = i == 0 ? .lowShelf : (i == MasterEQ.frequencies.count - 1 ? .highShelf : .parametric)
            b.frequency = f
            b.bandwidth = 1.0
            b.gain = Float(max(-12, min(12, eq.gains[safe: i] ?? 0)))
            b.bypass = false
        }
        let hp = masterEQ.bands[10]
        hp.filterType = .highPass
        hp.frequency = Float(max(20, eq.highPassHz))
        hp.bypass = eq.highPassHz < 20
        masterEQ.bypass = !eq.enabled
    }

    func setEQ(_ change: (inout MasterEQ) -> Void) {
        var eq = store.show.audioSettings.eq ?? MasterEQ()
        change(&eq)
        store.show.audioSettings.eq = eq
        applyEQ()
    }

    func setEQPreset(_ name: String) {
        guard let p = MasterEQ.presets.first(where: { $0.name == name }) else { return }
        setEQ { $0.gains = p.gains; $0.highPassHz = p.hp; $0.preset = p.name; $0.enabled = true }
    }

    private func handleConfigurationChange() {
        // Interface unplugged / sample rate changed. Restart and rewire the vocal rack.
        status = "Audio configuration changed — restarting engine"
        refreshDevices()
        for id in Array(playbacks.keys) {
            stop(instanceID: id, notify: false)
            onInstanceRemoved?(id)
        }
        if store.show.vocalRack.enabled { rebuildVocalGraph() } else { startEngine() }
    }

    // MARK: Playback

    /// Starts an audio cue. Returns the playback duration in seconds, or nil if the file can't be read.
    func play(cue: Cue, instanceID: UUID, completion: @escaping () -> Void) -> Double? {
        guard let path = cue.audioPath else { return nil }
        let url = URL(fileURLWithPath: path)
        // Video files play their extracted soundtrack (prepared in the background when the cue was added).
        let playable = MediaSupport.isVideo(url) ? (MediaSupport.readyAudio(for: url) ?? url) : url
        guard let file = try? AVAudioFile(forReading: playable) else {
            if MediaSupport.isVideo(url) { MediaSupport.prepare(url) }
            return nil
        }

        let pb = Playback(file: file)
        pb.completion = completion
        engine.attach(pb.player)
        engine.attach(pb.mixer)
        engine.connect(pb.player, to: pb.mixer, format: file.processingFormat)
        engine.connect(pb.mixer, to: engine.mainMixerNode, format: nil)

        let target = Self.linear(cue.gainDB)
        pb.mixer.outputVolume = cue.fadeIn > 0 ? 0 : target

        let sampleRate = file.processingFormat.sampleRate
        let startFrame = max(0, min(AVAudioFramePosition(cue.startOffset * sampleRate), file.length - 1))
        let frameCount = AVAudioFrameCount(max(0, file.length - startFrame))
        let duration = Double(frameCount) / sampleRate

        if cue.loop {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
            do {
                file.framePosition = 0
                try file.read(into: buffer)
            } catch { return nil }
            pb.player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        } else {
            pb.player.scheduleSegment(file, startingFrame: startFrame, frameCount: frameCount, at: nil,
                                      completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
                Task { @MainActor in self?.playbackEnded(instanceID) }
            }
        }

        playbacks[instanceID] = pb
        startEngine()
        pb.player.play()
        if cue.fadeIn > 0 { ramp(instanceID, to: target, over: cue.fadeIn, stopAtEnd: false) }
        return duration
    }

    private func playbackEnded(_ id: UUID) {
        guard let pb = playbacks.removeValue(forKey: id) else { return }
        pb.fadeTimer?.invalidate()
        teardown(pb)
        pb.completion?()
    }

    func fadeAndStop(instanceID: UUID, duration: Double) {
        guard playbacks[instanceID] != nil else { return }
        if duration <= 0 { stop(instanceID: instanceID, notify: true); return }
        ramp(instanceID, to: 0, over: duration, stopAtEnd: true)
    }

    func fadeAndStopAll(duration: Double) {
        for id in Array(playbacks.keys) { fadeAndStop(instanceID: id, duration: duration) }
    }

    func stopAll() {
        for id in Array(playbacks.keys) { stop(instanceID: id, notify: false) }
    }

    func isPlaying(_ instanceID: UUID) -> Bool { playbacks[instanceID] != nil }

    private func stop(instanceID: UUID, notify: Bool) {
        guard let pb = playbacks.removeValue(forKey: instanceID) else { return }
        pb.fadeTimer?.invalidate()
        pb.player.stop()
        teardown(pb)
        if notify { pb.completion?() }
    }

    private func teardown(_ pb: Playback) {
        engine.disconnectNodeOutput(pb.player)
        engine.disconnectNodeOutput(pb.mixer)
        engine.detach(pb.player)
        engine.detach(pb.mixer)
    }

    /// Equal-power ramp of a playback's volume.
    private func ramp(_ id: UUID, to target: Float, over seconds: Double, stopAtEnd: Bool) {
        guard let pb = playbacks[id] else { return }
        pb.fadeTimer?.invalidate()
        let from = pb.mixer.outputVolume
        let start = Date()
        pb.fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, let pb = self.playbacks[id] else { timer.invalidate(); return }
                let t = min(1, Date().timeIntervalSince(start) / max(seconds, 0.001))
                let curve: Float
                if target >= from {
                    curve = Float(sin(t * .pi / 2))
                    pb.mixer.outputVolume = from + (target - from) * curve
                } else {
                    curve = Float(cos(t * .pi / 2))
                    pb.mixer.outputVolume = target + (from - target) * curve
                }
                if t >= 1 {
                    timer.invalidate()
                    if stopAtEnd { self.stop(instanceID: id, notify: true) }
                }
            }
        }
        if let t = pb.fadeTimer { RunLoop.main.add(t, forMode: .common) }
    }

    // MARK: Metering

    private func installMeters() {
        guard !meterTapsInstalled else { return }
        meterTapsInstalled = true
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2048, format: nil,
                                        block: Self.meterTap { [weak self] level in
            Task { @MainActor in self?.outputLevel = level }
        })
    }

    /// Built outside the main actor so the tap block (called on the audio thread) isn't main-actor isolated.
    nonisolated private static func meterTap(_ report: @escaping @Sendable (Float) -> Void) -> AVAudioNodeTapBlock {
        return { buffer, _ in report(Self.peak(buffer)) }
    }

    nonisolated private static func peak(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        var peak: Float = 0
        let frames = Int(buffer.frameLength)
        for ch in 0..<Int(buffer.format.channelCount) {
            let samples = data[ch]
            var i = 0
            while i < frames {
                peak = max(peak, abs(samples[i]))
                i += 4
            }
        }
        return peak
    }

    // MARK: Vocal rack — plugin discovery

    func refreshPluginList() {
        let manager = AVAudioUnitComponentManager.shared()
        var list: [AVAudioUnitComponent] = []
        for type in [kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
            let desc = AudioComponentDescription(componentType: type, componentSubType: 0,
                                                 componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
            list += manager.components(matching: desc)
        }
        availablePlugins = list.sorted {
            ($0.manufacturerName, $0.name) < ($1.manufacturerName, $1.name)
        }
    }

    func requestMicAccess() {
        AVCaptureDevice.requestAccess(for: .audio) { @Sendable [weak self] granted in
            Task { @MainActor in
                self?.micPermission = granted ? .authorized : .denied
                if granted, self?.store.show.vocalRack.enabled == true { self?.loadVocalRack() }
            }
        }
    }

    // MARK: Vocal rack — building

    func addPlugin(_ component: AVAudioUnitComponent) {
        let d = component.audioComponentDescription
        let slot = PluginSlot(name: component.name, manufacturer: component.manufacturerName,
                              componentType: d.componentType, componentSubType: d.componentSubType,
                              componentManufacturer: d.componentManufacturer)
        store.show.vocalRack.plugins.append(slot)
        loadVocalRack()
    }

    func removePlugin(_ slotID: UUID) {
        captureVocalStates()
        pluginWindows[slotID]?.close()
        pluginWindows[slotID] = nil
        tearDownVocalGraph()
        if let unit = vocalUnits[slotID], unit.engine != nil { engine.detach(unit) }
        store.show.vocalRack.plugins.removeAll { $0.id == slotID }
        vocalUnits[slotID] = nil
        loadedPluginIDs = Set(vocalUnits.keys)
        loadVocalRack()
    }

    func movePlugin(from source: IndexSet, to destination: Int) {
        captureVocalStates()
        store.show.vocalRack.plugins.move(fromOffsets: source, toOffset: destination)
        rebuildVocalGraph()
    }

    func setVocalEnabled(_ enabled: Bool) {
        store.show.vocalRack.enabled = enabled
        if enabled {
            if micPermission != .authorized { requestMicAccess(); return }
            applyDeviceSettings()
            loadVocalRack()
        } else {
            captureVocalStates()
            tearDownVocalGraph()
            startEngine()
        }
    }

    func setVocalInputChannel(_ channel: Int) {
        store.show.vocalRack.inputChannel = channel
        if store.show.vocalRack.enabled { rebuildVocalGraph() }
    }

    func setVocalGain(_ db: Double) {
        store.show.vocalRack.gainDB = db
        vocalOut.outputVolume = Self.linear(db)
    }

    /// Instantiates any plugins not yet loaded (restoring saved state), then wires the graph.
    func loadVocalRack() {
        let slots = store.show.vocalRack.plugins
        let missing = slots.filter { vocalUnits[$0.id] == nil }
        guard !missing.isEmpty else { rebuildVocalGraph(); return }
        status = "Loading \(missing.count) plugin(s)…"
        Task { @MainActor in
            for slot in missing {
                let desc = AudioComponentDescription(componentType: slot.componentType,
                                                     componentSubType: slot.componentSubType,
                                                     componentManufacturer: slot.componentManufacturer,
                                                     componentFlags: 0, componentFlagsMask: 0)
                do {
                    let unit = try await AVAudioUnit.instantiate(with: desc, options: [])
                    if let state = slot.state, let dict = Self.decodeState(state) {
                        unit.auAudioUnit.fullState = dict
                    }
                    vocalUnits[slot.id] = unit
                } catch {
                    status = "Couldn't load \(slot.name): \(error.localizedDescription)"
                }
            }
            loadedPluginIDs = Set(vocalUnits.keys)
            rebuildVocalGraph()
        }
    }

    private func tearDownVocalGraph() {
        guard vocalWired else { return }
        engine.pause()   // pause (not stop) so tracks that are playing resume after rewiring
        vocalIn.removeTap(onBus: 0)
        engine.disconnectNodeInput(vocalIn)
        engine.disconnectNodeOutput(vocalIn)
        for unit in vocalUnits.values {
            engine.disconnectNodeOutput(unit)
            if unit.engine != nil { engine.detach(unit) }
        }
        engine.disconnectNodeOutput(vocalOut)
        vocalWired = false
        vocalLevel = 0
    }

    /// input → vocalIn → plugin 1 → plugin 2 … → vocalOut → main mixer
    func rebuildVocalGraph() {
        tearDownVocalGraph()
        if engine.isRunning { engine.pause() }   // never rewire the input node on a running engine
        let rack = store.show.vocalRack
        guard rack.enabled, micPermission == .authorized else { startEngine(); return }

        let input = engine.inputNode
        let hwFormat = input.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            status = "No audio input available — check the input device."
            startEngine()
            return
        }
        let clientChannels = Int(input.outputFormat(forBus: 0).channelCount)
        let mapped = CoreAudioDevices.setInputChannelMap(input.audioUnit, hardwareChannel: rack.inputChannel,
                                                         clientChannels: clientChannels)
        let inFormat = input.outputFormat(forBus: 0)
        guard let chainFormat = AVAudioFormat(standardFormatWithSampleRate: inFormat.sampleRate,
                                              channels: min(2, max(1, inFormat.channelCount))) else { return }

        engine.connect(input, to: vocalIn, format: inFormat)
        var previous: AVAudioNode = vocalIn
        for slot in rack.plugins {
            guard let unit = vocalUnits[slot.id] else { continue }
            if unit.engine == nil { engine.attach(unit) }
            engine.connect(previous, to: unit, format: chainFormat)
            unit.auAudioUnit.shouldBypassEffect = rack.bypassAll || slot.bypassed
            previous = unit
        }
        engine.connect(previous, to: vocalOut, format: chainFormat)
        engine.connect(vocalOut, to: engine.mainMixerNode, format: chainFormat)
        vocalOut.outputVolume = Self.linear(rack.gainDB)

        vocalIn.installTap(onBus: 0, bufferSize: 1024, format: nil,
                           block: Self.meterTap { [weak self] level in
            Task { @MainActor in self?.vocalLevel = level }
        })
        vocalWired = true
        startEngine()
        let chain = rack.plugins.map(\.name).joined(separator: " → ")
        status = "Vocal rack live on input \(rack.inputChannel + 1)\(mapped ? "" : " (channel map not applied)")"
            + (chain.isEmpty ? " · no plugins" : " · \(chain)")
    }

    // MARK: Vocal rack — bypass, state, presets

    func setVocalBypass(_ bypass: Bool) {
        store.show.vocalRack.bypassAll = bypass
        applyBypass()
    }

    func setSlotBypass(_ slotID: UUID, _ bypass: Bool) {
        guard let i = store.show.vocalRack.plugins.firstIndex(where: { $0.id == slotID }) else { return }
        store.show.vocalRack.plugins[i].bypassed = bypass
        applyBypass()
    }

    private func applyBypass() {
        let rack = store.show.vocalRack
        for slot in rack.plugins {
            vocalUnits[slot.id]?.auAudioUnit.shouldBypassEffect = rack.bypassAll || slot.bypassed
        }
    }

    /// Writes every loaded plugin's current settings into the show (called before save).
    func captureVocalStates() {
        for i in store.show.vocalRack.plugins.indices {
            let slot = store.show.vocalRack.plugins[i]
            if let unit = vocalUnits[slot.id], let state = unit.auAudioUnit.fullState, let data = Self.encodeState(state) {
                if store.show.vocalRack.plugins[i].state != data { store.show.vocalRack.plugins[i].state = data }
            }
        }
    }

    func savePreset(named name: String) {
        var preset = VocalPreset(name: name)
        for slot in store.show.vocalRack.plugins {
            if let unit = vocalUnits[slot.id], let state = unit.auAudioUnit.fullState, let data = Self.encodeState(state) {
                preset.states[slot.id.uuidString] = data
            }
            preset.bypassed[slot.id.uuidString] = slot.bypassed
        }
        store.show.vocalRack.presets.append(preset)
    }

    func applyVocalPreset(_ presetID: UUID) {
        guard let preset = store.show.vocalRack.presets.first(where: { $0.id == presetID }) else { return }
        for i in store.show.vocalRack.plugins.indices {
            let slot = store.show.vocalRack.plugins[i]
            if let data = preset.states[slot.id.uuidString], let dict = Self.decodeState(data) {
                vocalUnits[slot.id]?.auAudioUnit.fullState = dict
            }
            if let b = preset.bypassed[slot.id.uuidString] { store.show.vocalRack.plugins[i].bypassed = b }
        }
        applyBypass()
    }

    // MARK: Plugin windows

    func openPluginWindow(_ slotID: UUID) {
        if let existing = pluginWindows[slotID] { existing.makeKeyAndOrderFront(nil); return }
        guard let unit = vocalUnits[slotID],
              let slot = store.show.vocalRack.plugins.first(where: { $0.id == slotID }) else { return }
        unit.auAudioUnit.requestViewController { @Sendable [weak self] controller in
            Task { @MainActor in
                guard let self else { return }
                let vc: NSViewController
                if let controller {
                    vc = controller
                } else {
                    // Plugin has no custom UI — fall back to Apple's generic parameter view.
                    let generic = NSViewController()
                    generic.view = AUGenericView(audioUnit: unit.audioUnit)
                    vc = generic
                }
                let window = NSWindow(contentViewController: vc)
                window.isReleasedWhenClosed = false
                window.title = "\(slot.name) — \(slot.manufacturer)"
                let size = vc.preferredContentSize
                if size.width > 10, size.height > 10 { window.setContentSize(size) }
                window.makeKeyAndOrderFront(nil)
                self.pluginWindows[slotID] = window
            }
        }
    }

    // MARK: Utilities

    nonisolated static func linear(_ db: Double) -> Float {
        db <= -60 ? 0 : Float(pow(10, db / 20))
    }

    nonisolated static func encodeState(_ state: [String: Any]) -> Data? {
        try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
    }

    nonisolated static func decodeState(_ data: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }
}
