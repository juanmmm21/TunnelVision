import Foundation
import XCTest
@testable import Shared

/// Lo que la app dice del diff entre dos releases.
///
/// El modelo (`ReleaseDiff`) ya decide qué es nuevo y qué cambió; lo que se afirma aquí es que la
/// pantalla no dice más que él: que solo marca lo que la allowlist no cubre, que un cambio de TLS
/// lleva el nombre de quien lo negoció, y que lo que queda fuera de las listas se dice.
final class ReleaseComparisonPresentationTests: XCTestCase {

    private typealias Fixtures = FindingFixtures

    private func session(
        id: Int64, day: Int, kind: AuditSessionKind? = nil, open: Bool = false
    ) -> AuditSession {
        let startedAt = Fixtures.start.addingTimeInterval(TimeInterval(day) * 86_400)
        return AuditSession(
            id: id,
            projectID: 1,
            kind: kind ?? .audit(AppRelease(version: "2.\(day).0", build: "\(100 + day)")),
            environment: AuditEnvironment(deviceModel: "iPhone18,3", osVersion: "26.0", toolVersion: "1.0 (1)"),
            inspection: InspectionConditions(inspectionEnabled: false, caTrusted: false),
            startedAt: startedAt,
            endedAt: open ? nil : startedAt.addingTimeInterval(3_600),
            notes: ""
        )
    }

    private func display(
        earlier: [StoredFlow], later: [StoredFlow], allowlist: [String] = ["api.example.com"]
    ) throws -> ReleaseComparisonDisplay {
        ReleaseComparisonPresentation.display(
            of: try ReleaseDiff(
                between: session(id: 1, day: 0),
                flows: earlier,
                and: session(id: 2, day: 7),
                flows: later,
                project: try Fixtures.project(allowlist: allowlist)
            )
        )
    }

    private func count(_ label: String, in display: ReleaseComparisonDisplay) -> String? {
        guard case .text(let text) = display.counts.first(where: { $0.label == label })?.value else { return nil }
        return text
    }

    // MARK: - Con qué se puede comparar

    /// Solo otras sesiones de auditoría ya cerradas: una baseline no observa ninguna versión y una
    /// abierta aún puede ganar conexiones. Ofrecerlas sería ofrecer una fila que acaba en error.
    func testOnlyOtherEndedAuditSessionsAreOffered() throws {
        let project = AuditProjectOverview(
            project: try Fixtures.project(),
            sessions: [
                session(id: 1, day: 0, kind: .baseline),
                session(id: 2, day: 1),
                session(id: 3, day: 2),
                session(id: 4, day: 3),
                session(id: 5, day: 4, open: true),
            ]
        )
        let candidates = ReleaseComparisonPresentation.candidates(forSession: 3, in: project)
        // De la más reciente a la más antigua, y sin ella misma.
        XCTAssertEqual(candidates.map(\.id), [4, 2])
        XCTAssertEqual(candidates.first?.title, "Version 2.3.0 (103)")
    }

    func testABaselineAndAnOpenSessionAreOfferedNothing() throws {
        let project = AuditProjectOverview(
            project: try Fixtures.project(),
            sessions: [
                session(id: 1, day: 0, kind: .baseline),
                session(id: 2, day: 1),
                session(id: 3, day: 2, open: true),
            ]
        )
        XCTAssertTrue(ReleaseComparisonPresentation.candidates(forSession: 1, in: project).isEmpty)
        XCTAssertTrue(ReleaseComparisonPresentation.candidates(forSession: 3, in: project).isEmpty)
        XCTAssertTrue(ReleaseComparisonPresentation.candidates(forSession: 99, in: project).isEmpty)
        // Y la única de auditoría cerrada no tiene con quién.
        XCTAssertTrue(ReleaseComparisonPresentation.candidates(forSession: 2, in: project).isEmpty)
    }

    // MARK: - Qué sesión es cuál

    /// La posterior es la que empezó después, se pase en el orden que se pase.
    func testTheLaterSessionIsTheOneThatStartedLater() throws {
        let shown = try display(earlier: [], later: [])
        XCTAssertEqual(shown.earlierTitle, "Version 2.0.0 (100)")
        XCTAssertEqual(shown.laterTitle, "Version 2.7.0 (107)")
        XCTAssertTrue(shown.direction.contains("Version 2.7.0 (107)"))
        XCTAssertTrue(shown.direction.contains("Version 2.0.0 (100)"))
    }

    // MARK: - Las listas

    func testNewGoneAndSharedDomainsAreCountedAndListed() throws {
        let shown = try display(
            earlier: [
                Fixtures.flow(id: 1, sni: "api.example.com"),
                Fixtures.flow(id: 2, sni: "old.example.net"),
            ],
            later: [
                Fixtures.flow(id: 3, sni: "api.example.com"),
                Fixtures.flow(id: 4, sni: "tracker.example.net"),
            ]
        )
        XCTAssertEqual(shown.newDomains.map(\.host), ["tracker.example.net"])
        XCTAssertEqual(shown.goneDomains.map(\.host), ["old.example.net"])
        XCTAssertEqual(count("New domains", in: shown), "1")
        XCTAssertEqual(count("No longer contacted", in: shown), "1")
        XCTAssertEqual(count("In both", in: shown), "1")
    }

    /// Lo que la comparación existe para encontrar es un destino nuevo que nadie autorizó. Uno
    /// nuevo que la allowlist cubre no pide atención, y uno que desapareció tampoco.
    func testOnlyANewDomainOutsideTheAllowlistIsFlagged() throws {
        let shown = try display(
            earlier: [Fixtures.flow(id: 1, sni: "old.example.net")],
            later: [
                Fixtures.flow(id: 2, sni: "api.example.com"),
                Fixtures.flow(id: 3, sni: "tracker.example.net"),
            ]
        )
        let listed = try XCTUnwrap(shown.newDomains.first { $0.host == "api.example.com" })
        let unlisted = try XCTUnwrap(shown.newDomains.first { $0.host == "tracker.example.net" })
        XCTAssertEqual(listed.role, .neutral)
        XCTAssertEqual(listed.detail, "On the allowlist")
        XCTAssertEqual(unlisted.role, .warning)
        XCTAssertEqual(unlisted.detail, "Not on the allowlist")
        XCTAssertEqual(shown.goneDomains.first?.role, .neutral)
    }

    /// Sin allowlist no hay con qué medir: marcar todos los dominios nuevos sería llamar hallazgo
    /// a no haber escrito la lista.
    func testWithAnEmptyAllowlistNothingIsFlagged() throws {
        let shown = try display(
            earlier: [],
            later: [Fixtures.flow(id: 1, sni: "tracker.example.net")],
            allowlist: []
        )
        XCTAssertEqual(shown.newDomains.first?.role, .neutral)
        XCTAssertEqual(shown.newDomains.first?.detail, "The project has no allowlist")
    }

    // MARK: - TLS

    /// Un suelo que baja es lo que se marca, y la frase dice quién negoció: la app.
    func testALoweredTLSVersionIsFlaggedAndNamesTheApp() throws {
        let shown = try display(
            earlier: [Fixtures.flow(id: 1, serverTLS: Fixtures.negotiated(.tls13))],
            later: [Fixtures.flow(id: 2, serverTLS: Fixtures.negotiated(.tls11))]
        )
        let row = try XCTUnwrap(shown.tlsChanges.first)
        XCTAssertEqual(row.host, "api.example.com")
        XCTAssertEqual(row.role, .warning)
        XCTAssertEqual(row.detail, "The app negotiated TLS 1.1; earlier, TLS 1.3.")
    }

    func testARaisedTLSVersionIsListedWithoutAlarm() throws {
        let shown = try display(
            earlier: [Fixtures.flow(id: 1, serverTLS: Fixtures.negotiated(.tls12))],
            later: [Fixtures.flow(id: 2, serverTLS: Fixtures.negotiated(.tls13))]
        )
        XCTAssertEqual(shown.tlsChanges.first?.role, .neutral)
    }

    /// Lo que negoció la conexión del túnel no es lo que negoció la app, y la fila lo dice.
    func testAChangeSeenOnlyOnTheTunnelsConnectionSaysSo() throws {
        let shown = try display(
            earlier: [
                Fixtures.flow(id: 1, tlsStatus: .inspected,
                              serverTLS: Fixtures.negotiated(.tls13, source: .upstreamConnection)),
            ],
            later: [
                Fixtures.flow(id: 2, tlsStatus: .inspected,
                              serverTLS: Fixtures.negotiated(.tls12, source: .upstreamConnection)),
            ]
        )
        let row = try XCTUnwrap(shown.tlsChanges.first)
        XCTAssertTrue(row.detail.contains("TunnelVision's own connection"))
        XCTAssertTrue(row.detail.contains("not what the app negotiated"))
    }

    func testTheSameVersionInBothSessionsIsNotAChange() throws {
        let shown = try display(
            earlier: [Fixtures.flow(id: 1, serverTLS: Fixtures.negotiated(.tls13))],
            later: [Fixtures.flow(id: 2, serverTLS: Fixtures.negotiated(.tls13))]
        )
        XCTAssertTrue(shown.tlsChanges.isEmpty)
    }

    // MARK: - Lo que las listas no dicen

    /// Una conexión sin nombre no está en ninguna lista. Sin la frase, «ningún dominio nuevo» se
    /// leería como «ningún destino nuevo».
    func testUnnamedConnectionsAreCountedBesideTheLists() throws {
        let shown = try display(
            earlier: [Fixtures.flow(id: 1, sni: nil)],
            later: [Fixtures.flow(id: 2, sni: nil), Fixtures.flow(id: 3, sni: nil)]
        )
        XCTAssertTrue(shown.newDomains.isEmpty)
        let caveat = try XCTUnwrap(shown.caveat)
        XCTAssertTrue(caveat.contains("2 in the later session"))
        XCTAssertTrue(caveat.contains("1 in the earlier one"))
    }

    /// Un nombre que solo fue candidato de una dirección compartida no se da por contactado ni
    /// por ausente.
    func testADomainThatWasOnlyACandidateIsSaidToBeInNeitherList() throws {
        let shown = try display(
            earlier: [Fixtures.flow(id: 1, sni: "api.example.com")],
            later: [
                Fixtures.flow(id: 2, sni: "api.example.com"),
                Fixtures.flow(
                    id: 3, sni: nil,
                    resolvedName: ResolvedFlowName(name: "cdn.example.net", otherNames: ["shared.example.net"])
                ),
            ]
        )
        XCTAssertFalse(shown.newDomains.contains { $0.host == "shared.example.net" })
        XCTAssertTrue(try XCTUnwrap(shown.caveat).contains("shared address"))
    }

    func testWithNothingOutsideTheListsThereIsNoCaveat() throws {
        let shown = try display(
            earlier: [Fixtures.flow(id: 1)],
            later: [Fixtures.flow(id: 2)]
        )
        XCTAssertNil(shown.caveat)
    }

    // MARK: - Fallo

    /// Una sesión borrada entre que se ofrece y que se toca no deja un indicador girando.
    func testAComparisonThatCannotBeMadeSaysSo() {
        let refused = ReleaseComparisonPresentation.failed(ReleaseDiff.Refusal.baseline(sessionID: 1))
        let missing = ReleaseComparisonPresentation.failed(ReleaseComparisonError.sessionNotFound(4))
        XCTAssertEqual(refused.message, missing.message)
        XCTAssertTrue(refused.message.contains("can no longer be compared"))
        XCTAssertEqual(refused.role, .warning)
        XCTAssertNotNil(missing.diagnostic)
    }
}
