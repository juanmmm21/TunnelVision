import Foundation

/// Las secciones del informe, en el orden en que van.
public enum EvidenceReportSectionKind: String, Sendable, Hashable, CaseIterable {
    case session
    case method
    case catalogue
    case requirements
    case findings
    case checks
    case tlsReadings
    case capture
}

/// Un dato con su rótulo.
public struct EvidenceReportFact: Sendable, Hashable {
    public let label: String
    public let value: String

    /// Si el dato siguiente lo matiza y un salto de página no puede separarlos: un veredicto al
    /// pie de una página, con su `toolCoverage` en la siguiente, se lee como el requisito entero.
    /// Lo dice el contenido y no el dibujo, que no sabe qué es un veredicto.
    public let staysWithNext: Bool

    public init(label: String, value: String, staysWithNext: Bool = false) {
        self.label = label
        self.value = value
        self.staysWithNext = staysWithNext
    }
}

/// Una tabla. Cada fila tiene tantas celdas como columnas.
public struct EvidenceReportTable: Sendable, Hashable {
    public let columns: [String]
    public let rows: [[String]]

    public init(columns: [String], rows: [[String]]) {
        self.columns = columns
        self.rows = rows
    }
}

/// Una pieza del informe. Quien lo dibuja no sabe nada de auditorías: recorre piezas.
public enum EvidenceReportBlock: Sendable, Hashable {
    case heading(String)
    /// Texto del propio informe.
    case paragraph(String)
    /// Texto que el paquete ya lleva en otro de sus documentos, citado tal cual.
    case note(String)
    case facts([EvidenceReportFact])
    case table(EvidenceReportTable)
}

public struct EvidenceReportSection: Sendable, Hashable {
    public let kind: EvidenceReportSectionKind
    public let title: String
    public let blocks: [EvidenceReportBlock]
}

/// Cuánto de una lista imprime el informe antes de remitir al documento que la lleva entera.
///
/// Son límites y no detalles del dibujo: una sesión de veinte mil flujos tiene un hallazgo que
/// los cita todos, y un informe de cuatrocientas páginas de identificadores no lo lee nadie.
/// Nada se pierde: `findings.json` y `flows.json` no recortan. No tiene valor por defecto.
public struct EvidenceReportLimits: Sendable, Hashable {

    /// Cuántos identificadores de flujo se imprimen por hallazgo.
    public let flowIDsPerFinding: Int

    /// Cuántas filas se imprimen en la tabla de lecturas de TLS.
    public let tlsReadingRows: Int

    /// `nil` si alguno no es positivo: un informe que no imprime ninguno diría «0 de N» de todo.
    public init?(flowIDsPerFinding: Int, tlsReadingRows: Int) {
        guard flowIDsPerFinding > 0, tlsReadingRows > 0 else { return nil }
        self.init(checkedFlowIDsPerFinding: flowIDsPerFinding, tlsReadingRows: tlsReadingRows)
    }

    private init(checkedFlowIDsPerFinding flowIDsPerFinding: Int, tlsReadingRows: Int) {
        self.flowIDsPerFinding = flowIDsPerFinding
        self.tlsReadingRows = tlsReadingRows
    }

    /// Los del `report.pdf` que va en el paquete (`docs/spec/audit.md` § *Drawing the report*).
    public static let bundled = EvidenceReportLimits(checkedFlowIDsPerFinding: 12, tlsReadingRows: 150)
}

public enum EvidenceReportError: Error, Sendable, Hashable {
    /// El `capture.json` que se dio es de otra sesión: el informe contaría paquetes ajenos.
    case captureOfAnotherSession(captureSessionID: Int64, sessionID: Int64)
}

/// Lo que dice `report.pdf`, antes de dibujarlo: qué secciones, qué filas y qué frase en cada
/// sitio (`docs/spec/audit.md` § *The report*).
///
/// Es puro y no clasifica: lee los documentos de un `EvidenceBundle` ya armado y su
/// `capture.json`, así que lo que imprime no puede decir otra cosa que los ficheros que tiene al
/// lado. Lo que el paquete ya redacta se cita; las frases que son solo del informe salen de
/// `EvidenceWording`, y aquí quedan los rótulos. Instantes en UTC y números sin formato regional:
/// la misma sesión da el mismo informe en cualquier dispositivo.
public struct EvidenceReport: Sendable, Hashable {

    public let title: String

    /// Qué sesión es, en una línea: proyecto, release (o que es una baseline) e identificador.
    public let subtitle: String

    /// Siempre todas, en el orden de `EvidenceReportSectionKind`.
    public let sections: [EvidenceReportSection]

    /// Un informe con las piezas que se le den. Solo para probar a quien lo dibuja, que recorre
    /// piezas y no sabe de sesiones: el del paquete sale siempre del otro `init`.
    init(title: String, subtitle: String, sections: [EvidenceReportSection]) {
        self.title = title
        self.subtitle = subtitle
        self.sections = sections
    }

    /// - Parameter capture: el `capture.json` de este mismo paquete, tal como se escribió.
    public init(
        bundle: EvidenceBundle,
        capture: EvidenceCaptureDocument,
        limits: EvidenceReportLimits
    ) throws {
        let sessionID = bundle.session.session.id
        guard capture.sessionID == sessionID else {
            throw EvidenceReportError.captureOfAnotherSession(
                captureSessionID: capture.sessionID,
                sessionID: sessionID
            )
        }
        self.title = EvidenceWording.reportTitle
        self.subtitle = Self.sessionLine(of: bundle.session)
        self.sections = EvidenceReportSectionKind.allCases.map { kind in
            let blocks: [EvidenceReportBlock]
            switch kind {
            case .session: blocks = Self.session(bundle.session)
            case .method: blocks = Self.method(bundle)
            case .catalogue: blocks = Self.catalogue(bundle.findings.catalogue)
            case .requirements: blocks = Self.requirements(bundle)
            case .findings: blocks = Self.findings(bundle.findings.findings, limits: limits)
            case .checks: blocks = Self.checks(bundle.assessment.findings)
            case .tlsReadings: blocks = Self.tlsReadings(bundle.flows.flows, limits: limits)
            case .capture: blocks = Self.capture(capture)
            }
            return EvidenceReportSection(
                kind: kind,
                title: EvidenceWording.reportSectionTitle(kind),
                blocks: blocks
            )
        }
    }

    // MARK: - La sesión

    private static func sessionLine(of document: EvidenceSessionDocument) -> String {
        let release = document.session.release.map(Self.text) ?? document.session.kind
        return "\(document.project.name) · \(release) · session \(document.session.id)"
    }

    private static func text(_ release: EvidenceSessionDocument.Release) -> String {
        "\(release.version) (\(release.build))"
    }

    private static func session(_ document: EvidenceSessionDocument) -> [EvidenceReportBlock] {
        let session = document.session
        var facts = [EvidenceReportFact(label: "Project", value: document.project.name)]
        if let bundleIdentifier = document.project.bundleIdentifier {
            facts.append(EvidenceReportFact(label: "App bundle identifier", value: bundleIdentifier))
        }
        facts.append(EvidenceReportFact(label: "Session", value: String(session.id)))
        facts.append(EvidenceReportFact(label: "Kind", value: session.kind))
        if let release = session.release {
            facts.append(EvidenceReportFact(label: "Release", value: text(release)))
        }
        facts += [
            EvidenceReportFact(label: "Started", value: EvidenceBundleFormat.timestamp(session.startedAt)),
            EvidenceReportFact(label: "Ended", value: EvidenceBundleFormat.timestamp(session.endedAt)),
            EvidenceReportFact(label: "Device", value: session.environment.deviceModel),
            EvidenceReportFact(label: "iOS", value: session.environment.osVersion),
            EvidenceReportFact(label: "Recorded with TunnelVision", value: session.environment.toolVersion),
            EvidenceReportFact(label: "Exported with TunnelVision", value: document.exportedWith),
            EvidenceReportFact(label: "Exported", value: EvidenceBundleFormat.timestamp(document.exportedAt)),
            EvidenceReportFact(label: "TLS inspection", value: session.inspection.inspectionEnabled ? "on" : "off"),
            EvidenceReportFact(label: "Local CA trusted", value: session.inspection.caTrusted ? "yes" : "no"),
        ]
        if !session.notes.isEmpty {
            facts.append(EvidenceReportFact(label: "Notes", value: session.notes))
        }

        var blocks: [EvidenceReportBlock] = [
            .facts(facts),
            .paragraph(EvidenceWording.reportPinningConditions(
                supportsPinningEvidence: session.inspection.supportsPinningEvidence
            )),
            .heading("Markers"),
        ]
        if document.markers.isEmpty {
            blocks.append(.paragraph(EvidenceWording.reportNoMarkers))
        } else {
            blocks.append(.table(EvidenceReportTable(
                columns: ["Instant (UTC)", "Marker", "Label"],
                rows: document.markers.map {
                    [EvidenceBundleFormat.timestamp($0.date), $0.kind, $0.label ?? ""]
                }
            )))
        }
        blocks.append(.heading("Allowlist"))
        if document.project.allowlist.isEmpty {
            blocks.append(.paragraph(EvidenceWording.reportNoAllowlist))
        } else {
            blocks.append(.table(EvidenceReportTable(
                columns: ["Pattern", "Note"],
                rows: document.project.allowlist.map { [$0.pattern, $0.note ?? ""] }
            )))
        }
        return blocks
    }

    // MARK: - Cómo se lee

    private static func method(_ bundle: EvidenceBundle) -> [EvidenceReportBlock] {
        [
            .note(bundle.session.attribution),
            .note(bundle.findings.verdicts),
            .note(bundle.session.contents),
            .note(bundle.flows.contents),
        ]
    }

    // MARK: - El catálogo

    private static func catalogue(_ catalogue: EvidenceCatalogue) -> [EvidenceReportBlock] {
        [
            .facts([EvidenceReportFact(label: "Catalogue", value: catalogue.identifier)]
                + source(catalogue.source)),
            .heading("Minimum TLS version"),
            .facts([EvidenceReportFact(
                label: "Lowest version accepted",
                value: EvidenceWording.reportName(of: catalogue.minimumTLSVersion)
            )] + source(catalogue.tlsSource)),
        ]
    }

    private static func source(_ source: EvidenceCatalogue.Source) -> [EvidenceReportFact] {
        [
            EvidenceReportFact(label: "Document", value: source.document),
            EvidenceReportFact(label: "Title", value: source.title),
            EvidenceReportFact(label: "Version", value: "\(source.version) (\(source.date))"),
            EvidenceReportFact(label: "SHA-256 of the PDF it was checked against", value: source.sha256),
        ]
    }

    // MARK: - Los requisitos

    private static func requirements(_ bundle: EvidenceBundle) -> [EvidenceReportBlock] {
        let written = bundle.findings.requirements
        var blocks: [EvidenceReportBlock] = [
            .table(EvidenceReportTable(
                columns: ["Requirement", "Verdict"],
                rows: written.map { [$0.id, $0.verdictStatement] }
            )),
        ]
        // Los dos salen del mismo `SessionAssessment` y en su orden: el escrito da las frases y
        // los identificadores de hallazgo, el evaluado la comprobación con su tipo.
        for (requirement, assessed) in zip(written, bundle.assessment.requirements) {
            blocks.append(.heading("\(requirement.id) — \(requirement.title)"))
            blocks.append(.facts(facts(of: requirement, coverage: assessed.coverage)))
        }
        return blocks
    }

    private static func facts(
        of requirement: EvidenceRequirement,
        coverage: CheckCoverageSummary?
    ) -> [EvidenceReportFact] {
        var facts = [
            EvidenceReportFact(
                label: "Test aspect",
                value: "\(requirement.aspect.number) \(requirement.aspect.name)"
            ),
            EvidenceReportFact(label: "Test depth", value: requirement.testDepth),
            EvidenceReportFact(
                label: "Verdict",
                value: requirement.verdictStatement,
                staysWithNext: requirement.toolCoverage != nil
            ),
        ]
        // Pegado al veredicto: sin él, «observado sin contradicción» se lee como el requisito entero.
        if let toolCoverage = requirement.toolCoverage {
            facts.append(EvidenceReportFact(label: "Tool coverage (toolCoverage)", value: toolCoverage))
        }
        if !requirement.contraryFindingIDs.isEmpty {
            facts.append(EvidenceReportFact(
                label: "Findings against it",
                value: requirement.contraryFindingIDs.joined(separator: ", ")
            ))
        }
        if !requirement.supportingFindingIDs.isEmpty {
            facts.append(EvidenceReportFact(
                label: "Findings in its support",
                value: requirement.supportingFindingIDs.joined(separator: ", ")
            ))
        }
        if let coverage {
            facts.append(EvidenceReportFact(
                label: "Check behind it",
                value: EvidenceWording.reportCheckTitle(coverage.check)
            ))
            facts += counts(
                check: coverage.check,
                lookedAt: coverage.satisfiedFlowIDs.count,
                notAssessed: coverage.unassessedFlowIDs.count,
                notApplicable: coverage.notApplicableFlowIDs.count
            )
        }
        return facts
    }

    private static func counts(
        check: FindingsCheck,
        lookedAt: Int,
        notAssessed: Int,
        notApplicable: Int
    ) -> [EvidenceReportFact] {
        var facts: [EvidenceReportFact] = []
        if let label = EvidenceWording.reportLookedAtLabel(check) {
            facts.append(EvidenceReportFact(label: label, value: String(lookedAt)))
        }
        facts.append(EvidenceReportFact(label: "Connections not assessed", value: String(notAssessed)))
        facts.append(EvidenceReportFact(
            label: "Connections the check does not apply to",
            value: String(notApplicable)
        ))
        return facts
    }

    // MARK: - Los hallazgos

    private static func findings(
        _ findings: [EvidenceFinding],
        limits: EvidenceReportLimits
    ) -> [EvidenceReportBlock] {
        guard !findings.isEmpty else { return [.paragraph(EvidenceWording.reportNoFindings)] }

        // Los hallazgos que afirman lo mismo —la frase, no solo la clase— van juntos bajo su
        // frase, en el orden en que cada una apareció: sesenta hosts fuera de la allowlist son
        // una frase y sesenta filas.
        var order: [String] = []
        var groups: [String: [EvidenceFinding]] = [:]
        for finding in findings {
            if groups[finding.statement] == nil { order.append(finding.statement) }
            groups[finding.statement, default: []].append(finding)
        }

        var blocks: [EvidenceReportBlock] = []
        for statement in order {
            let group = groups[statement] ?? []
            guard let first = group.first else { continue }
            blocks.append(.heading(first.kind))
            blocks.append(.note(statement))

            let subjects = group.map(subject)
            let hasSubject = subjects.contains { !$0.isEmpty }
            blocks.append(.table(EvidenceReportTable(
                columns: ["Finding"] + (hasSubject ? ["Stated about"] : [])
                    + ["Connections", "Flows in flows.json"],
                rows: zip(group, subjects).map { finding, subject in
                    [finding.id] + (hasSubject ? [subject] : [])
                        + [String(finding.flowIDs.count), list(finding.flowIDs, limit: limits.flowIDsPerFinding)]
                }
            )))
        }
        return blocks
    }

    /// Aquello de lo que un hallazgo habla, cuando su frase no lo lleva: el host, o la versión
    /// con su origen.
    private static func subject(of finding: EvidenceFinding) -> String {
        if let host = finding.host { return host }
        if let observation = finding.tlsVersion {
            return "\(EvidenceWording.reportName(of: observation.version)), "
                + EvidenceWording.reportBasis(observation)
        }
        return ""
    }

    private static func list(_ flowIDs: [Int64], limit: Int) -> String {
        let shown = flowIDs.prefix(limit).map { String($0) }.joined(separator: ", ")
        guard flowIDs.count > limit else { return shown }
        return shown + ". " + EvidenceWording.reportOmitted(
            flowIDs.count - limit,
            of: "Connections",
            in: EvidenceBundleFormat.findingsFileName
        )
    }

    // MARK: - Las comprobaciones

    private static func checks(_ findings: SessionFindings) -> [EvidenceReportBlock] {
        var blocks: [EvidenceReportBlock] = [.paragraph(EvidenceWording.reportChecksIntroduction)]
        for check in FindingsCheck.allCases {
            let reasons: [(String, Int)]
            switch check {
            case .encryption:
                reasons = findings.encryption.unassessed.map { (EvidenceWording.reportReason($0.gap), $0.flowIDs.count) }
            case .tlsVersion:
                reasons = findings.tlsVersion.unassessed.map { (EvidenceWording.reportReason($0.gap), $0.flowIDs.count) }
            case .host:
                reasons = findings.host.unassessed.map { (EvidenceWording.reportReason($0.gap), $0.flowIDs.count) }
            case .pinning:
                reasons = findings.pinning.unassessed.map { (EvidenceWording.reportReason($0.gap), $0.flowIDs.count) }
            case .consent:
                reasons = findings.consent.unassessed.map { (EvidenceWording.reportReason($0.gap), $0.flowIDs.count) }
            }
            let coverage = findings.coverage(of: check)
            // Cada comprobación le da a un flujo un solo desenlace, así que ninguno está detrás
            // de dos hallazgos suyos y sumar no cuenta a nadie dos veces.
            let behindFindings = findings.findings
                .filter { $0.kind.check == check }
                .reduce(0) { $0 + $1.flowIDs.count }

            blocks.append(.heading(EvidenceWording.reportCheckTitle(check)))
            blocks.append(.facts(
                [EvidenceReportFact(label: "Connections behind a finding", value: String(behindFindings))]
                    + counts(
                        check: check,
                        lookedAt: coverage.satisfiedFlowIDs.count,
                        notAssessed: coverage.unassessedFlowIDs.count,
                        notApplicable: coverage.notApplicableFlowIDs.count
                    )
            ))
            if check == .pinning {
                blocks.append(.paragraph(EvidenceWording.reportPinningOutcomesNote))
            }
            if !reasons.isEmpty {
                blocks.append(.table(EvidenceReportTable(
                    columns: ["Why it could not be assessed", "Connections"],
                    rows: reasons.map { [$0.0, String($0.1)] }
                )))
            }
        }
        return blocks
    }

    // MARK: - Las lecturas de TLS

    private struct TLSReading: Hashable {
        let host: String
        let nameOrigin: String
        let reading: String
        let source: String
    }

    private static func tlsReadings(
        _ flows: [EvidenceFlow],
        limits: EvidenceReportLimits
    ) -> [EvidenceReportBlock] {
        var order: [TLSReading] = []
        var counts: [TLSReading: Int] = [:]
        var refused = 0
        var withoutReading = 0

        for flow in flows {
            let reading: String
            let source: String
            // La respuesta del servidor manda sobre QUIC, como en `TLSVersionObservation(of:)`.
            if let server = flow.serverTLS {
                guard let version = server.version, let origin = server.source else {
                    refused += 1
                    continue
                }
                reading = EvidenceWording.reportName(of: version)
                source = server.fromHelloRetryRequest == true ? "\(origin), from a HelloRetryRequest" : origin
            } else if let quic = flow.quic {
                reading = "QUIC \(quic.version.hex)"
                source = "quic, read from the \(quic.source)"
            } else {
                withoutReading += 1
                continue
            }
            let row = TLSReading(
                host: flow.name?.text ?? "(no name)",
                nameOrigin: flow.name?.origin ?? "",
                reading: reading,
                source: source
            )
            if counts[row] == nil { order.append(row) }
            counts[row, default: 0] += 1
        }

        var blocks: [EvidenceReportBlock] = []
        if !order.isEmpty {
            blocks.append(.note(EvidenceWording.reportTLSReadingsNote))
            blocks.append(.table(EvidenceReportTable(
                columns: ["Host", "Name from", "Reading", "Read from", "Connections"],
                rows: order.prefix(limits.tlsReadingRows).map {
                    [$0.host, $0.nameOrigin, $0.reading, $0.source, String(counts[$0] ?? 0)]
                }
            )))
            if order.count > limits.tlsReadingRows {
                blocks.append(.paragraph(EvidenceWording.reportOmitted(
                    order.count - limits.tlsReadingRows,
                    of: "Rows",
                    in: EvidenceBundleFormat.flowsFileName
                )))
            }
        }
        var facts = [EvidenceReportFact(
            label: "Connections with a reading",
            value: String(flows.count - refused - withoutReading)
        )]
        if refused > 0 {
            facts.append(EvidenceReportFact(
                label: "Connections the server refused with an alert",
                value: String(refused)
            ))
        }
        if withoutReading > 0 {
            facts.append(EvidenceReportFact(
                label: "Connections with no TLS or QUIC reading",
                value: String(withoutReading)
            ))
        }
        blocks.append(.facts(facts))
        return blocks
    }

    // MARK: - La captura

    private static func capture(_ document: EvidenceCaptureDocument) -> [EvidenceReportBlock] {
        let standing = EvidenceCaptureStanding(document.packets)
        var blocks: [EvidenceReportBlock] = [.paragraph(EvidenceWording.reportCaptureStanding(standing))]

        var facts: [EvidenceReportFact] = []
        switch standing {
        case .nothingRecorded:
            break
        case .complete(let packets):
            facts.append(EvidenceReportFact(label: "Packets recorded", value: String(packets)))
        case .incomplete(let written, let recorded, let missing):
            facts.append(EvidenceReportFact(label: "Packets recorded", value: String(recorded)))
            facts.append(EvidenceReportFact(label: "Packets in capture.pcapng", value: String(written)))
            facts += missing.map {
                EvidenceReportFact(label: EvidenceWording.reportLabel($0.reason), value: String($0.count))
            }
        }
        let outside = document.writtenOutsideSession
        if outside.beforeStart > 0 {
            facts.append(EvidenceReportFact(
                label: "In the capture, from before the session started",
                value: String(outside.beforeStart)
            ))
        }
        if outside.afterEnd > 0 {
            facts.append(EvidenceReportFact(
                label: "In the capture, from after the session ended",
                value: String(outside.afterEnd)
            ))
        }
        if !facts.isEmpty { blocks.append(.facts(facts)) }

        blocks.append(.note(document.contents))
        blocks.append(.note(document.packetComments))
        return blocks
    }
}
