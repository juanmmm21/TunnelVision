import Foundation

/// Por qué de una sesión no se puede armar un paquete de evidencia.
public enum EvidenceBundleError: Error, Sendable, Hashable {
    /// La sesión no es del proyecto que se dio: se juzgaría contra la allowlist de otro.
    case sessionOfAnotherProject(sessionProjectID: Int64, projectID: Int64)
    /// La sesión sigue abierta: sus flujos siguen cambiando, y un paquete es evidencia cerrada.
    case sessionStillOpen
    /// El mismo flujo dos veces: un hallazgo lo citaría dos veces y los recuentos mentirían.
    case duplicateFlow(id: Int64)
}

/// Los documentos del paquete de evidencia de una sesión, ya armados y sin escribir.
///
/// **Clasifica él mismo**, con el catálogo que se le da, en vez de recibir una evaluación ya
/// hecha: así los flujos de `flows.json` y los que citan los hallazgos de `findings.json` no
/// pueden venir de dos listas distintas, que es justo lo que un evaluador no podría detectar.
///
/// Es puro: no lee el historial, el reloj ni el disco. La captura (`.pcap`) no está aquí porque no
/// cabe en memoria; quien la recorta le da su digest al manifiesto con `manifest(adding:)`.
public struct EvidenceBundle: Sendable, Hashable {

    /// La evaluación de la que salen `findings` y los `findingIDs` de cada flujo. La lee también
    /// el informe, para no clasificar dos veces.
    public let assessment: SessionAssessment

    public let session: EvidenceSessionDocument
    public let flows: EvidenceFlowsDocument
    public let findings: EvidenceFindingsDocument

    /// - Parameter markers: los marcadores de la sesión. Los de otra sesión se ignoran.
    /// - Parameter flows: **todos** los flujos de la sesión, en el orden del historial. Nada aquí
    ///   puede comprobar que estén todos: los que falten no se evalúan ni se listan.
    /// - Parameter catalogue: el del proyecto (`RequirementCatalogueLibrary.catalogue(for:)`).
    /// - Parameter exportedWith: la versión de la herramienta que arma el paquete, que puede no
    ///   ser la que grabó la sesión.
    public init(
        project: AuditProject,
        session: AuditSession,
        markers: [SessionMarker],
        flows: [StoredFlow],
        catalogue: RequirementCatalogue,
        exportedWith: String,
        exportedAt: Date
    ) throws {
        guard session.projectID == project.id else {
            throw EvidenceBundleError.sessionOfAnotherProject(
                sessionProjectID: session.projectID,
                projectID: project.id
            )
        }
        guard let endedAt = session.endedAt else { throw EvidenceBundleError.sessionStillOpen }
        var seen: Set<Int64> = []
        for flow in flows where !seen.insert(flow.id).inserted {
            throw EvidenceBundleError.duplicateFlow(id: flow.id)
        }

        let ownMarkers = markers.filter { $0.sessionID == session.id }
        let assessment = SessionAssessment(
            catalogue: catalogue,
            flows: flows,
            project: project,
            session: session,
            markers: ownMarkers
        )

        // Un hallazgo es un valor único dentro de una sesión (flujos que prueban lo mismo son uno
        // solo), así que sirve de clave para su identificador.
        var findingIDs: [Finding: String] = [:]
        var written: [EvidenceFinding] = []
        var idsByFlow: [Int64: [String]] = [:]
        for (index, finding) in assessment.findings.findings.enumerated() {
            let id = "F\(index + 1)"
            findingIDs[finding] = id
            written.append(EvidenceFinding(id: id, finding: finding, policy: catalogue.policy))
            for flowID in finding.flowIDs {
                idsByFlow[flowID, default: []].append(id)
            }
        }

        self.assessment = assessment
        self.session = EvidenceSessionDocument(
            project: project,
            session: session,
            endedAt: endedAt,
            markers: ownMarkers,
            exportedWith: exportedWith,
            exportedAt: exportedAt
        )
        self.flows = EvidenceFlowsDocument(
            sessionID: session.id,
            flows: flows.map { EvidenceFlow($0, findingIDs: idsByFlow[$0.id] ?? []) }
        )
        self.findings = EvidenceFindingsDocument(
            sessionID: session.id,
            assessment: assessment,
            findings: written,
            findingIDs: findingIDs
        )
    }

    /// Los documentos codificados, sin el manifiesto: `session.json`, `flows.json`, `flows.csv` y
    /// `findings.json`.
    public func documentFiles() throws -> [EvidenceFile] {
        [
            EvidenceFile(
                name: EvidenceBundleFormat.sessionFileName,
                data: try EvidenceBundleFormat.encode(session)
            ),
            EvidenceFile(
                name: EvidenceBundleFormat.flowsFileName,
                data: try EvidenceBundleFormat.encode(flows)
            ),
            EvidenceFile(
                name: EvidenceBundleFormat.flowsCSVFileName,
                data: EvidenceFlowsCSV.document(flows.flows)
            ),
            EvidenceFile(
                name: EvidenceBundleFormat.findingsFileName,
                data: try EvidenceBundleFormat.encode(findings)
            ),
        ]
    }

    /// El manifiesto de unos documentos ya codificados y de los ficheros que no pasan por aquí.
    ///
    /// Recibe los ficheros en vez de volver a codificarlos para que el digest sea el de los bytes
    /// que se van a escribir, y no el de otra codificación que se supone idéntica.
    ///
    /// - Parameter extra: las entradas de lo que se escribe aparte, con su digest ya calculado.
    public func manifest(
        of files: [EvidenceFile],
        adding extra: [EvidenceManifest.Entry]
    ) throws -> EvidenceManifest {
        try EvidenceManifest(
            sessionID: session.session.id,
            exportedAt: session.exportedAt,
            entries: files.map(EvidenceManifest.Entry.init) + extra
        )
    }
}
