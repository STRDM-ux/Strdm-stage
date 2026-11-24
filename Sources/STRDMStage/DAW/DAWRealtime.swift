import Foundation
import AVFoundation
import AudioToolbox
import os

// Everything in this file is touched from the audio render thread or the MIDI scheduler thread.

/// Transport snapshot shared with the render thread.
struct TransportState: Sendable {
    var playing = false
    var anchorSample: Double = 0         // engine sample time at which `startBeat` sounds
    var startBeat: Double = 0
    var samplesPerBeat: Double = 24_000
    var sampleRate: Double = 48_000
    var loopOn = false
    var loopStart: Double = 0
    var loopEnd: Double = 16
    var metronome = false
    var clickUntilBeat: Double = -1      // count-in: click forced on until this beat
    var beatsPerBar = 4

    /// Musical position (beats) for an engine sample time, honouring the loop. nil before the anchor or when stopped.
    func beat(at sample: Double) -> Double? {
        guard playing, sample >= anchorSample else { return nil }
        var b = startBeat + (sample - anchorSample) / samplesPerBeat
        if loopOn, loopEnd > loopStart, startBeat < loopEnd, b >= loopEnd {
            let len = loopEnd - loopStart
            b = loopStart + (b - loopEnd).truncatingRemainder(dividingBy: len)
        }
        return b
    }
}

/// Decoded audio for clip playback (stereo, engine sample rate).
final class AudioData: @unchecked Sendable {
    let left: [Float]
    let right: [Float]
    let frames: Int
    let sampleRate: Double
    let peaks: [Float]                   // one value per 512 frames, for waveforms

    init(left: [Float], right: [Float], sampleRate: Double) {
        self.left = left
        self.right = right
        self.frames = min(left.count, right.count)
        self.sampleRate = sampleRate
        var p: [Float] = []
        p.reserveCapacity(frames / 512 + 1)
        var i = 0
        while i < frames {
            var m: Float = 0
            let end = min(frames, i + 512)
            var j = i
            while j < end { m = max(m, abs(left[j]), abs(right[j])); j += 4 }
            p.append(m)
            i = end
        }
        peaks = p
    }

    var duration: Double { Double(frames) / sampleRate }

    /// Decodes any audio (or video soundtrack) file to stereo Float32 at `sampleRate`.
    static func decode(path: String, sampleRate: Double) -> AudioData? {
        var url = URL(fileURLWithPath: path)
        if MediaSupport.isVideo(url) {
            guard let ready = MediaSupport.readyAudio(for: url) else { MediaSupport.prepare(url); return nil }
            url = ready
        }
        guard let file = try? AVAudioFile(forReading: url),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        do { try file.read(into: input) } catch { return nil }
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else { return nil }
        if file.processingFormat.channelCount == 1 { converter.channelMap = [0, 0] }
        let ratio = sampleRate / file.processingFormat.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(input.frameLength) * ratio) + 8192) else { return nil }
        var fed = false
        var err: NSError?
        _ = converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard let ch = out.floatChannelData else { return nil }
        let n = Int(out.frameLength)
        let l = Array(UnsafeBufferPointer(start: ch[0], count: n))
        let r = out.format.channelCount > 1 ? Array(UnsafeBufferPointer(start: ch[1], count: n)) : l
        return AudioData(left: l, right: r, sampleRate: sampleRate)
    }
}

struct ClipRender: Sendable {
    let data: AudioData
    let startBeat: Double
    let endBeat: Double
    let offsetFrames: Double
    let gain: Float
    let fadeIn: Double
    let fadeOut: Double
}

/// The realtime side of the Studio: transport, clock, per-track clip lists, metering, MIDI scheduling.
final class DAWRealtime: @unchecked Sendable {
    let transport = OSAllocatedUnfairLock(initialState: TransportState())
    let clock = OSAllocatedUnfairLock(initialState: 0.0)            // latest engine render sample time
    let meters = OSAllocatedUnfairLock(initialState: [UUID: Float]())

    // MARK: Audio clip source node

    func makeAudioTrackNode(format: AVAudioFormat) -> (AVAudioSourceNode, OSAllocatedUnfairLock<[ClipRender]>) {
        let clips = OSAllocatedUnfairLock(initialState: [ClipRender]())
        let transport = self.transport
        let node = AVAudioSourceNode(format: format) { isSilence, timestamp, frameCount, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            let frames = Int(frameCount)
            for b in buffers { b.mData?.assumingMemoryBound(to: Float.self).update(repeating: 0, count: frames) }
            let t = transport.withLock { $0 }
            guard t.playing else { isSilence.pointee = true; return noErr }
            let list = clips.withLock { $0 }
            guard !list.isEmpty, buffers.count >= 1, let lp = buffers[0].mData?.assumingMemoryBound(to: Float.self) else {
                isSilence.pointee = true
                return noErr
            }
            let rp = buffers.count > 1 ? (buffers[1].mData?.assumingMemoryBound(to: Float.self) ?? lp) : lp
            let t0 = timestamp.pointee.mSampleTime
            for i in 0..<frames {
                guard let b = t.beat(at: t0 + Double(i)) else { continue }
                for c in list where b >= c.startBeat && b < c.endBeat {
                    let idx = Int(c.offsetFrames + (b - c.startBeat) * t.samplesPerBeat)
                    guard idx >= 0, idx < c.data.frames else { continue }
                    var g = c.gain
                    if c.fadeIn > 0, b - c.startBeat < c.fadeIn { g *= Float((b - c.startBeat) / c.fadeIn) }
                    if c.fadeOut > 0, c.endBeat - b < c.fadeOut { g *= Float((c.endBeat - b) / c.fadeOut) }
                    lp[i] += c.data.left[idx] * g
                    if rp != lp { rp[i] += c.data.right[idx] * g }
                }
            }
            return noErr
        }
        return (node, clips)
    }

    // MARK: Metronome (also drives the clock the MIDI scheduler reads)

    func makeMetronome(format: AVAudioFormat) -> AVAudioSourceNode {
        final class State { var lastBeat = -1.0; var remaining = 0; var freq = 1500.0; var n = 0 }
        let state = State()
        let transport = self.transport
        let clock = self.clock
        return AVAudioSourceNode(format: format) { isSilence, timestamp, frameCount, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            let frames = Int(frameCount)
            for b in buffers { b.mData?.assumingMemoryBound(to: Float.self).update(repeating: 0, count: frames) }
            let t0 = timestamp.pointee.mSampleTime
            clock.withLock { $0 = t0 }
            let t = transport.withLock { $0 }
            guard t.playing, buffers.count >= 1, let lp = buffers[0].mData?.assumingMemoryBound(to: Float.self) else {
                isSilence.pointee = true
                state.lastBeat = -1
                return noErr
            }
            let rp = buffers.count > 1 ? (buffers[1].mData?.assumingMemoryBound(to: Float.self) ?? lp) : lp
            let clickLen = Int(t.sampleRate * 0.035)
            for i in 0..<frames {
                guard let b = t.beat(at: t0 + Double(i)) else { continue }
                let on = t.metronome || b < t.clickUntilBeat
                if on && (floor(b) != floor(state.lastBeat) || state.lastBeat < 0) && b - floor(b) < 0.05 {
                    let beatInBar = Int(floor(b)) % max(1, t.beatsPerBar)
                    state.freq = beatInBar == 0 ? 2000 : 1400
                    state.remaining = clickLen
                    state.n = 0
                }
                state.lastBeat = b
                if state.remaining > 0 {
                    let env = Float(state.remaining) / Float(clickLen)
                    let s = Float(sin(2 * .pi * state.freq * Double(state.n) / t.sampleRate)) * env * env * 0.5
                    lp[i] += s
                    if rp != lp { rp[i] += s }
                    state.remaining -= 1
                    state.n += 1
                }
            }
            return noErr
        }
    }

    // MARK: Metering

    func meterTap(_ id: UUID) -> AVAudioNodeTapBlock {
        let meters = self.meters
        return { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            var peak: Float = 0
            let n = Int(buffer.frameLength)
            for ch in 0..<Int(buffer.format.channelCount) {
                var i = 0
                while i < n { peak = max(peak, abs(data[ch][i])); i += 2 }
            }
            meters.withLock { m in m[id] = max(peak, (m[id] ?? 0) * 0.85) }
        }
    }
}

// MARK: - MIDI scheduler

struct SchedNote: Sendable {
    let start: Double        // absolute beat
    let length: Double
    let pitch: UInt8
    let velocity: UInt8
}

struct SchedTrack: @unchecked Sendable {
    let block: AUScheduleMIDIEventBlock
    let notes: [SchedNote]   // sorted by start
}

/// Sends note events to instruments ~120 ms ahead with sample-accurate timestamps.
final class MIDIScheduler: @unchecked Sendable {
    private let rt: DAWRealtime
    let tracks = OSAllocatedUnfairLock(initialState: [SchedTrack]())
    private let queue = DispatchQueue(label: "strdm.daw.midi", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var scheduledUntil = 0.0
    private let lookahead = 0.12
    /// Set during offline bounces so the live timer doesn't double-schedule.
    let suspended = OSAllocatedUnfairLock(initialState: false)

    init(rt: DAWRealtime) { self.rt = rt }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func reset(from sample: Double) { queue.sync { scheduledUntil = sample } }

    private func tick() {
        guard !suspended.withLock({ $0 }) else { return }
        let t = rt.transport.withLock { $0 }
        guard t.playing else { return }
        let now = rt.clock.withLock { $0 }
        let from = max(scheduledUntil, now, t.anchorSample)
        let to = max(now, t.anchorSample) + lookahead * t.sampleRate
        guard to > from else { return }
        scheduleWindow(from: from, to: to, transport: t)
        scheduledUntil = to
    }

    /// Schedules every note that starts in [from, to) (engine sample times). Used live and for offline bounces.
    func scheduleWindow(from: Double, to: Double, transport t: TransportState) {
        let list = tracks.withLock { $0 }
        guard !list.isEmpty else { return }
        var a = from
        var guardCount = 0
        while a < to - 0.5 && guardCount < 64 {
            guardCount += 1
            guard let beatA = t.beat(at: a) else { a = max(a + 1, t.anchorSample); continue }
            var segEnd = to
            let looping = t.loopOn && t.loopEnd > t.loopStart && t.startBeat < t.loopEnd && beatA < t.loopEnd
            if looping { segEnd = min(to, a + (t.loopEnd - beatA) * t.samplesPerBeat) }
            let beatB = beatA + (segEnd - a) / t.samplesPerBeat
            for tr in list {
                for n in tr.notes where n.start >= beatA - 1e-9 && n.start < beatB {
                    let on = a + (n.start - beatA) * t.samplesPerBeat
                    var offBeat = n.start + n.length
                    if looping && offBeat > t.loopEnd { offBeat = t.loopEnd }
                    let off = on + max(1, (offBeat - n.start) * t.samplesPerBeat - 2)
                    var onBytes: [UInt8] = [0x90, n.pitch, max(1, n.velocity)]
                    var offBytes: [UInt8] = [0x80, n.pitch, 0]
                    tr.block(AUEventSampleTime(on), 0, 3, &onBytes)
                    tr.block(AUEventSampleTime(off), 0, 3, &offBytes)
                }
            }
            if segEnd <= a { break }
            a = segEnd
        }
    }

    func allNotesOff(at sample: AUEventSampleTime = AUEventSampleTimeImmediate) {
        for tr in tracks.withLock({ $0 }) {
            var a: [UInt8] = [0xB0, 123, 0]
            var b: [UInt8] = [0xB0, 120, 0]
            tr.block(sample, 0, 3, &a)
            tr.block(sample, 0, 3, &b)
        }
    }
}
