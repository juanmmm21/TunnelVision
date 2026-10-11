import Foundation
import XCTest
import Shared

/// Tests del recorrido de los frames de un Initial. Lo que se afirma: que el CRYPTO se encuentra
/// **vaya detrás de lo que vaya** de lo que cabe en un Initial, que lo que no cabe corta ese
/// paquete conservando lo leído, y que ninguna longitud que elija el otro extremo hace leer fuera
/// del payload.
final class QUICInitialFramesTests: XCTestCase {

    private let hello: [UInt8] = Array("un trozo de handshake".utf8)

    private func frames(_ bytes: [UInt8]) -> QUICInitialFrames {
        QUICInitialFrames(payload: Data(bytes))
    }

    private func crypto(_ offset: UInt64, _ data: [UInt8]) -> QUICCryptoFrame {
        QUICCryptoFrame(offset: offset, data: Data(data))
    }

    // MARK: - El frame de las RFC

    /// RFC 9001 § A.2: el payload del Initial de ejemplo es un CRYPTO en el desplazamiento 0 con
    /// los 241 bytes del ClientHello, y relleno hasta 1162 bytes.
    func testReadsTheCryptoFrameOfTheRFCSamplePayload() {
        let frame = QUICRFCVectors.cryptoFrame
        let payload = frame + [UInt8](repeating: 0, count: QUICRFCVectors.payloadLength - frame.count)

        let read = frames(payload)
        XCTAssertNil(read.stop)
        // 06 · offset 00 · longitud 40f1 (241) · el mensaje, que empieza por 01 0000ed.
        XCTAssertEqual(read.crypto, [crypto(0, Array(frame.dropFirst(4)))])
        XCTAssertEqual(read.crypto.first?.data.count, 241)
        XCTAssertEqual(read.crypto.first?.data.prefix(4), Data([0x01, 0x00, 0x00, 0xed]))
    }

    /// De punta a punta con 10a: el Initial protegido de la RFC, abierto, da ese mismo frame.
    func testReadsTheCryptoFrameOutOfTheOpenedRFCInitials() throws {
        for (version, bytes) in [(QUICVersion.v1, QUICRFCVectors.clientInitialV1), (.v2, QUICRFCVectors.clientInitialV2)] {
            let datagram = Data(bytes)
            let keys = try XCTUnwrap(QUICInitialKeys(
                version: version, clientDestinationConnectionID: Data(QUICRFCVectors.destinationConnectionID)
            ))
            let packet = try QUICInitialPacket(
                datagram: datagram, header: QUICInitialHeader(datagram: datagram), keys: keys, largestPacketNumber: nil
            )
            let read = QUICInitialFrames(payload: packet.frames)
            XCTAssertNil(read.stop, "\(version)")
            XCTAssertEqual(read.crypto, [crypto(0, Array(QUICRFCVectors.cryptoFrame.dropFirst(4)))], "\(version)")
        }
    }

    // MARK: - Lo que se salta

    func testAnEmptyPayloadHasNoFramesAndDoesNotStop() {
        let read = frames([])
        XCTAssertEqual(read.crypto, [])
        XCTAssertNil(read.stop)
    }

    func testAPayloadOfPaddingAndPingsHasNoCryptoFrames() {
        let read = frames([0x00, 0x00, 0x01, 0x00, 0x01, 0x01] + [UInt8](repeating: 0, count: 1_100))
        XCTAssertEqual(read.crypto, [])
        XCTAssertNil(read.stop)
    }

    func testFindsCryptoBehindPaddingAndPing() {
        let payload = [UInt8](repeating: 0, count: 900) + [0x01] + QUICFixtures.cryptoFrame(offset: 7, data: hello) + [0x00, 0x01]
        let read = frames(payload)
        XCTAssertEqual(read.crypto, [crypto(7, hello)])
        XCTAssertNil(read.stop)
    }

    /// El Initial que retransmite un ClientHello suele llevar delante el ACK del Initial del
    /// servidor: hay que saber cuánto mide para llegar al CRYPTO.
    func testFindsCryptoBehindAnACKWithoutRanges() {
        let payload = QUICFixtures.ackFrame(largest: 0, delay: 300) + QUICFixtures.cryptoFrame(offset: 0, data: hello)
        let read = frames(payload)
        XCTAssertEqual(read.crypto, [crypto(0, hello)])
        XCTAssertNil(read.stop)
    }

    func testFindsCryptoBehindAnACKWithRanges() {
        // Valores de uno y de dos bytes mezclados: cada campo es un varint y mide lo que mide.
        let ack = QUICFixtures.ackFrame(
            largest: 9_000, delay: 70, firstRange: 2, ranges: [(gap: 1, length: 300), (gap: 64, length: 0), (gap: 0, length: 5)]
        )
        let read = frames(ack + QUICFixtures.cryptoFrame(offset: 100, data: hello))
        XCTAssertEqual(read.crypto, [crypto(100, hello)])
        XCTAssertNil(read.stop)
    }

    /// El ACK de tipo 0x03 lleva tres contadores de ECN detrás de los rangos; el 0x02, no. Si se
    /// confunden, el CRYPTO de detrás se lee tres varints antes o después de donde está.
    func testFindsCryptoBehindAnACKWithECNCounts() {
        let ack = QUICFixtures.ackFrame(largest: 3, ranges: [(gap: 0, length: 0)], ecnCounts: [1, 200, 0])
        let read = frames(ack + QUICFixtures.cryptoFrame(offset: 0, data: hello))
        XCTAssertEqual(read.crypto, [crypto(0, hello)])
        XCTAssertNil(read.stop)
    }

    func testFindsCryptoBehindAConnectionClose() {
        let close = QUICFixtures.connectionCloseFrame(errorCode: 0x0a, frameType: 0x06, reason: "handshake abandoned")
        let read = frames(close + QUICFixtures.cryptoFrame(offset: 0, data: hello))
        XCTAssertEqual(read.crypto, [crypto(0, hello)])
        XCTAssertNil(read.stop)
    }

    func testFindsCryptoBehindAConnectionCloseWithoutAReason() {
        let read = frames(QUICFixtures.connectionCloseFrame(errorCode: 0) + QUICFixtures.cryptoFrame(offset: 0, data: hello))
        XCTAssertEqual(read.crypto, [crypto(0, hello)])
        XCTAssertNil(read.stop)
    }

    // MARK: - Varios CRYPTO

    /// Salen en el orden en que viajan, no en el de sus desplazamientos: ordenarlos es del stream.
    func testKeepsSeveralCryptoFramesInWireOrder() {
        let first = Array(hello.prefix(5)), second = Array(hello.dropFirst(5))
        let payload = QUICFixtures.cryptoFrame(offset: 5, data: second)
            + [0x00, 0x00, 0x01]
            + QUICFixtures.cryptoFrame(offset: 0, data: first)
            + QUICFixtures.cryptoFrame(offset: 5, data: second)
        XCTAssertEqual(frames(payload).crypto, [crypto(5, second), crypto(0, first), crypto(5, second)])
    }

    func testReadsACryptoFrameWithoutData() {
        let read = frames(QUICFixtures.cryptoFrame(offset: 40, data: []) + QUICFixtures.cryptoFrame(offset: 0, data: hello))
        XCTAssertEqual(read.crypto, [crypto(40, []), crypto(0, hello)])
        XCTAssertNil(read.stop)
    }

    /// El tipo es un varint y aquí se acepta aunque no venga en su forma más corta (§ 12.4 deja
    /// rechazarlo a quien recibe): `4006` y `c0…06` son también un CRYPTO.
    func testAcceptsAFrameTypeInALongerEncoding() {
        let body = QUICFixtures.varint(3) + QUICFixtures.varint(hello.count) + hello
        XCTAssertEqual(frames([0x40, 0x06] + body).crypto, [crypto(3, hello)])
        XCTAssertEqual(frames(QUICFixtures.varint8(0x06) + body).crypto, [crypto(3, hello)])
        XCTAssertNil(frames([0x40, 0x00, 0x40, 0x01] + QUICFixtures.cryptoFrame(offset: 3, data: hello)).stop)
    }

    func testReadsAnOffsetInAnEightByteVarint() {
        let offset: UInt64 = 5_000_000_000
        let payload = [0x06] + QUICFixtures.varint8(offset) + QUICFixtures.varint(hello.count) + hello
        XCTAssertEqual(frames(payload).crypto, [crypto(offset, hello)])
    }

    /// El payload llega como un trozo de otro `Data`, con índices que no empiezan en cero.
    func testReadsAPayloadThatIsASliceOfALargerBuffer() {
        let frame = QUICFixtures.cryptoFrame(offset: 2, data: hello)
        let buffer = Data([0xFF, 0xFF, 0xFF] + QUICFixtures.ackFrame(largest: 1) + frame + [0xFF])
        let read = QUICInitialFrames(payload: buffer.dropFirst(3).dropLast(1))
        XCTAssertEqual(read.crypto, [crypto(2, hello)])
        XCTAssertNil(read.stop)
    }

    // MARK: - Lo que corta el paquete

    /// Todo tipo que no sea uno de los cinco que caben en un Initial: los de streams y control de
    /// flujo (0x04, 0x05, 0x07–0x1b), el CONNECTION_CLOSE de la aplicación (0x1d),
    /// HANDSHAKE_DONE (0x1e) y cualquiera sin definir.
    func testStopsAtAnyFrameTypeAnInitialCannotCarryKeepingWhatCameBefore() {
        let allowed: Set<UInt64> = [0x00, 0x01, 0x02, 0x03, 0x06, 0x1c]
        for type in UInt64(0)...0x3f where !allowed.contains(type) {
            let payload = QUICFixtures.cryptoFrame(offset: 0, data: hello)
                + [UInt8(type)]
                + QUICFixtures.cryptoFrame(offset: 50, data: hello)
            let read = frames(payload)
            XCTAssertEqual(read.stop, .unexpectedFrameType(type), "tipo \(type)")
            XCTAssertEqual(read.crypto, [crypto(0, hello)], "tipo \(type)")
        }
    }

    func testStopsAtAnUnknownFrameTypeOfSeveralBytes() {
        let read = frames([0x01] + QUICFixtures.varint(0x2ab2) + QUICFixtures.cryptoFrame(offset: 0, data: hello))
        XCTAssertEqual(read.stop, .unexpectedFrameType(0x2ab2))
        XCTAssertEqual(read.crypto, [])
    }

    /// Cortado en **cada** byte del segundo frame, sea de la clase que sea: lo anterior se
    /// conserva, el recorrido dice `truncated` y nada lee fuera.
    func testAFrameCutAnywhereIsTruncatedAndKeepsTheFramesBeforeIt() {
        let before = QUICFixtures.cryptoFrame(offset: 0, data: hello)
        let cut: [(name: String, bytes: [UInt8])] = [
            ("crypto", [0x06] + QUICFixtures.varint(300) + QUICFixtures.varint(hello.count) + hello),
            ("ack", QUICFixtures.ackFrame(largest: 700, delay: 90, firstRange: 1, ranges: [(gap: 2, length: 400)])),
            ("ack ecn", QUICFixtures.ackFrame(largest: 7, ranges: [(gap: 2, length: 4)], ecnCounts: [300, 1, 2])),
            ("close", QUICFixtures.connectionCloseFrame(errorCode: 300, frameType: 6, reason: "bye")),
        ]
        for (name, bytes) in cut {
            XCTAssertNil(frames(before + bytes).stop, name)
            for length in 1..<bytes.count {
                let read = frames(before + bytes.prefix(length))
                XCTAssertEqual(read.stop, .truncated, "\(name) cortado en \(length)")
                XCTAssertEqual(read.crypto, [crypto(0, hello)], "\(name) cortado en \(length)")
            }
        }
    }

    func testATypeVarintCutShortIsTruncated() {
        XCTAssertEqual(frames([0x01, 0x40]).stop, .truncated)
        XCTAssertEqual(frames([0xC0, 0x00, 0x00]).stop, .truncated)
    }

    /// Una cuenta de rangos que elige el otro extremo y no cabe en lo que queda: se rechaza por
    /// lo que mide el payload, sin recorrer 2^62 rangos.
    func testAnACKRangeCountLargerThanThePayloadIsTruncatedWithoutWalkingIt() {
        let ack: [UInt8] = [0x02, 0x05, 0x00] + QUICFixtures.varint8((1 << 62) - 1) + [0x00, 0x01, 0x02, 0x03, 0x04]
        let read = frames(QUICFixtures.cryptoFrame(offset: 0, data: hello) + ack)
        XCTAssertEqual(read.stop, .truncated)
        XCTAssertEqual(read.crypto, [crypto(0, hello)])
    }

    func testACryptoLengthLargerThanThePayloadIsTruncated() {
        let payload = [0x06, 0x00] + QUICFixtures.varint8((1 << 62) - 1) + hello
        let read = frames(payload)
        XCTAssertEqual(read.stop, .truncated)
        XCTAssertEqual(read.crypto, [])
    }

    func testAConnectionCloseReasonLargerThanThePayloadIsTruncated() {
        let read = frames([0x1c, 0x00, 0x00] + QUICFixtures.varint8(1 << 40) + hello)
        XCTAssertEqual(read.stop, .truncated)
    }

    /// RFC 9000 § 19.6: el stream no pasa de 2^62 − 1. Justo hasta ahí se lee; un byte más, no.
    func testACryptoFrameEndingBeyondTheStreamLimitStopsTheWalk() {
        let last: UInt64 = (1 << 62) - 1
        let fits = [0x06] + QUICFixtures.varint8(last - UInt64(hello.count)) + QUICFixtures.varint(hello.count) + hello
        XCTAssertEqual(frames(fits).crypto, [crypto(last - UInt64(hello.count), hello)])
        XCTAssertNil(frames(fits).stop)

        let beyond = [0x06] + QUICFixtures.varint8(last - UInt64(hello.count) + 1) + QUICFixtures.varint(hello.count) + hello
        XCTAssertEqual(frames(beyond).stop, .cryptoBeyondStreamLimit)
        XCTAssertEqual(frames(beyond).crypto, [])
    }
}
