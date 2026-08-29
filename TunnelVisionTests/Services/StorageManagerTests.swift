import Foundation
import XCTest
@testable import Shared

/// Tests del gestor de almacenamiento (M9), contra un `PcapWriter` **real** sobre un directorio temporal
/// y un `FlowStore` **real** sobre una BD temporal: lo que se ejercita es justo que la retención cruce
/// las dos mitades, que es la razón por la que este actor existe.
///
/// El tope de **tamaño** se afirma en `RetentionTests` con ficheros de mentira: ejercitarlo aquí exigiría
/// escribir cientos de megas en disco para el tope más pequeño que se puede elegir (256 MB). Lo que se
/// prueba aquí es la ejecución del plan, que es la misma venga del tope que venga, y para provocarla se
/// usa el corte por antigüedad: un `now` en el futuro deja "viejos" a los ficheros recién escritos.
final class StorageManagerTests: XCTestCase {

    private var captures: URL!
    private var plaintext: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        captures = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-manager-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        // El del contenido descifrado **no se crea**: lo crea su escritor con el primer byte que haya
        // que guardar, así que su ausencia es el estado normal y los tests parten de ella.
        plaintext = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-manager-plaintext-\(UUID().uuidString)", isDirectory: true)
        dbURL = PersistenceFixtures.temporaryDatabaseURL()
    }

    override func tearDownWithError() throws {
        // El test del borrado imposible deja el directorio sin permiso de escritura; devolverlo es lo
        // único que permite limpiarlo.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: captures.path)
        try? FileManager.default.removeItem(at: captures)
        try? FileManager.default.removeItem(at: plaintext)
        PersistenceFixtures.removeDatabase(at: dbURL)
    }

    // MARK: - Utilidades

    private struct StoreUnavailable: Error {}

    /// Ancla de la BD: sitúa el instante 0 de los tests **30 días antes de ahora**, para que un flujo
    /// escrito con sellos pequeños quede de verdad viejo frente a un corte por antigüedad real.
    private var anchor: MonotonicAnchor {
        MonotonicAnchor(uptimeNanoseconds: 1_000_000_000, wallClock: Date().addingTimeInterval(-30 * 86_400))
    }

    private func makeManager(storeAvailable: Bool = true) -> StorageManager {
        let url = dbURL!
        let anchor = anchor
        return StorageManager(
            library: CaptureLibrary(directory: captures),
            openingStore: {
                guard storeAvailable else { throw StoreUnavailable() }
                return try FlowStore(databaseURL: url, anchor: anchor)
            },
            plaintextDirectory: plaintext
        )
    }

    private func makeStore() throws -> FlowStore {
        try FlowStore(databaseURL: dbURL, anchor: anchor)
    }

    /// Un gestor cuyo directorio de capturas no se puede resolver: es el fallo que solo la costura de
    /// `CaptureLibrary` permite provocar (en el Simulator el contenedor del App Group responde siempre).
    private func makeManagerWithoutDirectory() -> StorageManager {
        let url = dbURL!
        let anchor = anchor
        return StorageManager(
            library: CaptureLibrary(resolvingDirectory: { throw CaptureLibraryError.containerUnavailable("group.x") }),
            openingStore: { try FlowStore(databaseURL: url, anchor: anchor) },
            plaintextDirectory: plaintext
        )
    }

    /// Escribe `count` capturas de un registro cada una, rotando entre ellas.
    private func writeCaptures(_ count: Int) async throws {
        let writer = try PcapWriter(config: .init(directory: captures, snaplen: 262_144))
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

    /// Un flujo con su paquete, fechado a `secondsAfterAnchor` del ancla.
    @discardableResult
    private func writeFlow(
        to store: FlowStore,
        remote: IPAddress,
        secondsAfterAnchor: UInt64
    ) async throws -> Int64 {
        let id = try await store.upsertFlow(
            PersistenceFixtures.flow(remote: remote, firstSeen: secondsAfterAnchor, lastSeen: secondsAfterAnchor)
        )
        try await store.appendPackets(
            [PersistenceFixtures.packet(timestamp: secondsAfterAnchor, key: PersistenceFixtures.key(remote: remote))],
            flowID: id
        )
        return id
    }

    private func remainingSequences() throws -> [UInt32] {
        CaptureDirectory.files(in: captures).map(\.sequence)
    }

    // MARK: - Uso

    func testUsageAddsUpTheCapturesAndTheHistory() async throws {
        try await writeCaptures(2)
        let store = try makeStore()
        try await writeFlow(to: store, remote: ModelFixtures.v4(1, 1, 1, 1), secondsAfterAnchor: 10)
        try await writeFlow(to: store, remote: ModelFixtures.v4(2, 2, 2, 2), secondsAfterAnchor: 20)

        let usage = try await makeManager().usage()

        XCTAssertEqual(usage.captureFileCount, 2)
        // Dos ficheros de cabecera global (24) + un registro (16 + 64) cada uno.
        XCTAssertEqual(usage.captureBytes, 2 * (24 + 16 + 64))
        XCTAssertGreaterThan(usage.historyBytes, 0)
        XCTAssertEqual(usage.historyFlowCount, 2)
        XCTAssertEqual(usage.totalBytes, usage.captureBytes + usage.historyBytes)
    }

    func testUsageStillReportsTheCapturesWhenTheHistoryCannotBeOpened() async throws {
        try await writeCaptures(1)

        let usage = try await makeManager(storeAvailable: false).usage()

        // El volumen está en las capturas: negarle la cifra entera al usuario porque falte la mitad
        // pequeña sería peor que darle la que sí se sabe.
        XCTAssertEqual(usage.captureBytes, 24 + 16 + 64)
        XCTAssertEqual(usage.historyBytes, 0)
        XCTAssertEqual(usage.historyFlowCount, 0)
    }

    func testUsageThrowsWhenTheCaptureDirectoryCannotBeResolved() async throws {
        let manager = makeManagerWithoutDirectory()

        do {
            _ = try await manager.usage()
            XCTFail("sin directorio no hay cifra que dar")
        } catch let error as StorageError {
            guard case .capturesUnavailable = error else { return XCTFail("caso inesperado: \(error)") }
        }
    }

    // MARK: - Aplicar los topes

    func testEnforceWithoutCapsTouchesNothing() async throws {
        try await writeCaptures(3)
        let store = try makeStore()
        try await writeFlow(to: store, remote: ModelFixtures.v4(1, 1, 1, 1), secondsAfterAnchor: 10)

        let outcome = try await makeManager().enforce(
            RetentionSettings(maxAge: .unlimited, maxCaptureSize: .unlimited),
            recordingSequence: nil
        )

        XCTAssertFalse(outcome.didChangeAnything)
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertEqual(try remainingSequences(), [0, 1, 2])
        let remaining = try await store.flowCount()
        XCTAssertEqual(remaining, 1)
    }

    func testEnforceDeletesTheAgedCapturesAndPrunesTheHistory() async throws {
        try await writeCaptures(3)
        let store = try makeStore()
        // Uno viejo (justo tras el ancla, hace 30 días) y uno de ahora mismo.
        try await writeFlow(to: store, remote: ModelFixtures.v4(1, 1, 1, 1), secondsAfterAnchor: 10)
        try await writeFlow(to: store, remote: ModelFixtures.v4(2, 2, 2, 2), secondsAfterAnchor: 30 * 86_400)

        let outcome = try await makeManager().enforce(
            RetentionSettings(maxAge: .oneWeek, maxCaptureSize: .unlimited),
            recordingSequence: nil,
            now: Date()
        )

        XCTAssertEqual(outcome.prunedFlows, 1, "solo el flujo anterior al corte")
        let survivors = try await store.flowCount()
        XCTAssertEqual(survivors, 1)
        // Los dos primeros ficheros se cerraron cuando apareció su sucesor, y aquí eso fue hace un
        // instante… así que con un corte de una semana **ningún** fichero es viejo todavía.
        XCTAssertEqual(try remainingSequences(), [0, 1, 2])
        XCTAssertTrue(outcome.deletedFiles.isEmpty)
        XCTAssertTrue(outcome.failures.isEmpty)
    }

    func testEnforceDeletesEveryClosedCaptureOnceTheyAreOlderThanTheCap() async throws {
        try await writeCaptures(3)
        let store = try makeStore()
        try await writeFlow(to: store, remote: ModelFixtures.v4(1, 1, 1, 1), secondsAfterAnchor: 10)

        // Un `now` en el futuro es la forma honesta de envejecer ficheros recién escritos sin tocar los
        // atributos del sistema de ficheros: el planificador solo mira fechas.
        let outcome = try await makeManager().enforce(
            RetentionSettings(maxAge: .oneWeek, maxCaptureSize: .unlimited),
            recordingSequence: nil,
            now: Date().addingTimeInterval(60 * 86_400)
        )

        XCTAssertEqual(outcome.deletedFiles, [0, 1])
        XCTAssertGreaterThan(outcome.bytesReclaimed, 0)
        // El último no tiene sucesor: nada dice cuándo se dejó de escribir, así que se queda.
        XCTAssertEqual(try remainingSequences(), [2])
        let survivors = try await store.flowCount()
        XCTAssertEqual(survivors, 0, "el corte se llevó también el historial")
    }

    func testEnforceNeverDeletesTheCaptureBeingWritten() async throws {
        try await writeCaptures(3)

        let outcome = try await makeManager().enforce(
            RetentionSettings(maxAge: .oneWeek, maxCaptureSize: .unlimited),
            recordingSequence: 1,
            now: Date().addingTimeInterval(60 * 86_400)
        )

        // El 1 está abierto: sus últimos bytes pueden ser un registro a medias y borrarlo dejaría a la
        // extensión escribiendo en un inodo sin nombre.
        XCTAssertEqual(outcome.deletedFiles, [0])
        XCTAssertEqual(try remainingSequences(), [1, 2])
    }

    func testEnforceReportsAHistoryItCouldNotOpenWithoutLosingTheFilesItDeleted() async throws {
        try await writeCaptures(3)

        let outcome = try await makeManager(storeAvailable: false).enforce(
            RetentionSettings(maxAge: .oneWeek, maxCaptureSize: .unlimited),
            recordingSequence: nil,
            now: Date().addingTimeInterval(60 * 86_400)
        )

        // Lanzar aquí perdería el recuento de lo que sí se liberó, que es lo que la pantalla tiene que
        // contar; el fallo vuelve dentro del resultado.
        XCTAssertEqual(outcome.deletedFiles, [0, 1])
        XCTAssertEqual(outcome.prunedFlows, 0)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertTrue(outcome.failures[0].contains("history"))
    }

    func testEnforceThrowsWhenItCannotEvenListTheDirectory() async throws {
        let manager = makeManagerWithoutDirectory()

        do {
            _ = try await manager.enforce(.default, recordingSequence: nil)
            XCTFail("sin listado no hay plan, y no se ha tocado nada")
        } catch let error as StorageError {
            guard case .capturesUnavailable = error else { return XCTFail("caso inesperado: \(error)") }
        }
    }

    // MARK: - Borrarlo todo

    func testClearEverythingRemovesEveryCaptureAndTheWholeHistory() async throws {
        try await writeCaptures(3)
        let store = try makeStore()
        try await writeFlow(to: store, remote: ModelFixtures.v4(1, 1, 1, 1), secondsAfterAnchor: 10)
        try await writeFlow(to: store, remote: ModelFixtures.v4(2, 2, 2, 2), secondsAfterAnchor: 20)

        let outcome = try await makeManager().clearEverything(recordingSequence: nil)

        XCTAssertEqual(outcome.deletedFiles, [0, 1, 2])
        XCTAssertEqual(outcome.prunedFlows, 2, "contadas antes de vaciar, que es cuando se pueden contar")
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertTrue(try remainingSequences().isEmpty)
        let survivors = try await store.flowCount()
        XCTAssertEqual(survivors, 0)
    }

    func testClearEverythingKeepsTheCaptureBeingWritten() async throws {
        try await writeCaptures(2)

        let outcome = try await makeManager().clearEverything(recordingSequence: 1)

        XCTAssertEqual(outcome.deletedFiles, [0])
        XCTAssertEqual(try remainingSequences(), [1])
    }

    func testADeletionThatFailsIsReportedWithoutLeavingTheHistoryUncleared() async throws {
        try await writeCaptures(2)
        let store = try makeStore()
        try await writeFlow(to: store, remote: ModelFixtures.v4(1, 1, 1, 1), secondsAfterAnchor: 10)
        // Un directorio sin permiso de escritura se puede listar pero no se puede borrar de él: es la
        // forma de provocar el fallo de borrado sin fingirlo.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: captures.path)

        let outcome = try await makeManager().clearEverything(recordingSequence: nil)

        XCTAssertTrue(outcome.deletedFiles.isEmpty)
        XCTAssertEqual(outcome.failures.count, 2, "un fallo por fichero, y ninguno aborta el siguiente")
        XCTAssertEqual(outcome.bytesReclaimed, 0)
        // Y el historial se vació igualmente: un fichero que no se deja borrar no es motivo para dejar
        // sin hacer la otra mitad de lo que el usuario pidió.
        XCTAssertEqual(outcome.prunedFlows, 1)
        let survivors = try await store.flowCount()
        XCTAssertEqual(survivors, 0)
    }

    // MARK: - El barrido del contenido descifrado (ADR 0007)

    /// Escribe un fichero de contenido descifrado indexado por un flujo, fechado a `secondsAfterAnchor`.
    private func writePlaintext(
        to store: FlowStore,
        sequence: UInt32,
        secondsAfterAnchor: UInt64,
        bytes: Int = 128
    ) async throws {
        try FileManager.default.createDirectory(at: plaintext, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: bytes).write(
            to: plaintext.appendingPathComponent(PlaintextFileName.make(sequence: sequence, date: Date()))
        )
        let flowID = try await writeFlow(
            to: store,
            remote: ModelFixtures.v4(10, 0, UInt8(sequence / 256), UInt8(sequence % 256)),
            secondsAfterAnchor: secondsAfterAnchor
        )
        try await store.appendPlaintext(
            [
                PlaintextChunkMeta(
                    timestamp: PersistenceFixtures.uptime(secondsAfterAnchor),
                    direction: .outbound,
                    stream: UInt64(sequence),
                    location: PlaintextLocation(fileSequence: sequence, recordOffset: 16),
                    storedLength: UInt32(bytes),
                    originalLength: UInt32(bytes)
                )
            ],
            flowID: flowID
        )
    }

    private func remainingPlaintextSequences() -> [UInt32] {
        PlaintextDirectory.files(in: plaintext).map(\.sequence)
    }

    /// La trampa que este barrido existe para no caer en: los topes de captura son del usuario y
    /// puede quitarlos, pero el contenido descifrado caduca igual.
    func testDecryptedContentExpiresEvenWithEveryCaptureCapRemoved() async throws {
        let store = try makeStore()
        // El ancla está 30 días atrás, así que este trozo es de hace 30 días.
        try await writePlaintext(to: store, sequence: 0, secondsAfterAnchor: 10)

        let outcome = await makeManager().sweepPlaintext(
            RetentionSettings(maxAge: .unlimited, maxCaptureSize: .unlimited, maxPlaintextAge: .oneDay),
            isMonitoring: false
        )

        XCTAssertEqual(outcome.prunedChunks, 1)
        XCTAssertEqual(outcome.deletedFiles, [0])
        XCTAssertTrue(remainingPlaintextSequences().isEmpty)
        // Y el flujo sigue en el historial con sus paquetes: lo que caducó es lo que dijo por dentro.
        let survivors = try await store.flowCount()
        XCTAssertEqual(survivors, 1)
    }

    func testDecryptedContentInsideItsWindowIsKept() async throws {
        let store = try makeStore()
        try await writePlaintext(to: store, sequence: 0, secondsAfterAnchor: 30 * 86_400)

        let outcome = await makeManager().sweepPlaintext(
            RetentionSettings(maxPlaintextAge: .oneDay),
            isMonitoring: false
        )

        XCTAssertFalse(outcome.didChangeAnything)
        XCTAssertEqual(remainingPlaintextSequences(), [0])
    }

    /// Con el túnel vivo el fichero más nuevo puede ser el que la extensión está escribiendo, y ese no
    /// se toca aunque su contenido esté caducado.
    func testTheNewestFileIsSparedWhileMonitoring() async throws {
        let store = try makeStore()
        try await writePlaintext(to: store, sequence: 0, secondsAfterAnchor: 10)
        try await writePlaintext(to: store, sequence: 1, secondsAfterAnchor: 11)

        let outcome = await makeManager().sweepPlaintext(
            RetentionSettings(maxPlaintextAge: .oneDay),
            isMonitoring: true
        )

        XCTAssertEqual(outcome.deletedFiles, [0])
        XCTAssertEqual(remainingPlaintextSequences(), [1])
    }

    /// Nunca haber descifrado nada no es un fallo: el directorio ni siquiera existe.
    func testSweepingWithNothingEverDecryptedIsQuiet() async throws {
        _ = try makeStore()

        let outcome = await makeManager().sweepPlaintext(RetentionSettings(), isMonitoring: false)

        XCTAssertFalse(outcome.didChangeAnything)
        XCTAssertTrue(outcome.failures.isEmpty)
    }

    func testASweepThatCannotOpenTheIndexIsReported() async throws {
        let store = try makeStore()
        try await writePlaintext(to: store, sequence: 0, secondsAfterAnchor: 10)

        let outcome = await makeManager(storeAvailable: false).sweepPlaintext(
            RetentionSettings(),
            isMonitoring: false
        )

        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertEqual(remainingPlaintextSequences(), [0], "sin índice no se borra a ciegas")
    }

    // MARK: - El borrado del contenido descifrado (ADR 0007, punto 3)

    /// Lo que hace que el gesto exista: se lleva lo descifrado **dentro de su plazo** —que es cuando
    /// alguien se arrepiente— y deja el historial y las capturas donde estaban.
    func testClearingDecryptedContentTakesItAllAndLeavesEverythingElse() async throws {
        let store = try makeStore()
        try await writeCaptures(2)
        try await writePlaintext(to: store, sequence: 0, secondsAfterAnchor: 30 * 86_400)
        try await writePlaintext(to: store, sequence: 1, secondsAfterAnchor: 30 * 86_400)

        let outcome = await makeManager().clearPlaintext(RetentionSettings(), isMonitoring: false)

        XCTAssertEqual(outcome.clearedChunks, 2)
        XCTAssertEqual(outcome.deletedFiles, [0, 1])
        XCTAssertEqual(outcome.bytesReclaimed, 256)
        XCTAssertEqual(outcome.bytesKept, 0)
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertTrue(remainingPlaintextSequences().isEmpty)
        // Las dos mitades que el gesto promete no tocar.
        XCTAssertEqual(CaptureDirectory.files(in: captures).map(\.sequence), [0, 1])
        let flows = try await store.flowCount()
        XCTAssertEqual(flows, 2)
    }

    /// El fichero que la extensión puede estar escribiendo no se toca ni siquiera aquí, y lo que se
    /// queda se **mide** en vez de deducirse: es lo que la pantalla necesita para poder decirlo.
    func testClearingWhileMonitoringKeepsTheOpenFileAndSaysHowMuchStays() async throws {
        let store = try makeStore()
        try await writePlaintext(to: store, sequence: 0, secondsAfterAnchor: 30 * 86_400)
        try await writePlaintext(to: store, sequence: 1, secondsAfterAnchor: 30 * 86_400)

        let outcome = await makeManager().clearPlaintext(RetentionSettings(), isMonitoring: true)

        XCTAssertEqual(outcome.clearedChunks, 2, "el índice se vacía entero, también el del abierto")
        XCTAssertEqual(outcome.deletedFiles, [0])
        XCTAssertEqual(outcome.bytesKept, 128)
        XCTAssertEqual(remainingPlaintextSequences(), [1])
    }

    /// Sin índice no se puede vaciar el índice, y sin vaciarlo el barrido conservaría todos los
    /// ficheros por estar referenciados: se para y se dice, en vez de dejar el gesto a medias.
    func testClearingWithoutTheIndexDeletesNothingAndIsReported() async throws {
        let store = try makeStore()
        try await writePlaintext(to: store, sequence: 0, secondsAfterAnchor: 30 * 86_400)

        let outcome = await makeManager(storeAvailable: false).clearPlaintext(
            RetentionSettings(),
            isMonitoring: false
        )

        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertFalse(outcome.didChangeAnything)
        XCTAssertEqual(outcome.bytesKept, 128)
        XCTAssertEqual(remainingPlaintextSequences(), [0])
    }

    func testClearingWithNothingDecryptedChangesNothing() async throws {
        _ = try makeStore()

        let outcome = await makeManager().clearPlaintext(RetentionSettings(), isMonitoring: false)

        XCTAssertFalse(outcome.didChangeAnything)
        XCTAssertTrue(outcome.failures.isEmpty)
    }

    // MARK: - La medida

    /// El contenido descifrado entra en el total: es espacio ocupado, y dejarlo fuera haría que la
    /// pantalla dijese menos de lo que iOS enseña justo en lo más sensible que se guarda.
    func testUsageCountsTheDecryptedContentAndAddsItToTheTotal() async throws {
        let store = try makeStore()
        try await writeCaptures(1)
        try await writePlaintext(to: store, sequence: 0, secondsAfterAnchor: 30 * 86_400, bytes: 512)

        let usage = try await makeManager().usage()

        XCTAssertEqual(usage.plaintextBytes, 512)
        XCTAssertEqual(usage.plaintextChunkCount, 1)
        XCTAssertTrue(usage.hasPlaintext)
        XCTAssertEqual(usage.totalBytes, usage.captureBytes + usage.historyBytes + 512)
    }

    func testUsageWithNothingDecryptedSaysSo() async throws {
        _ = try makeStore()
        try await writeCaptures(1)

        let usage = try await makeManager().usage()

        XCTAssertEqual(usage.plaintextBytes, 0)
        XCTAssertFalse(usage.hasPlaintext)
    }
}
