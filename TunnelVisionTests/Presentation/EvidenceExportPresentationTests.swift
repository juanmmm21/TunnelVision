import Foundation
import XCTest
import Shared

/// Tests de lo que la hoja del paquete de evidencia decide sin pintar nada: qué se dice de una
/// captura a la que le faltan paquetes, a la que no le falta ninguno y de una vacía, qué lleva el
/// resumen, y en qué frase acaba cada motivo por el que no hay paquete.
final class EvidenceExportPresentationTests: XCTestCase {

    private func document(
        written: Int = 0,
        lost: [EvidencePacketLoss: Int] = [:],
        beforeStart: Int = 0,
        afterEnd: Int = 0
    ) -> EvidenceCaptureDocument {
        EvidenceCaptureDocument(
            sessionID: 1,
            snaplen: 262_144,
            flows: [.init(id: 7, packets: EvidencePacketTally(written: written, lost: lost))],
            sourceFiles: [],
            writtenOutsideSession: .init(beforeStart: beforeStart, afterEnd: afterEnd)
        )
    }

    private func result(
        capture: EvidenceCaptureDocument? = nil,
        byteCount: UInt64 = 482_000,
        fileNames: [String] = [
            "capture.json", "capture.pcapng", "findings.json", "flows.csv", "flows.json",
            "manifest.json", "report.pdf", "session.json",
        ],
        flowCount: Int = 1_250,
        findingCount: Int = 4
    ) -> EvidenceExportResult {
        EvidenceExportResult(
            url: URL(fileURLWithPath: "/tmp/EvidenceExports/tunnelvision-evidence-session-1-20261009-203000.zip"),
            byteCount: byteCount,
            fileNames: fileNames,
            flowCount: flowCount,
            findingCount: findingCount,
            capture: capture ?? document(written: 10)
        )
    }

    // MARK: - Qué lleva la captura

    func testASessionWithNoPacketsIsNotACompleteCapture() {
        XCTAssertEqual(EvidenceCaptureStanding(EvidencePacketTally()), .nothingRecorded)
    }

    func testACaptureWithEveryPacketIsComplete() {
        XCTAssertEqual(EvidenceCaptureStanding(EvidencePacketTally(written: 42)), .complete(packets: 42))
    }

    func testAnIncompleteCaptureListsOnlyTheReasonsThatHavePackets() {
        let standing = EvidenceCaptureStanding(
            EvidencePacketTally(written: 5, lost: [.recordUnreadable: 2, .notCaptured: 3])
        )

        XCTAssertEqual(
            standing,
            .incomplete(
                written: 5,
                recorded: 10,
                missing: [
                    EvidenceMissingPackets(reason: .notCaptured, count: 3),
                    EvidenceMissingPackets(reason: .recordUnreadable, count: 2),
                ]
            )
        )
    }

    func testACaptureWithNothingWrittenIsIncompleteAndNotEmpty() {
        let standing = EvidenceCaptureStanding(EvidencePacketTally(lost: [.captureFileMissing: 8]))

        XCTAssertEqual(
            standing,
            .incomplete(
                written: 0,
                recorded: 8,
                missing: [EvidenceMissingPackets(reason: .captureFileMissing, count: 8)]
            )
        )
    }

    // MARK: - Cómo se dice

    func testACompleteCaptureSaysSoInOneSentenceAndShowsNoZeroes() {
        let display = AuditPresentation.evidenceCapture(document(written: 1_234))

        XCTAssertEqual(display.headline, "All 1,234 recorded packets are in the capture.")
        XCTAssertEqual(display.role, .neutral)
        XCTAssertEqual(display.details, [])
    }

    func testOnePacketIsWordedInTheSingular() {
        XCTAssertEqual(
            AuditPresentation.evidenceCapture(document(written: 1)).headline,
            "The 1 recorded packet is in the capture."
        )
        XCTAssertEqual(
            AuditPresentation.evidenceCapture(document(lost: [.notCaptured: 1])).headline,
            "The 1 recorded packet is not in the capture."
        )
    }

    func testAnIncompleteCaptureWarnsAndGivesOneSentencePerReason() {
        let display = AuditPresentation.evidenceCapture(
            document(written: 1_100, lost: [.notCaptured: 100, .captureFileMissing: 33, .recordUnreadable: 1])
        )

        XCTAssertEqual(display.headline, "1,100 of 1,234 recorded packets are in the capture.")
        XCTAssertEqual(display.role, .warning)
        XCTAssertEqual(
            display.details,
            [
                "100 packets were never written to a capture file.",
                "33 packets were in capture files that are no longer on this device.",
                "1 packet could not be read back from its capture file.",
            ]
        )
    }

    func testEachReasonHasItsSingularAndItsPlural() {
        func details(_ reason: EvidencePacketLoss, _ count: Int) -> [String] {
            AuditPresentation.evidenceCapture(document(written: 5, lost: [reason: count])).details
        }

        XCTAssertEqual(details(.notCaptured, 1), ["1 packet was never written to a capture file."])
        XCTAssertEqual(
            details(.captureFileMissing, 1),
            ["1 packet was in a capture file that is no longer on this device."]
        )
        XCTAssertEqual(
            details(.recordUnreadable, 2),
            ["2 packets could not be read back from their capture files."]
        )
    }

    func testAnEmptyCaptureIsSaidAsSuchAndIsNotAWarning() {
        let display = AuditPresentation.evidenceCapture(document())

        XCTAssertEqual(display.headline, "This session recorded no packets, so the capture is empty.")
        XCTAssertEqual(display.role, .neutral)
        XCTAssertEqual(display.details, [])
    }

    func testPacketsFromOutsideTheSessionAreCountedTogetherAndExplained() {
        let display = AuditPresentation.evidenceCapture(document(written: 50, beforeStart: 4, afterEnd: 3))

        XCTAssertEqual(display.role, .neutral, "no es un fallo: la captura está entera")
        XCTAssertEqual(display.details.count, 1)
        XCTAssertTrue(display.details[0].hasPrefix("7 packets in the capture are from before the session"))
        XCTAssertTrue(display.details[0].contains("also active during the session"))
    }

    func testTheOutsideNoteComesAfterWhatIsMissing() {
        let display = AuditPresentation.evidenceCapture(
            document(written: 50, lost: [.notCaptured: 2], beforeStart: 1)
        )

        XCTAssertEqual(display.details.count, 2)
        XCTAssertTrue(display.details[0].hasPrefix("2 packets were never written"))
        XCTAssertTrue(display.details[1].hasPrefix("1 packet in the capture is from before"))
    }

    // MARK: - El resumen

    func testTheSummarySaysWhatTheArchiveIsAndWhatItHolds() {
        let summary = AuditPresentation.evidenceExportPrepared(result())

        XCTAssertEqual(summary.fileName, "tunnelvision-evidence-session-1-20261009-203000.zip")
        XCTAssertEqual(summary.title, "Evidence bundle ready to share")
        XCTAssertEqual(summary.detail, "482 KB · ZIP · 8 files")
        XCTAssertEqual(summary.facts.map(\.label), ["Connections", "Findings"])
        XCTAssertEqual(summary.facts.map(\.value), [.text("1,250"), .text("4")])
        XCTAssertEqual(summary.capture, AuditPresentation.evidenceCapture(document(written: 10)))
    }

    /// Lo que el paquete dice de sí mismo no se redacta otra vez en la pantalla: una segunda frase
    /// acabaría diciendo otra cosa que el fichero.
    func testTheSummaryQuotesTheBundleInsteadOfRewordingIt() {
        let summary = AuditPresentation.evidenceExportPrepared(result())

        XCTAssertEqual(summary.contents, EvidenceSessionDocument.contentsNote)
        XCTAssertTrue(summary.contents.contains("Decrypted content is not part of this bundle"))
        XCTAssertEqual(summary.findingsNote, EvidenceWording.verdictsNote)
    }

    func testTheCautionSaysWhatTravelledInTheClearIsReadable() {
        XCTAssertTrue(AuditPresentation.evidenceCleartextCaution.contains("sent unencrypted can be read"))
    }

    func testNothingOnTheSheetSaysARequirementIsPassed() {
        let summary = AuditPresentation.evidenceExportPrepared(
            result(capture: document(written: 3, lost: [.notCaptured: 1], afterEnd: 1))
        )
        let everything = [
            summary.title, summary.detail, summary.contents, summary.findingsNote,
            summary.capture.headline, AuditPresentation.evidenceCleartextCaution,
            AuditPresentation.exportEvidenceFooter,
        ] + summary.capture.details + summary.facts.map(\.label)

        for sentence in everything {
            let lowered = sentence.lowercased()
            XCTAssertFalse(lowered.contains("passed"), sentence)
            XCTAssertFalse(lowered.contains("compliant"), sentence)
        }
    }

    // MARK: - Una exportación que no salió

    private static let failures: [EvidenceExportError] = [
        .sessionNotFound,
        .sessionStillOpen,
        .catalogueNotBundled(identifier: "tr-03161-1_9.9"),
        .catalogueUnusable(identifier: "tr-03161-1_3.0"),
        .historyUnreadable(.queryFailed("database is locked")),
        .historyChangedWhileExporting,
        .captureDirectoryUnavailable("containerUnavailable"),
        .writeFailed("No space left on device"),
    ]

    func testEveryFailureHasASentenceOfItsOwn() {
        let messages = Self.failures.map { AuditPresentation.evidenceExportFailed($0).message }

        XCTAssertEqual(Set(messages).count, Self.failures.count, "dos fallos comparten frase")
        for notice in Self.failures.map(AuditPresentation.evidenceExportFailed) {
            XCTAssertFalse(notice.message.isEmpty)
            XCTAssertEqual(notice.role, .warning)
        }
    }

    func testACatalogueThatIsNotBundledIsNamedAndNotReplaced() {
        let notice = AuditPresentation.evidenceExportFailed(.catalogueNotBundled(identifier: "tr-03161-1_9.9"))

        XCTAssertTrue(notice.message.contains("“tr-03161-1_9.9”"))
        XCTAssertTrue(notice.message.contains("never written against a different catalogue"))
    }

    func testAHistoryThatChangedSaysToExportAgain() {
        let notice = AuditPresentation.evidenceExportFailed(.historyChangedWhileExporting)

        XCTAssertTrue(notice.message.contains("Export it again"))
    }

    func testAFailedWriteSaysNothingWasLeftAndCarriesItsDetailApart() {
        let notice = AuditPresentation.evidenceExportFailed(.writeFailed("No space left on device"))

        XCTAssertTrue(notice.message.contains("nothing was left behind"))
        XCTAssertFalse(notice.message.contains("No space left on device"))
        XCTAssertEqual(notice.diagnostic, "No space left on device")
    }

    func testTheTechnicalDetailTravelsAsADiagnosticOnlyWhereThereIsOne() {
        let diagnostics = Self.failures.map { AuditPresentation.evidenceExportFailed($0).diagnostic }

        XCTAssertEqual(
            diagnostics,
            [nil, nil, nil, nil, "database is locked", nil, "containerUnavailable", "No space left on device"]
        )
    }
}
