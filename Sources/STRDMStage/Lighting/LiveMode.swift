import Foundation
import AVFoundation
import Accelerate
import os

/// LIVE MODE — listens to a microphone / line input and runs the whole stage from what it hears:
/// tempo + beat grid, kicks and snares, energy, builds, drops and breakdowns, all in real time.
/// It feeds a growing "live song" into the normal song-show engine, so lights, movers, lasers, effect hits
/// (when armed), screen visuals and crowd phones all follow the room — DJ sets, live bands, anything.
@MainActor
final class LiveMode: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var bpm: Double = 0
    @Published private(set) var section = "—"
    @Published private(set) var level: Double = 0          // 0…1 input level
    @Published private(set) var energy: Double = 0         // 0…1 relative energy
    @Published private(set) var kickFlash = false
    @Published private(set) var status = "Off"
    @Published var vibe: Vibe = .dancehall
    @Published var paletteName = "Pink & Purple"
    @Published var inputUID: String? = nil
    @Published var sensitivity: Double = 0.5               // 0 = only big changes, 1 = reacts to everything

    private let lighting: LightingEngine
    private let store: ShowStore
    private let engine = AVAudioEngine()
    private let dsp = LiveDSP()
    private var timer: Timer?
    private var instanceID = UUID()
    private var show: LightShow?
    private var started = Date()
    private var lastSectionChange = Date.distantPast
    private var lastKickCount = 0
    private var energyHistory: [Double] = []                // 2 / s, smoothed
    private var tick = 0

    init(lighting: LightingEngine, store: ShowStore) {
        self.lighting = lighting
        self.store = store
        inputUID = store.show.audioSettings.inputDeviceUID
    }

    // MARK: Start / stop

    func toggle() { running ? stop() : start() }

    func start() {
        guard !running else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in Task { @MainActor in if ok { self.start() } else { self.status = "Microphone access denied" } } }
            return
        case .denied, .restricted:
            status = "Allow microphone access in System Settings → Privacy → Microphone"
            return
        default: break
        }
        if let id = CoreAudioDevices.device(uid: inputUID)?.id ?? CoreAudioDevices.defaultDevice(input: true) {
            _ = CoreAudioDevices.setCurrentDevice(engine.inputNode.audioUnit, id)
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { status = "No input on that device"; return }
        dsp.reset(sampleRate: format.sampleRate)
        let dsp = self.dsp
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in dsp.process(buffer) }
        do { try engine.start() } catch { status = "Couldn't start input: \(error.localizedDescription)"; return }

        // A fresh "live song" that grows as the music plays.
        instanceID = UUID()
        started = Date()
        energyHistory = []
        lastKickCount = 0
        let analysis = SongAnalysis(duration: 6 * 3600, bpm: 120, beatOffset: 0, key: "Live", isMajor: true, loudnessDB: -20,
                                    brightness: 0.5, bassWeight: 0.5, onsetsPerSecond: 2, arousal: 0.6, valence: 0.6,
                                    energyCurve: [], suggestedVibe: vibe, reasoning: "Live input",
                                    beats: [], firstDownbeat: 0, kicks: [], snares: [],
                                    hatCurve: [], bassCurve: [], midCurve: [], highCurve: [], vocalCurve: [])
        var s = LightShow(name: "LIVE — listening", songPath: "", analysis: analysis, vibe: vibe, paletteName: paletteName, sections: [])
        s.fadeOutAtEnd = 0
        s.sections = [makeSection("Intro", at: 0, energy: 0.3, in: s)]
        show = s
        lighting.startSongShow(s, instanceID: instanceID)
        running = true
        status = "Listening…"
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lighting.stopSongShow(instanceID: instanceID)
        running = false
        status = "Off"
        section = "—"
        bpm = 0
    }

    // MARK: Real-time → live song

    private func update() {
        guard running, var s = show else { return }
        let t = Date().timeIntervalSince(started)
        let f = dsp.snapshot()
        level = f.level
        tick += 1

        // A song cue took over the lights: keep listening, pick up again when it's done.
        if let current = lighting.songShowInstanceID, current != instanceID {
            status = "Paused — a song cue is running"
            return
        }
        if lighting.songShowInstanceID == nil {
            lighting.startSongShow(s, instanceID: instanceID, offset: t)
        }

        // Tempo + beat grid
        if f.bpm > 0 { bpm = f.bpm }
        var a = s.analysis
        a.bpm = bpm > 0 ? bpm : 120
        a.beats = f.beats.map { $0 - f.clockOffset(started) }
        a.firstDownbeat = f.downbeatIndex
        a.kicks = f.kicks.map { $0 - f.clockOffset(started) }
        a.snares = f.snares.map { $0 - f.clockOffset(started) }
        if f.kicks.count != lastKickCount { lastKickCount = f.kicks.count; kickFlash.toggle() }

        // Curves (4 / s) and energy (2 / s), padded up to now
        let quarter = Int(t * 4)
        while (a.bassCurve?.count ?? 0) <= quarter {
            a.bassCurve?.append(f.bass); a.midCurve?.append(f.mid); a.highCurve?.append(f.high)
            a.hatCurve?.append(f.high); a.vocalCurve?.append(f.vocal)
        }
        let half = Int(t * 2)
        let e = f.energy
        while a.energyCurve.count <= half { a.energyCurve.append(e); energyHistory.append(e) }
        energy = e
        s.analysis = a

        // Song structure, decided live
        if tick % 5 == 0, let next = decideSection(t: t, f: f, current: s.sections.last!) {
            let sec = makeSection(next, at: t, energy: e, in: s)
            s.sections.append(sec)
            lastSectionChange = Date()
        }
        section = s.sections.last?.label ?? "—"
        status = f.level < 0.01 ? "Waiting for sound…" : "Following the room"
        show = s
        lighting.updateLiveShow(s, instanceID: instanceID)
    }

    /// Hysteresis state machine: Intro → Verse ⇄ Build → Drop / Chorus → Breakdown …
    private func decideSection(t: Double, f: LiveDSP.Features, current: ShowSection) -> String? {
        let held = Date().timeIntervalSince(lastSectionChange)
        let cur = current.label.lowercased()
        let e = f.energy
        let recent = energyHistory.suffix(4).reduce(0, +) / Double(max(1, min(4, energyHistory.count)))
        let earlier = energyHistory.dropLast(4).suffix(12)
        let before = earlier.isEmpty ? recent : earlier.reduce(0, +) / Double(earlier.count)
        let rise = recent - before
        let k = 0.5 + sensitivity                                   // how quickly we change our mind
        let minHold = 12 / k

        if f.level < 0.008 {                                       // silence / between songs
            return cur.hasPrefix("outro") || held < 3 ? nil : "Outro"
        }
        // The drop: bass slams back after a build or breakdown — react instantly.
        if (cur.hasPrefix("build") || cur.hasPrefix("breakdown") || cur.hasPrefix("intro")) && e > 0.72 && f.bassJump > 0.35 && held > 2 {
            return "Drop"
        }
        guard held > minHold else { return nil }
        if e < 0.3 && !cur.hasPrefix("breakdown") && !cur.hasPrefix("intro") { return "Breakdown" }
        if rise > 0.12 / k && e > 0.4 && e < 0.8 && !cur.hasPrefix("build") && !cur.hasPrefix("drop") { return "Build" }
        if e > 0.75 && !cur.hasPrefix("chorus") && !cur.hasPrefix("drop") { return "Chorus" }
        if e >= 0.3 && e < 0.62 && (cur.hasPrefix("chorus") || cur.hasPrefix("drop") || cur.hasPrefix("outro") || cur.hasPrefix("breakdown") || cur.hasPrefix("intro")) {
            return "Verse"
        }
        // Long sections get a fresh look every ~32 bars so it never sits still.
        if held > 32 * 4 * 60 / max(60, bpm) { return current.label.components(separatedBy: " ").first }
        return nil
    }

    private func makeSection(_ label: String, at t: Double, energy: Double, in s: LightShow) -> ShowSection {
        let count = s.sections.filter { $0.label.hasPrefix(label) }.count
        let sec = ShowSection(label: count == 0 ? label : "\(label) \(count + 1)", start: t, end: t + 3600, energy: energy,
                              look: s.sections.last?.look ?? .placeholder)
        // Generate the look as if this were the next section of a real song (keeps earlier looks frozen).
        var all = s.sections
        if !all.isEmpty { all[all.count - 1].end = t }
        all.append(sec)
        let looks = LookGenerator.looks(for: all, vibe: vibe, palette: Palette.named(paletteName), hasDrums: true)
        var out = sec
        out.look = looks.last?.look ?? sec.look
        if label == "Outro" { out.look.intensity = 0.25; out.look.laser = nil; out.look.sfxHit = nil; out.look.strobeBeats = 0 }
        if label != "Drop" { out.look.sfxHit = label == "Chorus" && out.look.sfxHit != nil ? out.look.sfxHit : nil }
        return out
    }

    /// Changing vibe / colours mid-set restyles from the next section on.
    func restyle() {
        guard var s = show else { return }
        s.vibe = vibe; s.paletteName = paletteName
        if let last = s.sections.last {
            s.sections.removeLast()
            s.sections.append(makeSection(last.label.components(separatedBy: " ").first ?? "Verse", at: last.start, energy: last.energy, in: s))
        }
        show = s
        lighting.updateLiveShow(s, instanceID: instanceID)
    }
}

extension SectionLook {
    static let placeholder = SectionLook(colorA: .white, colorB: .white, intensity: 0.6, chase: .still, beatsPerStep: 1,
                                         strobeBeats: 0, mover: .still, haze: 0.3)
}

// MARK: - DSP (runs on the audio thread)

final class LiveDSP: @unchecked Sendable {
    struct Features {
        var level = 0.0, energy = 0.0, bass = 0.0, mid = 0.0, high = 0.0, vocal = 0.0, bassJump = 0.0
        var bpm = 0.0
        var beats: [Double] = []        // absolute times (s since reference)
        var kicks: [Double] = []
        var snares: [Double] = []
        var downbeatIndex = 0
        var reference = Date()
        /// Seconds between the DSP's reference clock and the live song start.
        func clockOffset(_ songStart: Date) -> Double { songStart.timeIntervalSince(reference) }
    }

    private let lock = OSAllocatedUnfairLock()
    private var f = Features()
    private var sr = 48000.0
    private var fft: vDSP.FFT<DSPSplitComplex>?
    private let n = 1024
    private var window: [Float] = []
    private var prevBands = [Double](repeating: 0, count: 4)
    private var onset: [Double] = []             // onset strength, one per hop
    private var bassFlux: [Double] = []
    private var midFlux: [Double] = []
    private var hop = 0.0
    private var clock = 0.0                       // seconds since reference
    private var lastKick = -1.0, lastSnare = -1.0
    private var lastBeat = -1.0
    private var rmsSlow = 0.0, rmsMin = 1.0, rmsMax = 0.0
    private var bassSlow = 0.0
    private var accentByPhase = [Double](repeating: 0, count: 4)
    private var tempoCountdown = 0

    func reset(sampleRate: Double) {
        lock.withLock {
            f = Features()
            sr = sampleRate
            hop = Double(n) / sampleRate
            fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(n))), radix: .radix2, ofType: DSPSplitComplex.self)
            window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
            onset = []; bassFlux = []; midFlux = []
            clock = 0; lastKick = -1; lastSnare = -1; lastBeat = -1
            rmsSlow = 0; rmsMin = 1; rmsMax = 0.0001; bassSlow = 0
            accentByPhase = [0, 0, 0, 0]
            prevBands = [0, 0, 0, 0]
        }
    }

    func snapshot() -> Features { lock.withLock { f } }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData, buffer.frameLength >= UInt32(n) else { return }
        let frames = Int(buffer.frameLength)
        var mono = [Float](repeating: 0, count: n)
        let channels = Int(buffer.format.channelCount)
        let scale = 1 / Float(max(1, channels))
        for c in 0..<channels {
            let p = ch[c] + (frames - n)
            for i in 0..<n { mono[i] += p[i] * scale }
        }
        lock.withLock { analyse(mono, seconds: Double(frames) / sr) }
    }

    private func analyse(_ x: [Float], seconds: Double) {
        guard let fft else { return }
        clock += seconds
        let rms = Double(vDSP.rootMeanSquare(x))
        var w = [Float](repeating: 0, count: n)
        vDSP.multiply(x, window, result: &w)
        var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                w.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2)) }
                }
                var out = split
                fft.forward(input: split, output: &out)
                vDSP.absolute(out, result: &mags)
            }
        }
        let binHz = sr / Double(n)
        func band(_ lo: Double, _ hi: Double) -> Double {
            let a = max(1, Int(lo / binHz)), b = min(n / 2 - 1, Int(hi / binHz))
            guard b > a else { return 0 }
            return Double(mags[a...b].reduce(0, +)) / Double(b - a + 1)
        }
        let bands = [band(40, 150), band(150, 400), band(400, 2500), band(5000, 12000)]
        let logBands = bands.map { log10(1 + $0 * 10) }
        let flux = zip(logBands, prevBands).map { max(0, $0 - $1) }
        prevBands = logBands
        let strength = flux[0] * 1.4 + flux[1] * 0.6 + flux[2] + flux[3] * 0.8
        onset.append(strength); bassFlux.append(flux[0]); midFlux.append(flux[2] + flux[3] * 0.5)
        let keep = Int(8 / hop)
        if onset.count > keep { onset.removeFirst(onset.count - keep); bassFlux.removeFirst(bassFlux.count - keep); midFlux.removeFirst(midFlux.count - keep) }

        // Level + relative energy (adapts to any room / gain).
        rmsSlow = rmsSlow * 0.97 + rms * 0.03
        rmsMax = max(rmsMax * 0.9995, rmsSlow)
        rmsMin = min(rmsMin * 1.0005 + 0.000001, rmsSlow)
        f.level = min(1, rms * 4)
        f.energy = max(0, min(1, (rmsSlow - rmsMin) / max(0.0001, rmsMax - rmsMin)))
        let total = max(1e-6, bands.reduce(0, +))
        f.bass = min(1, bands[0] / total * 1.6)
        f.mid = min(1, bands[2] / total * 2)
        f.high = min(1, bands[3] / total * 6)
        f.vocal = min(1, max(0, (bands[2] - bands[0] * 0.3) / total * 2))
        let bassNow = logBands[0]
        f.bassJump = max(0, bassNow - bassSlow) / max(0.05, bassSlow)
        bassSlow = bassSlow * 0.995 + bassNow * 0.005

        // Kicks / snares: flux above an adaptive threshold, with refractory time.
        func peak(_ series: [Double], refractory: Double, last: inout Double) -> Bool {
            guard series.count > 20 else { return false }
            let recent = series.suffix(Int(1 / hop))
            let mean = recent.reduce(0, +) / Double(recent.count)
            let sd = sqrt(recent.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(recent.count))
            guard let v = series.last, v > mean + 1.5 * sd, v > 0.02, clock - last > refractory else { return false }
            last = clock
            return true
        }
        if peak(bassFlux, refractory: 0.22, last: &lastKick) {
            f.kicks.append(clock)
            if f.beats.count > 4 { accentByPhase[(f.beats.count - 1) % 4] += 1 }
        }
        if peak(midFlux, refractory: 0.15, last: &lastSnare) { f.snares.append(clock) }

        // Tempo every ~0.5 s from the onset autocorrelation (prefers 80–170 BPM).
        tempoCountdown -= 1
        if tempoCountdown <= 0 && onset.count > Int(4 / hop) {
            tempoCountdown = Int(0.5 / hop)
            var best = 0.0, bestLag = 0
            let m = onset.reduce(0, +) / Double(onset.count)
            let o = onset.map { $0 - m }
            let minLag = Int(60 / 180 / hop), maxLag = Int(60 / 70 / hop)
            for lag in minLag...maxLag {
                var s = 0.0
                for i in lag..<o.count { s += o[i] * o[i - lag] }
                let bpm = 60 / (Double(lag) * hop)
                let prior = exp(-pow(log2(bpm / 120), 2) / 0.5)
                s *= prior
                if s > best { best = s; bestLag = lag }
            }
            if bestLag > 0 {
                let est = 60 / (Double(bestLag) * hop)
                f.bpm = f.bpm == 0 ? est : (abs(est - f.bpm) / f.bpm < 0.04 ? f.bpm * 0.8 + est * 0.2 : (abs(est - f.bpm) / f.bpm > 0.15 ? est : f.bpm))
            }
        }
        // Beat clock: a phase-locked loop that nudges toward kicks.
        if f.bpm > 0 {
            let period = 60 / f.bpm
            if lastBeat < 0 { lastBeat = clock }
            if clock - lastBeat >= period {
                var beat = lastBeat + period
                if lastKick > 0, abs(lastKick - beat) < period * 0.25 { beat += (lastKick - beat) * 0.3 }
                lastBeat = beat
                f.beats.append(beat)
                // Bar line = the beat position with the most kicks.
                if let strongest = accentByPhase.indices.max(by: { accentByPhase[$0] < accentByPhase[$1] }) {
                    f.downbeatIndex = strongest
                }
                for i in accentByPhase.indices { accentByPhase[i] *= 0.995 }
            }
        }
        if f.kicks.count > 20000 { f.kicks.removeFirst(10000) }
        if f.snares.count > 20000 { f.snares.removeFirst(10000) }
    }
}
