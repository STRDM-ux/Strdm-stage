import Foundation

/// Musical context for one frame of a song show.
struct PatternContext {
    var beat: Double                 // song beat
    var sectionStartBeat: Double
    var sectionEndBeat: Double
    var beatsPerBar: Double = 4
    /// Local loudness relative to the section (−1 quieter … +1 louder).
    var energyDelta: Double = 0
    /// Live drum and band signals from the analyser (0…1): pulses on real hits, curves for density.
    var kick: Double = 0
    var snare: Double = 0
    var hats: Double = 0
    var vocal: Double = 0
    var bass: Double = 0
}

/// What a section is doing right now, after phrasing, fills and build-ups are applied.
struct ResolvedPattern {
    var chase: ChaseKind
    var mover: MoverMode
    var stepBeats: Double
    var phraseIndex: Int
    var reversed: Bool
    var colorShift: Int             // rotates A/B/C between phrases
    var levelScale: Double
    var buildProgress: Double?      // 0…1 during a build into the next section
    var breath: Bool                // the half-beat of darkness before a big section lands
    var inFill: Bool
    var moverSpeed: Double
}

enum PatternEngine {

    static func resolve(_ look: SectionLook, _ ctx: PatternContext) -> ResolvedPattern {
        let bpb = ctx.beatsPerBar
        let local = max(0, ctx.beat - ctx.sectionStartBeat)
        let seed = look.seed ?? 0
        let phraseBeats = Double(max(0, look.phraseBars ?? 0)) * bpb
        let phraseIndex = phraseBeats > 0 ? Int(local / phraseBeats) : 0
        let beatInPhrase = phraseBeats > 0 ? local - Double(phraseIndex) * phraseBeats : local

        var chase = look.chase
        var mover = look.mover
        if phraseBeats > 0 {
            if let v = look.variations, !v.isEmpty { chase = v[(phraseIndex + seed) % v.count] }
            if let v = look.moverVariations, !v.isEmpty { mover = v[(phraseIndex + seed / 2) % v.count] }
        }
        var step = max(0.25, look.beatsPerStep)
        var level = 1.0
        var moverSpeed = 1.0

        // Follow the song's own energy inside the section.
        level *= 1 + 0.18 * max(-1, min(1, ctx.energyDelta))
        if ctx.energyDelta > 0.45 && step > 0.5 { step /= 2; moverSpeed = 1.5 }

        // Fill: the last beats of a phrase run fast, then snap back on the "1".
        var inFill = false
        let remainingSection = ctx.sectionEndBeat - ctx.beat
        if look.fills == true, phraseBeats > 0, beatInPhrase >= phraseBeats - 2, remainingSection > 2 {
            inFill = true
            chase = look.intensity > 0.85 ? (phraseIndex % 2 == 0 ? .strobeRoll : .chase) : (phraseIndex % 2 == 0 ? .chase : .bounce)
            step = 0.25
            moverSpeed *= 1.6
        }

        // Build-up into a bigger next section: speed doubles each bar, level climbs, then a breath of dark.
        var build: Double? = nil
        var breath = false
        if look.buildUp == true {
            let length = ctx.sectionEndBeat - ctx.sectionStartBeat
            // Short "Build" sections ramp the whole way; longer ones build over their last bars
            let window = length <= 8 * bpb + 0.5 ? length : min(4 * bpb, max(bpb, length / 3))
            if remainingSection <= window && remainingSection > 0 {
                let p = 1 - remainingSection / window
                build = p
                inFill = false
                chase = p < 0.5 ? .chase : (p < 0.85 ? .bounce : .strobeRoll)
                step = max(0.125, 1 / pow(2, floor(p * 3)))
                level = 0.55 + 0.45 * p
                moverSpeed = 1 + 2 * p
                breath = remainingSection <= 0.5
            }
        }

        return ResolvedPattern(chase: chase, mover: mover, stepBeats: step, phraseIndex: phraseIndex,
                               reversed: phraseIndex % 2 == 1, colorShift: (phraseIndex + seed) % 3,
                               levelScale: level, buildProgress: build, breath: breath, inFill: inFill,
                               moverSpeed: moverSpeed)
    }

    /// Colour and level for fixture `i` of `n` (sorted left → right).
    static func evaluate(_ look: SectionLook, _ r: ResolvedPattern, _ ctx: PatternContext,
                         index rawI: Int, count rawN: Int, isMover: Bool) -> (RGB, Double) {
        let n = max(1, rawN)
        let i = r.reversed ? n - 1 - rawI : rawI
        let beat = ctx.beat
        let bps = r.stepBeats
        let step = Int(floor(beat / bps))
        let frac = (beat / bps) - floor(beat / bps)

        // Three-colour palette rotated per phrase.
        let base = [look.colorA, look.colorB, look.colorC ?? look.colorA.mix(.white, 0.35)]
        let A = base[r.colorShift % 3], B = base[(r.colorShift + 1) % 3], C = base[(r.colorShift + 2) % 3]
        let pos = n > 1 ? Double(i) / Double(n - 1) : 0.5

        var color = isMover ? B : A
        var level = look.intensity

        switch r.chase {
        case .still:
            break
        case .alternate:
            color = (i + step) % 2 == 0 ? A : B
        case .wave:
            let m = 0.5 + 0.5 * sin(2 * .pi * beat / (bps * 4) - 2 * .pi * Double(i) / Double(n))
            color = A.mix(B, m)
            level *= 0.55 + 0.45 * m
        case .pulse:
            level *= 0.3 + 0.7 * pow(1 - frac, 2)
            color = isMover ? B : (step % 4 == 3 ? B : A)
        case .breathe:
            let m = 0.5 + 0.5 * sin(2 * .pi * beat / (bps * 2))
            level *= 0.6 + 0.4 * m
            color = A.mix(B, 0.5 + 0.5 * sin(2 * .pi * beat / 32))
        case .sparkle:
            if hash(i, step) < 0.3 { color = .white; level = 1 } else { level *= 0.35 }
        case .chase:
            let width = max(1, n / 4)
            let head = step % n
            let d = (i - head + n) % n
            if d < width { color = A } else { color = B; level *= 0.12 }
        case .bounce:
            let period = max(1, 2 * (n - 1))
            let k = step % period
            let head = k < n ? k : period - k
            let d = abs(i - head)
            if d == 0 { color = A } else if d == 1 { color = A.mix(B, 0.5); level *= 0.45 } else { color = B; level *= 0.1 }
        case .centerOut, .outsideIn:
            let dist = abs(pos - 0.5) * 2              // 0 centre … 1 edge
            let dir = r.chase == .centerOut ? 1.0 : -1.0
            let m = 0.5 + 0.5 * cos(2 * .pi * (dist - dir * beat / (bps * 2)))
            color = A.mix(B, 1 - m)
            level *= 0.15 + 0.85 * pow(m, 1.5)
        case .stack:
            let cycle = bps * Double(n + 1)
            let t = (beat - ctx.sectionStartBeat).truncatingRemainder(dividingBy: cycle) / cycle
            let lit = Int(t * Double(n + 1))
            if i < lit { color = i == lit - 1 ? C : A } else { color = B; level *= 0.08 }
        case .rainbow:
            var u = (pos * 0.8 + beat / (bps * 8)).truncatingRemainder(dividingBy: 1)
            if u < 0 { u += 1 }
            color = u < 1.0 / 3 ? A.mix(B, u * 3) : (u < 2.0 / 3 ? B.mix(C, (u - 1.0 / 3) * 3) : C.mix(A, (u - 2.0 / 3) * 3))
        case .comet:
            var ph = (beat / bps - pos * 1.0).truncatingRemainder(dividingBy: 1)
            if ph < 0 { ph += 1 }
            let tail = pow(1 - ph, 3)
            color = B.mix(A, tail)
            level *= 0.06 + 0.94 * tail
        case .triplet:
            let k = (i + step) % 3
            color = k == 0 ? A : (k == 1 ? B : C)
        case .strobeRoll:
            let sub = Int(floor(beat * 4 / max(0.25, bps)))
            let sf = (beat * 4 / max(0.25, bps)).truncatingRemainder(dividingBy: 1)
            if hash(i, sub) < 0.4 && sf < 0.5 { color = .white; level = 1 } else { color = A; level *= 0.1 }
        case .twinkle:
            let slow = beat / (bps * 2)
            let k = Int(floor(slow)), f = slow - floor(slow)
            let a = hash(i, k), b = hash(i, k + 1)
            let s = a + (b - a) * (f * f * (3 - 2 * f))
            level *= 0.2 + 0.8 * s
            color = hash(i + 7, k) < 0.5 ? A : B.mix(C, 0.3)
        }

        // Groove accents.
        if !r.inFill && r.buildProgress == nil {
            let bpb = ctx.beatsPerBar
            let inBar = (beat - ctx.sectionStartBeat).truncatingRemainder(dividingBy: bpb)
            let beatInBar = Int(floor(max(0, inBar)))
            let f = inBar - floor(inBar)
            var hit = 0.0
            switch look.accent ?? .none {
            case .none: break
            case .downbeat: if beatInBar == 0 { hit = pow(1 - f, 3) }
            case .backbeat: if beatInBar % 2 == 1 { hit = pow(1 - f, 3) }
            case .oneDrop: if beatInBar == 2 { hit = pow(1 - f, 3) }
            case .offbeat: if f >= 0.5 { hit = pow(1 - (f - 0.5) * 2, 3) }
            case .everyBeat: hit = pow(1 - f, 4)
            case .drums:
                // Real drums: kick bumps everything, snare flashes the washes toward white, hats add sparkle
                hit = max(ctx.kick, 0.6 * ctx.snare)
                if !isMover && ctx.snare > 0.5 { color = color.mix(.white, 0.35 * ctx.snare) }
                if r.chase == .sparkle || r.chase == .twinkle { level *= 0.7 + 0.5 * ctx.hats }
            }
            if look.accent != nil && look.accent != AccentKind.none {
                level = level * 0.8 + 0.3 * hit
                if hit > 0.7 && isMover == false { color = color.mix(.white, 0.25 * hit) }
            }
        }

        // Build-up: brighten towards white, then a breath of darkness right before the hit.
        if let p = r.buildProgress {
            color = color.mix(C.mix(.white, 0.5), p * 0.6)
        }
        level *= r.levelScale
        if r.breath { level = 0 }

        // Drop hit: strobe burst at the start of the section.
        if look.strobeBeats > 0 && beat >= ctx.sectionStartBeat && beat - ctx.sectionStartBeat < look.strobeBeats {
            let on = (beat * 4).truncatingRemainder(dividingBy: 1) < 0.5
            color = .white
            level = on ? 1 : 0
        }
        return (color, max(0, min(1, level)))
    }

    /// Floor (or crowd) target in metres for mover `j` of `n`, or nil for "aim at the lead performer".
    static func moverTarget(_ mode: MoverMode, _ r: ResolvedPattern, _ ctx: PatternContext,
                            index j: Int, count n: Int, stageWidth w: Double, stageDepth d: Double) -> SIMD3<Double>? {
        let n = max(1, n)
        let dir = r.reversed ? -1.0 : 1.0
        let speed = r.moverSpeed
        let beat = ctx.beat * speed
        let phase = Double(j) * 2 * .pi / Double(n)
        let spread = (Double(j) - Double(n - 1) / 2)
        let cx = w / 2, cy = d * 0.4
        switch mode {
        case .followLead:
            return nil
        case .still:
            return SIMD3(cx + spread * 1.2, d * 0.35, 0)
        case .sweep:
            return SIMD3(cx + dir * w * 0.38 * sin(2 * .pi * beat / 16 + phase / 2),
                         cy + d * 0.25 * sin(2 * .pi * beat / 8 + phase / 2), 0)
        case .fan:
            return SIMD3(cx + spread * 2.6, -4 - 1.5 * sin(2 * .pi * beat / 2), 1.5)
        case .ballyhoo:
            return SIMD3(cx + w * 0.55 * sin(2 * .pi * beat / 4 + phase),
                         d * 0.3 + d * 0.8 * cos(2 * .pi * beat / 2 + phase), 0)
        case .circle:
            let a = dir * 2 * .pi * beat / 8 + phase
            return SIMD3(cx + spread * 1.5 + 1.6 * cos(a), cy + 1.6 * sin(a), 0)
        case .figure8:
            let a = dir * 2 * .pi * beat / 16 + phase / 2
            return SIMD3(cx + w * 0.32 * sin(a), cy + d * 0.28 * sin(2 * a), 0)
        case .crossfire:
            let leftSide = Double(j) < Double(n) / 2
            let swing = sin(2 * .pi * beat / 8)
            let x = leftSide ? cx + w * 0.25 + w * 0.15 * swing : cx - w * 0.25 - w * 0.15 * swing
            return SIMD3(x, cy + d * 0.15 * cos(2 * .pi * beat / 4), 0)
        case .tiltWave:
            let y = d * 0.2 - 5 * (0.5 + 0.5 * sin(2 * .pi * beat / 8 - dir * Double(j) * .pi / Double(n)))
            return SIMD3(cx + spread * 2, y, 0.8)
        case .audienceHit:
            let k = Int(floor(ctx.beat / 2))
            let x = cx + (hash(j, k) - 0.5) * w * 1.2
            return SIMD3(x, -3 - 6 * hash(j + 11, k), 1.6)
        case .jumps:
            let k = Int(floor(ctx.beat / max(0.5, r.stepBeats)))
            return SIMD3(w * (0.1 + 0.8 * hash(j, k)), d * (0.1 + 0.8 * hash(j + 5, k)), 0)
        }
    }

    static func hash(_ i: Int, _ step: Int) -> Double {
        let x = sin(Double(i) * 12.9898 + Double(step) * 78.233) * 43758.5453
        return x - floor(x)
    }
}
