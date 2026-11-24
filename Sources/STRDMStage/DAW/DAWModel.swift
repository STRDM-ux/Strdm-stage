import Foundation
import SwiftUI
import AVFoundation

// MARK: - Project

/// A Studio (DAW) session: tracks, clips, buses and master, saved inside the show file.
struct DAWProject: Codable, Equatable {
    var name: String = "New Session"
    var bpm: Double = 98
    var beatsPerBar: Int = 4
    var tracks: [DAWTrack] = []
    var buses: [DAWBus] = [DAWBus(name: "Reverb Bus", effects: [EffectSlot.stock(.reverb)]),
                           DAWBus(name: "Delay Bus", effects: [EffectSlot.stock(.delay)])]
    var master = MasterSettings()
    var loopEnabled = false
    var loopStart: Double = 0          // beats
    var loopEnd: Double = 16           // beats
    var metronome = false
    var countIn = true
    var snap: Double = 0.25            // beats (1/16 note)
    var keyRoot: Int = 9               // A
    var keyIsMinor = true

    var barLength: Double { Double(beatsPerBar) }

    /// Last beat that contains anything (for export length).
    var contentEnd: Double {
        let ends = tracks.flatMap { t in t.audioClips.map { $0.start + $0.length } + t.midiClips.map { $0.start + $0.length } }
        return ends.max() ?? 0
    }

    static func starter() -> DAWProject {
        var p = DAWProject()
        p.name = "Riddim Sketch"
        var drums = DAWTrack(name: "Drums", kind: .midi, color: .orange)
        drums.instrument = .drumMachine(kit: "Dancehall")
        var clip = MIDIClip(start: 0, length: 16, name: "One Drop")
        // One-drop-ish dancehall pattern over 4 bars
        for bar in 0..<4 {
            let b = Double(bar * 4)
            clip.notes.append(MIDINote(pitch: 36, start: b + 2, length: 0.25, velocity: 120))        // kick on 3
            clip.notes.append(MIDINote(pitch: 38, start: b + 2, length: 0.25, velocity: 110))        // rim/snare on 3
            for s in stride(from: 0.0, to: 4.0, by: 0.5) {
                clip.notes.append(MIDINote(pitch: 42, start: b + s, length: 0.125, velocity: s.truncatingRemainder(dividingBy: 1) == 0 ? 90 : 60))
            }
            clip.notes.append(MIDINote(pitch: 39, start: b + 3.5, length: 0.25, velocity: 80))       // clap pickup
        }
        drums.midiClips = [clip]
        drums.sends = [DAWSend(busIndex: 0, levelDB: -18)]

        var bass = DAWTrack(name: "Bass", kind: .midi, color: .purple)
        bass.instrument = .synth(preset: "Sub Bass")
        var bassClip = MIDIClip(start: 0, length: 16, name: "Bassline")
        let roots = [45, 45, 41, 43]   // A A F G
        for (bar, root) in roots.enumerated() {
            let b = Double(bar * 4)
            bassClip.notes.append(MIDINote(pitch: root - 12, start: b, length: 1.5, velocity: 110))
            bassClip.notes.append(MIDINote(pitch: root - 12, start: b + 2, length: 0.75, velocity: 100))
            bassClip.notes.append(MIDINote(pitch: root, start: b + 3, length: 0.5, velocity: 90))
        }
        bass.midiClips = [bassClip]

        var keys = DAWTrack(name: "Keys", kind: .midi, color: .pink)
        keys.instrument = .synth(preset: "Warm Pad")
        keys.volumeDB = -8
        var keysClip = MIDIClip(start: 0, length: 16, name: "Chords")
        let chords: [[Int]] = [[57, 60, 64], [57, 60, 64], [53, 57, 60], [55, 59, 62]]
        for (bar, chord) in chords.enumerated() {
            for n in chord {
                keysClip.notes.append(MIDINote(pitch: n, start: Double(bar * 4) + 0.5, length: 0.4, velocity: 80))
                keysClip.notes.append(MIDINote(pitch: n, start: Double(bar * 4) + 1.5, length: 0.4, velocity: 70))
                keysClip.notes.append(MIDINote(pitch: n, start: Double(bar * 4) + 2.5, length: 0.4, velocity: 80))
                keysClip.notes.append(MIDINote(pitch: n, start: Double(bar * 4) + 3.5, length: 0.4, velocity: 70))
            }
        }
        keys.midiClips = [keysClip]
        keys.sends = [DAWSend(busIndex: 0, levelDB: -10), DAWSend(busIndex: 1, levelDB: -16)]

        var vox = DAWTrack(name: "Vocal", kind: .audio, color: .green)
        vox.sends = [DAWSend(busIndex: 0, levelDB: -14)]
        p.tracks = [drums, bass, keys, vox]
        p.loopEnabled = true
        p.loopEnd = 16
        return p
    }
}

enum TrackColor: String, Codable, CaseIterable {
    case pink, purple, blue, teal, green, yellow, orange, red, gray
    var color: Color {
        switch self {
        case .pink: return Color(red: 1, green: 0.2, blue: 0.6)
        case .purple: return Color(red: 0.55, green: 0.3, blue: 1)
        case .blue: return Color(red: 0.2, green: 0.5, blue: 1)
        case .teal: return Color(red: 0.1, green: 0.75, blue: 0.75)
        case .green: return Color(red: 0.2, green: 0.8, blue: 0.4)
        case .yellow: return Color(red: 0.95, green: 0.8, blue: 0.2)
        case .orange: return Color(red: 1, green: 0.55, blue: 0.15)
        case .red: return Color(red: 0.95, green: 0.25, blue: 0.25)
        case .gray: return Color(white: 0.55)
        }
    }
}

// MARK: - Tracks

enum TrackKind: String, Codable { case audio, midi }

enum InstrumentSpec: Codable, Equatable {
    case synth(preset: String)
    case drumMachine(kit: String)
    case generalMIDI(program: Int)
    case sampler(path: String)
    case audioUnit(PluginSlot)

    var label: String {
        switch self {
        case .synth(let p): return "STRDM Synth — \(p)"
        case .drumMachine(let k): return "Drum Machine — \(k)"
        case .generalMIDI(let p): return "GM: \(GeneralMIDI.names[safe: p] ?? "Program \(p)")"
        case .sampler(let path): return "Sampler — \(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)"
        case .audioUnit(let slot): return "\(slot.name) (\(slot.manufacturer))"
        }
    }

    var isDrums: Bool { if case .drumMachine = self { return true }; return false }
}

struct DAWSend: Codable, Equatable, Hashable {
    var busIndex: Int
    var levelDB: Double = -12
}

struct DAWTrack: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var kind: TrackKind
    var color: TrackColor = .pink
    var volumeDB: Double = 0
    var pan: Double = 0                    // -1 … 1
    var mute = false
    var solo = false
    var armed = false
    var instrument: InstrumentSpec? = nil
    var effects: [EffectSlot] = []
    var sends: [DAWSend] = []
    var audioClips: [AudioClip] = []
    var midiClips: [MIDIClip] = []
    var automation: [AutomationLane] = []
    var padSamples: [Int: String] = [:]    // drum machine: MIDI note → custom sample path
    var inputChannel: Int = 0              // recording input (0 = input 1)
    var monitor = false
}

struct AudioClip: Codable, Equatable, Identifiable {
    var id = UUID()
    var path: String
    var start: Double                      // beats
    var length: Double                     // beats
    var fileOffset: Double = 0             // seconds into the file
    var gainDB: Double = 0
    var fadeIn: Double = 0                 // beats
    var fadeOut: Double = 0
    var name: String { URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }
}

struct MIDINote: Codable, Equatable, Hashable, Identifiable {
    var id = UUID()
    var pitch: Int
    var start: Double                      // beats, relative to clip start
    var length: Double
    var velocity: Int = 100
}

struct MIDIClip: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var length: Double
    var name: String = "Clip"
    var notes: [MIDINote] = []
}

enum AutomationTarget: String, Codable, CaseIterable, Identifiable {
    case volume, pan
    var id: String { rawValue }
    var label: String { self == .volume ? "Volume" : "Pan" }
}

struct AutomationPoint: Codable, Equatable, Hashable, Identifiable {
    var id = UUID()
    var beat: Double
    var value: Double                      // 0…1 normalised
}

struct AutomationLane: Codable, Equatable, Identifiable {
    var id = UUID()
    var target: AutomationTarget
    var enabled = true
    var points: [AutomationPoint] = []

    /// Linear interpolation; nil when there are no points.
    func value(at beat: Double) -> Double? {
        let pts = points.sorted { $0.beat < $1.beat }
        guard let first = pts.first, let last = pts.last else { return nil }
        if beat <= first.beat { return first.value }
        if beat >= last.beat { return last.value }
        for i in 1..<pts.count where pts[i].beat >= beat {
            let a = pts[i - 1], b = pts[i]
            let t = (beat - a.beat) / max(0.0001, b.beat - a.beat)
            return a.value + (b.value - a.value) * t
        }
        return last.value
    }
}

// MARK: - Effects, buses, master

enum StockEffect: String, Codable, CaseIterable, Identifiable {
    case eq, compressor, limiter, reverb, delay, distortion, highPass, lowPass, multiband
    var id: String { rawValue }
    var label: String {
        switch self {
        case .eq: return "EQ (Parametric)"
        case .compressor: return "Compressor"
        case .limiter: return "Limiter"
        case .reverb: return "Reverb"
        case .delay: return "Delay"
        case .distortion: return "Distortion"
        case .highPass: return "High-Pass Filter"
        case .lowPass: return "Low-Pass Filter"
        case .multiband: return "Multiband Compressor"
        }
    }
    /// Apple's built-in Audio Units — always present on every Mac.
    var subType: UInt32 {
        switch self {
        case .eq: return kAudioUnitSubType_NBandEQ
        case .compressor: return kAudioUnitSubType_DynamicsProcessor
        case .limiter: return kAudioUnitSubType_PeakLimiter
        case .reverb: return kAudioUnitSubType_Reverb2
        case .delay: return kAudioUnitSubType_Delay
        case .distortion: return kAudioUnitSubType_Distortion
        case .highPass: return kAudioUnitSubType_HighPassFilter
        case .lowPass: return kAudioUnitSubType_LowPassFilter
        case .multiband: return kAudioUnitSubType_MultiBandCompressor
        }
    }
}

typealias EffectSlot = PluginSlot

extension PluginSlot {
    static func stock(_ e: StockEffect) -> PluginSlot {
        PluginSlot(name: e.label, manufacturer: "Apple", componentType: kAudioUnitType_Effect,
                   componentSubType: e.subType, componentManufacturer: kAudioUnitManufacturer_Apple)
    }
}

struct DAWBus: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var volumeDB: Double = 0
    var mute = false
    var effects: [EffectSlot] = []
}

struct MasterSettings: Codable, Equatable {
    var volumeDB: Double = 0
    var effects: [EffectSlot] = [EffectSlot.stock(.eq), EffectSlot.stock(.multiband), EffectSlot.stock(.limiter)]
    var targetLUFS: Double = -10
}

// MARK: - Synth presets & GM

struct SynthPreset: Codable, Equatable, Hashable, Identifiable {
    var id: String { name }
    var name: String
    var wave1: Int        // 0 sine, 1 saw, 2 square, 3 triangle
    var wave2: Int
    var detune: Double    // cents
    var osc2Level: Double
    var subLevel: Double
    var cutoff: Double    // Hz
    var resonance: Double // 0…0.95
    var filterEnv: Double // octaves of envelope sweep
    var attack: Double
    var decay: Double
    var sustain: Double
    var release: Double
    var glide: Double = 0
    var gain: Double = 0.5

    static let library: [SynthPreset] = [
        SynthPreset(name: "Sub Bass", wave1: 0, wave2: 3, detune: 0, osc2Level: 0.3, subLevel: 0.6, cutoff: 600, resonance: 0.1, filterEnv: 0.5, attack: 0.005, decay: 0.3, sustain: 0.9, release: 0.12, gain: 0.7),
        SynthPreset(name: "808 Boom", wave1: 0, wave2: 0, detune: 0, osc2Level: 0, subLevel: 0.4, cutoff: 900, resonance: 0, filterEnv: 0, attack: 0.002, decay: 1.6, sustain: 0.0, release: 0.4, glide: 0.05, gain: 0.85),
        SynthPreset(name: "Reese", wave1: 1, wave2: 1, detune: 18, osc2Level: 1, subLevel: 0.4, cutoff: 900, resonance: 0.25, filterEnv: 0.8, attack: 0.01, decay: 0.4, sustain: 0.8, release: 0.2, gain: 0.45),
        SynthPreset(name: "Warm Pad", wave1: 1, wave2: 2, detune: 9, osc2Level: 0.6, subLevel: 0.1, cutoff: 1800, resonance: 0.15, filterEnv: 0.6, attack: 0.25, decay: 0.8, sustain: 0.75, release: 0.9, gain: 0.32),
        SynthPreset(name: "Pluck", wave1: 1, wave2: 2, detune: 5, osc2Level: 0.4, subLevel: 0, cutoff: 700, resonance: 0.35, filterEnv: 3.5, attack: 0.002, decay: 0.25, sustain: 0.0, release: 0.2, gain: 0.45),
        SynthPreset(name: "Lead", wave1: 2, wave2: 1, detune: 7, osc2Level: 0.7, subLevel: 0.2, cutoff: 2500, resonance: 0.3, filterEnv: 1.5, attack: 0.01, decay: 0.3, sustain: 0.7, release: 0.25, glide: 0.04, gain: 0.38),
        SynthPreset(name: "Organ Skank", wave1: 2, wave2: 0, detune: 0, osc2Level: 0.5, subLevel: 0.3, cutoff: 3000, resonance: 0.05, filterEnv: 0.3, attack: 0.003, decay: 0.12, sustain: 0.0, release: 0.08, gain: 0.4),
        SynthPreset(name: "Brass Stab", wave1: 1, wave2: 1, detune: 12, osc2Level: 0.8, subLevel: 0, cutoff: 1200, resonance: 0.2, filterEnv: 2.2, attack: 0.02, decay: 0.35, sustain: 0.5, release: 0.15, gain: 0.4),
        SynthPreset(name: "Bell", wave1: 0, wave2: 3, detune: 1200, osc2Level: 0.35, subLevel: 0, cutoff: 6000, resonance: 0, filterEnv: 0, attack: 0.001, decay: 1.2, sustain: 0, release: 1.0, gain: 0.4)
    ]

    static func named(_ n: String) -> SynthPreset { library.first { $0.name == n } ?? library[0] }
}

enum DrumKits {
    static let names = ["Dancehall", "Trap 808", "Afro", "Acoustic-ish"]
    /// Pad layout (MIDI note → name). Notes follow the General MIDI drum map.
    static let pads: [(note: Int, name: String)] = [
        (36, "Kick"), (38, "Snare"), (37, "Rim"), (39, "Clap"),
        (42, "Hat"), (46, "Open Hat"), (49, "Crash"), (51, "Ride"),
        (41, "Low Tom"), (45, "Mid Tom"), (48, "Hi Tom"), (56, "Cowbell"),
        (54, "Shaker"), (60, "Bongo Hi"), (61, "Bongo Lo"), (35, "808")
    ]
}

enum GeneralMIDI {
    static let names: [String] = [
        "Acoustic Grand Piano", "Bright Piano", "Electric Grand", "Honky-tonk", "Electric Piano 1", "Electric Piano 2", "Harpsichord", "Clavinet",
        "Celesta", "Glockenspiel", "Music Box", "Vibraphone", "Marimba", "Xylophone", "Tubular Bells", "Dulcimer",
        "Drawbar Organ", "Percussive Organ", "Rock Organ", "Church Organ", "Reed Organ", "Accordion", "Harmonica", "Tango Accordion",
        "Nylon Guitar", "Steel Guitar", "Jazz Guitar", "Clean Guitar", "Muted Guitar", "Overdrive Guitar", "Distortion Guitar", "Guitar Harmonics",
        "Acoustic Bass", "Finger Bass", "Pick Bass", "Fretless Bass", "Slap Bass 1", "Slap Bass 2", "Synth Bass 1", "Synth Bass 2",
        "Violin", "Viola", "Cello", "Contrabass", "Tremolo Strings", "Pizzicato Strings", "Harp", "Timpani",
        "String Ensemble 1", "String Ensemble 2", "Synth Strings 1", "Synth Strings 2", "Choir Aahs", "Voice Oohs", "Synth Voice", "Orchestra Hit",
        "Trumpet", "Trombone", "Tuba", "Muted Trumpet", "French Horn", "Brass Section", "Synth Brass 1", "Synth Brass 2",
        "Soprano Sax", "Alto Sax", "Tenor Sax", "Baritone Sax", "Oboe", "English Horn", "Bassoon", "Clarinet",
        "Piccolo", "Flute", "Recorder", "Pan Flute", "Blown Bottle", "Shakuhachi", "Whistle", "Ocarina",
        "Square Lead", "Saw Lead", "Calliope", "Chiff", "Charang", "Voice Lead", "Fifths", "Bass + Lead",
        "New Age Pad", "Warm Pad", "Polysynth", "Choir Pad", "Bowed Pad", "Metallic Pad", "Halo Pad", "Sweep Pad",
        "Rain", "Soundtrack", "Crystal", "Atmosphere", "Brightness", "Goblins", "Echoes", "Sci-fi",
        "Sitar", "Banjo", "Shamisen", "Koto", "Kalimba", "Bagpipe", "Fiddle", "Shanai",
        "Tinkle Bell", "Agogo", "Steel Drums", "Woodblock", "Taiko", "Melodic Tom", "Synth Drum", "Reverse Cymbal",
        "Fret Noise", "Breath", "Seashore", "Bird", "Telephone", "Helicopter", "Applause", "Gunshot"
    ]
}

/// Musical helpers.
enum Music {
    static let noteNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    static func name(_ pitch: Int) -> String { "\(noteNames[((pitch % 12) + 12) % 12])\(pitch / 12 - 1)" }
    static func inScale(_ pitch: Int, root: Int, minor: Bool) -> Bool {
        let steps = minor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]
        return steps.contains(((pitch - root) % 12 + 12) % 12)
    }
    static func barsBeats(_ beat: Double, beatsPerBar: Int) -> String {
        let b = max(0, beat)
        let bar = Int(b / Double(beatsPerBar)) + 1
        let beatInBar = Int(b.truncatingRemainder(dividingBy: Double(beatsPerBar))) + 1
        let sixteenth = Int((b - floor(b)) * 4) + 1
        return "\(bar).\(beatInBar).\(sixteenth)"
    }
}
