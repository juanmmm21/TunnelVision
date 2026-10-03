import AppIntents
import Foundation
import XCTest
@testable import Shared

/// Tests de lo que el marcador de fuera de la app **dice**. La regla que sujetan: solo un marcador
/// escrito produce una confirmación; todo lo demás es un error que dice que no se puso nada.
final class AuditMarkerIntentCopyTests: XCTestCase {

    // MARK: - Las opciones

    func testTheOptionsAreTheFixedMarkersOfTheSessionScreenWithTheSameNamesAndSymbols() {
        // App Intents obliga a repetir estos textos como literales; esto es lo que impide que el
        // control y la pantalla llamen distinto al mismo marcador, o que un marcador fijo nuevo se
        // quede sin su opción.
        let choices = AuditPresentation.markerChoices
        XCTAssertEqual(AuditMarkerOption.allCases.map(\.kind), choices.map(\.kind))
        XCTAssertEqual(AuditMarkerOption.allCases.map(\.title), choices.map(\.title))
        XCTAssertEqual(AuditMarkerOption.allCases.map(\.systemImage), choices.map(\.systemImage))
    }

    func testEveryOptionHasADisplayRepresentation() {
        XCTAssertEqual(
            Set(AuditMarkerOption.caseDisplayRepresentations.keys), Set(AuditMarkerOption.allCases)
        )
        XCTAssertEqual(AuditMarkerOption.allCases.map(\.title), ["Consent given", "Logged in", "Logged out"])
    }

    func testTheIntentMarksConsentUnlessToldOtherwiseAndNeverOpensTheApp() {
        XCTAssertEqual(PlaceAuditMarkerIntent().marker, .consentGiven)
        XCTAssertEqual(PlaceAuditMarkerIntent(marker: .loggedOut).marker, .loggedOut)
        XCTAssertFalse(PlaceAuditMarkerIntent.openAppWhenRun)
    }

    // MARK: - Lo que se dice después

    func testAPlacedMarkerIsConfirmedWithItsNameItsTimeToTheSecondAndItsProject() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_027)
        let reading = AuditMarkerIntentCopy.reading(
            .placed(title: "Consent given", date: date, projectName: "Example Health")
        )

        let confirmation = String(localized: try reading.get())
        let time = date.formatted(date: .omitted, time: .standard)
        XCTAssertEqual(confirmation, "“Consent given” marked at \(time) in Example Health.")
        // Al segundo: es lo que deja cotejarlo con lo que pasaba en la app auditada.
        XCTAssertTrue(time.contains(":47"), time)
    }

    func testNoOpenSessionIsAnErrorThatSaysNothingWasPlaced() {
        let reading = AuditMarkerIntentCopy.reading(.noOpenSession)

        XCTAssertEqual(reading.failure, .noOpenSession)
        XCTAssertEqual(
            String(localized: AuditMarkerIntentError.noOpenSession.localizedStringResource),
            "No marker was placed: no audit session is recording. Start one in TunnelVision first."
        )
    }

    func testAMarkerThatCouldNotBeWrittenIsAnErrorThatSaysNothingWasPlaced() {
        let reading = AuditMarkerIntentCopy.reading(.notPlaced)

        XCTAssertEqual(reading.failure, .notPlaced)
        XCTAssertEqual(
            String(localized: AuditMarkerIntentError.notPlaced.localizedStringResource),
            "No marker was placed: TunnelVision couldn't write to its history. Open the app and try again."
        )
    }

    // MARK: - Lo que el control dice antes

    func testTheControlStatusNamesTheProjectOrSaysWhyNothingWouldBeMarked() {
        XCTAssertEqual(
            AuditMarkerIntentCopy.controlStatus(.recording(projectName: "Example Health")), "Example Health"
        )
        XCTAssertEqual(AuditMarkerIntentCopy.controlStatus(.idle), "No session recording")
        XCTAssertEqual(AuditMarkerIntentCopy.controlStatus(.unavailable), "History unavailable")
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
