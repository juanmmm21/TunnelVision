import Foundation
import XCTest
import Shared

/// Tests del reensamblador TCP (M4). Cubren: stream en orden, fuera de orden (invertido e
/// intercalado), duplicado y solape parcial sin doble entrega, vuelta de la secuencia sobre el
/// límite de `UInt32`, y desbordamiento (por bytes o por número de segmentos) que degrada a
/// solo-metadatos liberando memoria.
final class TCPReassemblerTests: XCTestCase {

    private let isn: UInt32 = 1000              // primer byte de datos en 1001
    private var firstByte: UInt32 { isn &+ 1 }

    private func makeReassembler(
        maxBufferedBytes: Int = 256 * 1024,
        maxOutOfOrderSegments: Int = 128
    ) -> TCPReassembler {
        TCPReassembler(
            config: .init(maxBufferedBytes: maxBufferedBytes, maxOutOfOrderSegments: maxOutOfOrderSegments),
            isn: isn,
            direction: .outbound
        )
    }

    private func data(_ string: String) -> Data { Data(string.utf8) }

    // MARK: - En orden

    func testInOrderStreamReassembles() {
        var r = makeReassembler()
        XCTAssertEqual(r.accept(sequence: firstByte, payload: data("abc"), flags: []), .delivered(data("abc")))
        XCTAssertEqual(r.accept(sequence: firstByte &+ 3, payload: data("def"), flags: []), .delivered(data("def")))
        XCTAssertEqual(r.accept(sequence: firstByte &+ 6, payload: data("ghi"), flags: []), .delivered(data("ghi")))
        XCTAssertEqual(r.expectedSequence, firstByte &+ 9)
        XCTAssertEqual(r.bufferedByteCount, 0)
    }

    // MARK: - Fuera de orden

    func testReversedOutOfOrderReassemblesOnGapFill() {
        var r = makeReassembler()
        XCTAssertEqual(r.accept(sequence: firstByte &+ 6, payload: data("ghi"), flags: []), .buffered)
        XCTAssertEqual(r.accept(sequence: firstByte &+ 3, payload: data("def"), flags: []), .buffered)
        XCTAssertEqual(r.bufferedByteCount, 6)
        // El segmento que cierra el hueco arrastra todo lo bufferizado, ya contiguo.
        XCTAssertEqual(r.accept(sequence: firstByte, payload: data("abc"), flags: []), .delivered(data("abcdefghi")))
        XCTAssertEqual(r.bufferedByteCount, 0)
        XCTAssertEqual(r.expectedSequence, firstByte &+ 9)
    }

    func testInterleavedOutOfOrder() {
        var r = makeReassembler()
        XCTAssertEqual(r.accept(sequence: firstByte &+ 3, payload: data("def"), flags: []), .buffered)
        XCTAssertEqual(r.accept(sequence: firstByte, payload: data("abc"), flags: []), .delivered(data("abcdef")))
        XCTAssertEqual(r.accept(sequence: firstByte &+ 9, payload: data("jkl"), flags: []), .buffered)
        XCTAssertEqual(r.accept(sequence: firstByte &+ 6, payload: data("ghi"), flags: []), .delivered(data("ghijkl")))
        XCTAssertEqual(r.expectedSequence, firstByte &+ 12)
    }

    // MARK: - Duplicado y solape

    func testExactRetransmitIsDuplicate() {
        var r = makeReassembler()
        XCTAssertEqual(r.accept(sequence: firstByte, payload: data("abc"), flags: []), .delivered(data("abc")))
        XCTAssertEqual(r.accept(sequence: firstByte, payload: data("abc"), flags: []), .duplicate)
        // Subconjunto de lo ya entregado también es duplicado.
        XCTAssertEqual(r.accept(sequence: firstByte, payload: data("ab"), flags: []), .duplicate)
    }

    func testPartialOverlapDeliversOnlyNewBytes() {
        var r = makeReassembler()
        XCTAssertEqual(r.accept(sequence: firstByte, payload: data("abcd"), flags: []), .delivered(data("abcd")))
        // "cdef" empieza dentro de lo entregado (cd) y aporta "ef": solo se entrega lo nuevo.
        XCTAssertEqual(r.accept(sequence: firstByte &+ 2, payload: data("cdef"), flags: []), .delivered(data("ef")))
        XCTAssertEqual(r.expectedSequence, firstByte &+ 6)
    }

    func testOverlapWithBufferedSegmentNotDoubleDelivered() {
        var r = makeReassembler()
        // Bufferiza [+3, +6) = "def".
        XCTAssertEqual(r.accept(sequence: firstByte &+ 3, payload: data("def"), flags: []), .buffered)
        // Un segmento en orden que se solapa con el bufferizado: entrega "abcdef" una sola vez.
        XCTAssertEqual(r.accept(sequence: firstByte, payload: data("abcde"), flags: []), .delivered(data("abcdef")))
        XCTAssertEqual(r.bufferedByteCount, 0)
        XCTAssertEqual(r.expectedSequence, firstByte &+ 6)
    }

    func testRedundantBufferedSegmentIsDuplicate() {
        var r = makeReassembler()
        XCTAssertEqual(r.accept(sequence: firstByte &+ 3, payload: data("defgh"), flags: []), .buffered)
        // Rango contenido en lo ya bufferizado ⇒ nada nuevo.
        XCTAssertEqual(r.accept(sequence: firstByte &+ 4, payload: data("efg"), flags: []), .duplicate)
        XCTAssertEqual(r.bufferedByteCount, 5)
    }

    // MARK: - Control sin payload

    func testControlSegmentWithoutPayloadIsDuplicate() {
        var r = makeReassembler()
        XCTAssertEqual(r.accept(sequence: isn, payload: Data(), flags: .syn), .duplicate)
        XCTAssertEqual(r.accept(sequence: firstByte, payload: Data(), flags: [.ack]), .duplicate)
        XCTAssertEqual(r.expectedSequence, firstByte)
    }

    // MARK: - Vuelta de la secuencia (RFC 1982)

    func testSequenceWraparound() {
        // ISN cerca del techo: el primer byte cae en 0xFFFFFFFF y la secuencia da la vuelta.
        var r = TCPReassembler(config: .init(), isn: 0xFFFFFFFE, direction: .inbound)
        XCTAssertEqual(r.expectedSequence, 0xFFFFFFFF)
        XCTAssertEqual(r.accept(sequence: 0xFFFFFFFF, payload: data("AB"), flags: []), .delivered(data("AB")))
        XCTAssertEqual(r.expectedSequence, 1)   // 0xFFFFFFFF + 2, con wrap
        XCTAssertEqual(r.accept(sequence: 1, payload: data("CD"), flags: []), .delivered(data("CD")))
        // Fuera de orden a través del límite: bufferiza y luego empalma.
        XCTAssertEqual(r.accept(sequence: 7, payload: data("HI"), flags: []), .buffered)
        XCTAssertEqual(r.accept(sequence: 3, payload: data("EFGH"), flags: []), .delivered(data("EFGHHI")))
    }

    // MARK: - Desbordamiento y degradado

    func testByteOverflowDowngradesAndFreesMemory() {
        var r = makeReassembler(maxBufferedBytes: 8)
        XCTAssertEqual(r.accept(sequence: firstByte &+ 10, payload: data("12345"), flags: []), .buffered)
        XCTAssertEqual(r.bufferedByteCount, 5)
        // Otro segmento fuera de orden superaría los 8 bytes ⇒ degrada y libera.
        XCTAssertEqual(r.accept(sequence: firstByte &+ 20, payload: data("67890"), flags: []), .downgraded)
        XCTAssertTrue(r.isDowngraded)
        XCTAssertEqual(r.bufferedByteCount, 0)
        // A partir de aquí, todo es `.downgraded`, incluso un segmento en orden.
        XCTAssertEqual(r.accept(sequence: firstByte, payload: data("abc"), flags: []), .downgraded)
    }

    func testSegmentCountOverflowDowngrades() {
        var r = makeReassembler(maxOutOfOrderSegments: 2)
        XCTAssertEqual(r.accept(sequence: firstByte &+ 3, payload: data("aa"), flags: []), .buffered)
        XCTAssertEqual(r.accept(sequence: firstByte &+ 9, payload: data("bb"), flags: []), .buffered)
        // El tercer fragmento distinto supera el tope de segmentos fuera de orden.
        XCTAssertEqual(r.accept(sequence: firstByte &+ 15, payload: data("cc"), flags: []), .downgraded)
        XCTAssertTrue(r.isDowngraded)
    }

    // MARK: - Robustez

    func testLargeInOrderStreamReassemblesToOriginal() {
        var r = makeReassembler()
        var expected = Data()
        var seq = firstByte
        for i in 0..<500 {
            let chunk = Data(repeating: UInt8(i & 0xff), count: 20)
            expected.append(chunk)
            guard case .delivered(let out) = r.accept(sequence: seq, payload: chunk, flags: []) else {
                return XCTFail("segmento \(i) no se entregó en orden")
            }
            XCTAssertEqual(out, chunk)
            seq = seq &+ 20
        }
        XCTAssertEqual(r.expectedSequence, firstByte &+ 500 * 20)
        XCTAssertEqual(expected.count, 10_000)
    }
}
