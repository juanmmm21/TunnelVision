import Foundation
import XCTest
import Shared

/// Tests de la identidad del fichero de captura: el nombre (formato y lectura de vuelta, que son la
/// misma verdad para los dos procesos) y las consultas al directorio de capturas.
final class CaptureFileTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-file-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func touch(_ name: String) throws {
        try Data().write(to: directory.appendingPathComponent(name))
    }

    private static let referenceDate = Date(timeIntervalSince1970: 1_769_000_000)   // 2026-01-21 UTC

    // MARK: - Nombre

    func testNameCarriesThePaddedSequenceAndTheExtension() {
        let name = CaptureFileName.make(sequence: 42, date: Self.referenceDate)
        XCTAssertTrue(name.hasPrefix("tunnelvision-000042-"), name)
        XCTAssertTrue(name.hasSuffix(".pcap"), name)
    }

    func testSequenceRoundTripsThroughTheName() {
        // Incluye una secuencia por encima del relleno de 6 dígitos: el nombre crece y se sigue
        // leyendo, porque el relleno es para ordenar, no un tope.
        for sequence: UInt32 in [0, 1, 42, 999_999, 1_000_000, .max] {
            let name = CaptureFileName.make(sequence: sequence, date: Self.referenceDate)
            XCTAssertEqual(CaptureFileName.sequence(fromFileName: name), sequence, name)
        }
    }

    /// El relleno de ceros existe para que ordenar por nombre sea ordenar por secuencia: es lo que
    /// hace que la lista de capturas salga cronológica sin mirar dentro de los ficheros.
    func testPaddingMakesAlphabeticalOrderMatchSequenceOrder() {
        let names = [0, 1, 9, 10, 100, 999_999].map {
            CaptureFileName.make(sequence: UInt32($0), date: Self.referenceDate)
        }
        XCTAssertEqual(names, names.sorted())
    }

    func testForeignFileNamesAreRejected() {
        let rejected = [
            "otra-cosa-000001-20260121-000000.pcap",     // no es nuestro prefijo
            "tunnelvision-000001-20260121-000000.txt",   // no es una captura
            "tunnelvision-12-20260121-000000.pcap",      // menos dígitos de los que escribimos
            "tunnelvision-abcdef-20260121-000000.pcap",  // secuencia no numérica
            "tunnelvision-000001.pcap",                  // sin separador tras la secuencia
            "tunnelvision-.pcap",
        ]
        for name in rejected {
            XCTAssertNil(CaptureFileName.sequence(fromFileName: name), name)
        }
    }

    // MARK: - Directorio

    func testFilesAreSortedBySequenceAndForeignFilesAreIgnored() throws {
        try touch(CaptureFileName.make(sequence: 7, date: Self.referenceDate))
        try touch(CaptureFileName.make(sequence: 2, date: Self.referenceDate))
        try touch("notas.txt")
        try touch("captura-ajena.pcap")

        let files = CaptureDirectory.files(in: directory)
        XCTAssertEqual(files.map(\.sequence), [2, 7])
        XCTAssertEqual(files.map(\.url.lastPathComponent), files.map(\.url.lastPathComponent).sorted())
    }

    func testHighestSequenceIsNilWithoutCaptures() {
        XCTAssertNil(CaptureDirectory.highestSequence(in: directory))

        // Un directorio que aún no existe no es un error: todavía no se ha capturado nada.
        let missing = directory.appendingPathComponent("todavia-no", isDirectory: true)
        XCTAssertNil(CaptureDirectory.highestSequence(in: missing))
        XCTAssertTrue(CaptureDirectory.files(in: missing).isEmpty)
    }

    func testHighestSequenceIgnoresNameOrderAndTakesTheLargest() throws {
        try touch(CaptureFileName.make(sequence: 3, date: Self.referenceDate))
        try touch(CaptureFileName.make(sequence: 11, date: Self.referenceDate))
        XCTAssertEqual(CaptureDirectory.highestSequence(in: directory), 11)
    }

    func testURLForSequenceResolvesTheFileAndNilWhenItIsGone() throws {
        let name = CaptureFileName.make(sequence: 5, date: Self.referenceDate)
        try touch(name)

        XCTAssertEqual(CaptureDirectory.url(forSequence: 5, in: directory)?.lastPathComponent, name)
        XCTAssertNil(CaptureDirectory.url(forSequence: 6, in: directory))

        try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        XCTAssertNil(CaptureDirectory.url(forSequence: 5, in: directory))
    }
}
