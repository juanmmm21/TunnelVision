import Foundation
import Shared
import XCTest

/// Tests del inventario de dominios de una sesión: que un flujo solo cuenta como visto cuando su
/// nombre no tiene alternativa, que un flujo sin nombre no se pierde, y que las versiones de TLS
/// de un dominio salen solo de los flujos que fueron a él.
final class SessionDomainsTests: XCTestCase {

    private typealias Fixtures = FindingFixtures

    private func resolved(_ name: String, others: [String] = []) -> ResolvedFlowName {
        ResolvedFlowName(name: name, otherNames: others)
    }

    private func serverHello(_ version: TLSProtocolVersion) -> TLSVersionObservation {
        TLSVersionObservation(version: version, basis: .serverHello(fromHelloRetryRequest: false))
    }

    private func domain(_ host: String, in inventory: SessionDomains) throws -> DomainObservation {
        try XCTUnwrap(inventory.domains.first { $0.host == host })
    }

    func testNoFlowsIsAnEmptyInventory() {
        XCTAssertEqual(SessionDomains(flows: []), SessionDomains(domains: [], unnamedFlowIDs: []))
    }

    // MARK: - Qué es el dominio de un flujo

    func testFlowsThatAnnounceTheSameNameAreOneDomain() throws {
        let inventory = SessionDomains(flows: [
            Fixtures.flow(id: 1, sni: "api.example.com"),
            Fixtures.flow(id: 2, sni: "cdn.example.org"),
            Fixtures.flow(id: 3, sni: "api.example.com")
        ])
        XCTAssertEqual(inventory.domains.map(\.host), ["api.example.com", "cdn.example.org"])
        let api = try domain("api.example.com", in: inventory)
        XCTAssertEqual(api.flowIDs, [1, 3])
        XCTAssertEqual(api.candidateFlowIDs, [])
        XCTAssertTrue(api.isSeen)
    }

    /// El mismo texto que cita un hallazgo, para que el diff y el clasificador casen.
    func testTheHostIsNormalised() {
        let inventory = SessionDomains(flows: [
            Fixtures.flow(id: 1, sni: "API.Example.com."),
            Fixtures.flow(id: 2, sni: "api.example.com")
        ])
        XCTAssertEqual(inventory.domains.map(\.host), ["api.example.com"])
        XCTAssertEqual(inventory.domains.first?.flowIDs, [1, 2])
    }

    /// Un nombre deducido de una dirección que solo tenía ese es el dominio del flujo, y es el
    /// mismo dominio que el de un flujo que lo anunció.
    func testAResolvedNameWithNoCompetitionCountsAsSeen() throws {
        let inventory = SessionDomains(flows: [
            Fixtures.flow(id: 1, sni: nil, resolvedName: resolved("api.example.com")),
            Fixtures.flow(id: 2, sni: "api.example.com")
        ])
        XCTAssertEqual(try domain("api.example.com", in: inventory).flowIDs, [1, 2])
    }

    /// El SNI es lo que la conexión dijo de sí misma: los candidatos del DNS no entran.
    func testTheSNIDecidesAndTheResolvedNamesAreNotListed() {
        let inventory = SessionDomains(flows: [
            Fixtures.flow(
                id: 1,
                sni: "api.example.com",
                resolvedName: resolved("tracker.example.net", others: ["ads.example.net"])
            )
        ])
        XCTAssertEqual(inventory.domains.map(\.host), ["api.example.com"])
    }

    /// La regla de `HostAssessment`: el flujo pudo ir a cualquiera de los nombres de la
    /// dirección, así que es candidato de todos —también del atribuido— y visto de ninguno.
    func testAResolvedNameWithCompetitionMakesEveryNameACandidate() throws {
        let inventory = SessionDomains(flows: [
            Fixtures.flow(
                id: 1,
                sni: nil,
                resolvedName: resolved("api.example.com", others: ["tracker.example.net", "ads.example.net"])
            )
        ])
        XCTAssertEqual(
            inventory.domains.map(\.host),
            ["api.example.com", "tracker.example.net", "ads.example.net"]
        )
        for observation in inventory.domains {
            XCTAssertEqual(observation.flowIDs, [])
            XCTAssertEqual(observation.candidateFlowIDs, [1])
            XCTAssertFalse(observation.isSeen)
        }
    }

    /// Un candidato que solo se distingue por cómo está escrito no es una alternativa.
    func testACandidateThatIsTheSameNameIsNoCompetition() throws {
        let inventory = SessionDomains(flows: [
            Fixtures.flow(id: 1, sni: nil, resolvedName: resolved("api.example.com", others: ["API.example.com."]))
        ])
        XCTAssertEqual(inventory.domains.map(\.host), ["api.example.com"])
        XCTAssertEqual(inventory.domains.first?.flowIDs, [1])
    }

    func testADomainCanBeSeenByOneFlowAndCandidateOfAnother() throws {
        let inventory = SessionDomains(flows: [
            Fixtures.flow(id: 1, sni: nil, resolvedName: resolved("cdn.example.org", others: ["api.example.com"])),
            Fixtures.flow(id: 2, sni: "api.example.com")
        ])
        let api = try domain("api.example.com", in: inventory)
        XCTAssertEqual(api.flowIDs, [2])
        XCTAssertEqual(api.candidateFlowIDs, [1])
        XCTAssertTrue(api.isSeen)
        XCTAssertFalse(try domain("cdn.example.org", in: inventory).isSeen)
    }

    // MARK: - Flujos sin nombre

    func testUnnamedFlowsAreKeptApart() {
        let inventory = SessionDomains(flows: [
            Fixtures.flow(id: 1, sni: nil),
            Fixtures.flow(id: 2, sni: "api.example.com"),
            Fixtures.flow(id: 3, sni: "")
        ])
        XCTAssertEqual(inventory.unnamedFlowIDs, [1, 3])
        XCTAssertEqual(inventory.domains.map(\.host), ["api.example.com"])
    }

    // MARK: - Orden

    func testDomainsKeepTheOrderOfFirstAppearance() {
        let hosts = ["zeta.example.com", "alpha.example.com", "mid.example.com"]
        let flows = (hosts + hosts.reversed()).enumerated().map { index, host in
            Fixtures.flow(id: Int64(index + 1), sni: host)
        }
        XCTAssertEqual(SessionDomains(flows: flows).domains.map(\.host), hosts)
    }

    // MARK: - TLS

    func testFlowsWithTheSameReadingAreOneSighting() throws {
        let inventory = SessionDomains(flows: [
            Fixtures.flow(id: 1, serverTLS: Fixtures.negotiated(.tls13)),
            Fixtures.flow(id: 2, serverTLS: Fixtures.negotiated(.tls12)),
            Fixtures.flow(id: 3, serverTLS: Fixtures.negotiated(.tls13))
        ])
        XCTAssertEqual(try domain("api.example.com", in: inventory).tlsSightings, [
            TLSVersionSighting(observation: serverHello(.tls13), flowIDs: [1, 3]),
            TLSVersionSighting(observation: serverHello(.tls12), flowIDs: [2])
        ])
    }

    /// La misma versión leída de la conexión del túnel es otra cosa vista, no la misma.
    func testTheSameVersionFromAnotherSourceIsAnotherSighting() throws {
        let inventory = SessionDomains(flows: [
            Fixtures.flow(id: 1, serverTLS: Fixtures.negotiated(.tls13)),
            Fixtures.flow(id: 2, serverTLS: Fixtures.negotiated(.tls13, source: .upstreamConnection))
        ])
        XCTAssertEqual(try domain("api.example.com", in: inventory).tlsSightings, [
            TLSVersionSighting(observation: serverHello(.tls13), flowIDs: [1]),
            TLSVersionSighting(
                observation: TLSVersionObservation(version: .tls13, basis: .upstreamConnection),
                flowIDs: [2]
            )
        ])
    }

    func testFlowsWithNoVersionToReadAreListed() throws {
        let inventory = SessionDomains(flows: [
            Fixtures.flow(id: 1),
            Fixtures.flow(id: 2, serverTLS: Fixtures.negotiated(.tls13)),
            Fixtures.flow(id: 3, remotePort: 80, tlsStatus: .plaintext, streamOpening: .httpRequest)
        ])
        let api = try domain("api.example.com", in: inventory)
        XCTAssertEqual(api.flowIDsWithoutTLSReading, [1, 3])
        XCTAssertEqual(api.tlsSightings.map(\.flowIDs), [[2]])
    }

    /// La versión es de la conexión, y de una conexión candidata no se sabe a qué dominio iba.
    func testACandidateFlowLendsItsVersionToNoDomain() {
        let inventory = SessionDomains(flows: [
            Fixtures.flow(
                id: 1,
                sni: nil,
                resolvedName: resolved("api.example.com", others: ["cdn.example.org"]),
                serverTLS: Fixtures.negotiated(.tls10)
            )
        ])
        for observation in inventory.domains {
            XCTAssertEqual(observation.tlsSightings, [])
            XCTAssertEqual(observation.flowIDsWithoutTLSReading, [])
        }
    }
}
