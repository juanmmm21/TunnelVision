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

    private func makeViewModel(
        storeAvailable: Bool = true,
        conditions: Conditions = Conditions(InspectionConditions(inspectionEnabled: true, caTrusted: true))
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
            inspection: { InspectionConditions(inspectionEnabled: false, caTrusted: false) }
        )
        try await makeProject(viewModel)

        isBroken.set(InspectionConditions(inspectionEnabled: true, caTrusted: false))
        await viewModel.refresh()

        XCTAssertEqual(viewModel.content, .list)
        XCTAssertEqual(viewModel.projectRows.count, 1)
        XCTAssertEqual(viewModel.notice?.role, .warning)
    }
}
