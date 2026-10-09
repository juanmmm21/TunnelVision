import XCTest
@testable import Shared

/// Tests del formato pcapng, contra bytes escritos a mano y contra un lector que no comparte
/// código con el escritor. Lo que se afirma es lo que Wireshark exige de un bloque —alineado,
/// con su longitud repetida, con las opciones cerradas— y lo que la captura de una sesión
/// necesita de él: el comentario y el sentido de cada paquete.
final class PcapngFormatTests: XCTestCase {

    func testTheSectionHeaderIsTheDocumentedBytes() throws {
        let header = try PcapngFormat.sectionHeader(application: nil)

        XCTAssertEqual([UInt8](header), [
            0x0A, 0x0D, 0x0D, 0x0A,                             // tipo
            0x1C, 0x00, 0x00, 0x00,                             // 28 bytes
            0x4D, 0x3C, 0x2B, 0x1A,                             // marca de orden de bytes
            0x01, 0x00, 0x00, 0x00,                             // versión 1.0
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,     // longitud de sección sin especificar
            0x1C, 0x00, 0x00, 0x00,
        ])
    }

    func testTheSectionHeaderNamesTheApplicationThatWroteIt() throws {
        let decoded = try TestPcapngReader.read(try PcapngFormat.sectionHeader(application: "TunnelVision 1.1 (4)"))

        XCTAssertEqual(decoded.sections.count, 1)
        XCTAssertEqual(decoded.sections[0].byteOrderMagic, 0x1A2B_3C4D)
        XCTAssertEqual(decoded.sections[0].sectionLength, .max)
        XCTAssertEqual(
            decoded.sections[0].options,
            [.init(code: 4, value: Data("TunnelVision 1.1 (4)".utf8))]
        )
    }

    func testTheInterfaceIsRawIPWithItsSnaplenAndMicrosecondTimestamps() throws {
        let block = try PcapngFormat.interfaceDescription(snaplen: 262_144)

        XCTAssertEqual([UInt8](block), [
            0x01, 0x00, 0x00, 0x00,
            0x20, 0x00, 0x00, 0x00,                             // 32 bytes
            0x65, 0x00, 0x00, 0x00,                             // LINKTYPE_RAW (101) y reservado
            0x00, 0x00, 0x04, 0x00,                             // snaplen
            0x09, 0x00, 0x01, 0x00, 0x06, 0x00, 0x00, 0x00,     // if_tsresol = 10⁻⁶, con relleno
            0x00, 0x00, 0x00, 0x00,                             // opt_endofopt
            0x20, 0x00, 0x00, 0x00,
        ])
    }

    func testAPacketCarriesItsBytesItsLengthsAndItsInstant() throws {
        let bytes = Data([0x45, 0x00, 0x00, 0x05, 0xAA])
        // Por encima de 2³²: el instante va partido en dos mitades de 32 bits, la alta primero.
        let instant: UInt64 = 1_700_000_000_123_456
        let block = try PcapngFormat.enhancedPacket(
            timestampMicroseconds: instant, originalLength: 1_500, bytes: bytes, direction: nil, comment: nil
        )

        let packet = try XCTUnwrap(try TestPcapngReader.read(block).packets.first)
        XCTAssertEqual(packet.interfaceID, 0)
        XCTAssertEqual(packet.timestamp, instant)
        XCTAssertEqual(packet.capturedLength, 5)
        XCTAssertEqual(packet.originalLength, 1_500)
        XCTAssertEqual(packet.data, bytes)
        // Sin sentido ni comentario no hay lista de opciones, ni siquiera su final.
        XCTAssertEqual(packet.options, [])
        XCTAssertEqual(block.count, 12 + 20 + 8)
    }

    func testAPacketOfAnyLengthIsPaddedToThirtyTwoBits() throws {
        for length in 0...9 {
            let bytes = Data((0..<length).map { UInt8($0 + 1) })
            let comment = String(repeating: "c", count: length + 1)
            let block = try PcapngFormat.enhancedPacket(
                timestampMicroseconds: 1, originalLength: UInt32(length), bytes: bytes,
                direction: .outbound, comment: comment
            )

            XCTAssertEqual(block.count % 4, 0, "longitud \(length)")
            let packet = try XCTUnwrap(try TestPcapngReader.read(block).packets.first, "longitud \(length)")
            XCTAssertEqual(packet.data, bytes, "el relleno no entra en los datos (longitud \(length))")
            XCTAssertEqual(packet.comment, comment)
            XCTAssertEqual(packet.directionBits, 2)
        }
    }

    func testThePacketCommentIsUTF8AndItsLengthLeavesThePaddingOut() throws {
        let block = try PcapngFormat.enhancedPacket(
            timestampMicroseconds: 1, originalLength: 1, bytes: Data([0x45]), direction: nil, comment: "flow=12 ñ"
        )

        let packet = try XCTUnwrap(try TestPcapngReader.read(block).packets.first)
        XCTAssertEqual(packet.options, [.init(code: 1, value: Data("flow=12 ñ".utf8))])
        XCTAssertEqual(packet.comment, "flow=12 ñ")
    }

    func testThePacketFlagsSayWhichWayItTravelled() throws {
        let expected: [(Direction, UInt32)] = [(.inbound, 1), (.outbound, 2)]
        for (direction, bits) in expected {
            let block = try PcapngFormat.enhancedPacket(
                timestampMicroseconds: 1, originalLength: 1, bytes: Data([0x45]), direction: direction, comment: nil
            )
            let packet = try XCTUnwrap(try TestPcapngReader.read(block).packets.first)
            XCTAssertEqual(packet.directionBits, bits)
        }
    }

    func testAnOptionThatDoesNotFitItsLengthIsRefused() {
        XCTAssertThrowsError(try PcapngFormat.enhancedPacket(
            timestampMicroseconds: 1, originalLength: 1, bytes: Data([0x45]), direction: nil,
            comment: String(repeating: "x", count: 65_536)
        )) { error in
            XCTAssertEqual(error as? PcapngFormat.FormatError, .optionTooLong(code: 1, byteCount: 65_536))
        }
        // El mayor que cabe, cabe.
        XCTAssertNoThrow(try PcapngFormat.enhancedPacket(
            timestampMicroseconds: 1, originalLength: 1, bytes: Data([0x45]), direction: nil,
            comment: String(repeating: "x", count: 65_535)
        ))
    }

    func testBlocksWrittenOneAfterAnotherReadBackAsOneFile() throws {
        var file = try PcapngFormat.sectionHeader(application: "TunnelVision")
        file.append(try PcapngFormat.interfaceDescription(snaplen: 64))
        for index in 0..<3 {
            file.append(try PcapngFormat.enhancedPacket(
                timestampMicroseconds: UInt64(index), originalLength: 3, bytes: Data([1, 2, UInt8(index)]),
                direction: .inbound, comment: "flow=\(index)"
            ))
        }

        let decoded = try TestPcapngReader.read(file)
        XCTAssertEqual(decoded.blockTypes, [0x0A0D_0D0A, 1, 6, 6, 6])
        XCTAssertEqual(
            decoded.interfaces,
            [.init(linkType: 101, snaplen: 64, options: [.init(code: 9, value: Data([6]))])]
        )
        XCTAssertEqual(decoded.packets.map(\.comment), ["flow=0", "flow=1", "flow=2"])
        XCTAssertEqual(decoded.packets.map(\.timestamp), [0, 1, 2])
    }
}
