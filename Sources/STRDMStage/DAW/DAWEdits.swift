import Foundation
import AVFoundation

/// Editing operations used by the Studio UI. All go through `edit` so they're undoable.
extension DAWEngine {
    func track(_ id: UUID?) -> DAWTrack? { project.tracks.first { $0.id == id } }

    var selectedClipTrack: DAWTrack? {
        project.tracks.first { t in t.midiClips.contains { $0.id == selectedClipID } || t.audioClips.contains { $0.id == selectedClipID } }
    }

    var selectedMIDIClip: MIDIClip? {
        for t in project.tracks { if let c = t.midiClips.first(where: { $0.id == selectedClipID }) { return c } }
        return nil
    }

    func snap(_ beat: Double) -> Double {
        let s = max(0.0625, project.snap)
        return (beat / s).rounded() * s
    }

    // MARK: Tracks

    func addTrack(kind: TrackKind, instrument: InstrumentSpec? = nil, name: String? = nil) {
        let colors = TrackColor.allCases
        var t = DAWTrack(name: name ?? (kind == .audio ? "Audio \(project.tracks.count + 1)" : "Instrument \(project.tracks.count + 1)"),
                         kind: kind, color: colors[project.tracks.count % colors.count])
        if kind == .midi { t.instrument = instrument ?? .synth(preset: "Lead") }
        edit { $0.tracks.append(t) }
        selectedTrackID = t.id
    }

    func deleteTrack(_ id: UUID) {
        edit { $0.tracks.removeAll { $0.id == id } }
        if selectedTrackID == id { selectedTrackID = project.tracks.first?.id }
    }

    func duplicateTrack(_ id: UUID) {
        guard let i = project.tracks.firstIndex(where: { $0.id == id }) else { return }
        var copy = project.tracks[i]
        copy.id = UUID()
        copy.name += " copy"
        copy.effects = copy.effects.map { var e = $0; e.id = UUID(); return e }
        copy.midiClips = copy.midiClips.map { var c = $0; c.id = UUID(); return c }
        copy.audioClips = copy.audioClips.map { var c = $0; c.id = UUID(); return c }
        if case .audioUnit(var slot)? = copy.instrument { slot.id = UUID(); copy.instrument = .audioUnit(slot) }
        edit { $0.tracks.insert(copy, at: i + 1) }
    }

    func updateTrack(_ id: UUID, _ change: (inout DAWTrack) -> Void) {
        edit { p in
            if let i = p.tracks.firstIndex(where: { $0.id == id }) { change(&p.tracks[i]) }
        }
    }

    // MARK: Clips

    @discardableResult
    func newMIDIClip(trackID: UUID, at beat: Double, bars: Int = 4) -> UUID {
        let bar = Double(project.beatsPerBar)
        let clip = MIDIClip(start: floor(beat / bar) * bar, length: bar * Double(bars), name: "Clip")
        updateTrack(trackID) { $0.midiClips.append(clip) }
        selectedClipID = clip.id
        selectedTrackID = trackID
        return clip.id
    }

    func moveClip(_ id: UUID, toStart start: Double) {
        edit { p in
            for t in p.tracks.indices {
                if let c = p.tracks[t].midiClips.firstIndex(where: { $0.id == id }) { p.tracks[t].midiClips[c].start = max(0, start) }
                if let c = p.tracks[t].audioClips.firstIndex(where: { $0.id == id }) { p.tracks[t].audioClips[c].start = max(0, start) }
            }
        }
    }

    func resizeClip(_ id: UUID, length: Double) {
        edit { p in
            for t in p.tracks.indices {
                if let c = p.tracks[t].midiClips.firstIndex(where: { $0.id == id }) { p.tracks[t].midiClips[c].length = max(0.25, length) }
                if let c = p.tracks[t].audioClips.firstIndex(where: { $0.id == id }) { p.tracks[t].audioClips[c].length = max(0.25, length) }
            }
        }
    }

    func deleteSelectedClip() {
        guard let id = selectedClipID else { return }
        edit { p in
            for t in p.tracks.indices {
                p.tracks[t].midiClips.removeAll { $0.id == id }
                p.tracks[t].audioClips.removeAll { $0.id == id }
            }
        }
        selectedClipID = nil
    }

    func duplicateSelectedClip() {
        guard let id = selectedClipID else { return }
        var newID: UUID?
        edit { p in
            for t in p.tracks.indices {
                if let c = p.tracks[t].midiClips.first(where: { $0.id == id }) {
                    var copy = c
                    copy.id = UUID()
                    copy.start = c.start + c.length
                    copy.notes = c.notes.map { var n = $0; n.id = UUID(); return n }
                    p.tracks[t].midiClips.append(copy)
                    newID = copy.id
                }
                if let c = p.tracks[t].audioClips.first(where: { $0.id == id }) {
                    var copy = c
                    copy.id = UUID()
                    copy.start = c.start + c.length
                    p.tracks[t].audioClips.append(copy)
                    newID = copy.id
                }
            }
        }
        if let newID { selectedClipID = newID }
    }

    /// Splits the selected clip at the playhead.
    func splitSelectedAtPlayhead() {
        guard let id = selectedClipID else { return }
        let at = snap(playhead)
        edit { p in
            for t in p.tracks.indices {
                if let i = p.tracks[t].midiClips.firstIndex(where: { $0.id == id }) {
                    let c = p.tracks[t].midiClips[i]
                    guard at > c.start + 0.01, at < c.start + c.length - 0.01 else { return }
                    let cut = at - c.start
                    var left = c, right = c
                    left.length = cut
                    left.notes = c.notes.filter { $0.start < cut }
                    right.id = UUID()
                    right.start = at
                    right.length = c.length - cut
                    right.notes = c.notes.filter { $0.start >= cut }.map { var n = $0; n.start -= cut; return n }
                    p.tracks[t].midiClips[i] = left
                    p.tracks[t].midiClips.append(right)
                }
                if let i = p.tracks[t].audioClips.firstIndex(where: { $0.id == id }) {
                    let c = p.tracks[t].audioClips[i]
                    guard at > c.start + 0.01, at < c.start + c.length - 0.01 else { return }
                    let cut = at - c.start
                    var left = c, right = c
                    left.length = cut
                    right.id = UUID()
                    right.start = at
                    right.length = c.length - cut
                    right.fileOffset = c.fileOffset + cut * secondsPerBeat
                    p.tracks[t].audioClips[i] = left
                    p.tracks[t].audioClips.append(right)
                }
            }
        }
    }

    // MARK: Notes

    func updateClip(_ clipID: UUID, _ change: (inout MIDIClip) -> Void) {
        edit { p in
            for t in p.tracks.indices {
                if let c = p.tracks[t].midiClips.firstIndex(where: { $0.id == clipID }) { change(&p.tracks[t].midiClips[c]) }
            }
        }
    }

    func toggleStep(clipID: UUID, pitch: Int, step: Double, accent: Bool) {
        updateClip(clipID) { c in
            if let i = c.notes.firstIndex(where: { $0.pitch == pitch && abs($0.start - step) < 0.02 }) {
                c.notes.remove(at: i)
            } else {
                c.notes.append(MIDINote(pitch: pitch, start: step, length: 0.25, velocity: accent ? 127 : 100))
            }
        }
    }

    func quantize(clipID: UUID) {
        let s = max(0.0625, project.snap)
        updateClip(clipID) { c in
            for i in c.notes.indices {
                c.notes[i].start = (c.notes[i].start / s).rounded() * s
                c.notes[i].length = max(s, (c.notes[i].length / s).rounded() * s)
            }
        }
    }

    // MARK: Effects

    func addEffect(_ slot: EffectSlot, to target: ChainTarget) {
        edit { p in
            switch target {
            case .track(let id): if let i = p.tracks.firstIndex(where: { $0.id == id }) { p.tracks[i].effects.append(slot) }
            case .bus(let i): if p.buses.indices.contains(i) { p.buses[i].effects.append(slot) }
            case .master: p.master.effects.append(slot)
            }
        }
    }

    func updateEffects(_ target: ChainTarget, _ change: (inout [EffectSlot]) -> Void) {
        edit { p in
            switch target {
            case .track(let id): if let i = p.tracks.firstIndex(where: { $0.id == id }) { change(&p.tracks[i].effects) }
            case .bus(let i): if p.buses.indices.contains(i) { change(&p.buses[i].effects) }
            case .master: change(&p.master.effects)
            }
        }
    }

    func effects(of target: ChainTarget) -> [EffectSlot] {
        switch target {
        case .track(let id): return track(id)?.effects ?? []
        case .bus(let i): return project.buses.indices.contains(i) ? project.buses[i].effects : []
        case .master: return project.master.effects
        }
    }
}

enum ChainTarget: Hashable {
    case track(UUID), bus(Int), master
}

extension PluginSlot {
    init(component c: AVAudioUnitComponent) {
        let d = c.audioComponentDescription
        self.init(name: c.name, manufacturer: c.manufacturerName, componentType: d.componentType,
                  componentSubType: d.componentSubType, componentManufacturer: d.componentManufacturer)
    }
}
