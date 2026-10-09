import Foundation
import Shared
import XCTest

/// Tests de las reglas de veredicto: que un hallazgo contradice, que «sin contradicción» solo
/// se dice cuando hubo dónde mirar, y que todo lo demás es «no evaluado» y nunca «superado».
final class RequirementAssessmentTests: XCTestCase {

    private typealias Fixtures = FindingFixtures

    private static let inspecting = InspectionConditions(inspectionEnabled: true, caTrusted: true)
    private static let notInspecting = InspectionConditions(inspectionEnabled: false, caTrusted: false)

    private func requirement(_ rule: RequirementRule) -> Requirement {
        Requirement(
            id: "T.Net_1",
            aspect: RequirementAspect(number: 9, name: "Network"),
            title: "A requirement.",
            testDepth: .examine,
            rule: rule,
            toolCoverage: rule == .outsideToolScope ? nil : "What is looked at."
        )
    }

    private func classify(
        _ flows: [StoredFlow],
        allowlist: [String] = [],
        session: AuditSession = Fixtures.session(inspection: notInspecting),
        markers: [SessionMarker] = []
    ) throws -> SessionFindings {
        FindingsClassifier.classify(
            flows: flows,
            project: try Fixtures.project(allowlist: allowlist),
            session: session,
            markers: markers,
            policy: try XCTUnwrap(FindingsPolicy(minimumTLSVersion: .tls12))
        )
    }

    func testARequirementOutsideTheToolsScopeIsNeverAssessed() throws {
        let findings = try classify([
            Fixtures.flow(id: 1, remotePort: 80, tlsStatus: .plaintext, streamOpening: .httpRequest),
            Fixtures.flow(id: 2, streamOpening: .tlsHandshake),
        ])
        let assessment = requirement(.outsideToolScope).assess(findings)

        XCTAssertEqual(assessment.verdict, .notAssessed(.outsideToolScope))
        XCTAssertEqual(assessment.contraryFindings, [])
        XCTAssertEqual(assessment.supportingFindings, [])
        XCTAssertNil(assessment.coverage)
    }

    func testAContraryFindingContradictsEvenBesideSatisfiedFlows() throws {
        let findings = try classify([
            Fixtures.flow(id: 1, streamOpening: .tlsHandshake),
            Fixtures.flow(id: 2, remotePort: 80, tlsStatus: .plaintext, streamOpening: .httpRequest),
            Fixtures.flow(id: 3, remotePort: 8080, tlsStatus: .plaintext, streamOpening: .httpRequest),
        ])
        let assessment = requirement(.contraryFindings([.cleartextTraffic])).assess(findings)

        XCTAssertEqual(assessment.verdict, .contradicted)
        XCTAssertEqual(assessment.contraryFindings, [
            Finding(evidence: .cleartextTraffic(.http), flowIDs: [2, 3]),
        ])
        XCTAssertEqual(assessment.coverage?.check, .encryption)
        XCTAssertEqual(assessment.coverage?.satisfiedFlowIDs, [1])
    }

    func testWithoutFindingsItTakesSatisfiedFlowsToSayAnything() throws {
        let rule = RequirementRule.contraryFindings([.cleartextTraffic])

        let seen = try classify([Fixtures.flow(id: 1, streamOpening: .tlsHandshake)])
        XCTAssertEqual(requirement(rule).assess(seen).verdict, .observedWithoutContradiction)

        // Un TCP sin arranque leído: ni hallazgo ni flujo satisfecho.
        let notRead = try classify([Fixtures.flow(id: 1), Fixtures.flow(id: 2)])
        let assessment = requirement(rule).assess(notRead)
        XCTAssertEqual(assessment.verdict, .notAssessed(.nothingObserved))
        XCTAssertEqual(assessment.coverage?.satisfiedFlowIDs, [])
        XCTAssertEqual(assessment.coverage?.unassessedFlowIDs, [1, 2])

        XCTAssertEqual(requirement(rule).assess(try classify([])).verdict, .notAssessed(.nothingObserved))
    }

    func testOnlyTheKindsOfTheRuleCount() throws {
        // Un HTTP en claro no dice nada de un requisito sobre la versión de TLS.
        let findings = try classify([
            Fixtures.flow(id: 1, remotePort: 80, tlsStatus: .plaintext, sni: nil, streamOpening: .httpRequest),
        ])
        let assessment = requirement(.contraryFindings([.weakTLSVersion])).assess(findings)

        XCTAssertEqual(assessment.verdict, .notAssessed(.nothingObserved))
        XCTAssertEqual(assessment.contraryFindings, [])
        XCTAssertEqual(assessment.coverage?.check, .tlsVersion)
        XCTAssertEqual(assessment.coverage?.notApplicableFlowIDs, [1])
    }

    func testAWeakTLSVersionContradictsAndAGoodOneDoesNot() throws {
        let rule = RequirementRule.contraryFindings([.weakTLSVersion])

        let weak = try classify([
            Fixtures.flow(id: 1, serverTLS: Fixtures.negotiated(.tls13)),
            Fixtures.flow(id: 2, serverTLS: Fixtures.negotiated(.tls11)),
        ])
        XCTAssertEqual(requirement(rule).assess(weak).verdict, .contradicted)
        XCTAssertEqual(requirement(rule).assess(weak).contraryFindings.map(\.flowIDs), [[2]])

        let good = try classify([Fixtures.flow(id: 1, serverTLS: Fixtures.negotiated(.tls12))])
        XCTAssertEqual(requirement(rule).assess(good).verdict, .observedWithoutContradiction)
    }

    func testTwoKindsOfOneCheckBothContradict() throws {
        let rule = RequirementRule.contraryFindings([.hostNotInAllowlist, .unnamedFlow])
        let findings = try classify(
            [
                Fixtures.flow(id: 1, sni: "api.example.com"),
                Fixtures.flow(id: 2, sni: nil),
                Fixtures.flow(id: 3, sni: "ads.example.net"),
            ],
            allowlist: ["api.example.com"]
        )
        let assessment = requirement(rule).assess(findings)

        XCTAssertEqual(assessment.verdict, .contradicted)
        XCTAssertEqual(assessment.contraryFindings.map(\.kind), [.unnamedFlow, .hostNotInAllowlist])
        XCTAssertEqual(assessment.coverage?.satisfiedFlowIDs, [1])

        let listed = try classify([Fixtures.flow(id: 1, sni: "api.example.com")], allowlist: ["api.example.com"])
        XCTAssertEqual(requirement(rule).assess(listed).verdict, .observedWithoutContradiction)

        // Sin allowlist no se ha dicho qué se espera: los flujos con nombre no se evalúan.
        let unlisted = try classify([Fixtures.flow(id: 1, sni: "api.example.com")])
        XCTAssertEqual(requirement(rule).assess(unlisted).verdict, .notAssessed(.nothingObserved))
    }

    func testPinningReadsBothKinds() throws {
        let rule = RequirementRule.contraryAndSupportingFindings(
            contrary: [.pinningAbsent],
            supporting: [.pinningObserved]
        )
        let session = Fixtures.session(inspection: Self.inspecting)
        let refused = Fixtures.flow(id: 1, tlsStatus: .notInspectable, sni: "api.example.com")
        let accepted = Fixtures.flow(id: 2, tlsStatus: .inspected, sni: "cdn.example.com")

        let onlyRefused = requirement(rule).assess(try classify([refused], session: session))
        XCTAssertEqual(onlyRefused.verdict, .observedWithoutContradiction)
        XCTAssertEqual(onlyRefused.contraryFindings, [])
        XCTAssertEqual(onlyRefused.supportingFindings, [
            Finding(evidence: .pinningObserved(host: "api.example.com"), flowIDs: [1]),
        ])
        // La comprobación de pinning no tiene flujos satisfechos: el veredicto sale del hallazgo.
        XCTAssertEqual(onlyRefused.coverage?.satisfiedFlowIDs, [])

        let both = requirement(rule).assess(try classify([refused, accepted], session: session))
        XCTAssertEqual(both.verdict, .contradicted)
        XCTAssertEqual(both.contraryFindings, [
            Finding(evidence: .pinningAbsent(host: "cdn.example.com"), flowIDs: [2]),
        ])
        XCTAssertEqual(both.supportingFindings.map(\.flowIDs), [[1]])
    }

    func testPinningWithoutATrustedCAIsNotAssessed() throws {
        let rule = RequirementRule.contraryAndSupportingFindings(
            contrary: [.pinningAbsent],
            supporting: [.pinningObserved]
        )
        let findings = try classify(
            [Fixtures.flow(id: 1, tlsStatus: .notInspectable), Fixtures.flow(id: 2, tlsStatus: .inspected)],
            session: Fixtures.session(inspection: Self.notInspecting)
        )
        let assessment = requirement(rule).assess(findings)

        XCTAssertEqual(assessment.verdict, .notAssessed(.nothingObserved))
        XCTAssertEqual(assessment.coverage?.unassessedFlowIDs, [1, 2])
    }

    func testConsentWithoutAMarkerOrInABaselineIsNotAssessed() throws {
        let rule = RequirementRule.contraryFindings([.activityBeforeConsent])
        let flows = [Fixtures.flow(id: 1), Fixtures.flow(id: 20)]

        XCTAssertEqual(requirement(rule).assess(try classify(flows)).verdict, .notAssessed(.nothingObserved))

        let marked = try classify(flows, markers: [Fixtures.marker(id: 1, at: 10)])
        XCTAssertEqual(requirement(rule).assess(marked).verdict, .contradicted)
        XCTAssertEqual(requirement(rule).assess(marked).contraryFindings.map(\.flowIDs), [[1]])

        let after = try classify([Fixtures.flow(id: 20)], markers: [Fixtures.marker(id: 1, at: 10)])
        XCTAssertEqual(requirement(rule).assess(after).verdict, .observedWithoutContradiction)

        let baseline = try classify(
            flows,
            session: Fixtures.session(kind: .baseline, inspection: Self.notInspecting),
            markers: [Fixtures.marker(id: 1, at: 10)]
        )
        let assessment = requirement(rule).assess(baseline)
        XCTAssertEqual(assessment.verdict, .notAssessed(.nothingObserved))
        XCTAssertEqual(assessment.coverage?.notApplicableFlowIDs, [1, 20])
    }

    func testTheCoverageSummaryIsTheChecksOwn() throws {
        let findings = try classify(
            [
                Fixtures.flow(id: 1, streamOpening: .tlsHandshake),
                Fixtures.flow(id: 2, streamOpening: .unrecognised),
                Fixtures.flow(id: 3),
                Fixtures.flow(id: 4, proto: .icmp),
            ]
        )
        let summary = findings.coverage(of: .encryption)

        XCTAssertEqual(summary.check, .encryption)
        XCTAssertEqual(summary.satisfiedFlowIDs, findings.encryption.satisfiedFlowIDs)
        XCTAssertEqual(summary.unassessedFlowIDs, [2, 3])
        XCTAssertEqual(summary.notApplicableFlowIDs, [4])
        for check in FindingsCheck.allCases {
            XCTAssertEqual(findings.coverage(of: check).check, check)
        }
    }
}
