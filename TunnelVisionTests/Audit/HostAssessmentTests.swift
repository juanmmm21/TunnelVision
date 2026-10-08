import Foundation
import Shared
import XCTest

/// Tests de lo que se puede decir del destino de un flujo frente a una allowlist: que un nombre
/// deducido no autoriza a los que compartían su dirección, que sin allowlist no se juzga nada, y
/// que un flujo sin nombre sale con el motivo que el propio flujo deja ver.
final class HostAssessmentTests: XCTestCase {

    private typealias Fixtures = FindingFixtures

    private let allowlist = ["api.example.com", "*.example.org"]

    private func assess(_ flow: StoredFlow, allowlist: [String]? = nil) throws -> HostAssessment {
        HostAssessment(of: flow, project: try Fixtures.project(allowlist: allowlist ?? self.allowlist))
    }

    private func resolved(_ name: String, others: [String] = []) -> ResolvedFlowName {
        ResolvedFlowName(name: name, otherNames: others)
    }

    // MARK: - Un nombre anunciado

    func testAnAnnouncedNameCoveredByTheAllowlistIsAllowed() throws {
        XCTAssertEqual(try assess(Fixtures.flow(id: 1, sni: "api.example.com")), .allowed)
        XCTAssertEqual(try assess(Fixtures.flow(id: 1, sni: "eu.cdn.example.org")), .allowed)
    }

    func testAnAnnouncedNameOutsideTheAllowlistIsNotInIt() throws {
        XCTAssertEqual(
            try assess(Fixtures.flow(id: 1, sni: "tracker.example.net")),
            .notInAllowlist(host: "tracker.example.net")
        )
    }

    /// `*.example.org` no cubre `example.org`: la allowlist no autoriza lo que no dice.
    func testTheApexOfAWildcardIsNotInTheAllowlist() throws {
        XCTAssertEqual(try assess(Fixtures.flow(id: 1, sni: "example.org")), .notInAllowlist(host: "example.org"))
    }

    /// El host se cita normalizado, para que la misma máquina escrita de dos formas sea un hallazgo.
    func testTheHostIsCitedNormalised() throws {
        XCTAssertEqual(
            try assess(Fixtures.flow(id: 1, sni: "Tracker.Example.NET.")),
            .notInAllowlist(host: "tracker.example.net")
        )
        XCTAssertEqual(try assess(Fixtures.flow(id: 1, sni: "API.Example.com.")), .allowed)
    }

    /// El SNI es lo que la conexión dijo de sí misma: el nombre del DNS ya no es alternativa, ni
    /// para autorizarla ni para ponerla en duda.
    func testTheSNIDecidesAndTheResolvedNameIsNotConsulted() throws {
        let inside = Fixtures.flow(
            id: 1,
            sni: "api.example.com",
            resolvedName: resolved("tracker.example.net", others: ["ads.example.net"])
        )
        XCTAssertEqual(try assess(inside), .allowed)

        let outside = Fixtures.flow(id: 2, sni: "tracker.example.net", resolvedName: resolved("api.example.com"))
        XCTAssertEqual(try assess(outside), .notInAllowlist(host: "tracker.example.net"))
    }

    // MARK: - Un nombre deducido del DNS

    func testAResolvedNameWithNoCompetitionIsJudgedAlone() throws {
        XCTAssertEqual(try assess(Fixtures.flow(id: 1, sni: nil, resolvedName: resolved("api.example.com"))), .allowed)
        XCTAssertEqual(
            try assess(Fixtures.flow(id: 2, sni: nil, resolvedName: resolved("tracker.example.net"))),
            .notInAllowlist(host: "tracker.example.net")
        )
    }

    func testAResolvedNameIsAllowedOnlyIfEveryCandidateIs() throws {
        let flow = Fixtures.flow(
            id: 1,
            sni: nil,
            resolvedName: resolved("api.example.com", others: ["a.example.org", "b.example.org"])
        )
        XCTAssertEqual(try assess(flow), .allowed)
    }

    /// El caso que la regla existe para atrapar: el ganador está dentro y la dirección la
    /// compartía un nombre de fuera. El flujo pudo ser de cualquiera, así que no se da por bueno.
    func testAnAllowedWinnerDoesNotClearAnUnlistedCandidate() throws {
        let flow = Fixtures.flow(
            id: 1,
            sni: nil,
            resolvedName: resolved("api.example.com", others: ["a.example.org", "tracker.example.net"])
        )
        XCTAssertEqual(try assess(flow), .notAssessed(.candidatesDisagree(attributedNameAllowed: true)))
    }

    /// Y al revés: un ganador de fuera con un candidato de dentro tampoco es un hallazgo.
    func testAnUnlistedWinnerWithAnAllowedCandidateIsNotAFinding() throws {
        let flow = Fixtures.flow(
            id: 1,
            sni: nil,
            resolvedName: resolved("tracker.example.net", others: ["api.example.com"])
        )
        XCTAssertEqual(try assess(flow), .notAssessed(.candidatesDisagree(attributedNameAllowed: false)))
    }

    /// Si ninguno de los nombres de la dirección está dentro, fuese el que fuese iba fuera: es
    /// hallazgo, a nombre del que se le atribuyó.
    func testEveryCandidateOutsideIsAFindingUnderTheAttributedName() throws {
        let flow = Fixtures.flow(
            id: 1,
            sni: nil,
            resolvedName: resolved("tracker.example.net", others: ["ads.example.net"])
        )
        XCTAssertEqual(try assess(flow), .notInAllowlist(host: "tracker.example.net"))
    }

    // MARK: - Sin allowlist

    /// Un proyecto sin allowlist no ha dicho qué espera: no se llama inesperado a todo.
    func testWithoutAnAllowlistANamedFlowIsNotAssessed() throws {
        XCTAssertEqual(
            try assess(Fixtures.flow(id: 1, sni: "tracker.example.net"), allowlist: []),
            .notAssessed(.allowlistEmpty)
        )
        XCTAssertEqual(
            try assess(Fixtures.flow(id: 2, sni: nil, resolvedName: resolved("api.example.com")), allowlist: []),
            .notAssessed(.allowlistEmpty)
        )
    }

    /// Que un flujo no tenga nombre no depende de la allowlist: se dice igual.
    func testAnUnnamedFlowIsUnnamedWithOrWithoutAnAllowlist() throws {
        let flow = Fixtures.flow(id: 1, sni: nil)
        XCTAssertEqual(try assess(flow), .unnamed(.noClientHelloRead))
        XCTAssertEqual(try assess(flow, allowlist: []), .unnamed(.noClientHelloRead))
    }

    // MARK: - Sin nombre

    func testAClientHelloWithNoNameSaysItAnnouncedNone() throws {
        let flow = Fixtures.flow(id: 1, sni: nil, clientTLS: Fixtures.offer(.listed([.tls13])))
        XCTAssertEqual(try assess(flow), .unnamed(.serverNameNotAnnounced))
    }

    func testAClientHelloWithNoNameAndECHSaysTheNameMayBeEncrypted() throws {
        let flow = Fixtures.flow(
            id: 1,
            sni: nil,
            clientTLS: Fixtures.offer(.listed([.tls13]), encryptedClientHello: true)
        )
        XCTAssertEqual(try assess(flow), .unnamed(.encryptedClientHello))
    }

    func testWithoutAClientHelloThereWasNothingToReadANameFrom() throws {
        let flows = [
            Fixtures.flow(id: 1, sni: nil),
            Fixtures.flow(id: 2, proto: .udp, sni: nil, quic: QUICVersionReading(version: .v1, source: .server)),
            Fixtures.flow(id: 3, proto: .udp, remotePort: 53, tlsStatus: .plaintext, sni: nil),
            Fixtures.flow(id: 4, proto: .icmp, remotePort: 0, tlsStatus: .plaintext, sni: nil),
        ]
        for flow in flows {
            XCTAssertEqual(try assess(flow), .unnamed(.noClientHelloRead))
        }
    }

    /// Un SNI vacío no nombra a nadie: ni tapa el nombre resuelto ni cuenta como nombre.
    func testAnEmptySNIIsNoName() throws {
        XCTAssertEqual(
            try assess(Fixtures.flow(id: 1, sni: "", clientTLS: Fixtures.offer(.listed([.tls13])))),
            .unnamed(.serverNameNotAnnounced)
        )
        XCTAssertEqual(
            try assess(Fixtures.flow(id: 2, sni: "", resolvedName: resolved("tracker.example.net"))),
            .notInAllowlist(host: "tracker.example.net")
        )
    }

    /// Un ECH con nombre exterior sí tiene nombre: el motivo solo se mira cuando no hay ninguno.
    func testECHWithAnAnnouncedNameIsJudgedByThatName() throws {
        let flow = Fixtures.flow(
            id: 1,
            sni: "tracker.example.net",
            clientTLS: Fixtures.offer(.listed([.tls13]), encryptedClientHello: true)
        )
        XCTAssertEqual(try assess(flow), .notInAllowlist(host: "tracker.example.net"))
    }

    /// El `rawValue` del motivo acabará escrito en el paquete de evidencia: no se mueve solo.
    func testTheReasonIdentifiersAreStable() {
        XCTAssertEqual(UnnamedFlowReason.serverNameNotAnnounced.rawValue, "serverNameNotAnnounced")
        XCTAssertEqual(UnnamedFlowReason.encryptedClientHello.rawValue, "encryptedClientHello")
        XCTAssertEqual(UnnamedFlowReason.noClientHelloRead.rawValue, "noClientHelloRead")
    }
}
