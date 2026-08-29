import Foundation
import XCTest
import Shared

/// Tests del view model de la pantalla de capturas (M9) contra un `CaptureLibrary` **real** sobre un
/// directorio temporal poblado por un `PcapWriter` **real** — el mismo criterio que los tests del
/// feed en vivo y del historial: lo que interesa es el acoplamiento entre lo que escribe la extensión
/// y lo que la pantalla acaba enseñando y borrando.
///
/// Lo único guionizado es la rotación, porque va por el canal de control a un túnel que en Simulator
/// no existe, y porque sus cuatro desenlaces (aplicada, sin túnel, rechazada, respuesta inesperada)
/// son justo lo que hay que afirmar.
@MainActor
final class CapturesViewModelTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("captures-vm-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Utilidades

    /// Escribe `count` ficheros de captura con un paquete cada uno, como haría la extensión.
    private func writeCaptures(_ count: Int) async throws {
        let writer = try PcapWriter(
            config: .init(directory: tempDir, snaplen: 262_144, maxFileBytes: 64 * 1024 * 1024)
        )
        for index in 0..<count {
            _ = try await writer.write(
                packet: Data(repeating: 0xAB, count: 32 * (index + 1)),
                originalLength: 32 * (index + 1),
                timestamp: Int64(index + 1)
            )
            if index < count - 1 { try await writer.rotate() }
        }
        await writer.close()
    }

    private func makeViewModel(
        directory: URL? = nil,
        rotate: @escaping @Sendable () async throws -> ControlResponse = { .ok },
        export: (@Sendable () async throws -> FlowExportResult)? = nil,
        retention: @escaping @Sendable () throws -> RetentionSettings = { .default },
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> CapturesViewModel {
        CapturesViewModel(
            library: CaptureLibrary(directory: directory ?? tempDir),
            rotateCapture: rotate,
            // Por defecto, un export que nadie pide: los tests que lo ejercitan traen el suyo.
            exportConnections: export ?? { Self.exportResult(connectionCount: 0) },
            loadRetention: retention,
            now: now
        )
    }

    /// `nonisolated` porque lo llaman las closures de export, que corren fuera del hilo principal.
    private nonisolated static func exportResult(
        connectionCount: Int,
        byteCount: UInt64 = 4_096,
        truncated: Bool = false
    ) -> FlowExportResult {
        FlowExportResult(
            url: URL(fileURLWithPath: "/tmp/tunnelvision-connections-20231114-221320.json"),
            connectionCount: connectionCount,
            byteCount: byteCount,
            truncated: truncated
        )
    }

    // MARK: - Listado

    func testRefreshShowsTheCapturesNewestFirst() async throws {
        try await writeCaptures(3)
        let viewModel = makeViewModel()

        await viewModel.refresh()

        XCTAssertEqual(viewModel.state, .loaded)
        XCTAssertEqual(viewModel.content, .list)
        XCTAssertEqual(viewModel.rows.map(\.sequence), [2, 1, 0])
        XCTAssertEqual(viewModel.summary.fileCount, 3)
    }

    func testAnEmptyDirectoryIsTheTeachingEmptyAndNotAFailure() async throws {
        let viewModel = makeViewModel()

        await viewModel.refresh()

        guard case .placeholder(let placeholder) = viewModel.content else {
            return XCTFail("sin capturas debería haber un hueco que enseña")
        }
        XCTAssertEqual(placeholder.title, "No captures yet")
        XCTAssertEqual(viewModel.state, .loaded)
    }

    func testTheOpenFileIsMarkedOnlyWhileTheTunnelIsLive() async throws {
        try await writeCaptures(2)
        let viewModel = makeViewModel()
        await viewModel.refresh()

        viewModel.tunnelStateDidChange(to: .live)
        XCTAssertEqual(viewModel.recordingSequence, 1)
        XCTAssertTrue(viewModel.rows[0].isRecording)
        XCTAssertTrue(viewModel.canRotate)

        // `starting` es una transición: el writer aún no existe, así que nada está abierto.
        viewModel.tunnelStateDidChange(to: .starting)
        XCTAssertNil(viewModel.recordingSequence)
        XCTAssertFalse(viewModel.canRotate)

        viewModel.tunnelStateDidChange(to: .off)
        XCTAssertNil(viewModel.recordingSequence)
        XCTAssertFalse(viewModel.rows[0].isRecording)
    }

    // MARK: - Borrado

    func testDeletingRemovesTheRowAndTheFile() async throws {
        try await writeCaptures(2)
        let viewModel = makeViewModel()
        await viewModel.refresh()
        let removed = try XCTUnwrap(viewModel.rows.first { $0.sequence == 0 })

        await viewModel.delete(sequence: 0)

        XCTAssertEqual(viewModel.rows.map(\.sequence), [1])
        XCTAssertFalse(FileManager.default.fileExists(atPath: removed.url.path))
        XCTAssertEqual(viewModel.activity, .idle)
        XCTAssertNil(viewModel.notice)
    }

    func testTheFileBeingWrittenIsNotDeleted() async throws {
        try await writeCaptures(2)
        let viewModel = makeViewModel()
        await viewModel.refresh()
        viewModel.tunnelStateDidChange(to: .live)
        let open = try XCTUnwrap(viewModel.rows.first { $0.sequence == 1 })

        await viewModel.delete(sequence: 1)

        // La regla vive en el view model y no solo en la vista: la consecuencia (la extensión
        // escribiendo en un fichero sin nombre) es del dominio, no del dibujo.
        XCTAssertTrue(FileManager.default.fileExists(atPath: open.url.path))
        XCTAssertEqual(viewModel.rows.map(\.sequence), [1, 0])
        XCTAssertEqual(viewModel.notice, CapturesPresentation.cannotDeleteRecording)
    }

    func testDeletingSomethingAlreadyGoneIsNotReportedAsAFailure() async throws {
        try await writeCaptures(2)
        let viewModel = makeViewModel()
        await viewModel.refresh()
        let doomed = try XCTUnwrap(viewModel.rows.first { $0.sequence == 0 })

        // Desaparece a espaldas del view model, que sigue enseñando su fila.
        try FileManager.default.removeItem(at: doomed.url)
        await viewModel.delete(sequence: 0)

        // El usuario pidió que no estuviera y no está: contarlo como error sería inventar una avería.
        XCTAssertNil(viewModel.notice)
        XCTAssertEqual(viewModel.rows.map(\.sequence), [1])
    }

    // MARK: - Rotación

    func testRotatingPicksUpTheNewFile() async throws {
        try await writeCaptures(1)
        let directory = tempDir!
        let viewModel = makeViewModel(rotate: {
            // Lo que hace la extensión al recibir el comando: cierra el fichero abierto y abre el
            // siguiente, con la secuencia por encima de la mayor que hay.
            let writer = try PcapWriter(config: .init(directory: directory))
            await writer.close()
            return .ok
        })
        await viewModel.refresh()
        viewModel.tunnelStateDidChange(to: .live)

        await viewModel.rotate()

        XCTAssertEqual(viewModel.notice, CapturesPresentation.rotated)
        XCTAssertEqual(viewModel.rows.map(\.sequence), [1, 0])
        XCTAssertEqual(viewModel.activity, .idle)
    }

    func testRotatingWithoutATunnelIsExplainedAndNotBlamed() async throws {
        try await writeCaptures(1)
        let viewModel = makeViewModel(rotate: { .notRunning })
        await viewModel.refresh()

        await viewModel.rotate()

        XCTAssertEqual(viewModel.notice, CapturesPresentation.rotateUnavailable)
        XCTAssertEqual(viewModel.notice?.role, .neutral)
    }

    func testATunnelThatThrewNotRunningReadsTheSame() async throws {
        let viewModel = makeViewModel(rotate: { throw TunnelControlError.notRunning })
        await viewModel.refresh()

        await viewModel.rotate()

        // El mismo hecho llega por dos caminos (respuesta y excepción) y significa lo mismo: no hay
        // nadie escribiendo. Distinguirlos en pantalla sería contarle al usuario un detalle nuestro.
        XCTAssertEqual(viewModel.notice, CapturesPresentation.rotateUnavailable)
    }

    func testARejectedRotationKeepsTheReason() async throws {
        let viewModel = makeViewModel(rotate: { .failed("No space left on device") })
        await viewModel.refresh()

        await viewModel.rotate()

        XCTAssertEqual(viewModel.notice?.role, .warning)
        XCTAssertEqual(viewModel.notice?.diagnostic, "No space left on device")
    }

    func testAnUnexpectedReplyIsNotTakenAsSuccess() async throws {
        let viewModel = makeViewModel(rotate: { .stats(TunnelStats()) })
        await viewModel.refresh()

        await viewModel.rotate()

        // No se puede afirmar que haya rotado, así que no se enseña la confirmación.
        XCTAssertEqual(viewModel.notice?.role, .warning)
        XCTAssertNotEqual(viewModel.notice, CapturesPresentation.rotated)
    }

    func testATransportFailureIsAWarning() async throws {
        let viewModel = makeViewModel(rotate: { throw TunnelControlError.controlChannelFailed("XPC down") })
        await viewModel.refresh()

        await viewModel.rotate()

        XCTAssertEqual(viewModel.notice?.role, .warning)
        XCTAssertNotNil(viewModel.notice?.diagnostic)
    }

    // MARK: - Sitio que queda

    func testTheInventoryIsComparedWithTheSavedLimits() async throws {
        try await writeCaptures(3)
        let viewModel = makeViewModel(retention: { RetentionSettings(maxAge: .oneWeek, maxCaptureSize: .megabytes256) })

        await viewModel.refresh()

        guard case .bounded(let size, _) = viewModel.headroom else {
            return XCTFail("con topes guardados la pantalla debería poder comparar")
        }
        XCTAssertEqual(size.used, viewModel.summary.totalBytes)
        XCTAssertEqual(size.limit, 256 * 1024 * 1024)
    }

    func testTheOpenCaptureCountsAsRoomUsed() async throws {
        try await writeCaptures(2)
        let viewModel = makeViewModel(retention: { RetentionSettings(maxAge: .oneWeek, maxCaptureSize: .megabytes256) })
        await viewModel.refresh()
        let stopped = viewModel.headroom?.used

        viewModel.tunnelStateDidChange(to: .live)

        // El fichero que se está escribiendo ocupa disco igual que los demás, así que sigue contando
        // en lo ocupado aunque no se pueda borrar — la misma decisión que en `StorageUsage`. Lo que
        // cambia con el túnel es cuál es, y por eso la comparación es un derivado y no una foto
        // guardada en el refresco.
        XCTAssertEqual(viewModel.recordingSequence, 1)
        XCTAssertEqual(viewModel.headroom?.used, stopped)
        XCTAssertEqual(viewModel.headroom?.used, viewModel.summary.totalBytes)
    }

    func testAgeIsMeasuredAgainstTheReadAndNotAgainstAClockThatKeepsRunning() async throws {
        try await writeCaptures(2)
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let viewModel = makeViewModel(
            retention: { RetentionSettings(maxAge: .oneDay, maxCaptureSize: .unlimited) },
            now: { instant }
        )

        await viewModel.refresh()
        let first = viewModel.headroom

        // Dos lecturas del mismo derivado tienen que dar lo mismo: si preguntara la hora en cada
        // repintado, un repintado cualquiera podría cambiar la respuesta.
        XCTAssertEqual(first, viewModel.headroom)
    }

    func testLimitsThatCannotBeReadHideTheComparisonAndSayWhy() async throws {
        try await writeCaptures(2)
        let viewModel = makeViewModel(retention: { throw SettingsStoreError.corruptData("not JSON") })

        await viewModel.refresh()

        // La lista se queda: lo que se ha perdido es una parte de la pantalla, no la pantalla. Y el
        // hueco se explica, en vez de dejar un bloque que aparece unas veces y otras no.
        XCTAssertEqual(viewModel.content, .list)
        XCTAssertEqual(viewModel.rows.count, 2)
        XCTAssertNil(viewModel.headroom)
        XCTAssertEqual(viewModel.notice?.role, .warning)
        XCTAssertEqual(viewModel.notice?.diagnostic, "not JSON")
    }

    func testLimitsAreReReadOnEveryRefresh() async throws {
        try await writeCaptures(1)
        let store = SwitchableRetention()
        let viewModel = makeViewModel(retention: { try store.load() })
        await viewModel.refresh()
        XCTAssertNotNil(viewModel.headroom)

        // El usuario puede cambiar los topes en Ajustes y volver aquí: cachearlos serviría una
        // comparación contra un tope que ya no es el suyo.
        store.settings = RetentionSettings(maxAge: .unlimited, maxCaptureSize: .unlimited)
        await viewModel.refresh()

        guard case .unbounded = viewModel.headroom else {
            return XCTFail("los topes quitados deberían llegar a la pantalla")
        }
    }

    // MARK: - Fallos de lectura

    func testAFailedFirstReadIsTheBodyOfTheScreen() async {
        let resolver = FlakyDirectory(url: tempDir)
        resolver.isBroken = true
        let viewModel = CapturesViewModel(
            library: CaptureLibrary(resolvingDirectory: { try resolver.resolve() }),
            rotateCapture: { .ok },
            exportConnections: { Self.exportResult(connectionCount: 0) },
            loadRetention: { .default }
        )

        await viewModel.refresh()

        guard case .placeholder(let placeholder) = viewModel.content else {
            return XCTFail("un fallo sin filas debería ser el cuerpo de la pantalla")
        }
        XCTAssertEqual(placeholder.action, .retry)
    }

    func testAFailedRefreshDoesNotWipeTheListAlreadyDrawn() async throws {
        try await writeCaptures(2)
        let resolver = FlakyDirectory(url: tempDir)
        let viewModel = CapturesViewModel(
            library: CaptureLibrary(resolvingDirectory: { try resolver.resolve() }),
            rotateCapture: { .ok },
            exportConnections: { Self.exportResult(connectionCount: 0) },
            loadRetention: { .default }
        )
        await viewModel.refresh()
        XCTAssertEqual(viewModel.rows.count, 2)

        resolver.isBroken = true
        await viewModel.refresh()

        // Una lista desfasada dice más que una pantalla en blanco; lo que ha fallado se cuenta aparte.
        XCTAssertEqual(viewModel.content, .list)
        XCTAssertEqual(viewModel.rows.count, 2)
        XCTAssertEqual(viewModel.notice?.role, .warning)
    }

    func testRetryReadsTheDirectoryAgain() async throws {
        try await writeCaptures(1)
        let resolver = FlakyDirectory(url: tempDir)
        resolver.isBroken = true
        let viewModel = CapturesViewModel(
            library: CaptureLibrary(resolvingDirectory: { try resolver.resolve() }),
            rotateCapture: { .ok },
            exportConnections: { Self.exportResult(connectionCount: 0) },
            loadRetention: { .default }
        )
        await viewModel.refresh()
        guard case .placeholder = viewModel.content else {
            return XCTFail("el primer intento debería haber fallado")
        }

        resolver.isBroken = false
        await viewModel.perform(.retry)

        XCTAssertEqual(viewModel.content, .list)
        XCTAssertEqual(viewModel.state, .loaded)
    }

    func testTheNoticeIsDismissedByTheUser() async throws {
        let viewModel = makeViewModel(rotate: { .notRunning })
        await viewModel.refresh()
        await viewModel.rotate()
        XCTAssertNotNil(viewModel.notice)

        viewModel.dismissNotice()

        XCTAssertNil(viewModel.notice)
    }

    // MARK: - Export del listado de conexiones

    func testAPreparedExportIsShownBeforeItIsShared() async throws {
        // Compartir saca datos del dispositivo, así que primero se dice qué hay dentro: el view model
        // no comparte nada por su cuenta, deja el resumen y espera.
        let viewModel = makeViewModel(export: { Self.exportResult(connectionCount: 1_204) })

        await viewModel.exportFlows()

        let summary = try XCTUnwrap(viewModel.pendingExport)
        XCTAssertTrue(summary.title.contains("1,204"))
        XCTAssertTrue(summary.detail.contains("no packet contents"))
        XCTAssertNil(summary.truncationNote)
        XCTAssertNil(viewModel.notice)
        XCTAssertEqual(viewModel.activity, .idle)
    }

    func testATruncatedExportSaysSoBeforeSharing() async throws {
        let viewModel = makeViewModel(
            export: { Self.exportResult(connectionCount: 20_000, truncated: true) }
        )

        await viewModel.exportFlows()

        let note = try XCTUnwrap(viewModel.pendingExport?.truncationNote)
        XCTAssertTrue(note.contains("more than this"))
    }

    func testAnEmptyHistoryIsNotOfferedAsAFileToShare() async {
        // Una hoja del sistema con un fichero de cero conexiones es un gesto que no lleva a ninguna
        // parte: es más corto decirlo.
        let viewModel = makeViewModel(export: { Self.exportResult(connectionCount: 0) })

        await viewModel.exportFlows()

        XCTAssertNil(viewModel.pendingExport)
        XCTAssertEqual(viewModel.notice, CapturesPresentation.nothingToExport)
    }

    func testAHistoryThatCannotBeReadIsReportedAsSuchAndNotAsAWriteFailure() async throws {
        let viewModel = makeViewModel(
            export: { throw FlowExportError.historyUnreadable(.queryFailed("db is locked")) }
        )

        await viewModel.exportFlows()

        let notice = try XCTUnwrap(viewModel.notice)
        XCTAssertTrue(notice.message.contains("Couldn't read your history"))
        XCTAssertEqual(notice.role, .warning)
        XCTAssertNil(viewModel.pendingExport)
    }

    func testAFailedWriteIsReportedWithItsDetail() async throws {
        let viewModel = makeViewModel(export: { throw FlowExportError.writeFailed("disk is full") })

        await viewModel.exportFlows()

        let notice = try XCTUnwrap(viewModel.notice)
        XCTAssertTrue(notice.message.contains("Couldn't write"))
        XCTAssertEqual(notice.diagnostic, "disk is full")
    }

    func testAnErrorThatIsNotOursStillReachesTheUser() async throws {
        // La fábrica del historial puede lanzar lo que quiera (abrir la BD es de GRDB): tragárselo
        // dejaría el botón sin respuesta.
        struct Unexpected: Error {}
        let viewModel = makeViewModel(export: { throw Unexpected() })

        await viewModel.exportFlows()

        XCTAssertNotNil(viewModel.notice)
        XCTAssertNil(viewModel.pendingExport)
    }

    func testWhileTheExportIsBeingWrittenNoOtherActionStarts() async {
        // Escribir el listado tarda —es lo que hace real el estado `exporting` de la spec—, y durante
        // ese rato ni se rota ni se exporta otra vez: dos avisos peleándose por el mismo hueco.
        let gate = Gate()
        let viewModel = makeViewModel(export: {
            await gate.enterAndWait()
            return Self.exportResult(connectionCount: 3)
        })
        viewModel.tunnelStateDidChange(to: .live)

        let export = Task { await viewModel.exportFlows() }
        await gate.waitUntilEntered()

        XCTAssertEqual(viewModel.activity, .exporting)
        XCTAssertFalse(viewModel.canExport)
        XCTAssertFalse(viewModel.canRotate)

        await gate.open()
        await export.value

        XCTAssertEqual(viewModel.activity, .idle)
        XCTAssertNotNil(viewModel.pendingExport)
    }

    func testDismissingTheExportClearsIt() async {
        let viewModel = makeViewModel(export: { Self.exportResult(connectionCount: 3) })

        await viewModel.exportFlows()
        viewModel.dismissExport()

        XCTAssertNil(viewModel.pendingExport)
    }

    func testExportingDoesNotNeedTheTunnelRunning() async {
        // Lo que se lee es el historial, que está guardado con la monitorización parada.
        let viewModel = makeViewModel(export: { Self.exportResult(connectionCount: 3) })
        viewModel.tunnelStateDidChange(to: .off)

        XCTAssertTrue(viewModel.canExport)
        XCTAssertFalse(viewModel.canRotate)

        await viewModel.exportFlows()

        XCTAssertNotNil(viewModel.pendingExport)
    }
}

/// Una acción que se puede dejar a medias a voluntad, para mirar la pantalla **mientras** trabaja.
/// Sin esto, afirmar el estado `exporting` dependería de que dos tareas se ordenasen solas.
private actor Gate {
    private var entered = false
    private var opened = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    /// Avisa de que la acción empezó y se queda ahí hasta que la suelten.
    func enterAndWait() async {
        entered = true
        for waiter in enteredWaiters { waiter.resume() }
        enteredWaiters = []
        guard !opened else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func open() {
        opened = true
        for waiter in openWaiters { waiter.resume() }
        openWaiters = []
    }
}

/// Un directorio que se puede romper a voluntad, para ejercitar el único fallo que `CaptureLibrary`
/// puede tener: que el contenedor del App Group no se resuelva. La resolución es síncrona (la hace
/// cada operación antes de tocar disco), así que el estado va tras un `NSLock` y no tras un actor.
private final class FlakyDirectory: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var broken = false

    init(url: URL) {
        self.url = url
    }

    var isBroken: Bool {
        get { lock.lock(); defer { lock.unlock() }; return broken }
        set { lock.lock(); broken = newValue; lock.unlock() }
    }

    func resolve() throws -> URL {
        guard !isBroken else { throw CaptureLibraryError.containerUnavailable("group.test") }
        return url
    }
}

/// Unos topes que se pueden cambiar entre dos refrescos, como los cambia el usuario en Ajustes.
private final class SwitchableRetention: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = RetentionSettings.default

    var settings: RetentionSettings {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }

    func load() throws -> RetentionSettings { settings }
}
