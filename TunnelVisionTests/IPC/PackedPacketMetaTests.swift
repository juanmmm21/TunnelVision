import Foundation
import XCTest
import Shared

/// Tests del empaquetado de ancho fijo (M5): round-trip `PacketMeta` ↔ `PackedPacketMeta` para v4/v6
/// y todos los protocolos, layout byte-a-byte little-endian byte-exacto, y round-trip de bytes.
final class PackedPacketMetaTests: XCTestCase {

    func testPackedByteCountIsFixed() {
        XCTAssertEqual(PackedPacketMeta.packedByteCount, 64)
    }

    // MARK: - Round-trip contra PacketMeta

    func testRoundTripV4TCP() {
        let source = IPCFixtures.endpoint([10, 0, 0, 2], 51000)
        let destination = IPCFixtures.endpoint([93, 184, 216, 34], 443)
        let meta = IPCFixtures.meta(
            timestamp: 123_456_789,
            proto: .tcp,
            source: source,
            destination: destination,
            direction: .outbound,
            length: 1500,
            tcpFlags: [.syn, .ack],
            capture: CaptureLocation(fileSequence: 3, recordOffset: 4096)
        )
        XCTAssertEqual(PackedPacketMeta(meta).toPacketMeta(), meta)
    }

    func testRoundTripV6UDP() {
        let source = IPCFixtures.endpoint(Array(0..<16).map { UInt8($0) }, 5353)
        let destination = IPCFixtures.endpoint(Array(16..<32).map { UInt8($0) }, 53)
        let meta = IPCFixtures.meta(
            timestamp: 999,
            proto: .udp,
            source: source,
            destination: destination,
            direction: .inbound,
            length: 88,
            capture: nil
        )
        XCTAssertEqual(PackedPacketMeta(meta).toPacketMeta(), meta)
    }

    func testRoundTripPreservesEveryProtocol() {
        let source = IPCFixtures.endpoint([172, 16, 0, 1], 1000)
        let destination = IPCFixtures.endpoint([172, 16, 0, 9], 2000)
        for proto in [IPProtocolNumber.tcp, .udp, .icmp, .icmpv6, .other] {
            let meta = IPCFixtures.meta(
                timestamp: 7,
                proto: proto,
                source: source,
                destination: destination,
                direction: .outbound,
                length: 40,
                capture: CaptureLocation(fileSequence: 0, recordOffset: 512)
            )
            XCTAssertEqual(PackedPacketMeta(meta).toPacketMeta(), meta, "proto \(proto) no hizo round-trip")
        }
    }

    // MARK: - Layout binario byte-a-byte

    func testEncodeProducesFixedLittleEndianLayout() {
        let meta = PackedPacketMeta(
            timestamp: 0x0102_0304_0506_0708,
            protoAndDirection: 0x24,
            ipVersion: 6,
            tcpFlags: 0x18,
            portA: 0x1122,
            portB: 0x3344,
            addrA: (0..<16).map { UInt8($0) },
            addrB: (0..<16).map { UInt8(0xF0 + $0) },
            length: 0xAABB_CCDD,
            capture: CaptureLocation(fileSequence: 0x2122_2324, recordOffset: 0x1112_1314_1516_1718)
        )

        var buffer = [UInt8](repeating: 0xEE, count: PackedPacketMeta.packedByteCount)
        buffer.withUnsafeMutableBytes { meta.encode(into: $0.baseAddress!) }

        XCTAssertEqual(Array(buffer[0..<8]), [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01])
        XCTAssertEqual(buffer[8], 0x24)
        XCTAssertEqual(buffer[9], 6)
        XCTAssertEqual(buffer[10], 0x18)
        XCTAssertEqual(buffer[11], 0)                                   // byte reservado, siempre 0
        XCTAssertEqual(Array(buffer[12..<14]), [0x22, 0x11])
        XCTAssertEqual(Array(buffer[14..<16]), [0x44, 0x33])
        XCTAssertEqual(Array(buffer[16..<32]), (0..<16).map { UInt8($0) })
        XCTAssertEqual(Array(buffer[32..<48]), (0..<16).map { UInt8(0xF0 + $0) })
        XCTAssertEqual(Array(buffer[48..<52]), [0xDD, 0xCC, 0xBB, 0xAA])
        XCTAssertEqual(Array(buffer[52..<60]), [0x18, 0x17, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11])
        XCTAssertEqual(Array(buffer[60..<64]), [0x24, 0x23, 0x22, 0x21])

        let decoded = buffer.withUnsafeBytes { PackedPacketMeta(from: $0.baseAddress!) }
        XCTAssertEqual(decoded, meta)
    }

    /// El centinela de "sin captura" es el offset, no el fichero: un registro con offset 0 se lee
    /// sin localización aunque el hueco del fichero traiga basura, porque un `.pcap` no puede tener
    /// un registro delante de su cabecera global.
    func testAZeroOffsetMeansNoCaptureWhateverTheFileFieldSays() {
        var buffer = [UInt8](repeating: 0, count: PackedPacketMeta.packedByteCount)
        buffer[9] = 4                                        // ipVersion, para que decodifique algo válido
        buffer[60] = 0x07                                    // secuencia de fichero distinta de 0
        let decoded = buffer.withUnsafeBytes { PackedPacketMeta(from: $0.baseAddress!) }

        XCTAssertNil(decoded.capture)
        XCTAssertNil(decoded.toPacketMeta().capture)
    }

    /// Y al revés: un registro sin captura no escribe secuencia, así que el hueco queda a 0 y el
    /// round-trip por bytes lo devuelve igual de vacío.
    func testNoCaptureEncodesZeroesAndSurvivesTheByteRoundTrip() {
        let meta = IPCFixtures.meta(
            timestamp: 1,
            proto: .udp,
            source: IPCFixtures.endpoint([10, 0, 0, 2], 5353),
            destination: IPCFixtures.endpoint([224, 0, 0, 251], 5353),
            direction: .outbound,
            length: 60,
            capture: nil
        )
        var buffer = [UInt8](repeating: 0xEE, count: PackedPacketMeta.packedByteCount)
        buffer.withUnsafeMutableBytes { PackedPacketMeta(meta).encode(into: $0.baseAddress!) }

        XCTAssertEqual(Array(buffer[52..<64]), [UInt8](repeating: 0, count: 12))
        let decoded = buffer.withUnsafeBytes { PackedPacketMeta(from: $0.baseAddress!) }
        XCTAssertEqual(decoded.toPacketMeta(), meta)
    }
}
