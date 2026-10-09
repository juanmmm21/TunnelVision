import Foundation
import Shared
import XCTest

/// Tests del catálogo que viene con la app: que se carga del bundle, que es el que dice ser y
/// que una sesión evaluada con él da un veredicto por requisito.
final class RequirementCatalogueLibraryTests: XCTestCase {

    private typealias Fixtures = FindingFixtures

    private func project(catalogue: String?) -> AuditProject {
        AuditProject(
            id: 1,
            name: "Example",
            bundleIdentifier: nil,
            catalogueVersion: catalogue,
            allowlist: [],
            createdAt: Fixtures.start
        )
    }

    func testTheBundledCatalogueLoads() throws {
        let catalogue = try RequirementCatalogueLibrary.catalogue(
            identifier: RequirementCatalogueLibrary.defaultIdentifier
        )

        XCTAssertEqual(catalogue.identifier, "tr-03161-1_3.0")
        XCTAssertEqual(catalogue.source.document, "BSI TR-03161-1")
        XCTAssertEqual(catalogue.source.version, "3.0")
        XCTAssertEqual(catalogue.source.date, "2024-03-25")
        XCTAssertEqual(catalogue.tlsSource.document, "BSI TR-02102-2")
        XCTAssertEqual(catalogue.tlsSource.version, "2026-01")
        XCTAssertEqual(catalogue.policy.minimumTLSVersion, .tls12)
    }

    /// Que el identificador y el título de cada requisito son los del documento lo comprueba
    /// `Tools/Catalogue/verify.py` contra el PDF, que no está en el repositorio. Aquí se sujeta
    /// qué dice la herramienta de cada uno, para que un cambio en el JSON no pase sin verse.
    func testWhatTheBundledCatalogueSaysOfEachRequirement() throws {
        let catalogue = try RequirementCatalogueLibrary.catalogue(identifier: "tr-03161-1_3.0")
        let rules = catalogue.requirements.map { ($0.id, $0.rule) }
        let expected: [(String, RequirementRule)] = [
            ("O.Purp_3", .contraryFindings([.activityBeforeConsent])),
            ("O.Purp_8", .contraryFindings([.hostNotInAllowlist, .unnamedFlow])),
            ("O.Ntwk_1", .contraryFindings([.cleartextTraffic])),
            ("O.Ntwk_2", .contraryFindings([.weakTLSVersion])),
            ("O.Ntwk_3", .outsideToolScope),
            ("O.Ntwk_4", .contraryAndSupportingFindings(contrary: [.pinningAbsent], supporting: [.pinningObserved])),
            ("O.Ntwk_5", .outsideToolScope),
            ("O.Ntwk_6", .outsideToolScope),
            ("O.Ntwk_7", .outsideToolScope),
            ("O.Ntwk_8", .outsideToolScope),
        ]
        XCTAssertEqual(rules.map(\.0), expected.map(\.0))
        XCTAssertEqual(rules.map(\.1), expected.map(\.1))
    }

    func testEveryFindingKindBearsOnARequirementOfTheBundledCatalogue() throws {
        let catalogue = try RequirementCatalogueLibrary.catalogue(identifier: "tr-03161-1_3.0")
        var read: Set<FindingKind> = []
        for requirement in catalogue.requirements {
            switch requirement.rule {
            case .outsideToolScope:
                break
            case .contraryFindings(let kinds):
                read.formUnion(kinds)
            case .contraryAndSupportingFindings(let contrary, let supporting):
                read.formUnion(contrary)
                read.formUnion(supporting)
            }
        }
        XCTAssertEqual(read, Set(FindingKind.allCases))
    }

    func testAProjectWithoutACatalogueGetsTheDefault() throws {
        let catalogue = try RequirementCatalogueLibrary.catalogue(for: project(catalogue: nil))
        XCTAssertEqual(catalogue.identifier, RequirementCatalogueLibrary.defaultIdentifier)
    }

    func testAProjectGetsTheCatalogueItNames() throws {
        let catalogue = try RequirementCatalogueLibrary.catalogue(for: project(catalogue: "tr-03161-1_3.0"))
        XCTAssertEqual(catalogue.identifier, "tr-03161-1_3.0")
    }

    func testACatalogueThatIsNotBundledIsNotReplacedByAnother() {
        XCTAssertThrowsError(
            try RequirementCatalogueLibrary.catalogue(for: project(catalogue: "tr-03161-1_9.9"))
        ) { error in
            XCTAssertEqual(
                error as? RequirementCatalogueLibraryError,
                .notBundled(identifier: "tr-03161-1_9.9")
            )
        }
    }

    func testASessionIsAssessedRequirementByRequirement() throws {
        let catalogue = try RequirementCatalogueLibrary.catalogue(identifier: "tr-03161-1_3.0")
        let flows = [
            // Antes del consentimiento, a un host de la allowlist, con TLS 1.3 y rechazando la CA.
            Fixtures.flow(
                id: 1,
                tlsStatus: .notInspectable,
                sni: "api.example.com",
                serverTLS: Fixtures.negotiated(.tls13),
                streamOpening: .tlsHandshake
            ),
            // Después, a un host de fuera, con TLS 1.1.
            Fixtures.flow(
                id: 20,
                sni: "ads.example.net",
                serverTLS: Fixtures.negotiated(.tls11),
                streamOpening: .tlsHandshake
            ),
        ]
        let assessment = SessionAssessment(
            catalogue: catalogue,
            flows: flows,
            project: try Fixtures.project(allowlist: ["api.example.com"]),
            session: Fixtures.session(inspection: InspectionConditions(inspectionEnabled: true, caTrusted: true)),
            markers: [Fixtures.marker(id: 1, at: 10)]
        )

        XCTAssertEqual(assessment.requirements.map(\.requirement.id), catalogue.requirements.map(\.id))
        let verdicts = Dictionary(
            uniqueKeysWithValues: assessment.requirements.map { ($0.requirement.id, $0.verdict) }
        )
        XCTAssertEqual(verdicts["O.Purp_3"], .contradicted)
        XCTAssertEqual(verdicts["O.Purp_8"], .contradicted)
        XCTAssertEqual(verdicts["O.Ntwk_1"], .observedWithoutContradiction)
        XCTAssertEqual(verdicts["O.Ntwk_2"], .contradicted)
        XCTAssertEqual(verdicts["O.Ntwk_4"], .observedWithoutContradiction)
        for id in ["O.Ntwk_3", "O.Ntwk_5", "O.Ntwk_6", "O.Ntwk_7", "O.Ntwk_8"] {
            XCTAssertEqual(verdicts[id], .notAssessed(.outsideToolScope), id)
        }
    }

    func testTheSessionIsClassifiedWithTheCataloguesOwnMinimum() throws {
        let catalogue = try RequirementCatalogueLibrary.catalogue(identifier: "tr-03161-1_3.0")
        let assessment = SessionAssessment(
            catalogue: catalogue,
            flows: [Fixtures.flow(id: 1, serverTLS: Fixtures.negotiated(.tls12))],
            project: try Fixtures.project(),
            session: Fixtures.session(inspection: InspectionConditions(inspectionEnabled: false, caTrusted: false)),
            markers: []
        )

        XCTAssertEqual(assessment.findings.tlsVersion.satisfiedFlowIDs, [1])
        XCTAssertFalse(assessment.findings.findings.contains { $0.kind == .weakTLSVersion })
    }
}
