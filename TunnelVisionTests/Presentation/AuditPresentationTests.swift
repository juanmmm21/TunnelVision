import Foundation
import XCTest
import Shared

/// Tests de lo que la pestaña de auditoría decide sin pintar nada (`AuditPresentation`): qué cuerpo
/// le toca a la pantalla, cuál es la sesión que graba, qué dice una sesión sobre pinning y qué se le
/// cuenta al usuario cuando una acción no sale.
final class AuditPresentationTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func project(_ id: Int64, name: String = "Example Health", bundle: String? = nil) -> AuditProject {
        AuditProject(
            id: id,
            name: name,
            bundleIdentifier: bundle,
            catalogueVersion: nil,
            allowlist: [],
            createdAt: start
        )
    }

    private func session(
        _ id: Int64,
        project: Int64 = 1,
        kind: AuditSessionKind = .audit(AppRelease(version: "2.4.0", build: "187")),
        inspection: InspectionConditions = InspectionConditions(inspectionEnabled: true, caTrusted: true),
        ended: Bool = true,
        notes: String = ""
    ) -> AuditSession {
        AuditSession(
            id: id,
            projectID: project,
            kind: kind,
            environment: AuditEnvironment(deviceModel: "iPhone18,3", osVersion: "26.5", toolVersion: "1.0.0 (1)"),
            inspection: inspection,
            startedAt: start,
            endedAt: ended ? start.addingTimeInterval(600) : nil,
            notes: notes
        )
    }

    private func overview(_ entries: [(AuditProject, [AuditSession])]) -> AuditOverview {
        AuditOverview(projects: entries.map { AuditProjectOverview(project: $0.0, sessions: $0.1) })
    }

    // MARK: - El cuerpo de la pantalla

    func testEachStateFallsInOneBody() {
        XCTAssertEqual(AuditPresentation.content(state: .idle, projectCount: 0), .loading)
        XCTAssertEqual(AuditPresentation.content(state: .loading, projectCount: 0), .loading)

        guard case .placeholder(let empty) = AuditPresentation.content(state: .loaded, projectCount: 0) else {
            return XCTFail("sin proyectos y sin fallo, la pantalla enseña el vacío")
        }
        // El vacío **enseña** y ofrece el siguiente paso, no un reintento.
        XCTAssertEqual(empty.action, .newProject)
        XCTAssertEqual(empty.role, .accent)

        let failure = AuditLibraryError.history(.queryFailed("database is locked"))
        guard case .placeholder(let failed) = AuditPresentation.content(state: .failed(failure), projectCount: 0) else {
            return XCTFail("un fallo sin proyectos es el cuerpo de la pantalla")
        }
        XCTAssertEqual(failed.action, .retry)
        XCTAssertEqual(failed.diagnostic, "database is locked")
    }

    func testAListAlreadyDrawnIsNeverCoveredByAFailure() {
        let failure = AuditLibraryError.history(.queryFailed("io"))
        XCTAssertEqual(AuditPresentation.content(state: .failed(failure), projectCount: 2), .list)
    }

    // MARK: - La lista de proyectos

    func testAProjectRowCountsItsSessionsAndOnlyTheRecordingOneIsMarked() {
        let rows = AuditPresentation.projectRows(
            overview([
                (project(1, name: "Recording"), [session(1, ended: false), session(2)]),
                (project(2, name: "One"), [session(3, project: 2)]),
                (project(3, name: "None"), []),
            ])
        )

        XCTAssertEqual(rows.map(\.detail), ["2 sessions", "1 session", "No sessions yet"])
        XCTAssertEqual(rows.map(\.isRecording), [true, false, false])
        // Lo que no se ve —el distintivo— se tiene que oír.
        XCTAssertEqual(rows[0].accessibilityValue, "Recording now. 2 sessions")
        XCTAssertEqual(rows[1].accessibilityValue, "1 session")
    }

    func testTheRecordingSessionIsFoundWhicheverProjectHoldsIt() {
        let none = overview([(project(1), [session(1)])])
        XCTAssertNil(none.recording)
        XCTAssertNil(AuditPresentation.recordingBanner(none))

        let open = overview([(project(1), [session(1)]), (project(2, name: "Cardio"), [session(2, project: 2, ended: false)])])
        XCTAssertEqual(open.recording?.session.id, 2)

        let banner = AuditPresentation.recordingBanner(open)
        XCTAssertEqual(banner?.projectID, 2)
        XCTAssertEqual(banner?.sessionID, 2)
        // Dice de quién es y que se etiqueta **todo**: es lo que hace que una sesión olvidada importe.
        XCTAssertEqual(banner?.detail, "Every connection is being tagged for Cardio.")
    }

    // MARK: - Un proyecto

    func testASessionIsNamedAfterItsReleaseAndNeverReformatted() {
        XCTAssertEqual(AuditPresentation.sessionTitle(.baseline), "Baseline")
        // Un build de cuatro cifras **identifica** un binario: agrupado sería otro.
        XCTAssertEqual(
            AuditPresentation.sessionTitle(.audit(AppRelease(version: "2.4.0", build: "1870"))),
            "Version 2.4.0 (1870)"
        )
    }

    func testAProjectCanStartASessionOnlyWhileNothingIsRecording() {
        let entry = AuditProjectOverview(project: project(1, bundle: "com.example.health"), sessions: [session(1)])

        let free = AuditPresentation.project(entry, recording: nil)
        XCTAssertTrue(free.canStartSession)
        XCTAssertNil(free.startBlockedNote)
        XCTAssertEqual(free.bundleIdentifier, "com.example.health")
        XCTAssertEqual(free.sessions.map(\.title), ["Version 2.4.0 (187)"])

        // La suya propia.
        let own = AuditPresentation.project(entry, recording: (project(1), session(9, ended: false)))
        XCTAssertFalse(own.canStartSession)
        XCTAssertEqual(own.startBlockedNote, "End the session that is recording before starting another.")

        // La de **otro** proyecto también lo impide, y entonces hay que decir cuál: desde aquí no se ve.
        let other = AuditPresentation.project(
            entry, recording: (project(2, name: "Cardio"), session(9, project: 2, ended: false))
        )
        XCTAssertFalse(other.canStartSession)
        XCTAssertTrue(other.startBlockedNote?.contains("Cardio") ?? false)
    }

    func testDeletingAProjectSaysWhatIsLostAndWhatIsNot() {
        let empty = AuditPresentation.deleteProjectPrompt(sessionCount: 0)
        let recorded = AuditPresentation.deleteProjectPrompt(sessionCount: 2)

        XCTAssertNotEqual(empty, recorded)
        // Sin sesiones no hay evidencia que perder, y advertirlo sería una advertencia sin objeto.
        XCTAssertFalse(empty.contains("evidence"))
        // Con ellas: las conexiones se quedan, pero dejan de estar exentas de los topes.
        XCTAssertTrue(recorded.contains("stay in your history"))
        XCTAssertTrue(recorded.contains("storage limits"))
    }

    // MARK: - Una sesión

    func testPinningIsReadableOnlyWithBothConditionsAndEachGapHasItsOwnReason() {
        XCTAssertEqual(
            PinningEvidence.reading(InspectionConditions(inspectionEnabled: true, caTrusted: true)), .readable
        )
        XCTAssertEqual(
            PinningEvidence.reading(InspectionConditions(inspectionEnabled: false, caTrusted: true)), .inspectionOff
        )
        XCTAssertEqual(
            PinningEvidence.reading(InspectionConditions(inspectionEnabled: true, caTrusted: false)),
            .certificateUntrusted
        )
        // Con las dos apagadas manda la inspección: sin ella ni siquiera se ofrece el certificado.
        XCTAssertEqual(
            PinningEvidence.reading(InspectionConditions(inspectionEnabled: false, caTrusted: false)), .inspectionOff
        )

        // La misma regla que el modelo, dicha una sola vez allí.
        for enabled in [true, false] {
            for trusted in [true, false] {
                let conditions = InspectionConditions(inspectionEnabled: enabled, caTrusted: trusted)
                XCTAssertEqual(
                    PinningEvidence.reading(conditions) == .readable, conditions.supportsPinningEvidence
                )
            }
        }
    }

    /// Un requisito sin observación se informa como **no evaluado**, nunca como superado.
    func testASessionThatCannotAssessPinningNeverSaysItPassed() {
        for evidence in [PinningEvidence.inspectionOff, .certificateUntrusted] {
            for display in [AuditPresentation.pinning(evidence), AuditPresentation.pinningForecast(evidence)] {
                XCTAssertEqual(display.role, .warning)
                let lowered = display.headline.lowercased()
                XCTAssertTrue(lowered.contains("assessed"))
                XCTAssertFalse(lowered.contains("pass"))
                XCTAssertFalse(lowered.contains("fail"))
            }
        }
        // Las dos causas tienen salidas distintas, así que no pueden compartir explicación.
        XCTAssertNotEqual(
            AuditPresentation.pinning(.inspectionOff).detail,
            AuditPresentation.pinning(.certificateUntrusted).detail
        )
        XCTAssertEqual(AuditPresentation.pinning(.readable).role, .accent)
        // Leer el pinning no es saltárselo (ADR 0003), y la pantalla lo dice.
        XCTAssertTrue(AuditPresentation.pinning(.readable).detail.contains("Nothing was bypassed"))
    }

    /// Antes de grabar se habla de lo que va a pasar; después, de lo que pasó.
    func testTheFormSpeaksAboutTheSessionAboutToStartAndNotAPastOne() {
        for evidence in [PinningEvidence.readable, .inspectionOff, .certificateUntrusted] {
            let before = AuditPresentation.pinningForecast(evidence)
            let after = AuditPresentation.pinning(evidence)
            XCTAssertNotEqual(before.detail, after.detail)
            XCTAssertFalse(before.detail.contains(" was "), "el formulario no habla en pasado: \(before.detail)")
            XCTAssertEqual(before.role, after.role)
        }
    }

    func testARecordingSessionSaysEverythingIsTaggedAndAnEndedOneThatItIsKept() {
        let activity = AuditSessionActivity(markers: [], flowCount: 0)

        let open = AuditPresentation.session(session(1, ended: false), activity: activity)
        XCTAssertTrue(open.isRecording)
        XCTAssertEqual(open.status, "Recording")
        XCTAssertTrue(open.statusDetail.contains("whichever app"))
        XCTAssertEqual(open.facts.map(\.label), ["Started"], "una sesión abierta no tiene final que enseñar")
        XCTAssertEqual(open.connections, "0 connections")

        let ended = AuditPresentation.session(session(1), activity: AuditSessionActivity(markers: [], flowCount: 1))
        XCTAssertFalse(ended.isRecording)
        XCTAssertEqual(ended.status, "Ended")
        XCTAssertTrue(ended.statusDetail.contains("until you delete this session"))
        XCTAssertEqual(ended.facts.map(\.label), ["Started", "Ended"])
        XCTAssertEqual(ended.connections, "1 connection")
    }

    func testTheSessionShowsWhereItWasRecordedAndItsMarkersAsTheyHappened() {
        let markers = [
            SessionMarker(id: 1, sessionID: 1, date: start.addingTimeInterval(10), kind: .consentGiven),
            SessionMarker(id: 2, sessionID: 1, date: start.addingTimeInterval(20), kind: .custom("First sync")),
        ]
        let display = AuditPresentation.session(
            session(1, notes: "  Fresh install.  "),
            activity: AuditSessionActivity(markers: markers, flowCount: 1_234)
        )

        XCTAssertEqual(display.environment.map(\.value), [.text("iPhone18,3"), .text("26.5"), .text("1.0.0 (1)")])
        // El marcador libre sale con las palabras de quien lo escribió.
        XCTAssertEqual(display.markers.map(\.title), ["Consent given", "First sync"])
        XCTAssertEqual(display.markers.map(\.date), markers.map(\.date))
        XCTAssertEqual(display.connections, "1,234 connections")
        XCTAssertEqual(display.notes, "Fresh install.")

        // Unas notas en blanco no son una sección vacía: no hay sección.
        XCTAssertNil(AuditPresentation.session(session(1, notes: "  \n"), activity: AuditSessionActivity(markers: [], flowCount: 0)).notes)
    }

    func testTheFixedMarkersAreOfferedInTheOrderTheyUsuallyHappen() {
        XCTAssertEqual(AuditPresentation.markerChoices.map(\.kind), [.consentGiven, .loggedIn, .loggedOut])
        XCTAssertEqual(Set(AuditPresentation.markerChoices.map(\.title)).count, 3)
    }

    func testAClosedSessionExplainsWhyItTakesNoMoreMarkers() {
        XCTAssertNotEqual(
            AuditPresentation.markersFooter(isRecording: true),
            AuditPresentation.markersFooter(isRecording: false)
        )
        XCTAssertTrue(AuditPresentation.markersFooter(isRecording: false).contains("only be added while"))
    }

    // MARK: - Avisos

    func testARuleTheScreenCanFixHasItsOwnSentenceAndTheRestTravelWithADiagnostic() {
        let open = AuditPresentation.failed(.rule(.sessionAlreadyOpen(4)))
        XCTAssertTrue(open.message.contains("still recording"))
        XCTAssertNil(open.diagnostic, "lo que tiene salida desde la pantalla no necesita detalle técnico")

        let gone = AuditPresentation.failed(.rule(.sessionNotFound(4)))
        XCTAssertEqual(gone.message, AuditPresentation.failed(.rule(.projectNotFound(9))).message)

        let history = AuditPresentation.failed(.history(.queryFailed("database is locked")))
        XCTAssertEqual(history.diagnostic, "database is locked")
        XCTAssertEqual(history.role, .warning)

        XCTAssertEqual(
            AuditPresentation.refreshFailed(.history(.corruptData("bad row"))).diagnostic, "bad row"
        )
    }

    func testAStoreErrorIsToldApartFromAHistoryThatDidNotAnswer() {
        XCTAssertEqual(AuditLibraryError.classifying(AuditStoreError.emptyMarkerLabel), .rule(.emptyMarkerLabel))
        XCTAssertEqual(
            AuditLibraryError.classifying(FlowStore.StoreError.corruptRow("x")), .history(.corruptData("x"))
        )
        // Lo que ya viene clasificado se deja pasar.
        let classified = AuditLibraryError.rule(.sessionAlreadyOpen(1))
        XCTAssertEqual(AuditLibraryError.classifying(classified), classified)
    }
}
