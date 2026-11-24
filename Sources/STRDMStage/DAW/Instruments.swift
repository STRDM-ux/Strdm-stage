import Foundation
import AVFoundation
import AudioToolbox
import os

// MARK: - Shared instrument plumbing

/// Something that makes sound from MIDI, rendered on the audio thread.
protocol InstrumentKernel: AnyObject {
    func prepare(sampleRate: Double)
    func handleMIDI(_ status: UInt8, _ d1: UInt8, _ d2: UInt8)
    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int)
}

private func fourCC(_ s: String) -> FourCharCode {
    s.utf8.prefix(4).reduce(0) { ($0 << 8) | FourCharCode($1) }
}

/// In-process AUv3 instrument base: stereo out, sample-accurate MIDI.
class STRDMInstrumentAU: AUAudioUnit {
    private var outputBus: AUAudioUnitBus!
    private var busArray: AUAudioUnitBusArray!
    private var scratchL: UnsafeMutablePointer<Float>?
    private var scratchR: UnsafeMutablePointer<Float>?
    private var scratchCapacity = 0

    var kernel: InstrumentKernel { fatalError("subclass must provide a kernel") }

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        outputBus = try AUAudioUnitBus(format: format)
        outputBus.maximumChannelCount = 2
        busArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        maximumFramesToRender = 4096
    }

    override var outputBusses: AUAudioUnitBusArray { busArray }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let cap = Int(maximumFramesToRender)
        if cap > scratchCapacity {
            scratchL?.deallocate(); scratchR?.deallocate()
            scratchL = .allocate(capacity: cap); scratchR = .allocate(capacity: cap)
            scratchCapacity = cap
        }
        kernel.prepare(sampleRate: outputBus.format.sampleRate)
    }

    deinit {
        scratchL?.deallocate()
        scratchR?.deallocate()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let kernel = self.kernel
        let sl = scratchL, sr = scratchR
        return { _, timestamp, frameCount, _, outputData, eventsHead, _ in
            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            guard abl.count >= 1 else { return noErr }
            if abl[0].mData == nil, let sl { abl[0].mData = UnsafeMutableRawPointer(sl) }
            if abl.count > 1, abl[1].mData == nil, let sr { abl[1].mData = UnsafeMutableRawPointer(sr) }
            guard let lRaw = abl[0].mData else { return noErr }
            let left = lRaw.assumingMemoryBound(to: Float.self)
            let right = abl.count > 1 ? (abl[1].mData?.assumingMemoryBound(to: Float.self) ?? left) : left
            let frames = Int(frameCount)
            for i in 0..<Int(abl.count) { abl[i].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size) }
            left.update(repeating: 0, count: frames)
            if right != left { right.update(repeating: 0, count: frames) }

            let start = AUEventSampleTime(timestamp.pointee.mSampleTime)
            var done = 0
            var event = eventsHead
            while done < frames {
                while let e = event {
                    let offset = Int(max(0, e.pointee.head.eventSampleTime - start))
                    if offset > done { break }
                    if e.pointee.head.eventType == .MIDI {
                        let m = e.pointee.MIDI
                        kernel.handleMIDI(m.data.0, m.data.1, m.data.2)
                    }
                    event = UnsafePointer(e.pointee.head.next)
                }
                var next = frames
                if let e = event { next = min(frames, Int(max(0, e.pointee.head.eventSampleTime - start))) }
                let n = max(1, min(frames - done, next - done))
                kernel.render(left: left + done, right: right + done, frames: n)
                done += n
            }
            return noErr
        }
    }
}

// MARK: - STRDM Synth (subtractive, 16 voices)

final class SynthKernel: InstrumentKernel {
    private struct Voice {
        var active = false
        var note = 0
        var velocity: Double = 0
        var freq: Double = 440
        var targetFreq: Double = 440
        var p1 = 0.0, p2 = 0.0, pSub = 0.0
        var env = 0.0
        var stage = 0          // 0 attack 1 decay 2 sustain 3 release
        var fenv = 0.0
        var ic1 = 0.0, ic2 = 0.0
        var age = 0
    }
    private var voices = [Voice](repeating: Voice(), count: 16)
    private var sampleRate = 48_000.0
    private var preset = SynthPreset.library[0]
    private let pending = OSAllocatedUnfairLock<SynthPreset?>(initialState: nil)
    private var lastFreq = 0.0
    private var counter = 0

    func setPreset(_ p: SynthPreset) { pending.withLock { $0 = p } }

    func prepare(sampleRate: Double) { self.sampleRate = sampleRate }

    func handleMIDI(_ status: UInt8, _ d1: UInt8, _ d2: UInt8) {
        let type = status & 0xF0
        if type == 0x90 && d2 > 0 {
            noteOn(Int(d1), velocity: Double(d2) / 127)
        } else if type == 0x80 || (type == 0x90 && d2 == 0) {
            for i in voices.indices where voices[i].active && voices[i].note == Int(d1) && voices[i].stage < 3 { voices[i].stage = 3 }
        } else if type == 0xB0 && (d1 == 123 || d1 == 120) {
            for i in voices.indices { voices[i].stage = 3 }
        }
    }

    private func noteOn(_ note: Int, velocity: Double) {
        let f = 440 * pow(2, (Double(note) - 69) / 12)
        var idx = voices.firstIndex { !$0.active }
        if idx == nil { idx = voices.indices.max { voices[$0].age < voices[$1].age } }
        guard let i = idx else { return }
        var v = Voice()
        v.active = true
        v.note = note
        v.velocity = velocity
        v.targetFreq = f
        v.freq = (preset.glide > 0 && lastFreq > 0) ? lastFreq : f
        v.age = counter
        counter += 1
        voices[i] = v
        lastFreq = f
    }

    @inline(__always) private func blep(_ t: Double, _ dt: Double) -> Double {
        if t < dt { let x = t / dt; return x + x - x * x - 1 }
        if t > 1 - dt { let x = (t - 1) / dt; return x * x + x + x + 1 }
        return 0
    }

    @inline(__always) private func osc(_ wave: Int, _ t: Double, _ dt: Double) -> Double {
        switch wave {
        case 0: return sin(2 * .pi * t)
        case 1: return 2 * t - 1 - blep(t, dt)
        case 2:
            var s = t < 0.5 ? 1.0 : -1.0
            s += blep(t, dt)
            s -= blep((t + 0.5).truncatingRemainder(dividingBy: 1), dt)
            return s
        default: return 4 * abs(t - 0.5) - 1
        }
    }

    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        if let p = pending.withLock({ v -> SynthPreset? in let x = v; v = nil; return x }) { preset = p }
        let p = preset
        let sr = sampleRate
        let atk = 1 / max(1, p.attack * sr)
        let dec = exp(-1 / max(1, p.decay * sr * 0.35))
        let rel = exp(-1 / max(1, p.release * sr * 0.35))
        let fAtk = 1 / max(1, 0.002 * sr)
        let fDec = exp(-1 / max(1, (p.decay + 0.05) * sr * 0.35))
        let glideCoef = p.glide > 0 ? exp(-1 / (p.glide * sr)) : 0
        let detuneRatio = pow(2, p.detune / 1200)
        let k = 2 - 2 * min(0.95, max(0, p.resonance))
        let gain = p.gain

        for vi in voices.indices where voices[vi].active {
            var v = voices[vi]
            for n in 0..<frames {
                if glideCoef > 0 { v.freq = v.targetFreq + (v.freq - v.targetFreq) * glideCoef } else { v.freq = v.targetFreq }
                // Amp envelope
                switch v.stage {
                case 0:
                    v.env += atk
                    if v.env >= 1 { v.env = 1; v.stage = 1 }
                case 1:
                    v.env = p.sustain + (v.env - p.sustain) * dec
                    if abs(v.env - p.sustain) < 0.0005 { v.stage = 2 }
                case 2:
                    v.env = p.sustain
                    if p.sustain <= 0.0001 { v.stage = 3 }
                default:
                    v.env *= rel
                    if v.env < 0.0001 { v.active = false }
                }
                if !v.active { break }
                // Filter envelope
                if v.stage == 0 { v.fenv = min(1, v.fenv + fAtk) } else { v.fenv *= fDec }

                let dt1 = v.freq / sr
                let dt2 = v.freq * detuneRatio / sr
                let s = osc(p.wave1, v.p1, dt1) + p.osc2Level * osc(p.wave2, v.p2, dt2)
                    + p.subLevel * sin(2 * .pi * v.pSub)
                v.p1 += dt1; if v.p1 >= 1 { v.p1 -= 1 }
                v.p2 += dt2; if v.p2 >= 1 { v.p2 -= 1 }
                v.pSub += dt1 * 0.5; if v.pSub >= 1 { v.pSub -= 1 }

                let cutoff = min(sr * 0.45, p.cutoff * pow(2, p.filterEnv * v.fenv * v.velocity))
                let g = tan(.pi * cutoff / sr)
                let a1 = 1 / (1 + g * (g + k)), a2 = g * a1, a3 = g * a2
                let v3 = s - v.ic2
                let v1 = a1 * v.ic1 + a2 * v3
                let v2 = v.ic2 + a2 * v.ic1 + a3 * v3
                v.ic1 = 2 * v1 - v.ic1
                v.ic2 = 2 * v2 - v.ic2

                let out = Float(tanh(v2 * v.env * v.velocity * gain * 1.2) * 0.8)
                left[n] += out
                right[n] += out
            }
            voices[vi] = v
        }
    }
}

final class STRDMSynthAU: STRDMInstrumentAU {
    static let description = AudioComponentDescription(componentType: kAudioUnitType_MusicDevice, componentSubType: fourCC("stsy"),
                                                       componentManufacturer: fourCC("STRD"), componentFlags: 0, componentFlagsMask: 0)
    let synth = SynthKernel()
    override var kernel: InstrumentKernel { synth }
}

// MARK: - Drum machine (synthesised kits + custom samples)

final class DrumKernel: InstrumentKernel {
    private struct Hit { var sample: Int; var pos: Int; var gain: Float }
    private var samples: [Int: [Float]] = [:]        // note → mono sample data
    private var hits: [Hit] = []
    private var sampleRate = 48_000.0
    private var kit = "Dancehall"
    private var custom: [Int: [Float]] = [:]
    private let pendingSamples = OSAllocatedUnfairLock<[Int: [Float]]?>(initialState: nil)

    init() { hits.reserveCapacity(64) }

    func prepare(sampleRate: Double) {
        self.sampleRate = sampleRate
        var built = DrumSynth.kit(kit, sampleRate: sampleRate)
        for (k, v) in custom { built[k] = v }
        samples = built
    }

    /// Call from the main thread: swaps the kit (and any custom pad samples) in safely.
    func load(kit: String, custom: [Int: [Float]], sampleRate: Double) {
        self.kit = kit
        self.custom = custom
        var built = DrumSynth.kit(kit, sampleRate: sampleRate)
        for (k, v) in custom { built[k] = v }
        pendingSamples.withLock { $0 = built }
    }

    func handleMIDI(_ status: UInt8, _ d1: UInt8, _ d2: UInt8) {
        let type = status & 0xF0
        guard type == 0x90, d2 > 0 else {
            if type == 0xB0 && (d1 == 123 || d1 == 120) { hits.removeAll(keepingCapacity: true) }
            return
        }
        let note = Int(d1)
        // Closed hat chokes the open hat
        if note == 42 { hits.removeAll { $0.sample == 46 } }
        if hits.count >= 48 { hits.removeFirst() }
        hits.append(Hit(sample: note, pos: 0, gain: Float(d2) / 127))
    }

    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        if let swap = pendingSamples.withLock({ v -> [Int: [Float]]? in let x = v; v = nil; return x }) { samples = swap }
        var i = 0
        while i < hits.count {
            var h = hits[i]
            guard let data = samples[h.sample] ?? samples[36] else { hits.remove(at: i); continue }
            let count = min(frames, data.count - h.pos)
            if count > 0 {
                data.withUnsafeBufferPointer { buf in
                    for n in 0..<count {
                        let s = buf[h.pos + n] * h.gain
                        left[n] += s
                        right[n] += s
                    }
                }
                h.pos += count
            }
            if h.pos >= data.count { hits.remove(at: i) } else { hits[i] = h; i += 1 }
        }
    }
}

final class STRDMDrumAU: STRDMInstrumentAU {
    static let description = AudioComponentDescription(componentType: kAudioUnitType_MusicDevice, componentSubType: fourCC("stdr"),
                                                       componentManufacturer: fourCC("STRD"), componentFlags: 0, componentFlagsMask: 0)
    let drums = DrumKernel()
    override var kernel: InstrumentKernel { drums }
}

enum InstrumentRegistry {
    private static var registered = false

    static func registerAll() {
        guard !registered else { return }
        registered = true
        AUAudioUnit.registerSubclass(STRDMSynthAU.self, as: STRDMSynthAU.description, name: "STRDM: Synth", version: 1)
        AUAudioUnit.registerSubclass(STRDMDrumAU.self, as: STRDMDrumAU.description, name: "STRDM: Drum Machine", version: 1)
    }

    static let gmSoundBank = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
}

// MARK: - Drum synthesis

enum DrumSynth {
    struct Flavor { var pitch: Double; var decay: Double; var noise: Double; var drive: Double }

    static func flavor(_ kit: String) -> Flavor {
        switch kit {
        case "Trap 808": return Flavor(pitch: 0.85, decay: 1.6, noise: 1.1, drive: 1.6)
        case "Afro": return Flavor(pitch: 1.1, decay: 0.9, noise: 0.8, drive: 1.0)
        case "Acoustic-ish": return Flavor(pitch: 1.0, decay: 1.2, noise: 1.3, drive: 0.8)
        default: return Flavor(pitch: 1.0, decay: 1.0, noise: 1.0, drive: 1.2)   // Dancehall
        }
    }

    static func kit(_ name: String, sampleRate sr: Double) -> [Int: [Float]] {
        let f = flavor(name)
        var rng = SplitMix(seed: 42)
        var out: [Int: [Float]] = [:]
        out[36] = kick(sr, f, base: 52, sweep: 150, decay: 0.32)
        out[35] = kick(sr, f, base: 47, sweep: 95, decay: 1.4, sub: true)        // 808
        out[38] = snare(sr, f, &rng)
        out[37] = rim(sr, f, &rng)
        out[39] = clap(sr, f, &rng)
        out[42] = hat(sr, f, &rng, length: 0.06)
        out[46] = hat(sr, f, &rng, length: 0.35)
        out[49] = hat(sr, f, &rng, length: 1.6, bright: 0.6)
        out[51] = ride(sr, f, &rng)
        out[41] = tom(sr, f, freq: 95)
        out[45] = tom(sr, f, freq: 135)
        out[48] = tom(sr, f, freq: 185)
        out[56] = cowbell(sr, f)
        out[54] = shaker(sr, f, &rng)
        out[60] = tom(sr, f, freq: 390, decay: 0.12)
        out[61] = tom(sr, f, freq: 260, decay: 0.16)
        return out
    }

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Double {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53) * 2 - 1
        }
    }

    private static func buffer(_ seconds: Double, _ sr: Double) -> [Float] { [Float](repeating: 0, count: max(1, Int(seconds * sr))) }

    private static func kick(_ sr: Double, _ f: Flavor, base: Double, sweep: Double, decay: Double, sub: Bool = false) -> [Float] {
        let len = decay * f.decay * 1.6 + 0.05
        var b = buffer(len, sr)
        var phase = 0.0
        for i in 0..<b.count {
            let t = Double(i) / sr
            let freq = base * f.pitch + sweep * f.pitch * exp(-t * (sub ? 18 : 30))
            phase += freq / sr
            let env = exp(-t / (decay * f.decay)) * min(1, t * 2000)
            let click = sub ? 0 : exp(-t * 400) * 0.3
            b[i] = Float(tanh((sin(2 * .pi * phase) * env + click) * f.drive * (sub ? 1.4 : 1.1)) * 0.95)
        }
        return b
    }

    private static func snare(_ sr: Double, _ f: Flavor, _ rng: inout SplitMix) -> [Float] {
        var b = buffer(0.32 * f.decay, sr)
        var lp = 0.0, hpPrev = 0.0, hpOut = 0.0
        for i in 0..<b.count {
            let t = Double(i) / sr
            let tone = sin(2 * .pi * 190 * f.pitch * t) * exp(-t * 28) * 0.55
            let n = rng.next()
            lp += 0.6 * (n - lp)
            hpOut = 0.92 * (hpOut + lp - hpPrev)
            hpPrev = lp
            let noise = hpOut * exp(-t * 16 / f.decay) * 0.7 * f.noise
            b[i] = Float(tanh((tone + noise) * 1.3) * 0.9)
        }
        return b
    }

    private static func rim(_ sr: Double, _ f: Flavor, _ rng: inout SplitMix) -> [Float] {
        var b = buffer(0.08, sr)
        for i in 0..<b.count {
            let t = Double(i) / sr
            let s = sin(2 * .pi * 1700 * f.pitch * t) * exp(-t * 90) + sin(2 * .pi * 480 * f.pitch * t) * exp(-t * 60) * 0.6
                + rng.next() * exp(-t * 300) * 0.3
            b[i] = Float(s * 0.7)
        }
        return b
    }

    private static func clap(_ sr: Double, _ f: Flavor, _ rng: inout SplitMix) -> [Float] {
        var b = buffer(0.35 * f.decay, sr)
        var bp1 = 0.0, bp2 = 0.0
        for i in 0..<b.count {
            let t = Double(i) / sr
            var env = 0.0
            for burst in [0.0, 0.011, 0.022] where t >= burst { env = max(env, exp(-(t - burst) * 180)) }
            env = max(env, t > 0.03 ? exp(-(t - 0.03) * 14 / f.decay) * 0.6 : 0)
            let n = rng.next()
            bp1 += 0.35 * (n - bp1)
            bp2 += 0.35 * (bp1 - bp2)
            b[i] = Float((bp1 - bp2) * env * 2.6 * f.noise)
        }
        return b
    }

    private static func hat(_ sr: Double, _ f: Flavor, _ rng: inout SplitMix, length: Double, bright: Double = 0.85) -> [Float] {
        var b = buffer(length * f.decay + 0.02, sr)
        var prev = 0.0, hp = 0.0
        for i in 0..<b.count {
            let t = Double(i) / sr
            let n = rng.next()
            hp = bright * (hp + n - prev)
            prev = n
            let env = exp(-t / (length * f.decay * 0.35))
            b[i] = Float(hp * env * 0.45 * f.noise)
        }
        return b
    }

    private static func ride(_ sr: Double, _ f: Flavor, _ rng: inout SplitMix) -> [Float] {
        var b = buffer(1.2 * f.decay, sr)
        let partials = [415.0, 559.0, 728.0, 1015.0, 1376.0, 2210.0]
        for i in 0..<b.count {
            let t = Double(i) / sr
            var s = 0.0
            for p in partials { s += (sin(2 * .pi * p * f.pitch * t) > 0 ? 1 : -1) }
            b[i] = Float((s / Double(partials.count) * 0.25 + rng.next() * 0.08) * exp(-t * 3.5 / f.decay))
        }
        return b
    }

    private static func tom(_ sr: Double, _ f: Flavor, freq: Double, decay: Double = 0.3) -> [Float] {
        var b = buffer(decay * f.decay * 2, sr)
        var phase = 0.0
        for i in 0..<b.count {
            let t = Double(i) / sr
            phase += (freq * f.pitch * (1 + 0.5 * exp(-t * 25))) / sr
            b[i] = Float(sin(2 * .pi * phase) * exp(-t / (decay * f.decay)) * 0.85)
        }
        return b
    }

    private static func cowbell(_ sr: Double, _ f: Flavor) -> [Float] {
        var b = buffer(0.4, sr)
        for i in 0..<b.count {
            let t = Double(i) / sr
            let s = (sin(2 * .pi * 540 * f.pitch * t) > 0 ? 1.0 : -1.0) + (sin(2 * .pi * 800 * f.pitch * t) > 0 ? 1.0 : -1.0)
            b[i] = Float(s * 0.22 * exp(-t * 9))
        }
        return b
    }

    private static func shaker(_ sr: Double, _ f: Flavor, _ rng: inout SplitMix) -> [Float] {
        var b = buffer(0.12, sr)
        var prev = 0.0, hp = 0.0
        for i in 0..<b.count {
            let t = Double(i) / sr
            let n = rng.next()
            hp = 0.9 * (hp + n - prev); prev = n
            let env = sin(.pi * min(1, t / 0.12)) * exp(-t * 18)
            b[i] = Float(hp * env * 0.5 * f.noise)
        }
        return b
    }

    /// Decodes a user sample to mono float at the given rate.
    static func loadMono(_ url: URL, sampleRate: Double) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(min(file.length, Int64(sampleRate * 20)))) else { return nil }
        do { try file.read(into: input) } catch { return nil }
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else { return nil }
        let ratio = sampleRate / file.processingFormat.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024) else { return nil }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard let ch = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }
}
