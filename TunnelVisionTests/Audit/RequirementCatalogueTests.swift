import Foundation
import Shared
import XCTest

/// Tests del formato del catálogo: que uno bien escrito se lee entero y que uno mal escrito
/// falla al cargarlo, diciendo dónde, en vez de llegar a un informe.
final class RequirementCatalogueTests: XCTestCase {

    private static let digest = String(repeating: "a", count: 64)

    private static func source() -> [String: Any] {
        ["document": "Test Guideline", "title": "A guideline", "version": "1.0", "date": "2026-01-31", "sha256": digest]
    }

    private static func requirement(
        id: String = "T.Net_1",
        rule: String = "contraryFindings",
        contrary: [String]? = ["cleartextTraffic"],
        supporting: [String]? = nil,
        coverage: String? = "Only HTTP is recognised."
    ) -> [String: Any] {
        var entry: [String: Any] = [
            "id": id,
            "aspect": ["number": 9, "name": "Network"],
            "title": "Traffic is encrypted.",
            "testDepth": "EXAMINE",
            "rule": rule,
        ]
        entry["contraryKinds"] = contrary
        entry["supportingKinds"] = supporting
        entry["toolCoverage"] = coverage
        return entry
    }

    private static func file(
        formatVersion: Int = 1,
        minimumTLS: String = "1.2",
        requirements: [[String: Any]] = [requirement()]
    ) -> [String: Any] {
        [
            "formatVersion": formatVersion,
            "identifier": "test_1.0",
            "source": source(),
            "tls": ["minimumVersion": minimumTLS, "source": source()],
            "requirements": requirements,
        ]
    }

    private func load(_ file: [String: Any]) throws -> RequirementCatalogue {
        try RequirementCatalogue(data: try JSONSerialization.data(withJSONObject: file))
    }

    private func assertRefused(
        _ file: [String: Any],
        with expected: RequirementCatalogueError,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try load(file), line: line) { error in
            XCTAssertEqual(error as? RequirementCatalogueError, expected, line: line)
        }
    }

    func testAWellWrittenCatalogueIsReadWhole() throws {
        let catalogue = try load(Self.file(requirements: [
            Self.requirement(),
            Self.requirement(
                id: "T.Net_2",
                rule: "contraryAndSupportingFindings",
                contrary: ["pinningAbsent"],
                supporting: ["pinningObserved"]
            ),
            Self.requirement(id: "T.Net_3", rule: "outsideToolScope", contrary: nil, coverage: nil),
        ]))

        XCTAssertEqual(catalogue.identifier, "test_1.0")
        XCTAssertEqual(catalogue.source.version, "1.0")
        XCTAssertEqual(catalogue.source.date, "2026-01-31")
        XCTAssertEqual(catalogue.policy.minimumTLSVersion, .tls12)
        XCTAssertEqual(catalogue.requirements.map(\.id), ["T.Net_1", "T.Net_2", "T.Net_3"])

        let first = catalogue.requirements[0]
        XCTAssertEqual(first.aspect, RequirementAspect(number: 9, name: "Network"))
        XCTAssertEqual(first.title, "Traffic is encrypted.")
        XCTAssertEqual(first.testDepth, .examine)
        XCTAssertEqual(first.rule, .contraryFindings([.cleartextTraffic]))
        XCTAssertEqual(first.toolCoverage, "Only HTTP is recognised.")
        XCTAssertEqual(
            catalogue.requirements[1].rule,
            .contraryAndSupportingFindings(contrary: [.pinningAbsent], supporting: [.pinningObserved])
        )
        XCTAssertEqual(catalogue.requirements[2].rule, .outsideToolScope)
        XCTAssertNil(catalogue.requirements[2].toolCoverage)
    }

    func testEachTLSVersionTheFormatNamesIsAMinimum() throws {
        let versions: [(String, TLSProtocolVersion)] = [("1.0", .tls10), ("1.1", .tls11), ("1.2", .tls12), ("1.3", .tls13)]
        for (name, version) in versions {
            XCTAssertEqual(try load(Self.file(minimumTLS: name)).policy.minimumTLSVersion, version, name)
        }
    }

    func testAMinimumTheFormatDoesNotNameIsRefused() {
        for name in ["", "TLS 1.2", "1.4", "771", "SSL 3.0"] {
            assertRefused(Self.file(minimumTLS: name), with: .unknownTLSVersion(name))
        }
    }

    func testAnotherFormatVersionIsRefused() {
        assertRefused(Self.file(formatVersion: 2), with: .unsupportedFormatVersion(2))
    }

    func testSomethingThatIsNotTheFormatIsMalformed() {
        var file = Self.file()
        file["requirements"] = "none"
        XCTAssertThrowsError(try load(file)) { error in
            guard case .malformed = error as? RequirementCatalogueError else {
                return XCTFail("\(error)")
            }
        }
        XCTAssertThrowsError(try RequirementCatalogue(data: Data("not json".utf8))) { error in
            guard case .malformed = error as? RequirementCatalogueError else {
                return XCTFail("\(error)")
            }
        }
    }

    func testACatalogueWithoutRequirementsIsRefused() {
        assertRefused(Self.file(requirements: []), with: .noRequirements)
    }

    func testARepeatedRequirementIsRefused() {
        assertRefused(
            Self.file(requirements: [Self.requirement(), Self.requirement()]),
            with: .duplicateRequirement("T.Net_1")
        )
    }

    func testAnUnknownFindingKindIsRefused() {
        assertRefused(
            Self.file(requirements: [Self.requirement(contrary: ["cleartextTraffic", "expiredCertificate"])]),
            with: .unknownFindingKind(requirement: "T.Net_1", value: "expiredCertificate")
        )
        assertRefused(
            Self.file(requirements: [Self.requirement(
                rule: "contraryAndSupportingFindings",
                contrary: ["pinningAbsent"],
                supporting: ["pinned"]
            )]),
            with: .unknownFindingKind(requirement: "T.Net_1", value: "pinned")
        )
    }

    func testAnUnknownRuleOrTestDepthIsRefused() {
        assertRefused(
            Self.file(requirements: [Self.requirement(rule: "passIfNoFindings")]),
            with: .unknownRule(requirement: "T.Net_1", value: "passIfNoFindings")
        )
        var entry = Self.requirement()
        entry["testDepth"] = "check"
        assertRefused(
            Self.file(requirements: [entry]),
            with: .unknownTestDepth(requirement: "T.Net_1", value: "check")
        )
    }

    func testARuleAndItsKindsHaveToFit() {
        let cases: [(rule: String, contrary: [String]?, supporting: [String]?, problem: RuleShapeProblem)] = [
            ("outsideToolScope", ["cleartextTraffic"], nil, .unexpectedContraryKinds),
            ("outsideToolScope", nil, ["pinningObserved"], .unexpectedSupportingKinds),
            ("contraryFindings", nil, nil, .missingContraryKinds),
            ("contraryFindings", [], nil, .missingContraryKinds),
            ("contraryFindings", ["pinningAbsent"], ["pinningObserved"], .unexpectedSupportingKinds),
            ("contraryAndSupportingFindings", nil, ["pinningObserved"], .missingContraryKinds),
            ("contraryAndSupportingFindings", ["pinningAbsent"], nil, .missingSupportingKinds),
            ("contraryFindings", ["cleartextTraffic", "cleartextTraffic"], nil, .repeatedKind(.cleartextTraffic)),
            ("contraryAndSupportingFindings", ["pinningAbsent"], ["pinningAbsent"], .repeatedKind(.pinningAbsent)),
            ("contraryFindings", ["cleartextTraffic", "weakTLSVersion"], nil, .kindsOfSeveralChecks),
            ("contraryAndSupportingFindings", ["cleartextTraffic"], ["pinningObserved"], .kindsOfSeveralChecks),
        ]
        for testCase in cases {
            assertRefused(
                Self.file(requirements: [Self.requirement(
                    rule: testCase.rule,
                    contrary: testCase.contrary,
                    supporting: testCase.supporting
                )]),
                with: .ruleShape(requirement: "T.Net_1", problem: testCase.problem)
            )
        }
    }

    func testTwoKindsOfTheSameCheckFitOneRule() throws {
        let catalogue = try load(Self.file(requirements: [
            Self.requirement(contrary: ["hostNotInAllowlist", "unnamedFlow"]),
        ]))
        XCTAssertEqual(catalogue.requirements[0].rule.check, .host)
    }

    func testARuleThatReadsFindingsHasToSayWhatItCovers() {
        for coverage in [nil, "", "  \n"] as [String?] {
            assertRefused(
                Self.file(requirements: [Self.requirement(coverage: coverage)]),
                with: .missingToolCoverage(requirement: "T.Net_1")
            )
        }
    }

    func testAnEmptyIdentifierOrTitleIsRefused() {
        var file = Self.file()
        file["identifier"] = " "
        assertRefused(file, with: .emptyField("identifier"))

        var entry = Self.requirement()
        entry["title"] = ""
        assertRefused(Self.file(requirements: [entry]), with: .emptyField("T.Net_1.title"))
    }

    func testASourceNeedsARealDateAndADigest() {
        for date in ["31.01.2026", "2026-13-01", "2026-1-31", "2026-01-31T00:00:00Z"] {
            var file = Self.file()
            var source = Self.source()
            source["date"] = date
            file["source"] = source
            assertRefused(file, with: .invalidDate(date))
        }
        for digest in ["", "abc", String(repeating: "A", count: 64), String(repeating: "g", count: 64)] {
            var file = Self.file()
            var source = Self.source()
            source["sha256"] = digest
            file["tls"] = ["minimumVersion": "1.2", "source": source]
            assertRefused(file, with: .invalidDigest(digest))
        }
    }

    func testEveryFindingKindBelongsToOneCheck() {
        let byCheck = Dictionary(grouping: FindingKind.allCases, by: \.check)
        XCTAssertEqual(byCheck[.encryption], [.cleartextTraffic])
        XCTAssertEqual(byCheck[.tlsVersion], [.weakTLSVersion])
        XCTAssertEqual(byCheck[.host], [.hostNotInAllowlist, .unnamedFlow])
        XCTAssertEqual(byCheck[.pinning], [.pinningAbsent, .pinningObserved])
        XCTAssertEqual(byCheck[.consent], [.activityBeforeConsent])
        XCTAssertEqual(Set(byCheck.keys), Set(FindingsCheck.allCases))
    }
}
