import Foundation
import XCTest
import Shared

/// Tests del formato del contenido descifrado. Cubren las dos cabeceras byte a byte (que es lo que
/// hace que el fichero sea el mismo en cualquier máquina), el round-trip escritura→lectura, el recorte
/// dicho por la diferencia entre lo guardado y lo que medía, y los cinco rechazos del parser — que son
/// la parte que importa: un offset desfasado tiene que dar un error y no el contenido de otra
/// conversación.
final class PlaintextFormatTests: XCTestCase {

    // MARK: - Cabecera global

    func testGlobalHeaderIsByteExact() {
        let bytes = [UInt8](PlaintextFormat.globalHeader(maxRecordBytes: 65_536))

        XCTAssertEqual(bytes.count, PlaintextFormat.globalHeaderSize)
        XCTAssertEqual(Array(bytes[0..<4]), [0x54, 0x50, 0x56, 0x54])   // magic TVPT en LE
        XCTAssertEqual(Array(bytes[4..<6]), [0x01, 0x00])               // version_major 1
        XCTAssertEqual(Array(bytes[6..<8]), [0x00, 0x00])               // version_minor 0
        XCTAssertEqual(Array(bytes[8..<12]), [0x00, 0x00, 0x01, 0x00])  // 65_536 en LE
        XCTAssertEqual(Array(bytes[12..<16]), [0x00, 0x00, 0x00, 0x00]) // reservado
    }

    func testGlobalHeaderRoundTrip() throws {
        let header = try PlaintextFormat.globalHeader(
            parsing: PlaintextFormat.globalHeader(maxRecordBytes: 4_096)
        )
        XCTAssertEqual(header.maxRecordBytes, 4_096)
    }

    func testGlobalHeaderRejectsShortData() {
        XCTAssertThrowsError(try PlaintextFormat.globalHeader(parsing: Data([0x54, 0x50]))) { error in
            XCTAssertEqual(
                error as? PlaintextFormat.FormatError,
                .shortHeader(expected: PlaintextFormat.globalHeaderSize, actual: 2)
            )
        }
    }

    func testGlobalHeaderRejectsForeignMagic() {
        var data = PlaintextFormat.globalHeader(maxRecordBytes: 64)
        data[0] = 0xD4   // el primer byte de un .pcap little-endian
        XCTAssertThrowsError(try PlaintextFormat.globalHeader(parsing: data)) { error in
            guard case .unknownMagic = error as? PlaintextFormat.FormatError else {
                return XCTFail("se esperaba unknownMagic, llegó \(error)")
            }
        }
    }

    /// Un fichero nuestro de una versión mayor distinta se rechaza en vez de leerse a medias: es lo
    /// que permite que el formato crezca sin que un binario viejo enseñe basura como si fuera
    /// contenido.
    func testGlobalHeaderRejectsAnotherMajorVersion() {
        var data = PlaintextFormat.globalHeader(maxRecordBytes: 64)
        data[4] = 2
        XCTAssertThrowsError(try PlaintextFormat.globalHeader(parsing: data)) { error in
            XCTAssertEqual(
                error as? PlaintextFormat.FormatError,
                .unsupportedVersion(major: 2, minor: 0)
            )
        }
    }

    // MARK: - Cabecera de registro

    func testRecordHeaderIsByteExact() {
        let bytes = [UInt8](
            PlaintextFormat.recordHeader(
                stream: 1,
                timestamp: 0x0102_0304_0506_0708,
                storedLength: 3,
                originalLength: 9,
                direction: .inbound
            )
        )

        XCTAssertEqual(bytes.count, PlaintextFormat.recordHeaderSize)
        XCTAssertEqual(Array(bytes[0..<4]), [0x52, 0x50, 0x56, 0x54])   // magic TVPR en LE
        XCTAssertEqual(Array(bytes[4..<12]), [1, 0, 0, 0, 0, 0, 0, 0])  // stream
        XCTAssertEqual(Array(bytes[12..<20]), [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01])
        XCTAssertEqual(Array(bytes[20..<24]), [3, 0, 0, 0])             // storedLength
        XCTAssertEqual(Array(bytes[24..<28]), [9, 0, 0, 0])             // originalLength
        XCTAssertEqual(bytes[28], Direction.inbound.rawValue)
        XCTAssertEqual(Array(bytes[29..<32]), [0, 0, 0])                // relleno
    }

    func testRecordHeaderRoundTrip() throws {
        let header = try PlaintextFormat.recordHeader(
            parsing: PlaintextFormat.recordHeader(
                stream: .max,
                timestamp: 1_770_000_000_000_000_000,
                storedLength: 128,
                originalLength: 128,
                direction: .outbound
            )
        )

        XCTAssertEqual(header.stream, .max)
        XCTAssertEqual(header.timestamp, 1_770_000_000_000_000_000)
        XCTAssertEqual(header.storedLength, 128)
        XCTAssertEqual(header.originalLength, 128)
        XCTAssertEqual(header.direction, .outbound)
        XCTAssertFalse(header.isTruncated)
    }

    /// El único sitio donde se dice que un trozo no se guardó entero, y por eso se afirma aparte.
    func testTruncationIsToldByTheTwoLengths() throws {
        let header = try PlaintextFormat.recordHeader(
            parsing: PlaintextFormat.recordHeader(
                stream: 7,
                timestamp: 0,
                storedLength: 100,
                originalLength: 4_000,
                direction: .inbound
            )
        )
        XCTAssertTrue(header.isTruncated)
        XCTAssertEqual(header.originalLength - header.storedLength, 3_900)
    }

    /// Un instante anterior al epoch no se puede dar en producción, pero el campo es con signo y
    /// tiene que sobrevivir al viaje: si se leyera sin signo, una fecha así saltaría al año 2554.
    func testRecordHeaderKeepsNegativeTimestamps() throws {
        let header = try PlaintextFormat.recordHeader(
            parsing: PlaintextFormat.recordHeader(
                stream: 0,
                timestamp: -1_000,
                storedLength: 0,
                originalLength: 0,
                direction: .outbound
            )
        )
        XCTAssertEqual(header.timestamp, -1_000)
    }

    func testRecordHeaderRejectsShortData() {
        XCTAssertThrowsError(try PlaintextFormat.recordHeader(parsing: Data(repeating: 0, count: 31))) { error in
            XCTAssertEqual(
                error as? PlaintextFormat.FormatError,
                .shortHeader(expected: PlaintextFormat.recordHeaderSize, actual: 31)
            )
        }
    }

    /// Lo que la `magic` de registro existe para impedir: leer a mitad de un registro y devolver los
    /// bytes de otra conversación como si fueran los pedidos.
    func testRecordHeaderRejectsAnOffsetThatIsNotARecord() {
        var data = PlaintextFormat.recordHeader(
            stream: 3,
            timestamp: 0,
            storedLength: 16,
            originalLength: 16,
            direction: .inbound
        )
        data.append(Data(repeating: 0xAA, count: 16))
        // Ocho bytes dentro del registro: quedan de sobra para una cabecera entera, así que lo que
        // rechaza no es la falta de bytes sino que ahí no empieza ningún registro.
        let misaligned = data.dropFirst(8)

        XCTAssertThrowsError(try PlaintextFormat.recordHeader(parsing: misaligned)) { error in
            guard case .notARecord = error as? PlaintextFormat.FormatError else {
                return XCTFail("se esperaba notARecord, llegó \(error)")
            }
        }
    }

    func testRecordHeaderRejectsAnUnknownDirection() {
        var data = PlaintextFormat.recordHeader(
            stream: 1,
            timestamp: 0,
            storedLength: 0,
            originalLength: 0,
            direction: .outbound
        )
        data[data.startIndex + 28] = 9

        XCTAssertThrowsError(try PlaintextFormat.recordHeader(parsing: data)) { error in
            XCTAssertEqual(error as? PlaintextFormat.FormatError, .unknownDirection(9))
        }
    }

    /// Un `Data` que sale de un `subdata` conserva los índices del original: leer con enteros crudos
    /// leería fuera de sitio. Es el fallo que `PcapFormat` ya documentó y esta es su afirmación.
    func testParsersReadFromTheSliceStart() throws {
        var data = Data(repeating: 0xFF, count: 40)
        data.append(
            PlaintextFormat.recordHeader(
                stream: 42,
                timestamp: 5,
                storedLength: 1,
                originalLength: 1,
                direction: .inbound
            )
        )

        let header = try PlaintextFormat.recordHeader(parsing: data.dropFirst(40))
        XCTAssertEqual(header.stream, 42)
        XCTAssertEqual(header.timestamp, 5)
    }

    // MARK: - Nombres de fichero

    func testFileNameCarriesSequenceAndReadsItBack() {
        let name = PlaintextFileName.make(sequence: 7, date: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(name, "plaintext-000007-19700101-000000.tvpt")
        XCTAssertEqual(PlaintextFileName.sequence(fromFileName: name), 7)
    }

    func testFileNameOrdersAlphabeticallyAsChronologically() {
        let names = [90, 1, 10].map { PlaintextFileName.make(sequence: UInt32($0), date: Date()) }
        XCTAssertEqual(
            names.sorted().compactMap(PlaintextFileName.sequence(fromFileName:)),
            [1, 10, 90]
        )
    }

    /// El directorio no es solo nuestro (la retención borra, el usuario podría dejar algo ahí), así
    /// que lo que no sea un fichero nuestro tiene que quedarse fuera en vez de colarse con una
    /// secuencia inventada. Una captura, en particular, no es contenido descifrado.
    func testForeignNamesAreRejected() {
        let rejected = [
            "tunnelvision-000001-20260813-101500.pcap",
            "plaintext-0001-20260813-101500.tvpt",   // menos dígitos de los que el formato pone
            "plaintext-000001.tvpt",                 // sin componente de fecha
            "plaintext-abcdef-20260813-101500.tvpt",
            "000001-20260813-101500.tvpt",
            ".DS_Store",
        ]
        for name in rejected {
            XCTAssertNil(PlaintextFileName.sequence(fromFileName: name), "coló \(name)")
        }
    }
}
