import Foundation

/// Lo que una comprobación miró, sin sus motivos: lo que un requisito necesita para decir sobre
/// cuántos flujos descansa. Los motivos, con su tipo, siguen en `SessionFindings`.
public struct CheckCoverageSummary: Sendable, Hashable {
    public let check: FindingsCheck
    public let satisfiedFlowIDs: [Int64]
    public let unassessedFlowIDs: [Int64]
    public let notApplicableFlowIDs: [Int64]

    public init(
        check: FindingsCheck,
        satisfiedFlowIDs: [Int64],
        unassessedFlowIDs: [Int64],
        notApplicableFlowIDs: [Int64]
    ) {
        self.check = check
        self.satisfiedFlowIDs = satisfiedFlowIDs
        self.unassessedFlowIDs = unassessedFlowIDs
        self.notApplicableFlowIDs = notApplicableFlowIDs
    }

    fileprivate init<Gap>(check: FindingsCheck, coverage: CheckCoverage<Gap>) {
        self.init(
            check: check,
            satisfiedFlowIDs: coverage.satisfiedFlowIDs,
            unassessedFlowIDs: coverage.unassessed.flatMap(\.flowIDs),
            notApplicableFlowIDs: coverage.notApplicableFlowIDs
        )
    }
}

extension SessionFindings {

    public func coverage(of check: FindingsCheck) -> CheckCoverageSummary {
        switch check {
        case .encryption: return CheckCoverageSummary(check: check, coverage: encryption)
        case .tlsVersion: return CheckCoverageSummary(check: check, coverage: tlsVersion)
        case .host: return CheckCoverageSummary(check: check, coverage: host)
        case .pinning: return CheckCoverageSummary(check: check, coverage: pinning)
        case .consent: return CheckCoverageSummary(check: check, coverage: consent)
        }
    }
}

/// Por qué de un requisito no se dice nada.
public enum NotAssessedReason: Sendable, Hashable {
    /// La herramienta no observa nada que hable de él.
    case outsideToolScope
    /// Lo observa, pero en esta sesión no hubo ni un hallazgo ni un flujo en el que mirar.
    case nothingObserved
}

/// Lo que la herramienta dice de un requisito a la vista de una sesión.
///
/// No es el resultado de la prueba. «PASS», «FAIL» e «INCONCLUSIVE» los pone el evaluador y los
/// razona (TR-03161-1, tabla 3); aquí solo hay lo que el tráfico dejó ver, y por eso no existe
/// un caso que diga «superado».
public enum RequirementVerdict: Sendable, Hashable {
    /// Hay observaciones que contradicen el requisito.
    case contradicted
    /// Se miró y nada lo contradice, dentro de lo que la herramienta mira de él.
    case observedWithoutContradiction
    case notAssessed(NotAssessedReason)
}

/// Un requisito con lo que una sesión dice de él y lo que lo prueba.
public struct RequirementAssessment: Sendable, Hashable {

    public let requirement: Requirement

    public let verdict: RequirementVerdict

    /// Los hallazgos que lo contradicen, en el orden de `SessionFindings.findings`.
    public let contraryFindings: [Finding]

    /// Los hallazgos que lo apoyan. Van también cuando hay otros que lo contradicen: un host que
    /// rechazó la CA local no deja de haberlo hecho porque otro la aceptara.
    public let supportingFindings: [Finding]

    /// Cuánto miró la comprobación que respalda la regla, o `nil` si la regla no lee ninguna.
    public let coverage: CheckCoverageSummary?

    public init(
        requirement: Requirement,
        verdict: RequirementVerdict,
        contraryFindings: [Finding],
        supportingFindings: [Finding],
        coverage: CheckCoverageSummary?
    ) {
        self.requirement = requirement
        self.verdict = verdict
        self.contraryFindings = contraryFindings
        self.supportingFindings = supportingFindings
        self.coverage = coverage
    }
}

extension Requirement {

    /// - Parameter findings: los hallazgos de una sesión, clasificados con la `policy` del
    ///   catálogo de este requisito. Con otra, el veredicto hablaría de un umbral que el catálogo
    ///   no cita: `SessionAssessment` es quien garantiza que sea la misma.
    public func assess(_ findings: SessionFindings) -> RequirementAssessment {
        let contraryKinds: [FindingKind]
        let supportingKinds: [FindingKind]
        switch rule {
        case .outsideToolScope:
            return RequirementAssessment(
                requirement: self,
                verdict: .notAssessed(.outsideToolScope),
                contraryFindings: [],
                supportingFindings: [],
                coverage: nil
            )
        case .contraryFindings(let kinds):
            contraryKinds = kinds
            supportingKinds = []
        case .contraryAndSupportingFindings(let contrary, let supporting):
            contraryKinds = contrary
            supportingKinds = supporting
        }

        let contrary = findings.findings.filter { contraryKinds.contains($0.kind) }
        let supporting = findings.findings.filter { supportingKinds.contains($0.kind) }
        let coverage = rule.check.map(findings.coverage(of:))

        let verdict: RequirementVerdict
        if !contrary.isEmpty {
            verdict = .contradicted
        } else if !supporting.isEmpty || !(coverage?.satisfiedFlowIDs.isEmpty ?? true) {
            verdict = .observedWithoutContradiction
        } else {
            verdict = .notAssessed(.nothingObserved)
        }
        return RequirementAssessment(
            requirement: self,
            verdict: verdict,
            contraryFindings: contrary,
            supportingFindings: supporting,
            coverage: coverage
        )
    }
}

/// Una sesión evaluada contra un catálogo: sus hallazgos y lo que dicen de cada requisito.
///
/// Clasifica ella misma, con los umbrales del catálogo, para que los hallazgos y los requisitos
/// no puedan venir de dos catálogos distintos.
public struct SessionAssessment: Sendable, Hashable {

    public let catalogue: RequirementCatalogue

    public let findings: SessionFindings

    /// Uno por requisito del catálogo, en su orden.
    public let requirements: [RequirementAssessment]

    /// Los parámetros son los de `FindingsClassifier.classify`; `flows` tienen que ser **todos**
    /// los de la sesión.
    public init(
        catalogue: RequirementCatalogue,
        flows: [StoredFlow],
        project: AuditProject,
        session: AuditSession,
        markers: [SessionMarker]
    ) {
        let findings = FindingsClassifier.classify(
            flows: flows,
            project: project,
            session: session,
            markers: markers,
            policy: catalogue.policy
        )
        self.catalogue = catalogue
        self.findings = findings
        self.requirements = catalogue.requirements.map { $0.assess(findings) }
    }
}
