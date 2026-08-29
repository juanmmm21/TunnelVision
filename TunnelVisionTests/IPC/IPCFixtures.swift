import Foundation
import Shared

/// Constructores para los tests de M5: endpoints/`PacketMeta` sintéticos y un `PackedPacketMeta`
/// cuyos campos derivan todos de un mismo `i`, para poder detectar lecturas a medias (torn reads).
enum IPCFixtures {

    static func endpoint(_ bytes: [UInt8], _ port: UInt16) -> IPEndpoint {
        let version: IPVersion = bytes.count == 4 ? .v4 : .v6
        return IPEndpoint(address: IPAddress(version: version, bytes: bytes), port: port)
    }

    static func meta(
        timestamp: UInt64,
        proto: IPProtocolNumber,
        source: IPEndpoint,
        destination: IPEndpoint,
        direction: Direction,
        length: UInt32,
        tcpFlags: TCPFlags = [],
        capture: CaptureLocation?
    ) -> PacketMeta {
        PacketMeta(
            timestamp: timestamp,
            flowKey: FlowKey(proto: proto, source: source, destination: destination),
            direction: direction,
            length: length,
            tcpFlags: tcpFlags,
            capture: capture
        )
    }

    /// Localización de captura derivada de `i`, para usar `i` como discriminador de registro. El
    /// `+ 24` la aparta del 0, que es el centinela de "sin captura" y por tanto no la sobrevive.
    static func location(_ i: UInt64) -> CaptureLocation {
        CaptureLocation(fileSequence: UInt32(truncatingIfNeeded: i), recordOffset: i &+ 24)
    }

    /// Registro sintético con **todos** los campos derivados de `i`. Un registro íntegro cumple
    /// `timestamp == recordOffset - 24`, `portA == low16(i)`, `length == low32(i)` y
    /// `addrA[0] == low8(i)`; una lectura a medias (mezcla de dos registros) rompe alguna de ellas.
    static func packed(_ i: UInt64) -> PackedPacketMeta {
        var addrA = [UInt8](repeating: 0, count: 16)
        var addrB = [UInt8](repeating: 0, count: 16)
        for k in 0..<8 { addrA[k] = UInt8(truncatingIfNeeded: i >> (8 * k)) }
        for k in 0..<8 { addrB[k] = UInt8(truncatingIfNeeded: (i &* 2_654_435_761) >> (8 * k)) }
        return PackedPacketMeta(
            timestamp: i,
            protoAndDirection: 0x01,          // proto tcp (código 0) en nibble alto, inbound (1) en el bajo
            ipVersion: 4,
            tcpFlags: UInt8(truncatingIfNeeded: i),
            portA: UInt16(truncatingIfNeeded: i),
            portB: UInt16(truncatingIfNeeded: i >> 16),
            addrA: addrA,
            addrB: addrB,
            length: UInt32(truncatingIfNeeded: i),
            capture: location(i)
        )
    }

    /// `true` si el registro conserva las invariantes de `packed(_:)` (no hubo torn read).
    static func isIntact(_ r: PackedPacketMeta) -> Bool {
        r.capture == location(r.timestamp)
            && r.portA == UInt16(truncatingIfNeeded: r.timestamp)
            && r.length == UInt32(truncatingIfNeeded: r.timestamp)
            && r.addrA[0] == UInt8(truncatingIfNeeded: r.timestamp)
    }

    static func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ipc-tests-\(UUID().uuidString).bin")
    }
}
