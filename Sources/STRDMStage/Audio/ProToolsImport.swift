import Foundation
import AVFoundation
import AudioToolbox
import SwiftUI
import UniformTypeIdentifiers

/// Reads the insert chains out of a Pro Tools session (.ptx / .ptf) so a vocal chain can be rebuilt in the live rack.
/// Pro Tools sessions are XOR-obfuscated (see the open-source ptformat project); we decode them, read the plug-in
/// catalogue, then walk each track's channel-strip block to find its inserts in order.
struct ProToolsSession {
    struct Insert: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let manufacturer: String   // 4CC, e.g. ksWV (Waves), Antr (Antares), Digi (Avid)
        let product: String
        let bundleID: String
        /// Preset name saved in the session, when the plugin stores one we can read (Waves).
        let preset: String?
    }
    struct Track: Identifiable, Hashable {
        let id = UUID()
        let name: String
        var inserts: [Insert]
        var isMaster: Bool { name.lowercased().hasPrefix("master") }
        var isAux: Bool { let n = name.lowercased(); return n.hasPrefix("aux") || n.contains("bus") || n.contains("verb") || n.contains("delay") }
        var hasTuner: Bool { inserts.contains { PluginMatcher.isTuner($0.name) } }
    }
    let name: String
    let tracks: [Track]

    enum ImportError: LocalizedError {
        case unreadable, unsupported, nothingFound
        var errorDescription: String? {
            switch self {
            case .unreadable: return "Couldn't read that file."
            case .unsupported: return "That doesn't look like a Pro Tools session (.ptx / .ptf from Pro Tools 5 or later)."
            case .nothingFound: return "No plug-in inserts were found in that session."
            }
        }
    }

    static func load(_ url: URL) throws -> ProToolsSession {
        guard var d = try? Data(contentsOf: url), d.count > 0x40 else { throw ImportError.unreadable }
        try decrypt(&d)
        let bytes = [UInt8](d)
        let catalogue = readCatalogue(bytes)
        let trackMarks = readTrackNames(bytes)
        guard !catalogue.isEmpty, !trackMarks.isEmpty else { throw ImportError.nothingFound }

        // Every place a catalogued plugin is instantiated (its manufacturer+product 4CCs, byte-reversed).
        var hits: [(offset: Int, entry: CatalogueEntry)] = []
        for entry in catalogue {
            for off in find(entry.instanceKey, in: bytes) { hits.append((off, entry)) }
        }
        hits.sort { $0.offset < $1.offset }

        var order: [String] = []
        var chains: [String: [Insert]] = [:]
        var lastOffset: [String: Int] = [:]
        for (i, hit) in hits.enumerated() {
            guard let track = trackMarks.last(where: { $0.offset < hit.offset })?.name else { continue }
            if chains[track] == nil { order.append(track); chains[track] = [] }
            // The same instance is referenced twice (header + state); fold the pair into one insert.
            if let prev = chains[track]?.last, prev.name == hit.entry.name, hit.offset - (lastOffset[track] ?? 0) < 0x1000 {
                lastOffset[track] = hit.offset
                continue
            }
            let end = i + 1 < hits.count ? min(hits[i + 1].offset, hit.offset + 0x600) : hit.offset + 0x600
            chains[track]?.append(Insert(name: hit.entry.name, manufacturer: hit.entry.manufacturer, product: hit.entry.product,
                                         bundleID: hit.entry.bundleID, preset: presetName(bytes, from: hit.offset, to: end)))
            lastOffset[track] = hit.offset
        }
        let tracks = order.compactMap { n -> Track? in
            guard let ins = chains[n], !ins.isEmpty else { return nil }
            return Track(name: n, inserts: ins)
        }
        guard !tracks.isEmpty else { throw ImportError.nothingFound }
        return ProToolsSession(name: url.deletingPathExtension().lastPathComponent, tracks: tracks)
    }

    // MARK: Decoding

    private static func decrypt(_ d: inout Data) throws {
        let type = d[0x12], value = d[0x13]
        let mul: Int, negative: Bool
        switch type {
        case 0x01: mul = 53; negative = false     // Pro Tools 5–9
        case 0x05: mul = 11; negative = true      // Pro Tools 10 and later
        default: throw ImportError.unsupported
        }
        guard var delta = (0..<256).first(where: { ($0 * mul) & 0xff == Int(value) }) else { throw ImportError.unsupported }
        if negative { delta = (256 - delta) & 0xff }
        let key = (0..<256).map { UInt8(($0 * delta) & 0xff) }
        d.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for i in 0x14..<p.count {
                p[i] ^= key[type == 0x01 ? i & 0xff : (i >> 12) & 0xff]
            }
        }
    }

    private struct CatalogueEntry {
        let name: String, manufacturer: String, product: String, bundleID: String
        let instanceKey: [UInt8]
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> Int {
        guard i + 4 <= b.count else { return -1 }
        return Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24
    }
    private static func printable(_ s: ArraySlice<UInt8>) -> Bool { !s.isEmpty && s.allSatisfy { $0 >= 32 && $0 < 127 } }

    /// Catalogue blocks: 0x1017 type, then <len><name><3 × 4CC> and the bundle id.
    private static func readCatalogue(_ b: [UInt8]) -> [CatalogueEntry] {
        var out: [CatalogueEntry] = []
        var seen = Set<String>()
        var i = 0
        while i < b.count - 24 {
            if b[i] == 0x17, b[i + 1] == 0x10, b[i + 2] == 0x03 {
                let p = i + 3, len = u32(b, p)
                if (1...64).contains(len), p + 4 + len + 12 <= b.count {
                    let nameBytes = b[(p + 4)..<(p + 4 + len)]
                    let ids = Array(b[(p + 4 + len)..<(p + 4 + len + 12)])
                    if printable(nameBytes), printable(ids[...]) {
                        let rev = [ids[0..<4], ids[4..<8], ids[8..<12]].flatMap { $0.reversed() }
                        let name = String(decoding: nameBytes, as: UTF8.self)
                        let mfr = String(decoding: rev[0..<4], as: UTF8.self), prod = String(decoding: rev[4..<8], as: UTF8.self)
                        let window = String(decoding: b[p..<min(b.count, p + 300)].map { $0 >= 32 && $0 < 127 ? $0 : 10 }, as: UTF8.self)
                        let bundle = window.range(of: #"com\.[A-Za-z0-9_.\- ]+"#, options: .regularExpression).map { String(window[$0]) } ?? ""
                        if seen.insert(name + mfr + prod).inserted {
                            out.append(CatalogueEntry(name: name, manufacturer: mfr, product: prod, bundleID: bundle,
                                                      instanceKey: Array(rev[0..<8])))
                        }
                        i = p + 4 + len + 12
                        continue
                    }
                }
            }
            i += 1
        }
        return out
    }

    /// Channel-strip blocks: 5A 09 00 <len> 19 26 <len><track name>.
    private static func readTrackNames(_ b: [UInt8]) -> [(offset: Int, name: String)] {
        var out: [(Int, String)] = []
        var i = 0
        while i < b.count - 16 {
            if b[i] == 0x5A, b[i + 1] == 0x09, b[i + 2] == 0x00, b[i + 7] == 0x19, b[i + 8] == 0x26 {
                let len = u32(b, i + 9)
                if (1...128).contains(len), i + 13 + len <= b.count {
                    let nb = b[(i + 13)..<(i + 13 + len)]
                    if printable(nb) { out.append((i, String(decoding: nb, as: UTF8.self))); i += 13 + len; continue }
                }
            }
            i += 1
        }
        return out
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8]) -> [Int] {
        guard let first = needle.first, needle.count <= hay.count else { return [] }
        var out: [Int] = []
        var i = 0
        let last = hay.count - needle.count
        while i <= last {
            if hay[i] == first {
                var j = 1
                while j < needle.count && hay[i + j] == needle[j] { j += 1 }
                if j == needle.count { out.append(i) }
            }
            i += 1
        }
        return out
    }

    private static func presetName(_ b: [UInt8], from: Int, to: Int) -> String? {
        guard from < to, to <= b.count else { return nil }
        let s = String(decoding: b[from..<to].map { $0 >= 32 && $0 < 127 ? $0 : 32 }, as: UTF8.self)
        guard let r = s.range(of: #"<Preset Name="[^"]*""#, options: .regularExpression) else { return nil }
        let v = s[r].dropFirst(14).dropLast()
        return v.isEmpty ? nil : String(v)
    }
}

/// Finds the Audio Unit on this Mac that matches a Pro Tools insert (AAX ↔ AU), or a stock Apple stand-in.
enum PluginMatcher {
    enum Match {
        case exact(AVAudioUnitComponent)
        case substitute(AVAudioUnitComponent, note: String)
        case missing
        var component: AVAudioUnitComponent? {
            switch self { case .exact(let c), .substitute(let c, _): return c; case .missing: return nil }
        }
    }

    static func isTuner(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["auto-tune", "autotune", "melodyne", "waves tune", "metatune", "graillon", "pitch"].contains { n.contains($0) }
    }

    private static func norm(_ s: String) -> String {
        var n = s.lowercased()
        for junk in ["stereo", "mono", "(m)", "(s)", "aax", "native", "dsp", "hdx", " au"] { n = n.replacingOccurrences(of: junk, with: "") }
        return n.filter { $0.isLetter || $0.isNumber }
    }

    private static func fourCC(_ s: String) -> UInt32 {
        s.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// Avid stock plug-ins only exist as AAX — map them to the closest built-in Apple Audio Unit.
    private static let avidStandIns: [(match: String, appleSubType: String, note: String)] = [
        ("eq3", "nbeq", "Avid EQ3 → Apple N-Band EQ"),
        ("channelstrip", "dcmp", "Avid Channel Strip → Apple Dynamics Processor"),
        ("dyn3compressor", "dcmp", "Avid Dyn3 → Apple Dynamics Processor"),
        ("procompressor", "dcmp", "Avid Pro Compressor → Apple Dynamics Processor"),
        ("deesser", "mcmp", "De-esser → Apple Multiband Compressor"),
        ("dverb", "mrev", "Avid D-Verb → Apple Matrix Reverb"),
        ("reverb", "mrev", "Reverb → Apple Matrix Reverb"),
        ("moddelay", "dely", "Avid Mod Delay → Apple Delay"),
        ("delay", "dely", "Delay → Apple Delay"),
        ("maxim", "lmtr", "Avid Maxim → Apple Peak Limiter"),
        ("limiter", "lmtr", "Limiter → Apple Peak Limiter"),
    ]

    static func match(_ insert: ProToolsSession.Insert, in installed: [AVAudioUnitComponent]) -> Match {
        let mfr = fourCC(insert.manufacturer), want = norm(insert.name)
        let candidates = installed.filter { $0.audioComponentDescription.componentManufacturer == mfr }
        func pick(_ list: [AVAudioUnitComponent]) -> AVAudioUnitComponent? {
            // Prefer the stereo build of shell plugins (Waves ships "Name Mono" / "Name Stereo").
            list.first { $0.name.lowercased().contains("stereo") } ?? list.first
        }
        // 1. Same maker, same product code (many vendors reuse the AAX code as the AU sub-type).
        if let c = pick(candidates.filter { $0.audioComponentDescription.componentSubType == fourCC(insert.product) }) { return .exact(c) }
        // 2. Same maker, same name.
        if let c = pick(candidates.filter { norm($0.name) == want }) { return .exact(c) }
        if let c = pick(candidates.filter { norm($0.name).hasPrefix(want) || want.hasPrefix(norm($0.name)) }) { return .exact(c) }
        // 3. Any maker, same name (vendor codes sometimes differ between AAX and AU).
        if let c = pick(installed.filter { norm($0.name) == want }) { return .exact(c) }
        if want.count >= 5, let c = pick(installed.filter { norm($0.name).hasPrefix(want) }) { return .exact(c) }
        // 4. Stock stand-in.
        if let s = avidStandIns.first(where: { want.contains($0.match) }),
           let c = installed.first(where: { $0.audioComponentDescription.componentManufacturer == fourCC("appl")
                                            && $0.audioComponentDescription.componentSubType == fourCC(s.appleSubType) }) {
            return .substitute(c, note: s.note)
        }
        return .missing
    }
}

/// Sheet: pick a Pro Tools session, choose the vocal track (and its vocal bus), preview the matched chain, import.
struct ProToolsImportSheet: View {
    @EnvironmentObject var audio: AudioEngine
    @EnvironmentObject var store: ShowStore
    @Environment(\.dismiss) private var dismiss
    @State private var session: ProToolsSession?
    @State private var error: String?
    @State private var selected: [UUID] = []        // in chain order
    @State private var replace = true
    @State private var skip: Set<UUID> = []
    @State private var done: String?

    private var chain: [ProToolsSession.Insert] {
        guard let s = session else { return [] }
        return selected.compactMap { id in s.tracks.first { $0.id == id } }.flatMap(\.inserts)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "square.and.arrow.down.on.square").font(.title2).foregroundStyle(.pink)
                VStack(alignment: .leading) {
                    Text("Import vocal chain from Pro Tools").font(.title2.weight(.heavy))
                    Text(session.map { "\($0.name) — \($0.tracks.count) tracks with inserts" } ?? "Choose a .ptx session file")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(session == nil ? "Choose Session…" : "Other Session…") { choose() }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }

            if let s = session {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1 · Tick the vocal track, then its vocal bus (chain runs in tick order)").font(.caption.weight(.bold))
                        List {
                            ForEach(s.tracks) { t in
                                HStack {
                                    Image(systemName: selected.contains(t.id) ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(selected.contains(t.id) ? .pink : .secondary)
                                    if let n = selected.firstIndex(of: t.id) { Text("\(n + 1)").font(.caption.bold()).foregroundStyle(.pink) }
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(t.name).fontWeight(.semibold)
                                        Text(t.inserts.map(\.name).joined(separator: " → ")).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer()
                                    if t.hasTuner { Text("TUNE").font(.caption2.bold()).padding(3).background(Capsule().fill(.pink.opacity(0.3))) }
                                    if t.isMaster { Text("MASTER").font(.caption2.bold()).foregroundStyle(.secondary) }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if let i = selected.firstIndex(of: t.id) { selected.remove(at: i) } else { selected.append(t.id) }
                                }
                            }
                        }
                        .frame(minHeight: 260)
                    }
                    .frame(width: 330)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("2 · Live rack chain").font(.caption.weight(.bold))
                        List {
                            ForEach(chain) { ins in
                                let m = PluginMatcher.match(ins, in: audio.availablePlugins)
                                HStack(alignment: .top) {
                                    Toggle("", isOn: Binding(get: { !skip.contains(ins.id) },
                                                             set: { if $0 { skip.remove(ins.id) } else { skip.insert(ins.id) } }))
                                        .labelsHidden().disabled(m.component == nil)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(ins.name).fontWeight(.semibold)
                                        switch m {
                                        case .exact(let c):
                                            Label("\(c.manufacturerName) · \(c.name)", systemImage: "checkmark.circle.fill")
                                                .font(.caption2).foregroundStyle(.green)
                                        case .substitute(_, let note):
                                            Label(note, systemImage: "arrow.triangle.2.circlepath").font(.caption2).foregroundStyle(.yellow)
                                        case .missing:
                                            Label("Not installed as an Audio Unit on this Mac", systemImage: "xmark.circle.fill")
                                                .font(.caption2).foregroundStyle(.red)
                                        }
                                        if let p = ins.preset { Text("Session preset: “\(p)” — load it from the plugin's preset menu").font(.caption2).foregroundStyle(.secondary) }
                                    }
                                }
                            }
                        }
                        .frame(minHeight: 260)
                    }
                }
                Toggle("Replace the current rack (otherwise add to the end)", isOn: $replace)
                Text("Brings in the plugins and their order. Pro Tools saves knob settings in AAX format, which Audio Units can't read — dial them in, then save a Vocal Preset.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let done { Label(done, systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import \(importable.count) plugin\(importable.count == 1 ? "" : "s")") { apply() }
                    .keyboardShortcut(.defaultAction).tint(.pink).disabled(importable.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 820)
        .onAppear {
            if audio.availablePlugins.isEmpty { audio.refreshPluginList() }
            if session == nil { choose() }
        }
    }

    private var importable: [AVAudioUnitComponent] {
        chain.filter { !skip.contains($0.id) }.compactMap { PluginMatcher.match($0, in: audio.availablePlugins).component }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["ptx", "ptf", "pts"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose a Pro Tools session (.ptx)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let s = try ProToolsSession.load(url)
            session = s; error = nil; done = nil; skip = []
            // Guess: the first tuned vocal track, then the busiest aux (the vocal bus).
            var pick: [UUID] = []
            let vocalWords = ["vox", "vocal", "lead", "voc", "hook", "verse"]
            if let v = s.tracks.first(where: { t in vocalWords.contains { t.name.lowercased().contains($0) } && !t.isAux }) ?? s.tracks.first(where: \.hasTuner) {
                pick.append(v.id)
            }
            if let bus = s.tracks.filter({ $0.isAux && !$0.isMaster }).max(by: { $0.inserts.count < $1.inserts.count }), bus.inserts.count > 1 {
                pick.append(bus.id)
            }
            if pick.isEmpty, let t = s.tracks.filter({ !$0.isMaster }).max(by: { $0.inserts.count < $1.inserts.count }) { pick.append(t.id) }
            selected = pick
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func apply() {
        let comps = importable
        if replace { for slot in store.show.vocalRack.plugins { audio.removePlugin(slot.id) } }
        for c in comps { audio.addPlugin(c) }
        done = "Added \(comps.count) plugin\(comps.count == 1 ? "" : "s") to the live vocal rack."
    }
}
