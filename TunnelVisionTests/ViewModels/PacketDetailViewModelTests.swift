import Foundation
import XCTest
import Shared

/// Tests del view model de la pantalla de los bytes de un paquete (M9).
///
/// La lectura entra guionizada porque los caminos que hay que fijar son justo los que una biblioteca
/// sana sobre un directorio temporal no sabe provocar: el fichero borrado, el registro ilegible y el
/// registro que describe otro paquete. Lo que sí corre contra ficheros reales —que la localización
/// devuelta al capturar lleve a esos bytes— está en `CaptureLibraryTests`, donde lo que importa es el
/// acoplamiento entre los dos procesos.
@MainActor
final class PacketDetailViewModelTests: XCTestCase {

    // MARK: - Utilidades

    private static let location = CaptureLocation(fileSequence: 7, recordOffset: 1_024)

    private func summary(length: UInt32 = 64, capture: CaptureLocation?) -> PacketSummary {
        PacketSummary(
            id: 1,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            offset: 0.004,
            direction: .outbound,
            length: length,
            event: .data,
            flagsDetail: "PSH, ACK",
            capture: capture
        )
    }

    private func record(bytes: Data, originalLength: UInt32? = nil) -> CaptureRecord {
        CaptureRecord(
            location: Self.location,
            bytes: bytes,
            originalLength: originalLength ?? UInt32(bytes.count),
            timestampMicroseconds: 1_500
        )
    }

    /// Cuenta las lecturas para poder afirmar cuándo **no** se toca el disco. Es una clase para que la
    /// closure inyectada (que es `@Sendable`) pueda incrementarla sin capturar el caso de test.
    private final class ReadCounter: @unchecked Sendable {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    // MARK: - Sin localización

    func testAPacketWithoutBytesIsAnsweredWithoutReadingAnything() async {
        let counter = ReadCounter()
        let answer = record(bytes: Data())
        let viewModel = PacketDetailViewModel(packet: summary(capture: nil)) { _ in
            counter.increment()
            return answer
        }

        await viewModel.load()

        // Sin localización no hay fichero que abrir, y una lectura de disco solo podría acabar en el
        // mismo sitio.
        XCTAssertEqual(viewModel.state, .unavailable(.notCaptured))
        XCTAssertEqual(counter.count, 0)
        // Aun así la pantalla tiene algo que contar: por eso la fila lleva aquí igualmente.
        XCTAssertEqual(viewModel.packetFacts.map(\.label), ["When", "Direction", "Size"])
        XCTAssertTrue(viewModel.recordFacts.isEmpty)
    }

    // MARK: - Camino feliz

    func testTheBytesOfThePacketAreLoadedAndDumped() async {
        let expected = Self.location
        let answer = record(bytes: Data([0x47, 0x45, 0x54, 0x20]))
        let asked = ReadCounter()
        let viewModel = PacketDetailViewModel(packet: summary(length: 4, capture: expected)) { location in
            XCTAssertEqual(location, expected)
            asked.increment()
            return answer
        }

        await viewModel.load()

        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(viewModel.content, .bytes([HexDumpLine(offset: 0, hex: "47 45 54 20", ascii: "GET ")]))
        XCTAssertEqual(viewModel.recordFacts.map(\.label), ["Capture file", "Position in file"])
        XCTAssertNil(viewModel.truncationNote)
    }

    func testLoadingTwiceDoesNotReadTheFileAgain() async {
        let counter = ReadCounter()
        let answer = record(bytes: Data([0x41, 0x42]))
        let viewModel = PacketDetailViewModel(packet: summary(length: 2, capture: Self.location)) { _ in
            counter.increment()
            return answer
        }

        await viewModel.load()
        await viewModel.load()

        // `task` se dispara también al volver de una vista apilada encima: releer entonces gastaría
        // una lectura de disco para enseñar exactamente lo mismo.
        XCTAssertEqual(counter.count, 1)
    }

    // MARK: - Los bytes no son de este paquete

    func testBytesThatDescribeAnotherPacketAreNotDrawn() async {
        let answer = record(bytes: Data(repeating: 0xAA, count: 40), originalLength: 40)
        let viewModel = PacketDetailViewModel(packet: summary(length: 64, capture: Self.location)) { _ in
            answer
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.state, .unavailable(.mismatched(expected: 64, found: 40)))
        guard case .placeholder = viewModel.content else {
            return XCTFail("un registro de otro paquete no se pinta")
        }
    }

    func testASnaplenTruncatedRecordIsStillThisPacketAndSaysSo() async {
        let answer = record(bytes: Data(repeating: 0xBB, count: 32), originalLength: 1_500)
        let viewModel = PacketDetailViewModel(packet: summary(length: 1_500, capture: Self.location)) { _ in
            answer
        }

        await viewModel.load()

        guard case .bytes = viewModel.content else {
            return XCTFail("un paquete recortado por snaplen sí se enseña")
        }
        // Y se dice, porque callarlo dejaría creer que el paquete entero eran 32 bytes.
        XCTAssertEqual(viewModel.truncationNote?.contains("1.5 KB"), true)
    }

    // MARK: - Sin bytes que enseñar

    func testADeletedCaptureIsExplainedAndNotOfferedARetry() async {
        let viewModel = PacketDetailViewModel(packet: summary(capture: Self.location)) { _ in
            throw CaptureLibraryError.notFound(7)
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.state, .unavailable(.fileDeleted(7)))
        guard case .placeholder(let placeholder) = viewModel.content else {
            return XCTFail("estado inesperado")
        }
        XCTAssertNil(placeholder.action)
    }

    func testAReadFailureOffersARetryThatReallyReadsAgain() async {
        let counter = ReadCounter()
        let answer = record(bytes: Data([0x41, 0x42]))
        let viewModel = PacketDetailViewModel(packet: summary(length: 2, capture: Self.location)) { _ in
            counter.increment()
            guard counter.count > 1 else {
                throw CaptureLibraryError.recordUnreadable("cut short")
            }
            return answer
        }

        await viewModel.load()
        XCTAssertEqual(viewModel.state, .unavailable(.failed(.recordUnreadable("cut short"))))
        guard case .placeholder(let placeholder) = viewModel.content else {
            return XCTFail("estado inesperado")
        }
        XCTAssertEqual(placeholder.action, .retry)

        await viewModel.perform(.retry)

        XCTAssertEqual(counter.count, 2)
        XCTAssertEqual(viewModel.content, .bytes([HexDumpLine(offset: 0, hex: "41 42", ascii: "AB")]))
    }

    /// Un error que no viene tipado del servicio no se traga ni se enseña crudo: se clasifica como
    /// fallo de lectura, que es lo único que puede significar aquí.
    func testAnUntypedFailureStillLandsInAReadableState() async {
        struct Boom: Error {}
        let viewModel = PacketDetailViewModel(packet: summary(capture: Self.location)) { _ in throw Boom() }

        await viewModel.load()

        guard case .unavailable(.failed(.recordUnreadable)) = viewModel.state else {
            return XCTFail("estado inesperado: \(viewModel.state)")
        }
    }

    func testLoadAfterAFailureTriesAgainButLoadAfterSuccessDoesNot() async {
        let counter = ReadCounter()
        let viewModel = PacketDetailViewModel(packet: summary(length: 2, capture: Self.location)) { _ in
            counter.increment()
            throw CaptureLibraryError.recordUnreadable("still broken")
        }

        await viewModel.load()
        await viewModel.load()

        // Un estado sin bytes no es un estado cargado: volver a la pantalla vuelve a intentarlo.
        XCTAssertEqual(counter.count, 2)
    }
}
