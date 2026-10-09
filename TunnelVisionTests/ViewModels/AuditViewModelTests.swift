import Foundation
import XCTest
@testable import Shared

/// Tests del view model de auditoría, contra un `FlowStore` **real** sobre una BD temporal: lo que se
/// afirma es el ciclo de vida entero —crear un proyecto, abrir una sesión, marcar, cerrar, borrar— tal
/// y como lo recorren las tres pantallas, y que la sesión abierta se ve desde fuera de ellas.
@MainActor
final class AuditViewModelTests: XCTestCase {

    private var dbURL: URL!

    override func setUp() {
        super.setUp()
        dbURL = PersistenceFixtures.temporaryDatabaseURL()
    }

    override func tearDown() {
        PersistenceFixtures.removeDatabase(at: dbURL)
        dbURL = nil
        super.tearDown()
    }

    private struct StoreUnavailable: Error {}

    /// Un reloj que avanza un segundo por lectura: cada escritura queda fechada después de la anterior.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: TimeInterval = 0

        func now() -> Date {
            lock.lock(); defer { lock.unlock() }
            seconds += 1
            return Date(timeIntervalSince1970: 1_800_000_000 + seconds)
        }
    }

    /// Las condiciones de inspección, que un test puede cambiar entre dos lecturas.
    private final class Conditions: @unchecked Sendable {
        private let lock = NSLock()
        private var value: InspectionConditions

        init(_ value: InspectionConditions) { self.value = value }

        func set(_ new: InspectionConditions) { lock.lock(); value = new; lock.unlock() }

        func get() -> InspectionConditions { lock.lock(); defer { lock.unlock() }; return value }
    }

    private static let environment = AuditEnvironment(
        deviceModel: "iPhone18,3", osVersion: "26.5", toolVersion: "1.0.0 (1)"
    )

    /// Una exportación sin guion: un test que no exporta no debería llegar a pedirla.
    private static let noExport: AuditViewModel.EvidenceExport = { _, _ in
        throw EvidenceExportError.writeFailed("este test no exporta")
    }

    private func makeViewModel(
        storeAvailable: Bool = true,
        conditions: Conditions = Conditions(InspectionConditions(inspectionEnabled: true, caTrusted: true)),
        export: @escaping AuditViewModel.EvidenceExport = AuditViewModelTests.noExport
    ) -> AuditViewModel {
        let url = dbURL!
        let clock = Clock()
        return AuditViewModel(
            library: AuditLibrary(openingStore: {
                guard storeAvailable else { throw StoreUnavailable() }
                return try FlowStore(databaseURL: url, anchor: PersistenceFixtures.anchor)
            }),
            environment: { Self.environment },
            inspection: { conditions.get() },
            exportEvidence: export,
            now: { clock.now() }
        )
    }

    private func projectForm(_ name: String = "Example Health") -> AuditProjectForm {
        var form = AuditProjectForm()
        form.name = name
        form.lines = [AllowlistLine(pattern: "api.example.com", note: "Backend")]
        return form
    }

    private func auditForm(version: String = "2.4.0", build: String = "187") -> AuditSessionForm {
        var form = AuditSessionForm(role: .audit)
        form.version = version
        form.build = build
        return form
    }

    @discardableResult
    private func makeProject(_ viewModel: AuditViewModel, name: String = "Example Health") async throws -> Int64 {
        let issue = await viewModel.save(projectForm(name), editing: nil)
        XCTAssertNil(issue)
        return try XCTUnwrap(viewModel.overview.projects.first { $0.project.name == name }?.id)
    }

    // MARK: - Carga

    func testAnEmptyStoreTeachesInsteadOfShowingAnEmptyList() async {
        let viewModel = makeViewModel()
        XCTAssertEqual(viewModel.content, .loading)

        await viewModel.refresh()

        guard case .placeholder(let placeholder) = viewModel.content else {
            return XCTFail("sin proyectos la pantalla enseña el vacío")
        }
        XCTAssertEqual(placeholder.action, .newProject)
        XCTAssertNil(viewModel.recordingBanner)
    }

    func testAHistoryThatCannotBeOpenedIsTheBodyOfTheScreen() async {
        let viewModel = makeViewModel(storeAvailable: false)

        await viewModel.refresh()

        guard case .placeholder(let placeholder) = viewModel.content else {
            return XCTFail("un fallo sin proyectos es el cuerpo de la pantalla")
        }
        XCTAssertEqual(placeholder.action, .retry)
    }

    // MARK: - Proyectos

    func testSavingAFormCreatesTheProjectAndListsIt() async throws {
        let viewModel = makeViewModel()

        let id = try await makeProject(viewModel)

        XCTAssertEqual(viewModel.content, .list)
        XCTAssertEqual(viewModel.projectRows.map(\.name), ["Example Health"])
        XCTAssertEqual(viewModel.projectRows.first?.detail, "No sessions yet")
        let display = try XCTUnwrap(viewModel.projectDisplay(id: id))
        XCTAssertEqual(display.allowlist.map(\.pattern), ["api.example.com"])
        XCTAssertTrue(display.canStartSession)
    }

    func testAFormWithAnIssueWritesNothingAndReturnsIt() async {
        let viewModel = makeViewModel()
        await viewModel.refresh()

        let issue = await viewModel.save(projectForm("   "), editing: nil)

        XCTAssertEqual(issue, .emptyProjectName)
        XCTAssertTrue(viewModel.overview.projects.isEmpty)
        XCTAssertNil(viewModel.notice, "lo que tiene mal el formulario lo dice la hoja, no un aviso detrás")
    }

    func testEditingRewritesTheProjectAndKeepsItsSessions() async throws {
        let viewModel = makeViewModel()
        let id = try await makeProject(viewModel)
        _ = await viewModel.startSession(AuditSessionForm(role: .baseline), projectID: id)

        var form = AuditProjectForm(editing: try XCTUnwrap(viewModel.project(id: id)?.project))
        form.name = "Example Health 2"
        form.lines.append(AllowlistLine(pattern: "*.cdn.example.com"))
        let issue = await viewModel.save(form, editing: id)

        XCTAssertNil(issue)
        let display = try XCTUnwrap(viewModel.projectDisplay(id: id))
        XCTAssertEqual(display.name, "Example Health 2")
        XCTAssertEqual(display.allowlist.map(\.pattern), ["api.example.com", "*.cdn.example.com"])
        XCTAssertEqual(display.sessions.count, 1)
    }

    func testDeletingAProjectRemovesItAndWhateverWasRecording() async throws {
        let viewModel = makeViewModel()
        let id = try await makeProject(viewModel)
        _ = await viewModel.startSession(auditForm(), projectID: id)
        XCTAssertNotNil(viewModel.recordingBanner)

        await viewModel.deleteProject(id: id)

        XCTAssertNil(viewModel.projectDisplay(id: id))
        XCTAssertNil(viewModel.recordingBanner, "la sesión abierta se fue con su proyecto: nada sigue etiquetando")
    }

    // MARK: - Sesiones

    func testStartingASessionDeclaresTheDeviceAndTheInspectionOfThatInstant() async throws {
        let conditions = Conditions(InspectionConditions(inspectionEnabled: false, caTrusted: false))
        let viewModel = makeViewModel(conditions: conditions)
        let id = try await makeProject(viewModel)

        // El formulario las enseña antes de grabar…
        await viewModel.prepareSessionForm()
        XCTAssertEqual(viewModel.currentInspection?.supportsPinningEvidence, false)

        // …y el usuario va a Ajustes y enciende la inspección antes de confirmar.
        conditions.set(InspectionConditions(inspectionEnabled: true, caTrusted: true))
        let issue = await viewModel.startSession(auditForm(), projectID: id)

        XCTAssertNil(issue)
        let session = try XCTUnwrap(viewModel.overview.recording?.session)
        XCTAssertEqual(session.kind, .audit(AppRelease(version: "2.4.0", build: "187")))
        XCTAssertEqual(session.environment, Self.environment)
        // Las del instante en que empieza, no las que se leyeron al abrir el formulario.
        XCTAssertTrue(session.inspection.supportsPinningEvidence)
    }

    func testASessionWithoutAReleaseIsNotStarted() async throws {
        let viewModel = makeViewModel()
        let id = try await makeProject(viewModel)

        let issue = await viewModel.startSession(auditForm(version: "2.4.0", build: " "), projectID: id)

        XCTAssertEqual(issue, .missingRelease)
        XCTAssertNil(viewModel.overview.recording)
    }

    func testAnOpenSessionIsSeenFromOutsideItsScreenAndBlocksEveryProject() async throws {
        let viewModel = makeViewModel()
        let first = try await makeProject(viewModel, name: "First")
        let second = try await makeProject(viewModel, name: "Second")

        _ = await viewModel.startSession(auditForm(), projectID: first)

        // Es lo que la Dashboard enseña: una sesión olvidada tiene que verse desde donde se ve el túnel.
        let banner = try XCTUnwrap(viewModel.recordingBanner)
        XCTAssertEqual(banner.projectID, first)
        XCTAssertTrue(banner.detail.contains("First"))
        XCTAssertEqual(viewModel.projectRows.first { $0.id == first }?.isRecording, true)

        // Solo hay una abierta en toda la BD: el otro proyecto tampoco puede abrir la suya.
        let other = try XCTUnwrap(viewModel.projectDisplay(id: second))
        XCTAssertFalse(other.canStartSession)
        XCTAssertTrue(other.startBlockedNote?.contains("First") ?? false)

        // Y si aun así se intenta, el store lo rechaza y se cuenta con su salida.
        let issue = await viewModel.startSession(AuditSessionForm(role: .baseline), projectID: second)
        XCTAssertNil(issue, "no es un problema del formulario")
        XCTAssertTrue(viewModel.notice?.message.contains("still recording") ?? false)
        XCTAssertEqual(viewModel.overview.projects.flatMap(\.sessions).count, 1)
    }

    func testMarkersAreStampedAndListedAsTheyHappen() async throws {
        let viewModel = makeViewModel()
        let id = try await makeProject(viewModel)
        _ = await viewModel.startSession(auditForm(), projectID: id)
        let session = try XCTUnwrap(viewModel.overview.recording?.session)

        await viewModel.loadSession(id: session.id)
        XCTAssertEqual(viewModel.sessionDisplay?.markers.count, 0)

        await viewModel.addMarker(.consentGiven, toSession: session.id)
        await viewModel.addMarker(.custom("  First sync  "), toSession: session.id)

        let display = try XCTUnwrap(viewModel.sessionDisplay)
        XCTAssertEqual(display.markers.map(\.title), ["Consent given", "First sync"])
        XCTAssertLessThan(display.markers[0].date, display.markers[1].date)
        XCTAssertGreaterThan(display.markers[0].date, session.startedAt)
    }

    func testComingBackShowsAMarkerPlacedFromOutsideTheApp() async throws {
        let viewModel = makeViewModel()
        let id = try await makeProject(viewModel)
        _ = await viewModel.startSession(auditForm(), projectID: id)
        let session = try XCTUnwrap(viewModel.overview.recording?.session)
        await viewModel.loadSession(id: session.id)
        XCTAssertEqual(viewModel.sessionDisplay?.markers.count, 0)

        // El control o el atajo: otro store sobre la misma base, sin pasar por el view model.
        let outside = try FlowStore(databaseURL: dbURL, anchor: PersistenceFixtures.anchor)
        let outcome = try await outside.addMarkerToOpenSession(
            .consentGiven, at: session.startedAt.addingTimeInterval(5)
        )
        guard case .placed = outcome else { return XCTFail("se esperaba un marcador puesto, no \(outcome)") }
        XCTAssertEqual(viewModel.sessionDisplay?.markers.count, 0, "nadie se lo ha dicho todavía")

        await viewModel.resume()

        XCTAssertEqual(viewModel.sessionDisplay?.markers.map(\.title), ["Consent given"])
    }

    func testComingBackSeesASessionThatIsNoLongerThere() async throws {
        let viewModel = makeViewModel()
        let id = try await makeProject(viewModel)
        _ = await viewModel.startSession(auditForm(), projectID: id)
        let session = try XCTUnwrap(viewModel.overview.recording?.session)
        await viewModel.loadSession(id: session.id)

        let outside = try FlowStore(databaseURL: dbURL, anchor: PersistenceFixtures.anchor)
        try await outside.deleteAuditSession(id: session.id)

        await viewModel.resume()

        XCTAssertNil(viewModel.recordingBanner)
        XCTAssertNil(viewModel.sessionDisplay)
    }

    func testEndingASessionStopsTheRecordingAndRefusesFurtherMarkers() async throws {
        let viewModel = makeViewModel()
        let id = try await makeProject(viewModel)
        _ = await viewModel.startSession(auditForm(), projectID: id)
        let session = try XCTUnwrap(viewModel.overview.recording?.session)

        await viewModel.endSession(id: session.id)

        XCTAssertNil(viewModel.recordingBanner)
        XCTAssertEqual(viewModel.sessionDisplay?.isRecording, false)
        XCTAssertEqual(viewModel.projectDisplay(id: id)?.canStartSession, true)

        // Un marcador puesto después de mirar el tráfico ya no es una observación.
        await viewModel.addMarker(.loggedIn, toSession: session.id)
        XCTAssertTrue(viewModel.notice?.message.contains("already ended") ?? false)
        XCTAssertEqual(viewModel.sessionDisplay?.markers.count, 0)
    }

    func testTheSessionCountsTheConnectionsTheExtensionTaggedMeanwhile() async throws {
        let viewModel = makeViewModel()
        let id = try await makeProject(viewModel)
        _ = await viewModel.startSession(auditForm(), projectID: id)
        let session = try XCTUnwrap(viewModel.overview.recording?.session)

        // Otro store sobre la misma BD, que es lo que es la extensión.
        let extensionStore = try FlowStore(databaseURL: dbURL, anchor: PersistenceFixtures.anchor)
        _ = try await extensionStore.upsertFlow(
            PersistenceFixtures.flow(remote: ModelFixtures.v4(1, 1, 1, 1), firstSeen: 12, lastSeen: 20)
        )

        await viewModel.loadSession(id: session.id)

        XCTAssertEqual(viewModel.sessionDisplay?.connections, "1 connection")
    }

    func testDeletingASessionClosesItsScreenAndUntagsNothingElse() async throws {
        let viewModel = makeViewModel()
        let id = try await makeProject(viewModel)
        _ = await viewModel.startSession(AuditSessionForm(role: .baseline), projectID: id)
        let baseline = try XCTUnwrap(viewModel.overview.recording?.session)
        await viewModel.endSession(id: baseline.id)
        _ = await viewModel.startSession(auditForm(), projectID: id)
        let audit = try XCTUnwrap(viewModel.overview.recording?.session)
        await viewModel.loadSession(id: audit.id)

        await viewModel.deleteSession(id: audit.id)

        XCTAssertNil(viewModel.sessionDisplay)
        XCTAssertNil(viewModel.recordingBanner)
        XCTAssertEqual(viewModel.projectDisplay(id: id)?.sessions.map(\.title), ["Baseline"])
    }

    func testAFailedRefreshDoesNotWipeTheListAlreadyDrawn() async throws {
        let url = dbURL!
        let isBroken = Conditions(InspectionConditions(inspectionEnabled: false, caTrusted: false))
        let viewModel = AuditViewModel(
            library: AuditLibrary(openingStore: {
                // Se reutiliza el interruptor de las condiciones como «el historial ha dejado de abrirse».
                guard !isBroken.get().inspectionEnabled else { throw StoreUnavailable() }
                return try FlowStore(databaseURL: url, anchor: PersistenceFixtures.anchor)
            }),
            environment: { Self.environment },
            inspection: { InspectionConditions(inspectionEnabled: false, caTrusted: false) },
            exportEvidence: Self.noExport
        )
        try await makeProject(viewModel)

        isBroken.set(InspectionConditions(inspectionEnabled: true, caTrusted: false))
        await viewModel.refresh()

        XCTAssertEqual(viewModel.content, .list)
        XCTAssertEqual(viewModel.projectRows.count, 1)
        XCTAssertEqual(viewModel.notice?.role, .warning)
    }

    // MARK: - El paquete de evidencia

    /// Lo que se le pidió a la exportación.
    private final class ExportScript: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [(sessionID: Int64, date: Date)] = []

        /// Apunta la petición y devuelve cuántas van con ella.
        @discardableResult
        func record(_ sessionID: Int64, _ date: Date) -> Int {
            lock.lock(); defer { lock.unlock() }
            requests.append((sessionID, date))
            return requests.count
        }

        var asked: [(sessionID: Int64, date: Date)] {
            lock.lock(); defer { lock.unlock() }; return requests
        }
    }

    private nonisolated static func exportResult(
        sessionID: Int64,
        lost: [EvidencePacketLoss: Int] = [:]
    ) -> EvidenceExportResult {
        EvidenceExportResult(
            url: URL(fileURLWithPath: "/tmp/tunnelvision-evidence-session-\(sessionID)-20261009-203000.zip"),
            byteCount: 2_048,
            fileNames: ["capture.json", "capture.pcapng", "manifest.json"],
            flowCount: 3,
            findingCount: 1,
            capture: EvidenceCaptureDocument(
                sessionID: sessionID,
                snaplen: nil,
                flows: [.init(id: 1, packets: EvidencePacketTally(written: 9, lost: lost))],
                sourceFiles: [],
                writtenOutsideSession: .init(beforeStart: 0, afterEnd: 0)
            )
        )
    }

    /// Un proyecto con una sesión de auditoría ya cerrada, y su pantalla abierta.
    private func closedSession(_ viewModel: AuditViewModel) async throws -> AuditSession {
        let id = try await makeProject(viewModel)
        _ = await viewModel.startSession(auditForm(), projectID: id)
        let session = try XCTUnwrap(viewModel.overview.recording?.session)
        await viewModel.endSession(id: session.id)
        return session
    }

    /// El exportador de verdad sobre el historial del test y un temporal propio.
    private func realExporter(in root: URL) -> EvidenceExporter {
        let url = dbURL!
        return EvidenceExporter(
            directory: root.appendingPathComponent("EvidenceExports", isDirectory: true),
            captureDirectory: root.appendingPathComponent("Captures", isDirectory: true),
            openingStore: { try FlowStore(databaseURL: url, anchor: PersistenceFixtures.anchor) }
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-view-model-tests-\(UUID().uuidString)", isDirectory: true)
    }

    func testExportingLeavesTheBundleToBeShownBeforeItIsShared() async throws {
        let script = ExportScript()
        let viewModel = makeViewModel(export: { sessionID, date in
            script.record(sessionID, date)
            return Self.exportResult(sessionID: sessionID, lost: [.notCaptured: 2])
        })
        let session = try await closedSession(viewModel)

        await viewModel.exportEvidence(ofSession: session.id)

        let summary = try XCTUnwrap(viewModel.pendingEvidence)
        XCTAssertEqual(summary.fileName, "tunnelvision-evidence-session-\(session.id)-20261009-203000.zip")
        XCTAssertEqual(summary.capture.headline, "9 of 11 recorded packets are in the capture.")
        XCTAssertNil(viewModel.notice)
        XCTAssertFalse(viewModel.isWorking)
        XCTAssertFalse(viewModel.isExportingEvidence)

        XCTAssertEqual(script.asked.map(\.sessionID), [session.id])
        let endedAt = try XCTUnwrap(viewModel.overview.projects.first?.sessions.first?.endedAt)
        XCTAssertGreaterThan(try XCTUnwrap(script.asked.first?.date), endedAt, "el instante es el del toque")

        viewModel.dismissEvidenceExport()
        XCTAssertNil(viewModel.pendingEvidence)
    }

    func testEveryExportFailureIsANoticeAndNeverASheet() async throws {
        let failures: [EvidenceExportError] = [
            .catalogueNotBundled(identifier: "tr-03161-1_9.9"),
            .catalogueUnusable(identifier: "tr-03161-1_3.0"),
            .historyUnreadable(.queryFailed("database is locked")),
            .historyChangedWhileExporting,
            .captureDirectoryUnavailable("containerUnavailable"),
            .writeFailed("No space left on device"),
            .sessionStillOpen,
            .sessionNotFound,
        ]
        let script = ExportScript()
        let viewModel = makeViewModel(export: { sessionID, date in
            throw failures[script.record(sessionID, date) - 1]
        })
        let session = try await closedSession(viewModel)

        for failure in failures {
            await viewModel.exportEvidence(ofSession: session.id)

            XCTAssertEqual(viewModel.notice, AuditPresentation.evidenceExportFailed(failure), "\(failure)")
            XCTAssertNil(viewModel.pendingEvidence, "\(failure)")
            XCTAssertFalse(viewModel.isWorking, "\(failure)")
        }
    }

    func testAnUntypedExportErrorIsStillSaid() async throws {
        let viewModel = makeViewModel(export: { _, _ in throw StoreUnavailable() })
        let session = try await closedSession(viewModel)

        await viewModel.exportEvidence(ofSession: session.id)

        XCTAssertEqual(
            viewModel.notice?.message,
            AuditPresentation.evidenceExportFailed(.writeFailed("")).message
        )
        XCTAssertNil(viewModel.pendingEvidence)
    }

    func testAFailedExportDoesNotTakeAwayABundleAlreadyShown() async throws {
        let script = ExportScript()
        let viewModel = makeViewModel(export: { sessionID, date in
            guard script.record(sessionID, date) == 1 else {
                throw EvidenceExportError.historyChangedWhileExporting
            }
            return Self.exportResult(sessionID: sessionID)
        })
        let session = try await closedSession(viewModel)
        await viewModel.exportEvidence(ofSession: session.id)
        let shown = try XCTUnwrap(viewModel.pendingEvidence)

        await viewModel.exportEvidence(ofSession: session.id)

        XCTAssertEqual(viewModel.pendingEvidence, shown)
        XCTAssertEqual(viewModel.notice, AuditPresentation.evidenceExportFailed(.historyChangedWhileExporting))
    }

    func testASessionDeletedElsewhereClosesItsScreenWhenExportFindsOut() async throws {
        let url = dbURL!
        let viewModel = makeViewModel(export: { sessionID, _ in
            // Otro gesto la borra entre el toque y la lectura.
            let other = try FlowStore(databaseURL: url, anchor: PersistenceFixtures.anchor)
            try await other.deleteAuditSession(id: sessionID)
            throw EvidenceExportError.sessionNotFound
        })
        let session = try await closedSession(viewModel)
        XCTAssertEqual(viewModel.sessionDisplay?.id, session.id)

        await viewModel.exportEvidence(ofSession: session.id)

        XCTAssertNil(viewModel.sessionDisplay)
        XCTAssertEqual(viewModel.notice, AuditPresentation.evidenceExportFailed(.sessionNotFound))
        XCTAssertEqual(viewModel.overview.projects.first?.sessions.count, 0)
    }

    func testWhileABundleIsBeingWrittenNothingElseWritesAndASecondExportIsIgnored() async throws {
        let (gate, release) = AsyncStream<Void>.makeStream()
        let script = ExportScript()
        let viewModel = makeViewModel(export: { sessionID, date in
            script.record(sessionID, date)
            for await _ in gate { break }
            return Self.exportResult(sessionID: sessionID)
        })
        let session = try await closedSession(viewModel)

        let running = Task { await viewModel.exportEvidence(ofSession: session.id) }
        while script.asked.isEmpty { await Task.yield() }

        XCTAssertTrue(viewModel.isWorking)
        XCTAssertTrue(viewModel.isExportingEvidence)
        XCTAssertNil(viewModel.pendingEvidence)

        await viewModel.exportEvidence(ofSession: session.id)
        await viewModel.deleteSession(id: session.id)
        XCTAssertEqual(script.asked.count, 1)

        release.yield()
        await running.value

        XCTAssertNotNil(viewModel.pendingEvidence)
        XCTAssertFalse(viewModel.isWorking)
        XCTAssertFalse(viewModel.isExportingEvidence)
        XCTAssertEqual(viewModel.overview.projects.first?.sessions.count, 1, "el borrado no llegó a hacerse")
    }

    /// El acoplamiento de verdad: el exportador real sobre el mismo historial, y un zip en disco.
    func testTheRealExporterWritesAnArchiveForAClosedSession() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let exporter = realExporter(in: root)
        let viewModel = makeViewModel(export: { sessionID, date in
            try await exporter.export(sessionID: sessionID, exportedWith: "1.1 (4)", now: date)
        })
        let id = try await makeProject(viewModel)
        _ = await viewModel.startSession(auditForm(), projectID: id)
        let session = try XCTUnwrap(viewModel.overview.recording?.session)
        let extensionStore = try FlowStore(databaseURL: dbURL, anchor: PersistenceFixtures.anchor)
        _ = try await extensionStore.upsertFlow(
            PersistenceFixtures.flow(remote: ModelFixtures.v4(1, 1, 1, 1), firstSeen: 12, lastSeen: 20)
        )
        await viewModel.endSession(id: session.id)

        await viewModel.exportEvidence(ofSession: session.id)

        XCTAssertNil(viewModel.notice)
        let summary = try XCTUnwrap(viewModel.pendingEvidence)
        XCTAssertTrue(EvidenceExportNaming.isExportName(summary.fileName))
        XCTAssertTrue(FileManager.default.fileExists(atPath: summary.url.path))
        XCTAssertEqual(summary.facts.first?.value, .text("1"))
        XCTAssertEqual(summary.capture.headline, "This session recorded no packets, so the capture is empty.")
    }

    func testAnOpenSessionIsRefusedByTheRealExporterInASentence() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let exporter = realExporter(in: root)
        let viewModel = makeViewModel(export: { sessionID, date in
            try await exporter.export(sessionID: sessionID, exportedWith: "1.1 (4)", now: date)
        })
        let id = try await makeProject(viewModel)
        _ = await viewModel.startSession(auditForm(), projectID: id)
        let session = try XCTUnwrap(viewModel.overview.recording?.session)

        await viewModel.exportEvidence(ofSession: session.id)

        XCTAssertEqual(viewModel.notice, AuditPresentation.evidenceExportFailed(.sessionStillOpen))
        XCTAssertNil(viewModel.pendingEvidence)
    }
}
