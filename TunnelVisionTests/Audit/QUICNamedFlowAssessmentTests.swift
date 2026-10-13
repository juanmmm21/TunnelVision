import XCTest
import Shared

/// Lo que las comprobaciones de una sesión dicen de un flujo **QUIC** ahora que lleva el nombre y
/// la oferta de su ClientHello. Ninguna cambió de código para ello: aquí se sujeta que con los
/// dos campos puestos cada una dice lo que tiene que decir, y que ninguna lee de más.
final class QUICNamedFlowAssessmentTests: XCTestCase {

    private typealias Fixtures = FindingFixtures

    private static let offer = ClientTLSOffer(
        versions: .listed([.tls13]), applicationProtocols: ["h3"],
        omittedApplicationProtocols: 0, hasEncryptedClientHello: false
    )

    private func quicFlow(
        sni: String?,
        offer: ClientTLSOffer? = QUICNamedFlowAssessmentTests.offer,
        resolvedName: ResolvedFlowName? = nil,
        source: QUICVersionSource = .server
    ) -> StoredFlow {
        Fixtures.flow(
            id: 1, proto: .udp, sni: sni, resolvedName: resolvedName, clientTLS: offer,
            quic: QUICVersionReading(version: .v1, source: source)
        )
    }

    // MARK: - El destino frente a la allowlist

    /// Un nombre anunciado en un Initial se juzga como cualquier SNI, sin consultar el del DNS.
    func testAnAnnouncedQUICNameIsJudgedAgainstTheAllowlist() throws {
        let project = try Fixtures.project(allowlist: ["api.example.com"])

        XCTAssertEqual(HostAssessment(of: quicFlow(sni: "api.example.com"), project: project), .allowed)
        XCTAssertEqual(
            HostAssessment(of: quicFlow(sni: "tracker.example.net"), project: project),
            .notInAllowlist(host: "tracker.example.net")
        )
        let shadowed = quicFlow(
            sni: "tracker.example.net", resolvedName: ResolvedFlowName(name: "api.example.com", otherNames: [])
        )
        XCTAssertEqual(HostAssessment(of: shadowed, project: project), .notInAllowlist(host: "tracker.example.net"))
    }

    /// Los tres motivos de un flujo sin nombre significan en QUIC lo mismo que en TCP.
    func testTheReasonsOfAnUnnamedQUICFlowFollowWhatWasRead() throws {
        let project = try Fixtures.project()
        let withECH = ClientTLSOffer(
            versions: .listed([.tls13]), applicationProtocols: ["h3"],
            omittedApplicationProtocols: 0, hasEncryptedClientHello: true
        )

        XCTAssertEqual(HostAssessment(of: quicFlow(sni: nil), project: project), .unnamed(.serverNameNotAnnounced))
        XCTAssertEqual(
            HostAssessment(of: quicFlow(sni: nil, offer: withECH), project: project), .unnamed(.encryptedClientHello)
        )
        // Sin oferta no se leyó el ClientHello: la conexión ya estaba abierta, o no se dejó leer.
        XCTAssertEqual(HostAssessment(of: quicFlow(sni: nil, offer: nil), project: project), .unnamed(.noClientHelloRead))
    }

    // MARK: - Lo que la oferta NO cambia

    /// La versión de TLS de un flujo QUIC sigue saliendo de su versión de QUIC: que ahora haya
    /// oferta no lo convierte en un flujo «con ClientHello y sin respuesta del servidor».
    func testTheTLSVersionOfAQUICFlowStillComesFromItsQUICVersion() {
        XCTAssertEqual(
            TLSVersionAssessment(of: quicFlow(sni: "api.example.com"), minimum: .tls12),
            .acceptable(TLSVersionObservation(version: .tls13, basis: .quic(.v1)))
        )
        XCTAssertEqual(
            TLSVersionAssessment(of: quicFlow(sni: "api.example.com", source: .client), minimum: .tls12),
            .notAssessed(.quicVersionOnlyProposed(.v1))
        )
    }

    func testAQUICFlowIsStillEncryptedByItsVersion() {
        XCTAssertEqual(EncryptionAssessment(of: quicFlow(sni: "api.example.com")), .encrypted(.quic(.v1)))
    }

    /// Tener nombre anunciado no es haber sido inspeccionado: QUIC no se termina (ADR 0006), así
    /// que del pinning de ese host este flujo sigue sin decir nada.
    func testANamedQUICFlowStillSaysNothingAboutPinning() {
        let conditions = InspectionConditions(inspectionEnabled: true, caTrusted: true)
        XCTAssertEqual(
            PinningAssessment(of: quicFlow(sni: "api.example.com"), conditions: conditions),
            .notAssessed(.quicNotInspected)
        )
    }
}
