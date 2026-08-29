import Foundation
import XCTest
import Shared

/// Tests del escritor de contenido descifrado. Cubren lo que lo diferencia del de capturas —que no
/// crea fichero hasta que hay algo que guardar, que reparte identificadores de conversación y que no
/// reutiliza secuencias— además de lo que comparte con él: la localización que devuelve cada
/// escritura, el recorte por registro, la rotación por tamaño y los errores tipados.
final class PlaintextWriterTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plaintext-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeWriter(
        maxRecordBytes: UInt32 = 64 * 1024,
        maxFileBytes: UInt64 = 16 * 1024 * 1024,
        highestReferencedSequence: UInt32? = nil,
        highestReferencedStream: UInt64? = nil
    ) -> PlaintextWriter {
        PlaintextWriter(
            config: .init(
                directory: tempDir,
                maxRecordBytes: maxRecordBytes,
                maxFileBytes: maxFileBytes,
                highestReferencedSequence: highestReferencedSequence,
                highestReferencedStream: highestReferencedStream
            )
        )
    }

    // MARK: - Sin contenido no hay fichero

    /// La diferencia de fondo con el escritor de capturas: un túnel que no descifra nada no deja ni un
    /// artefacto en el disco.
    func testNoFileExistsUntilSomethingIsWritten() async throws {
        let writer = makeWriter()

        let before = await writer.files()
        let sequenceBefore = await writer.currentFileSequence
        XCTAssertTrue(before.isEmpty)
        XCTAssertNil(sequenceBefore)

        _ = try await writer.write(Data([1, 2, 3]), stream: 0, direction: .outbound, timestamp: 0)

        let after = await writer.files()
        let sequenceAfter = await writer.currentFileSequence
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(sequenceAfter, 0)
    }

    func testEmptyChunkWritesNothingAndReportsNoLocation() async throws {
        let writer = makeWriter()

        let location = try await writer.write(Data(), stream: 0, direction: .inbound, timestamp: 0)

        let files = await writer.files()
        XCTAssertNil(location)
        XCTAssertTrue(files.isEmpty)
    }

    func testFlushWithoutAnyContentIsNotAFailure() async throws {
        let writer = makeWriter()
        try await writer.flush()
        let files = await writer.files()
        XCTAssertTrue(files.isEmpty)
    }

    // MARK: - Lo que se escribe y dónde queda

    func testWriteReturnsTheRecordLocationAndEncodesTheFields() async throws {
        let writer = makeWriter()
        let stream = await writer.openStream()

        let first = try await writer.write(
            Data("GET / HTTP/1.1\r\n".utf8),
            stream: stream,
            direction: .outbound,
            timestamp: 1_770_000_000_000_000_000
        )
        let second = try await writer.write(
            Data("HTTP/1.1 200 OK\r\n".utf8),
            stream: stream,
            direction: .inbound,
            timestamp: 1_770_000_000_100_000_000
        )
        await writer.close()

        // El primer registro empieza justo detrás de la cabecera global, y el segundo detrás del
        // primero: ese offset es el que la fila del índice guarda.
        XCTAssertEqual(first?.fileSequence, 0)
        XCTAssertEqual(first?.recordOffset, 16)
        XCTAssertEqual(second?.recordOffset, 16 + 32 + 16)

        let files = await writer.files()
        let decoded = try TestPlaintextReader.read(files[0])
        XCTAssertEqual(decoded.magic, PlaintextFormat.magic)
        XCTAssertEqual(decoded.versionMajor, 1)
        XCTAssertEqual(decoded.maxRecordBytes, 64 * 1024)
        XCTAssertEqual(decoded.records.count, 2)

        XCTAssertEqual(decoded.records[0].magic, PlaintextFormat.recordMagic)
        XCTAssertEqual(decoded.records[0].stream, stream)
        XCTAssertEqual(decoded.records[0].timestamp, 1_770_000_000_000_000_000)
        XCTAssertEqual(decoded.records[0].direction, Direction.outbound.rawValue)
        XCTAssertEqual(decoded.records[0].data, Data("GET / HTTP/1.1\r\n".utf8))

        XCTAssertEqual(decoded.records[1].direction, Direction.inbound.rawValue)
        XCTAssertEqual(decoded.records[1].data, Data("HTTP/1.1 200 OK\r\n".utf8))
    }

    /// Un offset guardado tiene que llevar a **su** registro, que es lo que la pareja fichero+offset
    /// existe para garantizar: se lee el fichero por donde dice la localización y se comprueba que lo
    /// que hay ahí es el trozo que se escribió.
    func testALocationLeadsBackToItsOwnRecord() async throws {
        let writer = makeWriter()
        let alice = await writer.openStream()
        let bob = await writer.openStream()

        // Intercalados a propósito: un fichero lleva muchas conversaciones a la vez.
        _ = try await writer.write(Data("alice-1".utf8), stream: alice, direction: .outbound, timestamp: 1)
        let target = try await writer.write(Data("bob-1".utf8), stream: bob, direction: .outbound, timestamp: 2)
        _ = try await writer.write(Data("alice-2".utf8), stream: alice, direction: .inbound, timestamp: 3)
        await writer.close()

        let location = try XCTUnwrap(target)
        let url = try XCTUnwrap(PlaintextDirectory.url(forSequence: location.fileSequence, in: tempDir))
        let bytes = try Data(contentsOf: url)
        let start = Int(location.recordOffset)

        let header = try PlaintextFormat.recordHeader(parsing: bytes[start...])
        XCTAssertEqual(header.stream, bob)
        XCTAssertEqual(header.direction, .outbound)

        let payloadStart = start + PlaintextFormat.recordHeaderSize
        let payload = bytes[payloadStart..<(payloadStart + Int(header.storedLength))]
        XCTAssertEqual(Data(payload), Data("bob-1".utf8))
    }

    func testRecordIsCutAtMaxRecordBytesAndSaysSo() async throws {
        let writer = makeWriter(maxRecordBytes: 8)
        _ = try await writer.write(
            Data(repeating: 0xAB, count: 100),
            stream: 0,
            direction: .inbound,
            timestamp: 0
        )
        await writer.close()

        let files = await writer.files()
        let decoded = try TestPlaintextReader.read(files[0])
        XCTAssertEqual(decoded.records[0].storedLength, 8)
        XCTAssertEqual(decoded.records[0].originalLength, 100)
        XCTAssertEqual(decoded.records[0].data, Data(repeating: 0xAB, count: 8))
    }

    // MARK: - Identificadores de conversación

    func testStreamIdentifiersAreHandedOutOnceEach() async {
        let writer = makeWriter()
        var seen: Set<UInt64> = []
        for _ in 0..<100 {
            let stream = await writer.openStream()
            XCTAssertTrue(seen.insert(stream).inserted)
        }
    }

    /// Por lo mismo que la secuencia de fichero: si los identificadores volvieran a empezar en cada
    /// sesión, el contenido de una conversación de ayer se leería como el de otra de hoy.
    func testStreamIdentifiersStartAboveWhatTheIndexReferences() async {
        let writer = makeWriter(highestReferencedStream: 41)
        let stream = await writer.openStream()
        XCTAssertEqual(stream, 42)
    }

    // MARK: - Rotación y secuencias

    func testRotationBySizeProducesIndependentFiles() async throws {
        let writer = makeWriter(maxFileBytes: 100)

        for index in 0..<4 {
            _ = try await writer.write(
                Data(repeating: UInt8(index), count: 40),
                stream: 0,
                direction: .outbound,
                timestamp: Int64(index)
            )
        }
        await writer.close()

        let files = await writer.files()
        XCTAssertGreaterThan(files.count, 1)
        for url in files {
            let decoded = try TestPlaintextReader.read(url)
            XCTAssertEqual(decoded.magic, PlaintextFormat.magic)
            XCTAssertFalse(decoded.records.isEmpty, "un fichero rotado sin registros sería un fichero vacío")
        }
        // Ningún registro se pierde ni se duplica al rotar.
        let total = try files.reduce(0) { try $0 + TestPlaintextReader.read($1).records.count }
        XCTAssertEqual(total, 4)
    }

    /// Rotar no abre el fichero siguiente: solo lo abre la escritura que venga después, si viene.
    func testManualRotationLeavesNoEmptyFileBehind() async throws {
        let writer = makeWriter()
        _ = try await writer.write(Data([1]), stream: 0, direction: .outbound, timestamp: 0)
        try await writer.rotate()

        let afterRotate = await writer.files()
        let sequenceAfterRotate = await writer.currentFileSequence
        XCTAssertEqual(afterRotate.count, 1)
        XCTAssertNil(sequenceAfterRotate)

        _ = try await writer.write(Data([2]), stream: 0, direction: .outbound, timestamp: 1)
        let afterWrite = await writer.files()
        let sequenceAfterWrite = await writer.currentFileSequence
        XCTAssertEqual(afterWrite.count, 2)
        XCTAssertEqual(sequenceAfterWrite, 1)
    }

    func testRotationWithNothingOpenIsANoOp() async throws {
        let writer = makeWriter()
        try await writer.rotate()
        let files = await writer.files()
        XCTAssertTrue(files.isEmpty)
    }

    func testSequenceStartsAboveTheFilesAlreadyOnDisk() async throws {
        let stale = tempDir.appendingPathComponent(
            PlaintextFileName.make(sequence: 12, date: Date())
        )
        try Data(PlaintextFormat.globalHeader(maxRecordBytes: 64)).write(to: stale)

        let writer = makeWriter()
        let location = try await writer.write(Data([1]), stream: 0, direction: .inbound, timestamp: 0)

        XCTAssertEqual(location?.fileSequence, 13)
    }

    /// Un fichero borrado desaparece del disco, pero las filas que lo apuntaban siguen en la BD:
    /// reutilizar su número les daría el contenido de otra conversación.
    func testSequenceStartsAboveWhatTheIndexReferencesEvenIfItsFileIsGone() async throws {
        let writer = makeWriter(highestReferencedSequence: 30)
        let location = try await writer.write(Data([1]), stream: 0, direction: .inbound, timestamp: 0)

        XCTAssertEqual(location?.fileSequence, 31)
    }

    // MARK: - Errores

    func testWritingAfterCloseFails() async throws {
        let writer = makeWriter()
        _ = try await writer.write(Data([1]), stream: 0, direction: .outbound, timestamp: 0)
        await writer.close()

        do {
            _ = try await writer.write(Data([2]), stream: 0, direction: .outbound, timestamp: 1)
            XCTFail("se esperaba .closed")
        } catch {
            XCTAssertEqual(error as? PlaintextWriter.PlaintextWriteError, .closed)
        }
    }

    func testAnUnwritableDirectoryFailsToOpen() async throws {
        let writer = PlaintextWriter(
            config: .init(directory: URL(fileURLWithPath: "/dev/null/nope"), maxRecordBytes: 64)
        )

        do {
            _ = try await writer.write(Data([1]), stream: 0, direction: .outbound, timestamp: 0)
            XCTFail("se esperaba .openFailed")
        } catch {
            XCTAssertEqual(error as? PlaintextWriter.PlaintextWriteError, .openFailed)
        }
    }

    func testSequenceExhaustionIsReportedInsteadOfReused() async throws {
        let writer = makeWriter(highestReferencedSequence: .max)

        do {
            _ = try await writer.write(Data([1]), stream: 0, direction: .outbound, timestamp: 0)
            XCTFail("se esperaba .sequenceExhausted")
        } catch {
            XCTAssertEqual(error as? PlaintextWriter.PlaintextWriteError, .sequenceExhausted)
        }
    }

    // MARK: - Streaming

    /// La invariante del escritor: solo hay un registro en vuelo, así que el fichero crece con lo
    /// escrito y la memoria residente no. Se afirma por el tamaño exacto del fichero, que es lo
    /// observable desde fuera.
    func testFileGrowsExactlyByHeaderPlusContent() async throws {
        let writer = makeWriter()
        let chunk = Data(repeating: 0x5A, count: 1_000)

        for index in 0..<50 {
            _ = try await writer.write(chunk, stream: 0, direction: .outbound, timestamp: Int64(index))
        }
        await writer.close()

        let files = await writer.files()
        let url = try XCTUnwrap(files.first)
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertEqual(size, 16 + 50 * (32 + 1_000))
    }
}
