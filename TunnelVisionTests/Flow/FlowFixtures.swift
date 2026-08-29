import Foundation
import Shared

/// Constructores para los tests de M4: `ParsedPacket` sintéticos y un reloj monotónico manual.
enum FlowFixtures {

    static let localV4: [UInt8] = [10, 0, 0, 2]
    static let remoteV4: [UInt8] = [93, 184, 216, 34]

    static func endpoint(_ bytes: [UInt8], _ port: UInt16) -> IPEndpoint {
        let version: IPVersion = bytes.count == 4 ? .v4 : .v6
        return IPEndpoint(address: IPAddress(version: version, bytes: bytes), port: port)
    }

    /// `ParsedPacket` TCP mínimo pero coherente: `flowKey` canónico a partir de (source, destination),
    /// cabeceras rellenadas con valores plausibles. `length` es el total del datagrama IP.
    static func tcp(
        source: IPEndpoint,
        destination: IPEndpoint,
        flags: TCPFlags = [],
        sequence: UInt32 = 0,
        length: Int = 60
    ) -> ParsedPacket {
        let ip = IPHeader(
            version: source.address.version,
            source: source.address,
            destination: destination.address,
            proto: .tcp,
            rawProtocol: 6,
            payloadRange: 20..<length,
            totalLength: length
        )
        let tcp = TCPHeader(
            sourcePort: source.port,
            destinationPort: destination.port,
            sequence: sequence,
            acknowledgment: 0,
            flags: flags,
            windowSize: 65535,
            dataOffsetBytes: 20,
            payloadRange: 40..<length
        )
        let key = FlowKey(proto: .tcp, source: source, destination: destination)
        return ParsedPacket(ip: ip, tcp: tcp, udp: nil, flowKey: key, source: source, destination: destination)
    }

    static func udp(source: IPEndpoint, destination: IPEndpoint, length: Int = 40) -> ParsedPacket {
        let ip = IPHeader(
            version: source.address.version,
            source: source.address,
            destination: destination.address,
            proto: .udp,
            rawProtocol: 17,
            payloadRange: 20..<length,
            totalLength: length
        )
        let udp = UDPHeader(
            sourcePort: source.port,
            destinationPort: destination.port,
            length: UInt16(length - 20),
            payloadRange: 28..<length
        )
        let key = FlowKey(proto: .udp, source: source, destination: destination)
        return ParsedPacket(ip: ip, tcp: nil, udp: udp, flowKey: key, source: source, destination: destination)
    }
}

/// Reloj monotónico controlable para tests deterministas del `FlowTable`. El lock justifica el
/// `@unchecked Sendable`: el actor lo consulta desde su aislamiento, los tests lo avanzan desde otro.
final class ManualClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    init(_ start: UInt64 = 0) {
        self.value = start
    }

    func now() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: UInt64) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func advance(by delta: UInt64) {
        lock.lock()
        value &+= delta
        lock.unlock()
    }
}
