import Foundation
import XCTest
@testable import Shared

/// Tests de lo que hay debajo del intent del marcador, contra un `FlowStore` real: que el gesto de
/// fuera de la app acaba **siempre** en algo que se puede decir, y que nunca dice «puesto» sin que
/// el marcador esté escrito.
final class OpenSessionMarkingTests: XCTestCase {

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

    private func makeStore() throws -> FlowStore {
        try FlowStore(databaseURL: dbURL, anchor: PersistenceFixtures.anchor)
    }

    private func makeMarking(storeAvailable: Bool = true) -> OpenSessionMarking {
        let url = dbURL!
        return OpenSessionMarking(openingStore: {
            guard storeAvailable else { throw StoreUnavailable() }
            return try FlowStore(databaseURL: url, anchor: PersistenceFixtures.anchor)
        })
    }

    /// Abre una sesión como lo hace la app, y la devuelve.
    private func startSession(in store: FlowStore, projectName: String = "Example Health") async throws -> AuditSession {
        let project = try await store.createAuditProject(
            AuditProjectDraft(name: projectName, bundleIdentifier: nil, catalogueVersion: nil, allowlist: []),
            at: PersistenceFixtures.date(0)
        )
        return try await store.startAuditSession(
            AuditSessionDraft(
                projectID: project.id,
                kind: .audit(AppRelease(version: "2.4.0", build: "187")),
                environment: AuditEnvironment(deviceModel: "iPhone18,3", osVersion: "26.5", toolVersion: "1.0.0 (1)"),
                inspection: InspectionConditions(inspectionEnabled: true, caTrusted: true),
                notes: ""
            ),
            at: PersistenceFixtures.date(10)
        )
    }

    // MARK: - Marcar

    func testAMarkerIsWrittenWithTheInstantOfTheGestureAndReportedWithItsProject() async throws {
        let store = try makeStore()
        let session = try await startSession(in: store)

        let report = await makeMarking().place(.consentGiven, at: PersistenceFixtures.date(20))

        XCTAssertEqual(
            report,
            .placed(title: "Consent given", date: PersistenceFixtures.date(20), projectName: "Example Health")
        )
        let markers = try await store.markers(forSession: session.id)
        XCTAssertEqual(markers.map(\.kind), [.consentGiven])
        XCTAssertEqual(markers.map(\.date), [PersistenceFixtures.date(20)])
    }

    func testEveryOptionWritesItsOwnKind() async throws {
        let store = try makeStore()
        let session = try await startSession(in: store)
        let marking = makeMarking()

        for (offset, option) in AuditMarkerOption.allCases.enumerated() {
            let report = await marking.place(option, at: PersistenceFixtures.date(20 + UInt64(offset)))
            guard case .placed = report else { return XCTFail("\(option): \(report)") }
        }

        let markers = try await store.markers(forSession: session.id)
        XCTAssertEqual(markers.map(\.kind), [.consentGiven, .loggedIn, .loggedOut])
    }

    func testWithoutAnOpenSessionItSaysSoAndWritesNothing() async throws {
        let store = try makeStore()

        let empty = await makeMarking().place(.consentGiven, at: PersistenceFixtures.date(20))
        XCTAssertEqual(empty, .noOpenSession)

        let session = try await startSession(in: store)
        _ = try await store.endAuditSession(id: session.id, at: PersistenceFixtures.date(30))
        let ended = await makeMarking().place(.consentGiven, at: PersistenceFixtures.date(40))
        XCTAssertEqual(ended, .noOpenSession)
        let markers = try await store.markers(forSession: session.id)
        XCTAssertTrue(markers.isEmpty)
    }

    func testAHistoryThatCannotBeOpenedIsNotAPlacedMarker() async {
        let report = await makeMarking(storeAvailable: false).place(.consentGiven, at: PersistenceFixtures.date(20))
        XCTAssertEqual(report, .notPlaced)
    }

    func testAMarkerTheStoreRefusesIsNotAPlacedMarker() async throws {
        // Un reloj que retrocedió por detrás del inicio de la sesión: el store lo rechaza, y el
        // gesto tiene que decir que no se puso, no que no hay sesión.
        let store = try makeStore()
        let session = try await startSession(in: store)

        let report = await makeMarking().place(.consentGiven, at: PersistenceFixtures.date(5))

        XCTAssertEqual(report, .notPlaced)
        let markers = try await store.markers(forSession: session.id)
        XCTAssertTrue(markers.isEmpty)
    }

    // MARK: - Lo que el control enseña antes de pulsarlo

    func testTheControlNamesTheProjectThatIsRecording() async throws {
        let store = try makeStore()
        _ = try await startSession(in: store, projectName: "Diabetes Coach")

        let state = await makeMarking().controlState()

        XCTAssertEqual(state, .recording(projectName: "Diabetes Coach"))
    }

    func testTheControlIsIdleWithNoSessionAndAfterItEnds() async throws {
        let store = try makeStore()
        let before = await makeMarking().controlState()
        XCTAssertEqual(before, .idle)

        let session = try await startSession(in: store)
        _ = try await store.endAuditSession(id: session.id, at: PersistenceFixtures.date(30))
        let after = await makeMarking().controlState()
        XCTAssertEqual(after, .idle)
    }

    func testAHistoryThatCannotBeOpenedIsNotAnIdleControl() async {
        // «Sin sesión» y «no lo sé» no son lo mismo: el segundo no puede prometer que no se graba.
        let state = await makeMarking(storeAvailable: false).controlState()
        XCTAssertEqual(state, .unavailable)
    }
}
