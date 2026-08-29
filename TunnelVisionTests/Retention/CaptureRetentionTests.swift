import Foundation
import XCTest
@testable import Shared

/// Tests del ejecutor de la retención (M11): lo que pasa **de verdad** en el disco cuando se aplica un
/// plan ya decidido.
///
/// Se ejercita contra ficheros reales en un directorio temporal y un `FlowStore` real sobre una BD
/// temporal, porque lo que hay que afirmar aquí es justo lo que un doble no probaría: que se borra el
/// fichero que el plan señala y no otro, que un borrado imposible no se lleva por delante los demás, y
/// que el corte del historial ocurre **después** de los ficheros.
///
/// Quién se va y por qué es de `RetentionPlannerTests`; aquí los planes se construyen a mano para poder
/// pedir un borrado concreto sin montar la situación que lo provocaría.
final class CaptureRetentionTests: XCTestCase {

    private var directory: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-retention-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        dbURL = PersistenceFixtures.temporaryDatabaseURL()
    }

    override func tearDownWithError() throws {
        // El test del borrado imposible deja el directorio sin permiso de escritura; devolvérselo es lo
        // único que permite limpiarlo.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
        PersistenceFixtures.removeDatabase(at: dbURL)
    }

    // MARK: - Utilidades

    private struct HistoryUnavailable: Error {}

    /// Sitúa el instante 0 de la BD treinta días atrás, para que un flujo escrito con sellos pequeños
    /// quede de verdad viejo frente a un corte por antigüedad real.
    private var anchor: MonotonicAnchor {
        MonotonicAnchor(uptimeNanoseconds: 1_000_000_000, wallClock: Date().addingTimeInterval(-30 * 86_400))
    }

    private func makeStore() throws -> FlowStore {
        try FlowStore(databaseURL: dbURL, anchor: anchor)
    }

    /// Escribe `count` capturas de un registro cada una, rotando entre ellas.
    private func writeCaptures(_ count: Int) async throws {
        let writer = try PcapWriter(config: .init(directory: directory, snaplen: 262_144))
        for index in 0..<count {
            _ = try await writer.write(
                packet: Data(repeating: UInt8(index), count: 64),
                originalLength: 64,
                timestamp: Int64(index + 1) * 1_000
            )
            if index < count - 1 { try await writer.rotate() }
        }
        await writer.close()
    }

    private func files() -> [CaptureFileInfo] {
        CaptureDirectory.fileInfos(in: directory)
    }

    private func remainingSequences() -> [UInt32] {
        CaptureDirectory.files(in: directory).map(\.sequence)
    }

    private func plan(
        deleting sequences: [UInt32],
        cutoff: Date? = nil,
        sizeCapUnreachable: Bool = false
    ) -> RetentionPlan {
        RetentionPlan(
            historyCutoff: cutoff,
            filesToDelete: sequences,
            bytesReclaimed: 0,
            captureBytesAfter: 0,
            sizeCapUnreachable: sizeCapUnreachable
        )
    }

    private func neverOpened() -> @Sendable () throws -> FlowStore {
        { throw HistoryUnavailable() }
    }

    // MARK: - Borrado de capturas

    func testDeletesOnlyTheFilesThePlanNames() async throws {
        try await writeCaptures(3)

        let outcome = await CaptureRetention.execute(
            plan(deleting: [0, 1]),
            files: files(),
            openingHistory: neverOpened()
        )

        XCTAssertEqual(outcome.deletedFiles, [0, 1])
        XCTAssertEqual(remainingSequences(), [2], "la captura que el plan no señala se queda")
        XCTAssertTrue(outcome.failures.isEmpty)
    }

    func testCountsTheBytesOfWhatItActuallyDeleted() async throws {
        try await writeCaptures(2)
        // Cabecera global (24) + un registro (16 + 64) por fichero.
        let perFile: UInt64 = 24 + 16 + 64

        let outcome = await CaptureRetention.execute(
            plan(deleting: [0]),
            files: files(),
            openingHistory: neverOpened()
        )

        XCTAssertEqual(outcome.bytesReclaimed, perFile)
        XCTAssertTrue(outcome.didChangeAnything)
    }

    func testAFileThatIsNoLongerListedIsSkippedWithoutFailing() async throws {
        try await writeCaptures(1)
        let listing = files()
        // El plan pide una secuencia que nunca estuvo en el listado con el que se planificó: no hay URL
        // que borrar, y adivinarla sería borrar algo que nadie decidió borrar.
        let outcome = await CaptureRetention.execute(
            plan(deleting: [7]),
            files: listing,
            openingHistory: neverOpened()
        )

        XCTAssertTrue(outcome.deletedFiles.isEmpty)
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertEqual(remainingSequences(), [0])
    }

    func testOneImpossibleDeletionDoesNotAbortTheOthers() async throws {
        try await writeCaptures(2)
        let listing = files()
        // Sin permiso de escritura en el directorio, `removeItem` falla para los dos ficheros.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

        let outcome = await CaptureRetention.execute(
            plan(deleting: [0, 1]),
            files: listing,
            openingHistory: neverOpened()
        )

        XCTAssertEqual(outcome.failures.count, 2, "un fallo por fichero, y ninguno aborta el siguiente")
        XCTAssertTrue(outcome.deletedFiles.isEmpty)
        XCTAssertEqual(outcome.bytesReclaimed, 0, "no se cuenta como liberado lo que sigue en el disco")
    }

    // MARK: - Corte del historial

    func testPrunesTheHistoryWhenThePlanCarriesACutoff() async throws {
        let store = try makeStore()
        let old = try await store.upsertFlow(
            PersistenceFixtures.flow(remote: ModelFixtures.v4(1, 1, 1, 1), firstSeen: 10, lastSeen: 20)
        )
        XCTAssertGreaterThan(old, 0)

        // `XCTestCase` no es `Sendable`: la closure se lleva los dos valores, no el caso de prueba.
        let url = dbURL!
        let anchor = anchor

        // El ancla sitúa esos sellos treinta días atrás, así que un corte de ayer se los lleva.
        let outcome = await CaptureRetention.execute(
            plan(deleting: [], cutoff: Date().addingTimeInterval(-86_400)),
            files: [],
            openingHistory: { try FlowStore(databaseURL: url, anchor: anchor) }
        )

        XCTAssertEqual(outcome.prunedFlows, 1)
        let remaining = try await makeStore().flowCount()
        XCTAssertEqual(remaining, 0)
    }

    func testDoesNotTouchTheHistoryWhenThereIsNoCutoff() async throws {
        try await writeCaptures(1)

        // `neverOpened` lanza: si el ejecutor abriese el historial sin corte que aplicar, esto se contaría
        // como fallo. Que no lo haga es la afirmación.
        let outcome = await CaptureRetention.execute(
            plan(deleting: [0]),
            files: files(),
            openingHistory: neverOpened()
        )

        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertEqual(outcome.prunedFlows, 0)
    }

    func testAHistoryThatDoesNotOpenIsAPartialFailureAndNotALostDeletion() async throws {
        try await writeCaptures(1)

        let outcome = await CaptureRetention.execute(
            plan(deleting: [0], cutoff: Date()),
            files: files(),
            openingHistory: neverOpened()
        )

        XCTAssertEqual(outcome.deletedFiles, [0], "el fichero ya borrado sigue contando")
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertTrue(outcome.failures[0].contains("history"))
    }

    // MARK: - Lo que el plan dice y el resultado repite

    func testCarriesTheUnreachableSizeCapThrough() async throws {
        // Es del plan y no de la ejecución —lo decide medir, no borrar—, pero tiene que llegar al
        // resultado: es lo único que explica un tope que sigue incumplido después de una limpieza limpia.
        let outcome = await CaptureRetention.execute(
            plan(deleting: [], sizeCapUnreachable: true),
            files: [],
            openingHistory: neverOpened()
        )

        XCTAssertTrue(outcome.sizeCapUnreachable)
        XCTAssertFalse(outcome.didChangeAnything)
    }
}
