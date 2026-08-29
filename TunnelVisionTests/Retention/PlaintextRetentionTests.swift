import Foundation
import XCTest
@testable import Shared

/// Tests del barrido del contenido descifrado (ADR 0007): lo que pasa **de verdad** en el disco y en
/// el índice cuando la retención aprieta.
///
/// Se ejercita contra ficheros reales en un directorio temporal y un `FlowStore` real, porque lo que
/// hay que afirmar es justo lo que un doble no probaría: que un fichero deja de servir **cuando** su
/// última fila caduca y no antes, que se borra el que el índice ya no nombra y no otro, y que el orden
/// —podar, preguntar, borrar— es el que hace que la palabra "huérfano" signifique algo.
final class PlaintextRetentionTests: XCTestCase {

    private var directory: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plaintext-retention-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        dbURL = PersistenceFixtures.temporaryDatabaseURL()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
        PersistenceFixtures.removeDatabase(at: dbURL)
    }

    // MARK: - Utilidades

    private struct IndexUnavailable: Error {}

    private func makeStore() throws -> FlowStore {
        try FlowStore(databaseURL: dbURL, anchor: PersistenceFixtures.anchor)
    }

    /// Escribe un fichero de contenido descifrado con la secuencia y el tamaño pedidos. El contenido
    /// no importa aquí —quién lee un `.tvpt` es la pieza (4)—, solo su nombre y lo que pesa.
    private func writeFile(sequence: UInt32, bytes: Int) throws {
        let url = directory.appendingPathComponent(
            PlaintextFileName.make(sequence: sequence, date: Date())
        )
        try Data(repeating: 0xAB, count: bytes).write(to: url)
    }

    private func indexChunk(
        _ store: FlowStore,
        flowID: Int64,
        at seconds: UInt64,
        file: UInt32,
        offset: UInt64 = 16
    ) async throws {
        try await store.appendPlaintext(
            [
                PlaintextChunkMeta(
                    timestamp: PersistenceFixtures.uptime(seconds),
                    direction: .outbound,
                    stream: UInt64(file),
                    location: PlaintextLocation(fileSequence: file, recordOffset: offset),
                    storedLength: 64,
                    originalLength: 64
                )
            ],
            flowID: flowID
        )
    }

    private func makeFlow(_ store: FlowStore) async throws -> Int64 {
        try await store.upsertFlow(
            PersistenceFixtures.flow(
                remote: ModelFixtures.v4(93, 184, 216, 34),
                firstSeen: 1,
                lastSeen: 2
            )
        )
    }

    private func presentSequences() -> [UInt32] {
        PlaintextDirectory.files(in: directory).map(\.sequence)
    }

    /// El barrido con los ajustes de fábrica (un día) y el instante de referencia de los tests.
    private func sweep(
        openSequence: UInt32? = nil,
        age: PlaintextRetentionAge = .oneDay,
        at seconds: UInt64,
        ceiling: UInt64 = RetentionSettings.plaintextByteCeiling,
        openingHistory: (@Sendable () throws -> FlowStore)? = nil
    ) async -> PlaintextSweepOutcome {
        let dbURL = self.dbURL!
        return await PlaintextRetention.sweep(
            RetentionSettings(maxPlaintextAge: age),
            directory: directory,
            openSequence: openSequence,
            now: PersistenceFixtures.date(seconds),
            ceiling: ceiling,
            openingHistory: openingHistory
                ?? { try FlowStore(databaseURL: dbURL, anchor: PersistenceFixtures.anchor) }
        )
    }

    // MARK: - La antigüedad, y el huérfano que deja

    /// El orden entero del barrido en un test: caduca la fila, el fichero se queda sin quien lo
    /// nombre, y por eso se borra. Preguntar antes de podar lo habría conservado.
    func testAnExpiredChunkLeavesItsFileOrphanedAndTheFileGoes() async throws {
        let store = try makeStore()
        let flowID = try await makeFlow(store)
        try await indexChunk(store, flowID: flowID, at: 1, file: 0)
        try await indexChunk(store, flowID: flowID, at: 90_000, file: 1)
        try writeFile(sequence: 0, bytes: 200)
        try writeFile(sequence: 1, bytes: 300)

        // Un día y pico después del primer trozo, y un rato después del segundo.
        let outcome = await sweep(at: 91_000)

        XCTAssertEqual(outcome.prunedChunks, 1)
        XCTAssertEqual(outcome.deletedFiles, [0])
        XCTAssertEqual(outcome.bytesReclaimed, 200)
        XCTAssertFalse(outcome.ceilingEnforced)
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertEqual(presentSequences(), [1])
    }

    func testAFileWithLiveRowsSurvives() async throws {
        let store = try makeStore()
        let flowID = try await makeFlow(store)
        try await indexChunk(store, flowID: flowID, at: 100, file: 0)
        try await indexChunk(store, flowID: flowID, at: 200, file: 0, offset: 300)
        try writeFile(sequence: 0, bytes: 200)

        let outcome = await sweep(at: 300)

        XCTAssertFalse(outcome.didChangeAnything)
        XCTAssertEqual(presentSequences(), [0])
    }

    /// El caso del ADR: la caducidad es **del contenido**, no de la conexión, así que un fichero con
    /// trozos de horas distintas conserva los recientes y pierde los viejos — y sigue en disco.
    func testHalfAFileExpiringDoesNotDeleteIt() async throws {
        let store = try makeStore()
        let flowID = try await makeFlow(store)
        try await indexChunk(store, flowID: flowID, at: 1, file: 0)
        try await indexChunk(store, flowID: flowID, at: 90_000, file: 0, offset: 300)
        try writeFile(sequence: 0, bytes: 500)

        let outcome = await sweep(at: 91_000)

        XCTAssertEqual(outcome.prunedChunks, 1)
        XCTAssertTrue(outcome.deletedFiles.isEmpty)
        XCTAssertEqual(presentSequences(), [0])
    }

    /// Sin haber descifrado nunca nada no hay directorio, y eso no es un fallo: es el estado normal
    /// del producto.
    func testAMissingDirectoryIsNotAFailure() async throws {
        try FileManager.default.removeItem(at: directory)

        let outcome = await sweep(at: 10)

        XCTAssertFalse(outcome.didChangeAnything)
        XCTAssertTrue(outcome.failures.isEmpty)
    }

    // MARK: - El fichero abierto

    func testTheOpenFileIsNeverDeletedEvenWithNoRowsPointingAtIt() async throws {
        _ = try makeStore()
        try writeFile(sequence: 5, bytes: 100)

        let outcome = await sweep(openSequence: 5, at: 10)

        XCTAssertTrue(outcome.deletedFiles.isEmpty)
        XCTAssertEqual(presentSequences(), [5])
    }

    // MARK: - El techo

    func testTheCeilingDeletesTheOldestAndTakesItsIndexWithIt() async throws {
        let store = try makeStore()
        let flowID = try await makeFlow(store)
        try await indexChunk(store, flowID: flowID, at: 100, file: 0)
        try await indexChunk(store, flowID: flowID, at: 200, file: 1)
        try writeFile(sequence: 0, bytes: 400)
        try writeFile(sequence: 1, bytes: 400)

        let outcome = await sweep(at: 300, ceiling: 500)

        XCTAssertEqual(outcome.deletedFiles, [0])
        XCTAssertEqual(outcome.unindexedChunks, 1)
        XCTAssertTrue(outcome.ceilingEnforced)
        XCTAssertFalse(outcome.ceilingUnreachable)
        XCTAssertEqual(presentSequences(), [1])

        // Lo que el techo se llevó deja de contar como contenido guardado: una fila sin fichero
        // ofrecería abrir lo que ya no está.
        let referenced = try await store.referencedPlaintextFileSequences()
        XCTAssertEqual(referenced, [1])
    }

    func testTheCeilingCannotBeMetWhenTheOpenFileAloneIsOverIt() async throws {
        let store = try makeStore()
        let flowID = try await makeFlow(store)
        try await indexChunk(store, flowID: flowID, at: 100, file: 0)
        try await indexChunk(store, flowID: flowID, at: 200, file: 1)
        try writeFile(sequence: 0, bytes: 100)
        try writeFile(sequence: 1, bytes: 900)

        let outcome = await sweep(openSequence: 1, at: 300, ceiling: 500)

        XCTAssertEqual(outcome.deletedFiles, [0])
        XCTAssertTrue(outcome.ceilingUnreachable)
    }

    // MARK: - Lo que sale mal

    /// Sin índice no se distingue un huérfano de un fichero vivo, así que **no se borra nada**:
    /// borrar a ciegas se llevaría contenido que el usuario todavía puede leer.
    func testAnUnreachableIndexDeletesNothing() async throws {
        try writeFile(sequence: 0, bytes: 100)

        let outcome = await sweep(at: 10, openingHistory: { throw IndexUnavailable() })

        XCTAssertTrue(outcome.deletedFiles.isEmpty)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertEqual(presentSequences(), [0])
    }

    /// Un fichero que no se deja borrar no aborta el barrido, y **conserva su índice**: sigue siendo
    /// legible, y quitarle las filas lo convertiría en espacio que ya nadie sabe barrer.
    func testAFileThatCannotBeDeletedKeepsItsIndex() async throws {
        let store = try makeStore()
        let flowID = try await makeFlow(store)
        try await indexChunk(store, flowID: flowID, at: 100, file: 0)
        try await indexChunk(store, flowID: flowID, at: 200, file: 1)
        try writeFile(sequence: 0, bytes: 400)
        try writeFile(sequence: 1, bytes: 400)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)

        let outcome = await sweep(at: 300, ceiling: 500)

        XCTAssertTrue(outcome.deletedFiles.isEmpty)
        XCTAssertEqual(outcome.unindexedChunks, 0)
        XCTAssertEqual(outcome.failures.count, 1)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        let referenced = try await store.referencedPlaintextFileSequences()
        XCTAssertEqual(referenced, [0, 1])
    }
}
