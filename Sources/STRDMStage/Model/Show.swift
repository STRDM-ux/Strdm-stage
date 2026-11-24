import Foundation
import SwiftUI

// MARK: - Show document

/// Everything about one show: cue list, lighting patch, screens, vocal rack, stage plot and advance info.
/// Saved as JSON with the `.strdmshow` extension.
struct Show: Codable, Equatable {
    var formatVersion: Int = 1
    var name: String = "Untitled Show"
    var cues: [Cue] = []

    var lighting = LightingSetup()
    var screens: [ScreenOutput] = [ScreenOutput(name: "LED Wall")]
    var vocalRack = VocalRack()
    var audioSettings = AudioSettings()

    var stagePlot = StagePlot()
    var inputList: [InputChannel] = InputChannel.starterList
    var venue = VenueInfo()

    var control = ControlSettings()

    /// Auto-generated song light shows from the Light Set Builder.
    var lightShows: [LightShow] = []

    /// The Studio (DAW) session.
    var daw: DAWProject = DAWProject.starter()

    /// Special effects (flame, CO₂, confetti, pyro, cold spark).
    var effects = SFXSetup()

    /// GO behaviour: fade out the previous track/video when a new one starts.
    var playback = PlaybackSettings()

    /// 3D title on the screens.
    var titleSettings: TitleSettings? = nil

    /// Who's on stage (Stage Set Builder / Full Auto).
    var lineup: Lineup? = nil
}

// Tolerant decoding: any field missing from an older show file falls back to its default,
// so show files keep opening as new features are added.
extension Show {
    enum CodingKeys: String, CodingKey {
        case formatVersion, name, cues, lighting, screens, vocalRack, audioSettings,
             stagePlot, inputList, venue, control, lightShows, daw, effects, playback, titleSettings, lineup
    }

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? formatVersion
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? name
        cues = try c.decodeIfPresent([Cue].self, forKey: .cues) ?? cues
        lighting = try c.decodeIfPresent(LightingSetup.self, forKey: .lighting) ?? lighting
        screens = try c.decodeIfPresent([ScreenOutput].self, forKey: .screens) ?? screens
        vocalRack = try c.decodeIfPresent(VocalRack.self, forKey: .vocalRack) ?? vocalRack
        audioSettings = try c.decodeIfPresent(AudioSettings.self, forKey: .audioSettings) ?? audioSettings
        stagePlot = try c.decodeIfPresent(StagePlot.self, forKey: .stagePlot) ?? stagePlot
        inputList = try c.decodeIfPresent([InputChannel].self, forKey: .inputList) ?? inputList
        venue = try c.decodeIfPresent(VenueInfo.self, forKey: .venue) ?? venue
        control = try c.decodeIfPresent(ControlSettings.self, forKey: .control) ?? control
        lightShows = try c.decodeIfPresent([LightShow].self, forKey: .lightShows) ?? lightShows
        daw = (try? c.decodeIfPresent(DAWProject.self, forKey: .daw)) ?? daw
        effects = (try? c.decodeIfPresent(SFXSetup.self, forKey: .effects)) ?? effects
        playback = (try? c.decodeIfPresent(PlaybackSettings.self, forKey: .playback)) ?? playback
        titleSettings = try? c.decodeIfPresent(TitleSettings.self, forKey: .titleSettings)
        lineup = try? c.decodeIfPresent(Lineup.self, forKey: .lineup)
    }
}

struct PlaybackSettings: Codable, Equatable {
    /// Starting an audio or video cue fades out whatever audio/video was already playing.
    var autoStopPrevious = true
    var stopFade: Double = 2
}

// MARK: - Cues

enum CueKind: String, Codable, CaseIterable, Identifiable {
    case layered, audio, lights, video, videoBlack, fade, vocalFX, effect, wait, memo
    var id: String { rawValue }

    var label: String {
        switch self {
        case .audio: return "Audio / Track"
        case .lights: return "Lighting Scene"
        case .video: return "Video / Image"
        case .videoBlack: return "Screens to Black"
        case .fade: return "Fade & Stop"
        case .vocalFX: return "Vocal FX"
        case .wait: return "Wait"
        case .layered: return "Layered (sound + lights + FX)"
        case .memo: return "Memo"
        case .effect: return "Special Effect"
        }
    }

    var symbol: String {
        switch self {
        case .audio: return "waveform"
        case .lights: return "lightbulb.max.fill"
        case .video: return "play.rectangle.fill"
        case .videoBlack: return "rectangle.fill"
        case .fade: return "speaker.wave.1.fill"
        case .vocalFX: return "music.mic"
        case .wait: return "hourglass"
        case .layered: return "square.stack.3d.up.fill"
        case .memo: return "note.text"
        case .effect: return "flame.fill"
        }
    }

    var tint: Color {
        switch self {
        case .audio: return .blue
        case .lights: return .yellow
        case .video, .videoBlack: return .purple
        case .fade: return .teal
        case .vocalFX: return .pink
        case .wait: return .gray
        case .layered: return .mint
        case .memo: return .secondary
        case .effect: return .orange
        }
    }
}

enum ContinueMode: String, Codable, CaseIterable, Identifiable {
    case none, autoContinue, autoFollow
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "Do not continue"
        case .autoContinue: return "Auto-continue (fire next with this)"
        case .autoFollow: return "Auto-follow (fire next when this ends)"
        }
    }
    var shortLabel: String {
        switch self {
        case .none: return ""
        case .autoContinue: return "↓ AC"
        case .autoFollow: return "↓ AF"
        }
    }
}

enum FadeTarget: String, Codable, CaseIterable, Identifiable {
    case allAudio, specificCue, allVideo, everything
    var id: String { rawValue }
    var label: String {
        switch self {
        case .allAudio: return "All audio"
        case .specificCue: return "Specific cue"
        case .allVideo: return "All video"
        case .everything: return "Everything (audio + video)"
        }
    }
}

struct Cue: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var number: String = ""
    var name: String = ""
    var kind: CueKind
    var preWait: Double = 0
    var continueMode: ContinueMode = .none
    var notes: String = ""

    // Audio
    var audioPath: String?
    var gainDB: Double = 0
    var fadeIn: Double = 0
    var loop: Bool = false
    var startOffset: Double = 0

    // Lighting
    var sceneID: UUID?
    var lightFade: Double = 2

    // Video
    var videoPath: String?
    var screenID: UUID?
    var videoFade: Double = 1
    var videoLoop: Bool = false
    var videoFill: Bool = true
    /// Play the video's own sound through the show audio outputs (nil = yes).
    var videoSound: Bool?

    // Fade / stop
    var fadeTarget: FadeTarget = .allAudio
    var fadeTargetCueID: UUID?
    var fadeDuration: Double = 3

    // Vocal FX
    var vocalBypass: Bool = false
    var vocalPresetID: UUID?

    // Wait
    var waitDuration: Double = 5

    /// Auto light show (Light Set Builder) that runs in sync while this audio cue plays.
    var lightShowID: UUID?

    /// Fade out tracks/videos already playing when this fires (nil = follow the show setting).
    var stopPrevious: Bool?

    // Screens: several outputs, regions, fit and layering
    var allScreens: Bool?
    var screenIDs: [UUID]?
    var region: ScreenRegion?
    var fitMode: FitMode?
    /// Add on top of what's on screen instead of replacing it.
    var overlay: Bool?
    var mediaOpacity: Double?

    /// Default is Auto: the software reads each screen's real size and fits the media to it.
    var effectiveFit: FitMode { fitMode ?? .auto }

    /// Layered cue: every layer fires on one GO; each layer's pre-wait is its delay.
    var layers: [Cue]?

    // Special effect
    var sfxKind: SFXKind?
    var sfxDeviceIDs: [UUID]?
    var sfxPattern: SFXPattern?
    var sfxDuration: Double?

    init(kind: CueKind, number: String = "", name: String = "") {
        self.kind = kind
        self.number = number
        self.name = name
    }

    var displayName: String {
        if !name.isEmpty { return name }
        switch kind {
        case .audio: return audioPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "Audio cue"
        case .video: return videoPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "Video cue"
        case .layered:
            let parts = (layers ?? []).map { $0.displayName }
            return parts.isEmpty ? "Layered cue" : parts.joined(separator: " + ")
        default: return kind.label
        }
    }
}

// MARK: - Audio

struct AudioSettings: Codable, Equatable {
    var outputDeviceUID: String?
    var inputDeviceUID: String?
    var bufferFrames: Int = 128
    var masterGainDB: Double = 0
    /// Master graphic EQ on everything the Mac plays (tracks, videos, live vocal). nil = flat.
    var eq: MasterEQ? = nil
}

struct MasterEQ: Codable, Equatable {
    static let frequencies: [Float] = [31, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let labels = ["31", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    var enabled = true
    var gains: [Double] = Array(repeating: 0, count: 10)   // dB, ±12
    var highPassHz: Double = 0                              // 0 = off
    var preset: String = "Flat"

    static let presets: [(name: String, gains: [Double], hp: Double)] = [
        ("Flat", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0], 0),
        ("Dancehall Club", [5, 4, 2, 0, -1, -1, 0, 1, 2, 2], 25),
        ("Vocal Clarity", [0, -1, -2, -2, 0, 1, 3, 3, 1, 0], 60),
        ("Festival / Outdoor", [3, 3, 1, 0, -1, 0, 1, 2, 3, 3], 30),
        ("Small Room (tame bass)", [-4, -3, -1, 0, 0, 0, 1, 1, 0, -1], 50),
        ("Loudness (low volume)", [6, 4, 1, 0, -1, 0, 0, 2, 4, 5], 0),
        ("Warm", [2, 2, 1, 1, 0, 0, -1, -1, -2, -3], 30)
    ]
}

struct VocalRack: Codable, Equatable {
    var enabled: Bool = false
    /// Zero-based hardware input channel on the selected interface (0 = input 1).
    var inputChannel: Int = 0
    var gainDB: Double = 0
    var bypassAll: Bool = false
    var plugins: [PluginSlot] = []
    /// Snapshots of the whole rack that Vocal FX cues can recall (e.g. "Hard tune", "Ballad").
    var presets: [VocalPreset] = []
}

struct PluginSlot: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var manufacturer: String
    var componentType: UInt32
    var componentSubType: UInt32
    var componentManufacturer: UInt32
    var bypassed: Bool = false
    /// Binary property list of the Audio Unit's fullState, so settings survive save/reload.
    var state: Data?
}

struct VocalPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// slot id -> plugin state
    var states: [String: Data] = [:]
    var bypassed: [String: Bool] = [:]
}

// MARK: - Screens

struct ScreenOutput: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    /// CGDirectDisplayID of the physical screen. nil = windowed preview.
    var displayID: UInt32?
    var windowed: Bool = true
    /// Show generated 3D visuals here while a song light show runs (nil = yes).
    var autoVisuals: Bool?
    /// Auto fit: fill letterbox bars with a blurred copy of the media (nil = yes).
    var blurEdges: Bool?
}

/// Where on a screen a video/image sits (normalised, origin top-left).
enum ScreenRegion: String, Codable, CaseIterable, Identifiable {
    case full, left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight,
         thirdLeft, thirdCenter, thirdRight, center, pipTopLeft, pipTopRight, pipBottomLeft, pipBottomRight
    var id: String { rawValue }
    var label: String {
        switch self {
        case .full: return "Full screen"
        case .left: return "Left half"
        case .right: return "Right half"
        case .top: return "Top half"
        case .bottom: return "Bottom half"
        case .topLeft: return "Top-left quarter"
        case .topRight: return "Top-right quarter"
        case .bottomLeft: return "Bottom-left quarter"
        case .bottomRight: return "Bottom-right quarter"
        case .thirdLeft: return "Left third"
        case .thirdCenter: return "Centre third"
        case .thirdRight: return "Right third"
        case .center: return "Centre (60%)"
        case .pipTopLeft: return "Small top-left (logo / PiP)"
        case .pipTopRight: return "Small top-right (logo / PiP)"
        case .pipBottomLeft: return "Small bottom-left"
        case .pipBottomRight: return "Small bottom-right"
        }
    }
    var rect: CGRect {
        let p = 0.03, s = 0.28
        switch self {
        case .full: return CGRect(x: 0, y: 0, width: 1, height: 1)
        case .left: return CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .right: return CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .top: return CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case .bottom: return CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case .topLeft: return CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        case .topRight: return CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        case .bottomLeft: return CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        case .bottomRight: return CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        case .thirdLeft: return CGRect(x: 0, y: 0, width: 1.0 / 3, height: 1)
        case .thirdCenter: return CGRect(x: 1.0 / 3, y: 0, width: 1.0 / 3, height: 1)
        case .thirdRight: return CGRect(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 1)
        case .center: return CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        case .pipTopLeft: return CGRect(x: p, y: p, width: s, height: s)
        case .pipTopRight: return CGRect(x: 1 - p - s, y: p, width: s, height: s)
        case .pipBottomLeft: return CGRect(x: p, y: 1 - p - s, width: s, height: s)
        case .pipBottomRight: return CGRect(x: 1 - p - s, y: 1 - p - s, width: s, height: s)
        }
    }
}

/// How media is resized to its area.
enum FitMode: String, Codable, CaseIterable, Identifiable {
    case auto, fill, fit, stretch
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto (detect screen size)"
        case .fill: return "Fill (crop edges)"
        case .fit: return "Fit (show everything)"
        case .stretch: return "Stretch to fit"
        }
    }
}

// MARK: - Control

struct ControlSettings: Codable, Equatable {
    var oscEnabled: Bool = true
    var oscPort: UInt16 = 53535
    var midiEnabled: Bool = true
    var midiMappings: [MIDIMapping] = []
}

enum ControlAction: String, Codable, CaseIterable, Identifiable {
    case go, stopAll, panic, standbyNext, standbyPrevious, blackout, vocalBypassToggle
    var id: String { rawValue }
    var label: String {
        switch self {
        case .go: return "GO"
        case .stopAll: return "Stop all"
        case .panic: return "Panic (fade everything)"
        case .standbyNext: return "Standby next"
        case .standbyPrevious: return "Standby previous"
        case .blackout: return "Lighting blackout toggle"
        case .vocalBypassToggle: return "Vocal FX bypass toggle"
        }
    }
}

struct MIDIMapping: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case note, cc, program }
    var id = UUID()
    var action: ControlAction
    var kind: Kind
    var channel: Int   // 0-15, -1 = omni
    var number: Int    // note / cc / program number

    var description: String {
        let ch = channel < 0 ? "any ch" : "ch \(channel + 1)"
        switch kind {
        case .note: return "Note \(number) (\(ch))"
        case .cc: return "CC \(number) (\(ch))"
        case .program: return "Program \(number) (\(ch))"
        }
    }
}
