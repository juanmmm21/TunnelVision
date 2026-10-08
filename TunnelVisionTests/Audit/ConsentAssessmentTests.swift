import Foundation
import Shared
import XCTest

/// Tests de lo que se puede decir de un flujo frente al consentimiento marcado: que cuenta el
/// primer paquete, que sin marcador no hay «antes», y que varios marcadores solo dejan afirmar
/// aquello en lo que coinciden.
final class ConsentAssessmentTests: XCTestCase {

    private typealias Fixtures = FindingFixtures

    private let session = Fixtures.session(
        inspection: InspectionConditions(inspectionEnabled: false, caTrusted: false)
    )

    private func flow(startingAt offset: TimeInterval) -> StoredFlow {
        Fixtures.flow(id: 1, firstSeen: Fixtures.start.addingTimeInterval(offset))
    }

    private func assess(
        _ flow: StoredFlow,
        markers: [SessionMarker],
        kind: AuditSessionKind? = nil
    ) -> ConsentAssessment {
        ConsentAssessment(
            of: flow,
            sessionKind: kind ?? session.kind,
            consent: ConsentInterval(markers: markers, of: session)
        )
    }

    // MARK: - El intervalo

    func testASessionWithoutAConsentMarkerHasNoInterval() {
        XCTAssertNil(ConsentInterval(markers: [], of: session))
        XCTAssertNil(ConsentInterval(
            markers: [
                Fixtures.marker(id: 1, .loggedIn, at: 10),
                Fixtures.marker(id: 2, .loggedOut, at: 20),
                Fixtures.marker(id: 3, .custom("consentGiven"), at: 30),
            ],
            of: session
        ))
    }

    func testOneMarkerIsBothEndsOfTheInterval() throws {
        let interval = try XCTUnwrap(ConsentInterval(markers: [Fixtures.marker(id: 1, at: 60)], of: session))
        XCTAssertEqual(interval.first, Fixtures.start.addingTimeInterval(60))
        XCTAssertEqual(interval.last, interval.first)
    }

    /// Los extremos son los instantes, no el orden en que llegaron los marcadores.
    func testSeveralMarkersGiveTheEarliestAndTheLatest() throws {
        let markers = [
            Fixtures.marker(id: 1, at: 90),
            Fixtures.marker(id: 2, at: 30),
            Fixtures.marker(id: 3, .loggedIn, at: 5),
            Fixtures.marker(id: 4, at: 60),
        ]
        let interval = try XCTUnwrap(ConsentInterval(markers: markers, of: session))
        XCTAssertEqual(interval.first, Fixtures.start.addingTimeInterval(30))
        XCTAssertEqual(interval.last, Fixtures.start.addingTimeInterval(90))
    }

    func testTheMarkersOfAnotherSessionAreIgnored() throws {
        XCTAssertNil(ConsentInterval(markers: [Fixtures.marker(id: 1, at: 60, sessionID: 99)], of: session))

        let mixed = [Fixtures.marker(id: 1, at: 10, sessionID: 99), Fixtures.marker(id: 2, at: 60)]
        let interval = try XCTUnwrap(ConsentInterval(markers: mixed, of: session))
        XCTAssertEqual(interval.first, Fixtures.start.addingTimeInterval(60))
    }

    // MARK: - Un marcador

    func testAFlowOpenedBeforeTheMarkerIsBeforeConsent() {
        XCTAssertEqual(assess(flow(startingAt: 59), markers: [Fixtures.marker(id: 1, at: 60)]), .beforeConsent)
    }

    func testAFlowOpenedAtOrAfterTheMarkerIsAfterConsent() {
        let markers = [Fixtures.marker(id: 1, at: 60)]
        XCTAssertEqual(assess(flow(startingAt: 60), markers: markers), .afterConsent)
        XCTAssertEqual(assess(flow(startingAt: 61), markers: markers), .afterConsent)
    }

    /// Cuenta cuándo se abrió, no hasta cuándo duró: una conexión abierta antes y que siguió
    /// después es de antes.
    func testWhatCountsIsTheFirstPacket() {
        let opened = Fixtures.start.addingTimeInterval(10)
        let spanning = StoredFlow(
            id: 1,
            key: Fixtures.flow(id: 1).key,
            firstSeen: opened,
            lastSeen: opened.addingTimeInterval(500),
            bytesOut: 900,
            bytesIn: 4_200,
            packetCount: 12,
            tlsStatus: .encrypted,
            sni: "api.example.com",
            resolvedName: nil,
            serverTLS: nil,
            serverCertificates: nil,
            clientTLS: nil,
            quic: nil,
            streamOpening: nil
        )
        XCTAssertEqual(assess(spanning, markers: [Fixtures.marker(id: 1, at: 60)]), .beforeConsent)
    }

    /// Un flujo que venía de antes de la sesión y llevó tráfico durante ella está etiquetado con
    /// ella, y es de antes del consentimiento como cualquier otro.
    func testAFlowOlderThanTheSessionIsBeforeConsent() {
        XCTAssertEqual(assess(flow(startingAt: -300), markers: [Fixtures.marker(id: 1, at: 60)]), .beforeConsent)
    }

    // MARK: - Sin marcador, o con varios

    func testWithoutAMarkerThereIsNoBefore() {
        XCTAssertEqual(assess(flow(startingAt: 10), markers: []), .notAssessed(.noConsentMarker))
        XCTAssertEqual(
            assess(flow(startingAt: 10), markers: [Fixtures.marker(id: 1, .loggedIn, at: 60)]),
            .notAssessed(.noConsentMarker)
        )
    }

    func testSeveralMarkersOnlyStateWhatAllOfThemSay() {
        let markers = [Fixtures.marker(id: 1, at: 30), Fixtures.marker(id: 2, at: 90)]
        XCTAssertEqual(assess(flow(startingAt: 29), markers: markers), .beforeConsent)
        XCTAssertEqual(assess(flow(startingAt: 30), markers: markers), .notAssessed(.betweenConsentMarkers))
        XCTAssertEqual(assess(flow(startingAt: 89), markers: markers), .notAssessed(.betweenConsentMarkers))
        XCTAssertEqual(assess(flow(startingAt: 90), markers: markers), .afterConsent)
    }

    // MARK: - Baseline

    func testABaselineIsNotApplicableWithOrWithoutMarkers() {
        XCTAssertEqual(assess(flow(startingAt: 10), markers: [], kind: .baseline), .notApplicable)
        XCTAssertEqual(
            assess(flow(startingAt: 10), markers: [Fixtures.marker(id: 1, at: 60)], kind: .baseline),
            .notApplicable
        )
    }

    func testTheGapIdentifiersAreStable() {
        XCTAssertEqual(ConsentGap.noConsentMarker.rawValue, "noConsentMarker")
        XCTAssertEqual(ConsentGap.betweenConsentMarkers.rawValue, "betweenConsentMarkers")
    }
}
