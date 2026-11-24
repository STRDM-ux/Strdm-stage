import Foundation
import SwiftUI

/// Mirrors the JSON from STRDM Stage's /api/state.
struct LiveState: Decodable, Equatable {
    struct CueItem: Decodable, Equatable, Identifiable { let id: String; let number: String; let name: String; let kind: String; let notes: String; let running: Bool; let auto: String }
    struct Running: Decodable, Equatable, Identifiable {
        let title: String; let number: String; let kind: String; let progress: Double?; let remaining: Double?; let elapsed: Double; let phase: String
        var id: String { number + title }
    }
    struct Song: Decodable, Equatable { let name: String; let section: String; let bpm: Double; let beat: Int; let vibe: String; let elapsed: Double; let duration: Double }
    struct Named: Decodable, Equatable, Identifiable, Hashable { let id: String; let name: String }
    struct EQ: Decodable, Equatable { let enabled: Bool; let gains: [Double]; let labels: [String]; let lowCut: Double; let preset: String; let presets: [String] }
    struct Dot: Decodable, Equatable { let x: Double; let y: Double; let c: String; let l: Double; let kind: String }
    struct Person: Decodable, Equatable { let x: Double; let y: Double; let name: String }
    struct MapState: Decodable, Equatable { let w: Double; let d: Double; let lights: [Dot]; let people: [Person]; let items: [Dot] }
    struct Screen: Decodable, Equatable, Hashable { let name: String; let showing: String; let open: Bool }
    struct Crew: Decodable, Equatable { let critical: Int; let warnings: Int; let fixable: Int; let top: [String] }

    let show: String
    let standbyIndex: Int
    let standby: CueItem?
    let cues: [CueItem]
    let running: [Running]
    let blackout: Bool
    let gm: Double
    let scenes: [Named]
    let activeScene: String?
    let performers: [Named]
    let follow: String?
    let song: Song?
    let vocalEnabled: Bool
    let vocalBypass: Bool
    let vocalPlugins: [String]
    let vocalPresets: [Named]
    let outputLevel: Double
    let clock: String
    // Newer Mac builds
    let eq: EQ?
    let masterGain: Double?
    let sfxArmed: Bool?
    let sfxUnits: Int?
    let visualStyles: [Named]?
    let visualStyle: String?
    let screens: [Screen]?
    let map: MapState?
    let crew: Crew?
    let liveOn: Bool?
    let liveBPM: Double?
    let liveSection: String?
}

enum CueKind {
    static func symbol(_ kind: String) -> String {
        switch kind {
        case "audio": return "music.note"
        case "lights": return "lightbulb.fill"
        case "video": return "film.fill"
        case "videoBlack": return "rectangle.fill"
        case "fade": return "speaker.wave.1.fill"
        case "vocalFX": return "music.mic"
        case "wait": return "hourglass"
        case "memo": return "note.text"
        case "layered": return "square.stack.3d.up.fill"
        case "effect": return "flame.fill"
        default: return "circle"
        }
    }
    static func color(_ kind: String) -> Color {
        switch kind {
        case "audio": return .blue
        case "lights": return .yellow
        case "video", "videoBlack": return .purple
        case "effect": return .orange
        case "vocalFX": return .pink
        default: return .secondary
        }
    }
}

extension Color {
    init(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
    // STRDM Live brand: neon pink + cyan orbit
    static let strdmPink = Color(red: 1, green: 61 / 255, blue: 129 / 255)
    static let strdmPurple = Color(red: 0, green: 229 / 255, blue: 1)   // cyan accent
    static let goGreen = Color(red: 0.13, green: 0.83, blue: 0.38)
    static let card = Color(white: 0.09)
}

func timeString(_ s: Double) -> String {
    let t = max(0, Int(s))
    return "\(t / 60):" + String(format: "%02d", t % 60)
}
