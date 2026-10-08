import Foundation

/// La clase de un hallazgo. Su `rawValue` es el identificador con el que un catálogo de requisitos
/// dice qué hallazgos le afectan, así que es formato: no se renombra.
///
/// Solo lleva las clases que el clasificador **produce**. Una clase que nadie puede levantar sería
/// una fila del informe que siempre sale limpia sin que nadie haya mirado.
public enum FindingKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// Una conexión negoció una versión de TLS por debajo del mínimo exigido.
    case weakTLSVersion
}

/// Lo que un hallazgo **afirma**, con lo observado que lo sostiene.
///
/// Es un valor comparable a propósito: dos flujos que prueban exactamente lo mismo son un hallazgo
/// con dos flujos, no dos hallazgos. Por eso aquí no va nada que sea del flujo —su host, su
/// instante—: eso se lee de los flujos que el hallazgo señala.
public enum FindingEvidence: Sendable, Hashable {
    case weakTLSVersion(TLSVersionObservation)

    public var kind: FindingKind {
        switch self {
        case .weakTLSVersion: return .weakTLSVersion
        }
    }
}

/// Un hallazgo: una afirmación y los flujos que la prueban.
///
/// Los paquetes no se citan aquí. Se llega a ellos por el flujo (`packets.flow_id`), y con ellos al
/// fichero y la posición de sus bytes; apuntarlos dos veces sería decir lo mismo en dos sitios.
public struct Finding: Sendable, Hashable {

    public let evidence: FindingEvidence

    /// Los `id` de los flujos que lo prueban, en el orden en que se le dieron al clasificador (el
    /// del historial de una sesión: como ocurrieron). Nunca vacío.
    public let flowIDs: [Int64]

    public init(evidence: FindingEvidence, flowIDs: [Int64]) {
        self.evidence = evidence
        self.flowIDs = flowIDs
    }

    public var kind: FindingKind { evidence.kind }
}

/// Los flujos de los que una comprobación **no pudo decir nada**, con el motivo.
public struct UnassessedFlows<Gap: Sendable & Hashable>: Sendable, Hashable {
    public let gap: Gap
    public let flowIDs: [Int64]

    public init(gap: Gap, flowIDs: [Int64]) {
        self.gap = gap
        self.flowIDs = flowIDs
    }
}

/// Hasta dónde llegó una comprobación sobre los flujos de una sesión, aparte de sus hallazgos.
///
/// Existe porque «sin hallazgos» no distingue dos cosas que un informe no puede confundir: que se
/// miró y estaba bien, o que no había nada que se pudiera mirar. Un requisito solo puede darse por
/// observado sin incidencias si `satisfiedFlowIDs` no está vacío; si lo está, es «no evaluado por
/// esta herramienta», nunca «superado».
public struct CheckCoverage<Gap: Sendable & Hashable>: Sendable, Hashable {

    /// Los flujos en los que la comprobación se pudo hacer y no encontró nada que señalar.
    public let satisfiedFlowIDs: [Int64]

    /// Los flujos a los que la comprobación aplicaba y no se pudo hacer, agrupados por motivo, en
    /// el orden en que cada motivo apareció por primera vez.
    public let unassessed: [UnassessedFlows<Gap>]

    /// Los flujos a los que la comprobación no aplica: no son de lo que mira.
    public let notApplicableFlowIDs: [Int64]

    public init(
        satisfiedFlowIDs: [Int64],
        unassessed: [UnassessedFlows<Gap>],
        notApplicableFlowIDs: [Int64]
    ) {
        self.satisfiedFlowIDs = satisfiedFlowIDs
        self.unassessed = unassessed
        self.notApplicableFlowIDs = notApplicableFlowIDs
    }
}
