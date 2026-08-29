import Foundation
import XCTest
import Shared

/// Tests del export del listado de conexiones (M9) contra ficheros **de verdad** sobre un directorio
/// temporal: lo que se afirma es lo que queda escrito en disco y se puede volver a leer.
///
/// El historial entra guionizado —una closure de páginas— y no como `HistoryReader` real, porque lo
/// que hay que ejercitar aquí es justo lo que un store sano no sabe hacer: quedarse a medias, tener
/// más filas de las que caben en el tope, o no dejarse leer. El acoplamiento contra el lector real
/// tiene su propio test al final, que es el que demuestra que las dos mitades encajan.
final class FlowExporterTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-export-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Utilidades

    /// Un historial de mentira de `count` conexiones, paginado como lo haría el lector: devuelve
    /// menos de las pedidas cuando se acaba.
    private func pages(_ count: Int) -> FlowExporter.PageProvider {
        let flows = (0..<count).map { index in
            HistoryFixtures.historyFlow(
                id: Int64(index + 1),
                remote: HistoryFixtures.remote(UInt8(index % 200)),
                // `lastSeen` decreciente: el historial va del más reciente al más antiguo, y el
                // cursor de la página siguiente sale de la última fila entregada.
                firstSeen: 0,
                lastSeen: UInt64(count - index)
            )
        }
        return { limit, cursor in
            let start = cursor.map { c in flows.firstIndex { $0.id == c.id }.map { $0 + 1 } ?? 0 } ?? 0
            guard start < flows.count else { return [] }
            return Array(flows[start..<min(start + limit, flows.count)])
        }
    }

    private func decode(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "el fichero escrito no es un objeto JSON"
        )
    }

    // MARK: - El fichero escrito

    func testWritesEveryConnectionAndTheFileParsesBack() async throws {
        let exporter = FlowExporter(directory: tempDir, limit: 100, pageSize: 7)

        let result = try await exporter.export(
            now: HistoryFixtures.anchorWallClock, pages: pages(20)
        )

        XCTAssertEqual(result.connectionCount, 20)
        XCTAssertFalse(result.truncated)
        XCTAssertGreaterThan(result.byteCount, 0)

        let object = try decode(result.url)
        XCTAssertEqual((object["connections"] as? [[String: Any]])?.count, 20)
        XCTAssertEqual(object["connectionCount"] as? Int, 20)
        XCTAssertEqual(object["truncated"] as? Bool, false)
    }

    func testAnEmptyHistoryStillWritesAValidFile() async throws {
        // El fichero se escribe igual y es JSON válido; que no se le ofrezca al usuario es decisión
        // del view model, no de aquí — este servicio no puede saber qué se hace con lo que escribe.
        let exporter = FlowExporter(directory: tempDir)

        let result = try await exporter.export(pages: pages(0))

        XCTAssertEqual(result.connectionCount, 0)
        XCTAssertFalse(result.truncated)
        XCTAssertEqual((try decode(result.url)["connections"] as? [[String: Any]])?.count, 0)
    }

    func testTheFileNameCarriesTheExportInstant() async throws {
        let exporter = FlowExporter(directory: tempDir)

        let result = try await exporter.export(
            now: Date(timeIntervalSince1970: 1_700_000_000), pages: pages(1)
        )

        XCTAssertEqual(result.url.lastPathComponent, "tunnelvision-connections-20231114-221320.json")
        XCTAssertEqual(result.url.deletingLastPathComponent().standardizedFileURL, tempDir.standardizedFileURL)
    }

    // MARK: - Paginación y tope

    func testPagesAreChainedWithoutRepeatingOrSkippingConnections() async throws {
        // Con páginas de 7 sobre 20 conexiones, el encadenado por cursor es lo único que hace que
        // salgan las 20 y ninguna dos veces.
        let exporter = FlowExporter(directory: tempDir, limit: 100, pageSize: 7)

        let result = try await exporter.export(pages: pages(20))

        let connections = try XCTUnwrap(decode(result.url)["connections"] as? [[String: Any]])
        let ids = connections.compactMap { $0["id"] as? Int64 }
        XCTAssertEqual(ids, Array(1...20).map(Int64.init))
    }

    func testTheCapCutsTheExportAndTheFileSaysSo() async throws {
        let exporter = FlowExporter(directory: tempDir, limit: 5, pageSize: 4)

        let result = try await exporter.export(pages: pages(20))

        XCTAssertEqual(result.connectionCount, 5)
        XCTAssertTrue(result.truncated)

        let object = try decode(result.url)
        XCTAssertEqual(object["connectionCount"] as? Int, 5)
        XCTAssertEqual(object["truncated"] as? Bool, true)
        // Son las **más recientes**: es el trozo que alguien que exporta quiere de verdad.
        let ids = (object["connections"] as? [[String: Any]])?.compactMap { $0["id"] as? Int64 }
        XCTAssertEqual(ids, [1, 2, 3, 4, 5])
    }

    func testAHistoryThatEndsExactlyAtTheCapIsNotReportedAsTruncated() async throws {
        // El caso que se lee mal si `truncated` se deduce del recuento: hay exactamente cinco
        // conexiones y el tope son cinco. Decir "recortado" aquí sería inventarse un historial.
        let exporter = FlowExporter(directory: tempDir, limit: 5, pageSize: 5)

        let result = try await exporter.export(pages: pages(5))

        XCTAssertEqual(result.connectionCount, 5)
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(try decode(result.url)["truncated"] as? Bool, false)
    }

    func testTheHistoryIsNeverAskedForMoreThanTheCap() async throws {
        // El tope acota el trabajo, no solo la salida: pedir páginas enteras para tirarlas sería
        // recorrer la BD entera igualmente.
        let asked = Asked()
        let backing = pages(1_000)
        let exporter = FlowExporter(directory: tempDir, limit: 10, pageSize: 8)

        _ = try await exporter.export { limit, cursor in
            await asked.record(limit)
            return try await backing(limit, cursor)
        }

        let limits = await asked.limits
        // Dos páginas (8 + 2) y la pregunta de una sola fila que decide si hubo recorte.
        XCTAssertEqual(limits, [8, 2, 1])
    }

    // MARK: - Fallos

    func testAHistoryThatFailsMidwayLeavesNoHalfWrittenFile() async throws {
        // Un JSON sin cerrar es peor que ningún fichero: quien lo abriese no vería un error, vería
        // un historial que se acaba antes de tiempo.
        let exporter = FlowExporter(directory: tempDir, limit: 100, pageSize: 4)
        let backing = pages(20)

        do {
            _ = try await exporter.export { limit, cursor in
                let page = try await backing(limit, cursor)
                guard page.first?.id == 1 else { throw HistoryError.queryFailed("db is locked") }
                return page
            }
            XCTFail("un historial que falla a mitad debería propagar el fallo")
        } catch let error as FlowExportError {
            XCTAssertEqual(error, .historyUnreadable(.queryFailed("db is locked")))
        }

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(leftovers, [], "no debería quedar un fichero a medias")
    }

    func testAnUnreachableDirectoryIsAWriteFailureAndNotACrash() async throws {
        let exporter = FlowExporter(
            resolvingDirectory: { throw CaptureLibraryError.containerUnavailable("group.test") }
        )

        do {
            _ = try await exporter.export(pages: pages(1))
            XCTFail("sin directorio no se puede exportar")
        } catch let error as FlowExportError {
            guard case .writeFailed = error else {
                return XCTFail("un directorio irresoluble es un fallo de escritura, no de historial")
            }
        }
    }

    // MARK: - Limpieza

    func testEachExportTakesThepreviousOneWithIt() async throws {
        // Acumularlos convertiría el temporal en un almacén silencioso de copias del historial.
        let exporter = FlowExporter(directory: tempDir)

        let first = try await exporter.export(
            now: Date(timeIntervalSince1970: 1_700_000_000), pages: pages(2)
        )
        let second = try await exporter.export(
            now: Date(timeIntervalSince1970: 1_700_003_600), pages: pages(2)
        )

        XCTAssertNotEqual(first.url, second.url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
    }

    func testCleaningUpTouchesNothingItDidNotWrite() async throws {
        let stranger = tempDir.appendingPathComponent("tunnelvision-000001-20231114-221320.pcap")
        try Data("not ours".utf8).write(to: stranger)
        let exporter = FlowExporter(directory: tempDir)

        _ = try await exporter.export(pages: pages(1))

        XCTAssertTrue(FileManager.default.fileExists(atPath: stranger.path))
    }

    func testTheDirectoryIsCreatedIfItIsNotThereYet() async throws {
        let nested = tempDir.appendingPathComponent("Exports", isDirectory: true)
        let exporter = FlowExporter(directory: nested)

        let result = try await exporter.export(pages: pages(1))

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))
    }

    // MARK: - Contra el historial real

    func testExportsWhatAHistoryReaderReallyHasStored() async throws {
        // La única prueba de que las dos mitades encajan: el lector pagina un `FlowStore` de verdad y
        // lo que sale del store acaba en el fichero, con el reparto de extremos ya hecho.
        let store = try FlowStore(
            databaseURL: tempDir.appendingPathComponent("history.sqlite"),
            anchor: HistoryFixtures.anchor
        )
        _ = try await store.upsertFlow(
            HistoryFixtures.record(
                remote: HistoryFixtures.remote(1), firstSeen: 0, lastSeen: 10, sni: "a.example"
            )
        )
        _ = try await store.upsertFlow(
            HistoryFixtures.record(
                remote: HistoryFixtures.remote(2), remotePort: 80, localPort: 51_001,
                firstSeen: 5, lastSeen: 20, tlsStatus: .plaintext
            )
        )
        _ = try await store.upsertFlow(
            HistoryFixtures.record(
                remote: HistoryFixtures.remote(3), localPort: 51_002, proto: .udp,
                firstSeen: 8, lastSeen: 30
            )
        )
        let reader = HistoryReader(store: store)
        let exporter = FlowExporter(directory: tempDir, limit: 100, pageSize: 2)

        let result = try await exporter.export { limit, cursor in
            try await reader.flowPage(limit: limit, after: cursor)
        }

        XCTAssertEqual(result.connectionCount, 3)
        let connections = try XCTUnwrap(decode(result.url)["connections"] as? [[String: Any]])
        // Del más reciente al más antiguo, que es como pagina el historial.
        XCTAssertEqual(connections.compactMap { $0["protocol"] as? String }, ["udp", "tcp", "tcp"])
        XCTAssertEqual(connections.compactMap { $0["host"] as? String }.last, "a.example")
        // Los extremos salen repartidos: el dispositivo es la IP del túnel.
        let local = try XCTUnwrap(connections[0]["local"] as? [String: Any])
        XCTAssertEqual(local["address"] as? String, HistoryFixtures.deviceIPv4.description)
    }
}

/// Los tamaños de página que se le pidieron al historial. Es un actor porque la closure de páginas es
/// `@Sendable` y se llama desde dentro del exportador.
private actor Asked {
    private(set) var limits: [Int] = []
    func record(_ limit: Int) { limits.append(limit) }
}
