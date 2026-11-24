import Foundation
import Darwin

/// Minimal UDP sender (BSD socket) with broadcast + multicast enabled — what Art-Net and sACN need.
final class UDPSender {
    private var fd: Int32

    init() {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if fd >= 0 {
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
            var ttl: UInt8 = 8
            setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        }
    }

    deinit {
        if fd >= 0 { Darwin.close(fd) }
    }

    @discardableResult
    func send(_ bytes: [UInt8], to host: String, port: UInt16) -> Bool {
        guard fd >= 0 else { return false }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }
        let sent = bytes.withUnsafeBytes { buffer -> Int in
            withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, buffer.baseAddress, buffer.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent >= 0
    }
}

/// Builds and sends Art-Net (ArtDmx) and sACN (ANSI E1.31) packets on a background queue.
final class DMXOutput {
    private let sender = UDPSender()
    private let queue = DispatchQueue(label: "strdm.dmx.output", qos: .userInteractive)
    private var sequences: [Int: UInt8] = [:]
    private let cid: [UInt8]
    private let sourceName = "STRDM Stage"

    init() {
        // Stable per-install component id for sACN.
        let key = "STRDMStage.sACN.CID"
        let uuid: UUID
        if let s = UserDefaults.standard.string(forKey: key), let u = UUID(uuidString: s) {
            uuid = u
        } else {
            uuid = UUID()
            UserDefaults.standard.set(uuid.uuidString, forKey: key)
        }
        let u = uuid.uuid
        cid = [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
    }

    /// `universes` maps zero-based universe index → 512 slot values.
    func send(universes: [Int: [UInt8]], setup: LightingSetup) {
        let proto = setup.dmxProtocol
        let artNetHost = setup.artNetDestination
        let unicast = setup.sACNUnicast.trimmingCharacters(in: .whitespaces)
        queue.async { [self] in
            for (universe, data) in universes {
                let seq = nextSequence(universe)
                switch proto {
                case .artNet:
                    let packet = Self.artDmx(universe: universe, sequence: seq, data: data)
                    sender.send(packet, to: artNetHost, port: 6454)
                case .sACN:
                    let wireUniverse = universe + 1
                    let packet = Self.e131(universe: wireUniverse, sequence: seq, data: data, cid: cid, source: sourceName)
                    let host = unicast.isEmpty
                        ? "239.255.\((wireUniverse >> 8) & 0xFF).\(wireUniverse & 0xFF)"
                        : unicast
                    sender.send(packet, to: host, port: 5568)
                }
            }
        }
    }

    private func nextSequence(_ universe: Int) -> UInt8 {
        var s = (sequences[universe] ?? 0) &+ 1
        if s == 0 { s = 1 }   // Art-Net: 0 disables sequencing
        sequences[universe] = s
        return s
    }

    // MARK: Packet builders

    static func artDmx(universe: Int, sequence: UInt8, data: [UInt8]) -> [UInt8] {
        var p = [UInt8]()
        p.reserveCapacity(18 + 512)
        p += Array("Art-Net".utf8) + [0]
        p += [0x00, 0x50]                     // OpDmx (0x5000), little-endian
        p += [0x00, 14]                       // protocol version 14
        p += [sequence, 0]                    // sequence, physical
        p += [UInt8(universe & 0xFF),         // SubUni
              UInt8((universe >> 8) & 0x7F)]  // Net
        p += [0x02, 0x00]                     // length 512, big-endian
        p += padded(data)
        return p
    }

    static func e131(universe: Int, sequence: UInt8, data: [UInt8], cid: [UInt8], source: String) -> [UInt8] {
        let slots = padded(data)
        var p = [UInt8]()
        p.reserveCapacity(638)
        // Root layer
        p += [0x00, 0x10, 0x00, 0x00]
        p += [0x41, 0x53, 0x43, 0x2d, 0x45, 0x31, 0x2e, 0x31, 0x37, 0x00, 0x00, 0x00]
        p += be16(0x7000 | (638 - 16))
        p += [0x00, 0x00, 0x00, 0x04]
        p += cid
        // Framing layer
        p += be16(0x7000 | (638 - 38))
        p += [0x00, 0x00, 0x00, 0x02]
        var name = Array(source.utf8.prefix(63))
        name += [UInt8](repeating: 0, count: 64 - name.count)
        p += name
        p += [100]                 // priority
        p += [0x00, 0x00]          // sync address
        p += [sequence]
        p += [0x00]                // options
        p += be16(universe)
        // DMP layer
        p += be16(0x7000 | (638 - 115))
        p += [0x02, 0xa1, 0x00, 0x00, 0x00, 0x01]
        p += be16(513)
        p += [0x00]                // start code
        p += slots
        return p
    }

    private static func padded(_ data: [UInt8]) -> [UInt8] {
        if data.count == 512 { return data }
        if data.count > 512 { return Array(data.prefix(512)) }
        return data + [UInt8](repeating: 0, count: 512 - data.count)
    }

    private static func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
}
