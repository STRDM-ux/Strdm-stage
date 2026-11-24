import Foundation
import SwiftUI

/// One cue instance currently in pre-wait or running.
struct RunningCue: Identifiable, Equatable {
    enum Phase: Equatable { case preWait, running, fading }
    let id: UUID            // run instance id (the same cue can run twice)
    let cueID: UUID
    let cueNumber: String
    let title: String
    let kind: CueKind
    var phase: Phase
    var startedAt: Date
    var duration: Double?   // nil = until stopped (looping)
    var followEnabled = true
    /// Cues started by the same GO (auto-continue chains) share this, so they don't stop each other.
    var goID = UUID()
}

/// The show-runner: GO button, standby pointer, pre-waits and auto-continue / auto-follow chains.
@MainActor
final class ShowEngine: ObservableObject {
    @Published var standbyIndex: Int = 0
    @Published private(set) var running: [RunningCue] = []
    @Published var selectedCueID: UUID? = nil
    @Published var log: [String] = []

    private let store: ShowStore
    private let audio: AudioEngine
    private let lighting: LightingEngine
    private let screens: ScreenManager
    private var pending: [UUID: DispatchWorkItem] = [:]

    init(store: ShowStore, audio: AudioEngine, lighting: LightingEngine, screens: ScreenManager) {
        self.store = store
        self.audio = audio
        self.lighting = lighting
        self.screens = screens
        screens.onInstanceRemoved = { [weak self] id in
            self?.running.removeAll { $0.id == id }
        }
        audio.onInstanceRemoved = { [weak self] id in
            self?.running.removeAll { $0.id == id }
            self?.lighting.stopSongShow(instanceID: id)
        }
    }

    var cues: [Cue] { store.show.cues }

    var standbyCue: Cue? {
        cues.indices.contains(standbyIndex) ? cues[standbyIndex] : nil
    }

    // MARK: Transport

    func go() {
        guard cues.indices.contains(standbyIndex) else {
            note("End of cue list.")
            return
        }
        fire(index: standbyIndex)
    }

    /// Fades out audio/video still playing from earlier GOs.
    func stopPrevious(except goID: UUID, fade: Double) {
        let targets = running.filter { ($0.kind == .audio || $0.kind == .video) && $0.goID != goID && $0.phase != .fading }
        guard !targets.isEmpty else { return }
        let ids = targets.map(\.id)
        markFading { ids.contains($0.id) }
        for id in ids {
            audio.fadeAndStop(instanceID: id, duration: fade)
            screens.fadeAndStop(instanceID: id, duration: fade)
            lighting.stopSongShow(instanceID: id)
        }
        note("Faded out previous: " + targets.map { "\($0.cueNumber) \($0.title)" }.joined(separator: ", "))
    }

    func setStandby(_ index: Int) {
        standbyIndex = max(0, min(index, cues.count))
    }

    func moveStandby(by delta: Int) { setStandby(standbyIndex + delta) }

    func setStandby(cueID: UUID) {
        if let i = store.cueIndex(cueID) { setStandby(i) }
    }

    /// Hard stop: everything silent and black immediately, pending pre-waits cancelled. Lighting holds its look.
    func stopAll() {
        cancelPending()
        running.removeAll()
        lighting.stopSongShow()
        if lighting.sfx?.masterArmed == true { lighting.sfx?.disarmMaster(reason: "Stop All") }
        audio.stopAll()
        screens.stopAll(fade: 0)
        note("STOP ALL")
    }

    /// Panic: cancel pre-waits, fade all audio and video out over 2 seconds.
    func panic() {
        cancelPending()
        for i in running.indices {
            running[i].followEnabled = false
            running[i].phase = .fading
        }
        audio.fadeAndStopAll(duration: 2)
        screens.stopAll(fade: 2)
        lighting.stopSongShow()
        lighting.sfx?.emergencyStop(reason: "PANIC")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) { [weak self] in
            MainActor.assumeIsolated { self?.running.removeAll() }
        }
        note("PANIC — fading everything")
    }

    /// Fires one cue directly (from the cue list's play button) without moving standby.
    func fireOnly(cueID: UUID) {
        guard let i = store.cueIndex(cueID) else { return }
        fire(index: i, moveStandby: false)
    }

    // MARK: Firing

    func fire(index: Int, moveStandby: Bool = true, goID: UUID = UUID()) {
        guard cues.indices.contains(index) else { return }
        let cue = cues[index]
        if moveStandby { standbyIndex = index + 1 }
        let runID = UUID()

        if cue.preWait > 0 {
            running.append(RunningCue(id: runID, cueID: cue.id, cueNumber: cue.number, title: cue.displayName,
                                      kind: cue.kind, phase: .preWait, startedAt: Date(), duration: cue.preWait, goID: goID))
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.start(cue: cue, index: index, runID: runID, goID: goID) }
            }
            pending[runID] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + cue.preWait, execute: work)
        } else {
            start(cue: cue, index: index, runID: runID, goID: goID)
        }
    }

    private func start(cue: Cue, index: Int, runID: UUID, goID: UUID = UUID()) {
        pending[runID] = nil
        running.removeAll { $0.id == runID }

        // A new track/video fades out the previous one (unless the cue or show says otherwise).
        if index >= 0, cue.kind == .audio || cue.kind == .video,
           cue.stopPrevious ?? store.show.playback.autoStopPrevious {
            stopPrevious(except: goID, fade: store.show.playback.stopFade)
        }

        let finished: () -> Void = { [weak self] in self?.cueFinished(runID: runID, cue: cue, index: index) }
        var duration: Double? = 0
        var tracked = true

        switch cue.kind {
        case .audio:
            if let d = audio.play(cue: cue, instanceID: runID, completion: finished) {
                duration = cue.loop ? nil : d
                if let showID = cue.lightShowID, let show = store.show.lightShows.first(where: { $0.id == showID }) {
                    lighting.startSongShow(show, instanceID: runID, offset: cue.startOffset)
                }
            } else {
                note("Cue \(cue.number): audio file missing or unreadable.")
                tracked = false
            }

        case .lights:
            guard let sceneID = cue.sceneID else { note("Cue \(cue.number): no scene selected."); tracked = false; break }
            lighting.goToScene(sceneID, fade: cue.lightFade, completion: finished)
            duration = cue.lightFade

        case .video:
            if let d = screens.play(cue: cue, instanceID: runID, completion: finished) {
                duration = cue.videoLoop ? nil : d
                // Video sound through the show interface (same instance id, so fades/stops hit both).
                if cue.videoSound != false, let path = cue.videoPath,
                   let audioURL = MediaSupport.readyAudio(for: URL(fileURLWithPath: path)) {
                    var soundCue = Cue(kind: .audio)
                    soundCue.audioPath = audioURL.path
                    soundCue.loop = cue.videoLoop
                    soundCue.fadeIn = cue.videoFade
                    _ = audio.play(cue: soundCue, instanceID: runID, completion: {})
                } else if cue.videoSound != false, let path = cue.videoPath {
                    MediaSupport.prepare(URL(fileURLWithPath: path))
                }
            } else {
                note("Cue \(cue.number): video/image missing or no screen output assigned.")
                tracked = false
            }

        case .videoBlack:
            screens.stopAll(fade: cue.videoFade)
            for i in running.indices where running[i].kind == .video {
                running[i].followEnabled = false
                running[i].phase = .fading
            }
            let fadeIDs = running.filter { $0.kind == .video }.map(\.id)
            after(cue.videoFade) { [weak self] in self?.running.removeAll { fadeIDs.contains($0.id) } }
            duration = cue.videoFade
            after(cue.videoFade, finished)

        case .fade:
            performFade(cue)
            duration = cue.fadeDuration
            after(cue.fadeDuration, finished)

        case .vocalFX:
            audio.setVocalBypass(cue.vocalBypass)
            if let preset = cue.vocalPresetID { audio.applyVocalPreset(preset) }
            duration = 0
            after(0.05, finished)

        case .wait:
            duration = cue.waitDuration
            after(cue.waitDuration, finished)

        case .memo:
            duration = 0
            after(0.05, finished)

        case .layered:
            let layers = cue.layers ?? []
            if index >= 0, layers.contains(where: { $0.kind == .audio || $0.kind == .video }),
               cue.stopPrevious ?? store.show.playback.autoStopPrevious {
                stopPrevious(except: goID, fade: store.show.playback.stopFade)
            }
            for (k, layer) in layers.enumerated() where layer.kind != .layered {
                var l = layer
                l.number = cue.number.isEmpty ? "\(k + 1)" : "\(cue.number).\(k + 1)"
                l.continueMode = .none
                fireLayer(l, goID: goID)
            }
            if layers.isEmpty { note("Cue \(cue.number): layered cue has no layers.") }
            duration = 0
            tracked = false
            note("GO \(cue.number) — \(layers.count) layers")

        case .effect:
            let kind = cue.sfxKind ?? .co2
            let ids = cue.sfxDeviceIDs ?? store.show.effects.devices.filter { $0.kind == kind }.map(\.id)
            if let sfx = lighting.sfx {
                if !sfx.masterArmed { note("Cue \(cue.number): effects not armed — \(kind.label) skipped.") }
                else { sfx.fire(ids, pattern: cue.sfxPattern ?? .all, duration: cue.sfxDuration, source: .cue) }
            }
            duration = 0
            after(0.05, finished)
        }

        if tracked {
            running.append(RunningCue(id: runID, cueID: cue.id, cueNumber: cue.number, title: cue.displayName,
                                      kind: cue.kind, phase: .running, startedAt: Date(), duration: duration, goID: goID))
            note("GO \(cue.number) — \(cue.displayName)")
        }

        if cue.continueMode == .autoContinue || (!tracked && cue.continueMode == .autoFollow) {
            fire(index: index + 1, goID: goID)
        }
    }

    /// Starts one layer of a layered cue (its pre-wait is the delay), sharing the GO so layers don't stop each other.
    private func fireLayer(_ layer: Cue, goID: UUID) {
        let runID = UUID()
        if layer.preWait > 0 {
            running.append(RunningCue(id: runID, cueID: layer.id, cueNumber: layer.number, title: layer.displayName,
                                      kind: layer.kind, phase: .preWait, startedAt: Date(), duration: layer.preWait, goID: goID))
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.start(cue: layer, index: -1, runID: runID, goID: goID) }
            }
            pending[runID] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + layer.preWait, execute: work)
        } else {
            start(cue: layer, index: -1, runID: runID, goID: goID)
        }
    }

    private func cueFinished(runID: UUID, cue: Cue, index: Int) {
        lighting.stopSongShow(instanceID: runID)
        guard let entry = running.first(where: { $0.id == runID }) else { return }
        running.removeAll { $0.id == runID }
        if entry.followEnabled && cue.continueMode == .autoFollow {
            fire(index: index + 1, goID: entry.goID)
        }
    }

    private func performFade(_ cue: Cue) {
        let d = cue.fadeDuration
        switch cue.fadeTarget {
        case .allAudio:
            markFading { $0.kind == .audio }
            audio.fadeAndStopAll(duration: d)
        case .allVideo:
            markFading { $0.kind == .video }
            screens.stopAll(fade: d)
        case .everything:
            markFading { $0.kind == .audio || $0.kind == .video }
            audio.fadeAndStopAll(duration: d)
            screens.stopAll(fade: d)
        case .specificCue:
            guard let target = cue.fadeTargetCueID else { return }
            let ids = running.filter { $0.cueID == target }.map(\.id)
            markFading { $0.cueID == target }
            for id in ids {
                audio.fadeAndStop(instanceID: id, duration: d)
                screens.fadeAndStop(instanceID: id, duration: d)
            }
        }
    }

    private func markFading(_ predicate: (RunningCue) -> Bool) {
        var ids: [UUID] = []
        for i in running.indices where predicate(running[i]) {
            running[i].followEnabled = false
            running[i].phase = .fading
            ids.append(running[i].id)
        }
        // Clean up the list even if an engine doesn't report completion.
        let maxFade = 30.0
        after(maxFade) { [weak self] in self?.running.removeAll { ids.contains($0.id) } }
    }

    // MARK: Ad-hoc (Light Set Builder preview)

    /// Runs a cue that isn't in the cue list (e.g. previewing a song with its light show).
    @discardableResult
    func fireAdHoc(_ cue: Cue) -> UUID {
        let runID = UUID()
        start(cue: cue, index: -1, runID: runID)
        return runID
    }

    func stopInstance(_ runID: UUID, fade: Double = 0.5) {
        for i in running.indices where running[i].id == runID { running[i].followEnabled = false }
        audio.fadeAndStop(instanceID: runID, duration: fade)
        lighting.stopSongShow(instanceID: runID)
    }

    // MARK: Helpers

    private func cancelPending() {
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
    }

    private func after(_ seconds: Double, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds)) {
            MainActor.assumeIsolated { block() }
        }
    }

    func note(_ message: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        log.append("[\(stamp)] \(message)")
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    // MARK: External control

    func perform(_ action: ControlAction) {
        switch action {
        case .go: go()
        case .stopAll: stopAll()
        case .panic: panic()
        case .standbyNext: moveStandby(by: 1)
        case .standbyPrevious: moveStandby(by: -1)
        case .blackout: lighting.blackout.toggle()
        case .vocalBypassToggle: audio.setVocalBypass(!store.show.vocalRack.bypassAll)
        }
    }

    /// Fire by cue number (used by OSC /cue/{number}/start).
    func fire(cueNumber: String) {
        if let i = cues.firstIndex(where: { $0.number == cueNumber }) { fire(index: i) }
    }
}
