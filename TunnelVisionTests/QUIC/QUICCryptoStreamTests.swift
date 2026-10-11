import Foundation
import XCTest
import Shared

/// Tests de la recomposición del stream CRYPTO. Lo que se afirma, por orden de importancia: que
/// **lleguen como lleguen los frames —desordenados, repetidos, solapados— sale el mismo stream,
/// en orden y una sola vez**; que un frame posterior no reescribe lo que ya había; y que los dos
/// topes paran al stream antes de que crezca.
final class QUICCryptoStreamTests: XCTestCase {

    /// 200 bytes que no se repiten a ninguna distancia corta: un trozo fuera de sitio se nota.
    private let message: [UInt8] = (0..<200).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 / 13) }

    private func stream(maxStreamBytes: Int = 4_096, maxPendingFragments: Int = 8) -> QUICCryptoStream {
        QUICCryptoStream(limits: .init(maxStreamBytes: maxStreamBytes, maxPendingFragments: maxPendingFragments))
    }

    private func frame(_ range: Range<Int>) -> QUICCryptoFrame {
        QUICCryptoFrame(offset: UInt64(range.lowerBound), data: Data(message[range]))
    }

    private func frame(at offset: Int, _ bytes: [UInt8]) -> QUICCryptoFrame {
        QUICCryptoFrame(offset: UInt64(offset), data: Data(bytes))
    }

    private func delivered(_ bytes: ArraySlice<UInt8>) -> QUICCryptoStream.Delivery {
        .delivered(Data(bytes))
    }

    private let nothing = QUICCryptoStream.Delivery.delivered(Data())

    /// Mete los frames uno tras otro y devuelve todo lo entregado, seguido.
    private func feed(_ frames: [QUICCryptoFrame], into stream: inout QUICCryptoStream) -> [UInt8]? {
        var out: [UInt8] = []
        for frame in frames {
            guard case .delivered(let bytes) = stream.insert(frame) else { return nil }
            out += bytes
        }
        return out
    }

    // MARK: - En orden

    func testDeliversFramesThatArriveInOrderAsTheyCome() {
        var stream = stream()
        XCTAssertEqual(stream.insert(frame(0..<80)), delivered(message[0..<80]))
        XCTAssertEqual(stream.insert(frame(80..<81)), delivered(message[80..<81]))
        XCTAssertEqual(stream.insert(frame(81..<200)), delivered(message[81..<200]))
        XCTAssertEqual(stream.deliveredByteCount, 200)
        XCTAssertEqual(stream.pendingFragmentCount, 0)
    }

    func testAFrameWithoutDataChangesNothing() {
        var stream = stream()
        XCTAssertEqual(stream.insert(frame(at: 0, [])), nothing)
        XCTAssertEqual(stream.insert(frame(at: 50, [])), nothing)
        XCTAssertEqual(stream.pendingFragmentCount, 0)
        XCTAssertEqual(stream.insert(frame(0..<200)), delivered(message[0..<200]))
    }

    // MARK: - Desordenados

    func testHoldsAFrameThatArrivesAheadUntilTheGapBeforeItFills() {
        var stream = stream()
        XCTAssertEqual(stream.insert(frame(120..<200)), nothing)
        XCTAssertEqual(stream.pendingFragmentCount, 1)
        XCTAssertEqual(stream.deliveredByteCount, 0)

        XCTAssertEqual(stream.insert(frame(0..<120)), delivered(message[0..<200]))
        XCTAssertEqual(stream.pendingFragmentCount, 0)
        XCTAssertEqual(stream.deliveredByteCount, 200)
    }

    /// Partido en dos por **cada** punto y entregado al revés.
    func testReassemblesTheMessageSplitAtEveryPointAndDeliveredBackwards() {
        for split in 1..<message.count {
            var stream = stream()
            XCTAssertEqual(stream.insert(frame(split..<message.count)), nothing, "corte en \(split)")
            XCTAssertEqual(stream.insert(frame(0..<split)), delivered(message[...]), "corte en \(split)")
        }
    }

    func testReassemblesThreePiecesInEveryOrder() {
        let pieces = [0..<70, 70..<130, 130..<200]
        let orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        for order in orders {
            var stream = stream()
            XCTAssertEqual(feed(order.map { frame(pieces[$0]) }, into: &stream), message, "\(order)")
            XCTAssertEqual(stream.pendingFragmentCount, 0, "\(order)")
        }
    }

    /// Solo se entrega hasta el primer hueco: lo que hay detrás espera al siguiente.
    func testDeliversOnlyUpToTheFirstGap() {
        var stream = stream()
        XCTAssertEqual(stream.insert(frame(50..<100)), nothing)
        XCTAssertEqual(stream.insert(frame(150..<200)), nothing)
        XCTAssertEqual(stream.insert(frame(0..<50)), delivered(message[0..<100]))
        XCTAssertEqual(stream.pendingFragmentCount, 1)
        XCTAssertEqual(stream.insert(frame(100..<150)), delivered(message[100..<200]))
    }

    // MARK: - Repetidos y solapados

    func testARetransmissionOfWhatWasDeliveredDeliversNothing() {
        var stream = stream()
        XCTAssertEqual(stream.insert(frame(0..<120)), delivered(message[0..<120]))
        XCTAssertEqual(stream.insert(frame(0..<120)), nothing)
        XCTAssertEqual(stream.insert(frame(30..<90)), nothing)
        XCTAssertEqual(stream.insert(frame(119..<120)), nothing)
        XCTAssertEqual(stream.deliveredByteCount, 120)
        XCTAssertEqual(stream.pendingFragmentCount, 0)
    }

    func testAFrameThatStraddlesWhatWasDeliveredDeliversOnlyTheNewBytes() {
        var stream = stream()
        XCTAssertEqual(stream.insert(frame(0..<100)), delivered(message[0..<100]))
        XCTAssertEqual(stream.insert(frame(60..<140)), delivered(message[100..<140]))
        XCTAssertEqual(stream.insert(frame(0..<200)), delivered(message[140..<200]))
    }

    func testARepeatedFrameAheadIsHeldOnce() {
        var stream = stream()
        XCTAssertEqual(stream.insert(frame(100..<150)), nothing)
        XCTAssertEqual(stream.insert(frame(100..<150)), nothing)
        XCTAssertEqual(stream.insert(frame(110..<140)), nothing)
        XCTAssertEqual(stream.pendingFragmentCount, 1)
        XCTAssertEqual(stream.insert(frame(0..<100)), delivered(message[0..<150]))
    }

    func testFramesAheadThatOverlapOrTouchBecomeOneFragment() {
        var stream = stream()
        XCTAssertEqual(stream.insert(frame(40..<60)), nothing)
        XCTAssertEqual(stream.insert(frame(100..<120)), nothing)
        XCTAssertEqual(stream.insert(frame(160..<180)), nothing)
        XCTAssertEqual(stream.pendingFragmentCount, 3)

        // Toca al primero por detrás: uno menos no, los mismos, porque se funde con él.
        XCTAssertEqual(stream.insert(frame(60..<70)), nothing)
        XCTAssertEqual(stream.pendingFragmentCount, 3)
        // Solapa al primero y al segundo y los une.
        XCTAssertEqual(stream.insert(frame(65..<105)), nothing)
        XCTAssertEqual(stream.pendingFragmentCount, 2)
        // Cubre los dos que quedan y sobresale por los dos lados.
        XCTAssertEqual(stream.insert(frame(30..<200)), nothing)
        XCTAssertEqual(stream.pendingFragmentCount, 1)

        XCTAssertEqual(stream.insert(frame(0..<30)), delivered(message[0..<200]))
    }

    /// Si dos frames no dicen lo mismo del mismo sitio, valen los bytes que llegaron antes —
    /// también cuando el segundo cubre al primero por los dos lados.
    func testTheBytesThatArrivedFirstWinWhereTwoFramesDisagree() {
        var stream = stream()
        XCTAssertEqual(stream.insert(frame(at: 10, [UInt8](repeating: 0xAA, count: 10))), nothing)
        XCTAssertEqual(stream.insert(frame(at: 5, [UInt8](repeating: 0xBB, count: 20))), nothing)
        XCTAssertEqual(stream.insert(frame(at: 0, [UInt8](repeating: 0xCC, count: 30))), .delivered(Data(
            [UInt8](repeating: 0xCC, count: 5)
                + [UInt8](repeating: 0xBB, count: 5)
                + [UInt8](repeating: 0xAA, count: 10)
                + [UInt8](repeating: 0xBB, count: 5)
                + [UInt8](repeating: 0xCC, count: 5)
        )))
    }

    func testAFrameCannotRewriteWhatWasAlreadyDelivered() {
        var stream = stream()
        XCTAssertEqual(stream.insert(frame(0..<50)), delivered(message[0..<50]))
        let rewrite = [UInt8](repeating: 0xEE, count: 60)
        XCTAssertEqual(stream.insert(frame(at: 0, rewrite)), .delivered(Data(rewrite[50...])))
        XCTAssertEqual(stream.deliveredByteCount, 60)
    }

    /// Lo que un cliente de verdad hace con un ClientHello: trocearlo, barajarlo, repetir trozos y
    /// solaparlos. Mil repartos distintos del mismo mensaje dan siempre el mensaje.
    func testReassemblesTheMessageHoweverItIsCutShuffledRepeatedAndOverlapped() {
        var generator = SplitMix64(seed: 0x51C_2026_1010)
        for round in 0..<1_000 {
            var frames: [QUICCryptoFrame] = []
            var start = 0
            while start < message.count {
                let end = min(message.count, start + Int.random(in: 1...40, using: &generator))
                // Cada trozo se alarga a veces por los dos lados para pisar a sus vecinos.
                let from = max(0, start - Int.random(in: 0...6, using: &generator))
                let to = min(message.count, end + Int.random(in: 0...6, using: &generator))
                frames.append(frame(from..<to))
                if Int.random(in: 0..<4, using: &generator) == 0 { frames.append(frame(start..<end)) }
                start = end
            }
            frames.shuffle(using: &generator)

            var stream = stream(maxStreamBytes: message.count, maxPendingFragments: frames.count)
            XCTAssertEqual(feed(frames, into: &stream), message, "reparto \(round)")
            XCTAssertEqual(stream.pendingFragmentCount, 0, "reparto \(round)")
            XCTAssertEqual(stream.deliveredByteCount, message.count, "reparto \(round)")
        }
    }

    func testAcceptsDataThatIsASliceOfALargerBuffer() {
        var stream = stream()
        let buffer = Data([0xFF, 0xFF] + message + [0xFF])
        let ahead = QUICCryptoFrame(offset: 100, data: buffer[102..<202])
        let first = QUICCryptoFrame(offset: 0, data: buffer[2..<110])
        XCTAssertEqual(stream.insert(ahead), nothing)
        XCTAssertEqual(stream.insert(first), delivered(message[0..<200]))
    }

    // MARK: - Los topes

    func testAcceptsAFrameThatEndsExactlyAtTheByteLimit() {
        var stream = stream(maxStreamBytes: 200)
        XCTAssertEqual(stream.insert(frame(150..<200)), nothing)
        XCTAssertEqual(stream.insert(frame(0..<150)), delivered(message[0..<200]))
        XCTAssertNil(stream.exceeded)
    }

    func testAFrameThatReachesPastTheByteLimitEndsTheStream() {
        var stream = stream(maxStreamBytes: 199)
        XCTAssertEqual(stream.insert(frame(100..<150)), nothing)
        XCTAssertEqual(stream.insert(frame(150..<200)), .exceeded(.streamBytes))
        XCTAssertEqual(stream.exceeded, .streamBytes)
        // Abandonado: suelta lo que guardaba y no vuelve a entregar, ni lo que antes habría cabido.
        XCTAssertEqual(stream.pendingFragmentCount, 0)
        XCTAssertEqual(stream.insert(frame(0..<100)), .exceeded(.streamBytes))
        XCTAssertEqual(stream.deliveredByteCount, 0)
    }

    func testAnOffsetNoBufferCouldHoldEndsTheStreamWithoutOverflowing() {
        let offsets: [UInt64] = [.max, UInt64(Int.max), UInt64(Int.max) + 1, (1 << 62) - 1, 4_097]
        for offset in offsets {
            var stream = stream(maxStreamBytes: 4_096)
            let frame = QUICCryptoFrame(offset: offset, data: Data([0x01, 0x02]))
            XCTAssertEqual(stream.insert(frame), .exceeded(.streamBytes), "\(offset)")
        }
    }

    func testALimitOfZeroBytesAcceptsNothing() {
        var stream = stream(maxStreamBytes: 0)
        XCTAssertEqual(stream.insert(frame(0..<1)), .exceeded(.streamBytes))
    }

    func testHoldsAsManyFragmentsAsTheLimitAllows() {
        var stream = stream(maxPendingFragments: 2)
        XCTAssertEqual(stream.insert(frame(20..<30)), nothing)
        XCTAssertEqual(stream.insert(frame(40..<50)), nothing)
        XCTAssertEqual(stream.pendingFragmentCount, 2)
        XCTAssertNil(stream.exceeded)
        // Un tercero que se funde con los que hay no es un fragmento más.
        XCTAssertEqual(stream.insert(frame(30..<40)), nothing)
        XCTAssertEqual(stream.pendingFragmentCount, 1)
        XCTAssertEqual(stream.insert(frame(0..<20)), delivered(message[0..<50]))
    }

    func testOneFragmentMoreThanTheLimitEndsTheStream() {
        var stream = stream(maxPendingFragments: 2)
        XCTAssertEqual(stream.insert(frame(20..<30)), nothing)
        XCTAssertEqual(stream.insert(frame(40..<50)), nothing)
        XCTAssertEqual(stream.insert(frame(60..<70)), .exceeded(.pendingFragments))
        XCTAssertEqual(stream.exceeded, .pendingFragments)
        XCTAssertEqual(stream.pendingFragmentCount, 0)
        XCTAssertEqual(stream.insert(frame(0..<20)), .exceeded(.pendingFragments))
    }

    /// El tope cuenta lo que **queda** esperando: el frame que llega y se entrega en el acto no
    /// ocupa un sitio, ni aunque los pendientes estén al completo.
    func testAFrameDeliveredAtOnceDoesNotCountAgainstTheFragmentLimit() {
        var stream = stream(maxPendingFragments: 2)
        XCTAssertEqual(stream.insert(frame(20..<30)), nothing)
        XCTAssertEqual(stream.insert(frame(40..<50)), nothing)
        XCTAssertEqual(stream.insert(frame(0..<10)), delivered(message[0..<10]))
        XCTAssertEqual(stream.pendingFragmentCount, 2)
        XCTAssertNil(stream.exceeded)
    }

    func testALimitOfZeroFragmentsOnlyTakesFramesInOrder() {
        var stream = stream(maxPendingFragments: 0)
        XCTAssertEqual(stream.insert(frame(0..<100)), delivered(message[0..<100]))
        XCTAssertEqual(stream.insert(frame(101..<200)), .exceeded(.pendingFragments))
    }
}

/// Un generador con semilla, para que el reparto que hace fallar un test se pueda repetir.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
