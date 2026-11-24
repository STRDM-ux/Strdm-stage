import Foundation
import SwiftUI

enum StageItemKind: String, Codable, CaseIterable, Identifiable {
    case vocalMic, monitorWedge, iem, drums, drumRiser, bassAmp, guitarAmp, keys, djBooth, playback,
         diBox, powerDrop, sideFill, sub, ledWall, riser, percussion, horns, person, label,
         truss, trussTower, catwalk, bStage, roundRiser, stairs, ramp, setPiece, scrim, ledFloor, lineArray
    var id: String { rawValue }

    /// Palette groups for the stage designer.
    static let structure: [StageItemKind] = [.truss, .trussTower, .riser, .roundRiser, .drumRiser, .catwalk, .bStage,
                                             .stairs, .ramp, .ledWall, .ledFloor, .scrim, .setPiece, .lineArray]
    static let band: [StageItemKind] = [.person, .vocalMic, .drums, .percussion, .keys, .djBooth, .playback, .bassAmp,
                                        .guitarAmp, .horns, .monitorWedge, .sideFill, .sub, .iem, .diBox, .powerDrop, .label]

    /// Platforms performers can stand on (drawn as decks in 3D).
    var isDeck: Bool { [.riser, .drumRiser, .roundRiser, .catwalk, .bStage, .stairs, .ramp].contains(self) }
    /// Deck extensions that sit on the venue floor (can be in front of the stage).
    var isFloorDeck: Bool { self == .catwalk || self == .bStage }
    var isRound: Bool { self == .roundRiser || self == .bStage }
    var isRigging: Bool { self == .truss || self == .trussTower || self == .lineArray }
    /// Structural items that stage templates replace.
    var isStructure: Bool { Self.structure.contains(self) }

    /// Default height in metres (top of the object above the deck; trusses: trim height).
    var defaultHeight: Double {
        switch self {
        case .truss: return 6
        case .trussTower: return 6.5
        case .lineArray: return 7
        case .ledWall: return 4.5
        case .scrim: return 5
        case .setPiece: return 2
        case .riser, .drumRiser: return 0.4
        case .roundRiser: return 0.6
        case .catwalk, .bStage: return 0
        case .stairs, .ramp: return 0.6
        case .ledFloor: return 0.02
        default: return 1
        }
    }

    var label: String {
        switch self {
        case .vocalMic: return "Vocal Mic"
        case .monitorWedge: return "Wedge"
        case .iem: return "IEM Pack"
        case .drums: return "Drum Kit"
        case .drumRiser: return "Drum Riser"
        case .bassAmp: return "Bass Amp"
        case .guitarAmp: return "Guitar Amp"
        case .keys: return "Keys"
        case .djBooth: return "DJ / Selector"
        case .playback: return "Playback Rig"
        case .diBox: return "DI Box"
        case .powerDrop: return "Power Drop"
        case .sideFill: return "Side Fill"
        case .sub: return "Sub"
        case .ledWall: return "LED Wall"
        case .riser: return "Riser"
        case .percussion: return "Percussion"
        case .horns: return "Horns"
        case .person: return "Performer"
        case .label: return "Text Label"
        case .truss: return "Truss"
        case .trussTower: return "Truss Tower"
        case .catwalk: return "Catwalk / Thrust"
        case .bStage: return "B-Stage (round)"
        case .roundRiser: return "Round Riser"
        case .stairs: return "Stairs"
        case .ramp: return "Ramp"
        case .setPiece: return "Set Piece"
        case .scrim: return "Scrim / Gauze"
        case .ledFloor: return "LED Floor"
        case .lineArray: return "PA Line Array"
        }
    }

    var symbol: String {
        switch self {
        case .vocalMic: return "music.mic"
        case .monitorWedge: return "speaker.wave.2.fill"
        case .iem: return "headphones"
        case .drums: return "circle.grid.cross.fill"
        case .drumRiser, .riser: return "square.stack.3d.up.fill"
        case .bassAmp, .guitarAmp: return "hifispeaker.fill"
        case .keys: return "pianokeys"
        case .djBooth: return "opticaldisc.fill"
        case .playback: return "laptopcomputer"
        case .diBox: return "cable.connector"
        case .powerDrop: return "bolt.fill"
        case .sideFill, .sub: return "hifispeaker.2.fill"
        case .ledWall: return "tv.fill"
        case .percussion: return "circle.circle.fill"
        case .horns: return "music.quarternote.3"
        case .person: return "figure.stand"
        case .label: return "textformat"
        case .truss: return "rectangle.split.3x1"
        case .trussTower: return "building.columns"
        case .catwalk: return "arrow.down.to.line.compact"
        case .bStage: return "circle.circle"
        case .roundRiser: return "circle.fill"
        case .stairs: return "stairs"
        case .ramp: return "triangle.fill"
        case .setPiece: return "cube.fill"
        case .scrim: return "rectangle.dashed"
        case .ledFloor: return "square.grid.4x3.fill"
        case .lineArray: return "speaker.wave.3.fill"
        }
    }

    /// Default footprint in metres (width, depth).
    var defaultSize: CGSize {
        switch self {
        case .vocalMic: return CGSize(width: 0.5, height: 0.5)
        case .monitorWedge: return CGSize(width: 0.7, height: 0.5)
        case .iem, .diBox, .powerDrop: return CGSize(width: 0.4, height: 0.4)
        case .drums: return CGSize(width: 2.0, height: 1.8)
        case .drumRiser: return CGSize(width: 2.4, height: 2.4)
        case .bassAmp, .guitarAmp: return CGSize(width: 0.8, height: 0.5)
        case .keys: return CGSize(width: 1.5, height: 0.8)
        case .djBooth: return CGSize(width: 1.8, height: 0.9)
        case .playback: return CGSize(width: 1.0, height: 0.7)
        case .sideFill: return CGSize(width: 0.8, height: 0.8)
        case .sub: return CGSize(width: 1.0, height: 0.8)
        case .ledWall: return CGSize(width: 6.0, height: 0.4)
        case .riser: return CGSize(width: 2.0, height: 2.0)
        case .percussion: return CGSize(width: 1.4, height: 1.2)
        case .horns: return CGSize(width: 2.0, height: 1.0)
        case .person: return CGSize(width: 0.6, height: 0.6)
        case .label: return CGSize(width: 2.0, height: 0.5)
        case .truss: return CGSize(width: 12, height: 0.3)
        case .trussTower: return CGSize(width: 0.5, height: 0.5)
        case .catwalk: return CGSize(width: 2, height: 6)
        case .bStage: return CGSize(width: 4, height: 4)
        case .roundRiser: return CGSize(width: 3, height: 3)
        case .stairs: return CGSize(width: 1.5, height: 1.2)
        case .ramp: return CGSize(width: 1.5, height: 2.5)
        case .setPiece: return CGSize(width: 2, height: 1)
        case .scrim: return CGSize(width: 10, height: 0.1)
        case .ledFloor: return CGSize(width: 6, height: 3)
        case .lineArray: return CGSize(width: 0.8, height: 0.8)
        }
    }

    var color: Color {
        switch self {
        case .vocalMic, .person: return .pink
        case .monitorWedge, .iem, .sideFill, .sub: return .teal
        case .drums, .drumRiser, .riser, .percussion: return .orange
        case .bassAmp, .guitarAmp, .keys, .horns: return .indigo
        case .djBooth, .playback: return .purple
        case .diBox: return .gray
        case .powerDrop: return .red
        case .ledWall: return .blue
        case .label: return .secondary
        case .truss, .trussTower: return Color(white: 0.75)
        case .catwalk, .bStage, .roundRiser, .stairs, .ramp: return .brown
        case .setPiece: return .mint
        case .scrim: return .cyan
        case .ledFloor: return .blue
        case .lineArray: return .teal
        }
    }
}

struct StageItem: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var kind: StageItemKind
    var label: String
    /// Centre position in metres from stage-left/downstage corner (x across, y = depth from downstage edge).
    var x: Double
    var y: Double
    var width: Double
    var depth: Double
    var rotation: Double = 0
    var notes: String = ""
    /// Height of the top above the deck (trusses: trim height). nil = the kind's default.
    var height: Double? = nil
    /// Lift above the deck (e.g. a set piece on a riser). nil = 0.
    var elevation: Double? = nil
    var locked: Bool? = nil
    /// LED walls: panel type, grid and processor setup (pixel map, power, weight).
    var led: LEDWallSpec? = nil

    var topHeight: Double { height ?? kind.defaultHeight }
}

struct StagePlot: Codable, Equatable {
    var stageWidth: Double = 12
    var stageDepth: Double = 8
    /// Height of the stage deck above the venue floor (metres). nil = 1.2 m.
    var deckHeight: Double? = nil
    var deck: Double { deckHeight ?? 1.2 }
    var items: [StageItem] = []
    /// Optional venue / stage-set model made in Blender (exported as .usdz/.usdc/.obj) shown in 3D views.
    var venueModelPath: String?
    var venueModelScale: Double?
    var venueModelOffsetY: Double?
}

struct InputChannel: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var channel: Int
    var source: String
    var micOrDI: String
    var stand: String = ""
    var phantom: Bool = false
    var notes: String = ""

    static let starterList: [InputChannel] = [
        InputChannel(channel: 1, source: "Lead Vocal", micOrDI: "Wireless SM58 / Beta 58", stand: "Tall boom", notes: "Auto-Tune insert from playback rig"),
        InputChannel(channel: 2, source: "Hype / BG Vocal", micOrDI: "Wireless SM58", stand: "Tall boom"),
        InputChannel(channel: 3, source: "Playback Stems L", micOrDI: "DI (stereo)", phantom: false),
        InputChannel(channel: 4, source: "Playback Stems R", micOrDI: "DI (stereo)"),
        InputChannel(channel: 5, source: "Click / Talkback", micOrDI: "DI", notes: "IEM only — never to FOH"),
        InputChannel(channel: 6, source: "DJ L", micOrDI: "DI (stereo)"),
        InputChannel(channel: 7, source: "DJ R", micOrDI: "DI (stereo)")
    ]
}

struct VenueInfo: Codable, Equatable {
    var artist: String = "Armanii"
    var tourName: String = ""
    var venueName: String = ""
    var city: String = ""
    var showDate: Date = Date()
    var loadIn: String = ""
    var soundcheck: String = ""
    var doors: String = ""
    var setTime: String = ""
    var setLength: String = ""
    var capacity: String = ""
    var stageDimensions: String = ""
    var power: String = ""
    var paSystem: String = ""
    var lightingDesk: String = ""
    var videoNotes: String = ""
    var productionContact: String = ""
    var promoterContact: String = ""
    var hospitality: String = ""
    var notes: String = ""
}
