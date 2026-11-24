import Foundation
import SwiftUI

// MARK: - Model

/// How one song hands over to the next — the audio move and the matching lighting moment.
enum MixTransition: String, Codable, CaseIterable, Identifiable {
    case blend, cutOnDrop, echoOut, blackoutDrop
    var id: String { rawValue }
    var label: String {
        switch self {
        case .blend: return "Blend"
        case .cutOnDrop: return "Cut on the drop"
        case .echoOut: return "Fade & breathe"
        case .blackoutDrop: return "Blackout → slam"
        }
    }
    var symbol: String {
        switch self {
        case .blend: return "arrow.left.arrow.right"
        case .cutOnDrop: return "scissors"
        case .echoOut: return "wind"
        case .blackoutDrop: return "bolt.fill"
        }
    }
    var detail: String {
        switch self {
        case .blend: return "16-beat crossfade; lights cross-fade colours, dimmer dips slightly."
        case .cutOnDrop: return "Hard cut on the bar; strobe hit and the next song's look slams in."
        case .echoOut: return "8-beat fade out; lights breathe down then rise with the new song."
        case .blackoutDrop: return "Short blackout + silence, then the next song hits with a strobe and an effect (if armed)."
        }
    }
    /// Length in beats of the outgoing song.
    var beats: Double {
        switch self {
        case .blend: return 16
        case .cutOnDrop: return 0.5
        case .echoOut: return 8
        case .blackoutDrop: return 2
        }
    }
}

struct ShowMix: Codable, Equatable {
    struct Song: Codable, Equatable, Identifiable {
        var id = UUID()
        var lightShowID: UUID
        var name: String
        var path: String
        var clipID: UUID
        var trackIndex: Int
        var start: Double          // mix seconds
        var fileOffset: Double     // seconds into the file where it enters
        var exit: Double           // seconds into the file where the transition to the next song starts
        var end: Double            // mix seconds where this song is fully gone
    }
    struct Transition: Codable, Equatable, Identifiable {
        var id = UUID()
        var kind: MixTransition
        var at: Double             // mix seconds the transition starts
        var length: Double         // seconds
        var auto = true            // chosen by the auto-mixer (false = user picked it)
    }
    var songs: [Song] = []
    var transitions: [Transition] = []
    /// Master light level over the mix (beats → 0…1). Edit it in the Studio's Lights lane.
    var intensity: [AutomationPoint] = []
    var cueIDs: [UUID] = []
    var duration: Double = 0       // seconds
}


// MARK: - Auto mixer

@MainActor
enum ShowMixer {
    /// Builds a continuous mix of the chosen song cues: Deck A / Deck B tracks, beat-aligned transitions,
    /// fades and a master light-level lane — all editable in the Studio.
    static func build(cueIDs: [UUID], store: ShowStore, overrides: [Int: MixTransition] = [:]) -> DAWProject? {
        let shows = store.show.lightShows
        let entries: [(cue: Cue, show: LightShow, path: String)] = cueIDs.compactMap { id in
            guard let cue = store.show.cues.first(where: { $0.id == id }), cue.kind == .audio,
                  let path = cue.audioPath, let lsID = cue.lightShowID, let ls = shows.first(where: { $0.id == lsID }) else { return nil }
            return (cue, ls, path)
        }
        guard !entries.isEmpty else { return nil }
        let bpm = entries[0].show.analysis.bpm > 0 ? entries[0].show.analysis.bpm : 120
        let spb = 60 / bpm                      // project seconds per beat
        var project = DAWProject()
        project.name = "Show Mix — \(store.show.venue.artist.isEmpty ? store.show.name : store.show.venue.artist)"
        project.bpm = bpm
        project.loopEnabled = false
        var deckA = DAWTrack(name: "Deck A", kind: .audio, color: .pink)
        var deckB = DAWTrack(name: "Deck B", kind: .audio, color: .blue)
        var mix = ShowMix()
        mix.cueIDs = entries.map(\.cue.id)

        var cursor = 0.0                        // mix time where the next song enters
        for (i, e) in entries.enumerated() {
            let a = e.show.analysis
            let songSPB = 60 / max(40, a.bpm)
            // Enter on the first downbeat (skips silence / count-ins), except the opener.
            let offset = i == 0 ? 0 : max(0, firstDownbeat(a))
            // Leave at the outro (or 16 beats from the end), on a bar line.
            var exit = a.duration
            if i < entries.count - 1 {
                let outro = e.show.sections.last { $0.label.lowercased().hasPrefix("outro") && $0.start > a.duration * 0.55 }
                exit = outro?.start ?? (a.duration - 16 * songSPB)
                exit = snapToBar(exit, a)
                exit = max(offset + 20, min(a.duration - 1, exit))
            }
            // Transition to the next song: chosen from energy + tempo, unless the user picked one.
            var kind = MixTransition.blend
            if i < entries.count - 1 {
                let next = entries[i + 1].show
                let here = e.show.sections.last { $0.start <= exit }?.energy ?? 0.6
                let nextOpen = next.sections.first?.energy ?? 0.5
                let tempoGap = abs(next.analysis.bpm - a.bpm) / max(1, a.bpm)
                if nextOpen > 0.75 && next.sections.first.map({ $0.label.lowercased().contains("drop") || $0.label.lowercased().contains("chorus") }) == true {
                    kind = tempoGap > 0.08 ? .blackoutDrop : .cutOnDrop
                } else if nextOpen + 0.25 < here {
                    kind = .echoOut
                } else if tempoGap > 0.12 {
                    kind = .blackoutDrop
                } else {
                    kind = .blend
                }
                if let o = overrides[i] { kind = o }
            }
            let tLen = i < entries.count - 1 ? kind.beats * songSPB : 0
            let start = cursor
            let playEnd = (i < entries.count - 1 && kind != .cutOnDrop && kind != .blackoutDrop) ? exit + tLen : exit
            let length = playEnd - offset
            let trackIndex = i % 2
            var clip = AudioClip(path: e.path, start: start / spb, length: length / spb, fileOffset: offset)
            if i > 0 {
                switch mix.transitions.last?.kind ?? .blend {
                case .blend: clip.fadeIn = 8 * songSPB / spb
                case .echoOut: clip.fadeIn = 2 * songSPB / spb
                default: clip.fadeIn = 0
                }
            }
            if i < entries.count - 1 {
                switch kind {
                case .blend, .echoOut: clip.fadeOut = tLen / spb
                case .blackoutDrop: clip.fadeOut = tLen / spb
                case .cutOnDrop: clip.fadeOut = 0.05 / spb
                }
            }
            if trackIndex == 0 { deckA.audioClips.append(clip) } else { deckB.audioClips.append(clip) }
            let exitMix = start + (exit - offset)
            mix.songs.append(.init(lightShowID: e.show.id, name: e.show.name, path: e.path, clipID: clip.id, trackIndex: trackIndex,
                                   start: start, fileOffset: offset, exit: exit, end: start + length))
            if i < entries.count - 1 {
                mix.transitions.append(.init(kind: kind, at: exitMix, length: tLen, auto: overrides[i] == nil))
                switch kind {
                case .blend: cursor = exitMix                              // next song rides in under this one
                case .echoOut: cursor = exitMix + tLen * 0.5
                case .cutOnDrop: cursor = exitMix
                case .blackoutDrop: cursor = exitMix + tLen + 0.35            // a breath of silence in the dark
                }
            }
        }
        mix.duration = mix.songs.map(\.end).max() ?? 0
        mix.intensity = defaultIntensity(mix, spb: spb)
        project.tracks = [deckA, deckB]
        project.mix = mix
        return project
    }

    static func defaultIntensity(_ mix: ShowMix, spb: Double) -> [AutomationPoint] {
        var pts = [AutomationPoint(beat: 0, value: 1)]
        for t in mix.transitions {
            let a = t.at / spb, l = max(0.5, t.length / spb)
            switch t.kind {
            case .blend:
                pts += [AutomationPoint(beat: a, value: 1), AutomationPoint(beat: a + l * 0.5, value: 0.7), AutomationPoint(beat: a + l, value: 1)]
            case .echoOut:
                pts += [AutomationPoint(beat: a, value: 1), AutomationPoint(beat: a + l, value: 0.25), AutomationPoint(beat: a + l + 4, value: 1)]
            case .cutOnDrop:
                pts += [AutomationPoint(beat: a - 1, value: 1), AutomationPoint(beat: a - 0.25, value: 0.1), AutomationPoint(beat: a, value: 1)]
            case .blackoutDrop:
                pts += [AutomationPoint(beat: a, value: 1), AutomationPoint(beat: a + l * 0.6, value: 0), AutomationPoint(beat: a + l + 0.35 / spb, value: 0),
                        AutomationPoint(beat: a + l + 0.4 / spb, value: 1)]
            }
        }
        pts.append(AutomationPoint(beat: mix.duration / spb, value: 1))
        return pts.sorted { $0.beat < $1.beat }
    }

    private static func firstDownbeat(_ a: SongAnalysis) -> Double {
        if let b = a.beats, !b.isEmpty { return b[min(b.count - 1, max(0, a.firstDownbeat ?? 0))] }
        return max(0, a.beatOffset)
    }

    private static func snapToBar(_ t: Double, _ a: SongAnalysis) -> Double {
        guard let b = a.beats, b.count > 8 else {
            let bar = 4 * 60 / max(40, a.bpm)
            return ((t - a.beatOffset) / bar).rounded() * bar + a.beatOffset
        }
        let first = a.firstDownbeat ?? 0
        let candidates = stride(from: first, to: b.count, by: 4).map { b[$0] }
        return candidates.min { abs($0 - t) < abs($1 - t) } ?? t
    }

    // MARK: Lights for the whole mix

    /// One light show covering the whole mix: every song's sections on the mix timeline, transition moments,
    /// merged beat grid / drum hits / curves, and the master light-level lane.
    static func lightShow(for project: DAWProject, store: ShowStore, songPath: String = "") -> LightShow? {
        guard var mix = project.mix, !mix.songs.isEmpty else { return nil }
        let spb = 60 / max(20, project.bpm)
        mix.songs = liveSongs(project)
        mix.duration = max(mix.duration, mix.songs.map(\.end).max() ?? 0)
        var sections: [ShowSection] = []
        var beats: [Double] = [], kicks: [Double] = [], snares: [Double] = []
        let n4 = Int(mix.duration * 4) + 2, n2 = Int(mix.duration * 2) + 2
        var energy = [Double](repeating: 0.5, count: n2)
        var bass = [Double](repeating: 0, count: n4), mid = bass, high = bass, hats = bass, vocal = bass
        var first: LightShow?

        for (i, s) in mix.songs.enumerated() {
            guard let ls = store.show.lightShows.first(where: { $0.id == s.lightShowID }) else { continue }
            if first == nil { first = ls }
            let a = ls.analysis
            // This song owns the lights from its handover point until the next song takes over.
            let from = i == 0 ? 0 : handover(mix, i)
            let to = i == mix.songs.count - 1 ? s.end : handover(mix, i + 1)
            func mixT(_ t: Double) -> Double { s.start + (t - s.fileOffset) }
            for sec in ls.sections {
                let a0 = max(from, mixT(sec.start)), a1 = min(to, mixT(sec.end))
                guard a1 - a0 > 0.05 else { continue }
                var x = sec
                x.id = UUID(); x.start = a0; x.end = a1
                sections.append(x)
            }
            func shift(_ arr: [Double]?) -> [Double] { (arr ?? []).map(mixT).filter { $0 >= from && $0 < to } }
            beats += shift(a.beats); kicks += shift(a.kicks); snares += shift(a.snares)
            for k in Int(from * 2)..<min(n2, Int(to * 2) + 1) {
                let t = Double(k) / 2 - s.start + s.fileOffset
                if t >= 0 { energy[k] = SongAnalysis.curveValue(a.energyCurve, at: t, rate: 2) }
            }
            for k in Int(from * 4)..<min(n4, Int(to * 4) + 1) {
                let t = Double(k) / 4 - s.start + s.fileOffset
                guard t >= 0 else { continue }
                bass[k] = SongAnalysis.curveValue(a.bassCurve, at: t); mid[k] = SongAnalysis.curveValue(a.midCurve, at: t)
                high[k] = SongAnalysis.curveValue(a.highCurve, at: t); hats[k] = SongAnalysis.curveValue(a.hatCurve, at: t)
                vocal[k] = SongAnalysis.curveValue(a.vocalCurve, at: t)
            }
        }
        sections.sort { $0.start < $1.start }
        // Transition moments.
        for (i, t) in mix.transitions.enumerated() where i + 1 < mix.songs.count {
            let h = handover(mix, i + 1)
            guard let k = sections.firstIndex(where: { abs($0.start - h) < 0.06 }) ?? sections.firstIndex(where: { $0.start >= h - 0.06 }) else { continue }
            switch t.kind {
            case .cutOnDrop:
                sections[k].look.strobeBeats = max(sections[k].look.strobeBeats, 1)
            case .blackoutDrop:
                sections[k].look.strobeBeats = max(sections[k].look.strobeBeats, 2)
                if sections[k].look.sfxHit == nil { sections[k].look.sfxHit = .co2 }
                var dark = sections[k]
                dark.id = UUID(); dark.label = "Blackout"; dark.start = t.at + t.length * 0.6; dark.end = h
                dark.look.intensity = 0; dark.look.strobeBeats = 0; dark.look.sfxHit = nil; dark.look.laser = nil
                if dark.end - dark.start > 0.05 {
                    if k > 0 { sections[k - 1].end = min(sections[k - 1].end, dark.start) }
                    sections.insert(dark, at: k)
                }
            case .echoOut:
                if k > 0 {
                    sections[k - 1].look.chase = .breathe
                    sections[k - 1].look.laser = nil
                }
            case .blend:
                break
            }
        }
        // Keep it gapless.
        for i in sections.indices.dropLast() { sections[i].end = sections[i + 1].start }
        guard let base = first else { return nil }
        var analysis = SongAnalysis(duration: mix.duration, bpm: project.bpm, beatOffset: 0, key: base.analysis.key, isMajor: base.analysis.isMajor,
                                    loudnessDB: base.analysis.loudnessDB, brightness: base.analysis.brightness, bassWeight: base.analysis.bassWeight,
                                    onsetsPerSecond: base.analysis.onsetsPerSecond, arousal: base.analysis.arousal, valence: base.analysis.valence,
                                    energyCurve: energy, suggestedVibe: base.vibe, reasoning: "Studio show mix",
                                    beats: beats.sorted(), firstDownbeat: 0, kicks: kicks.sorted(), snares: snares.sorted(),
                                    hatCurve: hats, bassCurve: bass, midCurve: mid, highCurve: high, vocalCurve: vocal)
        analysis.structure = mix.songs.map(\.name).joined(separator: " → ")
        var show = LightShow(name: project.name, songPath: songPath, analysis: analysis, vibe: base.vibe,
                             paletteName: base.paletteName, sections: sections)
        show.fadeOutAtEnd = 4
        // Master light level, sampled 4×/s from the Lights lane.
        show.intensityCurve = (0..<n4).map { k in value(mix.intensity, atBeat: Double(k) / 4 / spb) }
        return show
    }

    /// Song positions as they are now on the timeline (the user may have moved or trimmed clips).
    static func liveSongs(_ project: DAWProject) -> [ShowMix.Song] {
        guard let mix = project.mix else { return [] }
        let spb = 60 / max(20, project.bpm)
        let clips = project.tracks.flatMap(\.audioClips)
        return mix.songs.map { s in
            guard let c = clips.first(where: { $0.id == s.clipID }) else { return s }
            var x = s
            x.start = c.start * spb
            x.end = (c.start + c.length) * spb
            x.fileOffset = c.fileOffset
            return x
        }
    }

    /// Light sections laid on the mix timeline (fast — for drawing the Lights lane).
    struct TimelineSection: Identifiable { let id: UUID; let songIndex: Int; let sectionID: UUID; let start: Double; let end: Double; let look: SectionLook; let label: String }
    static func timelineSections(_ project: DAWProject, store: ShowStore) -> [TimelineSection] {
        guard var mix = project.mix else { return [] }
        mix.songs = liveSongs(project)
        var out: [TimelineSection] = []
        for (i, s) in mix.songs.enumerated() {
            guard let ls = store.show.lightShows.first(where: { $0.id == s.lightShowID }) else { continue }
            let from = i == 0 ? 0 : handover(mix, i)
            let to = i == mix.songs.count - 1 ? s.end : handover(mix, i + 1)
            for sec in ls.sections {
                let a0 = max(from, s.start + sec.start - s.fileOffset), a1 = min(to, s.start + sec.end - s.fileOffset)
                if a1 - a0 > 0.05 { out.append(.init(id: sec.id, songIndex: i, sectionID: sec.id, start: a0, end: a1, look: sec.look, label: sec.label)) }
            }
        }
        return out
    }

    /// Mix time where song i takes over the lights from song i-1.
    static func handover(_ mix: ShowMix, _ i: Int) -> Double {
        guard i > 0, i < mix.songs.count, i - 1 < mix.transitions.count else { return i < mix.songs.count ? mix.songs[i].start : mix.duration }
        let t = mix.transitions[i - 1]
        switch t.kind {
        case .blend: return t.at + t.length * 0.5
        case .echoOut: return mix.songs[i].start
        case .cutOnDrop, .blackoutDrop: return mix.songs[i].start
        }
    }

    static func value(_ pts: [AutomationPoint], atBeat b: Double) -> Double {
        guard let f = pts.first else { return 1 }
        if b <= f.beat { return f.value }
        for (p, q) in zip(pts, pts.dropFirst()) where b <= q.beat {
            let k = (b - p.beat) / max(0.0001, q.beat - p.beat)
            return p.value + (q.value - p.value) * k
        }
        return pts.last?.value ?? 1
    }
}
