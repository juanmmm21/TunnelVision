import Foundation
import Shared
import XCTest

/// Tests del diff entre releases: qué dos sesiones se comparan y cuál es la posterior, que un
/// dominio que solo es candidato en un lado no se da por nuevo ni por desaparecido, y que las
/// versiones de TLS solo se comparan con las que contestan al mismo ClientHello.
final class ReleaseDiffTests: XCTestCase {

    private typealias Fixtures = FindingFixtures

    private let allowlist = ["api.example.com", "*.example.org"]

    /// Una sesión cerrada del proyecto 1 que empezó `day` días después del arranque de los fixtures.
    private func session(
        id: Int64,
        day: Int,
        kind: AuditSessionKind? = nil,
        projectID: Int64 = 1,
        open: Bool = false
    ) -> AuditSession {
        let startedAt = Fixtures.start.addingTimeInterval(TimeInterval(day) * 86_400)
        return AuditSession(
            id: id,
            projectID: projectID,
            kind: kind ?? .audit(AppRelease(version: "2.\(day).0", build: "\(100 + day)")),
            environment: AuditEnvironment(deviceModel: "iPhone18,3", osVersion: "26.0", toolVersion: "1.0 (1)"),
            inspection: InspectionConditions(inspectionEnabled: false, caTrusted: false),
            startedAt: startedAt,
            endedAt: open ? nil : startedAt.addingTimeInterval(3_600),
            notes: ""
        )
    }

    private func diff(
        earlier: [StoredFlow],
        later: [StoredFlow],
        allowlist: [String]? = nil
    ) throws -> ReleaseDiff {
        try ReleaseDiff(
            between: session(id: 1, day: 0),
            flows: earlier,
            and: session(id: 2, day: 7),
            flows: later,
            project: try Fixtures.project(allowlist: allowlist ?? self.allowlist)
        )
    }

    private func comparison(of host: String, in diff: ReleaseDiff) throws -> DomainComparison {
        try XCTUnwrap(diff.domains.first { $0.host == host })
    }

    private func resolved(_ name: String, others: [String] = []) -> ResolvedFlowName {
        ResolvedFlowName(name: name, otherNames: others)
    }

    private func quic(id: Int64, sni: String = "api.example.com") -> StoredFlow {
        Fixtures.flow(id: id, proto: .udp, sni: sni, quic: QUICVersionReading(version: .v1, source: .server))
    }

    private func assertRefuses(
        _ expected: ReleaseDiff.Refusal,
        _ first: AuditSession,
        _ second: AuditSession,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let project = try Fixtures.project(allowlist: allowlist)
        XCTAssertThrowsError(
            try ReleaseDiff(between: first, flows: [], and: second, flows: [], project: project),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? ReleaseDiff.Refusal, expected, file: file, line: line)
        }
    }

    // MARK: - Qué dos sesiones se comparan

    func testASessionIsNotComparedWithItself() throws {
        try assertRefuses(.sameSession, session(id: 1, day: 0), session(id: 1, day: 0))
    }

    func testSessionsOfDifferentProjectsAreNotCompared() throws {
        try assertRefuses(.differentProjects, session(id: 1, day: 0), session(id: 2, day: 7, projectID: 9))
    }

    /// La allowlist tiene que ser la del proyecto de las sesiones.
    func testTheProjectHasToBeTheSessionsOwn() throws {
        try assertRefuses(
            .notTheSessionsProject,
            session(id: 1, day: 0, projectID: 9),
            session(id: 2, day: 7, projectID: 9)
        )
    }

    /// Una baseline no tiene release, se dé en el sitio que se dé.
    func testABaselineIsNotPartOfAReleaseDiff() throws {
        try assertRefuses(.baseline(sessionID: 2), session(id: 1, day: 0), session(id: 2, day: 7, kind: .baseline))
        try assertRefuses(.baseline(sessionID: 1), session(id: 1, day: 0, kind: .baseline), session(id: 2, day: 7))
    }

    /// Una sesión que sigue grabando daría por desaparecido lo que aún no ha contactado.
    func testAnOpenSessionIsNotCompared() throws {
        try assertRefuses(.stillOpen(sessionID: 2), session(id: 1, day: 0), session(id: 2, day: 7, open: true))
    }

    func testTheFirstReasonThatFailsIsTheOneGiven() throws {
        try assertRefuses(
            .differentProjects,
            session(id: 1, day: 0, kind: .baseline),
            session(id: 2, day: 7, projectID: 9, open: true)
        )
        try assertRefuses(
            .baseline(sessionID: 1),
            session(id: 1, day: 0, kind: .baseline),
            session(id: 2, day: 7, open: true)
        )
    }

    // MARK: - Cuál es la posterior

    /// Se dan en cualquier orden: la posterior es la que empezó después.
    func testTheLaterSessionIsTheOneThatStartedLater() throws {
        let old = session(id: 5, day: 0)
        let recent = session(id: 3, day: 7)
        let oldFlows = [Fixtures.flow(id: 1, sni: "old.example.com")]
        let recentFlows = [Fixtures.flow(id: 2, sni: "new.example.com")]
        let project = try Fixtures.project(allowlist: allowlist)

        let inOrder = try ReleaseDiff(between: old, flows: oldFlows, and: recent, flows: recentFlows, project: project)
        let swapped = try ReleaseDiff(between: recent, flows: recentFlows, and: old, flows: oldFlows, project: project)

        XCTAssertEqual(inOrder, swapped)
        XCTAssertEqual(inOrder.earlier, old)
        XCTAssertEqual(inOrder.later, recent)
        XCTAssertEqual(inOrder.newDomains.map(\.host), ["new.example.com"])
        XCTAssertEqual(inOrder.goneDomains.map(\.host), ["old.example.com"])
    }

    /// El build es texto libre y no ordena nada: una release «menor» grabada después es la posterior.
    func testTheReleaseDoesNotDecideTheOrder() throws {
        let first = session(id: 1, day: 0, kind: .audit(AppRelease(version: "3.0.0", build: "900")))
        let second = session(id: 2, day: 7, kind: .audit(AppRelease(version: "2.0.0", build: "100")))
        let result = try ReleaseDiff(
            between: first, flows: [], and: second, flows: [], project: try Fixtures.project()
        )
        XCTAssertEqual(result.later, second)
    }

    func testSessionsThatStartedAtTheSameInstantAreOrderedByID() throws {
        let result = try ReleaseDiff(
            between: session(id: 8, day: 0), flows: [],
            and: session(id: 4, day: 0), flows: [],
            project: try Fixtures.project()
        )
        XCTAssertEqual(result.earlier.id, 4)
        XCTAssertEqual(result.later.id, 8)
    }

    func testTwoSessionsOfTheSameBuildAreComparedLikeAnyOther() throws {
        let release = AuditSessionKind.audit(AppRelease(version: "2.4.0", build: "118"))
        let result = try ReleaseDiff(
            between: session(id: 1, day: 0, kind: release),
            flows: [Fixtures.flow(id: 1, sni: "api.example.com")],
            and: session(id: 2, day: 1, kind: release),
            flows: [Fixtures.flow(id: 2, sni: "tracker.example.net")],
            project: try Fixtures.project(allowlist: allowlist)
        )
        XCTAssertEqual(result.newDomains.map(\.host), ["tracker.example.net"])
    }

    // MARK: - Nuevos, desaparecidos y sin cambio

    func testDomainsAreNewGoneOrInBoth() throws {
        let result = try diff(
            earlier: [
                Fixtures.flow(id: 1, sni: "api.example.com"),
                Fixtures.flow(id: 2, sni: "legacy.example.org")
            ],
            later: [
                Fixtures.flow(id: 11, sni: "tracker.example.net"),
                Fixtures.flow(id: 12, sni: "api.example.com")
            ]
        )
        XCTAssertEqual(result.newDomains.map(\.host), ["tracker.example.net"])
        XCTAssertEqual(result.goneDomains.map(\.host), ["legacy.example.org"])
        XCTAssertEqual(result.domainsInBoth.map(\.host), ["api.example.com"])
        XCTAssertEqual(result.undeterminedDomains, [])
    }

    /// Cada dominio lleva lo que cada sesión dijo de él: los flujos que lo prueban, por lado.
    func testEachDomainCarriesBothObservations() throws {
        let result = try diff(
            earlier: [Fixtures.flow(id: 1, sni: "api.example.com"), Fixtures.flow(id: 2, sni: "gone.example.com")],
            later: [Fixtures.flow(id: 11, sni: "api.example.com"), Fixtures.flow(id: 12, sni: "new.example.com")]
        )
        let both = try comparison(of: "api.example.com", in: result)
        XCTAssertEqual(both.earlier?.flowIDs, [1])
        XCTAssertEqual(both.later?.flowIDs, [11])
        let new = try comparison(of: "new.example.com", in: result)
        XCTAssertNil(new.earlier)
        XCTAssertEqual(new.later?.flowIDs, [12])
        let gone = try comparison(of: "gone.example.com", in: result)
        XCTAssertEqual(gone.earlier?.flowIDs, [2])
        XCTAssertNil(gone.later)
    }

    func testTheSameNameWrittenDifferentlyIsNotAChange() throws {
        let result = try diff(
            earlier: [Fixtures.flow(id: 1, sni: "API.Example.com.")],
            later: [Fixtures.flow(id: 11, sni: nil, resolvedName: resolved("api.example.com"))]
        )
        XCTAssertEqual(result.domainsInBoth.map(\.host), ["api.example.com"])
        XCTAssertEqual(result.newDomains, [])
        XCTAssertEqual(result.goneDomains, [])
    }

    func testTwoSessionsWithNoFlowsHaveNothingToSay() throws {
        let result = try diff(earlier: [], later: [])
        XCTAssertEqual(result.domains, [])
        XCTAssertEqual(result.earlierUnnamedFlowIDs, [])
        XCTAssertEqual(result.laterUnnamedFlowIDs, [])
    }

    /// Primero lo de la sesión posterior, como ocurrió; después lo que solo estaba en la anterior.
    func testTheOrderIsTheLaterSessionsThenWhatOnlyTheEarlierHad() throws {
        let result = try diff(
            earlier: [
                Fixtures.flow(id: 1, sni: "zeta.example.com"),
                Fixtures.flow(id: 2, sni: "kept.example.com"),
                Fixtures.flow(id: 3, sni: "alpha.example.com")
            ],
            later: [
                Fixtures.flow(id: 11, sni: "omega.example.com"),
                Fixtures.flow(id: 12, sni: "kept.example.com"),
                Fixtures.flow(id: 13, sni: "beta.example.com")
            ]
        )
        XCTAssertEqual(result.domains.map(\.host), [
            "omega.example.com", "kept.example.com", "beta.example.com",
            "zeta.example.com", "alpha.example.com"
        ])
    }

    // MARK: - La allowlist y el titular

    func testEachDomainSaysHowItStandsAgainstTheAllowlist() throws {
        let result = try diff(
            earlier: [],
            later: [
                Fixtures.flow(id: 11, sni: "api.example.com"),
                Fixtures.flow(id: 12, sni: "eu.cdn.example.org"),
                Fixtures.flow(id: 13, sni: "tracker.example.net")
            ]
        )
        let entries = try Fixtures.project(allowlist: allowlist).allowlist
        XCTAssertEqual(try comparison(of: "api.example.com", in: result).standing, .listed(entries[0]))
        XCTAssertEqual(try comparison(of: "eu.cdn.example.org", in: result).standing, .listed(entries[1]))
        XCTAssertEqual(try comparison(of: "tracker.example.net", in: result).standing, .unlisted)
    }

    /// El titular: nuevo **y** fuera de la allowlist. Ni lo nuevo que se esperaba, ni lo de fuera
    /// que ya estaba, ni lo de fuera que se fue.
    func testTheHeadlineIsWhatIsNewAndUnlisted() throws {
        let result = try diff(
            earlier: [
                Fixtures.flow(id: 1, sni: "ads.example.net"),
                Fixtures.flow(id: 2, sni: "old-tracker.example.net")
            ],
            later: [
                Fixtures.flow(id: 11, sni: "new.example.org"),
                Fixtures.flow(id: 12, sni: "ads.example.net"),
                Fixtures.flow(id: 13, sni: "tracker.example.net")
            ]
        )
        XCTAssertEqual(result.newDomains.map(\.host), ["new.example.org", "tracker.example.net"])
        XCTAssertEqual(result.unexpectedNewDomains.map(\.host), ["tracker.example.net"])
    }

    /// Sin allowlist nadie ha dicho qué se espera: hay dominios nuevos y ningún titular.
    func testWithoutAnAllowlistNothingNewIsUnexpected() throws {
        let result = try diff(earlier: [], later: [Fixtures.flow(id: 11, sni: "tracker.example.net")], allowlist: [])
        XCTAssertEqual(result.newDomains.map(\.standing), [.allowlistEmpty])
        XCTAssertEqual(result.unexpectedNewDomains, [])
    }

    // MARK: - Dominios que solo son candidatos

    /// Un flujo que pudo ir a cualquiera de dos nombres no prueba que ninguno sea nuevo.
    func testACandidateInTheLaterSessionIsNotNew() throws {
        let result = try diff(
            earlier: [],
            later: [
                Fixtures.flow(
                    id: 11, sni: nil, resolvedName: resolved("tracker.example.net", others: ["api.example.com"])
                )
            ]
        )
        XCTAssertEqual(result.newDomains, [])
        XCTAssertEqual(result.unexpectedNewDomains, [])
        XCTAssertEqual(result.undeterminedDomains.map(\.host), ["tracker.example.net", "api.example.com"])
        XCTAssertEqual(
            try comparison(of: "tracker.example.net", in: result).status,
            .undetermined(earlier: .absent, later: .candidateOnly)
        )
    }

    /// Y uno que en la anterior solo pudo contactarse no se da por nuevo al verse en la posterior.
    func testADomainThatWasOnlyACandidateBeforeIsNotNew() throws {
        let result = try diff(
            earlier: [
                Fixtures.flow(
                    id: 1, sni: nil, resolvedName: resolved("api.example.com", others: ["tracker.example.net"])
                )
            ],
            later: [Fixtures.flow(id: 11, sni: "tracker.example.net")]
        )
        XCTAssertEqual(result.newDomains, [])
        XCTAssertEqual(
            try comparison(of: "tracker.example.net", in: result).status,
            .undetermined(earlier: .candidateOnly, later: .seen)
        )
        XCTAssertEqual(
            try comparison(of: "api.example.com", in: result).status,
            .undetermined(earlier: .candidateOnly, later: .absent)
        )
    }

    func testADomainThatIsOnlyACandidateLaterIsNotGoneNorKept() throws {
        let result = try diff(
            earlier: [Fixtures.flow(id: 1, sni: "api.example.com")],
            later: [
                Fixtures.flow(id: 11, sni: nil, resolvedName: resolved("cdn.example.org", others: ["api.example.com"]))
            ]
        )
        XCTAssertEqual(result.goneDomains, [])
        XCTAssertEqual(result.domainsInBoth, [])
        XCTAssertEqual(
            try comparison(of: "api.example.com", in: result).status,
            .undetermined(earlier: .seen, later: .candidateOnly)
        )
    }

    /// Basta un flujo que lo anuncie para que el dominio esté visto, sea candidato de otros o no.
    func testADomainSeenOnceIsSeenWhateverElseItIsACandidateOf() throws {
        let result = try diff(
            earlier: [Fixtures.flow(id: 1, sni: "api.example.com")],
            later: [
                Fixtures.flow(id: 11, sni: nil, resolvedName: resolved("cdn.example.org", others: ["api.example.com"])),
                Fixtures.flow(id: 12, sni: "api.example.com")
            ]
        )
        XCTAssertEqual(result.domainsInBoth.map(\.host), ["api.example.com"])
    }

    func testAComparisonNeedsTheDomainOnOneSide() throws {
        XCTAssertNil(DomainComparison(host: "api.example.com", standing: .unlisted, earlier: nil, later: nil))
    }

    // MARK: - Flujos sin nombre

    /// Van con el diff, por lado: cualquiera pudo ir a un dominio que se da por desaparecido.
    func testUnnamedFlowsTravelWithTheDiffOnEachSide() throws {
        let result = try diff(
            earlier: [Fixtures.flow(id: 1, sni: nil), Fixtures.flow(id: 2, sni: "api.example.com")],
            later: [Fixtures.flow(id: 11, sni: nil), Fixtures.flow(id: 12, sni: nil)]
        )
        XCTAssertEqual(result.earlierUnnamedFlowIDs, [1])
        XCTAssertEqual(result.laterUnnamedFlowIDs, [11, 12])
        XCTAssertEqual(result.goneDomains.map(\.host), ["api.example.com"])
    }

    // MARK: - Cambios de TLS

    private struct NotInBothSessions: Error {}

    private func status(
        earlier: [StoredFlow],
        later: [StoredFlow]
    ) throws -> (app: TLSVersionComparison, tunnel: TLSVersionComparison) {
        let result = try diff(earlier: earlier, later: later)
        guard case .inBoth(let app, let tunnel) = try comparison(of: "api.example.com", in: result).status else {
            throw NotInBothSessions()
        }
        return (app, tunnel)
    }

    func testTheSameVersionsOnBothSidesIsNoChange() throws {
        let result = try diff(
            earlier: [Fixtures.flow(id: 1, serverTLS: Fixtures.negotiated(.tls13))],
            later: [Fixtures.flow(id: 11, serverTLS: Fixtures.negotiated(.tls13))]
        )
        XCTAssertEqual(
            try comparison(of: "api.example.com", in: result).status,
            .inBoth(app: .same([.tls13]), tunnel: .notCompared(.notReadInEitherSession))
        )
        XCTAssertEqual(result.domainsWithTLSChange, [])
    }

    /// El caso del plan: un host que bajó a 1.2.
    func testAHostThatDroppedToAWeakerVersionIsLowered() throws {
        let result = try diff(
            earlier: [Fixtures.flow(id: 1, serverTLS: Fixtures.negotiated(.tls13))],
            later: [Fixtures.flow(id: 11, serverTLS: Fixtures.negotiated(.tls12))]
        )
        XCTAssertEqual(
            try comparison(of: "api.example.com", in: result).status,
            .inBoth(
                app: .different(earlier: [.tls13], later: [.tls12], floor: .lowered),
                tunnel: .notCompared(.notReadInEitherSession)
            )
        )
        XCTAssertEqual(result.domainsWithTLSChange.map(\.host), ["api.example.com"])
    }

    /// Lo que se compara es la más baja: basta una conexión peor para que el suelo baje.
    func testOneWeakerConnectionLowersTheFloor() throws {
        let app = try status(
            earlier: [Fixtures.flow(id: 1, serverTLS: Fixtures.negotiated(.tls13))],
            later: [
                Fixtures.flow(id: 11, serverTLS: Fixtures.negotiated(.tls13)),
                Fixtures.flow(id: 12, serverTLS: Fixtures.negotiated(.tls11))
            ]
        ).app
        XCTAssertEqual(app, .different(earlier: [.tls13], later: [.tls11, .tls13], floor: .lowered))
    }

    func testAFloorThatWentUpIsRaised() throws {
        let app = try status(
            earlier: [
                Fixtures.flow(id: 1, serverTLS: Fixtures.negotiated(.tls13)),
                Fixtures.flow(id: 2, serverTLS: Fixtures.negotiated(.tls10))
            ],
            later: [Fixtures.flow(id: 11, serverTLS: Fixtures.negotiated(.tls12))]
        ).app
        XCTAssertEqual(app, .different(earlier: [.tls10, .tls13], later: [.tls12], floor: .raised))
    }

    /// Las versiones cambian y la más baja no: se dice el cambio y que el suelo aguantó.
    func testDifferentVersionsWithTheSameFloorAreHeld() throws {
        let app = try status(
            earlier: [
                Fixtures.flow(id: 1, serverTLS: Fixtures.negotiated(.tls12)),
                Fixtures.flow(id: 2, serverTLS: Fixtures.negotiated(.tls13))
            ],
            later: [Fixtures.flow(id: 11, serverTLS: Fixtures.negotiated(.tls12))]
        ).app
        XCTAssertEqual(app, .different(earlier: [.tls12, .tls13], later: [.tls12], floor: .held))
    }

    /// Cuántas conexiones llevaban cada versión, y en qué orden, no es un cambio.
    func testTheSameSetOfVersionsIsTheSameWhateverTheOrderOrTheCount() throws {
        let app = try status(
            earlier: [
                Fixtures.flow(id: 1, serverTLS: Fixtures.negotiated(.tls13)),
                Fixtures.flow(id: 2, serverTLS: Fixtures.negotiated(.tls12))
            ],
            later: [
                Fixtures.flow(id: 11, serverTLS: Fixtures.negotiated(.tls12)),
                Fixtures.flow(id: 12, serverTLS: Fixtures.negotiated(.tls13)),
                Fixtures.flow(id: 13, serverTLS: Fixtures.negotiated(.tls12))
            ]
        ).app
        XCTAssertEqual(app, .same([.tls12, .tls13]))
    }

    /// Un borrador no se ordena: se dice que las versiones cambiaron y no hacia dónde.
    func testAnUnpublishedVersionIsNotOrdered() throws {
        let draft = TLSProtocolVersion(rawValue: 0x7F1C)
        let app = try status(
            earlier: [Fixtures.flow(id: 1, serverTLS: Fixtures.negotiated(.tls12))],
            later: [Fixtures.flow(id: 11, serverTLS: Fixtures.negotiated(draft))]
        ).app
        XCTAssertEqual(app, .different(earlier: [.tls12], later: [draft], floor: .notOrdered))
    }

    /// QUIC es una conexión de la app y lleva TLS 1.3: pasar de QUIC a TLS 1.2 sobre TCP es bajar.
    func testQUICCountsAsTheAppsOwnTLS13() throws {
        let app = try status(
            earlier: [quic(id: 1)],
            later: [Fixtures.flow(id: 11, serverTLS: Fixtures.negotiated(.tls12))]
        ).app
        XCTAssertEqual(app, .different(earlier: [.tls13], later: [.tls12], floor: .lowered))

        let unchanged = try status(
            earlier: [quic(id: 1)],
            later: [Fixtures.flow(id: 11, serverTLS: Fixtures.negotiated(.tls13))]
        ).app
        XCTAssertEqual(unchanged, .same([.tls13]))
    }

    /// Lo que el servidor le dio al túnel no se compara con lo que le dio a la app: una sesión
    /// inspeccionada y otra sin inspeccionar no dan un cambio de TLS, dan dos lecturas sin pareja.
    func testAnUpstreamReadingIsNeverComparedWithTheAppsOwn() throws {
        let result = try diff(
            earlier: [Fixtures.flow(id: 1, serverTLS: Fixtures.negotiated(.tls13))],
            later: [Fixtures.flow(id: 11, serverTLS: Fixtures.negotiated(.tls12, source: .upstreamConnection))]
        )
        XCTAssertEqual(
            try comparison(of: "api.example.com", in: result).status,
            .inBoth(
                app: .notCompared(.notReadInLaterSession),
                tunnel: .notCompared(.notReadInEarlierSession)
            )
        )
        XCTAssertEqual(result.domainsWithTLSChange, [])
    }

    func testTheTunnelsReadingsAreComparedWithEachOther() throws {
        let result = try diff(
            earlier: [Fixtures.flow(id: 1, serverTLS: Fixtures.negotiated(.tls13, source: .upstreamConnection))],
            later: [Fixtures.flow(id: 11, serverTLS: Fixtures.negotiated(.tls12, source: .upstreamConnection))]
        )
        XCTAssertEqual(
            try comparison(of: "api.example.com", in: result).status,
            .inBoth(
                app: .notCompared(.notReadInEitherSession),
                tunnel: .different(earlier: [.tls13], later: [.tls12], floor: .lowered)
            )
        )
        XCTAssertEqual(result.domainsWithTLSChange.map(\.host), ["api.example.com"])
    }

    /// Un flujo sin lectura no es una versión: la falta se dice, no se compara.
    func testASideWithNoReadingIsNotCompared() throws {
        let app = try status(
            earlier: [Fixtures.flow(id: 1, serverTLS: Fixtures.negotiated(.tls13))],
            later: [Fixtures.flow(id: 11), Fixtures.flow(id: 12, serverTLS: .refused(alert: 70))]
        ).app
        XCTAssertEqual(app, .notCompared(.notReadInLaterSession))
    }

    func testANewOrGoneDomainHasNoTLSChange() throws {
        let result = try diff(
            earlier: [Fixtures.flow(id: 1, sni: "gone.example.com", serverTLS: Fixtures.negotiated(.tls13))],
            later: [Fixtures.flow(id: 11, sni: "new.example.com", serverTLS: Fixtures.negotiated(.tls10))]
        )
        XCTAssertEqual(result.domainsWithTLSChange, [])
        XCTAssertFalse(try comparison(of: "new.example.com", in: result).hasTLSChange)
    }

    func testTheNegotiatorOfEachSource() {
        XCTAssertEqual(TLSVersionBasis.serverHello(fromHelloRetryRequest: false).negotiator, .app)
        XCTAssertEqual(TLSVersionBasis.serverHello(fromHelloRetryRequest: true).negotiator, .app)
        XCTAssertEqual(TLSVersionBasis.quic(.v1).negotiator, .app)
        XCTAssertEqual(TLSVersionBasis.upstreamConnection.negotiator, .tunnel)
    }
}
