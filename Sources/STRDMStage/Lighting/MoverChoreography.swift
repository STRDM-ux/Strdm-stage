import Foundation

/// Live movement choreographies for the moving heads — they drive the real DMX pan/tilt, the 2D map and the 3D venue.
enum MoverChoreo: String, CaseIterable, Identifiable, Codable {
    case wave3D, symFan, scissors, domino, smooth, climax
    var id: String { rawValue }
    var label: String {
        switch self {
        case .wave3D: return "3D Wave"
        case .symFan: return "Sym Fan"
        case .scissors: return "Scissors"
        case .domino: return "Domino"
        case .smooth: return "Smooth"
        case .climax: return "Climax"
        }
    }
    var symbol: String {
        switch self {
        case .wave3D: return "water.waves"
        case .symFan: return "fan.fill"
        case .scissors: return "scissors"
        case .domino: return "rectangle.split.3x1"
        case .smooth: return "circle.dotted"
        case .climax: return "bolt.fill"
        }
    }
    /// Beats per full cycle at speed 1.
    var periodBeats: Double {
        switch self {
        case .wave3D: return 8
        case .symFan: return 4
        case .scissors: return 2
        case .domino: return 4
        case .smooth: return 16
        case .climax: return 2
        }
    }

    /// Pan (° from facing the audience, + = stage right) and tilt (° from straight down, 90 = horizontal over the crowd)
    /// for mover `u` (0 stage left … 1 stage right) at cycle phase `ph` (radians).
    func angles(u: Double, index: Int, ph: Double, size k: Double) -> (pan: Double, tilt: Double) {
        let side = u < 0.5 ? -1.0 : 1.0
        let mirror = (u - 0.5) * 2          // −1…1, symmetric about centre
        switch self {
        case .wave3D:
            return (28 * k * sin(ph - u * 2 * .pi), 55 + 22 * k * sin(ph - u * 2 * .pi + .pi / 2))
        case .symFan:
            let open = 0.5 + 0.5 * sin(ph)
            return (mirror * 62 * k * open, 62 + 10 * k * open)
        case .scissors:
            return ((index % 2 == 0 ? 1 : -1) * 42 * k * sin(ph), 58)
        case .domino:
            let pop = pow(max(0, cos(ph - u * 2 * .pi)), 10)
            return (side * 12 * k, 25 + 70 * k * pop)
        case .smooth:
            return (32 * k * sin(ph + u * 2), 50 + 18 * k * cos(ph + u * 2))
        case .climax:
            return (70 * k * sin(ph * 2 + Double(index) * 1.7), 62 + 30 * k * sin(ph * 3 + Double(index)))
        }
    }
}

extension LightingEngine {
    /// Beat position right now, smooth between beats (songStatus only updates once per beat).
    var songBeatNow: Double? {
        guard let run = songRun else { return nil }
        let t = Date().timeIntervalSince(run.start) + run.offset
        return max(0, run.show.analysis.beatPosition(t))
    }

    /// Beat-synced when a song is running, otherwise 120 BPM.
    func applyChoreography() {
        guard let choreo else { return }
        let movers = fixtures.filter { role($0) == .mover }.sorted { position($0).x < position($1).x }
        guard !movers.isEmpty else { return }
        let beats = songBeatNow ?? Date().timeIntervalSinceReferenceDate * 2
        let ph = beats / choreo.periodBeats * 2 * .pi * choreoSpeed
        var next = live
        for (i, f) in movers.enumerated() {
            guard var values = next[f.id] else { continue }
            let u = movers.count == 1 ? 0.5 : Double(i) / Double(movers.count - 1)
            let a = choreo.angles(u: u, index: i, ph: ph, size: choreoSize)
            write(pan: clamp((a.pan + 270) / 540), tilt: clamp((a.tilt + 135) / 270), into: &values, for: f)
            if choreoLightsUp {
                for (c, ch) in f.profile.channels.enumerated() where c < values.count && ch.kind == .intensity {
                    values[c] = max(values[c], 230)
                }
                let colorIdx = f.profile.channels.indices.filter { $0 < values.count && f.profile.channels[$0].kind.isColor }
                if !colorIdx.isEmpty && colorIdx.allSatisfy({ values[$0] < 8 }) {
                    for c in colorIdx where f.profile.channels[c].kind == .white || f.profile.channels[c].kind == .red
                        || f.profile.channels[c].kind == .green || f.profile.channels[c].kind == .blue { values[c] = 255 }
                }
            }
            next[f.id] = values
        }
        if next != live { live = next }
    }
}
