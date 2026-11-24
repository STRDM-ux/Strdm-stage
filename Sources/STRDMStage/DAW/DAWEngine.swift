import Foundation
import AVFoundation
import AudioToolbox
import AppKit
import Combine
import CoreAudioKit
import os

/// The Studio: a multitrack DAW that runs on its own audio engine next to the show engine.
@MainActor
final class DAWEngine: ObservableObject {
    // MARK: Published UI state
    @Published private(set) var isPlaying = false
    @Published private(set) var isRecording = false
    @Published private(set) var isBuilding = false
    @Published private(set) var isExporting = false
    @Published var playhead: Double = 0                 // beats (when stopped)
    @Published var selectedTrackID: UUID? = nil
    @Published var selectedClipID: UUID? = nil
    @Published private(set) var levels: [UUID: Float] = [:]
    @Published private(set) var masterLevel: Float = 0
    @Published var status = "Studio ready"
    @Published private(set) var lastLUFS: Double? = nil
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var instrumentComponents: [AVAudioUnitComponent] = []
    @Published private(set) var effectComponents: [AVAudioUnitComponent] = []

    /// Called after "Export to Show" writes a file (the app adds a cue + builds its light show).
    var onExportToShow: ((URL, String) -> Void)?

    let engine = AVAudioEngine()
    let rt = DAWRealtime()
    private lazy var scheduler = MIDIScheduler(rt: rt)
    private let store: ShowStore
    private let audioCache = DAWAudioCache()
    private var cancellables = Set<AnyCancellable>()

    // Graph
    private struct TrackNodes {
        let source: AVAudioNode
        let instrument: AVAudioUnit?
        let effects: [AVAudioUnit]
        let fader: AVAudioMixerNode
        let sends: [(node: AVAudioMixerNode, bus: Int)]
        let clips: OSAllocatedUnfairLock<[ClipRender]>?
    }
    private var trackNodes: [UUID: TrackNodes] = [:]
    private var busFaders: [AVAudioMixerNode] = []
    private var masterFader = AVAudioMixerNode()
    private var attached: [AVAudioNode] = []
    private var effectUnits: [UUID: AVAudioUnit] = [:]
    private var instrumentUnits: [UUID: (signature: String, unit: AVAudioUnit)] = [:]
    private var structure = ""
    private var format: AVAudioFormat!
    private var uiTimer: Timer?
    private var anchorSeconds = 0.0
    private var pluginWindows: [String: NSWindow] = [:]

    // Undo
    private var undoStack: [DAWProject] = []
    private var redoStack: [DAWProject] = []
    private var lastUndoPush = Date.distantPast

    // Recording
    private final class Recorder: @unchecked Sendable {
        let trackID: UUID
        let channel: Int
        let file: AVAudioFile
        let url: URL
        init(trackID: UUID, channel: Int, file: AVAudioFile, url: URL) {
            self.trackID = trackID; self.channel = channel; self.file = file; self.url = url
        }
    }
    private var recorders: [Recorder] = []
    private let firstInputHost = OSAllocatedUnfairLock<UInt64?>(initialState: nil)
    private var recordStartBeat = 0.0
    private var inputReady = false
    private var liveNotes: [UInt8: (start: Double, velocity: UInt8)] = [:]
    private var recordedNotes: [MIDINote] = []
    private var recordingMIDITrack: UUID?

    var project: DAWProject { store.show.daw }

    init(store: ShowStore) {
        self.store = store
        InstrumentRegistry.registerAll()
        refreshComponents()
        scheduler.start()
        store.$show
            .map(\.daw)
            .removeDuplicates()
            .sink { [weak self] daw in
                Task { @MainActor in self?.projectDidChange(daw) }
            }
            .store(in: &cancellables)
        uiTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.uiTick() }
        }
        if let t = uiTimer { RunLoop.main.add(t, forMode: .common) }
        Task { await rebuildGraph() }
    }

    var sampleRate: Double { format?.sampleRate ?? 48_000 }
    var samplesPerBeat: Double { sampleRate * 60 / max(20, project.bpm) }
    var secondsPerBeat: Double { 60 / max(20, project.bpm) }

    // MARK: - Editing with undo

    /// All Studio edits go through here so they can be undone.
    func edit(_ change: (inout DAWProject) -> Void) {
        let before = store.show.daw
        var p = before
        change(&p)
        guard p != before else { return }
        if Date().timeIntervalSince(lastUndoPush) > 0.4 {
            undoStack.append(before)
            if undoStack.count > 200 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        lastUndoPush = Date()
        store.show.daw = p
        canUndo = !undoStack.isEmpty
        canRedo = false
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(store.show.daw)
        store.show.daw = prev
        lastUndoPush = .distantPast
        canUndo = !undoStack.isEmpty
        canRedo = true
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(store.show.daw)
        store.show.daw = next
        lastUndoPush = .distantPast
        canUndo = true
        canRedo = !redoStack.isEmpty
    }

    // MARK: - Project changes

    private func structuralSignature(_ p: DAWProject) -> String {
        var parts: [String] = []
        for t in p.tracks {
            var inst = "-"
            switch t.instrument {
            case .synth?: inst = "synth"
            case .drumMachine?: inst = "drums"
            case .generalMIDI(let prog)?: inst = "gm\(prog)"
            case .sampler(let path)?: inst = "smp\(path)"
            case .audioUnit(let slot)?: inst = "au\(slot.id)"
            case nil: inst = "none"
            }
            parts.append("\(t.id)|\(t.kind.rawValue)|\(inst)|\(t.effects.map(\.id.uuidString).joined(separator: ","))|\(t.sends.map { String($0.busIndex) }.joined(separator: ","))")
        }
        for b in p.buses { parts.append("bus\(b.id)|\(b.effects.map(\.id.uuidString).joined(separator: ","))") }
        parts.append("master|\(p.master.effects.map(\.id.uuidString).joined(separator: ","))")
        return parts.joined(separator: "\n")
    }

    private func projectDidChange(_ p: DAWProject) {
        if structuralSignature(p) != structure {
            Task { await rebuildGraph() }
        } else {
            applyLiveSettings()
            updateSnapshots()
            applyMix()
        }
    }

    // MARK: - Graph

    func rebuildGraph() async {
        guard !isBuilding else { return }
        isBuilding = true
        defer { isBuilding = false }
        let wasPlaying = isPlaying
        if wasPlaying { stop() }
        captureStates()

        engine.stop()
        for n in attached {
            engine.disconnectNodeOutput(n)
            engine.detach(n)
        }
        attached.removeAll()
        trackNodes.removeAll()
        busFaders.removeAll()

        // Output device follows the show's interface choice.
        let settings = store.show.audioSettings
        if let id = CoreAudioDevices.device(uid: settings.outputDeviceUID)?.id ?? CoreAudioDevices.defaultDevice(input: false) {
            CoreAudioDevices.setCurrentDevice(engine.outputNode.audioUnit, id)
        }
        let outRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        format = AVAudioFormat(standardFormatWithSampleRate: outRate > 0 ? outRate : 48_000, channels: 2)
        let fmt = format!

        let p = project
        structure = structuralSignature(p)

        func attach(_ n: AVAudioNode) { engine.attach(n); attached.append(n) }

        // Master: sum → master effects → master fader → hardware
        let sum = AVAudioMixerNode()
        attach(sum)
        var masterChain: [AVAudioNode] = [sum]
        for slot in p.master.effects {
            if let u = await effectUnit(slot) { attach(u); masterChain.append(u) }
        }
        masterFader = AVAudioMixerNode()
        attach(masterFader)
        masterChain.append(masterFader)
        for i in 0..<(masterChain.count - 1) { engine.connect(masterChain[i], to: masterChain[i + 1], format: fmt) }
        engine.connect(masterFader, to: engine.mainMixerNode, format: fmt)
        masterFader.installTap(onBus: 0, bufferSize: 1024, format: nil, block: rt.meterTap(Self.masterMeterID))

        // Buses
        var busInputs: [AVAudioMixerNode] = []
        for bus in p.buses {
            let input = AVAudioMixerNode()
            attach(input)
            var chain: [AVAudioNode] = [input]
            for slot in bus.effects { if let u = await effectUnit(slot) { attach(u); chain.append(u) } }
            let fader = AVAudioMixerNode()
            attach(fader)
            chain.append(fader)
            for i in 0..<(chain.count - 1) { engine.connect(chain[i], to: chain[i + 1], format: fmt) }
            engine.connect(fader, to: sum, fromBus: 0, toBus: sum.nextAvailableInputBus, format: fmt)
            busInputs.append(input)
            busFaders.append(fader)
        }

        // Tracks
        for track in p.tracks {
            var source: AVAudioNode
            var instrument: AVAudioUnit?
            var clipLock: OSAllocatedUnfairLock<[ClipRender]>?
            if track.kind == .audio {
                let (node, lock) = rt.makeAudioTrackNode(format: fmt)
                source = node
                clipLock = lock
                attach(node)
            } else {
                guard let unit = await instrumentUnit(for: track) else { continue }
                instrument = unit
                source = unit
                attach(unit)
                configureInstrumentAfterAttach(unit, track: track)
            }
            var chain: [AVAudioNode] = [source]
            var effects: [AVAudioUnit] = []
            for slot in track.effects {
                if let u = await effectUnit(slot) { attach(u); chain.append(u); effects.append(u) }
            }
            let fader = AVAudioMixerNode()
            attach(fader)
            chain.append(fader)
            for i in 0..<(chain.count - 1) { engine.connect(chain[i], to: chain[i + 1], format: fmt) }

            var points = [AVAudioConnectionPoint(node: sum, bus: sum.nextAvailableInputBus)]
            var sends: [(node: AVAudioMixerNode, bus: Int)] = []
            for send in track.sends where send.busIndex >= 0 && send.busIndex < busInputs.count {
                let s = AVAudioMixerNode()
                attach(s)
                points.append(AVAudioConnectionPoint(node: s, bus: 0))
                sends.append((s, send.busIndex))
            }
            engine.connect(fader, to: points, fromBus: 0, format: fmt)
            for s in sends {
                let busIn = busInputs[s.bus]
                engine.connect(s.node, to: busIn, fromBus: 0, toBus: busIn.nextAvailableInputBus, format: fmt)
            }
            fader.installTap(onBus: 0, bufferSize: 1024, format: nil, block: rt.meterTap(track.id))
            trackNodes[track.id] = TrackNodes(source: source, instrument: instrument, effects: effects,
                                              fader: fader, sends: sends, clips: clipLock)
        }

        // Metronome (straight to hardware, never in exports)
        let click = rt.makeMetronome(format: fmt)
        attach(click)
        engine.connect(click, to: engine.mainMixerNode, format: fmt)

        rt.transport.withLock { t in
            t.sampleRate = fmt.sampleRate
            t.samplesPerBeat = fmt.sampleRate * 60 / max(20, p.bpm)
        }
        updateSnapshots()
        applyLiveSettings()
        applyMix()
        engine.prepare()
        do {
            try engine.start()
            status = "Studio ready · \(Int(fmt.sampleRate)) Hz · \(p.tracks.count) tracks"
        } catch {
            status = "Studio audio failed to start: \(error.localizedDescription)"
        }
    }

    static let masterMeterID = UUID(uuidString: "00000000-0000-0000-0000-00000000AAAA")!

    private func effectUnit(_ slot: EffectSlot) async -> AVAudioUnit? {
        if let u = effectUnits[slot.id] { u.auAudioUnit.shouldBypassEffect = slot.bypassed; return u }
        let desc = AudioComponentDescription(componentType: slot.componentType, componentSubType: slot.componentSubType,
                                             componentManufacturer: slot.componentManufacturer, componentFlags: 0, componentFlagsMask: 0)
        guard let unit = try? await AVAudioUnit.instantiate(with: desc, options: []) else {
            status = "Couldn't load \(slot.name)"
            return nil
        }
        if let data = slot.state, let dict = AudioEngine.decodeState(data) { unit.auAudioUnit.fullState = dict }
        unit.auAudioUnit.shouldBypassEffect = slot.bypassed
        effectUnits[slot.id] = unit
        return unit
    }

    private func instrumentSignature(_ t: DAWTrack) -> String {
        switch t.instrument {
        case .synth?: return "synth"
        case .drumMachine?: return "drums"
        case .generalMIDI(let p)?: return "gm\(p)"
        case .sampler(let path)?: return "smp\(path)"
        case .audioUnit(let s)?: return "au\(s.id)"
        case nil: return "synth"
        }
    }

    private func instrumentUnit(for track: DAWTrack) async -> AVAudioUnit? {
        let sig = instrumentSignature(track)
        if let cached = instrumentUnits[track.id], cached.signature == sig { return cached.unit }
        var unit: AVAudioUnit?
        switch track.instrument ?? .synth(preset: "Sub Bass") {
        case .synth:
            unit = try? await AVAudioUnit.instantiate(with: STRDMSynthAU.description, options: [])
        case .drumMachine:
            unit = try? await AVAudioUnit.instantiate(with: STRDMDrumAU.description, options: [])
        case .generalMIDI, .sampler:
            unit = AVAudioUnitSampler()
        case .audioUnit(let slot):
            let desc = AudioComponentDescription(componentType: slot.componentType, componentSubType: slot.componentSubType,
                                                 componentManufacturer: slot.componentManufacturer, componentFlags: 0, componentFlagsMask: 0)
            unit = try? await AVAudioUnit.instantiate(with: desc, options: [])
            if let u = unit, let data = slot.state, let dict = AudioEngine.decodeState(data) { u.auAudioUnit.fullState = dict }
        }
        guard let u = unit else { status = "Couldn't load the instrument for \(track.name)"; return nil }
        instrumentUnits[track.id] = (sig, u)
        return u
    }

    /// Samplers load their sounds once attached to the engine.
    private func configureInstrumentAfterAttach(_ unit: AVAudioUnit, track: DAWTrack) {
        guard let sampler = unit as? AVAudioUnitSampler else { return }
        switch track.instrument {
        case .generalMIDI(let program)?:
            try? sampler.loadSoundBankInstrument(at: InstrumentRegistry.gmSoundBank, program: UInt8(max(0, min(127, program))),
                                                 bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB), bankLSB: UInt8(kAUSampler_DefaultBankLSB))
        case .sampler(let path)?:
            try? sampler.loadAudioFiles(at: [URL(fileURLWithPath: path)])
        default: break
        }
    }

    /// Non-structural instrument changes: synth preset, drum kit, custom pads.
    private func applyLiveSettings() {
        for track in project.tracks {
            guard let unit = trackNodes[track.id]?.instrument else { continue }
            switch track.instrument {
            case .synth(let preset)?:
                (unit.auAudioUnit as? STRDMSynthAU)?.synth.setPreset(SynthPreset.named(preset))
            case .drumMachine(let kit)?:
                guard let drums = (unit.auAudioUnit as? STRDMDrumAU)?.drums else { break }
                let key = "\(kit)|\(track.padSamples.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))"
                if drumKeys[track.id] != key {
                    drumKeys[track.id] = key
                    var custom: [Int: [Float]] = [:]
                    for (note, path) in track.padSamples {
                        if let s = DrumSynth.loadMono(URL(fileURLWithPath: path), sampleRate: sampleRate) { custom[note] = s }
                    }
                    drums.load(kit: kit, custom: custom, sampleRate: sampleRate)
                }
            default: break
            }
            for slot in track.effects { effectUnits[slot.id]?.auAudioUnit.shouldBypassEffect = slot.bypassed }
        }
        for bus in project.buses { for slot in bus.effects { effectUnits[slot.id]?.auAudioUnit.shouldBypassEffect = slot.bypassed } }
        for slot in project.master.effects { effectUnits[slot.id]?.auAudioUnit.shouldBypassEffect = slot.bypassed }
    }
    private var drumKeys: [UUID: String] = [:]

    /// Pushes clip lists and note lists to the realtime side.
    private func updateSnapshots() {
        let p = project
        let sr = sampleRate
        var sched: [SchedTrack] = []
        for track in p.tracks {
            guard let nodes = trackNodes[track.id] else { continue }
            if track.kind == .audio, let lock = nodes.clips {
                var list: [ClipRender] = []
                for c in track.audioClips {
                    guard let data = audioCache.data(path: c.path, sampleRate: sr, onLoad: { [weak self] in self?.updateSnapshots() }) else { continue }
                    list.append(ClipRender(data: data, startBeat: c.start, endBeat: c.start + c.length,
                                           offsetFrames: c.fileOffset * sr, gain: AudioEngine.linear(c.gainDB),
                                           fadeIn: c.fadeIn, fadeOut: c.fadeOut))
                }
                lock.withLock { $0 = list }
            } else if let inst = nodes.instrument, let block = inst.auAudioUnit.scheduleMIDIEventBlock {
                var notes: [SchedNote] = []
                for clip in track.midiClips {
                    for n in clip.notes where n.start < clip.length {
                        let len = min(n.length, clip.length - n.start)
                        notes.append(SchedNote(start: clip.start + n.start, length: max(0.01, len),
                                               pitch: UInt8(max(0, min(127, n.pitch))), velocity: UInt8(max(1, min(127, n.velocity)))))
                    }
                }
                notes.sort { $0.start < $1.start }
                sched.append(SchedTrack(block: block, notes: notes))
            }
        }
        scheduler.tracks.withLock { $0 = sched }
        let recording = isRecording
        rt.transport.withLock { t in
            t.samplesPerBeat = sr * 60 / max(20, p.bpm)
            t.loopOn = p.loopEnabled && !recording
            t.loopStart = p.loopStart
            t.loopEnd = max(p.loopStart + 0.25, p.loopEnd)
            t.metronome = p.metronome
            t.beatsPerBar = p.beatsPerBar
        }
    }

    /// Volumes, pans, mutes/solos, sends, bus and master levels.
    func applyMix(exportSolo: UUID? = nil) {
        let p = project
        let anySolo = p.tracks.contains { $0.solo }
        let beat = isPlaying ? currentBeat() : playhead
        for track in p.tracks {
            guard let nodes = trackNodes[track.id] else { continue }
            var db = track.volumeDB
            var pan = track.pan
            if isPlaying {
                for lane in track.automation where lane.enabled {
                    guard let v = lane.value(at: beat) else { continue }
                    if lane.target == .volume { db = -60 + v * 66 }
                    if lane.target == .pan { pan = v * 2 - 1 }
                }
            }
            var audible = !track.mute && (!anySolo || track.solo)
            if let exportSolo { audible = track.id == exportSolo }
            nodes.fader.outputVolume = audible ? AudioEngine.linear(db) : 0
            nodes.fader.pan = Float(max(-1, min(1, pan)))
            for (i, s) in nodes.sends.enumerated() where i < track.sends.count {
                s.node.outputVolume = AudioEngine.linear(track.sends[i].levelDB)
            }
        }
        for (i, f) in busFaders.enumerated() where i < p.buses.count {
            f.outputVolume = p.buses[i].mute ? 0 : AudioEngine.linear(p.buses[i].volumeDB)
        }
        masterFader.outputVolume = AudioEngine.linear(p.master.volumeDB)
    }

    // MARK: - Transport

    func togglePlay() { isPlaying ? stop() : play() }

    func play(from beat: Double? = nil, clickUntil: Double = -1) {
        if !engine.isRunning { try? engine.start() }
        guard let last = engine.outputNode.lastRenderTime, last.isSampleTimeValid, last.isHostTimeValid else {
            status = "Audio not running yet — try again"
            return
        }
        let start = max(0, beat ?? playhead)
        let preroll = 0.08 * sampleRate
        let anchor = Double(last.sampleTime) + preroll
        anchorSeconds = AVAudioTime.seconds(forHostTime: last.hostTime) + preroll / sampleRate
        updateSnapshots()
        scheduler.reset(from: anchor)
        rt.transport.withLock { t in
            t.playing = true
            t.anchorSample = anchor
            t.startBeat = start
            t.clickUntilBeat = clickUntil
        }
        isPlaying = true
    }

    func stop() {
        let wasPlaying = isPlaying
        if isRecording { finishRecording() }
        if wasPlaying { playhead = max(0, currentBeat()) }
        rt.transport.withLock { $0.playing = false }
        scheduler.allNotesOff()
        let now = rt.clock.withLock { $0 }
        scheduler.allNotesOff(at: AUEventSampleTime(now + 0.2 * sampleRate))
        isPlaying = false
        applyMix()
    }

    func returnToStart() {
        let wasPlaying = isPlaying
        if wasPlaying { stop() }
        playhead = project.loopEnabled ? project.loopStart : 0
        if wasPlaying { play() }
    }

    func seek(to beat: Double) {
        let wasPlaying = isPlaying
        if wasPlaying { stop() }
        playhead = max(0, beat)
        if wasPlaying { play() }
    }

    /// Current musical position, from the host clock while playing.
    func currentBeat() -> Double {
        let t = rt.transport.withLock { $0 }
        guard t.playing else { return playhead }
        let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        let sample = t.anchorSample + (now - anchorSeconds) * t.sampleRate
        return t.beat(at: sample) ?? t.startBeat
    }

    private func uiTick() {
        // meters at ~15 Hz
        let m = rt.meters.withLock { d -> [UUID: Float] in
            let copy = d
            for k in d.keys { d[k] = (d[k] ?? 0) * 0.6 }
            return copy
        }
        // Only publish when a meter actually moves — every @Published write redraws every Studio view.
        func q(_ v: Float) -> Float { v < 0.002 ? 0 : (v * 200).rounded() / 200 }
        let master = q(m[Self.masterMeterID] ?? 0)
        if master != masterLevel { masterLevel = master }
        var trackLevels = m.mapValues(q)
        trackLevels[Self.masterMeterID] = nil
        if trackLevels != levels { levels = trackLevels }
        if isPlaying {
            if project.tracks.contains(where: { $0.automation.contains { $0.enabled && !$0.points.isEmpty } }) { applyMix() }
        }
    }

    // MARK: - Live MIDI (controllers, typing keyboard, pads)

    var liveTrackID: UUID? {
        if let armed = project.tracks.first(where: { $0.armed && $0.kind == .midi }) { return armed.id }
        if let sel = selectedTrackID, project.tracks.first(where: { $0.id == sel })?.kind == .midi { return sel }
        return project.tracks.first { $0.kind == .midi }?.id
    }

    func liveMIDI(_ status: UInt8, _ d1: UInt8, _ d2: UInt8) {
        guard let id = liveTrackID, let unit = trackNodes[id]?.instrument,
              let block = unit.auAudioUnit.scheduleMIDIEventBlock else { return }
        var bytes: [UInt8] = [status, d1, d2]
        block(AUEventSampleTimeImmediate, 0, 3, &bytes)
        guard isRecording, recordingMIDITrack == id else { return }
        let type = status & 0xF0
        let beat = currentBeat()
        if type == 0x90 && d2 > 0 {
            liveNotes[d1] = (beat, d2)
        } else if type == 0x80 || (type == 0x90 && d2 == 0), let on = liveNotes.removeValue(forKey: d1) {
            recordedNotes.append(MIDINote(pitch: Int(d1), start: on.start, length: max(0.05, beat - on.start), velocity: Int(on.velocity)))
        }
    }

    func audition(pitch: Int, velocity: Int = 110, length: Double = 0.25) {
        liveMIDI(0x90, UInt8(max(0, min(127, pitch))), UInt8(velocity))
        DispatchQueue.main.asyncAfter(deadline: .now() + length) { [weak self] in
            MainActor.assumeIsolated { self?.liveMIDI(0x80, UInt8(max(0, min(127, pitch))), 0) }
        }
    }

    // MARK: - Recording

    func toggleRecord() { isRecording ? stop() : startRecording() }

    func startRecording() {
        let p = project
        let armedAudio = p.tracks.filter { $0.armed && $0.kind == .audio }
        let midiTarget = p.tracks.first { $0.armed && $0.kind == .midi }?.id
            ?? (armedAudio.isEmpty ? liveTrackID : nil)
        guard !armedAudio.isEmpty || midiTarget != nil else {
            status = "Arm a track (R) to record"
            return
        }
        if isPlaying { stop() }
        recordStartBeat = playhead
        recorders.removeAll()
        firstInputHost.withLock { $0 = nil }
        recordedNotes.removeAll()
        liveNotes.removeAll()
        recordingMIDITrack = midiTarget

        if !armedAudio.isEmpty {
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
                status = "Allow microphone access, then press record again"
                return
            }
            if !inputReady {
                engine.stop()
                let settings = store.show.audioSettings
                if let id = CoreAudioDevices.device(uid: settings.inputDeviceUID)?.id ?? CoreAudioDevices.defaultDevice(input: true) {
                    CoreAudioDevices.setCurrentDevice(engine.inputNode.audioUnit, id)
                }
                _ = engine.inputNode
                engine.prepare()
                try? engine.start()
                inputReady = true
            }
            let input = engine.inputNode
            let inFormat = input.outputFormat(forBus: 0)
            guard inFormat.channelCount > 0, inFormat.sampleRate > 0 else { status = "No audio input"; return }
            let folder = Self.mediaFolder()
            for track in armedAudio {
                let stamp = Int(Date().timeIntervalSince1970)
                let url = folder.appendingPathComponent("\(track.name.replacingOccurrences(of: "/", with: "-")) take \(stamp).caf")
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: inFormat.sampleRate,
                                               AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true]
                if let file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false) {
                    recorders.append(Recorder(trackID: track.id, channel: min(track.inputChannel, Int(inFormat.channelCount) - 1), file: file, url: url))
                }
            }
            let recs = recorders
            let firstHost = firstInputHost
            input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { buffer, when in
                let host = when.hostTime
                firstHost.withLock { if $0 == nil { $0 = host } }
                guard let data = buffer.floatChannelData else { return }
                for r in recs {
                    guard let mono = AVAudioPCMBuffer(pcmFormat: r.file.processingFormat, frameCapacity: buffer.frameLength),
                          let dst = mono.floatChannelData else { continue }
                    mono.frameLength = buffer.frameLength
                    dst[0].update(from: data[r.channel], count: Int(buffer.frameLength))
                    try? r.file.write(from: mono)
                }
            }
        }

        isRecording = true
        let countIn = p.countIn ? Double(p.beatsPerBar) : 0
        play(from: max(0, recordStartBeat - countIn), clickUntil: recordStartBeat)
        status = "Recording…"
    }

    private func finishRecording() {
        isRecording = false
        let endBeat = currentBeat()
        if !recorders.isEmpty {
            engine.inputNode.removeTap(onBus: 0)
            let latency = engine.inputNode.presentationLatency + engine.outputNode.presentationLatency
            let firstHost = firstInputHost.withLock { $0 }
            let t = rt.transport.withLock { $0 }
            for r in recorders {
                let frames = Double(r.file.length)
                let sr = r.file.processingFormat.sampleRate
                guard frames > 0 else { continue }
                var startBeat = recordStartBeat
                if let h = firstHost {
                    let secs = AVAudioTime.seconds(forHostTime: h) - anchorSeconds - latency
                    startBeat = t.startBeat + secs / secondsPerBeat
                }
                var offset = 0.0
                if startBeat < recordStartBeat {
                    offset = (recordStartBeat - startBeat) * secondsPerBeat
                    startBeat = recordStartBeat
                }
                let lengthBeats = max(0.25, frames / sr / secondsPerBeat - offset / secondsPerBeat)
                let clip = AudioClip(path: r.url.path, start: startBeat, length: lengthBeats, fileOffset: offset)
                let tid = r.trackID
                edit { p in
                    guard let i = p.tracks.firstIndex(where: { $0.id == tid }) else { return }
                    // Recording over existing audio keeps the old take (Pro Tools-style playlist) instead of layering.
                    let end = clip.start + clip.length
                    let covered = p.tracks[i].audioClips.filter { $0.start < end - 0.01 && $0.start + $0.length > clip.start + 0.01 }
                    if !covered.isEmpty {
                        p.tracks[i].takes = (p.tracks[i].takes ?? []) + covered
                        let ids = Set(covered.map(\.id))
                        p.tracks[i].audioClips.removeAll { ids.contains($0.id) }
                    }
                    p.tracks[i].audioClips.append(clip)
                }
            }
            recorders.removeAll()
        }
        if let tid = recordingMIDITrack {
            for (pitch, on) in liveNotes {
                recordedNotes.append(MIDINote(pitch: Int(pitch), start: on.start, length: max(0.05, endBeat - on.start), velocity: Int(on.velocity)))
            }
            liveNotes.removeAll()
            let notes = recordedNotes.filter { $0.start >= recordStartBeat - 0.1 }
            if !notes.isEmpty {
                let bar = Double(project.beatsPerBar)
                let start = floor(recordStartBeat / bar) * bar
                let end = ceil(max(endBeat, (notes.map { $0.start + $0.length }.max() ?? endBeat)) / bar) * bar
                var clip = MIDIClip(start: start, length: max(bar, end - start), name: "Take")
                clip.notes = notes.map { n in var m = n; m.start = max(0, n.start - start); return m }
                edit { p in
                    if let i = p.tracks.firstIndex(where: { $0.id == tid }) { p.tracks[i].midiClips.append(clip) }
                }
                selectedClipID = clip.id
            }
            recordingMIDITrack = nil
        }
        status = "Recorded"
    }

    static func mediaFolder() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = docs.appendingPathComponent("STRDM Stage Shows/Studio Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Export / bounce

    enum ExportFormat: String, CaseIterable, Identifiable {
        case wav, m4a
        var id: String { rawValue }
        var label: String { self == .wav ? "WAV 24-bit" : "AAC (.m4a)" }
    }

    /// Renders offline (faster than real time) to a file.
    func bounce(to url: URL, from startBeat: Double, to endBeat: Double, solo: UUID? = nil,
                format exportFormat: ExportFormat = .wav, tail: Double = 2) throws {
        let wasPlaying = isPlaying
        if wasPlaying { stop() }
        let fmt = format!
        let spb = samplesPerBeat
        engine.stop()
        do { try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4096) } catch {
            try? engine.start()
            throw error
        }
        scheduler.suspended.withLock { $0 = true }
        defer {
            scheduler.suspended.withLock { $0 = false }
            engine.stop()
            engine.disableManualRenderingMode()
            rt.transport.withLock { $0.playing = false }
            applyMix()
            try? engine.start()
        }
        applyMix(exportSolo: solo)
        updateSnapshots()
        rt.transport.withLock { t in
            t.playing = true
            t.anchorSample = 0
            t.startBeat = startBeat
            t.loopOn = false
            t.metronome = false
            t.clickUntilBeat = -1
        }
        try engine.start()
        let total = AVAudioFramePosition((endBeat - startBeat) * spb + tail * fmt.sampleRate)
        let settings: [String: Any]
        switch exportFormat {
        case .wav:
            settings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: fmt.sampleRate, AVNumberOfChannelsKey: 2,
                        AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                        AVLinearPCMIsNonInterleaved: false]
        case .m4a:
            settings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: fmt.sampleRate, AVNumberOfChannelsKey: 2,
                        AVEncoderBitRateKey: 320_000]
        }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount) else { return }
        var done: AVAudioFramePosition = 0
        let tState = rt.transport.withLock { $0 }
        while done < total {
            let n = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity), total - done))
            let t0 = Double(engine.manualRenderingSampleTime)
            scheduler.scheduleWindow(from: t0, to: t0 + Double(n), transport: tState)
            let result = try engine.renderOffline(n, to: buffer)
            guard result == .success else { break }
            try file.write(from: buffer)
            done += AVAudioFramePosition(n)
        }
        scheduler.allNotesOff()
    }

    struct ExportResult { let url: URL; let lufs: Double? }

    /// Bounces the mix; optionally auto-masters to the target loudness with the master limiter.
    func exportMix(name: String, loopOnly: Bool, autoMaster: Bool, format: ExportFormat = .wav) async -> ExportResult? {
        guard !isExporting else { return nil }
        isExporting = true
        defer { isExporting = false }
        let p = project
        let start = loopOnly ? p.loopStart : 0
        let end = loopOnly ? p.loopEnd : max(4, p.contentEnd)
        let folder = Self.exportFolder()
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let url = folder.appendingPathComponent("\(safe).\(format.rawValue)")
        do {
            status = "Bouncing…"
            await Task.yield()
            if autoMaster, let limiter = masterLimiter() {
                let probe = folder.appendingPathComponent(".probe-\(UUID().uuidString).wav")
                setLimiterPreGain(limiter, 0)
                try bounce(to: probe, from: start, to: end)
                if let measured = Loudness.integratedLUFS(url: probe) {
                    let gain = max(-6, min(18, p.master.targetLUFS - measured))
                    setLimiterPreGain(limiter, gain)
                    status = String(format: "Mastering: %.1f LUFS → target %.0f (gain %+.1f dB)", measured, p.master.targetLUFS, gain)
                }
                try? FileManager.default.removeItem(at: probe)
            }
            try bounce(to: url, from: start, to: end, format: format)
            let lufs = Loudness.integratedLUFS(url: url)
            lastLUFS = lufs
            status = "Exported \(url.lastPathComponent)" + (lufs.map { String(format: " · %.1f LUFS", $0) } ?? "")
            return ExportResult(url: url, lufs: lufs)
        } catch {
            status = "Export failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// One file per track (solo bounces) into a folder.
    func exportStems(name: String) async -> URL? {
        guard !isExporting else { return nil }
        isExporting = true
        defer { isExporting = false }
        let p = project
        let folder = Self.exportFolder().appendingPathComponent("\(name) Stems", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let end = max(4, p.contentEnd)
        for (i, track) in p.tracks.enumerated() where !(track.audioClips.isEmpty && track.midiClips.isEmpty) {
            status = "Stem \(i + 1)/\(p.tracks.count): \(track.name)"
            await Task.yield()
            let url = folder.appendingPathComponent("\(String(format: "%02d", i + 1)) \(track.name.replacingOccurrences(of: "/", with: "-")).wav")
            do { try bounce(to: url, from: 0, to: end, solo: track.id) } catch {
                status = "Stem failed: \(error.localizedDescription)"
                return nil
            }
        }
        status = "Stems exported to \(folder.lastPathComponent)"
        return folder
    }

    func exportToShow(name: String, autoMaster: Bool) async {
        guard let result = await exportMix(name: name, loopOnly: false, autoMaster: autoMaster) else { return }
        onExportToShow?(result.url, name)
    }

    static func exportFolder() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = docs.appendingPathComponent("STRDM Stage Shows/Studio Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func masterLimiter() -> AVAudioUnit? {
        for slot in project.master.effects where slot.componentSubType == kAudioUnitSubType_PeakLimiter && !slot.bypassed {
            if let u = effectUnits[slot.id] { return u }
        }
        return nil
    }

    private func setLimiterPreGain(_ unit: AVAudioUnit, _ db: Double) {
        AudioUnitSetParameter(unit.audioUnit, AudioUnitParameterID(kLimiterParam_PreGain), kAudioUnitScope_Global, 0, AudioUnitParameterValue(db), 0)
    }

    // MARK: - Plugins

    func refreshComponents() {
        let manager = AVAudioUnitComponentManager.shared()
        let inst = AudioComponentDescription(componentType: kAudioUnitType_MusicDevice, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
        instrumentComponents = manager.components(matching: inst)
            .filter { $0.manufacturerName != "STRDM" && !$0.name.hasPrefix("STRDM") }
            .sorted { ($0.manufacturerName, $0.name) < ($1.manufacturerName, $1.name) }
        var effects: [AVAudioUnitComponent] = []
        for type in [kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
            let d = AudioComponentDescription(componentType: type, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
            effects += manager.components(matching: d)
        }
        effectComponents = effects.sorted { ($0.manufacturerName, $0.name) < ($1.manufacturerName, $1.name) }
    }

    /// Opens a plugin's own window (or Apple's generic editor).
    func openEditor(for slot: EffectSlot) { openWindow(unit: effectUnits[slot.id], title: slot.name, key: slot.id.uuidString) }

    func openInstrumentEditor(trackID: UUID) {
        guard let unit = trackNodes[trackID]?.instrument else { return }
        let name = project.tracks.first { $0.id == trackID }?.name ?? "Instrument"
        openWindow(unit: unit, title: name, key: "inst-\(trackID)")
    }

    private func openWindow(unit: AVAudioUnit?, title: String, key: String) {
        guard let unit else { return }
        if let w = pluginWindows[key] { w.makeKeyAndOrderFront(nil); return }
        unit.auAudioUnit.requestViewController { @Sendable [weak self] controller in
            Task { @MainActor in
                guard let self else { return }
                let vc: NSViewController
                if let controller { vc = controller } else {
                    let g = NSViewController()
                    g.view = AUGenericView(audioUnit: unit.audioUnit)
                    vc = g
                }
                let w = NSWindow(contentViewController: vc)
                w.isReleasedWhenClosed = false
                w.title = title
                let size = vc.preferredContentSize
                if size.width > 10 && size.height > 10 { w.setContentSize(size) }
                w.makeKeyAndOrderFront(nil)
                self.pluginWindows[key] = w
            }
        }
    }

    /// Saves plugin settings into the project (called before the show saves).
    func captureStates() {
        var p = store.show.daw
        var changed = false
        func capture(_ slots: inout [EffectSlot]) {
            for i in slots.indices {
                if let u = effectUnits[slots[i].id], let st = u.auAudioUnit.fullState, let data = AudioEngine.encodeState(st), slots[i].state != data {
                    slots[i].state = data
                    changed = true
                }
            }
        }
        for t in p.tracks.indices {
            capture(&p.tracks[t].effects)
            if case .audioUnit(var slot)? = p.tracks[t].instrument, let u = instrumentUnits[p.tracks[t].id]?.unit,
               let st = u.auAudioUnit.fullState, let data = AudioEngine.encodeState(st), slot.state != data {
                slot.state = data
                p.tracks[t].instrument = .audioUnit(slot)
                changed = true
            }
        }
        for b in p.buses.indices { capture(&p.buses[b].effects) }
        capture(&p.master.effects)
        if changed { store.show.daw = p }
    }

    // MARK: - Clip helpers

    func audioDuration(path: String) -> Double? { audioCache.data(path: path, sampleRate: sampleRate, onLoad: nil)?.duration }
    func peaks(path: String) -> [Float]? { audioCache.data(path: path, sampleRate: sampleRate, onLoad: { [weak self] in self?.objectWillChange.send() })?.peaks }

    /// Adds an audio file as a clip (length from the file once decoded; 8 bars until then).
    func addAudioClip(url: URL, trackID: UUID? = nil, at beat: Double) {
        let path = url.path
        if MediaSupport.isVideo(url) { MediaSupport.prepare(url) }
        let spb = secondsPerBeat
        let target = trackID ?? project.tracks.first(where: { $0.kind == .audio })?.id
        let clipID = UUID()
        edit { p in
            var tid = target
            if tid == nil {
                let t = DAWTrack(name: url.deletingPathExtension().lastPathComponent, kind: .audio, color: .teal)
                p.tracks.append(t)
                tid = t.id
            }
            guard let i = p.tracks.firstIndex(where: { $0.id == tid }) else { return }
            var clip = AudioClip(path: path, start: beat, length: 32)
            clip.id = clipID
            p.tracks[i].audioClips.append(clip)
        }
        _ = audioCache.data(path: path, sampleRate: sampleRate) { [weak self] in
            guard let self, let d = self.audioCache.data(path: path, sampleRate: self.sampleRate, onLoad: nil) else { return }
            let beats = d.duration / spb
            self.store.show.daw.tracks = self.store.show.daw.tracks.map { t in
                var t = t
                if let ci = t.audioClips.firstIndex(where: { $0.id == clipID }) { t.audioClips[ci].length = beats }
                return t
            }
        }
    }
}

/// Decodes audio files for clips once, in the background.
@MainActor
final class DAWAudioCache {
    private var cache: [String: AudioData] = [:]
    private var loading: Set<String> = []
    private var waiters: [String: [() -> Void]] = [:]

    func data(path: String, sampleRate: Double, onLoad: (() -> Void)?) -> AudioData? {
        let key = "\(path)@\(Int(sampleRate))"
        if let d = cache[key] { return d }
        if let onLoad { waiters[key, default: []].append(onLoad) }
        guard !loading.contains(key) else { return nil }
        loading.insert(key)
        Task.detached(priority: .userInitiated) {
            let d = AudioData.decode(path: path, sampleRate: sampleRate)
            await MainActor.run {
                self.loading.remove(key)
                if let d { self.cache[key] = d }
                let w = self.waiters.removeValue(forKey: key) ?? []
                w.forEach { $0() }
            }
        }
        return nil
    }
}

/// ITU-R BS.1770 integrated loudness (K-weighting + gating).
enum Loudness {
    static func integratedLUFS(url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        do { try file.read(into: buf) } catch { return nil }
        guard let data = buf.floatChannelData else { return nil }
        let fs = file.processingFormat.sampleRate
        let n = Int(buf.frameLength)
        let channels = Int(buf.format.channelCount)
        guard n > Int(fs * 0.4) else { return nil }

        // Stage 1: high shelf (+4 dB @ 1681 Hz), Stage 2: high-pass (38 Hz) — BS.1770 coefficients for any fs.
        func shelf() -> [Double] {
            let f0 = 1681.974450955533, G = 3.999843853973347, Q = 0.7071752369554196
            let K = tan(.pi * f0 / fs), Vh = pow(10, G / 20), Vb = pow(Vh, 0.4996667741545416)
            let a0 = 1 + K / Q + K * K
            return [(Vh + Vb * K / Q + K * K) / a0, 2 * (K * K - Vh) / a0, (Vh - Vb * K / Q + K * K) / a0,
                    2 * (K * K - 1) / a0, (1 - K / Q + K * K) / a0]
        }
        func highpass() -> [Double] {
            let f0 = 38.13547087602444, Q = 0.5003270373238773
            let K = tan(.pi * f0 / fs)
            let a0 = 1 + K / Q + K * K
            return [1, -2, 1, 2 * (K * K - 1) / a0, (1 - K / Q + K * K) / a0]
        }
        let s = shelf(), h = highpass()
        let block = Int(fs * 0.4), hop = Int(fs * 0.1)
        var weighted = [[Double]](repeating: [Double](repeating: 0, count: n), count: channels)
        for c in 0..<channels {
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            var u1 = 0.0, u2 = 0.0, z1 = 0.0, z2 = 0.0
            for i in 0..<n {
                let x = Double(data[c][i])
                let y = s[0] * x + s[1] * x1 + s[2] * x2 - s[3] * y1 - s[4] * y2
                x2 = x1; x1 = x; y2 = y1; y1 = y
                let z = h[0] * y + h[1] * u1 + h[2] * u2 - h[3] * z1 - h[4] * z2
                u2 = u1; u1 = y; z2 = z1; z1 = z
                weighted[c][i] = z * z
            }
        }
        var blocks: [Double] = []
        var start = 0
        while start + block <= n {
            var sum = 0.0
            for c in 0..<channels { for i in start..<(start + block) { sum += weighted[c][i] } }
            blocks.append(sum / Double(block))
            start += hop
        }
        func lufs(_ ms: Double) -> Double { -0.691 + 10 * log10(max(ms, 1e-12)) }
        let above = blocks.filter { lufs($0) > -70 }
        guard !above.isEmpty else { return nil }
        let rel = lufs(above.reduce(0, +) / Double(above.count)) - 10
        let gated = above.filter { lufs($0) > rel }
        guard !gated.isEmpty else { return nil }
        return lufs(gated.reduce(0, +) / Double(gated.count))
    }
}
