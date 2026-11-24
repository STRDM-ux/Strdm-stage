import Foundation
import SwiftUI

/// Special effects: flame units, CO₂ jets, confetti cannons, fireworks/pyro, cold sparks — all on DMX.
enum SFXKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case flame, co2, confetti, fireworks, coldSpark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .flame: return "Flame"
        case .co2: return "CO₂ Jet"
        case .confetti: return "Confetti Cannon"
        case .fireworks: return "Fireworks / Pyro"
        case .coldSpark: return "Cold Spark"
        }
    }
    var plural: String {
        switch self {
        case .flame: return "Flames"
        case .co2: return "CO₂"
        case .confetti: return "Confetti"
        case .fireworks: return "Pyro"
        case .coldSpark: return "Sparks"
        }
    }
    var symbol: String {
        switch self {
        case .flame: return "flame.fill"
        case .co2: return "wind"
        case .confetti: return "party.popper.fill"
        case .fireworks: return "fireworks"
        case .coldSpark: return "sparkles"
        }
    }
    var tint: Color {
        switch self {
        case .flame: return .orange
        case .co2: return .cyan
        case .confetti: return .pink
        case .fireworks: return .red
        case .coldSpark: return .yellow
        }
    }
    /// One-shot devices fire a short trigger pulse and use up a load.
    var isOneShot: Bool { self == .confetti || self == .fireworks }
    var defaultBurst: Double {
        switch self {
        case .flame: return 1.0
        case .co2: return 1.5
        case .confetti, .fireworks: return 0.5
        case .coldSpark: return 3
        }
    }
    var defaultMaxBurst: Double {
        switch self {
        case .flame: return 2.0
        case .co2: return 4.0
        case .confetti, .fireworks: return 0.5
        case .coldSpark: return 10
        }
    }
    var defaultCooldown: Double {
        switch self {
        case .flame: return 2.0
        case .co2: return 0.5
        case .confetti, .fireworks: return 1.0
        case .coldSpark: return 1.0
        }
    }
}

struct SFXDevice: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var kind: SFXKind
    var universe: Int = 1
    var address: Int = 500
    /// Channel offsets inside the device's DMX footprint (1 = the start address).
    var fireChannel: Int = 1
    var fireValue: Int = 255
    /// Safety / enable channel held while the device is armed (flame units usually need one).
    var safetyChannel: Int? = nil
    var safetyValue: Int = 255
    /// Optional height / output channel (cold sparks, some flame units).
    var heightChannel: Int? = nil
    var height: Int = 255
    var maxBurst: Double
    var cooldown: Double
    /// One-shot devices: loads per refill (nil = unlimited).
    var loads: Int? = nil
    /// Allow song shows to fire this automatically on drops (still needs arming).
    var allowAuto: Bool = false
    var stageX: Double? = nil
    var stageY: Double? = nil

    static func make(_ kind: SFXKind, number: Int, universe: Int, address: Int) -> SFXDevice {
        var d = SFXDevice(name: "\(kind.label) \(number)", kind: kind, universe: universe, address: address,
                          maxBurst: kind.defaultMaxBurst, cooldown: kind.defaultCooldown)
        switch kind {
        case .flame:
            d.safetyChannel = 1; d.fireChannel = 2
        case .coldSpark:
            d.heightChannel = 1; d.fireChannel = 2
        case .confetti:
            d.loads = 1
        case .fireworks:
            d.loads = 1
        case .co2:
            break
        }
        return d
    }

    var footprint: Int { max(fireChannel, safetyChannel ?? 0, heightChannel ?? 0) }
    var lastAddress: Int { address + footprint - 1 }
}

enum SFXPattern: String, Codable, CaseIterable, Identifiable, Sendable {
    case all, leftToRight, rightToLeft, centerOut, outsideIn, alternate, random
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "All together"
        case .leftToRight: return "Chase left → right"
        case .rightToLeft: return "Chase right → left"
        case .centerOut: return "Centre out"
        case .outsideIn: return "Outside in"
        case .alternate: return "Odd then even"
        case .random: return "Random"
        }
    }
}

struct SFXSetup: Codable, Equatable {
    var devices: [SFXDevice] = []
    /// Seconds between units in chase patterns.
    var chaseStep: Double = 0.15
    /// Disarm automatically after this many minutes with nothing fired (0 = never).
    var autoDisarmMinutes: Double = 20
}
