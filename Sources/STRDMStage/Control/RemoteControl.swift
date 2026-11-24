import Foundation
import CoreMIDI
import Network

// MARK: - MIDI

/// Listens to every MIDI input (footswitches, pads, Stream Deck via MIDI, a drummer's SPD-SX…)
/// and maps notes / CCs / program changes to show actions. Supports MIDI learn.
@MainActor
final class MIDIControl: ObservableObject {
    @Published private(set) var sourceNames: [String] = []
    @Published private(set) var lastMessage = "—"
    @Published var learning: ControlAction? = nil

    var onAction: ((ControlAction) -> Void)?
    /// Every incoming channel message (the Studio plays/records notes from controllers).
    var onMessage: ((UInt8, UInt8, UInt8) -> Void)?

    private let store: ShowStore
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var connected: [MIDIEndpointRef] = []

    init(store: ShowStore) {
        self.store = store
        let status = MIDIClientCreateWithBlock("STRDM Stage" as CFString, &client) { @Sendable [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged {
                Task { @MainActor in self?.connectSources() }
            }
        }
        guard status == noErr else { lastMessage = "MIDI unavailable (\(status))"; return }
        MIDIInputPortCreateWithProtocol(client, "STRDM Input" as CFString, ._1_0, &port) { @Sendable [weak self] list, _ in
            let messages = MIDIControl.parse(list)
            guard !messages.isEmpty else { return }
            Task { @MainActor in messages.forEach { self?.handle($0) } }
        }
        connectSources()
    }

    func connectSources() {
        for src in connected { MIDIPortDisconnectSource(port, src) }
        connected.removeAll()
        var names: [String] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            if MIDIPortConnectSource(port, src, nil) == noErr {
                connected.append(src)
                names.append(Self.name(of: src))
            }
        }
        sourceNames = names
    }

    private static func name(of endpoint: MIDIEndpointRef) -> String {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &value) == noErr, let value else { return "MIDI source" }
        return value.takeRetainedValue() as String
    }

    struct Message: Sendable {
        let status: UInt8
        let data1: UInt8
        let data2: UInt8
    }

    /// Decodes MIDI 1.0 channel-voice messages out of a Universal MIDI Packet event list.
    nonisolated static func parse(_ list: UnsafePointer<MIDIEventList>) -> [Message] {
        var out: [Message] = []
        for packetPtr in list.unsafeSequence() {
            var packet = packetPtr.pointee
            let count = min(Int(packet.wordCount), 64)
            withUnsafeBytes(of: &packet.words) { raw in
                let words = raw.bindMemory(to: UInt32.self)
                var i = 0
                while i < count {
                    let w = words[i]
                    let type = w >> 28
                    if type == 0x2 {
                        out.append(Message(status: UInt8((w >> 16) & 0xFF),
                                           data1: UInt8((w >> 8) & 0x7F),
                                           data2: UInt8(w & 0x7F)))
                    }
                    switch type {
                    case 0x3, 0x4: i += 2
                    case 0x5: i += 4
                    default: i += 1
                    }
                }
            }
        }
        return out
    }

    private func handle(_ m: Message) {
        onMessage?(m.status, m.data1, m.data2)
        let kindBits = m.status & 0xF0
        let channel = Int(m.status & 0x0F)
        let kind: MIDIMapping.Kind
        let number: Int
        switch kindBits {
        case 0x90 where m.data2 > 0:
            kind = .note; number = Int(m.data1)
        case 0xB0 where m.data2 >= 64:
            kind = .cc; number = Int(m.data1)
        case 0xC0:
            kind = .program; number = Int(m.data1)
        default:
            return
        }
        let description = MIDIMapping(action: .go, kind: kind, channel: channel, number: number).description
        lastMessage = description

        if let action = learning {
            store.show.control.midiMappings.removeAll { $0.action == action }
            store.show.control.midiMappings.append(MIDIMapping(action: action, kind: kind, channel: channel, number: number))
            learning = nil
            return
        }
        guard store.show.control.midiEnabled else { return }
        for map in store.show.control.midiMappings
        where map.kind == kind && map.number == number && (map.channel < 0 || map.channel == channel) {
            onAction?(map.action)
        }
    }
}

// MARK: - OSC

/// UDP OSC server. Works with Bitfocus Companion (Stream Deck), TouchOSC, QLab network cues, Ableton via Max, etc.
///
///   /go  /stop  /panic  /standby/next  /standby/prev  /blackout  /vocal/bypass
///   /cue/{number}/start   (or /cue/{number}/go)
///   /lights/gm  <float 0–1>
@MainActor
final class OSCControl: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var lastMessage = "—"
    @Published private(set) var error: String? = nil

    var onMessage: ((String, [Any]) -> Void)?
    private var listener: NWListener?

    func start(port: UInt16) {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { error = "Invalid port"; return }
        do {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: nwPort)
            listener.newConnectionHandler = { @Sendable [weak self] connection in
                connection.start(queue: .global(qos: .userInteractive))
                OSCControl.receive(on: connection) { address, args in
                    Task { @MainActor in self?.received(address, args) }
                }
            }
            listener.stateUpdateHandler = { @Sendable [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: self?.isListening = true; self?.error = nil
                    case .failed(let e): self?.isListening = false; self?.error = e.localizedDescription
                    case .cancelled: self?.isListening = false
                    default: break
                    }
                }
            }
            listener.start(queue: .global(qos: .userInteractive))
            self.listener = listener
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isListening = false
    }

    private func received(_ address: String, _ args: [Any]) {
        lastMessage = args.isEmpty ? address : "\(address) \(args.map { "\($0)" }.joined(separator: " "))"
        onMessage?(address, args)
    }

    nonisolated private static func receive(on connection: NWConnection,
                                            handler: @escaping @Sendable (String, [Any]) -> Void) {
        connection.receiveMessage { data, _, _, error in
            if let data {
                for (address, args) in OSCControl.parse(data) { handler(address, args) }
            }
            if error == nil { OSCControl.receive(on: connection, handler: handler) }
        }
    }

    // MARK: OSC decoding (messages + bundles, int/float/string args)

    nonisolated static func parse(_ data: Data) -> [(String, [Any])] {
        let bytes = [UInt8](data)
        if bytes.starts(with: Array("#bundle".utf8)) {
            var results: [(String, [Any])] = []
            var i = 16   // "#bundle\0" + 8-byte timetag
            while i + 4 <= bytes.count {
                let size = Int(readInt32(bytes, i))
                i += 4
                guard size > 0, i + size <= bytes.count else { break }
                results += OSCControl.parse(Data(bytes[i..<(i + size)]))
                i += size
            }
            return results
        }
        var i = 0
        guard let address = readString(bytes, &i), address.hasPrefix("/") else { return [] }
        var args: [Any] = []
        if i < bytes.count, let tags = readString(bytes, &i), tags.hasPrefix(",") {
            for tag in tags.dropFirst() {
                switch tag {
                case "i":
                    guard i + 4 <= bytes.count else { break }
                    args.append(Int(readInt32(bytes, i))); i += 4
                case "f":
                    guard i + 4 <= bytes.count else { break }
                    args.append(Float(bitPattern: UInt32(bitPattern: readInt32(bytes, i)))); i += 4
                case "s":
                    if let s = readString(bytes, &i) { args.append(s) }
                case "T": args.append(true)
                case "F": args.append(false)
                default: break
                }
            }
        }
        return [(address, args)]
    }

    nonisolated private static func readInt32(_ b: [UInt8], _ i: Int) -> Int32 {
        Int32(bitPattern: UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]))
    }

    nonisolated private static func readString(_ b: [UInt8], _ i: inout Int) -> String? {
        guard i < b.count, let end = b[i...].firstIndex(of: 0) else { return nil }
        let s = String(decoding: b[i..<end], as: UTF8.self)
        i = (end + 4) & ~3   // skip null terminator + padding to 4 bytes
        return s
    }
}
