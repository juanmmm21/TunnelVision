import Foundation
import XCTest
import Shared

/// Tests de la mitad **lectora** del formato pcap (M9), la que estrena `Shared/Capture` para que la
/// app pueda abrir lo que la extensión escribe.
///
/// Lo que se afirma aquí no es "parsea bien unos bytes": es que **parsear deshace exactamente lo que
/// escribe el constructor de la misma cabecera**. Por eso los vectores salen de `globalHeader(...)` y
/// `recordHeader(...)` en vez de escribirse a mano otra vez — si alguien cambiara un offset en un lado
/// y no en el otro, un vector escrito a mano seguiría pasando en ambos.
final class PcapFormatTests: XCTestCase {

    // MARK: - Cabecera global

    func testParsingUndoesWritingTheGlobalHeader() throws {
        let header = try PcapFormat.globalHeader(parsing: PcapFormat.globalHeader(snaplen: 262_144))

        XCTAssertEqual(header.snaplen, 262_144)
        XCTAssertEqual(header.linkType, PcapFormat.linktypeRaw)
    }

    func testTheGlobalHeaderIsRejectedWhenItIsShorterThanItsFields() {
        let short = PcapFormat.globalHeader(snaplen: 1_024).prefix(23)

        XCTAssertThrowsError(try PcapFormat.globalHeader(parsing: short)) { error in
            // No es "cabecera corrupta": es que hay menos bytes de los que hacen falta, que es lo que
            // le pasa a un fichero que la extensión dejó a medias al morir.
            XCTAssertEqual(error as? PcapFormat.FormatError, .shortHeader(expected: 24, actual: 23))
        }
    }

    func testAFileWrittenByAnotherToolIsRejectedByItsMagic() {
        var foreign = PcapFormat.globalHeader(snaplen: 1_024)
        // La misma `magic` escrita en big-endian (`a1 b2 c3 d4` en disco, que leída en little-endian
        // da `swappedMagic`): un `.pcap` perfectamente válido, pero no de los nuestros. Distinguirlo
        // importa porque lo que se le puede decir al usuario es distinto.
        foreign.replaceSubrange(0..<4, with: [0xa1, 0xb2, 0xc3, 0xd4])

        XCTAssertThrowsError(try PcapFormat.globalHeader(parsing: foreign)) { error in
            XCTAssertEqual(error as? PcapFormat.FormatError, .unknownMagic(PcapFormat.swappedMagic))
        }
    }

    func testAnotherLinkLayerIsRejectedInsteadOfMisread() {
        var ethernet = PcapFormat.globalHeader(snaplen: 1_024)
        // LINKTYPE_ETHERNET (1): sus registros empiezan por 14 bytes de cabecera Ethernet, así que
        // leerlos como datagramas IP desnudos daría una lectura falsa de cada byte del volcado.
        ethernet.replaceSubrange(20..<24, with: [0x01, 0x00, 0x00, 0x00])

        XCTAssertThrowsError(try PcapFormat.globalHeader(parsing: ethernet)) { error in
            XCTAssertEqual(error as? PcapFormat.FormatError, .unsupportedLinkType(1))
        }
    }

    // MARK: - Cabecera de registro

    func testParsingUndoesWritingTheRecordHeader() throws {
        let written = PcapFormat.recordHeader(tsSec: 1_700_000_000, tsUsec: 123_456, inclLen: 96, origLen: 1_514)
        let header = try PcapFormat.recordHeader(parsing: written)

        XCTAssertEqual(header.tsSec, 1_700_000_000)
        XCTAssertEqual(header.tsUsec, 123_456)
        // `inclLen < origLen` es exactamente lo que significa que el `snaplen` recortó el paquete.
        XCTAssertEqual(header.inclLen, 96)
        XCTAssertEqual(header.origLen, 1_514)
    }

    func testTheRecordHeaderIsParsedFromASliceThatDoesNotStartAtZero() throws {
        // Un `Data` que sale de una lectura por offset conserva los índices de su origen. Si el
        // parser indexara con enteros crudos, leería fuera de sitio sin dar un solo error.
        let file = PcapFormat.globalHeader(snaplen: 4_096)
            + PcapFormat.recordHeader(tsSec: 7, tsUsec: 8, inclLen: 9, origLen: 10)
        let slice = file[24...]

        let header = try PcapFormat.recordHeader(parsing: slice)

        XCTAssertEqual(header, PcapFormat.RecordHeader(tsSec: 7, tsUsec: 8, inclLen: 9, origLen: 10))
    }

    func testARecordHeaderCutShortIsRejected() {
        let short = PcapFormat.recordHeader(tsSec: 1, tsUsec: 2, inclLen: 3, origLen: 4).prefix(15)

        XCTAssertThrowsError(try PcapFormat.recordHeader(parsing: short)) { error in
            XCTAssertEqual(error as? PcapFormat.FormatError, .shortHeader(expected: 16, actual: 15))
        }
    }

    /// El parser **no** valida `inclLen` contra el `snaplen`: no lo conoce. Esa comprobación es de
    /// quien lee el fichero, que es quien va a reservar la memoria — y la hace `CaptureLibrary`.
    func testTheRecordHeaderDoesNotJudgeItsOwnLength() throws {
        let absurd = PcapFormat.recordHeader(tsSec: 0, tsUsec: 0, inclLen: .max, origLen: .max)

        XCTAssertEqual(try PcapFormat.recordHeader(parsing: absurd).inclLen, .max)
    }
}
