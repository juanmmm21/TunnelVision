import Foundation
import Shared

/// Qué enseña la hoja del paquete de evidencia ya escrito, **antes** de compartirlo
/// (`docs/ux/audit.md` § *Exporting a session*).
///
/// Lo que hay que decidir aquí es qué se dice de la captura. Abriendo el zip un evaluador ve los
/// paquetes que están; los que faltan no se ven, y un flujo con pocos paquetes se lee como un flujo
/// con poco tráfico. `capture.json` lo cuenta, y esta hoja lo dice con palabras en el único
/// momento en que sirve: antes de que el paquete salga del dispositivo.

/// Lo que la hoja dice de la captura: un titular con su símbolo y su color, y debajo una frase por
/// cada cosa que un lector del zip no podría ver.
public struct EvidenceCaptureDisplay: Sendable, Equatable {
    public let headline: String
    public let systemImage: String
    public let role: StatusRole

    /// Una frase por motivo con paquetes que faltan y, si los hay, la de los paquetes de fuera de
    /// la ventana de la sesión. Vacío cuando no hay nada que añadir al titular.
    public let details: [String]

    public init(headline: String, systemImage: String, role: StatusRole, details: [String]) {
        self.headline = headline
        self.systemImage = systemImage
        self.role = role
        self.details = details
    }
}

/// El paquete ya escrito, tal y como se le enseña al usuario antes de compartirlo.
public struct EvidenceExportSummary: Sendable, Equatable, Identifiable {

    /// El zip es su propia identidad: es lo que la hoja del sistema va a compartir.
    public var id: URL { url }

    public let url: URL
    public let fileName: String
    public let title: String

    /// Cuánto ocupa, en qué formato va y cuántos ficheros lleva dentro.
    public let detail: String

    /// Lo que el paquete dice de sí mismo en `session.json`, con sus palabras.
    public let contents: String

    /// Conexiones y hallazgos.
    public let facts: [AuditFact]

    /// Lo que `findings.json` dice de sus veredictos, con sus palabras.
    public let findingsNote: String

    public let capture: EvidenceCaptureDisplay

    public init(
        url: URL,
        fileName: String,
        title: String,
        detail: String,
        contents: String,
        facts: [AuditFact],
        findingsNote: String,
        capture: EvidenceCaptureDisplay
    ) {
        self.url = url
        self.fileName = fileName
        self.title = title
        self.detail = detail
        self.contents = contents
        self.facts = facts
        self.findingsNote = findingsNote
        self.capture = capture
    }
}

extension AuditPresentation {

    // MARK: - Exportar una sesión

    public static var exportEvidenceSectionTitle: String {
        String(
            localized: "audit.session.evidence.section",
            defaultValue: "Evidence bundle",
            comment: "Heading over the row that exports a closed audit session as an evidence bundle."
        )
    }

    public static var exportEvidenceActionTitle: String {
        String(
            localized: "audit.session.evidence.action",
            defaultValue: "Export evidence",
            comment: """
                Row that writes the evidence bundle of a closed audit session. It does not share \
                anything yet: a sheet first shows what the bundle holds.
                """
        )
    }

    public static var exportEvidenceFooter: String {
        String(
            localized: "audit.session.evidence.footer",
            defaultValue: """
                Writes this session's connections, findings and capture into one archive, with a \
                checksum of every file. You see what it holds before anything is shared.
                """,
            comment: """
                Note under the row that exports an audit session. It must say that nothing leaves \
                the device by tapping the row: sharing is a second, separate step.
                """
        )
    }

    public static var evidenceSheetTitle: String {
        String(
            localized: "audit.evidence.sheet.title",
            defaultValue: "Evidence bundle",
            comment: "Title of the sheet that shows a written evidence bundle before it is shared."
        )
    }

    public static var evidenceShareTitle: String {
        String(
            localized: "audit.evidence.share",
            defaultValue: "Share",
            comment: """
                Button that hands the evidence bundle to the system share sheet. It must read as \
                'send this somewhere', not as 'save': this is the moment it leaves the device.
                """
        )
    }

    public static var evidenceCaptureSectionTitle: String {
        String(
            localized: "audit.evidence.capture.section",
            defaultValue: "Capture",
            comment: """
                Heading, on the evidence bundle sheet, over what the bundle's packet capture holds \
                and what it lacks.
                """
        )
    }

    /// Va con la captura **siempre**, falten paquetes o no: es lo que quien comparte tiene que
    /// saber antes de mandarla, y «sin contenido descifrado» se lee solo como «sin contenido».
    public static var evidenceCleartextCaution: String {
        String(
            localized: "audit.evidence.capture.cleartext",
            defaultValue: """
                The capture holds each packet as it crossed the tunnel. Anything that was sent \
                unencrypted can be read in it.
                """,
            comment: """
                Caution on the evidence bundle sheet, shown before sharing. The bundle carries no \
                decrypted content, but its packet capture does carry, readable, whatever an app \
                sent without encryption — from a medical app that can be health data.
                """
        )
    }

    /// Qué se ha escrito, antes de compartirlo.
    ///
    /// Lo que el paquete ya dice de sí mismo —qué lleva y qué no, y qué es un veredicto— se enseña
    /// **con sus palabras** (`EvidenceSessionDocument.contentsNote`, `EvidenceWording`): son
    /// límites que costó decidir, y una segunda redacción en la pantalla acabaría diciendo otra
    /// cosa que el fichero que el usuario está a punto de mandar.
    public static func evidenceExportPrepared(_ result: EvidenceExportResult) -> EvidenceExportSummary {
        EvidenceExportSummary(
            url: result.url,
            fileName: result.url.lastPathComponent,
            title: String(
                localized: "audit.evidence.summary.title",
                defaultValue: "Evidence bundle ready to share",
                comment: "Headline of the sheet that shows a written evidence bundle."
            ),
            detail: evidenceDetail(byteCount: result.byteCount, fileCount: result.fileNames.count),
            contents: EvidenceSessionDocument.contentsNote,
            facts: [
                AuditFact(
                    label: String(
                        localized: "audit.evidence.connections.label",
                        defaultValue: "Connections",
                        comment: "Label of the number of connections an evidence bundle lists."
                    ),
                    value: .text(DisplayFormat.count(UInt64(max(result.flowCount, 0))))
                ),
                AuditFact(
                    label: String(
                        localized: "audit.evidence.findings.label",
                        defaultValue: "Findings",
                        comment: """
                            Label of the number of findings an evidence bundle holds. A finding is \
                            an observation about the recorded traffic, not a failed test.
                            """
                    ),
                    value: .text(DisplayFormat.count(UInt64(max(result.findingCount, 0))))
                ),
            ],
            findingsNote: EvidenceWording.verdictsNote,
            capture: evidenceCapture(result.capture)
        )
    }

    /// Lo que la captura lleva y lo que no, en frases.
    public static func evidenceCapture(_ document: EvidenceCaptureDocument) -> EvidenceCaptureDisplay {
        let outside = document.writtenOutsideSession.beforeStart + document.writtenOutsideSession.afterEnd
        let outsideNote = outside > 0 ? [outsideSessionNote(outside)] : []

        switch EvidenceCaptureStanding(document.packets) {
        case .nothingRecorded:
            return EvidenceCaptureDisplay(
                headline: String(
                    localized: "audit.evidence.capture.empty",
                    defaultValue: "This session recorded no packets, so the capture is empty.",
                    comment: """
                        Headline about the capture of an evidence bundle when the history holds no \
                        packet of the session. The capture file exists and opens; it has no packets.
                        """
                ),
                systemImage: "tray",
                role: .neutral,
                details: outsideNote
            )

        case .complete(let packets):
            return EvidenceCaptureDisplay(
                headline: completeHeadline(packets),
                systemImage: "checkmark.circle",
                role: .neutral,
                details: outsideNote
            )

        case .incomplete(let written, let recorded, let missing):
            return EvidenceCaptureDisplay(
                headline: incompleteHeadline(written: written, recorded: recorded),
                systemImage: "exclamationmark.circle",
                role: .warning,
                details: missing.map(missingNote) + outsideNote
            )
        }
    }

    private static func evidenceDetail(byteCount: UInt64, fileCount: Int) -> String {
        guard fileCount != 1 else {
            return String(
                localized: "audit.evidence.summary.detail.one",
                defaultValue: "\(DisplayFormat.bytes(byteCount)) · ZIP · 1 file",
                comment: """
                    Secondary line of the evidence bundle sheet when the archive holds exactly one \
                    file. See the plural form in the sibling key.
                    """
            )
        }
        return String(
            localized: "audit.evidence.summary.detail.other",
            defaultValue: """
                \(DisplayFormat.bytes(byteCount)) · ZIP · \
                \(DisplayFormat.count(UInt64(max(fileCount, 0)))) files
                """,
            comment: """
                Secondary line of the evidence bundle sheet: how big the archive is, its format \
                and how many files it holds. 'ZIP' is a format name and stays as is. The order and \
                the separators are translatable.
                """
        )
    }

    private static func completeHeadline(_ packets: Int) -> String {
        guard packets != 1 else {
            return String(
                localized: "audit.evidence.capture.complete.one",
                defaultValue: "The 1 recorded packet is in the capture.",
                comment: """
                    Headline about the capture of an evidence bundle when the session recorded \
                    exactly one packet and it is in the capture. See the plural form in the \
                    sibling key.
                    """
            )
        }
        return String(
            localized: "audit.evidence.capture.complete.other",
            defaultValue: "All \(DisplayFormat.count(UInt64(max(packets, 0)))) recorded packets are in the capture.",
            comment: """
                Headline about the capture of an evidence bundle when every packet the history \
                holds for the session is in the capture with its bytes. The placeholder is how many.
                """
        )
    }

    private static func incompleteHeadline(written: Int, recorded: Int) -> String {
        guard recorded != 1 else {
            return String(
                localized: "audit.evidence.capture.incomplete.one",
                defaultValue: "The 1 recorded packet is not in the capture.",
                comment: """
                    Headline about the capture of an evidence bundle when the session recorded \
                    exactly one packet and its bytes are not in the capture. See the plural form \
                    in the sibling key.
                    """
            )
        }
        return String(
            localized: "audit.evidence.capture.incomplete.other",
            defaultValue: """
                \(DisplayFormat.count(UInt64(max(written, 0)))) of \
                \(DisplayFormat.count(UInt64(max(recorded, 0)))) recorded packets are in the capture.
                """,
            comment: """
                Headline about the capture of an evidence bundle when some packets the history \
                holds are not in it. The first placeholder is how many are in the capture, the \
                second how many the session recorded.
                """
        )
    }

    /// Por qué faltan, con las mismas palabras con las que `capture.json` define cada motivo.
    private static func missingNote(_ missing: EvidenceMissingPackets) -> String {
        let count = DisplayFormat.count(UInt64(max(missing.count, 0)))
        switch (missing.reason, missing.count == 1) {
        case (.notCaptured, true):
            return String(
                localized: "audit.evidence.capture.notCaptured.one",
                defaultValue: "1 packet was never written to a capture file.",
                comment: """
                    Why one packet of an audit session is not in the bundle's capture: capturing \
                    was off, or its writer failed. See the plural form in the sibling key.
                    """
            )
        case (.notCaptured, false):
            return String(
                localized: "audit.evidence.capture.notCaptured.other",
                defaultValue: "\(count) packets were never written to a capture file.",
                comment: """
                    Why some packets of an audit session are not in the bundle's capture: \
                    capturing was off, or its writer failed. The placeholder is how many.
                    """
            )
        case (.captureFileMissing, true):
            return String(
                localized: "audit.evidence.capture.fileMissing.one",
                defaultValue: "1 packet was in a capture file that is no longer on this device.",
                comment: """
                    Why one packet of an audit session is not in the bundle's capture: the capture \
                    file that held it was deleted. See the plural form in the sibling key.
                    """
            )
        case (.captureFileMissing, false):
            return String(
                localized: "audit.evidence.capture.fileMissing.other",
                defaultValue: "\(count) packets were in capture files that are no longer on this device.",
                comment: """
                    Why some packets of an audit session are not in the bundle's capture: the \
                    capture files that held them were deleted. The placeholder is how many.
                    """
            )
        case (.recordUnreadable, true):
            return String(
                localized: "audit.evidence.capture.unreadable.one",
                defaultValue: "1 packet could not be read back from its capture file.",
                comment: """
                    Why one packet of an audit session is not in the bundle's capture: its capture \
                    file is there but the record could not be read. See the plural form in the \
                    sibling key.
                    """
            )
        case (.recordUnreadable, false):
            return String(
                localized: "audit.evidence.capture.unreadable.other",
                defaultValue: "\(count) packets could not be read back from their capture files.",
                comment: """
                    Why some packets of an audit session are not in the bundle's capture: their \
                    capture files are there but the records could not be read. The placeholder is \
                    how many.
                    """
            )
        }
    }

    /// Paquetes que sí están en la captura pero cuyo instante cae fuera de la sesión. No son un
    /// fallo, y por eso la frase dice por qué están: sin ella se leen como tráfico de más.
    private static func outsideSessionNote(_ count: Int) -> String {
        guard count != 1 else {
            return String(
                localized: "audit.evidence.capture.outside.one",
                defaultValue: """
                    1 packet in the capture is from before the session started or after it ended: \
                    it belongs to a connection that was also active during the session.
                    """,
                comment: """
                    Note on the evidence bundle sheet when one captured packet falls outside the \
                    session's time window. See the plural form in the sibling key.
                    """
            )
        }
        return String(
            localized: "audit.evidence.capture.outside.other",
            defaultValue: """
                \(DisplayFormat.count(UInt64(max(count, 0)))) packets in the capture are from \
                before the session started or after it ended: they belong to connections that \
                were also active during the session.
                """,
            comment: """
                Note on the evidence bundle sheet when captured packets fall outside the session's \
                time window. It is not an error: a connection belongs to the session when it \
                carried traffic while the session was open. The placeholder is how many packets.
                """
        )
    }

    // MARK: - Una exportación que no salió

    /// Por qué no hay paquete. Ninguno de estos fallos deja nada en disco, y las frases lo dicen
    /// donde podría dudarse.
    public static func evidenceExportFailed(_ error: EvidenceExportError) -> AuditNotice {
        switch error {
        case .sessionNotFound:
            return AuditNotice(
                message: String(
                    localized: "audit.evidence.failed.gone",
                    defaultValue: "This session no longer exists, so there is nothing to export.",
                    comment: """
                        Notice when exporting an audit session failed because the session, or its \
                        project, was deleted meanwhile.
                        """
                ),
                role: .warning
            )

        case .sessionStillOpen:
            return AuditNotice(
                message: String(
                    localized: "audit.evidence.failed.stillOpen",
                    defaultValue: "This session is still recording. End it before exporting its evidence.",
                    comment: """
                        Notice when exporting an audit session was refused because it is still \
                        open. Evidence is exported from a closed session only.
                        """
                ),
                role: .warning
            )

        case .catalogueNotBundled(let identifier):
            return AuditNotice(
                message: String(
                    localized: "audit.evidence.failed.catalogueNotBundled",
                    defaultValue: """
                        This project is assessed against the requirement catalogue \
                        “\(identifier)”, which this version of TunnelVision doesn't include. \
                        Nothing was exported: a bundle is never written against a different catalogue.
                        """,
                    comment: """
                        Notice when exporting an audit session was refused because the project \
                        names a requirement catalogue this build does not carry. The placeholder \
                        is the catalogue's identifier, shown as written. It must say that no other \
                        catalogue was used instead.
                        """
                ),
                role: .warning
            )

        case .catalogueUnusable(let identifier):
            return AuditNotice(
                message: String(
                    localized: "audit.evidence.failed.catalogueUnusable",
                    defaultValue: """
                        The requirement catalogue “\(identifier)” couldn't be read, so nothing \
                        was exported.
                        """,
                    comment: """
                        Notice when exporting an audit session failed because the bundled \
                        requirement catalogue could not be loaded. The placeholder is the \
                        catalogue's identifier, shown as written.
                        """
                ),
                role: .warning
            )

        case .historyUnreadable(let historyError):
            return AuditNotice(
                message: String(
                    localized: "audit.evidence.failed.history",
                    defaultValue: "Your history didn't answer, so nothing was exported.",
                    comment: """
                        Notice when exporting an audit session failed because the history database \
                        could not be read. The technical detail travels apart, as a diagnostic.
                        """
                ),
                diagnostic: evidenceDiagnostic(for: historyError),
                role: .warning
            )

        case .historyChangedWhileExporting:
            return AuditNotice(
                message: String(
                    localized: "audit.evidence.failed.changed",
                    defaultValue: """
                        The history changed while the bundle was being written, so it was \
                        discarded. Export it again.
                        """,
                    comment: """
                        Notice when exporting an audit session was stopped because the history \
                        changed between two reads. Repeating the export is the remedy, and the \
                        sentence must say so.
                        """
                ),
                role: .warning
            )

        case .captureDirectoryUnavailable(let detail):
            return AuditNotice(
                message: String(
                    localized: "audit.evidence.failed.captures",
                    defaultValue: "The captures on this device couldn't be reached, so nothing was exported.",
                    comment: """
                        Notice when exporting an audit session failed because the folder holding \
                        the device's capture files could not be resolved. The technical detail \
                        travels apart, as a diagnostic.
                        """
                ),
                diagnostic: detail,
                role: .warning
            )

        case .writeFailed(let detail):
            return AuditNotice(
                message: String(
                    localized: "audit.evidence.failed.write",
                    defaultValue: """
                        The bundle couldn't be written, and nothing was left behind. Writing it \
                        needs free space for up to twice the session's capture.
                        """,
                    comment: """
                        Notice when exporting an audit session failed while writing the bundle or \
                        its archive. It must say that no partial bundle remains, and names the one \
                        cause the user can act on: free storage. The technical detail travels \
                        apart, as a diagnostic.
                        """
                ),
                diagnostic: detail,
                role: .warning
            )
        }
    }

    private static func evidenceDiagnostic(for error: HistoryError) -> String {
        switch error {
        case .corruptData(let detail): detail
        case .queryFailed(let detail): detail
        }
    }
}
