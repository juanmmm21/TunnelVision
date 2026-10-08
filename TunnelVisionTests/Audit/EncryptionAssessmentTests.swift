import Foundation
import Shared
import XCTest

/// Tests de lo que se puede decir de si un flujo iba cifrado: que «en claro» solo sale de haberlo
/// **visto**, que el puerto y el estado del flujo no bastan para nada, y que lo que no se miró
/// lleva su motivo.
final class EncryptionAssessmentTests: XCTestCase {

    private typealias Fixtures = FindingFixtures

    private func assess(_ flow: StoredFlow) -> EncryptionAssessment {
        EncryptionAssessment(of: flow)
    }

    // MARK: - En claro

    func testAnHTTPRequestIsCleartextOnAnyPort() {
        for port in [UInt16(80), 8080, 443] {
            let flow = Fixtures.flow(id: 1, remotePort: port, tlsStatus: .plaintext, streamOpening: .httpRequest)
            XCTAssertEqual(assess(flow), .cleartext(.http))
        }
    }

    /// El estado del 443 lo pone el puerto: no tapa lo que se vio.
    func testAnHTTPRequestIsCleartextWhateverTheStatusSays() {
        let flow = Fixtures.flow(id: 1, remotePort: 443, tlsStatus: .encrypted, streamOpening: .httpRequest)
        XCTAssertEqual(assess(flow), .cleartext(.http))
    }

    // MARK: - El puerto no dice nada

    /// El caso que motivó todo esto: sin lectura, un TCP al 80 no es «en claro»…
    func testPlaintextStatusAloneIsNotCleartext() {
        for port in [UInt16(80), 5223, 993, 8443] {
            let flow = Fixtures.flow(id: 1, remotePort: port, tlsStatus: .plaintext)
            XCTAssertEqual(assess(flow), .notAssessed(.openingNotRead))
        }
    }

    /// …ni un TCP al 443 es «cifrado».
    func testEncryptedStatusAloneIsNotEncrypted() {
        let flow = Fixtures.flow(id: 1, remotePort: 443, tlsStatus: .encrypted)
        XCTAssertEqual(assess(flow), .notAssessed(.openingNotRead))
    }

    // MARK: - Cifrado

    func testATLSHandshakeIsEncryptedOnAnyPort() {
        for port in [UInt16(443), 5223, 993] {
            let flow = Fixtures.flow(id: 1, remotePort: port, streamOpening: .tlsHandshake)
            XCTAssertEqual(assess(flow), .encrypted(.tls))
        }
    }

    /// Flujos grabados antes de que el arranque se leyera: cualquier lectura que solo existe si
    /// hubo TLS vale lo mismo.
    func testAnyReadingThatNeedsTLSCountsWithoutAnOpening() {
        let flows = [
            Fixtures.flow(id: 1, clientTLS: Fixtures.offer(.listed([.tls13]))),
            Fixtures.flow(id: 2, serverTLS: Fixtures.negotiated(.tls12)),
            Fixtures.flow(id: 3, serverTLS: .refused(alert: 40)),
            Fixtures.flow(id: 4, tlsStatus: .inspected),
            Fixtures.flow(id: 5, tlsStatus: .notInspectable),
        ]
        for flow in flows {
            XCTAssertEqual(assess(flow), .encrypted(.tls), "flujo \(flow.id)")
        }
    }

    func testAKnownQUICVersionIsEncryptedFromEitherEnd() {
        for source in [QUICVersionSource.client, .server] {
            let flow = Fixtures.flow(id: 1, proto: .udp, quic: QUICVersionReading(version: .v2, source: source))
            XCTAssertEqual(assess(flow), .encrypted(.quic(.v2)))
        }
    }

    // MARK: - Sin evaluar

    func testAnUnrecognisedOpeningIsNeitherCleartextNorEncrypted() {
        for (port, status) in [(UInt16(22), TLSInspectionStatus.plaintext), (443, .encrypted)] {
            let flow = Fixtures.flow(id: 1, remotePort: port, tlsStatus: status, streamOpening: .unrecognised)
            XCTAssertEqual(assess(flow), .notAssessed(.unrecognisedOpening))
        }
    }

    func testAnUnrecognisedQUICVersionIsNotVouchedFor() {
        let draft = QUICVersion(rawValue: 0xFF00_001D)
        let flow = Fixtures.flow(
            id: 1, proto: .udp, tlsStatus: .plaintext, quic: QUICVersionReading(version: draft, source: .server)
        )
        XCTAssertEqual(assess(flow), .notAssessed(.unrecognisedQUICVersion(draft)))
    }

    /// UDP contra el 443 sin cabecera larga es «no clasificado», y el DNS del 53 cae aquí también.
    func testUDPWithoutAQUICReadingIsNotRead() {
        for port in [UInt16(443), 53, 123] {
            let flow = Fixtures.flow(id: 1, proto: .udp, remotePort: port, tlsStatus: .plaintext)
            XCTAssertEqual(assess(flow), .notAssessed(.datagramsNotRead))
        }
    }

    func testOtherProtocolsAreNotApplicable() {
        for proto in [IPProtocolNumber.icmp, .icmpv6, .other] {
            let flow = Fixtures.flow(id: 1, proto: proto, remotePort: 0, tlsStatus: .plaintext)
            XCTAssertEqual(assess(flow), .notApplicable)
        }
    }
}
