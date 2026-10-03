import Foundation
import XCTest
import Shared

/// Tests de los dos formularios de auditoría: lo que alguien teclea, convertido en un borrador o en
/// **lo primero** que tiene mal, con la línea a la que se refiere.
final class AuditFormsTests: XCTestCase {

    private func form(name: String = "Example Health", lines: [AllowlistLine]) -> AuditProjectForm {
        var form = AuditProjectForm()
        form.name = name
        form.lines = lines
        return form
    }

    // MARK: - El proyecto

    func testABlankFormStartsWithOneLineReadyToWrite() {
        let form = AuditProjectForm()
        XCTAssertEqual(form.lines.count, 1)
        XCTAssertEqual(form.draft(), .failure(.emptyProjectName))
    }

    func testAFormBecomesADraftTrimmedAndWithoutItsBlankLines() throws {
        var form = form(
            name: "  Example Health ",
            lines: [
                AllowlistLine(pattern: " API.Example.com. ", note: " Backend "),
                AllowlistLine(),
                AllowlistLine(pattern: "*.cdn.example.com", note: "   "),
            ]
        )
        form.bundleIdentifier = "  "

        let draft = try form.draft().get()

        XCTAssertEqual(draft.name, "Example Health")
        XCTAssertNil(draft.bundleIdentifier, "un identificador en blanco es que no se escribió")
        XCTAssertEqual(draft.allowlist.map(\.pattern.text), ["api.example.com", "*.cdn.example.com"])
        XCTAssertEqual(draft.allowlist.map(\.note), ["Backend", nil])
    }

    func testTheIssuePointsAtTheLineThatHasIt() {
        let bad = AllowlistLine(pattern: "https://api.example.com")
        let result = form(lines: [AllowlistLine(pattern: "ok.example.com"), bad]).draft()

        XCTAssertEqual(result, .failure(.invalidPattern(line: bad.id, reason: .invalidCharacter(":"))))
        guard case .failure(let issue) = result else { return XCTFail("debería haber un problema") }
        XCTAssertEqual(issue.line, bad.id)
        // Una URL pegada es el error de verdad: la frase nombra el carácter que sobra.
        XCTAssertTrue(AuditPresentation.message(for: issue).contains(":"))
    }

    func testTheSecondOfTwoEqualPatternsIsTheOneMarked() {
        let first = AllowlistLine(pattern: "api.example.com")
        let second = AllowlistLine(pattern: "API.example.com.")

        let result = form(lines: [first, second]).draft()

        // Iguales una vez normalizados, que es como los guarda el store.
        XCTAssertEqual(result, .failure(.duplicatePattern(line: second.id, pattern: "api.example.com")))
    }

    func testANoteWithoutADomainIsNotSilentlyDropped() {
        let orphan = AllowlistLine(pattern: "  ", note: "crash reporting")

        // Quien la escribió creía estar permitiendo algo: ignorarla dejaría un hueco en la allowlist.
        XCTAssertEqual(form(lines: [orphan]).draft(), .failure(.noteWithoutPattern(line: orphan.id)))
    }

    func testOnlyTheFirstIssueIsReported() {
        let bad = AllowlistLine(pattern: "a..b")
        // Sin nombre **y** con un patrón malo: se corrige de arriba abajo.
        XCTAssertEqual(form(name: " ", lines: [bad]).draft(), .failure(.emptyProjectName))
    }

    func testEditingAProjectRoundTripsWhatItDeclares() throws {
        let project = AuditProject(
            id: 7,
            name: "Example Health",
            bundleIdentifier: "com.example.health",
            catalogueVersion: "tr-03161-1_test",
            allowlist: [
                AllowlistEntry(pattern: try DomainPattern(parsing: "api.example.com"), note: "Backend"),
                AllowlistEntry(pattern: try DomainPattern(parsing: "*.cdn.example.com"), note: nil),
            ],
            createdAt: Date(timeIntervalSince1970: 0)
        )

        let draft = try AuditProjectForm(editing: project).draft().get()

        XCTAssertEqual(draft.name, project.name)
        XCTAssertEqual(draft.bundleIdentifier, project.bundleIdentifier)
        XCTAssertEqual(draft.allowlist, project.allowlist)
        // El formulario no lo edita, pero tampoco lo pierde.
        XCTAssertEqual(draft.catalogueVersion, "tr-03161-1_test")
    }

    func testEveryPatternRejectionHasASentenceOfItsOwn() {
        let reasons: [DomainPattern.ParseError] = [
            .empty, .misplacedWildcard, .nonASCII, .emptyLabel, .labelTooLong("x"), .nameTooLong,
            .invalidCharacter("/"),
        ]
        let line = UUID()
        let messages = reasons.map { AuditPresentation.message(for: .invalidPattern(line: line, reason: $0)) }

        XCTAssertEqual(Set(messages).count, reasons.count, "«patrón inválido» a secas deja adivinando cuál de las reglas")
    }

    // MARK: - La sesión

    func testAnAuditSessionNeedsBothVersionAndBuild() {
        var form = AuditSessionForm(role: .audit)
        XCTAssertEqual(form.kind(), .failure(.missingRelease))

        form.version = " 2.4.0 "
        XCTAssertEqual(form.kind(), .failure(.missingRelease), "dos builds de una versión son binarios distintos")

        form.build = " 187 "
        XCTAssertEqual(form.kind(), .success(.audit(AppRelease(version: "2.4.0", build: "187"))))
    }

    func testABaselineIgnoresWhateverWasTypedAsRelease() {
        var form = AuditSessionForm(role: .baseline)
        form.version = "2.4.0"
        form.build = "187"

        // Se graba sin la app auditada: no puede llevar una release.
        XCTAssertEqual(form.kind(), .success(.baseline))
    }

    func testTheFirstSessionSuggestedIsTheBaselineAndThenAnAudit() {
        XCTAssertEqual(AuditSessionForm.suggestedRole(existing: []), .baseline)

        let environment = AuditEnvironment(deviceModel: "iPhone18,3", osVersion: "26.5", toolVersion: "1.0.0 (1)")
        let inspection = InspectionConditions(inspectionEnabled: false, caTrusted: false)
        func session(_ kind: AuditSessionKind) -> AuditSession {
            AuditSession(
                id: 1, projectID: 1, kind: kind, environment: environment, inspection: inspection,
                startedAt: Date(timeIntervalSince1970: 0), endedAt: nil, notes: ""
            )
        }

        XCTAssertEqual(AuditSessionForm.suggestedRole(existing: [session(.baseline)]), .audit)
        XCTAssertEqual(
            AuditSessionForm.suggestedRole(existing: [session(.audit(AppRelease(version: "1", build: "1")))]),
            .baseline,
            "sin baseline no hay contra qué leer el tráfico de la app"
        )
    }

    func testEachSessionRoleSaysWhatToDoBeforeStarting() {
        XCTAssertNotEqual(AuditPresentation.sessionRoleFooter(.audit), AuditPresentation.sessionRoleFooter(.baseline))
        XCTAssertNotEqual(AuditPresentation.label(for: .audit), AuditPresentation.label(for: .baseline))
        // La baseline se llama igual en el selector que en la lista de sesiones.
        XCTAssertEqual(AuditPresentation.label(for: .baseline), AuditPresentation.sessionTitle(.baseline))
    }
}
