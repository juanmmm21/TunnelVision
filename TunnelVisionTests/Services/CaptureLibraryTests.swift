import Foundation
import XCTest
import Shared

/// Tests del directorio de capturas visto desde la app (M9), contra ficheros escritos por un
/// `PcapWriter` **real** sobre un directorio temporal — no contra ficheros inventados: lo que se
/// ejercita es el acoplamiento entre las dos mitades, la que escribe (extensión) y la que lista y
/// borra (app), que es donde el nombre del fichero tiene que significar lo mismo en los dos lados.
final class CaptureLibraryTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-library-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Utilidades

    private func makeWriter(maxFileBytes: UInt64 = 64 * 1024 * 1024) throws -> PcapWriter {
        try PcapWriter(config: .init(directory: tempDir, snaplen: 262_144, maxFileBytes: maxFileBytes))
    }

    /// Un datagrama cualquiera: aquí no importa su contenido, solo que ocupe bytes en el fichero.
    private func packet(_ length: Int) -> Data {
        Data(repeating: 0xAB, count: length)
    }

    /// Un datagrama **reconocible**: cada paquete lleva un byte distinto, que es lo que permite
    /// afirmar que una localización llevó a *sus* bytes y no a los del vecino.
    private func packet(_ length: Int, filledWith byte: UInt8) -> Data {
        Data(repeating: byte, count: length)
    }

    // MARK: - Listado

    func testListsTheFilesTheWriterWroteInSequenceOrder() async throws {
        let writer = try makeWriter()
        _ = try await writer.write(packet: packet(64), originalLength: 64, timestamp: 1_000)
        try await writer.rotate()
        _ = try await writer.write(packet: packet(128), originalLength: 128, timestamp: 2_000)
        await writer.close()

        let library = CaptureLibrary(directory: tempDir)
        let files = try await library.files()

        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files.map(\.sequence), [0, 1])
        // El tamaño es el de disco, no una estimación: cabecera global (24) + registro (16 + datos).
        XCTAssertEqual(files[0].byteCount, 24 + 16 + 64)
        XCTAssertEqual(files[1].byteCount, 24 + 16 + 128)
        XCTAssertNotNil(files[0].createdAt)
        // La secuencia que la app lee es la que la extensión escribió en el nombre: una sola verdad
        // (`CaptureFileName`), que es lo que permite resolver la `CaptureLocation` de un paquete.
        XCTAssertEqual(CaptureFileName.sequence(fromFileName: files[1].url.lastPathComponent), 1)
    }

    func testTheUrlOfEachFileResolvesToItsOwnBytes() async throws {
        let writer = try makeWriter()
        _ = try await writer.write(packet: packet(16), originalLength: 16, timestamp: 1)
        try await writer.rotate()
        _ = try await writer.write(packet: packet(32), originalLength: 32, timestamp: 2)
        await writer.close()

        let files = try await CaptureLibrary(directory: tempDir).files()

        // Cada URL listada abre un `.pcap` válido cuyos registros son los suyos y no los del otro
        // fichero: es la propiedad que hace que la exportación no mezcle capturas.
        let first = try TestPcapReader.read(files[0].url)
        let second = try TestPcapReader.read(files[1].url)
        XCTAssertEqual(first.records.map(\.inclLen), [16])
        XCTAssertEqual(second.records.map(\.inclLen), [32])
    }

    func testAbsentDirectoryIsAnEmptyListAndNotAFailure() async throws {
        let missing = tempDir.appendingPathComponent("never-created", isDirectory: true)
        let files = try await CaptureLibrary(directory: missing).files()

        // Antes de la primera sesión de túnel el directorio no existe todavía. Eso es "no hay
        // capturas", no una avería que enseñar.
        XCTAssertTrue(files.isEmpty)
    }

    func testForeignFilesAreNotListed() async throws {
        let writer = try makeWriter()
        await writer.close()
        try Data("not a capture".utf8)
            .write(to: tempDir.appendingPathComponent("notes.txt"))
        try Data().write(to: tempDir.appendingPathComponent("tunnelvision-bad.pcap"))

        let files = try await CaptureLibrary(directory: tempDir).files()

        XCTAssertEqual(files.map(\.sequence), [0])
    }

    /// El fallo de resolución del contenedor se ejercita por la costura y no con un App Group
    /// inventado: en el Simulator, `containerURL(forSecurityApplicationGroupIdentifier:)` devuelve
    /// una ruta para **cualquier** identificador, así que el caso real —una app sin el entitlement—
    /// no se puede provocar ahí. Lo que sí se afirma es que el error llega tipado y sin tocar disco.
    func testAnUnresolvableDirectoryIsATypedFailure() async {
        let library = CaptureLibrary(resolvingDirectory: {
            throw CaptureLibraryError.containerUnavailable("group.test")
        })

        do {
            _ = try await library.files()
            XCTFail("listar sin contenedor debería fallar")
        } catch let error as CaptureLibraryError {
            XCTAssertEqual(error, .containerUnavailable("group.test"))
        } catch {
            XCTFail("error inesperado: \(error)")
        }

        do {
            try await library.delete(sequence: 0)
            XCTFail("borrar sin contenedor debería fallar")
        } catch let error as CaptureLibraryError {
            // Y falla por la resolución, no como "no encontrado": son cosas distintas y la pantalla
            // las cuenta distinto.
            XCTAssertEqual(error, .containerUnavailable("group.test"))
        } catch {
            XCTFail("error inesperado: \(error)")
        }
    }

    // MARK: - Borrado

    func testDeleteRemovesTheFileFromDiskAndFromTheListing() async throws {
        let writer = try makeWriter()
        _ = try await writer.write(packet: packet(8), originalLength: 8, timestamp: 1)
        try await writer.rotate()
        _ = try await writer.write(packet: packet(8), originalLength: 8, timestamp: 2)
        await writer.close()

        let library = CaptureLibrary(directory: tempDir)
        let before = try await library.files()
        let removed = try XCTUnwrap(before.first { $0.sequence == 0 })

        try await library.delete(sequence: 0)

        XCTAssertFalse(FileManager.default.fileExists(atPath: removed.url.path))
        let after = try await library.files()
        XCTAssertEqual(after.map(\.sequence), [1])
    }

    func testDeletingAnAbsentSequenceIsTypedAsNotFound() async throws {
        let writer = try makeWriter()
        await writer.close()
        let library = CaptureLibrary(directory: tempDir)

        do {
            try await library.delete(sequence: 99)
            XCTFail("borrar lo que no está debería fallar")
        } catch let error as CaptureLibraryError {
            XCTAssertEqual(error, .notFound(99))
        }
    }

    func testDeleteDoesNotTouchTheOtherCaptures() async throws {
        let writer = try makeWriter()
        _ = try await writer.write(packet: packet(24), originalLength: 24, timestamp: 1)
        try await writer.rotate()
        _ = try await writer.write(packet: packet(48), originalLength: 48, timestamp: 2)
        try await writer.rotate()
        _ = try await writer.write(packet: packet(96), originalLength: 96, timestamp: 3)
        await writer.close()

        let library = CaptureLibrary(directory: tempDir)
        try await library.delete(sequence: 1)

        let files = try await library.files()
        XCTAssertEqual(files.map(\.sequence), [0, 2])
        // Los bytes del que sobrevive siguen siendo los suyos: borrar no renumera nada.
        XCTAssertEqual(try TestPcapReader.read(files[1].url).records.map(\.inclLen), [96])
    }

    // MARK: - Los bytes de un paquete

    /// El salto paquete→bytes completo, de punta a punta: lo que el writer devolvió al capturar es lo
    /// que la app usa para volver a esos bytes exactos. Es el acoplamiento que justifica que el
    /// formato viva en `Shared`.
    func testEveryLocationTheWriterReturnedResolvesToItsOwnBytes() async throws {
        let writer = try makeWriter()
        var locations: [CaptureLocation] = []
        for (index, byte) in [UInt8(0x11), 0x22, 0x33].enumerated() {
            let payload = packet(16 + index * 8, filledWith: byte)
            locations.append(
                try await writer.write(
                    packet: payload,
                    originalLength: payload.count,
                    timestamp: Int64(index + 1) * 1_000_000_000
                )
            )
        }
        await writer.close()

        let library = CaptureLibrary(directory: tempDir)

        for (index, byte) in [UInt8(0x11), 0x22, 0x33].enumerated() {
            let record = try await library.record(at: locations[index])
            XCTAssertEqual(record.bytes, packet(16 + index * 8, filledWith: byte))
            XCTAssertEqual(record.originalLength, UInt32(16 + index * 8))
            XCTAssertEqual(record.capturedLength, UInt32(16 + index * 8))
            XCTAssertFalse(record.isTruncated)
            // El sello sale de la cabecera del registro, en microsegundos: el writer recibe
            // nanosegundos desde el epoch y los descompone.
            XCTAssertEqual(record.timestampMicroseconds, UInt64(index + 1) * 1_000_000)
            XCTAssertEqual(record.location, locations[index])
        }
    }

    /// El fallo que todo esto vino a impedir: dos ficheros reinician sus offsets tras la cabecera
    /// global, así que **el mismo offset** existe en los dos y solo el par (fichero, offset) identifica
    /// unos bytes. Si el fichero se ignorase, este test devolvería los mismos bytes dos veces.
    func testTheSameOffsetInTwoFilesResolvesToDifferentBytes() async throws {
        let writer = try makeWriter()
        let first = try await writer.write(
            packet: packet(32, filledWith: 0xAA), originalLength: 32, timestamp: 1
        )
        try await writer.rotate()
        let second = try await writer.write(
            packet: packet(32, filledWith: 0xBB), originalLength: 32, timestamp: 2
        )
        await writer.close()

        XCTAssertEqual(first.recordOffset, second.recordOffset)
        XCTAssertNotEqual(first.fileSequence, second.fileSequence)

        let library = CaptureLibrary(directory: tempDir)
        let recordA = try await library.record(at: first)
        let recordB = try await library.record(at: second)

        XCTAssertEqual(recordA.bytes, packet(32, filledWith: 0xAA))
        XCTAssertEqual(recordB.bytes, packet(32, filledWith: 0xBB))
    }

    func testASnaplenTruncatedRecordSaysHowMuchOfThePacketIsThere() async throws {
        let writer = try PcapWriter(config: .init(directory: tempDir, snaplen: 32, maxFileBytes: .max))
        let location = try await writer.write(
            packet: packet(1_500, filledWith: 0xCD), originalLength: 1_500, timestamp: 1
        )
        await writer.close()

        let record = try await CaptureLibrary(directory: tempDir).record(at: location)

        // Guardados 32, medía 1500: enseñar los 32 sin decirlo dejaría al usuario creyendo que el
        // paquete entero cabía en una línea y media de volcado.
        XCTAssertEqual(record.capturedLength, 32)
        XCTAssertEqual(record.originalLength, 1_500)
        XCTAssertTrue(record.isTruncated)
    }

    func testTheBytesOfADeletedCaptureAreNotFoundAndNotAFailure() async throws {
        let writer = try makeWriter()
        let location = try await writer.write(packet: packet(16), originalLength: 16, timestamp: 1)
        await writer.close()

        let library = CaptureLibrary(directory: tempDir)
        try await library.delete(sequence: location.fileSequence)

        do {
            _ = try await library.record(at: location)
            XCTFail("leer los bytes de una captura borrada debería fallar")
        } catch let error as CaptureLibraryError {
            // Es el mismo caso que borrar algo que ya no está, y a propósito: el hecho es idéntico
            // —esa secuencia no está—, y lo que cambia es la copia de cada pantalla.
            XCTAssertEqual(error, .notFound(location.fileSequence))
        }
    }

    func testAnOffsetInsideTheFileHeaderIsRejectedWithoutOpeningAnything() async throws {
        let writer = try makeWriter()
        _ = try await writer.write(packet: packet(16), originalLength: 16, timestamp: 1)
        await writer.close()

        let library = CaptureLibrary(directory: tempDir)

        // Ningún registro puede vivir delante de la cabecera global, que es justo la propiedad que
        // hace del 0 un centinela seguro en el ring y en el store.
        for offset in [UInt64(0), 23] {
            do {
                _ = try await library.record(at: CaptureLocation(fileSequence: 0, recordOffset: offset))
                XCTFail("un offset dentro de la cabecera global no es un registro")
            } catch let error as CaptureLibraryError {
                guard case .recordUnreadable = error else {
                    return XCTFail("error inesperado: \(error)")
                }
            }
        }
    }

    func testAnOffsetPastTheEndOfTheFileIsUnreadable() async throws {
        let writer = try makeWriter()
        _ = try await writer.write(packet: packet(16), originalLength: 16, timestamp: 1)
        await writer.close()

        do {
            _ = try await CaptureLibrary(directory: tempDir)
                .record(at: CaptureLocation(fileSequence: 0, recordOffset: 4_096))
            XCTFail("leer más allá del final debería fallar")
        } catch let error as CaptureLibraryError {
            guard case .recordUnreadable = error else {
                return XCTFail("error inesperado: \(error)")
            }
        }
    }

    /// Un fichero se puede quedar a medias: la extensión puede morir entre la cabecera del registro y
    /// sus bytes. Entonces la lectura falla en vez de devolver medio paquete rellenado con lo que haya.
    func testARecordCutShortByADyingWriterIsUnreadable() async throws {
        let writer = try makeWriter()
        let location = try await writer.write(packet: packet(64), originalLength: 64, timestamp: 1)
        await writer.close()

        let url = try XCTUnwrap(CaptureDirectory.url(forSequence: 0, in: tempDir))
        let handle = try FileHandle(forWritingTo: url)
        // Se corta a la mitad del payload: la cabecera del registro sigue diciendo 64 bytes.
        try handle.truncate(atOffset: location.recordOffset + 16 + 30)
        try handle.close()

        do {
            _ = try await CaptureLibrary(directory: tempDir).record(at: location)
            XCTFail("un registro a medias no se puede enseñar")
        } catch let error as CaptureLibraryError {
            guard case .recordUnreadable(let detail) = error else {
                return XCTFail("error inesperado: \(error)")
            }
            XCTAssertTrue(detail.contains("30"), "el detalle dice cuánto había: \(detail)")
        }
    }

    func testARecordLongerThanTheFilesSnaplenIsRejectedBeforeReservingMemory() async throws {
        let writer = try PcapWriter(config: .init(directory: tempDir, snaplen: 64, maxFileBytes: .max))
        let location = try await writer.write(packet: packet(64), originalLength: 64, timestamp: 1)
        await writer.close()

        // Se falsea el `incl_len` del registro a 4 GB. Sin el tope, leerlo sería intentar reservar
        // esa memoria por culpa de un fichero corrupto.
        let url = try XCTUnwrap(CaptureDirectory.url(forSequence: 0, in: tempDir))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: location.recordOffset + 8)
        try handle.write(contentsOf: Data([0xff, 0xff, 0xff, 0xff]))
        try handle.close()

        do {
            _ = try await CaptureLibrary(directory: tempDir).record(at: location)
            XCTFail("un registro mayor que el snaplen del fichero no es válido")
        } catch let error as CaptureLibraryError {
            guard case .recordUnreadable(let detail) = error else {
                return XCTFail("error inesperado: \(error)")
            }
            XCTAssertTrue(detail.contains("64"), "el detalle nombra el snaplen: \(detail)")
        }
    }

    func testAFileThatIsNotOneOfOursIsRejectedByItsHeader() async throws {
        let name = CaptureFileName.make(sequence: 3, date: Date(timeIntervalSince1970: 0))
        try Data(repeating: 0x00, count: 512).write(to: tempDir.appendingPathComponent(name))

        do {
            _ = try await CaptureLibrary(directory: tempDir)
                .record(at: CaptureLocation(fileSequence: 3, recordOffset: 24))
            XCTFail("un fichero con otra cabecera no se puede leer como captura nuestra")
        } catch let error as CaptureLibraryError {
            guard case .recordUnreadable(let detail) = error else {
                return XCTFail("error inesperado: \(error)")
            }
            XCTAssertTrue(detail.contains("unknownMagic"), "el detalle dice qué pasó: \(detail)")
        }
    }

    func testReadingARecordAlsoNeedsTheContainerToResolve() async {
        let library = CaptureLibrary(resolvingDirectory: {
            throw CaptureLibraryError.containerUnavailable("group.test")
        })

        do {
            _ = try await library.record(at: CaptureLocation(fileSequence: 0, recordOffset: 24))
            XCTFail("leer sin contenedor debería fallar")
        } catch let error as CaptureLibraryError {
            // Y se distingue de "el fichero no está": no se sabe siquiera dónde mirar, así que la
            // pantalla no puede decir que los bytes se borraron.
            XCTAssertEqual(error, .containerUnavailable("group.test"))
        } catch {
            XCTFail("error inesperado: \(error)")
        }
    }
}
