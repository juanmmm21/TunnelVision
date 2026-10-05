import XCTest
import GRDB
@testable import Shared

/// Tests de la mitad de auditoría del store (esquema `v6`, ADR 0008). Lo que se afirma es lo que el
/// informe va a dar por cierto: que un proyecto vuelve como se escribió, que solo hay una sesión
/// abierta, que un flujo pertenece a la sesión que estaba abierta mientras tuvo tráfico, y que borrar
/// la auditoría no se lleva el historial.
final class AuditStoreTests: XCTestCase {

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

    private func makeStore(anchor: MonotonicAnchor = PersistenceFixtures.anchor) throws -> FlowStore {
        try FlowStore(databaseURL: dbURL, anchor: anchor)
    }

    private static let release = AppRelease(version: "2.4.0", build: "187")

    private func entry(_ text: String, note: String? = nil) throws -> AllowlistEntry {
        AllowlistEntry(pattern: try DomainPattern(parsing: text), note: note)
    }

    private func projectDraft(
        name: String = "Example Health",
        allowlist: [AllowlistEntry] = []
    ) -> AuditProjectDraft {
        AuditProjectDraft(
            name: name,
            bundleIdentifier: "com.example.health",
            catalogueVersion: nil,
            allowlist: allowlist
        )
    }

    private func sessionDraft(
        project: Int64,
        kind: AuditSessionKind = .audit(AuditStoreTests.release),
        inspection: InspectionConditions = InspectionConditions(inspectionEnabled: true, caTrusted: true),
        notes: String = ""
    ) -> AuditSessionDraft {
        AuditSessionDraft(
            projectID: project,
            kind: kind,
            environment: AuditEnvironment(deviceModel: "iPhone18,3", osVersion: "27.0", toolVersion: "1.0.0 (1)"),
            inspection: inspection,
            notes: notes
        )
    }

    private func makeProject(_ store: FlowStore) async throws -> AuditProject {
        try await store.createAuditProject(projectDraft(), at: PersistenceFixtures.date(0))
    }

    private func upsert(
        _ store: FlowStore, remote: IPAddress, firstSeen: UInt64, lastSeen: UInt64
    ) async throws -> Int64 {
        try await store.upsertFlow(
            PersistenceFixtures.flow(remote: remote, firstSeen: firstSeen, lastSeen: lastSeen)
        )
    }

    private func assert<T>(
        _ expression: @autoclosure () async throws -> T,
        throws expected: AuditStoreError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("se esperaba \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AuditStoreError, expected, file: file, line: line)
        }
    }

    // MARK: - Proyectos

    func testAProjectReadsBackAsItWasWritten() async throws {
        let store = try makeStore()
        let allowlist = [
            try entry("api.example.com", note: "backend"),
            try entry("*.sentry.io", note: "crash reporting"),
            try entry("cdn.example.com"),
        ]
        let created = try await store.createAuditProject(
            projectDraft(allowlist: allowlist), at: PersistenceFixtures.date(5)
        )

        XCTAssertEqual(created.name, "Example Health")
        XCTAssertEqual(created.bundleIdentifier, "com.example.health")
        XCTAssertNil(created.catalogueVersion)
        XCTAssertEqual(created.allowlist, allowlist)
        XCTAssertEqual(created.createdAt, PersistenceFixtures.date(5))

        let read = try await store.auditProject(id: created.id)
        XCTAssertEqual(read, created)
    }

    func testTheAllowlistKeepsTheOrderItWasWrittenIn() async throws {
        let store = try makeStore()
        let allowlist = [try entry("zeta.example.com"), try entry("alpha.example.com"), try entry("*.mid.example.com")]
        let created = try await store.createAuditProject(
            projectDraft(allowlist: allowlist), at: PersistenceFixtures.date(0)
        )
        let read = try await store.auditProject(id: created.id)
        XCTAssertEqual(read?.allowlist.map(\.pattern.text), ["zeta.example.com", "alpha.example.com", "*.mid.example.com"])
    }

    func testAProjectNameIsTrimmedAndCannotBeEmpty() async throws {
        let store = try makeStore()
        let created = try await store.createAuditProject(
            projectDraft(name: "  Example  "), at: PersistenceFixtures.date(0)
        )
        XCTAssertEqual(created.name, "Example")

        await assert(
            try await store.createAuditProject(self.projectDraft(name: "   "), at: PersistenceFixtures.date(0)),
            throws: .emptyProjectName
        )
    }

    /// Dos escrituras del mismo nombre son el mismo patrón una vez normalizado, y una allowlist que lo
    /// lleva dos veces tendría dos notas para una sola conexión.
    func testTheSamePatternTwiceIsRejectedAndNothingIsWritten() async throws {
        let store = try makeStore()
        let allowlist = [try entry("api.example.com"), try entry("API.Example.com.")]
        await assert(
            try await store.createAuditProject(self.projectDraft(allowlist: allowlist), at: PersistenceFixtures.date(0)),
            throws: .duplicateAllowlistPattern("api.example.com")
        )
        let projects = try await store.auditProjects()
        XCTAssertTrue(projects.isEmpty)
    }

    func testProjectsAreListedNewestFirstAndEachHasItsOwnAllowlist() async throws {
        let store = try makeStore()
        let older = try await store.createAuditProject(
            projectDraft(name: "Older", allowlist: [try entry("a.example.com")]), at: PersistenceFixtures.date(1)
        )
        let newer = try await store.createAuditProject(
            projectDraft(name: "Newer", allowlist: [try entry("a.example.com"), try entry("b.example.com")]),
            at: PersistenceFixtures.date(2)
        )
        let projects = try await store.auditProjects()
        XCTAssertEqual(projects.map(\.id), [newer.id, older.id])
        XCTAssertEqual(projects.map(\.allowlist.count), [2, 1])
    }

    func testAMissingProjectIsNilAndDeletingItIsAnError() async throws {
        let store = try makeStore()
        let missing = try await store.auditProject(id: 99)
        XCTAssertNil(missing)
        await assert(try await store.deleteAuditProject(id: 99), throws: .projectNotFound(99))
    }

    // MARK: - Sesiones

    func testASessionReadsBackAsItWasStarted() async throws {
        let store = try makeStore()
        let project = try await makeProject(store)
        let draft = sessionDraft(
            project: project.id,
            inspection: InspectionConditions(inspectionEnabled: true, caTrusted: false),
            notes: "primera pasada del onboarding"
        )
        let session = try await store.startAuditSession(draft, at: PersistenceFixtures.date(10))

        XCTAssertEqual(session.projectID, project.id)
        XCTAssertEqual(session.kind, .audit(Self.release))
        XCTAssertEqual(session.environment, draft.environment)
        XCTAssertEqual(session.inspection, draft.inspection)
        XCTAssertEqual(session.startedAt, PersistenceFixtures.date(10))
        XCTAssertNil(session.endedAt)
        XCTAssertTrue(session.isOpen)
        XCTAssertEqual(session.notes, "primera pasada del onboarding")

        let read = try await store.auditSession(id: session.id)
        XCTAssertEqual(read, session)
        let open = try await store.openAuditSession()
        XCTAssertEqual(open, session)
    }

    func testABaselineSessionCarriesNoRelease() async throws {
        let store = try makeStore()
        let project = try await makeProject(store)
        let session = try await store.startAuditSession(
            sessionDraft(project: project.id, kind: .baseline), at: PersistenceFixtures.date(10)
        )
        let read = try await store.auditSession(id: session.id)
        XCTAssertEqual(read?.kind, .baseline)
        XCTAssertNil(read?.kind.release)
    }

    func testASessionNeedsAnExistingProject() async throws {
        let store = try makeStore()
        await assert(
            try await store.startAuditSession(self.sessionDraft(project: 99), at: PersistenceFixtures.date(10)),
            throws: .projectNotFound(99)
        )
    }

    func testOnlyOneSessionCanBeOpenEvenAcrossProjects() async throws {
        let store = try makeStore()
        let first = try await makeProject(store)
        let second = try await store.createAuditProject(projectDraft(name: "Other"), at: PersistenceFixtures.date(1))
        let open = try await store.startAuditSession(sessionDraft(project: first.id), at: PersistenceFixtures.date(10))

        await assert(
            try await store.startAuditSession(self.sessionDraft(project: second.id), at: PersistenceFixtures.date(11)),
            throws: .sessionAlreadyOpen(open.id)
        )
    }

    /// La regla no es solo del código: la extensión etiqueta con «la sesión abierta», así que el
    /// esquema tiene que impedir dos aunque alguien escriba la tabla por otro camino.
    func testTheSchemaItselfRefusesASecondOpenSession() async throws {
        let store = try makeStore()
        let project = try await makeProject(store)
        _ = try await store.startAuditSession(sessionDraft(project: project.id), at: PersistenceFixtures.date(10))

        let raw = try DatabaseQueue(path: dbURL.path)
        defer { try? raw.close() }
        do {
            try await raw.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO audit_sessions
                        (project_id, kind, device_model, os_version, tool_version,
                         inspection_enabled, ca_trusted, started_at, ended_at, notes)
                    VALUES (?, 1, 'x', 'x', 'x', 0, 0, 0, NULL, '')
                    """,
                    arguments: [project.id]
                )
            }
            XCTFail("el índice único debía rechazar la segunda sesión abierta")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
        }
    }

    func testEndingASessionClosesItAndLetsAnotherStart() async throws {
        let store = try makeStore()
        let project = try await makeProject(store)
        let session = try await store.startAuditSession(sessionDraft(project: project.id), at: PersistenceFixtures.date(10))

        let ended = try await store.endAuditSession(id: session.id, at: PersistenceFixtures.date(70))
        XCTAssertEqual(ended.endedAt, PersistenceFixtures.date(70))
        XCTAssertFalse(ended.isOpen)
        let open = try await store.openAuditSession()
        XCTAssertNil(open)

        let next = try await store.startAuditSession(sessionDraft(project: project.id), at: PersistenceFixtures.date(80))
        XCTAssertNotEqual(next.id, session.id)
    }

    func testASessionCannotEndTwiceNorBeforeItStartedNorIfItDoesNotExist() async throws {
        let store = try makeStore()
        let project = try await makeProject(store)
        let session = try await store.startAuditSession(sessionDraft(project: project.id), at: PersistenceFixtures.date(10))

        await assert(try await store.endAuditSession(id: 99, at: PersistenceFixtures.date(20)), throws: .sessionNotFound(99))
        await assert(
            try await store.endAuditSession(id: session.id, at: PersistenceFixtures.date(9)),
            throws: .dateBeforeSessionStart
        )
        _ = try await store.endAuditSession(id: session.id, at: PersistenceFixtures.date(20))
        await assert(
            try await store.endAuditSession(id: session.id, at: PersistenceFixtures.date(30)),
            throws: .sessionAlreadyEnded(session.id)
        )
        // El primer cierre es el que queda.
        let read = try await store.auditSession(id: session.id)
        XCTAssertEqual(read?.endedAt, PersistenceFixtures.date(20))
    }

    func testSessionsOfAProjectAreListedNewestFirstAndOnlyItsOwn() async throws {
        let store = try makeStore()
        let project = try await makeProject(store)
        let other = try await store.createAuditProject(projectDraft(name: "Other"), at: PersistenceFixtures.date(1))

        let baseline = try await store.startAuditSession(
            sessionDraft(project: project.id, kind: .baseline), at: PersistenceFixtures.date(10)
        )
        _ = try await store.endAuditSession(id: baseline.id, at: PersistenceFixtures.date(20))
        let foreign = try await store.startAuditSession(sessionDraft(project: other.id), at: PersistenceFixtures.date(30))
        _ = try await store.endAuditSession(id: foreign.id, at: PersistenceFixtures.date(40))
        let audit = try await store.startAuditSession(sessionDraft(project: project.id), at: PersistenceFixtures.date(50))

        let sessions = try await store.auditSessions(forProject: project.id)
        XCTAssertEqual(sessions.map(\.id), [audit.id, baseline.id])
    }

    // MARK: - Marcadores

    func testMarkersComeBackInTheOrderTheyHappened() async throws {
        let store = try makeStore()
        let project = try await makeProject(store)
        let session = try await store.startAuditSession(sessionDraft(project: project.id), at: PersistenceFixtures.date(10))

        // Escritos fuera de orden a propósito: lo que ordena es el instante, no la inserción.
        _ = try await store.addMarker(.loggedIn, toSession: session.id, at: PersistenceFixtures.date(40))
        let consent = try await store.addMarker(.consentGiven, toSession: session.id, at: PersistenceFixtures.date(20))
        _ = try await store.addMarker(.custom("  abre la cámara "), toSession: session.id, at: PersistenceFixtures.date(50))
        _ = try await store.addMarker(.loggedOut, toSession: session.id, at: PersistenceFixtures.date(60))

        XCTAssertEqual(consent.sessionID, session.id)
        XCTAssertEqual(consent.date, PersistenceFixtures.date(20))

        let markers = try await store.markers(forSession: session.id)
        XCTAssertEqual(markers.map(\.kind), [.consentGiven, .loggedIn, .custom("abre la cámara"), .loggedOut])
        XCTAssertEqual(markers.map(\.date), [20, 40, 50, 60].map(PersistenceFixtures.date))
    }

    // MARK: - Marcar sin saber qué sesión está abierta

    func testAMarkerFromOutsideLandsInTheOpenSessionAndNamesItsProject() async throws {
        let store = try makeStore()
        let project = try await makeProject(store)
        let session = try await store.startAuditSession(sessionDraft(project: project.id), at: PersistenceFixtures.date(10))

        let outcome = try await store.addMarkerToOpenSession(.consentGiven, at: PersistenceFixtures.date(20))

        guard case .placed(let marker, in: let recording) = outcome else {
            return XCTFail("se esperaba un marcador puesto, no \(outcome)")
        }
        XCTAssertEqual(marker.sessionID, session.id)
        XCTAssertEqual(marker.date, PersistenceFixtures.date(20))
        XCTAssertEqual(recording, AuditRecording(session: session, projectName: "Example Health"))
        let markers = try await store.markers(forSession: session.id)
        XCTAssertEqual(markers, [marker])
    }

    func testWithNoOpenSessionNothingIsMarkedAndNoneIsOpened() async throws {
        let store = try makeStore()

        // Ni un proyecto siquiera.
        var outcome = try await store.addMarkerToOpenSession(.consentGiven, at: PersistenceFixtures.date(20))
        XCTAssertEqual(outcome, .noOpenSession)

        // Y con una sesión que ya terminó: no se reabre ni recibe el marcador.
        let project = try await makeProject(store)
        let session = try await store.startAuditSession(sessionDraft(project: project.id), at: PersistenceFixtures.date(10))
        _ = try await store.endAuditSession(id: session.id, at: PersistenceFixtures.date(30))

        outcome = try await store.addMarkerToOpenSession(.consentGiven, at: PersistenceFixtures.date(40))
        XCTAssertEqual(outcome, .noOpenSession)
        let markers = try await store.markers(forSession: session.id)
        XCTAssertTrue(markers.isEmpty)
        let open = try await store.openAuditSession()
        XCTAssertNil(open)
    }

    func testASessionEndedByAnotherProcessIsSeenByTheOneThatMarks() async throws {
        // Dos stores sobre la misma base: la app, que abre y cierra la sesión, y la extensión de
        // controles, que marca. Lo que una hace lo ve la otra sin que nadie se lo diga.
        let app = try makeStore()
        let controls = try makeStore()
        let project = try await makeProject(app)
        let session = try await app.startAuditSession(sessionDraft(project: project.id), at: PersistenceFixtures.date(10))

        let first = try await controls.addMarkerToOpenSession(.loggedIn, at: PersistenceFixtures.date(20))
        guard case .placed = first else { return XCTFail("se esperaba un marcador puesto, no \(first)") }
        let seenByTheApp = try await app.markers(forSession: session.id)
        XCTAssertEqual(seenByTheApp.map(\.kind), [.loggedIn])

        _ = try await app.endAuditSession(id: session.id, at: PersistenceFixtures.date(30))
        let second = try await controls.addMarkerToOpenSession(.loggedOut, at: PersistenceFixtures.date(40))
        XCTAssertEqual(second, .noOpenSession)
    }

    func testAMarkerFromOutsideObeysTheRulesOfAnyMarker() async throws {
        let store = try makeStore()
        let project = try await makeProject(store)
        let session = try await store.startAuditSession(sessionDraft(project: project.id), at: PersistenceFixtures.date(10))

        await assert(
            try await store.addMarkerToOpenSession(.consentGiven, at: PersistenceFixtures.date(5)),
            throws: .dateBeforeSessionStart
        )
        await assert(
            try await store.addMarkerToOpenSession(.custom("  "), at: PersistenceFixtures.date(20)),
            throws: .emptyMarkerLabel
        )
        let markers = try await store.markers(forSession: session.id)
        XCTAssertTrue(markers.isEmpty)
    }

    func testTheRecordingIsTheOpenSessionWithItsProjectsName() async throws {
        let store = try makeStore()
        let none = try await store.auditRecording()
        XCTAssertNil(none)

        let project = try await makeProject(store)
        let session = try await store.startAuditSession(sessionDraft(project: project.id), at: PersistenceFixtures.date(10))
        let recording = try await store.auditRecording()
        XCTAssertEqual(recording, AuditRecording(session: session, projectName: "Example Health"))

        _ = try await store.endAuditSession(id: session.id, at: PersistenceFixtures.date(30))
        let afterwards = try await store.auditRecording()
        XCTAssertNil(afterwards)
    }

    func testAMarkerNeedsAnOpenSessionAndADateInsideIt() async throws {
        let store = try makeStore()
        let project = try await makeProject(store)
        let session = try await store.startAuditSession(sessionDraft(project: project.id), at: PersistenceFixtures.date(10))

        await assert(
            try await store.addMarker(.consentGiven, toSession: 99, at: PersistenceFixtures.date(20)),
            throws: .sessionNotFound(99)
        )
        await assert(
            try await store.addMarker(.consentGiven, toSession: session.id, at: PersistenceFixtures.date(5)),
            throws: .dateBeforeSessionStart
        )
        await assert(
            try await store.addMarker(.custom("   "), toSession: session.id, at: PersistenceFixtures.date(20)),
            throws: .emptyMarkerLabel
        )

        _ = try await store.endAuditSession(id: session.id, at: PersistenceFixtures.date(30))
        await assert(
            try await store.addMarker(.consentGiven, toSession: session.id, at: PersistenceFixtures.date(25)),
            throws: .sessionAlreadyEnded(session.id)
        )
        let markers = try await store.markers(forSession: session.id)
        XCTAssertTrue(markers.isEmpty)
    }

    // MARK: - A qué sesión pertenece un flujo

    func testAFlowWrittenWithNoOpenSessionBelongsToNone() async throws {
        let store = try makeStore()
        let project = try await makeProject(store)
        let session = try await store.startAuditSession(sessionDraft(project: project.id), at: PersistenceFixtures.date(10))
        _ = try await store.endAuditSession(id: session.id, at: PersistenceFixtures.date(20))

        _ = try await upsert(store, remote: ModelFixtures.v4(1, 1, 1, 1), firstSeen: 30, lastSeen: 31)

        let flows = try await store.flows(inAuditSession: session.id, limit: 10)
        XCTAssertTrue(flows.isEmpty)
        let all = try await store.recentFlows(limit: 10)
        XCTAssertEqual(all.count, 1)
    }

    func testFlowsWrittenWhileASessionIsOpenBelongToItInTheOrderTheyBegan() async throws {
        let store = try makeStore()
        let project = try await makeProject(store)
        let session = try await store.startAuditSession(sessionDraft(project: project.id), at: PersistenceFixtures.date(10))

        // Volcados en orden contrario al de comienzo: lo que ordena es `first_seen`.
        let later = try await upsert(store, remote: ModelFixtures.v4(2, 2, 2, 2), firstSeen: 40, lastSeen: 45)
        let earlier = try await upsert(store, remote: ModelFixtures.v4(1, 1, 1, 1), firstSeen: 20, lastSeen: 50)

        let flows = try await store.flows(inAuditSession: session.id, limit: 10)
        XCTAssertEqual(flows.map(\.id), [earlier, later])

        let limited = try await store.flows(inAuditSession: session.id, limit: 1)
        XCTAssertEqual(limited.map(\.id), [earlier])
    }

    /// Una conexión que ya estaba abierta y sigue teniendo tráfico durante la sesión es parte de lo
    /// que la app hizo en ella: dejarla fuera le escondería al informe una conexión viva.
    func testAFlowThatBeganBeforeTheSessionJoinsItOnItsNextFlush() async throws {
        let store = try makeStore()
        let project = try await makeProject(store)
        let remote = ModelFixtures.v4(1, 1, 1, 1)

        let flowID = try await upsert(store, remote: remote, firstSeen: 1, lastSeen: 5)
        let session = try await store.startAuditSession(sessionDraft(project: project.id), at: PersistenceFixtures.date(10))
        let before = try await store.flows(inAuditSession: session.id, limit: 10)
        XCTAssertTrue(before.isEmpty, "sin tráfico durante la sesión no pertenece a ella")

        let sameFlow = try await upsert(store, remote: remote, firstSeen: 1, lastSeen: 15)
        XCTAssertEqual(sameFlow, flowID)
        let after = try await store.flows(inAuditSession: session.id, limit: 10)
        XCTAssertEqual(after.map(\.id), [flowID])
    }

    func testAFlowKeepsItsSessionAfterTheSessionEndsAndAnotherStarts() async throws {
        let store = try makeStore()
        let project = try await makeProject(store)
        let remote = ModelFixtures.v4(1, 1, 1, 1)

        let first = try await store.startAuditSession(sessionDraft(project: project.id), at: PersistenceFixtures.date(10))
        let flowID = try await upsert(store, remote: remote, firstSeen: 12, lastSeen: 15)
        _ = try await store.endAuditSession(id: first.id, at: PersistenceFixtures.date(20))

        // Sigue vivo sin sesión abierta, y luego durante otra.
        _ = try await upsert(store, remote: remote, firstSeen: 12, lastSeen: 25)
        let second = try await store.startAuditSession(sessionDraft(project: project.id), at: PersistenceFixtures.date(30))
        _ = try await upsert(store, remote: remote, firstSeen: 12, lastSeen: 35)

        let inFirst = try await store.flows(inAuditSession: first.id, limit: 10)
        XCTAssertEqual(inFirst.map(\.id), [flowID])
        let inSecond = try await store.flows(inAuditSession: second.id, limit: 10)
        XCTAssertTrue(inSecond.isEmpty)
    }

    /// Es el camino real: la app abre la sesión por su conexión y la extensión escribe por la suya.
    func testAStoreOpenedByAnotherProcessTagsWithTheSessionTheAppOpened() async throws {
        let app = try makeStore()
        let extensionStore = try makeStore(
            anchor: MonotonicAnchor(uptimeNanoseconds: 1_000_000_000, wallClock: PersistenceFixtures.date(100))
        )
        let project = try await makeProject(app)
        let session = try await app.startAuditSession(sessionDraft(project: project.id), at: PersistenceFixtures.date(100))

        let flowID = try await extensionStore.upsertFlow(
            PersistenceFixtures.flow(remote: ModelFixtures.v4(1, 1, 1, 1), firstSeen: 1, lastSeen: 2)
        )

        let flows = try await app.flows(inAuditSession: session.id, limit: 10)
        XCTAssertEqual(flows.map(\.id), [flowID])
    }

    // MARK: - Ficheros de captura de una sesión

    func testCaptureFilesOfASessionAreTheOnesItsPacketsPointAt() async throws {
        let store = try makeStore()
        let project = try await makeProject(store)

        // Antes de la sesión: su fichero no es de ella.
        let outsideKey = PersistenceFixtures.key(remote: ModelFixtures.v4(9, 9, 9, 9))
        let outside = try await upsert(store, remote: ModelFixtures.v4(9, 9, 9, 9), firstSeen: 1, lastSeen: 2)
        try await store.appendPackets(
            [PersistenceFixtures.packet(timestamp: 1, key: outsideKey, capture: CaptureLocation(fileSequence: 3, recordOffset: 24))],
            flowID: outside
        )

        let session = try await store.startAuditSession(sessionDraft(project: project.id), at: PersistenceFixtures.date(10))
        let key = PersistenceFixtures.key(remote: ModelFixtures.v4(1, 1, 1, 1))
        let inside = try await upsert(store, remote: ModelFixtures.v4(1, 1, 1, 1), firstSeen: 12, lastSeen: 20)
        try await store.appendPackets(
            [
                PersistenceFixtures.packet(timestamp: 12, key: key, capture: CaptureLocation(fileSequence: 4, recordOffset: 24)),
                PersistenceFixtures.packet(timestamp: 13, key: key, capture: CaptureLocation(fileSequence: 4, recordOffset: 96)),
                // La captura rotó en medio de la sesión.
                PersistenceFixtures.packet(timestamp: 14, key: key, capture: CaptureLocation(fileSequence: 5, recordOffset: 24)),
                // Sin captura: su `pcap_file` vale 0 sin significar el fichero 0.
                PersistenceFixtures.packet(timestamp: 15, key: key, capture: nil),
            ],
            flowID: inside
        )

        let sequences = try await store.captureFileSequences(inAuditSession: session.id)
        XCTAssertEqual(sequences, [4, 5])
    }

    func testASessionCountsOnlyItsOwnFlows() async throws {
        let store = try makeStore()
        let project = try await makeProject(store)
        _ = try await upsert(store, remote: ModelFixtures.v4(9, 9, 9, 9), firstSeen: 1, lastSeen: 2)
        let session = try await store.startAuditSession(sessionDraft(project: project.id), at: PersistenceFixtures.date(10))
        _ = try await upsert(store, remote: ModelFixtures.v4(1, 1, 1, 1), firstSeen: 12, lastSeen: 20)
        _ = try await upsert(store, remote: ModelFixtures.v4(2, 2, 2, 2), firstSeen: 13, lastSeen: 21)

        let count = try await store.flowCount(inAuditSession: session.id)
        XCTAssertEqual(count, 2)
        let none = try await store.flowCount(inAuditSession: 99)
        XCTAssertEqual(none, 0)
    }

    /// Lo que tiene que poder contar quien vaya a vaciar el historial: las conexiones que son
    /// evidencia de **cualquier** sesión, abierta o cerrada, y ninguna de las demás.
    func testTheAuditFlowCountCoversEverySessionAndNothingElse() async throws {
        let store = try makeStore()
        let project = try await makeProject(store)
        _ = try await upsert(store, remote: ModelFixtures.v4(9, 9, 9, 9), firstSeen: 1, lastSeen: 2)
        let before = try await store.auditFlowCount()
        XCTAssertEqual(before, 0)

        _ = try await store.startAuditSession(sessionDraft(project: project.id), at: PersistenceFixtures.date(10))
        _ = try await upsert(store, remote: ModelFixtures.v4(1, 1, 1, 1), firstSeen: 12, lastSeen: 20)
        _ = try await upsert(store, remote: ModelFixtures.v4(2, 2, 2, 2), firstSeen: 13, lastSeen: 21)

        let count = try await store.auditFlowCount()
        XCTAssertEqual(count, 2)
    }

    func testASessionWithoutCapturedPacketsHasNoCaptureFiles() async throws {
        let store = try makeStore()
        let project = try await makeProject(store)
        let session = try await store.startAuditSession(sessionDraft(project: project.id), at: PersistenceFixtures.date(10))
        _ = try await upsert(store, remote: ModelFixtures.v4(1, 1, 1, 1), firstSeen: 12, lastSeen: 20)

        let sequences = try await store.captureFileSequences(inAuditSession: session.id)
        XCTAssertTrue(sequences.isEmpty)
    }

    // MARK: - Borrado

    func testDeletingAProjectTakesItsSessionsAndMarkersButLeavesTheHistory() async throws {
        let store = try makeStore()
        let project = try await store.createAuditProject(
            projectDraft(allowlist: [try entry("api.example.com")]), at: PersistenceFixtures.date(0)
        )
        let session = try await store.startAuditSession(sessionDraft(project: project.id), at: PersistenceFixtures.date(10))
        _ = try await store.addMarker(.consentGiven, toSession: session.id, at: PersistenceFixtures.date(15))
        let flowID = try await upsert(store, remote: ModelFixtures.v4(1, 1, 1, 1), firstSeen: 12, lastSeen: 20)

        try await store.deleteAuditProject(id: project.id)

        let projects = try await store.auditProjects()
        XCTAssertTrue(projects.isEmpty)
        let gone = try await store.auditSession(id: session.id)
        XCTAssertNil(gone)
        let markers = try await store.markers(forSession: session.id)
        XCTAssertTrue(markers.isEmpty)
        let open = try await store.openAuditSession()
        XCTAssertNil(open, "la sesión abierta se fue con su proyecto: nada sigue etiquetando")

        // El flujo ocurrió igual: se queda, sin etiqueta.
        let flow = try await store.flow(id: flowID)
        XCTAssertNotNil(flow)
        let tagged = try await store.flows(inAuditSession: session.id, limit: 10)
        XCTAssertTrue(tagged.isEmpty)

        let raw = try DatabaseQueue(path: dbURL.path)
        defer { try? raw.close() }
        let leftovers = try await raw.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM audit_allowlist") ?? -1
        }
        XCTAssertEqual(leftovers, 0)
    }

    /// Vaciar el historial es borrar tráfico, no el trabajo de preparar una auditoría.
    func testClearingTheHistoryLeavesProjectsAndSessionsInPlace() async throws {
        let store = try makeStore()
        let project = try await makeProject(store)
        let session = try await store.startAuditSession(sessionDraft(project: project.id), at: PersistenceFixtures.date(10))
        _ = try await upsert(store, remote: ModelFixtures.v4(1, 1, 1, 1), firstSeen: 12, lastSeen: 20)

        try await store.clearAll()

        let projects = try await store.auditProjects()
        XCTAssertEqual(projects.map(\.id), [project.id])
        let read = try await store.auditSession(id: session.id)
        XCTAssertEqual(read, session)
        let flows = try await store.flows(inAuditSession: session.id, limit: 10)
        XCTAssertTrue(flows.isEmpty)
    }

    func testDeletingASessionTakesItsMarkersAndUntagsItsFlows() async throws {
        let store = try makeStore()
        let project = try await makeProject(store)
        let session = try await store.startAuditSession(sessionDraft(project: project.id), at: PersistenceFixtures.date(10))
        _ = try await store.addMarker(.consentGiven, toSession: session.id, at: PersistenceFixtures.date(15))
        let flowID = try await upsert(store, remote: ModelFixtures.v4(1, 1, 1, 1), firstSeen: 12, lastSeen: 20)

        try await store.deleteAuditSession(id: session.id)

        let gone = try await store.auditSession(id: session.id)
        XCTAssertNil(gone)
        let markers = try await store.markers(forSession: session.id)
        XCTAssertTrue(markers.isEmpty)
        let flow = try await store.flow(id: flowID)
        XCTAssertNotNil(flow, "el flujo ocurrió igual: se queda, sin etiqueta")
        let projects = try await store.auditProjects()
        XCTAssertEqual(projects.map(\.id), [project.id], "el proyecto no se va con una de sus sesiones")

        // Era la abierta: ya no hay ninguna que etiquete, y se puede abrir otra.
        let open = try await store.openAuditSession()
        XCTAssertNil(open)
        let later = try await upsert(store, remote: ModelFixtures.v4(2, 2, 2, 2), firstSeen: 30, lastSeen: 31)
        let next = try await store.startAuditSession(sessionDraft(project: project.id), at: PersistenceFixtures.date(40))
        let tagged = try await store.flows(inAuditSession: next.id, limit: 10)
        XCTAssertFalse(tagged.map(\.id).contains(later))
    }

    func testDeletingASessionThatDoesNotExistIsAnError() async throws {
        let store = try makeStore()

        do {
            try await store.deleteAuditSession(id: 99)
            XCTFail("borrar lo que no existe tiene que decirse")
        } catch let error as AuditStoreError {
            XCTAssertEqual(error, .sessionNotFound(99))
        }
    }

    // MARK: - Editar un proyecto

    func testUpdatingAProjectRewritesWhatItDeclaresAndKeepsItsSessions() async throws {
        let store = try makeStore()
        let project = try await store.createAuditProject(
            projectDraft(allowlist: [try entry("api.example.com", note: "backend"), try entry("*.cdn.example.com")]),
            at: PersistenceFixtures.date(0)
        )
        let session = try await store.startAuditSession(sessionDraft(project: project.id), at: PersistenceFixtures.date(10))

        let updated = try await store.updateAuditProject(
            id: project.id,
            with: AuditProjectDraft(
                name: "  Example Health 2  ",
                bundleIdentifier: nil,
                catalogueVersion: nil,
                // Otro orden, una entrada menos y una nueva: la lista se sustituye entera.
                allowlist: [try entry("*.cdn.example.com", note: "assets"), try entry("crash.example.org")]
            )
        )

        XCTAssertEqual(updated.id, project.id)
        XCTAssertEqual(updated.name, "Example Health 2")
        XCTAssertNil(updated.bundleIdentifier)
        XCTAssertEqual(updated.allowlist.map(\.pattern.text), ["*.cdn.example.com", "crash.example.org"])
        XCTAssertEqual(updated.allowlist.first?.note, "assets")
        XCTAssertEqual(updated.createdAt, project.createdAt, "editar no vuelve a crear")

        let read = try await store.auditProject(id: project.id)
        XCTAssertEqual(read, updated)
        let sessions = try await store.auditSessions(forProject: project.id)
        XCTAssertEqual(sessions.map(\.id), [session.id])
    }

    func testUpdatingAProjectObeysTheSameRulesAsCreatingIt() async throws {
        let store = try makeStore()
        let project = try await store.createAuditProject(
            projectDraft(allowlist: [try entry("api.example.com")]), at: PersistenceFixtures.date(0)
        )

        do {
            _ = try await store.updateAuditProject(id: project.id, with: projectDraft(name: "   "))
            XCTFail("un nombre vacío no se guarda")
        } catch let error as AuditStoreError {
            XCTAssertEqual(error, .emptyProjectName)
        }
        do {
            _ = try await store.updateAuditProject(
                id: project.id,
                with: projectDraft(allowlist: [try entry("a.example.com"), try entry("A.example.com")])
            )
            XCTFail("el mismo patrón dos veces no se guarda")
        } catch let error as AuditStoreError {
            XCTAssertEqual(error, .duplicateAllowlistPattern("a.example.com"))
        }
        do {
            _ = try await store.updateAuditProject(id: 99, with: projectDraft())
            XCTFail("editar lo que no existe tiene que decirse")
        } catch let error as AuditStoreError {
            XCTAssertEqual(error, .projectNotFound(99))
        }

        // Nada de lo rechazado dejó rastro.
        let read = try await store.auditProject(id: project.id)
        XCTAssertEqual(read, project)
    }

    // MARK: - Retención

    /// La evidencia no caduca: con el tope de fábrica de una semana se iría antes de exportarse.
    func testPruningLeavesTheFlowsOfAnAuditSessionAlone() async throws {
        let store = try makeStore()
        let project = try await makeProject(store)
        let outside = try await upsert(store, remote: ModelFixtures.v4(9, 9, 9, 9), firstSeen: 1, lastSeen: 2)
        let session = try await store.startAuditSession(sessionDraft(project: project.id), at: PersistenceFixtures.date(10))
        let inside = try await upsert(store, remote: ModelFixtures.v4(1, 1, 1, 1), firstSeen: 12, lastSeen: 20)
        _ = try await store.endAuditSession(id: session.id, at: PersistenceFixtures.date(30))

        let deleted = try await store.prune(before: PersistenceFixtures.date(1_000))

        XCTAssertEqual(deleted, 1)
        let gone = try await store.flow(id: outside)
        XCTAssertNil(gone)
        let kept = try await store.flow(id: inside)
        XCTAssertNotNil(kept, "cerrar la sesión no la deja caducar: sigue siendo evidencia")

        // Solo borrar la sesión le quita la etiqueta, y con ella la exención.
        try await store.deleteAuditSession(id: session.id)
        let afterwards = try await store.prune(before: PersistenceFixtures.date(1_000))
        XCTAssertEqual(afterwards, 1)
    }

    func testEvidenceFilesAreTheOnesAnySessionPointsAt() async throws {
        let store = try makeStore()
        let project = try await makeProject(store)

        let outsideRemote = ModelFixtures.v4(9, 9, 9, 9)
        let outside = try await upsert(store, remote: outsideRemote, firstSeen: 1, lastSeen: 2)
        try await store.appendPackets(
            [PersistenceFixtures.packet(
                timestamp: 1, key: PersistenceFixtures.key(remote: outsideRemote),
                capture: CaptureLocation(fileSequence: 3, recordOffset: 24)
            )],
            flowID: outside
        )

        var sessions: [AuditSession] = []
        for (index, file) in [UInt32(4), UInt32(6)].enumerated() {
            let start = UInt64(10 + index * 20)
            let session = try await store.startAuditSession(
                sessionDraft(project: project.id), at: PersistenceFixtures.date(start)
            )
            let remote = ModelFixtures.v4(1, 1, 1, UInt8(index + 1))
            let flowID = try await upsert(store, remote: remote, firstSeen: start + 1, lastSeen: start + 2)
            try await store.appendPackets(
                [
                    PersistenceFixtures.packet(
                        timestamp: start + 1, key: PersistenceFixtures.key(remote: remote),
                        capture: CaptureLocation(fileSequence: file, recordOffset: 24)
                    ),
                    // Sin captura: su `pcap_file` vale 0 sin significar el fichero 0.
                    PersistenceFixtures.packet(
                        timestamp: start + 2, key: PersistenceFixtures.key(remote: remote), capture: nil
                    ),
                ],
                flowID: flowID
            )
            _ = try await store.endAuditSession(id: session.id, at: PersistenceFixtures.date(start + 5))
            sessions.append(session)
        }

        let evidence = try await store.auditEvidenceFileSequences()
        XCTAssertEqual(evidence, [4, 6], "las de todas las sesiones, y ninguna de fuera")

        try await store.deleteAuditSession(id: sessions[0].id)
        let remaining = try await store.auditEvidenceFileSequences()
        XCTAssertEqual(remaining, [6])
    }

    // MARK: - Migración

    /// Una BD detenida en `v5` migra sola, conserva sus flujos y los deja sin sesión de auditoría:
    /// nada de lo que se grabó antes de que existieran pertenece a ninguna.
    func testADatabaseStoppedAtV5GainsTheAuditTablesWithoutLosingAnything() async throws {
        let legacy = try DatabaseQueue(path: dbURL.path)
        try Schema.migrator().migrate(legacy, upTo: "v5")
        try await legacy.write { db in
            try db.execute(
                sql: """
                INSERT INTO flows
                    (session, proto, addr_a, port_a, addr_b, port_b,
                     first_seen, last_seen, bytes_out, bytes_in, packet_count, tls_status, sni)
                VALUES (1, 6, ?, 51000, ?, 443, ?, ?, 10, 20, 3, 1, 'example.com')
                """,
                arguments: [
                    Data(PersistenceFixtures.deviceIP.bytes),
                    Data(ModelFixtures.v4(1, 1, 1, 1).bytes),
                    WallClock.nanosecondsSince1970(from: PersistenceFixtures.date(1)),
                    WallClock.nanosecondsSince1970(from: PersistenceFixtures.date(2)),
                ]
            )
        }
        try legacy.close()

        let store = try makeStore()
        let flows = try await store.recentFlows(limit: 10)
        XCTAssertEqual(flows.count, 1)
        XCTAssertEqual(flows.first?.sni, "example.com")
        XCTAssertEqual(flows.first?.totalBytes, 30)

        let project = try await makeProject(store)
        let session = try await store.startAuditSession(sessionDraft(project: project.id), at: PersistenceFixtures.date(10))
        let tagged = try await store.flows(inAuditSession: session.id, limit: 10)
        XCTAssertTrue(tagged.isEmpty)
    }
}
