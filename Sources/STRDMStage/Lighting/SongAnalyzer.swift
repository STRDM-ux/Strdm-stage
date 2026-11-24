import Foundation
import AVFoundation
import Accelerate

/// Listens to a song file and works out tempo, beat grid, key, energy sections and overall vibe.
/// Pure DSP (Accelerate), runs off the main thread, no internet needed.
enum SongAnalyzer {
    enum AnalysisError: LocalizedError {
        case unreadable, tooShort, fft
        var errorDescription: String? {
            switch self {
            case .unreadable: return "Couldn't read that audio file."
            case .tooShort: return "Song is too short to analyse (needs at least 10 seconds)."
            case .fft: return "Audio analysis failed to start."
            }
        }
    }

    struct Result: Sendable {
        let analysis: SongAnalysis
        let sections: [ShowSection]
    }

    static func analyze(url: URL) throws -> Result {
        let (mono, sampleRate) = try loadMono(url: url)
        guard Double(mono.count) / sampleRate >= 10 else { throw AnalysisError.tooShort }
        let duration = Double(mono.count) / sampleRate

        // ---- Frame features -------------------------------------------------
        let n = 1024
        let hop = 512
        let log2n = vDSP_Length(10)
        let half = n / 2
        let frameRate = sampleRate / Double(hop)
        let frameCount = (mono.count - n) / hop + 1
        guard frameCount > 64, let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { throw AnalysisError.fft }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        // Bin maps: pitch class (chroma), frequency band, timbre band
        var pitchClass = [Int](repeating: -1, count: half)
        var binFreq = [Float](repeating: 0, count: half)
        var band = [Int](repeating: 5, count: half)          // 0 sub … 5 air
        var timbre = [Int](repeating: 0, count: half)        // 12 log-spaced bands 40 Hz – 11 kHz
        let bandEdges: [Double] = [60, 150, 500, 2500, 6000]
        for k in 1..<half {
            let f = Double(k) * sampleRate / Double(n)
            binFreq[k] = Float(f)
            if f >= 55 && f <= 2000 {
                let midi = 12 * log2(f / 440) + 69
                pitchClass[k] = ((Int(midi.rounded()) % 12) + 12) % 12
            }
            band[k] = bandEdges.firstIndex { f < $0 } ?? 5
            timbre[k] = max(0, min(11, Int(log2(max(40, f) / 40) * 12 / log2(11000 / 40))))
        }
        let bassLimit = Int(150 * Double(n) / sampleRate)

        var frame = [Float](repeating: 0, count: n)
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        var logMag = [Float](repeating: 0, count: half)
        var prevLogMag = [Float](repeating: 0, count: half)

        var rms = [Float](repeating: 0, count: frameCount)
        var flux = [Float](repeating: 0, count: frameCount)
        var kickFlux = [Float](repeating: 0, count: frameCount)
        var snareFlux = [Float](repeating: 0, count: frameCount)
        var hatFlux = [Float](repeating: 0, count: frameCount)
        var bands = [[Float]](repeating: [Float](repeating: 0, count: frameCount), count: 6)
        var chromaFrames = [[Float]](repeating: [Float](repeating: 0, count: 12), count: frameCount)
        var timbreFrames = [[Float]](repeating: [Float](repeating: 0, count: 12), count: frameCount)
        var vocalness = [Float](repeating: 0, count: frameCount)
        var chroma = [Double](repeating: 0, count: 12)
        var centroidSum = 0.0, centroidWeight = 0.0
        var bassPower = 0.0, totalPower = 0.0

        mono.withUnsafeBufferPointer { samples in
            for f in 0..<frameCount {
                let start = samples.baseAddress! + f * hop
                var r: Float = 0
                vDSP_rmsqv(start, 1, &r, vDSP_Length(n))
                rms[f] = r
                vDSP_vmul(start, 1, window, 1, &frame, 1, vDSP_Length(n))

                real.withUnsafeMutableBufferPointer { rp in
                    imag.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        frame.withUnsafeBufferPointer { fp in
                            fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                                vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                            }
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
                    }
                }
                power[0] = 0

                var fx: Float = 0, kf: Float = 0, sf: Float = 0, hf: Float = 0
                var cNum = 0.0, cDen = 0.0
                var bandSum = [Float](repeating: 0, count: 6)
                var tb = [Float](repeating: 0, count: 12)
                var vocalLogSum: Float = 0, vocalLinSum: Float = 0, vocalBins: Float = 0
                for k in 1..<half {
                    let p = power[k]
                    let mag = sqrtf(p)
                    let lm = log1pf(100 * mag)
                    logMag[k] = lm
                    let d = lm - prevLogMag[k]
                    let fr = binFreq[k]
                    if d > 0 {
                        fx += d
                        if fr >= 40 && fr < 150 { kf += d }
                        else if (fr >= 180 && fr < 350) || (fr >= 1500 && fr < 4500) { sf += d }
                        else if fr >= 7000 { hf += d }
                    }
                    cNum += Double(fr * mag)
                    cDen += Double(mag)
                    bandSum[band[k]] += p
                    tb[timbre[k]] += mag
                    if fr >= 250 && fr <= 3500 {
                        vocalLogSum += logf(p + 1e-10)
                        vocalLinSum += p
                        vocalBins += 1
                    }
                    let pd = Double(p)
                    totalPower += pd
                    if k <= bassLimit { bassPower += pd }
                    let pc = pitchClass[k]
                    if pc >= 0 {
                        chroma[pc] += Double(mag) * Double(r)
                        chromaFrames[f][pc] += mag
                    }
                }
                flux[f] = fx; kickFlux[f] = kf; snareFlux[f] = sf; hatFlux[f] = hf
                for b in 0..<6 { bands[b][f] = log1pf(bandSum[b]) }
                for b in 0..<12 { timbreFrames[f][b] = log1pf(tb[b]) }
                // Vocals: strong, tonal (non-flat) energy in the voice range relative to the whole spectrum
                if vocalBins > 0 && vocalLinSum > 0 {
                    let flatness = expf(vocalLogSum / vocalBins) / (vocalLinSum / vocalBins)
                    let share = (bandSum[2] + bandSum[3]) / max(1e-9, bandSum.reduce(0, +))
                    vocalness[f] = max(0, (1 - flatness)) * share
                }
                swap(&prevLogMag, &logMag)
                if cDen > 0 {
                    centroidSum += (cNum / cDen) * Double(r)
                    centroidWeight += Double(r)
                }
            }
        }

        // ---- Tempo & beat tracking --------------------------------------------
        let onset = Self.normalizedOnset(flux, frameRate: frameRate)
        let (bpm, lag) = Self.estimateTempo(onset, frameRate: frameRate)
        let beatFrames = Self.trackBeats(onset, period: lag)
        var beatTimes = beatFrames.map { Double($0) / frameRate }
        if beatTimes.count < 8 {
            let phase = Self.estimatePhase(onset, lag: lag) / frameRate
            beatTimes = stride(from: phase, to: duration, by: 60 / bpm).map { $0 }
        }
        // Downbeats: the beat phase (of 4) with the most kick + harmonic change
        let kickOn = Self.normalizedOnset(kickFlux, frameRate: frameRate)
        var chromaChange = [Double](repeating: 0, count: beatTimes.count)
        for (i, t) in beatTimes.enumerated() where i > 0 {
            let a = Self.meanVector(chromaFrames, from: beatTimes[i - 1] * frameRate, to: t * frameRate)
            let b = Self.meanVector(chromaFrames, from: t * frameRate, to: (i + 1 < beatTimes.count ? beatTimes[i + 1] : t + 60 / bpm) * frameRate)
            chromaChange[i] = 1 - Self.cosine(a, b)
        }
        var phaseScore = [Double](repeating: 0, count: 4)
        for (i, t) in beatTimes.enumerated() {
            let fi = min(kickOn.count - 1, Int(t * frameRate))
            let k = (max(0, fi - 2)...min(kickOn.count - 1, fi + 2)).map { kickOn[$0] }.max() ?? 0
            phaseScore[i % 4] += k + 2 * chromaChange[i]
        }
        let downPhase = phaseScore.indices.max { phaseScore[$0] < phaseScore[$1] } ?? 0
        let beatOffset = beatTimes.indices.contains(downPhase) ? beatTimes[downPhase] : 0

        // ---- Drum hits -------------------------------------------------------------
        let snareOn = Self.normalizedOnset(snareFlux, frameRate: frameRate)
        let hatOn = Self.normalizedOnset(hatFlux, frameRate: frameRate)
        let kicks = Self.pickPeaks(kickOn, frameRate: frameRate, minGap: 0.12, sensitivity: 1.2)
        let snares = Self.pickPeaks(snareOn, frameRate: frameRate, minGap: 0.12, sensitivity: 1.4)
        let hats = Self.pickPeaks(hatOn, frameRate: frameRate, minGap: 0.06, sensitivity: 1.0)

        // ---- Loudness, brightness, bass, onsets ---------------------------------
        let meanRMS = Double(rms.reduce(0, +)) / Double(max(1, rms.count))
        let loudnessDB = 20 * log10(max(meanRMS, 1e-6))
        let centroid = centroidWeight > 0 ? centroidSum / centroidWeight : 1500
        let brightness = clamp((centroid - 1200) / 2300)
        let bassWeight = totalPower > 0 ? bassPower / totalPower : 0
        let onsetsPerSecond = Self.countPeaks(onset) / duration

        // ---- Key -------------------------------------------------------------
        let (key, isMajor) = Self.estimateKey(chroma)

        // ---- Curves (energy 2/s, the rest 4/s) ----------------------------------
        let smoothWindow = max(1, Int(frameRate * 0.5))
        var energyCurve: [Double] = []
        var i = 0
        while i < rms.count {
            let slice = rms[i..<min(rms.count, i + smoothWindow)]
            energyCurve.append(Double(slice.reduce(0, +)) / Double(slice.count))
            i += smoothWindow
        }
        let peakEnergy = Self.percentile(energyCurve, 0.95)
        energyCurve = energyCurve.map { clamp($0 / max(peakEnergy, 1e-6)) }
        let q = max(1, Int(frameRate / 4))
        let bassCurve = Self.curve(zip(bands[0], bands[1]).map { max($0, $1) }, step: q)
        let midCurve = Self.curve(zip(bands[2], bands[3]).map { max($0, $1) }, step: q)
        let highCurve = Self.curve(zip(bands[4], bands[5]).map { max($0, $1) }, step: q)
        let vocalCurve = Self.curve(vocalness, step: q)
        var hatDensity = [Double](repeating: 0, count: Int(duration * 4) + 1)
        for h in hats { let k = Int(h * 4); if k < hatDensity.count { hatDensity[k] += 1 } }
        let hatPeak = max(1, Self.percentile(hatDensity, 0.95))
        hatDensity = hatDensity.map { clamp($0 / hatPeak) }

        // ---- Structure --------------------------------------------------------------
        let bars = Self.bars(beatTimes: beatTimes, downPhase: downPhase, duration: duration, bpm: bpm)
        let sections = Self.findStructure(bars: bars, frameRate: frameRate, rms: rms, chroma: chromaFrames,
                                          timbre: timbreFrames, vocal: vocalCurve, kicks: kicks, snares: snares,
                                          hats: hats, duration: duration)

        // ---- Vibe ------------------------------------------------------------
        let kickRate = Double(kicks.count) / duration
        let beatRegularity = Self.regularity(kicks, period: 60 / bpm)
        let danceability = clamp(0.4 * beatRegularity + 0.3 * clamp((kickRate - 0.5) / 2) + 0.3 * clamp(1 - abs(bpm - 115) / 60))
        let arousal = 0.3 * clamp((bpm - 70) / 70)
            + 0.3 * clamp((onsetsPerSecond - 1) / 4)
            + 0.25 * clamp((loudnessDB + 24) / 16)
            + 0.15 * clamp(Double(snares.count + hats.count / 2) / duration / 4)
        let valence = 0.55 * (isMajor ? 1 : 0) + 0.45 * brightness
        let vibe = Self.classify(arousal: arousal, valence: valence, bpm: bpm, bass: bassWeight)
        let vocalShare = vocalCurve.isEmpty ? 0 : vocalCurve.filter { $0 > 0.45 }.count * 100 / vocalCurve.count
        let structure = sections.map { s -> String in
            let barsLen = Int(((s.end - s.start) / (240 / bpm)).rounded())
            return "\(s.label) \(barsLen)"
        }.joined(separator: " → ")

        let reasoning = [
            "\(Int(bpm.rounded())) BPM",
            key,
            bassWeight > 0.5 ? "heavy bass" : (bassWeight > 0.3 ? "solid bass" : "light bass"),
            brightness > 0.6 ? "bright mix" : (brightness < 0.35 ? "dark/warm mix" : "balanced mix"),
            arousal > 0.62 ? "high energy" : (arousal > 0.42 ? "medium energy" : "low energy"),
            "\(kicks.count) kicks · \(snares.count) snares",
            "vocals ~\(vocalShare)% of the song",
            "danceability \(Int(danceability * 100))%",
            String(format: "%.1f hits/sec", onsetsPerSecond)
        ].joined(separator: " · ")

        var analysis = SongAnalysis(duration: duration, bpm: bpm, beatOffset: beatOffset, key: key, isMajor: isMajor,
                                    loudnessDB: loudnessDB, brightness: brightness, bassWeight: bassWeight,
                                    onsetsPerSecond: onsetsPerSecond, arousal: arousal, valence: valence,
                                    energyCurve: energyCurve, suggestedVibe: vibe, reasoning: reasoning)
        analysis.beats = beatTimes.map { ($0 * 1000).rounded() / 1000 }
        analysis.firstDownbeat = downPhase
        analysis.kicks = kicks.map { ($0 * 1000).rounded() / 1000 }
        analysis.snares = snares.map { ($0 * 1000).rounded() / 1000 }
        analysis.hatCurve = hatDensity.map { ($0 * 100).rounded() / 100 }
        analysis.bassCurve = bassCurve
        analysis.midCurve = midCurve
        analysis.highCurve = highCurve
        analysis.vocalCurve = vocalCurve
        analysis.danceability = danceability
        analysis.structure = structure
        return Result(analysis: analysis, sections: sections)
    }

    // MARK: - Deep analysis helpers

    /// Dynamic-programming beat tracker (Ellis 2007): beats land on onsets while keeping a steady period.
    static func trackBeats(_ onset: [Double], period: Double) -> [Int] {
        let n = onset.count
        guard n > Int(period * 4), period > 2 else { return [] }
        let tightness = 120.0
        var score = onset
        var back = [Int](repeating: -1, count: n)
        let lo = Int(period * 0.5), hi = Int(period * 2)
        for i in 0..<n {
            var best = -Double.infinity, bestJ = -1
            var j = i - hi
            while j <= i - lo {
                if j >= 0 {
                    let r = log(Double(i - j) / period)
                    let s = score[j] - tightness * r * r
                    if s > best { best = s; bestJ = j }
                }
                j += 1
            }
            if bestJ >= 0 && best > 0 { score[i] = onset[i] + best; back[i] = bestJ }
        }
        // Start from the best score in the last period and walk back
        let tailStart = max(0, n - Int(period))
        var cur = (tailStart..<n).max { score[$0] < score[$1] } ?? (n - 1)
        var beats: [Int] = []
        while cur >= 0 {
            beats.append(cur)
            cur = back[cur]
        }
        return beats.reversed()
    }

    static func pickPeaks(_ x: [Double], frameRate: Double, minGap: Double, sensitivity: Double) -> [Double] {
        guard x.count > 3 else { return [] }
        let w = max(2, Int(frameRate * 0.5))
        var out: [Double] = []
        var last = -1e9
        var runSum = 0.0, runSq = 0.0
        for i in 0..<x.count {
            runSum += x[i]; runSq += x[i] * x[i]
            if i >= w { runSum -= x[i - w]; runSq -= x[i - w] * x[i - w] }
            let cnt = Double(min(i + 1, w))
            let mean = runSum / cnt
            let sd = sqrt(max(0, runSq / cnt - mean * mean))
            guard i > 0, i < x.count - 1 else { continue }
            if x[i] > mean + sensitivity * sd && x[i] > 0.08 && x[i] >= x[i - 1] && x[i] > x[i + 1] {
                let t = Double(i) / frameRate
                if t - last >= minGap { out.append(t); last = t }
            }
        }
        return out
    }

    static func curve(_ x: [Float], step: Int) -> [Double] {
        var out: [Double] = []
        var i = 0
        while i < x.count {
            let slice = x[i..<min(x.count, i + step)]
            out.append(Double(slice.reduce(0, +)) / Double(slice.count))
            i += step
        }
        let lo = percentile(out, 0.05), hi = percentile(out, 0.97)
        return out.map { ((clamp(($0 - lo) / max(1e-6, hi - lo))) * 100).rounded() / 100 }
    }

    static func meanVector(_ frames: [[Float]], from a: Double, to b: Double) -> [Double] {
        let lo = max(0, min(frames.count - 1, Int(a))), hi = max(lo + 1, min(frames.count, Int(b)))
        let dim = frames.first?.count ?? 0
        var v = [Double](repeating: 0, count: dim)
        for f in lo..<hi { for d in 0..<dim { v[d] += Double(frames[f][d]) } }
        let c = Double(hi - lo)
        return v.map { $0 / c }
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<min(a.count, b.count) { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? dot / sqrt(na * nb) : 0
    }

    static func regularity(_ hits: [Double], period: Double) -> Double {
        guard hits.count > 8, period > 0 else { return 0 }
        var good = 0
        for i in 1..<hits.count {
            let r = (hits[i] - hits[i - 1]) / period
            let nearest = max(0.5, (r * 2).rounded() / 2)
            if abs(r - nearest) < 0.08 { good += 1 }
        }
        return Double(good) / Double(hits.count - 1)
    }

    /// Bar boundaries (seconds), 4 beats each, starting at the first downbeat (with a pickup bar if needed).
    static func bars(beatTimes: [Double], downPhase: Int, duration: Double, bpm: Double) -> [Double] {
        var b: [Double] = []
        if downPhase < beatTimes.count, beatTimes[downPhase] > 0.3 { b.append(0) }
        var i = downPhase
        while i < beatTimes.count { b.append(beatTimes[i]); i += 4 }
        let barLen = 240 / bpm
        while let last = b.last, last + barLen < duration { b.append(last + barLen) }
        if (b.last ?? 0) < duration { b.append(duration) }
        return b
    }

    struct Bar {
        var start: Double, end: Double
        var energy: Double
        var chroma: [Double], timbre: [Double]
        var vocal: Double, kicks: Int, snares: Int, hats: Int
    }

    /// Song structure from bar-level features: novelty boundaries, repetition groups, builds and drops.
    static func findStructure(bars edges: [Double], frameRate: Double, rms: [Float], chroma: [[Float]], timbre: [[Float]],
                              vocal: [Double], kicks: [Double], snares: [Double], hats: [Double], duration: Double) -> [ShowSection] {
        guard edges.count > 2 else { return [] }
        func count(_ hits: [Double], _ a: Double, _ b: Double) -> Int { hits.filter { $0 >= a && $0 < b }.count }
        var bars: [Bar] = []
        for i in 0..<(edges.count - 1) {
            let a = edges[i], b = edges[i + 1]
            let lo = min(rms.count - 1, Int(a * frameRate)), hi = max(lo + 1, min(rms.count, Int(b * frameRate)))
            let e = Double(rms[lo..<hi].reduce(0, +)) / Double(hi - lo)
            let vlo = min(vocal.count - 1, Int(a * 4)), vhi = max(vlo + 1, min(vocal.count, Int(b * 4)))
            let v = vocal.isEmpty ? 0 : vocal[vlo..<vhi].reduce(0, +) / Double(vhi - vlo)
            bars.append(Bar(start: a, end: b, energy: e,
                            chroma: meanVector(chroma, from: a * frameRate, to: b * frameRate),
                            timbre: meanVector(timbre, from: a * frameRate, to: b * frameRate),
                            vocal: v, kicks: count(kicks, a, b), snares: count(snares, a, b), hats: count(hats, a, b)))
        }
        let n = bars.count
        let ePeak = max(1e-6, percentile(bars.map(\.energy), 0.92))
        let eNorm = bars.map { clamp($0.energy / ePeak) }

        // Self-similarity (timbre + harmony) and checkerboard novelty
        func feature(_ b: Bar) -> [Double] {
            let cn = sqrt(b.chroma.map { $0 * $0 }.reduce(0, +)) + 1e-9
            let tn = sqrt(b.timbre.map { $0 * $0 }.reduce(0, +)) + 1e-9
            return b.chroma.map { $0 / cn } + b.timbre.map { 1.4 * $0 / tn }
        }
        let feats = bars.map(feature)
        var ssm = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n { for j in i..<n { let s = cosine(feats[i], feats[j]); ssm[i][j] = s; ssm[j][i] = s } }
        let K = 4
        var novelty = [Double](repeating: 0, count: n)
        for i in 1..<n {
            var s = 0.0
            for a in -K..<K { for b in -K..<K {
                let x = i + a, y = i + b
                guard x >= 0, y >= 0, x < n, y < n else { continue }
                let sign: Double = (a < 0) == (b < 0) ? 1 : -1
                s += sign * ssm[x][y]
            } }
            // energy steps are boundaries too
            let before = eNorm[max(0, i - 2)..<i].reduce(0, +) / Double(min(2, i))
            let after = eNorm[i..<min(n, i + 2)].reduce(0, +) / Double(min(2, n - i))
            novelty[i] = max(0, s) + 6 * abs(after - before)
        }
        let nMean = novelty.reduce(0, +) / Double(n)
        let nSD = sqrt(novelty.map { ($0 - nMean) * ($0 - nMean) }.reduce(0, +) / Double(n))
        var cuts: [Int] = [0]
        for i in 2..<max(3, n - 1) where i < n - 1 {
            guard novelty[i] > nMean + 0.4 * nSD, novelty[i] >= novelty[i - 1], novelty[i] >= novelty[i + 1] else { continue }
            // snap to the 4-bar phrase grid when close
            var c = i
            let snapped = Int((Double(i) / 4).rounded()) * 4
            if abs(snapped - i) == 1 && snapped > 0 && snapped < n { c = snapped }
            if c - (cuts.last ?? 0) >= 4 { cuts.append(c) } else if novelty[i] > novelty[cuts.last ?? 0], cuts.count > 1 { cuts[cuts.count - 1] = c }
        }
        if n - (cuts.last ?? 0) < 3, cuts.count > 1 { cuts.removeLast() }
        cuts.append(n)

        // Segments + repetition groups
        struct Seg { var a: Int; var b: Int; var energy: Double; var vocal: Double; var feat: [Double]
                     var kickRate: Double; var snareRate: Double; var hatRate: Double; var slope: Double; var group = -1 }
        var segs: [Seg] = []
        for k in 0..<(cuts.count - 1) {
            let a = cuts[k], b = cuts[k + 1]
            let len = Double(b - a)
            let e = eNorm[a..<b].reduce(0, +) / len
            let v = bars[a..<b].map(\.vocal).reduce(0, +) / len
            var f = [Double](repeating: 0, count: feats[0].count)
            for i in a..<b { for d in 0..<f.count { f[d] += feats[i][d] / len } }
            let secs = bars[b - 1].end - bars[a].start
            let slope = len >= 2 ? (eNorm[(b - 1)] + eNorm[max(a, b - 2)]) / 2 - (eNorm[a] + eNorm[min(b - 1, a + 1)]) / 2 : 0
            segs.append(Seg(a: a, b: b, energy: e, vocal: v, feat: f,
                            kickRate: Double(bars[a..<b].map(\.kicks).reduce(0, +)) / secs,
                            snareRate: Double(bars[a..<b].map(\.snares).reduce(0, +)) / secs,
                            hatRate: Double(bars[a..<b].map(\.hats).reduce(0, +)) / secs, slope: slope))
        }
        var groups = 0
        for i in segs.indices where segs[i].group < 0 {
            segs[i].group = groups
            for j in (i + 1)..<segs.count where segs[j].group < 0 && cosine(segs[i].feat, segs[j].feat) > 0.965
                && abs(segs[i].energy - segs[j].energy) < 0.25 {
                segs[j].group = groups
            }
            groups += 1
        }
        // The chorus: the loudest musical idea that repeats
        var groupEnergy: [Int: (sum: Double, count: Int)] = [:]
        for s in segs { groupEnergy[s.group, default: (0, 0)].sum += s.energy; groupEnergy[s.group, default: (0, 0)].count += 1 }
        let chorusGroup = groupEnergy.filter { $0.value.count >= 2 }
            .max { $0.value.sum / Double($0.value.count) < $1.value.sum / Double($1.value.count) }?.key

        let placeholder = SectionLook(colorA: .white, colorB: .white, intensity: 1, chase: .still,
                                      beatsPerStep: 4, strobeBeats: 0, mover: .still, haze: 0)
        var out: [ShowSection] = []
        var verse = 0, chorus = 0, drop = 0
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        for (k, s) in segs.enumerated() {
            let next = k + 1 < segs.count ? segs[k + 1] : nil
            let prev = k > 0 ? segs[k - 1] : nil
            let isFirst = k == 0, isLast = k == segs.count - 1
            var label: String
            let jump = s.energy - (prev?.energy ?? s.energy)
            let builds = s.slope > 0.18 && (next.map { $0.energy > s.energy + 0.1 } ?? false)
                && (s.b - s.a) <= 8
            if isFirst && s.energy < 0.7 {
                label = "Intro"
            } else if isLast && (s.energy < 0.65 || s.slope < -0.2) {
                label = "Outro"
            } else if builds {
                label = s.vocal > 0.5 ? "Pre-Chorus" : "Build"
            } else if s.energy >= 0.72 && (jump > 0.25 || prev.map { $0.slope > 0.18 } == true) && s.vocal < 0.45 && s.kickRate > 1 {
                drop += 1; label = drop > 1 ? "Drop \(drop)" : "Drop"
            } else if s.group == chorusGroup || s.energy >= 0.8 {
                chorus += 1; label = "Chorus \(chorus)"
            } else if s.energy < 0.42 {
                label = s.vocal > 0.5 && groupEnergy[s.group]?.count == 1 ? "Bridge" : "Breakdown"
            } else {
                verse += 1; label = "Verse \(verse)"
            }
            let start = k == 0 ? 0 : bars[s.a].start
            let end = isLast ? duration : bars[s.b - 1].end
            var sec = ShowSection(label: label, start: start, end: end, energy: s.energy, look: placeholder)
            sec.vocal = (s.vocal * 100).rounded() / 100
            sec.group = String(letters[min(letters.count - 1, s.group)])
            // Key of this section
            var ch = [Double](repeating: 0, count: 12)
            for i in s.a..<s.b { for d in 0..<12 { ch[d] += bars[i].chroma[d] } }
            sec.key = estimateKey(ch).0
            out.append(sec)
        }
        return out
    }

    // MARK: - Audio loading

    /// Decodes the file to mono and decimates to ~22–24 kHz (plenty for tempo/energy/key).
    private static func loadMono(url: URL) throws -> ([Float], Double) {
        guard let file = try? AVAudioFile(forReading: url) else {
            // Video files (.mp4/.mov) and anything AVAudioFile can't open: decode the soundtrack instead.
            let rate = 22_050.0
            let samples = try MediaSupport.decodeMono(url, sampleRate: rate)
            guard !samples.isEmpty else { throw AnalysisError.unreadable }
            return (samples, rate)
        }
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let decim = format.sampleRate >= 88_200 ? 4 : (format.sampleRate >= 44_100 ? 2 : 1)
        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw AnalysisError.unreadable }
        var out: [Float] = []
        out.reserveCapacity(Int(file.length) / decim + 1)
        var acc: Float = 0
        var accCount = 0
        while file.framePosition < file.length {
            do { try file.read(into: buffer, frameCount: chunk) } catch { break }
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let data = buffer.floatChannelData else { throw AnalysisError.unreadable }
            for i in 0..<frames {
                var s: Float = 0
                for c in 0..<channels { s += data[c][i] }
                acc += s / Float(channels)
                accCount += 1
                if accCount == decim {
                    out.append(acc / Float(decim))
                    acc = 0
                    accCount = 0
                }
            }
        }
        return (out, format.sampleRate / Double(decim))
    }

    // MARK: - Tempo

    private static func normalizedOnset(_ flux: [Float], frameRate: Double) -> [Double] {
        let x = flux.map(Double.init)
        let w = max(1, Int(frameRate * 0.25))
        var out = [Double](repeating: 0, count: x.count)
        var runSum = 0.0
        for i in 0..<x.count {
            runSum += x[i]
            if i >= 2 * w { runSum -= x[i - 2 * w] }
            let count = Double(min(i + 1, 2 * w))
            out[i] = max(0, x[i] - runSum / count)
        }
        let peak = out.max() ?? 1
        return peak > 0 ? out.map { $0 / peak } : out
    }

    private static func estimateTempo(_ onset: [Double], frameRate: Double) -> (Double, Double) {
        let minLag = Int(frameRate * 60 / 180)
        let maxLag = Int(frameRate * 60 / 70)
        let limit = min(onset.count, Int(frameRate * 120))   // first two minutes is enough
        guard maxLag + 2 < limit else { return (100, frameRate * 0.6) }
        var scores = [Double](repeating: 0, count: maxLag + 2)
        for lag in minLag...(maxLag + 1) {
            var s = 0.0
            var i = 0
            while i + lag < limit { s += onset[i] * onset[i + lag]; i += 1 }
            let bpm = 60 * frameRate / Double(lag)
            let w = exp(-0.5 * pow(log2(bpm / 110) / 0.9, 2))   // mild preference for 80–140
            scores[lag] = s * w
        }
        var best = minLag
        for lag in minLag...maxLag where scores[lag] > scores[best] { best = lag }
        // Parabolic refinement
        var refined = Double(best)
        if best > minLag {
            let a = scores[best - 1], b = scores[best], c = scores[best + 1]
            let denom = a - 2 * b + c
            if abs(denom) > 1e-9 { refined += 0.5 * (a - c) / denom }
        }
        var bpm = 60 * frameRate / refined
        while bpm < 75 { bpm *= 2 }
        while bpm > 170 { bpm /= 2 }
        return ((bpm * 10).rounded() / 10, 60 * frameRate / bpm)
    }

    private static func estimatePhase(_ onset: [Double], lag: Double) -> Double {
        guard lag > 1 else { return 0 }
        var bestPhase = 0
        var bestScore = -1.0
        for phase in 0..<Int(lag) {
            var s = 0.0
            var t = Double(phase)
            while Int(t) < onset.count { s += onset[Int(t)]; t += lag }
            if s > bestScore { bestScore = s; bestPhase = phase }
        }
        return Double(bestPhase)
    }

    private static func countPeaks(_ onset: [Double]) -> Double {
        guard onset.count > 2 else { return 0 }
        let mean = onset.reduce(0, +) / Double(onset.count)
        let sd = sqrt(onset.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(onset.count))
        let threshold = mean + sd
        var count = 0
        for i in 1..<(onset.count - 1) where onset[i] > threshold && onset[i] >= onset[i - 1] && onset[i] > onset[i + 1] {
            count += 1
        }
        return Double(count)
    }

    // MARK: - Key (Krumhansl–Schmuckler)

    private static let majorProfile = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let minorProfile = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
    private static let noteNames = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

    static func estimateKey(_ chroma: [Double]) -> (String, Bool) {
        var best = (score: -Double.infinity, root: 0, major: true)
        for root in 0..<12 {
            for major in [true, false] {
                let profile = major ? majorProfile : minorProfile
                let rotated = (0..<12).map { profile[($0 - root + 12) % 12] }
                let r = correlation(chroma, rotated)
                if r > best.score { best = (r, root, major) }
            }
        }
        return ("\(noteNames[best.root]) \(best.major ? "major" : "minor")", best.major)
    }

    private static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
        var num = 0.0, da = 0.0, db = 0.0
        for i in 0..<a.count {
            num += (a[i] - ma) * (b[i] - mb)
            da += (a[i] - ma) * (a[i] - ma)
            db += (b[i] - mb) * (b[i] - mb)
        }
        return da > 0 && db > 0 ? num / sqrt(da * db) : 0
    }

    // MARK: - Sections

    /// Splits the song into 2-bar blocks, levels each block low/mid/high, then merges runs into labelled sections.
    private static func findSections(rms: [Float], frameRate: Double, duration: Double, bpm: Double, beatOffset: Double) -> [ShowSection] {
        let blockDur = 8 * 60 / bpm
        var blocks: [(start: Double, end: Double, energy: Double)] = []
        var t = beatOffset
        if t > 0.5 { blocks.append((0, t, 0)) }
        while t < duration {
            let end = min(duration, t + blockDur)
            let lo = min(Int(t * frameRate), rms.count - 1)
            let hi = min(rms.count, max(lo + 1, Int(end * frameRate)))
            let slice = rms[lo..<hi]
            blocks.append((t, end, Double(slice.reduce(0, +)) / Double(max(1, slice.count))))
            t = end
        }
        if blocks.count > 1, blocks[0].energy == 0 { blocks[0].energy = blocks[1].energy * 0.6 }
        let peak = percentile(blocks.map(\.energy), 0.9)
        let norm = blocks.map { clamp($0.energy / max(peak, 1e-6)) }

        // Level 0 = low, 1 = mid, 2 = high, median-filtered to ignore single-block blips.
        var levels = norm.map { $0 >= 0.8 ? 2 : ($0 < 0.5 ? 0 : 1) }
        if levels.count >= 3 {
            var filtered = levels
            for i in 1..<(levels.count - 1) {
                filtered[i] = [levels[i - 1], levels[i], levels[i + 1]].sorted()[1]
            }
            levels = filtered
        }

        // Merge runs
        struct Run { var start: Double; var end: Double; var level: Int; var energies: [Double] }
        var runs: [Run] = []
        for (i, b) in blocks.enumerated() {
            if var last = runs.last, last.level == levels[i] {
                last.end = b.end
                last.energies.append(norm[i])
                runs[runs.count - 1] = last
            } else {
                runs.append(Run(start: b.start, end: b.end, level: levels[i], energies: [norm[i]]))
            }
        }
        // Absorb very short runs (< 1 block) into the previous one
        var merged: [Run] = []
        for r in runs {
            if let last = merged.last, r.end - r.start < blockDur * 0.99 {
                merged[merged.count - 1].end = r.end
                merged[merged.count - 1].energies += r.energies
                _ = last
            } else {
                merged.append(r)
            }
        }

        let placeholder = SectionLook(colorA: .white, colorB: .white, intensity: 1, chase: .still,
                                      beatsPerStep: 4, strobeBeats: 0, mover: .still, haze: 0)
        var sections: [ShowSection] = []
        var verse = 0, chorus = 0
        for (i, r) in merged.enumerated() {
            let energy = r.energies.reduce(0, +) / Double(max(1, r.energies.count))
            let prevEnergy = i > 0 ? merged[i - 1].energies.reduce(0, +) / Double(max(1, merged[i - 1].energies.count)) : 0
            let label: String
            switch r.level {
            case 0:
                if i == 0 { label = "Intro" }
                else if i == merged.count - 1 { label = "Outro" }
                else { label = "Breakdown" }
            case 2:
                if energy - prevEnergy >= 0.3 && i > 0 { label = "Drop" }
                else { chorus += 1; label = "Chorus \(chorus)" }
            default:
                if i == 0 { label = "Intro" }
                else if i == merged.count - 1 { label = "Outro" }
                else { verse += 1; label = "Verse \(verse)" }
            }
            sections.append(ShowSection(label: label, start: r.start, end: r.end, energy: energy, look: placeholder))
        }
        if let first = sections.first, first.start > 0 { sections[0].start = 0 }
        return sections
    }

    // MARK: - Vibe

    static func classify(arousal: Double, valence: Double, bpm: Double, bass: Double) -> Vibe {
        if bass >= 0.5 && (80...115).contains(bpm) && arousal >= 0.4 && arousal < 0.8 { return .dancehall }
        if arousal >= 0.62 { return valence >= 0.45 ? .hype : .dark }
        if arousal >= 0.45 { return valence >= 0.5 ? .euphoric : .dark }
        return valence >= 0.45 ? .romantic : .chill
    }

    // MARK: - Helpers

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 1 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }
}

func clamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { max(lo, min(hi, x)) }
