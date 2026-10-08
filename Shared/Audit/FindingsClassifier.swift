import Foundation

/// Los umbrales contra los que se clasifica. Son **configuración**: salen del catálogo de
/// requisitos con el que se evalúa el proyecto, y el clasificador no lleva ninguno escrito.
public struct FindingsPolicy: Sendable, Hashable {

    /// La versión de TLS más baja que se acepta.
    public let minimumTLSVersion: TLSProtocolVersion

    /// `nil` si el mínimo no es una versión publicada: no se podría comparar nada con él, y un
    /// catálogo que lo trae está mal escrito y tiene que saberse al cargarlo, no al informar.
    public init?(minimumTLSVersion: TLSProtocolVersion) {
        guard minimumTLSVersion.isPublished else { return nil }
        self.minimumTLSVersion = minimumTLSVersion
    }
}

/// Lo que el clasificador dice de los flujos de una sesión: los hallazgos y, por cada
/// comprobación, hasta dónde llegó.
public struct SessionFindings: Sendable, Hashable {

    /// En el orden en que cada uno apareció por primera vez al recorrer los flujos; si un flujo
    /// prueba dos, el de tráfico sin cifrar va antes que el de la versión de TLS.
    public let findings: [Finding]

    /// Lo que la comprobación de la versión de TLS pudo y no pudo mirar.
    public let tlsVersion: CheckCoverage<TLSVersionGap>

    /// Lo que la comprobación de tráfico sin cifrar pudo y no pudo mirar.
    public let encryption: CheckCoverage<EncryptionGap>

    public init(
        findings: [Finding],
        tlsVersion: CheckCoverage<TLSVersionGap>,
        encryption: CheckCoverage<EncryptionGap>
    ) {
        self.findings = findings
        self.tlsVersion = tlsVersion
        self.encryption = encryption
    }
}

/// El clasificador de hallazgos: de los flujos de una sesión a lo que prueban.
///
/// Es puro —no lee el historial ni el reloj— y no decide veredictos: que un hallazgo incumpla un
/// requisito lo dice la regla del catálogo. Aquí solo se afirma lo que los flujos dejan afirmar, y
/// lo que no se pudo mirar se devuelve con su motivo en vez de callarse.
public enum FindingsClassifier {

    /// - Parameter flows: los flujos de una sesión de auditoría, en el orden del historial
    ///   (`FlowStore.flows(inAuditSession:limit:)`: como ocurrieron).
    public static func classify(flows: [StoredFlow], policy: FindingsPolicy) -> SessionFindings {
        var findings = Grouping<FindingEvidence>()
        var tlsGaps = Grouping<TLSVersionGap>()
        var tlsSatisfied: [Int64] = []
        var tlsNotApplicable: [Int64] = []
        var encryptionGaps = Grouping<EncryptionGap>()
        var encryptionSatisfied: [Int64] = []
        var encryptionNotApplicable: [Int64] = []

        for flow in flows {
            switch EncryptionAssessment(of: flow) {
            case .cleartext(let proto):
                findings.add(flow.id, to: .cleartextTraffic(proto))
            case .encrypted:
                encryptionSatisfied.append(flow.id)
            case .notAssessed(let gap):
                encryptionGaps.add(flow.id, to: gap)
            case .notApplicable:
                encryptionNotApplicable.append(flow.id)
            }

            switch TLSVersionAssessment(of: flow, minimum: policy.minimumTLSVersion) {
            case .weak(let observation):
                findings.add(flow.id, to: .weakTLSVersion(observation))
            case .acceptable:
                tlsSatisfied.append(flow.id)
            case .notAssessed(let gap):
                tlsGaps.add(flow.id, to: gap)
            case .notApplicable:
                tlsNotApplicable.append(flow.id)
            }
        }

        return SessionFindings(
            findings: findings.groups.map { Finding(evidence: $0.key, flowIDs: $0.flowIDs) },
            tlsVersion: CheckCoverage(
                satisfiedFlowIDs: tlsSatisfied,
                unassessed: tlsGaps.groups.map { UnassessedFlows(gap: $0.key, flowIDs: $0.flowIDs) },
                notApplicableFlowIDs: tlsNotApplicable
            ),
            encryption: CheckCoverage(
                satisfiedFlowIDs: encryptionSatisfied,
                unassessed: encryptionGaps.groups.map { UnassessedFlows(gap: $0.key, flowIDs: $0.flowIDs) },
                notApplicableFlowIDs: encryptionNotApplicable
            )
        )
    }

    /// Agrupa ids de flujo por una clave conservando el orden de primera aparición: un `Dictionary`
    /// solo no lo da, y el orden de un informe no puede depender de un hash.
    private struct Grouping<Key: Hashable> {
        private(set) var groups: [(key: Key, flowIDs: [Int64])] = []
        private var indices: [Key: Int] = [:]

        mutating func add(_ flowID: Int64, to key: Key) {
            if let index = indices[key] {
                groups[index].flowIDs.append(flowID)
            } else {
                indices[key] = groups.count
                groups.append((key: key, flowIDs: [flowID]))
            }
        }
    }
}
