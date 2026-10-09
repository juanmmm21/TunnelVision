import Foundation

/// Cómo se redacta en el paquete lo que un hallazgo afirma y lo que un veredicto dice.
///
/// Está en un solo sitio porque cada frase es un límite que costó decidir: lo que se observó, y
/// ni una palabra más. Un hallazgo de pinning habla de un host y no de la app; uno de tráfico en
/// claro, de una petición que se vio y no de un puerto; y ningún veredicto dice que un requisito
/// se cumple, porque eso lo pone quien evalúa. El informe en PDF lee estas mismas frases.
public enum EvidenceWording {

    /// Va al principio de `findings.json`.
    public static let verdictsNote =
        "A verdict states what the recorded traffic showed, within the toolCoverage of its "
        + "requirement. It is not a test result: the results of TR-03161 are the assessor's to give. "
        + "No verdict states that a requirement is met, and a requirement with no applicable "
        + "observation is not assessed by this tool."

    public static func statement(of verdict: RequirementVerdict) -> String {
        switch verdict {
        case .contradicted:
            return "Contradicted by observations of this session."
        case .observedWithoutContradiction:
            return "Observed without contradiction, within what the tool looks at for this requirement."
        case .notAssessed(.outsideToolScope):
            return "Not assessed by this tool."
        case .notAssessed(.nothingObserved):
            return "Not assessed by this tool: nothing in this session could be looked at for it."
        }
    }

    /// - Parameter policy: la política con la que se clasificó: el mínimo de TLS que cita un
    ///   hallazgo de versión es el suyo.
    public static func statement(of evidence: FindingEvidence, policy: FindingsPolicy) -> String {
        switch evidence {
        case .weakTLSVersion(let observation):
            return weakTLSStatement(observation, minimum: policy.minimumTLSVersion)
        case .cleartextTraffic(.http):
            return "An HTTP request was observed in the clear."
        case .hostNotInAllowlist:
            return "A connection went to a host that the project's allowlist does not cover."
        case .unnamedFlow(.serverNameNotAnnounced):
            return "A connection has no name to compare with the allowlist: its ClientHello announced none."
        case .unnamedFlow(.encryptedClientHello):
            return "A connection has no name to compare with the allowlist: its ClientHello announced "
                + "none and carried Encrypted Client Hello, so the name may be encrypted."
        case .unnamedFlow(.noClientHelloRead):
            return "A connection has no name to compare with the allowlist: no ClientHello was read "
                + "from it and no DNS reply seen by the tunnel named its address."
        case .pinningAbsent:
            return "A connection to this host accepted a certificate issued by the local CA: for "
                + "this host, a user-installed root is trusted."
        case .pinningObserved:
            // Del host y no de la app: tras el primer rechazo el relay no vuelve a intentarlo.
            return "A connection to this host refused the local CA's certificate. The statement is "
                + "about the host: after a refusal the tunnel does not try that host again, so the "
                + "refusal may predate this session."
        case .activityBeforeConsent:
            return "A connection was opened before every consent marker of the session."
        }
    }

    private static func weakTLSStatement(
        _ observation: TLSVersionObservation,
        minimum: TLSProtocolVersion
    ) -> String {
        let floor = EvidenceTLSVersion.publishedName(of: minimum) ?? "the minimum"
        switch observation.basis {
        case .serverHello:
            return "A connection negotiated a TLS version below \(floor)."
        case .upstreamConnection:
            return "The server negotiated a TLS version below \(floor) with the tunnel's own "
                + "connection, which offers the current versions."
        case .quic:
            return "A QUIC connection carries a TLS version below \(floor)."
        }
    }
}
