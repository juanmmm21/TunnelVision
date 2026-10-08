import XCTest
@testable import Shared

/// Tests de los patrones de la allowlist. Lo que se afirma es que un patrón dice lo mismo se escriba
/// como se escriba, que uno que nunca podría coincidir no se deja construir, y dónde está exactamente
/// el borde de un comodín — que es de lo que depende qué conexión sale como inesperada en un informe.
final class DomainPatternTests: XCTestCase {

    // MARK: - Normalización

    func testAnExactNameIsNormalised() throws {
        let pattern = try DomainPattern(parsing: "  API.Example.COM.  ")
        XCTAssertEqual(pattern.scope, .exact)
        XCTAssertEqual(pattern.name, "api.example.com")
        XCTAssertEqual(pattern.text, "api.example.com")
    }

    func testAWildcardKeepsItsPrefixInTheCanonicalText() throws {
        let pattern = try DomainPattern(parsing: "*.Example.com")
        XCTAssertEqual(pattern.scope, .subdomains)
        XCTAssertEqual(pattern.name, "example.com")
        XCTAssertEqual(pattern.text, "*.example.com")
    }

    func testTwoSpellingsOfTheSameNameAreTheSamePattern() throws {
        XCTAssertEqual(
            try DomainPattern(parsing: "Example.com."),
            try DomainPattern(parsing: "example.com")
        )
    }

    func testTheCanonicalTextParsesBackToTheSamePattern() throws {
        for text in ["example.com", "*.example.com", "_dmarc.example.com", "xn--mnchen-3ya.de"] {
            let pattern = try DomainPattern(parsing: text)
            XCTAssertEqual(try DomainPattern(parsing: pattern.text), pattern)
        }
    }

    // MARK: - Lo que no se deja construir

    private func assertParsing(
        _ text: String,
        throws expected: DomainPattern.ParseError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try DomainPattern(parsing: text), file: file, line: line) { error in
            XCTAssertEqual(error as? DomainPattern.ParseError, expected, file: file, line: line)
        }
    }

    func testEmptyTextIsRejected() {
        assertParsing("", throws: .empty)
        assertParsing("   ", throws: .empty)
        assertParsing("*.", throws: .empty)
        assertParsing(".", throws: .empty)
    }

    func testAWildcardAnywhereButTheFrontIsRejected() {
        assertParsing("*", throws: .misplacedWildcard)
        assertParsing("*example.com", throws: .misplacedWildcard)
        assertParsing("api.*.example.com", throws: .misplacedWildcard)
        assertParsing("*.*.example.com", throws: .misplacedWildcard)
    }

    func testANonASCIINameIsRejectedSoItGetsWrittenInPunycode() {
        assertParsing("münchen.de", throws: .nonASCII)
    }

    func testAnEmptyLabelIsRejected() {
        assertParsing("example..com", throws: .emptyLabel)
        assertParsing(".example.com", throws: .emptyLabel)
    }

    func testLengthLimitsAreEnforced() throws {
        let longestLabel = String(repeating: "a", count: 63)
        XCTAssertNoThrow(try DomainPattern(parsing: "\(longestLabel).com"))

        let tooLong = String(repeating: "a", count: 64)
        assertParsing("\(tooLong).com", throws: .labelTooLong(tooLong))

        // Cuatro etiquetas de 63 más sus puntos son 255: dos por encima del tope del nombre.
        let name = Array(repeating: longestLabel, count: 4).joined(separator: ".")
        assertParsing(name, throws: .nameTooLong)
    }

    func testCharactersThatNoNameCarriesAreRejected() {
        assertParsing("exa mple.com", throws: .invalidCharacter(" "))
        assertParsing("https://example.com", throws: .invalidCharacter(":"))
        assertParsing("example.com/path", throws: .invalidCharacter("/"))
    }

    // MARK: - Coincidencia

    func testAnExactPatternMatchesOnlyItsName() throws {
        let pattern = try DomainPattern(parsing: "api.example.com")
        XCTAssertTrue(pattern.matches("api.example.com"))
        XCTAssertFalse(pattern.matches("example.com"))
        XCTAssertFalse(pattern.matches("v2.api.example.com"))
        XCTAssertFalse(pattern.matches("api.example.com.evil.net"))
    }

    func testAWildcardMatchesAnyDepthBelowItsSuffix() throws {
        let pattern = try DomainPattern(parsing: "*.example.com")
        XCTAssertTrue(pattern.matches("api.example.com"))
        XCTAssertTrue(pattern.matches("v2.api.example.com"))
    }

    func testAWildcardDoesNotMatchItsOwnSuffix() throws {
        let pattern = try DomainPattern(parsing: "*.example.com")
        XCTAssertFalse(pattern.matches("example.com"))
    }

    /// El borde que importa: un sufijo de texto no es un sufijo de etiquetas.
    func testAWildcardDoesNotMatchANameThatMerelyEndsWithTheSameLetters() throws {
        let pattern = try DomainPattern(parsing: "*.example.com")
        XCTAssertFalse(pattern.matches("notexample.com"))
        XCTAssertFalse(pattern.matches("api.notexample.com"))
        XCTAssertFalse(pattern.matches("api.example.com.evil.net"))
    }

    func testTheObservedNameIsNormalisedLikeThePattern() throws {
        XCTAssertTrue(try DomainPattern(parsing: "api.example.com").matches("API.Example.com."))
        XCTAssertTrue(try DomainPattern(parsing: "*.example.com").matches("API.Example.com."))
    }

    // MARK: - La allowlist de un proyecto

    private func project(_ entries: [(String, String?)]) throws -> AuditProject {
        AuditProject(
            id: 1,
            name: "Example",
            bundleIdentifier: nil,
            catalogueVersion: nil,
            allowlist: try entries.map { AllowlistEntry(pattern: try DomainPattern(parsing: $0.0), note: $0.1) },
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testAProjectAnswersWithTheEntryThatCoversAName() throws {
        let project = try project([("api.example.com", "backend"), ("*.sentry.io", "crash reporting")])
        XCTAssertEqual(project.allowlistEntry(matching: "api.example.com")?.note, "backend")
        XCTAssertEqual(project.allowlistEntry(matching: "o123.ingest.sentry.io")?.note, "crash reporting")
    }

    func testANameOutsideTheAllowlistHasNoEntry() throws {
        let project = try project([("api.example.com", nil)])
        XCTAssertNil(project.allowlistEntry(matching: "tracker.example.net"))
    }

    func testAnEmptyAllowlistCoversNothing() throws {
        XCTAssertNil(try project([]).allowlistEntry(matching: "api.example.com"))
    }

    func testTheFirstCoveringEntryWins() throws {
        let project = try project([("*.example.com", "wildcard"), ("api.example.com", "exact")])
        XCTAssertEqual(project.allowlistEntry(matching: "api.example.com")?.note, "wildcard")
    }

    // MARK: - Condiciones de inspección

    /// La forma en que se compara un nombre observado es también la forma en que se cita.
    func testAnObservedHostIsNormalisedLikeAPattern() {
        XCTAssertEqual(DomainPattern.normalised(host: "API.Example.COM."), "api.example.com")
        XCTAssertEqual(DomainPattern.normalised(host: "api.example.com"), "api.example.com")
    }

    func testPinningCanOnlyBeReadWithInspectionOnAndTheCATrusted() {
        XCTAssertTrue(InspectionConditions(inspectionEnabled: true, caTrusted: true).supportsPinningEvidence)
        XCTAssertFalse(InspectionConditions(inspectionEnabled: true, caTrusted: false).supportsPinningEvidence)
        XCTAssertFalse(InspectionConditions(inspectionEnabled: false, caTrusted: true).supportsPinningEvidence)
        XCTAssertFalse(InspectionConditions(inspectionEnabled: false, caTrusted: false).supportsPinningEvidence)
    }

    func testOnlyAnAuditSessionCarriesARelease() {
        let release = AppRelease(version: "2.4.0", build: "187")
        XCTAssertEqual(AuditSessionKind.audit(release).release, release)
        XCTAssertNil(AuditSessionKind.baseline.release)
    }
}
