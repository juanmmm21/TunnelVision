import Foundation

/// Un hallazgo tal como se escribe: su identificador dentro del paquete, lo que afirma y los
/// flujos que lo prueban.
public struct EvidenceFinding: Encodable, Sendable, Hashable {

    /// `F1`, `F2`…, en el orden de los hallazgos de la sesión. Solo identifica dentro de **este**
    /// paquete: es con lo que un flujo de `flows.json` y un requisito señalan a un hallazgo.
    public let id: String

    /// El `rawValue` de `FindingKind`, que es también lo que cita el catálogo.
    public let kind: String

    /// Lo que se afirma, redactado. Los datos de la afirmación van en sus campos, no en la frase.
    public let statement: String

    /// Solo en `hostNotInAllowlist` y en los dos de pinning: el host, normalizado.
    public let host: String?

    /// Solo en `weakTLSVersion`: la versión observada, con su origen.
    public let tlsVersion: EvidenceTLSObservation?

    /// Solo en `cleartextTraffic`: el protocolo que se vio en claro.
    public let cleartextProtocol: String?

    /// Solo en `unnamedFlow`: por qué el flujo no tiene nombre.
    public let unnamedReason: String?

    public let flowIDs: [Int64]

    init(id: String, finding: Finding, policy: FindingsPolicy) {
        self.id = id
        self.kind = finding.kind.rawValue
        self.statement = EvidenceWording.statement(of: finding.evidence, policy: policy)
        self.flowIDs = finding.flowIDs
        switch finding.evidence {
        case .hostNotInAllowlist(let host), .pinningAbsent(let host), .pinningObserved(let host):
            self.host = host
        case .weakTLSVersion, .cleartextTraffic, .unnamedFlow, .activityBeforeConsent:
            self.host = nil
        }
        if case .weakTLSVersion(let observation) = finding.evidence {
            self.tlsVersion = EvidenceTLSObservation(observation)
        } else {
            self.tlsVersion = nil
        }
        if case .cleartextTraffic(let proto) = finding.evidence {
            self.cleartextProtocol = proto.rawValue
        } else {
            self.cleartextProtocol = nil
        }
        if case .unnamedFlow(let reason) = finding.evidence {
            self.unnamedReason = reason.rawValue
        } else {
            self.unnamedReason = nil
        }
    }
}

/// Los flujos de los que una comprobación no pudo decir nada, con el motivo y lo que lo detalla.
public struct EvidenceUnassessedFlows: Encodable, Sendable, Hashable {

    /// El identificador del motivo. Los campos opcionales que siguen son sus detalles, y cada
    /// motivo lleva solo los suyos.
    public let reason: String

    public let alert: UInt8?
    public let tlsVersion: EvidenceTLSObservation?
    public let upstreamVersion: EvidenceTLSVersion?

    /// Con `appNegotiationNotObserved`: por qué la oferta de la app no descarta que negociara
    /// menos (`notRead`, `encryptedClientHello`, `ceilingOnly`, `listsWeakerVersion`,
    /// `listNotConclusive`).
    public let clientOffer: String?

    /// Con `clientOffer` = `ceilingOnly`: el techo que anunció.
    public let clientOfferCeiling: EvidenceTLSVersion?

    public let quicVersion: EvidenceWireCode?

    /// Con `candidatesDisagree`: de qué lado de la allowlist cae el nombre que se le atribuyó.
    public let attributedNameAllowed: Bool?

    public let flowIDs: [Int64]

    private init(
        reason: String,
        flowIDs: [Int64],
        alert: UInt8? = nil,
        tlsVersion: EvidenceTLSObservation? = nil,
        upstreamVersion: EvidenceTLSVersion? = nil,
        clientOffer: String? = nil,
        clientOfferCeiling: EvidenceTLSVersion? = nil,
        quicVersion: EvidenceWireCode? = nil,
        attributedNameAllowed: Bool? = nil
    ) {
        self.reason = reason
        self.flowIDs = flowIDs
        self.alert = alert
        self.tlsVersion = tlsVersion
        self.upstreamVersion = upstreamVersion
        self.clientOffer = clientOffer
        self.clientOfferCeiling = clientOfferCeiling
        self.quicVersion = quicVersion
        self.attributedNameAllowed = attributedNameAllowed
    }

    init(_ group: UnassessedFlows<TLSVersionGap>) {
        let ids = group.flowIDs
        switch group.gap {
        case .serverAnswerNotRead:
            self.init(reason: "serverAnswerNotRead", flowIDs: ids)
        case .serverRefused(let alert):
            self.init(reason: "serverRefused", flowIDs: ids, alert: alert)
        case .unrecognisedVersion(let observation):
            self.init(
                reason: "unrecognisedVersion",
                flowIDs: ids,
                tlsVersion: EvidenceTLSObservation(observation)
            )
        case .appNegotiationNotObserved(let upstream, let offer):
            let ceiling: TLSProtocolVersion?
            if case .ceilingOnly(let version) = offer { ceiling = version } else { ceiling = nil }
            self.init(
                reason: "appNegotiationNotObserved",
                flowIDs: ids,
                upstreamVersion: EvidenceTLSVersion(upstream),
                clientOffer: Self.name(of: offer),
                clientOfferCeiling: ceiling.map(EvidenceTLSVersion.init)
            )
        case .quicVersionOnlyProposed(let version):
            self.init(reason: "quicVersionOnlyProposed", flowIDs: ids, quicVersion: EvidenceWireCode(version))
        case .unrecognisedQUICVersion(let version):
            self.init(reason: "unrecognisedQUICVersion", flowIDs: ids, quicVersion: EvidenceWireCode(version))
        }
    }

    init(_ group: UnassessedFlows<EncryptionGap>) {
        let ids = group.flowIDs
        switch group.gap {
        case .unrecognisedOpening:
            self.init(reason: "unrecognisedOpening", flowIDs: ids)
        case .openingNotRead:
            self.init(reason: "openingNotRead", flowIDs: ids)
        case .unrecognisedQUICVersion(let version):
            self.init(reason: "unrecognisedQUICVersion", flowIDs: ids, quicVersion: EvidenceWireCode(version))
        case .datagramsNotRead:
            self.init(reason: "datagramsNotRead", flowIDs: ids)
        }
    }

    init(_ group: UnassessedFlows<HostGap>) {
        switch group.gap {
        case .allowlistEmpty:
            self.init(reason: "allowlistEmpty", flowIDs: group.flowIDs)
        case .candidatesDisagree(let attributedNameAllowed):
            self.init(
                reason: "candidatesDisagree",
                flowIDs: group.flowIDs,
                attributedNameAllowed: attributedNameAllowed
            )
        }
    }

    init(_ group: UnassessedFlows<PinningGap>) {
        self.init(reason: group.gap.rawValue, flowIDs: group.flowIDs)
    }

    init(_ group: UnassessedFlows<ConsentGap>) {
        self.init(reason: group.gap.rawValue, flowIDs: group.flowIDs)
    }

    private static func name(of offer: ClientOfferGap) -> String {
        switch offer {
        case .notRead: return "notRead"
        case .encryptedClientHello: return "encryptedClientHello"
        case .ceilingOnly: return "ceilingOnly"
        case .listsWeakerVersion: return "listsWeakerVersion"
        case .listNotConclusive: return "listNotConclusive"
        }
    }
}

/// Hasta dónde llegó una de las cinco comprobaciones: en cuántos flujos pudo mirar, en cuáles no
/// y por qué. Es lo que impide leer «sin hallazgos» como «sin problemas».
public struct EvidenceCheck: Encodable, Sendable, Hashable {

    /// El `rawValue` de `FindingsCheck`.
    public let check: String

    /// Los flujos en los que se pudo mirar y no hubo nada que señalar. En `pinning` está siempre
    /// vacío: allí el desenlace favorable también es un hallazgo.
    public let satisfiedFlowIDs: [Int64]

    public let unassessed: [EvidenceUnassessedFlows]
    public let notApplicableFlowIDs: [Int64]

    init(_ check: FindingsCheck, findings: SessionFindings) {
        switch check {
        case .encryption:
            self.init(check, findings.encryption, EvidenceUnassessedFlows.init)
        case .tlsVersion:
            self.init(check, findings.tlsVersion, EvidenceUnassessedFlows.init)
        case .host:
            self.init(check, findings.host, EvidenceUnassessedFlows.init)
        case .pinning:
            self.init(check, findings.pinning, EvidenceUnassessedFlows.init)
        case .consent:
            self.init(check, findings.consent, EvidenceUnassessedFlows.init)
        }
    }

    private init<Gap>(
        _ check: FindingsCheck,
        _ coverage: CheckCoverage<Gap>,
        _ written: (UnassessedFlows<Gap>) -> EvidenceUnassessedFlows
    ) {
        self.check = check.rawValue
        self.satisfiedFlowIDs = coverage.satisfiedFlowIDs
        self.unassessed = coverage.unassessed.map(written)
        self.notApplicableFlowIDs = coverage.notApplicableFlowIDs
    }
}

/// Un requisito del catálogo con lo que la sesión dice de él.
public struct EvidenceRequirement: Encodable, Sendable, Hashable {

    public struct Aspect: Encodable, Sendable, Hashable {
        public let number: Int
        public let name: String
    }

    /// El identificador del documento, tal cual.
    public let id: String
    public let aspect: Aspect

    /// El título del documento, en su idioma.
    public let title: String
    public let testDepth: String

    /// `outsideToolScope`, `contraryFindings` o `contraryAndSupportingFindings`.
    public let rule: String

    /// `contradicted`, `observedWithoutContradiction` o `notAssessed`. **No es el resultado de la
    /// prueba**, que pone el evaluador, y no hay ninguno que diga que el requisito se cumple.
    public let verdict: String

    /// Solo con `notAssessed`: `outsideToolScope` o `nothingObserved`.
    public let notAssessedReason: String?

    public let verdictStatement: String

    /// Qué mira la herramienta de este requisito y qué no: el límite del veredicto. Es texto del
    /// catálogo, y va siempre que la regla lee hallazgos.
    public let toolCoverage: String?

    public let contraryFindingIDs: [String]
    public let supportingFindingIDs: [String]

    /// La comprobación que respalda la regla, cuya cobertura está en `checks`; ausente si la
    /// regla no lee ninguna.
    public let check: String?

    init(_ assessment: RequirementAssessment, findingIDs: [Finding: String]) {
        let requirement = assessment.requirement
        self.id = requirement.id
        self.aspect = Aspect(number: requirement.aspect.number, name: requirement.aspect.name)
        self.title = requirement.title
        self.testDepth = requirement.testDepth.rawValue
        self.rule = Self.name(of: requirement.rule)
        switch assessment.verdict {
        case .contradicted:
            self.verdict = "contradicted"
            self.notAssessedReason = nil
        case .observedWithoutContradiction:
            self.verdict = "observedWithoutContradiction"
            self.notAssessedReason = nil
        case .notAssessed(.outsideToolScope):
            self.verdict = "notAssessed"
            self.notAssessedReason = "outsideToolScope"
        case .notAssessed(.nothingObserved):
            self.verdict = "notAssessed"
            self.notAssessedReason = "nothingObserved"
        }
        self.verdictStatement = EvidenceWording.statement(of: assessment.verdict)
        self.toolCoverage = requirement.toolCoverage
        self.contraryFindingIDs = assessment.contraryFindings.compactMap { findingIDs[$0] }
        self.supportingFindingIDs = assessment.supportingFindings.compactMap { findingIDs[$0] }
        self.check = requirement.rule.check?.rawValue
    }

    private static func name(of rule: RequirementRule) -> String {
        switch rule {
        case .outsideToolScope: return "outsideToolScope"
        case .contraryFindings: return "contraryFindings"
        case .contraryAndSupportingFindings: return "contraryAndSupportingFindings"
        }
    }
}

/// El catálogo contra el que se evaluó, con lo que hace falta para volver a sus documentos.
public struct EvidenceCatalogue: Encodable, Sendable, Hashable {

    public struct Source: Encodable, Sendable, Hashable {
        public let document: String
        public let title: String
        public let version: String
        public let date: String

        /// El SHA-256 del PDF con el que se verificó el catálogo.
        public let sha256: String

        init(_ source: CatalogueSource) {
            self.document = source.document
            self.title = source.title
            self.version = source.version
            self.date = source.date
            self.sha256 = source.sha256
        }
    }

    public let identifier: String
    public let source: Source

    /// La versión de TLS más baja que se aceptó al clasificar, y el documento del que sale.
    public let minimumTLSVersion: EvidenceTLSVersion
    public let tlsSource: Source

    init(_ catalogue: RequirementCatalogue) {
        self.identifier = catalogue.identifier
        self.source = Source(catalogue.source)
        self.minimumTLSVersion = EvidenceTLSVersion(catalogue.policy.minimumTLSVersion)
        self.tlsSource = Source(catalogue.tlsSource)
    }
}

/// `findings.json`: lo que la sesión dice de cada requisito del catálogo, los hallazgos que lo
/// sostienen y hasta dónde llegó cada comprobación.
///
/// Los paquetes no se citan aquí: un hallazgo señala flujos, y de un flujo a sus paquetes se llega
/// por la captura del paquete, que es la que sabe en qué posición quedaron sus bytes al recortarla.
public struct EvidenceFindingsDocument: Encodable, Sendable, Hashable {

    public let format: String
    public let formatVersion: Int
    public let sessionID: Int64

    /// Cómo se lee un veredicto: va en el propio fichero porque es lo primero que se malinterpreta.
    public let verdicts: String

    public let catalogue: EvidenceCatalogue

    /// Uno por requisito del catálogo, en su orden.
    public let requirements: [EvidenceRequirement]

    /// En el orden en que cada uno apareció por primera vez al recorrer los flujos.
    public let findings: [EvidenceFinding]

    /// Las cinco comprobaciones, siempre todas, lean o no algún requisito del catálogo.
    public let checks: [EvidenceCheck]

    init(sessionID: Int64, assessment: SessionAssessment, findings: [EvidenceFinding], findingIDs: [Finding: String]) {
        self.format = EvidenceBundleFormat.findingsIdentifier
        self.formatVersion = EvidenceBundleFormat.version
        self.sessionID = sessionID
        self.verdicts = EvidenceWording.verdictsNote
        self.catalogue = EvidenceCatalogue(assessment.catalogue)
        self.requirements = assessment.requirements.map { EvidenceRequirement($0, findingIDs: findingIDs) }
        self.findings = findings
        self.checks = FindingsCheck.allCases.map { EvidenceCheck($0, findings: assessment.findings) }
    }
}
