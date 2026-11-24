import Foundation
import SwiftUI
import AppKit

// MARK: - Colour

struct RGB: Codable, Hashable, Sendable {
    var r: Double
    var g: Double
    var b: Double

    static let white = RGB(r: 1, g: 1, b: 1)
    static let black = RGB(r: 0, g: 0, b: 0)

    var color: Color { Color(red: r, green: g, blue: b) }

    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        r = Double(ns.redComponent); g = Double(ns.greenComponent); b = Double(ns.blueComponent)
    }

    init(hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }

    func mix(_ other: RGB, _ t: Double) -> RGB {
        let k = max(0, min(1, t))
        return RGB(r: r + (other.r - r) * k, g: g + (other.g - g) * k, b: b + (other.b - b) * k)
    }
}

struct Palette: Codable, Hashable, Identifiable, Sendable {
    var id: String { name }
    var name: String
    var a: RGB        // main wash colour
    var b: RGB        // second colour (alternates / movers)
    var accent: RGB   // hits, drops, sparkle

    static let library: [Palette] = [
        Palette(name: "Pink & Purple", a: RGB(hex: 0xFF1493), b: RGB(hex: 0x7A00FF), accent: RGB(hex: 0xFFFFFF)),
        Palette(name: "Fire", a: RGB(hex: 0xFF2000), b: RGB(hex: 0xFF8C00), accent: RGB(hex: 0xFFFFFF)),
        Palette(name: "Yaad (Green & Gold)", a: RGB(hex: 0x00B140), b: RGB(hex: 0xFFC600), accent: RGB(hex: 0xFF2A00)),
        Palette(name: "Dark Club", a: RGB(hex: 0x1A00FF), b: RGB(hex: 0xC8001E), accent: RGB(hex: 0xFFFFFF)),
        Palette(name: "Ice", a: RGB(hex: 0x00C8FF), b: RGB(hex: 0xFFFFFF), accent: RGB(hex: 0x3A5BFF)),
        Palette(name: "Sunset", a: RGB(hex: 0xFF6A00), b: RGB(hex: 0xFF2E7E), accent: RGB(hex: 0xFFD27A)),
        Palette(name: "Ocean", a: RGB(hex: 0x0047FF), b: RGB(hex: 0x00E5C8), accent: RGB(hex: 0xFFFFFF)),
        Palette(name: "Neon", a: RGB(hex: 0x00FF6A), b: RGB(hex: 0xFF00E1), accent: RGB(hex: 0xFFFF00)),
        Palette(name: "Warm Romance", a: RGB(hex: 0xFF9A3C), b: RGB(hex: 0xFF5C8A), accent: RGB(hex: 0xFFE3C2)),
        Palette(name: "Chill Teal", a: RGB(hex: 0x006DFF), b: RGB(hex: 0x00B3A6), accent: RGB(hex: 0xB0E0FF))
    ]

    static func named(_ name: String) -> Palette { library.first { $0.name == name } ?? library[0] }
}

// MARK: - Vibe

enum Vibe: String, Codable, CaseIterable, Identifiable, Sendable {
    case hype, dancehall, dark, euphoric, romantic, chill
    var id: String { rawValue }

    var label: String {
        switch self {
        case .hype: return "Hype / Party"
        case .dancehall: return "Dancehall Bounce"
        case .dark: return "Dark & Aggressive"
        case .euphoric: return "Euphoric / Uplifting"
        case .romantic: return "Romantic / Slow"
        case .chill: return "Chill / Moody"
        }
    }

    var symbol: String {
        switch self {
        case .hype: return "flame.fill"
        case .dancehall: return "speaker.wave.3.fill"
        case .dark: return "bolt.fill"
        case .euphoric: return "sparkles"
        case .romantic: return "heart.fill"
        case .chill: return "moon.stars.fill"
        }
    }

    var defaultPalette: String {
        switch self {
        case .hype: return "Fire"
        case .dancehall: return "Yaad (Green & Gold)"
        case .dark: return "Dark Club"
        case .euphoric: return "Ice"
        case .romantic: return "Warm Romance"
        case .chill: return "Chill Teal"
        }
    }
}

enum ChaseKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case still, alternate, wave, pulse, breathe, sparkle
    case chase, bounce, centerOut, outsideIn, stack, rainbow, comet, triplet, strobeRoll, twinkle
    var id: String { rawValue }
    var label: String {
        switch self {
        case .still: return "Still"
        case .alternate: return "Alternate A/B"
        case .wave: return "Wave"
        case .pulse: return "Pulse on beat"
        case .breathe: return "Slow breathe"
        case .sparkle: return "Sparkle"
        case .chase: return "Chase (runner)"
        case .bounce: return "Bounce (ping-pong)"
        case .centerOut: return "Center out"
        case .outsideIn: return "Outside in"
        case .stack: return "Stack / build"
        case .rainbow: return "Colour roll"
        case .comet: return "Comet tails"
        case .triplet: return "Three-colour step"
        case .strobeRoll: return "Strobe roll"
        case .twinkle: return "Twinkle"
        }
    }
}

enum MoverMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case still, sweep, fan, ballyhoo, followLead
    case circle, figure8, crossfire, tiltWave, audienceHit, jumps
    var id: String { rawValue }
    var label: String {
        switch self {
        case .still: return "Still (on stage)"
        case .sweep: return "Slow sweep"
        case .fan: return "Fan to crowd"
        case .ballyhoo: return "Ballyhoo (big & fast)"
        case .followLead: return "Follow lead performer"
        case .circle: return "Circles"
        case .figure8: return "Figure 8"
        case .crossfire: return "Crossfire (X)"
        case .tiltWave: return "Tilt wave"
        case .audienceHit: return "Hit the crowd"
        case .jumps: return "Jump on the beat"
        }
    }
}

/// What the lasers do in a section.
enum LaserLook: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, beams, fan, tunnel, sheet, scan, chase
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .beams: return "Beams"
        case .fan: return "Fan over the crowd"
        case .tunnel: return "Tunnel / cone"
        case .sheet: return "Liquid sky (sheet)"
        case .scan: return "Scanning"
        case .chase: return "Chase"
        }
    }
    /// DMX value for the Pattern channel (8 slots of 32).
    var patternValue: Double {
        switch self {
        case .off: return 0
        case .beams: return 16
        case .fan: return 48
        case .tunnel: return 80
        case .sheet: return 112
        case .scan: return 144
        case .chase: return 176
        }
    }
    static func fromPattern(_ v: Double) -> LaserLook {
        let all: [LaserLook] = [.beams, .fan, .tunnel, .sheet, .scan, .chase]
        return all[max(0, min(all.count - 1, Int(v / 32)))]
    }
}

/// Which beats get an extra punch.
enum AccentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, downbeat, backbeat, oneDrop, offbeat, everyBeat, drums
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "None"
        case .downbeat: return "Bar downbeat"
        case .backbeat: return "Backbeat (2 & 4)"
        case .oneDrop: return "One drop (beat 3)"
        case .offbeat: return "Offbeat skank"
        case .everyBeat: return "Every beat"
        case .drums: return "Follow the real drums"
        }
    }
}

// MARK: - Show timeline

struct SectionLook: Codable, Hashable, Sendable {
    var colorA: RGB
    var colorB: RGB
    var intensity: Double          // 0…1
    var chase: ChaseKind
    var beatsPerStep: Double       // chase speed in beats
    var strobeBeats: Double        // strobe burst at section start (0 = none)
    var mover: MoverMode
    var haze: Double               // 0…1
    /// Screen visual for this section (nil = automatic from the section and vibe).
    var visual: VisualStyle? = nil
    /// Third colour (accent) for three-colour patterns.
    var colorC: RGB? = nil
    /// Patterns to rotate through, one per phrase (nil = always `chase`).
    var variations: [ChaseKind]? = nil
    /// Mover moves to rotate through, one per phrase.
    var moverVariations: [MoverMode]? = nil
    /// Phrase length in bars; the pattern changes every phrase (nil/0 = never).
    var phraseBars: Int? = nil
    var accent: AccentKind? = nil
    /// Quick fill on the last beats of each phrase.
    var fills: Bool? = nil
    /// Build tension into the next section (speed up, rise, blackout breath before it lands).
    var buildUp: Bool? = nil
    /// Offsets which variation a section starts on, so repeated choruses differ.
    var seed: Int? = nil
    /// Special effect hit when this section starts (needs arming + "allow auto-fire").
    var sfxHit: SFXKind? = nil
    /// Repeat the effect hit every N bars through the section (nil/0 = once).
    var sfxEveryBars: Int? = nil
    /// Laser look for this section (nil = off).
    var laser: LaserLook? = nil
}

struct ShowSection: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var label: String              // Intro, Verse, Chorus, Drop, Breakdown, Outro
    var start: Double              // seconds
    var end: Double
    var energy: Double             // 0…1 relative to the song's loudest part
    var look: SectionLook
    /// How much singing/rapping is in this section (0…1), from the analyser.
    var vocal: Double? = nil
    /// Sections with the same letter repeat musically (A = first idea, B = second…).
    var group: String? = nil
    var key: String? = nil
}

struct SongAnalysis: Codable, Hashable, Sendable {
    var duration: Double
    var bpm: Double
    var beatOffset: Double         // seconds to the first downbeat-ish beat
    var key: String                // e.g. "A minor"
    var isMajor: Bool
    var loudnessDB: Double         // mean RMS dBFS
    var brightness: Double         // 0…1 (spectral centroid)
    var bassWeight: Double         // 0…1 share of power below 150 Hz
    var onsetsPerSecond: Double
    var arousal: Double            // 0…1 energy / intensity
    var valence: Double            // 0…1 happy ↔ dark
    var energyCurve: [Double]      // ~2 values per second, 0…1
    var suggestedVibe: Vibe
    var reasoning: String

    // Deep analysis (nil on shows analysed before it existed)
    /// Every beat (seconds), tracked through tempo drift.
    var beats: [Double]? = nil
    /// Index into `beats` of the first downbeat (bar line).
    var firstDownbeat: Int? = nil
    var kicks: [Double]? = nil
    var snares: [Double]? = nil
    /// 4 values per second, 0…1.
    var hatCurve: [Double]? = nil
    var bassCurve: [Double]? = nil
    var midCurve: [Double]? = nil
    var highCurve: [Double]? = nil
    var vocalCurve: [Double]? = nil
    var danceability: Double? = nil
    var structure: String? = nil

    /// Musical position in beats (beat 0 = first downbeat), following the tracked beat grid.
    func beatPosition(_ t: Double) -> Double {
        guard let b = beats, b.count > 8 else { return (t - beatOffset) * bpm / 60 }
        let first = firstDownbeat ?? 0
        let period = 60 / max(30, bpm)
        if t <= b[0] { return Double(-first) - (b[0] - t) / period }
        if t >= b[b.count - 1] { return Double(b.count - 1 - first) + (t - b[b.count - 1]) / period }
        var lo = 0, hi = b.count - 1
        while hi - lo > 1 { let m = (lo + hi) / 2; if b[m] <= t { lo = m } else { hi = m } }
        return Double(lo - first) + (t - b[lo]) / max(0.05, b[hi] - b[lo])
    }

    /// 1 right on a hit, decaying to 0 (for kick/snare-driven light bumps).
    static func hitPulse(_ hits: [Double]?, at t: Double, decay: Double = 0.12) -> Double {
        guard let h = hits, !h.isEmpty, t >= h[0] else { return 0 }
        var lo = 0, hi = h.count - 1
        while hi > lo { let m = (lo + hi + 1) / 2; if h[m] <= t { lo = m } else { hi = m - 1 } }
        let dt = t - h[lo]
        return dt < 0 ? 0 : exp(-dt / decay)
    }

    static func curveValue(_ c: [Double]?, at t: Double, rate: Double = 4) -> Double {
        guard let c, !c.isEmpty else { return 0 }
        let x = t * rate
        let i = max(0, min(c.count - 1, Int(x)))
        let j = min(c.count - 1, i + 1)
        let f = x - Double(i)
        return c[i] + (c[j] - c[i]) * max(0, min(1, f))
    }
}

struct LightShow: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var songPath: String
    var analysis: SongAnalysis
    var vibe: Vibe
    var paletteName: String
    var sections: [ShowSection]
    var fadeOutAtEnd: Double = 4
    /// Original music video, when the song was analysed from a video file.
    var videoPath: String? = nil
}

// MARK: - Look generator

enum LookGenerator {
    struct Part {
        var chases: [ChaseKind]
        var speed: Double            // beats per step
        var movers: [MoverMode]
        var phraseBars: Int
    }
    struct Profile {
        var baseIntensity: Double
        var intro: Part, verse: Part, chorus: Part, drop: Part, breakdown: Part
        var accent: AccentKind
        var strobeOnDrops: Bool
        var fills: Bool
        var haze: Double
    }

    static func profile(_ vibe: Vibe) -> Profile {
        switch vibe {
        case .hype:
            return Profile(baseIntensity: 1.0,
                           intro: Part(chases: [.breathe, .centerOut], speed: 4, movers: [.tiltWave, .still], phraseBars: 8),
                           verse: Part(chases: [.alternate, .chase, .bounce, .triplet], speed: 1, movers: [.sweep, .crossfire, .circle], phraseBars: 8),
                           chorus: Part(chases: [.pulse, .centerOut, .rainbow, .comet], speed: 1, movers: [.fan, .figure8, .crossfire], phraseBars: 4),
                           drop: Part(chases: [.strobeRoll, .pulse, .chase, .sparkle], speed: 0.5, movers: [.ballyhoo, .jumps, .audienceHit], phraseBars: 4),
                           breakdown: Part(chases: [.breathe, .stack], speed: 2, movers: [.followLead, .tiltWave], phraseBars: 8),
                           accent: .downbeat, strobeOnDrops: true, fills: true, haze: 0.6)
        case .dancehall:
            return Profile(baseIntensity: 0.9,
                           intro: Part(chases: [.breathe, .twinkle], speed: 4, movers: [.still, .tiltWave], phraseBars: 8),
                           verse: Part(chases: [.pulse, .alternate, .triplet, .bounce], speed: 1, movers: [.still, .sweep, .tiltWave], phraseBars: 8),
                           chorus: Part(chases: [.alternate, .centerOut, .comet, .rainbow], speed: 1, movers: [.sweep, .circle, .crossfire], phraseBars: 4),
                           drop: Part(chases: [.pulse, .strobeRoll, .outsideIn, .chase], speed: 0.5, movers: [.fan, .jumps, .ballyhoo], phraseBars: 4),
                           breakdown: Part(chases: [.breathe, .twinkle], speed: 4, movers: [.followLead], phraseBars: 8),
                           accent: .backbeat, strobeOnDrops: true, fills: true, haze: 0.5)
        case .dark:
            return Profile(baseIntensity: 0.85,
                           intro: Part(chases: [.twinkle, .breathe], speed: 4, movers: [.tiltWave, .sweep], phraseBars: 8),
                           verse: Part(chases: [.wave, .comet, .outsideIn], speed: 2, movers: [.sweep, .crossfire], phraseBars: 8),
                           chorus: Part(chases: [.alternate, .chase, .centerOut, .comet], speed: 1, movers: [.ballyhoo, .crossfire, .figure8], phraseBars: 4),
                           drop: Part(chases: [.sparkle, .strobeRoll, .bounce], speed: 0.5, movers: [.ballyhoo, .jumps, .audienceHit], phraseBars: 4),
                           breakdown: Part(chases: [.breathe, .stack], speed: 4, movers: [.tiltWave], phraseBars: 8),
                           accent: .everyBeat, strobeOnDrops: true, fills: true, haze: 0.8)
        case .euphoric:
            return Profile(baseIntensity: 0.95,
                           intro: Part(chases: [.breathe, .rainbow], speed: 4, movers: [.tiltWave, .sweep], phraseBars: 8),
                           verse: Part(chases: [.wave, .rainbow, .comet], speed: 2, movers: [.sweep, .circle], phraseBars: 8),
                           chorus: Part(chases: [.centerOut, .rainbow, .alternate, .comet], speed: 1, movers: [.fan, .figure8, .circle], phraseBars: 4),
                           drop: Part(chases: [.alternate, .strobeRoll, .outsideIn, .pulse], speed: 0.5, movers: [.fan, .ballyhoo, .audienceHit], phraseBars: 4),
                           breakdown: Part(chases: [.stack, .breathe], speed: 2, movers: [.tiltWave, .followLead], phraseBars: 8),
                           accent: .downbeat, strobeOnDrops: true, fills: true, haze: 0.6)
        case .romantic:
            return Profile(baseIntensity: 0.7,
                           intro: Part(chases: [.breathe], speed: 8, movers: [.followLead], phraseBars: 8),
                           verse: Part(chases: [.breathe, .wave, .twinkle], speed: 8, movers: [.followLead, .sweep], phraseBars: 8),
                           chorus: Part(chases: [.wave, .rainbow, .centerOut], speed: 4, movers: [.followLead, .circle], phraseBars: 8),
                           drop: Part(chases: [.wave, .comet], speed: 2, movers: [.sweep, .fan], phraseBars: 8),
                           breakdown: Part(chases: [.breathe], speed: 8, movers: [.followLead], phraseBars: 8),
                           accent: .none, strobeOnDrops: false, fills: false, haze: 0.4)
        case .chill:
            return Profile(baseIntensity: 0.6,
                           intro: Part(chases: [.breathe, .twinkle], speed: 8, movers: [.still], phraseBars: 8),
                           verse: Part(chases: [.breathe, .wave, .twinkle], speed: 8, movers: [.still, .tiltWave], phraseBars: 8),
                           chorus: Part(chases: [.wave, .rainbow], speed: 4, movers: [.sweep, .circle], phraseBars: 8),
                           drop: Part(chases: [.wave, .comet, .centerOut], speed: 2, movers: [.sweep, .figure8], phraseBars: 8),
                           breakdown: Part(chases: [.breathe], speed: 8, movers: [.still], phraseBars: 8),
                           accent: .offbeat, strobeOnDrops: false, fills: false, haze: 0.5)
        }
    }

    /// Builds a look for every section from the vibe and palette — varied per phrase and per repeat.
    static func looks(for sections: [ShowSection], vibe: Vibe, palette: Palette, hasDrums: Bool = false) -> [ShowSection] {
        let p = profile(vibe)
        var seen: [String: Int] = [:]
        let lastChorus = sections.lastIndex { $0.label.lowercased().hasPrefix("chorus") || $0.label.lowercased().hasPrefix("drop") }
        return sections.enumerated().map { idx, s in
            var section = s
            let label = s.label.lowercased()
            let key = String(label.prefix(4))
            let repeatIndex = seen[key, default: 0]
            seen[key] = repeatIndex + 1
            let part: Part
            var colorA = palette.a, colorB = palette.b, colorC = palette.accent
            var intensity = p.baseIntensity
            var strobe = 0.0
            var haze = p.haze
            if label.hasPrefix("intro") {
                part = p.intro; intensity *= 0.45
            } else if label.hasPrefix("verse") {
                part = p.verse; intensity *= 0.72
                if repeatIndex % 2 == 1 { swap(&colorA, &colorB) }
            } else if label.hasPrefix("chorus") || label.hasPrefix("hook") {
                part = p.chorus; intensity *= 0.92
                colorA = palette.b; colorB = palette.a
            } else if label.hasPrefix("drop") {
                part = p.drop; intensity = 1
                colorA = palette.accent; colorB = palette.a; colorC = palette.b
                strobe = p.strobeOnDrops ? 4 : 0
                haze = min(1, haze + 0.2)
            } else if label.hasPrefix("build") || label.hasPrefix("pre") {
                // Tension: stack up and chase faster into whatever comes next
                part = Part(chases: [.stack, .chase, .bounce], speed: 1, movers: [.tiltWave, .circle], phraseBars: 4)
                intensity *= 0.8
            } else if label.hasPrefix("break") || label.hasPrefix("bridge") {
                part = p.breakdown; intensity *= 0.4
                colorA = palette.b; colorB = palette.a
            } else {
                part = p.intro; intensity *= 0.35; haze *= 0.5
            }
            // Big sections get louder as the song goes on; the last chorus/drop is the biggest.
            var chases = part.chases
            var movers = part.movers
            if idx == lastChorus && sections.count > 3 {
                intensity = min(1, intensity + 0.08)
                if !chases.contains(.strobeRoll) && p.strobeOnDrops { chases.append(.strobeRoll) }
                if !movers.contains(.ballyhoo) && vibe != .romantic && vibe != .chill { movers.append(.ballyhoo) }
                if p.strobeOnDrops { strobe = 4 }
            }
            // Energy inside the section nudges the speed.
            var speed = part.speed
            if s.energy > 0.85 && speed > 0.5 { speed /= 2 }
            if s.energy < 0.3 && speed < 8 { speed *= 2 }
            // Build into the next section when it's clearly bigger.
            var build = label.hasPrefix("build") || label.hasPrefix("pre")
            if !build && idx + 1 < sections.count {
                let next = sections[idx + 1]
                let nl = next.label.lowercased()
                build = (next.energy > s.energy + 0.12 || nl.hasPrefix("drop") || nl.hasPrefix("chorus"))
                    && vibe != .chill && s.end - s.start > 8
            }
            var look = SectionLook(colorA: colorA, colorB: colorB, intensity: intensity, chase: chases[0],
                                   beatsPerStep: speed, strobeBeats: strobe, mover: movers[0], haze: haze)
            look.colorC = colorC
            look.variations = chases.count > 1 ? chases : nil
            look.moverVariations = movers.count > 1 ? movers : nil
            look.phraseBars = part.phraseBars
            look.accent = label.hasPrefix("intro") || label.hasPrefix("outro") ? AccentKind.none
                : (hasDrums && vibe != .romantic && vibe != .chill ? .drums : p.accent)
            // Lots of singing in a quieter section: movers find the artist
            if (s.vocal ?? 0) > 0.55 && (label.hasPrefix("verse") || label.hasPrefix("bridge") || label.hasPrefix("break")) {
                var m = look.moverVariations ?? [look.mover]
                m.removeAll { $0 == .followLead }
                m.insert(.followLead, at: 0)
                look.moverVariations = m
                look.mover = .followLead
            }
            look.fills = p.fills && !label.hasPrefix("intro") && !label.hasPrefix("outro")
            look.buildUp = build
            look.seed = repeatIndex * 2 + idx
            look.laser = laserLook(label: label, vibe: vibe, repeatIndex: repeatIndex, isLast: idx == lastChorus)
            let fx = effectHit(label: label, vibe: vibe, isLast: idx == lastChorus)
            look.sfxHit = fx.kind
            look.sfxEveryBars = fx.everyBars
            section.look = look
            section.look.visual = VisualDefaults.style(for: s.label, vibe: vibe)
            return section
        }
    }

    /// Lasers per section and vibe: big moments get beams, slow ones a liquid sky, quiet parts stay dark.
    static func laserLook(label: String, vibe: Vibe, repeatIndex: Int, isLast: Bool) -> LaserLook {
        let alt = repeatIndex % 2 == 1
        if label.hasPrefix("build") || label.hasPrefix("pre") {
            return vibe == .romantic || vibe == .chill ? .off : .chase
        }
        if label.hasPrefix("bridge") { return vibe == .euphoric || vibe == .dark ? .sheet : .off }
        switch vibe {
        case .hype:
            if label.hasPrefix("drop") { return alt ? .chase : .scan }
            if label.hasPrefix("chorus") || label.hasPrefix("hook") { return alt ? .fan : .beams }
            if label.hasPrefix("verse") { return alt ? .off : .fan }
            if label.hasPrefix("intro") { return .sheet }
            return .off
        case .dancehall:
            if label.hasPrefix("drop") { return isLast ? .scan : .beams }
            if label.hasPrefix("chorus") || label.hasPrefix("hook") { return alt ? .tunnel : .fan }
            return .off
        case .dark:
            if label.hasPrefix("drop") { return .chase }
            if label.hasPrefix("chorus") || label.hasPrefix("hook") { return .tunnel }
            if label.hasPrefix("verse") || label.hasPrefix("intro") { return .sheet }
            return .off
        case .euphoric:
            if label.hasPrefix("drop") { return .beams }
            if label.hasPrefix("chorus") || label.hasPrefix("hook") { return .fan }
            if label.hasPrefix("verse") { return .tunnel }
            if label.hasPrefix("intro") || label.hasPrefix("break") { return .sheet }
            return .off
        case .romantic:
            return (label.hasPrefix("chorus") || label.hasPrefix("hook")) && isLast ? .sheet : .off
        case .chill:
            return label.hasPrefix("intro") || label.hasPrefix("chorus") ? .sheet : .off
        }
    }

    /// Special effects per section and vibe (they only fire when armed and the unit allows auto-fire).
    static func effectHit(label: String, vibe: Vibe, isLast: Bool) -> (kind: SFXKind?, everyBars: Int?) {
        let big = label.hasPrefix("drop") || label.hasPrefix("chorus") || label.hasPrefix("hook")
        guard big else { return (nil, nil) }
        switch vibe {
        case .hype:
            if isLast { return (.confetti, nil) }
            return label.hasPrefix("drop") ? (.flame, 8) : (.co2, nil)
        case .dancehall:
            if isLast { return (.confetti, nil) }
            return label.hasPrefix("drop") ? (.co2, 8) : (nil, nil)
        case .dark:
            return label.hasPrefix("drop") ? (.flame, 4) : (isLast ? SFXKind.flame : nil, nil)
        case .euphoric:
            if isLast { return (.confetti, nil) }
            return label.hasPrefix("drop") ? (.co2, 8) : (nil, nil)
        case .romantic, .chill:
            return isLast ? (.coldSpark, nil) : (nil, nil)
        }
    }

    /// Adds lasers and effect hits to shows made before they existed (keeps everything else).
    static func addLasersAndEffects(_ show: LightShow) -> LightShow {
        guard show.sections.allSatisfy({ $0.look.laser == nil && $0.look.sfxHit == nil }) else { return show }
        var out = show
        let fresh = looks(for: show.sections, vibe: show.vibe, palette: Palette.named(show.paletteName))
        for i in out.sections.indices where i < fresh.count {
            out.sections[i].look.laser = fresh[i].look.laser
            out.sections[i].look.sfxHit = fresh[i].look.sfxHit
            out.sections[i].look.sfxEveryBars = fresh[i].look.sfxEveryBars
        }
        return out
    }

    /// Adds phrasing, accents, fills and build-ups to shows made before the pattern engine,
    /// keeping their colours, levels and chosen chase/mover.
    static func upgrade(_ show: LightShow) -> LightShow {
        guard show.sections.allSatisfy({ $0.look.phraseBars == nil }) else { return show }
        var out = show
        let fresh = looks(for: show.sections, vibe: show.vibe, palette: Palette.named(show.paletteName))
        for i in out.sections.indices where i < fresh.count {
            let n = fresh[i].look
            var l = out.sections[i].look
            l.colorC = n.colorC
            var v = n.variations ?? [l.chase]
            v.removeAll { $0 == l.chase }; v.insert(l.chase, at: 0)
            l.variations = v
            var m = n.moverVariations ?? [l.mover]
            m.removeAll { $0 == l.mover }; m.insert(l.mover, at: 0)
            l.moverVariations = m
            l.phraseBars = n.phraseBars
            l.accent = n.accent
            l.fills = n.fills
            l.buildUp = n.buildUp
            l.seed = n.seed
            out.sections[i].look = l
        }
        return out
    }

    static func makeShow(name: String, path: String, analysis: SongAnalysis, sections: [ShowSection],
                         vibe: Vibe? = nil, paletteName: String? = nil) -> LightShow {
        let v = vibe ?? analysis.suggestedVibe
        let pal = paletteName ?? v.defaultPalette
        return LightShow(name: name, songPath: path, analysis: analysis, vibe: v, paletteName: pal,
                         sections: looks(for: sections, vibe: v, palette: Palette.named(pal),
                                         hasDrums: (analysis.kicks?.count ?? 0) > 30))
    }
}
