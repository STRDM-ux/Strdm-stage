import Foundation

enum DMXProtocol: String, Codable, CaseIterable, Identifiable {
    case artNet, sACN
    var id: String { rawValue }
    var label: String { self == .artNet ? "Art-Net" : "sACN (E1.31)" }
}

enum ChannelKind: String, Codable, CaseIterable {
    case intensity, red, green, blue, white, amber, uv, pan, panFine, tilt, tiltFine, speed, strobe, colorWheel, gobo, effect, haze, other
    case laserMode, laserPattern, laserColor, laserZoom, laserRotate, laserX, laserY, laserSpeed

    /// Channels scaled by the grand master and forced to zero on blackout.
    var isIntensityLike: Bool {
        switch self {
        case .intensity, .haze: return true
        default: return false
        }
    }
    var isColor: Bool {
        switch self {
        case .red, .green, .blue, .white, .amber, .uv: return true
        default: return false
        }
    }
}

struct ChannelDef: Codable, Equatable, Hashable {
    var name: String
    var kind: ChannelKind
    var defaultValue: UInt8 = 0
}

struct FixtureProfile: Codable, Equatable, Hashable, Identifiable {
    var id: String { name }
    var name: String
    var channels: [ChannelDef]

    /// True when the fixture has no dedicated dimmer, so colour channels are the intensity.
    var colorIsIntensity: Bool { !channels.contains { $0.kind == .intensity } }

    static let library: [FixtureProfile] = [
        FixtureProfile(name: "Dimmer (1ch)", channels: [
            ChannelDef(name: "Intensity", kind: .intensity)
        ]),
        FixtureProfile(name: "LED Par RGB (3ch)", channels: [
            ChannelDef(name: "Red", kind: .red), ChannelDef(name: "Green", kind: .green), ChannelDef(name: "Blue", kind: .blue)
        ]),
        FixtureProfile(name: "LED Par RGBW (4ch)", channels: [
            ChannelDef(name: "Red", kind: .red), ChannelDef(name: "Green", kind: .green),
            ChannelDef(name: "Blue", kind: .blue), ChannelDef(name: "White", kind: .white)
        ]),
        FixtureProfile(name: "LED Par Dim+RGBW+Strobe (6ch)", channels: [
            ChannelDef(name: "Dimmer", kind: .intensity), ChannelDef(name: "Red", kind: .red),
            ChannelDef(name: "Green", kind: .green), ChannelDef(name: "Blue", kind: .blue),
            ChannelDef(name: "White", kind: .white), ChannelDef(name: "Strobe", kind: .strobe)
        ]),
        FixtureProfile(name: "LED Par RGBWAUV + Dim (8ch)", channels: [
            ChannelDef(name: "Dimmer", kind: .intensity), ChannelDef(name: "Red", kind: .red),
            ChannelDef(name: "Green", kind: .green), ChannelDef(name: "Blue", kind: .blue),
            ChannelDef(name: "White", kind: .white), ChannelDef(name: "Amber", kind: .amber),
            ChannelDef(name: "UV", kind: .uv), ChannelDef(name: "Strobe", kind: .strobe)
        ]),
        FixtureProfile(name: "Moving Head Wash (13ch)", channels: [
            ChannelDef(name: "Pan", kind: .pan, defaultValue: 128), ChannelDef(name: "Pan Fine", kind: .panFine),
            ChannelDef(name: "Tilt", kind: .tilt, defaultValue: 128), ChannelDef(name: "Tilt Fine", kind: .tiltFine),
            ChannelDef(name: "Speed", kind: .speed), ChannelDef(name: "Dimmer", kind: .intensity),
            ChannelDef(name: "Strobe", kind: .strobe), ChannelDef(name: "Red", kind: .red),
            ChannelDef(name: "Green", kind: .green), ChannelDef(name: "Blue", kind: .blue),
            ChannelDef(name: "White", kind: .white), ChannelDef(name: "Zoom", kind: .effect),
            ChannelDef(name: "Macro", kind: .other)
        ]),
        FixtureProfile(name: "Moving Head Spot (14ch)", channels: [
            ChannelDef(name: "Pan", kind: .pan, defaultValue: 128), ChannelDef(name: "Pan Fine", kind: .panFine),
            ChannelDef(name: "Tilt", kind: .tilt, defaultValue: 128), ChannelDef(name: "Tilt Fine", kind: .tiltFine),
            ChannelDef(name: "Speed", kind: .speed), ChannelDef(name: "Dimmer", kind: .intensity),
            ChannelDef(name: "Strobe", kind: .strobe), ChannelDef(name: "Color Wheel", kind: .colorWheel),
            ChannelDef(name: "Gobo", kind: .gobo), ChannelDef(name: "Gobo Rotation", kind: .gobo),
            ChannelDef(name: "Prism", kind: .effect), ChannelDef(name: "Focus", kind: .effect),
            ChannelDef(name: "Frost", kind: .effect), ChannelDef(name: "Reset", kind: .other)
        ]),
        FixtureProfile(name: "Strobe (2ch)", channels: [
            ChannelDef(name: "Intensity", kind: .intensity), ChannelDef(name: "Rate", kind: .strobe)
        ]),
        FixtureProfile(name: "Hazer / Fog (2ch)", channels: [
            ChannelDef(name: "Output", kind: .haze), ChannelDef(name: "Fan", kind: .other)
        ]),
        FixtureProfile(name: "Blinder 2-cell (2ch)", channels: [
            ChannelDef(name: "Cell 1", kind: .intensity), ChannelDef(name: "Cell 2", kind: .intensity)
        ]),
        // Typical RGB show laser in DMX mode. Values: Mode 0 = off / 255 = DMX; Pattern, Colour and
        // Rotation use the usual 8 slots per channel — check your laser's manual and adjust the profile if needed.
        FixtureProfile(name: "Laser RGB (9ch)", channels: [
            ChannelDef(name: "Mode", kind: .laserMode), ChannelDef(name: "Pattern", kind: .laserPattern),
            ChannelDef(name: "Zoom", kind: .laserZoom), ChannelDef(name: "Rotation", kind: .laserRotate),
            ChannelDef(name: "X Move", kind: .laserX, defaultValue: 64), ChannelDef(name: "Y Move", kind: .laserY, defaultValue: 64),
            ChannelDef(name: "Colour", kind: .laserColor), ChannelDef(name: "Scan Speed", kind: .laserSpeed, defaultValue: 200),
            ChannelDef(name: "Strobe", kind: .strobe)
        ])
    ]
}

struct Fixture: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var profile: FixtureProfile
    /// Zero-based universe as sent on the wire (Art-Net 0 / sACN 1 are both "universe 1" in the UI).
    var universe: Int = 0
    /// 1-based DMX start address.
    var address: Int = 1
    var group: String = ""
    /// Position on the live stage map, metres (x across from stage left, y from the downstage edge; negative = front truss).
    var stageX: Double?
    var stageY: Double?
    /// Hanging height in metres (used to aim moving heads at performers).
    var stageZ: Double?

    var footprint: Int { profile.channels.count }
    var lastAddress: Int { address + footprint - 1 }
}

struct LightScene: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    /// fixture id (uuidString) -> channel values (0...255, or -1 = not part of this scene, keeps tracking).
    var levels: [String: [Int]] = [:]
}

struct LightingSetup: Codable, Equatable {
    var dmxProtocol: DMXProtocol = .artNet
    /// Art-Net destination. 2.255.255.255 / 10.255.255.255 broadcast, or a node's IP.
    var artNetDestination: String = "2.255.255.255"
    /// For sACN: multicast by default, or set a unicast IP.
    var sACNUnicast: String = ""
    var outputEnabled: Bool = false
    var fixtures: [Fixture] = []
    var scenes: [LightScene] = []
}
