import Foundation

/// Por qué un flujo no tiene nombre. Es lo que se puede decir **mirando el flujo**; los tres casos
/// implican además que ninguna respuesta de DNS vista por el túnel había nombrado su dirección.
///
/// Que no hubiera DNS que leer (cifrado) no está aquí: es un hecho de la sesión, lo dicen unos
/// contadores del túnel que no se guardan con ella, y un flujo no lo lleva apuntado.
public enum UnnamedFlowReason: String, Sendable, Hashable, Codable {
    /// Se leyó el ClientHello y no anunciaba ningún nombre: es lo que hace una conexión abierta
    /// contra una dirección escrita a mano.
    case serverNameNotAnnounced
    /// Se leyó el ClientHello, no anunciaba nombre y llevaba Encrypted Client Hello: el nombre de
    /// verdad puede ir cifrado dentro.
    case encryptedClientHello
    /// No se leyó ningún ClientHello del que sacar un nombre: el flujo no es TLS sobre TCP (QUIC,
    /// otro protocolo), o su handshake pasó antes de la captura o no se dejó recorrer.
    case noClientHelloRead
}

/// Por qué no se pudo decir si el destino de un flujo con nombre estaba en la allowlist.
public enum HostGap: Sendable, Hashable {
    /// El proyecto no tiene allowlist escrita: no hay contra qué juzgar, y llamar «inesperadas» a
    /// todas las conexiones sería afirmar una decisión que el evaluador no ha tomado.
    case allowlistEmpty
    /// El nombre se dedujo del DNS y la dirección la compartían nombres de dentro y de fuera de la
    /// allowlist: el flujo pudo ser de cualquiera. `attributedNameAllowed` dice de qué lado cae el
    /// nombre que se le atribuyó (el resuelto más recientemente).
    case candidatesDisagree(attributedNameAllowed: Bool)
}

/// Lo que se puede decir del destino de **un** flujo frente a la allowlist de un proyecto.
///
/// Aplica a todos los flujos —todos fueron a algún sitio—, así que no hay caso «no aplica»: un
/// flujo sin nombre no se aparta de la comprobación, es un hallazgo con su motivo.
public enum HostAssessment: Sendable, Hashable {

    /// El flujo fue a un host que ninguna entrada de la allowlist cubre. El host va normalizado
    /// (`DomainPattern.normalised(host:)`). Con un nombre deducido del DNS solo se da cuando
    /// **ningún** candidato de la dirección está cubierto, y el host es el que se le atribuyó.
    case notInAllowlist(host: String)

    /// El flujo no tiene nombre, así que no hay nada que comparar con la allowlist.
    case unnamed(UnnamedFlowReason)

    /// El nombre del flujo está cubierto por la allowlist, y si era deducido del DNS lo están
    /// también todos los demás candidatos de su dirección.
    case allowed

    case notAssessed(HostGap)

    public init(of flow: StoredFlow, project: AuditProject) {
        guard let name = flow.name else {
            self = .unnamed(Self.unnamedReason(of: flow))
            return
        }
        guard !project.allowlist.isEmpty else {
            self = .notAssessed(.allowlistEmpty)
            return
        }
        let attributedAllowed = project.allowlistEntry(matching: name.text) != nil
        // Que el ganador esté autorizado no autoriza a los demás, y al revés: mientras los
        // candidatos no digan todos lo mismo, del destino del flujo no se afirma nada.
        let othersAgree = name.otherCandidates.allSatisfy {
            (project.allowlistEntry(matching: $0) != nil) == attributedAllowed
        }
        guard othersAgree else {
            self = .notAssessed(.candidatesDisagree(attributedNameAllowed: attributedAllowed))
            return
        }
        self = attributedAllowed ? .allowed : .notInAllowlist(host: DomainPattern.normalised(host: name.text))
    }

    private static func unnamedReason(of flow: StoredFlow) -> UnnamedFlowReason {
        guard let offer = flow.clientTLS else { return .noClientHelloRead }
        return offer.hasEncryptedClientHello ? .encryptedClientHello : .serverNameNotAnnounced
    }
}
