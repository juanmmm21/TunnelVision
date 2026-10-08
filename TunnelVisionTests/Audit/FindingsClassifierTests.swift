import Foundation
import Shared
import XCTest

/// Tests del clasificador: que agrupa los flujos que prueban lo mismo, que conserva el orden en
/// que ocurrieron, y que lo que no se pudo mirar sale con su motivo en vez de contarse como bueno.
final class FindingsClassifierTests: XCTestCase {

    private typealias Fixtures = FindingFixtures

    private func policy(_ minimum: TLSProtocolVersion = .tls12) throws -> FindingsPolicy {
        try XCTUnwrap(FindingsPolicy(minimumTLSVersion: minimum))
    }

    private func classify(
        _ flows: [StoredFlow],
        allowlist: [String] = [],
        minimum: TLSProtocolVersion = .tls12
    ) throws -> SessionFindings {
        FindingsClassifier.classify(
            flows: flows,
            project: try Fixtures.project(allowlist: allowlist),
            policy: try policy(minimum)
        )
    }

    private func serverHello(_ version: TLSProtocolVersion) -> TLSVersionObservation {
        TLSVersionObservation(version: version, basis: .serverHello(fromHelloRetryRequest: false))
    }

    func testAPolicyNeedsAPublishedMinimum() {
        XCTAssertNotNil(FindingsPolicy(minimumTLSVersion: .tls12))
        XCTAssertNil(FindingsPolicy(minimumTLSVersion: TLSProtocolVersion(rawValue: 0x7F1C)))
        XCTAssertNil(FindingsPolicy(minimumTLSVersion: TLSProtocolVersion(rawValue: 0)))
    }

    func testNoFlowsIsNoFindingsAndNothingAssessed() throws {
        let result = try classify([])
        XCTAssertEqual(result.findings, [])
        XCTAssertEqual(
            result.tlsVersion,
            CheckCoverage(satisfiedFlowIDs: [], unassessed: [], notApplicableFlowIDs: [])
        )
        XCTAssertEqual(
            result.encryption,
            CheckCoverage(satisfiedFlowIDs: [], unassessed: [], notApplicableFlowIDs: [])
        )
        XCTAssertEqual(
            result.host,
            CheckCoverage(satisfiedFlowIDs: [], unassessed: [], notApplicableFlowIDs: [])
        )
    }

    func testFlowsThatProveTheSameThingAreOneFinding() throws {
        let flows = [
            Fixtures.flow(id: 1, serverTLS: Fixtures.negotiated(.tls10)),
            Fixtures.flow(id: 2, serverTLS: Fixtures.negotiated(.tls13)),
            Fixtures.flow(id: 3, serverTLS: Fixtures.negotiated(.tls10)),
        ]
        let result = try classify(flows)
        XCTAssertEqual(result.findings, [
            Finding(evidence: .weakTLSVersion(serverHello(.tls10)), flowIDs: [1, 3]),
        ])
        XCTAssertEqual(result.findings.first?.kind, .weakTLSVersion)
        XCTAssertEqual(result.tlsVersion.satisfiedFlowIDs, [2])
    }

    /// La misma versión leída de dos sitios no dice lo mismo, así que son dos hallazgos; y salen
    /// en el orden en que cada uno apareció, no en el de un hash.
    func testADifferentVersionOrSourceIsADifferentFinding() throws {
        let flows = [
            Fixtures.flow(id: 1, serverTLS: Fixtures.negotiated(.tls11)),
            Fixtures.flow(id: 2, tlsStatus: .inspected, serverTLS: Fixtures.negotiated(.tls11, source: .upstreamConnection)),
            Fixtures.flow(id: 3, serverTLS: Fixtures.negotiated(.tls10)),
            Fixtures.flow(id: 4, serverTLS: Fixtures.negotiated(.tls11)),
        ]
        let result = try classify(flows)
        XCTAssertEqual(result.findings, [
            Finding(evidence: .weakTLSVersion(serverHello(.tls11)), flowIDs: [1, 4]),
            Finding(
                evidence: .weakTLSVersion(TLSVersionObservation(version: .tls11, basis: .upstreamConnection)),
                flowIDs: [2]
            ),
            Finding(evidence: .weakTLSVersion(serverHello(.tls10)), flowIDs: [3]),
        ])
    }

    func testEveryFlowLandsInExactlyOnePlace() throws {
        let flows = [
            Fixtures.flow(id: 1, serverTLS: Fixtures.negotiated(.tls10)),
            Fixtures.flow(id: 2, serverTLS: Fixtures.negotiated(.tls13)),
            Fixtures.flow(id: 3),
            Fixtures.flow(id: 4, remotePort: 80, tlsStatus: .plaintext),
            Fixtures.flow(id: 5, serverTLS: .refused(alert: 40)),
            Fixtures.flow(id: 6),
            Fixtures.flow(id: 7, proto: .udp, quic: QUICVersionReading(version: .v1, source: .server)),
            Fixtures.flow(id: 8, proto: .udp, remotePort: 53, tlsStatus: .plaintext),
        ]
        let result = try classify(flows)

        XCTAssertEqual(result.findings.map(\.flowIDs), [[1]])
        XCTAssertEqual(result.tlsVersion.satisfiedFlowIDs, [2, 7])
        XCTAssertEqual(result.tlsVersion.unassessed, [
            UnassessedFlows(gap: .serverAnswerNotRead, flowIDs: [3, 6]),
            UnassessedFlows(gap: .serverRefused(alert: 40), flowIDs: [5]),
        ])
        XCTAssertEqual(result.tlsVersion.notApplicableFlowIDs, [4, 8])

        let placed = result.findings.flatMap(\.flowIDs)
            + result.tlsVersion.satisfiedFlowIDs
            + result.tlsVersion.unassessed.flatMap(\.flowIDs)
            + result.tlsVersion.notApplicableFlowIDs
        XCTAssertEqual(placed.sorted(), flows.map(\.id))
    }

    /// Una sesión en la que nada se pudo leer no tiene hallazgos **ni** observaciones a favor: es
    /// lo que separa «no evaluado» de «superado».
    func testNothingReadableIsNotTheSameAsNothingWrong() throws {
        let flows = [Fixtures.flow(id: 1), Fixtures.flow(id: 2, tlsStatus: .notInspectable)]
        let result = try classify(flows)
        XCTAssertEqual(result.findings, [])
        XCTAssertEqual(result.tlsVersion.satisfiedFlowIDs, [])
        XCTAssertEqual(result.tlsVersion.unassessed, [UnassessedFlows(gap: .serverAnswerNotRead, flowIDs: [1, 2])])
    }

    func testTheThresholdComesFromThePolicy() throws {
        let flows = [Fixtures.flow(id: 1, serverTLS: Fixtures.negotiated(.tls12))]
        XCTAssertEqual(try classify(flows, minimum: .tls12).findings, [])
        XCTAssertEqual(
            try classify(flows, minimum: .tls13).findings,
            [Finding(evidence: .weakTLSVersion(serverHello(.tls12)), flowIDs: [1])]
        )
    }

    // MARK: - Tráfico sin cifrar

    func testFlowsSeenInTheClearAreOneFinding() throws {
        let flows = [
            Fixtures.flow(id: 1, remotePort: 80, tlsStatus: .plaintext, streamOpening: .httpRequest),
            Fixtures.flow(id: 2, remotePort: 5223, tlsStatus: .encrypted, streamOpening: .tlsHandshake),
            Fixtures.flow(id: 3, remotePort: 8080, tlsStatus: .plaintext, streamOpening: .httpRequest),
        ]
        let result = try classify(flows)
        XCTAssertEqual(result.findings, [Finding(evidence: .cleartextTraffic(.http), flowIDs: [1, 3])])
        XCTAssertEqual(result.findings.first?.kind, .cleartextTraffic)
        XCTAssertEqual(result.encryption.satisfiedFlowIDs, [2])
    }

    /// Las dos comprobaciones son independientes: cada una coloca **todos** los flujos.
    func testEachCheckPlacesEveryFlow() throws {
        let flows = [
            Fixtures.flow(id: 1, remotePort: 80, tlsStatus: .plaintext, streamOpening: .httpRequest),
            Fixtures.flow(id: 2, serverTLS: Fixtures.negotiated(.tls10), streamOpening: .tlsHandshake),
            Fixtures.flow(id: 3),
            Fixtures.flow(id: 4, remotePort: 22, tlsStatus: .plaintext, streamOpening: .unrecognised),
            Fixtures.flow(id: 5, proto: .udp, quic: QUICVersionReading(version: .v1, source: .server)),
            Fixtures.flow(id: 6, proto: .udp, remotePort: 53, tlsStatus: .plaintext),
            Fixtures.flow(id: 7, proto: .icmp, remotePort: 0, tlsStatus: .plaintext),
        ]
        let result = try classify(flows)

        XCTAssertEqual(result.findings, [
            Finding(evidence: .cleartextTraffic(.http), flowIDs: [1]),
            Finding(evidence: .weakTLSVersion(serverHello(.tls10)), flowIDs: [2]),
        ])
        XCTAssertEqual(result.encryption.satisfiedFlowIDs, [2, 5])
        XCTAssertEqual(result.encryption.unassessed, [
            UnassessedFlows(gap: .openingNotRead, flowIDs: [3]),
            UnassessedFlows(gap: .unrecognisedOpening, flowIDs: [4]),
            UnassessedFlows(gap: .datagramsNotRead, flowIDs: [6]),
        ])
        XCTAssertEqual(result.encryption.notApplicableFlowIDs, [7])

        let cleartext = result.findings.filter { $0.kind == .cleartextTraffic }.flatMap(\.flowIDs)
        let placed = cleartext
            + result.encryption.satisfiedFlowIDs
            + result.encryption.unassessed.flatMap(\.flowIDs)
            + result.encryption.notApplicableFlowIDs
        XCTAssertEqual(placed.sorted(), flows.map(\.id))
    }

    /// Una sesión grabada antes de que el arranque se leyera: nada en claro, y nada a favor.
    func testNoOpeningsReadIsNotTheSameAsNoCleartext() throws {
        let flows = [
            Fixtures.flow(id: 1, remotePort: 80, tlsStatus: .plaintext),
            Fixtures.flow(id: 2, remotePort: 443, tlsStatus: .encrypted),
        ]
        let result = try classify(flows)
        XCTAssertEqual(result.findings, [])
        XCTAssertEqual(result.encryption.satisfiedFlowIDs, [])
        XCTAssertEqual(result.encryption.unassessed, [UnassessedFlows(gap: .openingNotRead, flowIDs: [1, 2])])
    }

    // MARK: - El destino contra la allowlist

    /// Todas las conexiones a un mismo host de fuera son un hallazgo, venga el nombre del SNI o
    /// del DNS y esté escrito como esté; otro host es otro hallazgo.
    func testConnectionsToTheSameUnlistedHostAreOneFinding() throws {
        let flows = [
            Fixtures.flow(id: 1, sni: "tracker.example.net"),
            Fixtures.flow(id: 2, sni: "api.example.com"),
            Fixtures.flow(id: 3, sni: "ads.example.net"),
            Fixtures.flow(
                id: 4,
                proto: .udp,
                sni: nil,
                resolvedName: ResolvedFlowName(name: "tracker.example.net", otherNames: [])
            ),
            Fixtures.flow(id: 5, sni: "Tracker.Example.net."),
        ]
        let result = try classify(flows, allowlist: ["api.example.com"])
        let hostFindings = result.findings.filter { $0.kind == .hostNotInAllowlist }
        XCTAssertEqual(hostFindings, [
            Finding(evidence: .hostNotInAllowlist(host: "tracker.example.net"), flowIDs: [1, 4, 5]),
            Finding(evidence: .hostNotInAllowlist(host: "ads.example.net"), flowIDs: [3]),
        ])
        XCTAssertEqual(result.host.satisfiedFlowIDs, [2])
    }

    func testUnnamedFlowsAreOneFindingPerReason() throws {
        let flows = [
            Fixtures.flow(id: 1, sni: nil),
            Fixtures.flow(id: 2, sni: nil, clientTLS: Fixtures.offer(.listed([.tls13]))),
            Fixtures.flow(id: 3, proto: .udp, sni: nil),
            Fixtures.flow(id: 4, sni: nil, clientTLS: Fixtures.offer(.listed([.tls13]), encryptedClientHello: true)),
        ]
        let result = try classify(flows, allowlist: ["api.example.com"])
        let unnamed = result.findings.filter { $0.kind == .unnamedFlow }
        XCTAssertEqual(unnamed, [
            Finding(evidence: .unnamedFlow(.noClientHelloRead), flowIDs: [1, 3]),
            Finding(evidence: .unnamedFlow(.serverNameNotAnnounced), flowIDs: [2]),
            Finding(evidence: .unnamedFlow(.encryptedClientHello), flowIDs: [4]),
        ])
    }

    /// La comprobación del destino coloca todos los flujos, y ninguno en «no aplica».
    func testTheHostCheckPlacesEveryFlow() throws {
        let shared = ResolvedFlowName(name: "api.example.com", otherNames: ["tracker.example.net"])
        let flows = [
            Fixtures.flow(id: 1, sni: "api.example.com"),
            Fixtures.flow(id: 2, sni: "tracker.example.net"),
            Fixtures.flow(id: 3, sni: nil),
            Fixtures.flow(id: 4, proto: .udp, sni: nil, resolvedName: shared),
            Fixtures.flow(id: 5, proto: .icmp, remotePort: 0, tlsStatus: .plaintext, sni: nil),
            Fixtures.flow(id: 6, proto: .udp, sni: nil, resolvedName: shared),
        ]
        let result = try classify(flows, allowlist: ["api.example.com"])

        XCTAssertEqual(result.host.satisfiedFlowIDs, [1])
        XCTAssertEqual(result.host.unassessed, [
            UnassessedFlows(gap: .candidatesDisagree(attributedNameAllowed: true), flowIDs: [4, 6]),
        ])
        XCTAssertEqual(result.host.notApplicableFlowIDs, [])

        let found = result.findings
            .filter { $0.kind == .hostNotInAllowlist || $0.kind == .unnamedFlow }
            .flatMap(\.flowIDs)
        let placed = found + result.host.satisfiedFlowIDs + result.host.unassessed.flatMap(\.flowIDs)
        XCTAssertEqual(placed.sorted(), flows.map(\.id))
    }

    /// Un proyecto sin allowlist: ninguna conexión con nombre es hallazgo **ni** observación a
    /// favor. Lo que no tiene nombre se sigue diciendo.
    func testWithoutAnAllowlistNothingIsUnexpectedAndNothingIsExpected() throws {
        let flows = [
            Fixtures.flow(id: 1, sni: "api.example.com"),
            Fixtures.flow(id: 2, sni: "tracker.example.net"),
            Fixtures.flow(id: 3, sni: nil),
        ]
        let result = try classify(flows)
        XCTAssertEqual(result.findings, [Finding(evidence: .unnamedFlow(.noClientHelloRead), flowIDs: [3])])
        XCTAssertEqual(result.host.satisfiedFlowIDs, [])
        XCTAssertEqual(result.host.unassessed, [UnassessedFlows(gap: .allowlistEmpty, flowIDs: [1, 2])])
    }

    /// Un flujo que prueba tres cosas las da en un orden fijo: sin cifrar, versión, destino.
    func testAFlowThatProvesSeveralThingsGivesThemInAFixedOrder() throws {
        let flows = [
            Fixtures.flow(
                id: 1,
                sni: "tracker.example.net",
                serverTLS: Fixtures.negotiated(.tls10),
                streamOpening: .httpRequest
            ),
        ]
        let result = try classify(flows, allowlist: ["api.example.com"])
        XCTAssertEqual(result.findings.map(\.kind), [.cleartextTraffic, .weakTLSVersion, .hostNotInAllowlist])
    }

    /// El `rawValue` es lo que escribirá un catálogo de requisitos: no puede moverse solo.
    func testTheKindIdentifiersAreStable() {
        XCTAssertEqual(
            FindingKind.allCases.map(\.rawValue),
            ["weakTLSVersion", "cleartextTraffic", "hostNotInAllowlist", "unnamedFlow"]
        )
    }
}
