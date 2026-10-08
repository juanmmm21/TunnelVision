import Foundation
import Shared
import XCTest

/// Tests de lo que se puede decir de la versión de TLS de un flujo: que una versión débil se
/// señala con su origen, y que nada se da por bueno —ni por malo— sin haberlo observado.
final class TLSVersionAssessmentTests: XCTestCase {

    private typealias Fixtures = FindingFixtures

    private func assess(_ flow: StoredFlow, minimum: TLSProtocolVersion = .tls12) -> TLSVersionAssessment {
        TLSVersionAssessment(of: flow, minimum: minimum)
    }

    private func serverHello(_ version: TLSProtocolVersion, retry: Bool = false) -> TLSVersionObservation {
        TLSVersionObservation(version: version, basis: .serverHello(fromHelloRetryRequest: retry))
    }

    private func upstream(_ version: TLSProtocolVersion) -> TLSVersionObservation {
        TLSVersionObservation(version: version, basis: .upstreamConnection)
    }

    // MARK: - Lectura del ServerHello

    func testAVersionBelowTheMinimumIsWeak() {
        for version in [TLSProtocolVersion.ssl30, .tls10, .tls11] {
            XCTAssertEqual(
                assess(Fixtures.flow(id: 1, serverTLS: Fixtures.negotiated(version))),
                .weak(serverHello(version))
            )
        }
    }

    func testTheMinimumItselfAndAboveAreAcceptable() {
        for version in [TLSProtocolVersion.tls12, .tls13] {
            XCTAssertEqual(
                assess(Fixtures.flow(id: 1, serverTLS: Fixtures.negotiated(version))),
                .acceptable(serverHello(version))
            )
        }
    }

    /// El umbral se recibe: con 1.3 de mínimo, 1.2 es débil; con 1.0, 1.0 vale.
    func testTheThresholdIsTheOneGiven() {
        let tls12 = Fixtures.flow(id: 1, serverTLS: Fixtures.negotiated(.tls12))
        XCTAssertEqual(assess(tls12, minimum: .tls13), .weak(serverHello(.tls12)))
        let tls10 = Fixtures.flow(id: 2, serverTLS: Fixtures.negotiated(.tls10))
        XCTAssertEqual(assess(tls10, minimum: .tls10), .acceptable(serverHello(.tls10)))
    }

    func testAHelloRetryRequestReadingSaysSo() {
        let flow = Fixtures.flow(id: 1, serverTLS: Fixtures.negotiated(.tls13, fromHelloRetryRequest: true))
        XCTAssertEqual(assess(flow), .acceptable(serverHello(.tls13, retry: true)))
    }

    /// Una lectura del ServerHello es lo que la conexión negoció: la oferta del cliente no la
    /// matiza, lleve lo que lleve.
    func testAServerHelloReadingDoesNotDependOnTheOffer() {
        let flow = Fixtures.flow(
            id: 1,
            serverTLS: Fixtures.negotiated(.tls13),
            clientTLS: Fixtures.offer(.listed([.tls13, .tls10]), encryptedClientHello: true)
        )
        XCTAssertEqual(assess(flow), .acceptable(serverHello(.tls13)))
    }

    /// Un borrador `0x7F1C` es mayor que `0x0304` por su valor crudo; no por eso es mejor que 1.3.
    func testAnUnpublishedVersionIsNeitherWeakNorAcceptable() {
        for raw in [UInt16(0x7F1C), 0x0305, 0x0200, 0xFFFF] {
            let version = TLSProtocolVersion(rawValue: raw)
            XCTAssertEqual(
                assess(Fixtures.flow(id: 1, serverTLS: Fixtures.negotiated(version))),
                .notAssessed(.unrecognisedVersion(serverHello(version)))
            )
        }
    }

    func testARefusalHasNoVersionToAssess() {
        let flow = Fixtures.flow(id: 1, serverTLS: .refused(alert: 70))
        XCTAssertEqual(assess(flow), .notAssessed(.serverRefused(alert: 70)))
    }

    // MARK: - Lectura de la conexión de subida

    /// Si el servidor no le da más que esto al cliente del túnel, la app tampoco negoció más.
    func testAWeakUpstreamVersionIsWeakAndCitesItsSource() {
        let flow = Fixtures.flow(
            id: 1,
            tlsStatus: .inspected,
            serverTLS: Fixtures.negotiated(.tls11, source: .upstreamConnection),
            clientTLS: Fixtures.offer(.listed([.tls13, .tls12]))
        )
        XCTAssertEqual(assess(flow), .weak(upstream(.tls11)))
    }

    func testAnAcceptableUpstreamVersionNeedsAnOfferThatExcludesWeakerOnes() {
        let flow = Fixtures.flow(
            id: 1,
            tlsStatus: .inspected,
            serverTLS: Fixtures.negotiated(.tls13, source: .upstreamConnection),
            clientTLS: Fixtures.offer(.listed([.tls13, .tls12]))
        )
        XCTAssertEqual(assess(flow), .acceptable(upstream(.tls13)))
    }

    func testAnAcceptableUpstreamVersionWithoutAConclusiveOfferIsNotAssessed() {
        let cases: [(ClientTLSOffer?, ClientOfferGap)] = [
            (nil, .notRead),
            (Fixtures.offer(.listed([.tls13, .tls12]), encryptedClientHello: true), .encryptedClientHello),
            (Fixtures.offer(.upTo(.tls12)), .ceilingOnly(.tls12)),
            (Fixtures.offer(.upTo(.tls10)), .ceilingOnly(.tls10)),
            (Fixtures.offer(.listed([.tls13, .tls12, .tls11])), .listsWeakerVersion),
            (Fixtures.offer(.listed([.tls10])), .listsWeakerVersion),
            (Fixtures.offer(.listed([])), .listNotConclusive),
            (Fixtures.offer(.listed([.tls13, TLSProtocolVersion(rawValue: 0x7F1C)])), .listNotConclusive),
        ]
        for (offer, gap) in cases {
            let flow = Fixtures.flow(
                id: 1,
                tlsStatus: .inspected,
                serverTLS: Fixtures.negotiated(.tls13, source: .upstreamConnection),
                clientTLS: offer
            )
            XCTAssertEqual(
                assess(flow),
                .notAssessed(.appNegotiationNotObserved(upstream: .tls13, offer: gap)),
                "oferta: \(String(describing: offer))"
            )
        }
    }

    /// Una versión débil en la lista pesa más que un valor desconocido a su lado: es lo que se sabe.
    func testAListedWeakerVersionWinsOverAnUnrecognisedOne() {
        let flow = Fixtures.flow(
            id: 1,
            tlsStatus: .inspected,
            serverTLS: Fixtures.negotiated(.tls12, source: .upstreamConnection),
            clientTLS: Fixtures.offer(.listed([TLSProtocolVersion(rawValue: 0x7F1C), .tls11]))
        )
        XCTAssertEqual(
            assess(flow),
            .notAssessed(.appNegotiationNotObserved(upstream: .tls12, offer: .listsWeakerVersion))
        )
    }

    /// El mínimo también mueve lo que cuenta como «por debajo» en la oferta.
    func testTheOfferIsReadAgainstTheGivenMinimum() {
        let flow = Fixtures.flow(
            id: 1,
            tlsStatus: .inspected,
            serverTLS: Fixtures.negotiated(.tls13, source: .upstreamConnection),
            clientTLS: Fixtures.offer(.listed([.tls13, .tls12]))
        )
        XCTAssertEqual(
            assess(flow, minimum: .tls13),
            .notAssessed(.appNegotiationNotObserved(upstream: .tls13, offer: .listsWeakerVersion))
        )
    }

    // MARK: - QUIC

    func testAQUICVersionTheServerSpeaksIsTLS13() {
        for version in [QUICVersion.v1, .v2] {
            let flow = Fixtures.flow(
                id: 1, proto: .udp, quic: QUICVersionReading(version: version, source: .server)
            )
            XCTAssertEqual(
                assess(flow),
                .acceptable(TLSVersionObservation(version: .tls13, basis: .quic(version)))
            )
        }
    }

    func testAQUICVersionOnlyTheClientProposedIsNotAssessed() {
        let flow = Fixtures.flow(id: 1, proto: .udp, quic: QUICVersionReading(version: .v1, source: .client))
        XCTAssertEqual(assess(flow), .notAssessed(.quicVersionOnlyProposed(.v1)))
    }

    func testAnUnrecognisedQUICVersionIsNotVouchedFor() {
        let draft = QUICVersion(rawValue: 0xFF00_001D)
        for source in [QUICVersionSource.client, .server] {
            let flow = Fixtures.flow(
                id: 1, proto: .udp, tlsStatus: .plaintext, quic: QUICVersionReading(version: draft, source: source)
            )
            XCTAssertEqual(assess(flow), .notAssessed(.unrecognisedQUICVersion(draft)))
        }
    }

    // MARK: - Sin lectura

    /// `serverTLS == nil` no es «no era TLS»: con cualquier señal de TLS es un «no se leyó».
    func testAFlowWithSignsOfTLSButNoAnswerIsNotAssessed() {
        let byStatus: [TLSInspectionStatus] = [.encrypted, .inspected, .notInspectable]
        for status in byStatus {
            XCTAssertEqual(assess(Fixtures.flow(id: 1, tlsStatus: status)), .notAssessed(.serverAnswerNotRead))
        }
        let byOffer = Fixtures.flow(
            id: 2, remotePort: 8443, tlsStatus: .plaintext, clientTLS: Fixtures.offer(.listed([.tls13]))
        )
        XCTAssertEqual(assess(byOffer), .notAssessed(.serverAnswerNotRead))
    }

    func testAFlowWithNoSignOfTLSIsNotApplicable() {
        XCTAssertEqual(assess(Fixtures.flow(id: 1, remotePort: 80, tlsStatus: .plaintext)), .notApplicable)
        XCTAssertEqual(assess(Fixtures.flow(id: 2, proto: .udp, tlsStatus: .plaintext)), .notApplicable)
    }

    // MARK: - Versiones publicadas

    func testOnlyTheFivePublishedVersionsArePublished() {
        for version in [TLSProtocolVersion.ssl30, .tls10, .tls11, .tls12, .tls13] {
            XCTAssertTrue(version.isPublished)
        }
        for raw in [UInt16(0x02FF), 0x0305, 0x7F1C, 0x0000, 0xFFFF] {
            XCTAssertFalse(TLSProtocolVersion(rawValue: raw).isPublished)
        }
    }
}
