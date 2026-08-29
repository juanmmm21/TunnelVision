import Foundation
import XCTest
import Shared

/// Tests del camino de vuelta al contenido descifrado: de una fila del índice a los bytes que nombra
/// (pieza 4). Van contra ficheros escritos por un `PlaintextWriter` **real** sobre un directorio
/// temporal, como los de `CaptureLibraryTests` y por el mismo motivo: lo que hay que ejercitar es el
/// acoplamiento entre las dos mitades —la que escribe, en la extensión, y la que lee, en la app—, que
/// es donde el formato tiene que significar lo mismo en los dos lados. Un fichero inventado a mano
/// solo aparece donde hace falta un fichero **imposible** de escribir (uno corrupto).
final class PlaintextLibraryTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plaintext-library-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    // MARK: - Utilidades

    private func makeWriter(
        maxRecordBytes: UInt32 = 64 * 1024,
        maxFileBytes: UInt64 = 16 * 1024 * 1024
    ) -> PlaintextWriter {
        PlaintextWriter(
            config: .init(directory: tempDir, maxRecordBytes: maxRecordBytes, maxFileBytes: maxFileBytes)
        )
    }

    /// Un trozo **reconocible**: cada conversación lleva su propio byte de relleno, que es lo que
    /// permite afirmar que una localización llevó a *sus* bytes y no a los del vecino.
    private func content(_ length: Int, filledWith byte: UInt8) -> Data {
        Data(repeating: byte, count: length)
    }

    /// La fila del índice tal y como el volcado la habría escrito para ese registro. Los tests la
    /// construyen a mano en vez de pasar por el store: lo que se prueba aquí es el lector de ficheros,
    /// y meter una BD por medio ejercitaría otra cosa (eso ya lo hace `PlaintextIndexTests`).
    private func row(
        at location: PlaintextLocation,
        stream: UInt64,
        stored: UInt32,
        original: UInt32? = nil,
        id: Int64 = 1,
        direction: Direction = .outbound
    ) -> StoredPlaintextChunk {
        StoredPlaintextChunk(
            id: id,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            direction: direction,
            stream: stream,
            location: location,
            storedLength: stored,
            originalLength: original ?? stored
        )
    }

    private func expectError(
        _ expected: PlaintextLibraryError,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        from body: () async throws -> PlaintextRecord
    ) async {
        do {
            _ = try await body()
            XCTFail("se esperaba \(expected): \(message)", file: file, line: line)
        } catch let error as PlaintextLibraryError {
            XCTAssertEqual(error, expected, message, file: file, line: line)
        } catch {
            XCTFail("error inesperado \(error): \(message)", file: file, line: line)
        }
    }

    /// El caso del error cuyo texto lleva el detalle del sistema o del parser: se afirma **cuál** es,
    /// no cómo está redactado — es diagnóstico, no copia.
    private func expectUnreadable(
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        from body: () async throws -> PlaintextRecord
    ) async {
        do {
            _ = try await body()
            XCTFail("se esperaba recordUnreadable: \(message)", file: file, line: line)
        } catch let error as PlaintextLibraryError {
            guard case .recordUnreadable = error else {
                return XCTFail("error inesperado \(error): \(message)", file: file, line: line)
            }
        } catch {
            XCTFail("error inesperado \(error): \(message)", file: file, line: line)
        }
    }

    private func expectMismatch(
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        from body: () async throws -> PlaintextRecord
    ) async {
        do {
            let record = try await body()
            XCTFail("se esperaba recordMismatch y llegaron \(record.bytes.count) bytes: \(message)",
                    file: file, line: line)
        } catch let error as PlaintextLibraryError {
            guard case .recordMismatch = error else {
                return XCTFail("error inesperado \(error): \(message)", file: file, line: line)
            }
        } catch {
            XCTFail("error inesperado \(error): \(message)", file: file, line: line)
        }
    }

    // MARK: - El camino de vuelta

    func testALocationLeadsBackToItsOwnBytes() async throws {
        let writer = makeWriter()
        let stream = await writer.openStream()
        let sent = content(320, filledWith: 0xA1)
        let location = try await writer.write(
            sent,
            stream: stream,
            direction: .outbound,
            timestamp: 1_700_000_000_000_000_000
        )
        await writer.close()

        let library = PlaintextLibrary(directory: tempDir)
        let record = try await library.record(
            for: row(at: try XCTUnwrap(location), stream: stream, stored: 320)
        )

        XCTAssertEqual(record.bytes, sent)
        XCTAssertEqual(record.stream, stream)
        XCTAssertEqual(record.direction, .outbound)
        XCTAssertEqual(record.storedLength, 320)
        XCTAssertEqual(record.originalLength, 320)
        XCTAssertFalse(record.isTruncated)
        XCTAssertEqual(record.droppedLength, 0)
        XCTAssertEqual(record.location, location)
        // El fichero fecha en absoluto, al contrario que el `.pcap`: sobrevive a la sesión que lo
        // escribió, así que su sello vale por sí solo sin el ancla de aquella.
        XCTAssertEqual(record.date.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
    }

    /// Lo que el formato existe para poder hacer: un fichero **intercala conversaciones**, así que
    /// leer por offset tiene que dar el registro de esta y no el del vecino de al lado.
    func testALocationLeadsToItsOwnRecordAmongInterleavedConversations() async throws {
        let writer = makeWriter()
        let first = await writer.openStream()
        let second = await writer.openStream()

        let firstRequest = try await writer.write(
            content(64, filledWith: 0x11), stream: first, direction: .outbound, timestamp: 1_000
        )
        _ = try await writer.write(
            content(128, filledWith: 0x22), stream: second, direction: .outbound, timestamp: 2_000
        )
        let firstResponse = try await writer.write(
            content(96, filledWith: 0x33), stream: first, direction: .inbound, timestamp: 3_000
        )
        await writer.close()

        let library = PlaintextLibrary(directory: tempDir)
        let request = try await library.record(
            for: row(at: try XCTUnwrap(firstRequest), stream: first, stored: 64)
        )
        let response = try await library.record(
            for: row(at: try XCTUnwrap(firstResponse), stream: first, stored: 96, direction: .inbound)
        )

        XCTAssertEqual(request.bytes, content(64, filledWith: 0x11))
        XCTAssertEqual(request.direction, .outbound)
        XCTAssertEqual(response.bytes, content(96, filledWith: 0x33), "el registro de en medio es de otra conversación")
        XCTAssertEqual(response.direction, .inbound)
        XCTAssertEqual(response.stream, first)
    }

    /// La rotación es lo que hace que un offset por sí solo no identifique nada: los dos ficheros
    /// tienen un registro en el mismo sitio y solo la pareja fichero+offset los separa.
    func testTheFileSequenceIsWhatSeparatesTwoRecordsAtTheSameOffset() async throws {
        let writer = makeWriter()
        let stream = await writer.openStream()
        let first = try await writer.write(
            content(48, filledWith: 0xAA), stream: stream, direction: .outbound, timestamp: 1_000
        )
        try await writer.rotate()
        let second = try await writer.write(
            content(48, filledWith: 0xBB), stream: stream, direction: .outbound, timestamp: 2_000
        )
        await writer.close()

        let firstLocation = try XCTUnwrap(first)
        let secondLocation = try XCTUnwrap(second)
        XCTAssertEqual(firstLocation.recordOffset, secondLocation.recordOffset, "cada fichero reinicia sus offsets")
        XCTAssertNotEqual(firstLocation.fileSequence, secondLocation.fileSequence)

        let library = PlaintextLibrary(directory: tempDir)
        let older = try await library.record(for: row(at: firstLocation, stream: stream, stored: 48))
        let newer = try await library.record(for: row(at: secondLocation, stream: stream, stored: 48))

        XCTAssertEqual(older.bytes, content(48, filledWith: 0xAA))
        XCTAssertEqual(newer.bytes, content(48, filledWith: 0xBB))
    }

    /// Lo recortado se lee entero **de lo que hay**, y las dos longitudes dicen cuánto falta: es lo
    /// único que la pantalla tiene para no enseñar un trozo a medias como si fuera todo.
    func testATruncatedRecordComesBackWithItsBeginningAndBothLengths() async throws {
        let writer = makeWriter(maxRecordBytes: 128)
        let stream = await writer.openStream()
        let body = content(1_000, filledWith: 0x5A)
        let location = try await writer.write(
            body, stream: stream, direction: .inbound, timestamp: 4_000
        )
        await writer.close()

        let library = PlaintextLibrary(directory: tempDir)
        let record = try await library.record(
            for: row(
                at: try XCTUnwrap(location),
                stream: stream,
                stored: 128,
                original: 1_000,
                direction: .inbound
            )
        )

        XCTAssertEqual(record.bytes, body.prefix(128), "se guarda el principio")
        XCTAssertEqual(record.storedLength, 128)
        XCTAssertEqual(record.originalLength, 1_000)
        XCTAssertTrue(record.isTruncated)
        XCTAssertEqual(record.droppedLength, 872)
    }

    // MARK: - Lo que ya no está

    /// El caso **normal**, no una avería: el contenido descifrado caduca mucho antes que el historial
    /// (ADR 0007), así que una conexión sigue en la Timeline con sus bytes ya barridos.
    func testAFileTheSweepAlreadyTookIsNotFound() async throws {
        let writer = makeWriter()
        let stream = await writer.openStream()
        let written = try await writer.write(
            content(64, filledWith: 0xC3), stream: stream, direction: .outbound, timestamp: 1_000
        )
        await writer.close()
        let location = try XCTUnwrap(written)

        let url = try XCTUnwrap(PlaintextDirectory.url(forSequence: location.fileSequence, in: tempDir))
        try FileManager.default.removeItem(at: url)

        let library = PlaintextLibrary(directory: tempDir)
        await expectError(.notFound(location.fileSequence), "un fichero barrido no está roto: no está") {
            try await library.record(for: self.row(at: location, stream: stream, stored: 64))
        }
    }

    func testAnUnresolvableContainerIsItsOwnFailure() async {
        let library = PlaintextLibrary(resolvingDirectory: {
            throw PlaintextLibraryError.containerUnavailable("group.test.missing")
        })
        await expectError(.containerUnavailable("group.test.missing"), "no saber dónde mirar no es 'no hay nada'") {
            try await library.record(
                for: self.row(
                    at: PlaintextLocation(fileSequence: 0, recordOffset: 16),
                    stream: 0,
                    stored: 10
                )
            )
        }
    }

    // MARK: - Lo que no se cree

    /// La comprobación que hace de `recordOffset == 0` un centinela seguro: ningún registro puede
    /// empezar dentro de la cabecera global, así que ni se abre el fichero.
    func testAnOffsetInsideTheFileHeaderIsRefusedWithoutOpeningAnything() async throws {
        let writer = makeWriter()
        let stream = await writer.openStream()
        _ = try await writer.write(
            content(64, filledWith: 0x01), stream: stream, direction: .outbound, timestamp: 1_000
        )
        await writer.close()

        let library = PlaintextLibrary(directory: tempDir)
        await expectUnreadable("un 0 es 'sin contenido', nunca una posición") {
            try await library.record(
                for: self.row(
                    at: PlaintextLocation(fileSequence: 0, recordOffset: 0),
                    stream: stream,
                    stored: 64
                )
            )
        }
    }

    /// Lo que la `recordMagic` existe para convertir en una respuesta clara: un offset desfasado da
    /// bytes que no son la cabecera de nada.
    func testAnOffsetThatIsNotARecordStartIsRefused() async throws {
        let writer = makeWriter()
        let stream = await writer.openStream()
        let written = try await writer.write(
            content(64, filledWith: 0x02), stream: stream, direction: .outbound, timestamp: 1_000
        )
        await writer.close()
        let location = try XCTUnwrap(written)

        let library = PlaintextLibrary(directory: tempDir)
        await expectUnreadable("en medio de una cabecera no empieza ningún registro") {
            try await library.record(
                for: self.row(
                    at: PlaintextLocation(
                        fileSequence: location.fileSequence,
                        recordOffset: location.recordOffset + 8
                    ),
                    stream: stream,
                    stored: 64
                )
            )
        }
    }

    /// El error que sostiene todo lo demás: hay un registro legible ahí, pero es de **otra**
    /// conversación. Enseñarlo bajo la cabecera de esta sería la peor avería posible de este producto.
    func testARecordFromAnotherConversationIsRefusedInsteadOfShown() async throws {
        let writer = makeWriter()
        let mine = await writer.openStream()
        let theirs = await writer.openStream()
        _ = try await writer.write(
            content(64, filledWith: 0x11), stream: mine, direction: .outbound, timestamp: 1_000
        )
        let written = try await writer.write(
            content(64, filledWith: 0x22), stream: theirs, direction: .outbound, timestamp: 2_000
        )
        await writer.close()
        let neighbour = try XCTUnwrap(written)

        let library = PlaintextLibrary(directory: tempDir)
        await expectMismatch("la fila dice una conversación y el registro dice otra") {
            try await library.record(for: self.row(at: neighbour, stream: mine, stored: 64))
        }
    }

    /// La otra mitad de la validación: la misma conversación, pero un registro que no mide lo que la
    /// fila dice — así que no es *este* trozo.
    func testARecordWhoseLengthsDisagreeWithTheRowIsRefused() async throws {
        let writer = makeWriter()
        let stream = await writer.openStream()
        let written = try await writer.write(
            content(64, filledWith: 0x31), stream: stream, direction: .outbound, timestamp: 1_000
        )
        _ = try await writer.write(
            content(200, filledWith: 0x32), stream: stream, direction: .inbound, timestamp: 2_000
        )
        await writer.close()
        let first = try XCTUnwrap(written)

        let library = PlaintextLibrary(directory: tempDir)
        await expectMismatch("mismo stream, otro trozo") {
            try await library.record(for: self.row(at: first, stream: stream, stored: 200))
        }
        await expectMismatch("lo que se recortó también identifica al registro") {
            try await library.record(
                for: self.row(at: first, stream: stream, stored: 64, original: 900)
            )
        }
    }

    // MARK: - Ficheros que no se pueden escribir

    /// Un fichero que no es nuestro. Se rechaza en vez de interpretarlo: el único productor es
    /// `PlaintextWriter`.
    func testAForeignFileIsRefusedByItsMagic() async throws {
        var data = Data([0x50, 0x4B, 0x03, 0x04])          // un zip, no un `.tvpt`
        data.append(Data(repeating: 0, count: 12 + PlaintextFormat.recordHeaderSize))
        try data.write(to: tempDir.appendingPathComponent(PlaintextFileName.make(sequence: 0, date: Date())))

        let library = PlaintextLibrary(directory: tempDir)
        await expectUnreadable("una cabecera global ajena no se interpreta") {
            try await library.record(
                for: self.row(
                    at: PlaintextLocation(fileSequence: 0, recordOffset: 16),
                    stream: 0,
                    stored: 0
                )
            )
        }
    }

    /// El tope del fichero es lo que acota la lectura **antes** de reservar memoria: un registro que
    /// dice medir más que el `maxRecordBytes` de su fichero es corrupción, no un trozo grande.
    func testARecordClaimingMoreThanTheFileAllowsIsRefusedBeforeAllocating() async throws {
        var data = PlaintextFormat.globalHeader(maxRecordBytes: 64)
        data.append(
            PlaintextFormat.recordHeader(
                stream: 7,
                timestamp: 1_000,
                storedLength: 4_000_000_000,
                originalLength: 4_000_000_000,
                direction: .outbound
            )
        )
        try data.write(to: tempDir.appendingPathComponent(PlaintextFileName.make(sequence: 0, date: Date())))

        let library = PlaintextLibrary(directory: tempDir)
        await expectUnreadable("un fichero corrupto no puede pedir memoria") {
            try await library.record(
                for: self.row(
                    at: PlaintextLocation(fileSequence: 0, recordOffset: 16),
                    stream: 7,
                    stored: 4_000_000_000
                )
            )
        }
    }

    /// Un fichero que se quedó a medias: la extensión pudo morir escribiendo. La cabecera promete
    /// bytes que no están, y decirlo es mejor que devolver medio trozo como si fuera entero.
    func testARecordCutShortOnDiskIsRefused() async throws {
        let writer = makeWriter()
        let stream = await writer.openStream()
        let written = try await writer.write(
            content(256, filledWith: 0x77), stream: stream, direction: .outbound, timestamp: 1_000
        )
        await writer.close()
        let location = try XCTUnwrap(written)

        let url = try XCTUnwrap(PlaintextDirectory.url(forSequence: location.fileSequence, in: tempDir))
        let whole = try Data(contentsOf: url)
        try whole.prefix(whole.count - 100).write(to: url)

        let library = PlaintextLibrary(directory: tempDir)
        await expectUnreadable("la cabecera promete 256 bytes y en el disco hay 156") {
            try await library.record(for: self.row(at: location, stream: stream, stored: 256))
        }
    }
}
