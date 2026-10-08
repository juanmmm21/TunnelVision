import Foundation
import Shared
import XCTest

/// Tests de lo que se puede decir del pinning en un flujo: que solo se lee de un desenlace de
/// inspección, que sin inspección y CA de confianza no se afirma nada, y que un flujo que no se
/// intentó inspeccionar no cuenta como uno que aceptó.
final class PinningAssessmentTests: XCTestCase {

    private typealias Fixtures = FindingFixtures

    private let inspecting = InspectionConditions(inspectionEnabled: true, caTrusted: true)

    private func assess(_ flow: StoredFlow, conditions: InspectionConditions? = nil) -> PinningAssessment {
        PinningAssessment(of: flow, conditions: conditions ?? inspecting)
    }

    // MARK: - Los dos desenlaces

    func testAnInspectedFlowTrustsAUserInstalledRoot() {
        XCTAssertEqual(
            assess(Fixtures.flow(id: 1, tlsStatus: .inspected, sni: "api.example.com")),
            .absent(host: "api.example.com")
        )
    }

    func testAFlowThatRejectedTheLocalCAIsPinningObserved() {
        XCTAssertEqual(
            assess(Fixtures.flow(id: 1, tlsStatus: .notInspectable, sni: "pay.example.com")),
            .observed(host: "pay.example.com")
        )
    }

    func testTheHostIsCitedNormalised() {
        XCTAssertEqual(
            assess(Fixtures.flow(id: 1, tlsStatus: .inspected, sni: "API.Example.com.")),
            .absent(host: "api.example.com")
        )
        XCTAssertEqual(
            assess(Fixtures.flow(id: 1, tlsStatus: .notInspectable, sni: "API.Example.com.")),
            .observed(host: "api.example.com")
        )
    }

    /// El certificado se emitió para el SNI. Un flujo con desenlace y sin él —solo con un nombre
    /// deducido, o con ninguno— no deja decir de qué host es la observación.
    func testAnOutcomeWithoutAnAnnouncedNameIsNotAssessed() {
        let resolved = ResolvedFlowName(name: "api.example.com", otherNames: [])
        for status in [TLSInspectionStatus.inspected, .notInspectable] {
            XCTAssertEqual(
                assess(Fixtures.flow(id: 1, tlsStatus: status, sni: nil, resolvedName: resolved)),
                .notAssessed(.outcomeWithoutAnnouncedName)
            )
            XCTAssertEqual(
                assess(Fixtures.flow(id: 1, tlsStatus: status, sni: "")),
                .notAssessed(.outcomeWithoutAnnouncedName)
            )
        }
    }

    // MARK: - Las condiciones de la sesión

    /// Con la CA sin confiar toda app la rechaza: ni el rechazo ni —si lo hubiera— un flujo
    /// inspeccionado se informan. El motivo es el primero que falta.
    func testWithoutInspectionOrATrustedCANothingIsRead() {
        let outcomes = [
            Fixtures.flow(id: 1, tlsStatus: .inspected),
            Fixtures.flow(id: 2, tlsStatus: .notInspectable),
            Fixtures.flow(id: 3),
            Fixtures.flow(id: 4, proto: .udp, quic: QUICVersionReading(version: .v1, source: .server)),
        ]
        for flow in outcomes {
            XCTAssertEqual(
                assess(flow, conditions: InspectionConditions(inspectionEnabled: true, caTrusted: false)),
                .notAssessed(.caNotTrusted)
            )
            XCTAssertEqual(
                assess(flow, conditions: InspectionConditions(inspectionEnabled: false, caTrusted: true)),
                .notAssessed(.inspectionOff)
            )
            XCTAssertEqual(
                assess(flow, conditions: InspectionConditions(inspectionEnabled: false, caTrusted: false)),
                .notAssessed(.inspectionOff)
            )
        }
    }

    // MARK: - Sin desenlace

    /// `encrypted` a secas es que no se intentó o no se supo cómo acabó: no es haber aceptado.
    func testTLSWithoutAnOutcomeIsNotAssessed() {
        XCTAssertEqual(assess(Fixtures.flow(id: 1)), .notAssessed(.noInspectionOutcome))
        XCTAssertEqual(
            assess(Fixtures.flow(id: 2, remotePort: 5223, tlsStatus: .plaintext, streamOpening: .tlsHandshake)),
            .notAssessed(.noInspectionOutcome)
        )
        XCTAssertEqual(
            assess(Fixtures.flow(id: 3, remotePort: 8443, tlsStatus: .plaintext, clientTLS: Fixtures.offer(.listed([.tls13])))),
            .notAssessed(.noInspectionOutcome)
        )
        XCTAssertEqual(
            assess(Fixtures.flow(id: 4, remotePort: 8443, tlsStatus: .plaintext, serverTLS: Fixtures.negotiated(.tls13))),
            .notAssessed(.noInspectionOutcome)
        )
    }

    func testQUICIsNeverInspected() {
        for source in [QUICVersionSource.server, .client] {
            XCTAssertEqual(
                assess(Fixtures.flow(id: 1, proto: .udp, quic: QUICVersionReading(version: .v1, source: source))),
                .notAssessed(.quicNotInspected)
            )
        }
        XCTAssertEqual(
            assess(Fixtures.flow(
                id: 2,
                proto: .udp,
                tlsStatus: .plaintext,
                quic: QUICVersionReading(version: QUICVersion(rawValue: 0xFACE_B002), source: .client)
            )),
            .notAssessed(.quicNotInspected)
        )
    }

    // MARK: - No aplica

    func testAFlowWithNoSignOfTLSHasNothingToPin() {
        XCTAssertEqual(assess(Fixtures.flow(id: 1, remotePort: 80, tlsStatus: .plaintext)), .notApplicable)
        XCTAssertEqual(
            assess(Fixtures.flow(id: 2, remotePort: 22, tlsStatus: .plaintext, streamOpening: .unrecognised)),
            .notApplicable
        )
        XCTAssertEqual(
            assess(Fixtures.flow(id: 3, proto: .udp, remotePort: 53, tlsStatus: .plaintext)),
            .notApplicable
        )
        XCTAssertEqual(assess(Fixtures.flow(id: 4, proto: .icmp, tlsStatus: .plaintext)), .notApplicable)
    }

    /// Un 443 que habló HTTP en claro conserva el `encrypted` que le puso el puerto: lo visto
    /// manda, y ahí no hay certificado que fijar.
    func testAnHTTPRequestSeenInTheClearHasNothingToPinWhateverThePortSays() {
        XCTAssertEqual(
            assess(Fixtures.flow(id: 1, tlsStatus: .encrypted, streamOpening: .httpRequest)),
            .notApplicable
        )
    }

    /// No aplica aunque la sesión no inspeccionase: el motivo de la sesión es para los flujos a
    /// los que la comprobación aplicaba.
    func testNotApplicableDoesNotDependOnTheConditions() {
        XCTAssertEqual(
            assess(
                Fixtures.flow(id: 1, remotePort: 80, tlsStatus: .plaintext),
                conditions: InspectionConditions(inspectionEnabled: false, caTrusted: false)
            ),
            .notApplicable
        )
    }

    func testTheGapIdentifiersAreStable() {
        XCTAssertEqual(PinningGap.inspectionOff.rawValue, "inspectionOff")
        XCTAssertEqual(PinningGap.caNotTrusted.rawValue, "caNotTrusted")
        XCTAssertEqual(PinningGap.quicNotInspected.rawValue, "quicNotInspected")
        XCTAssertEqual(PinningGap.noInspectionOutcome.rawValue, "noInspectionOutcome")
        XCTAssertEqual(PinningGap.outcomeWithoutAnnouncedName.rawValue, "outcomeWithoutAnnouncedName")
    }
}
