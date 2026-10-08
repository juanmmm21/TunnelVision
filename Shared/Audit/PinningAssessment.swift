import Foundation

/// Por qué no se pudo decir nada del pinning de un flujo al que la comprobación aplicaba.
///
/// Van de lo más general a lo más concreto, y un flujo se lleva el primero que le toca: en una
/// sesión sin inspección no se llega a preguntar si el flujo era QUIC.
public enum PinningGap: String, Sendable, Hashable, Codable {
    /// La sesión se grabó con la inspección apagada: no hubo handshake contra la CA local.
    case inspectionOff
    /// La inspección estaba encendida y la CA sin confiar: **toda** app la rechaza, pinnee o no,
    /// así que un rechazo no dice nada de la app.
    case caNotTrusted
    /// El flujo es QUIC, y la inspección solo termina TLS sobre TCP.
    case quicNotInspected
    /// El flujo muestra TLS sobre TCP y no lleva desenlace de inspección: no era candidato (fuera
    /// del 443, sin nombre anunciado), el intento falló por algo que no era la app, o la conexión
    /// no llegó a cerrarse limpia. No se intentó o no se supo, que no es lo mismo que aceptar.
    case noInspectionOutcome
    /// El flujo lleva un desenlace y no el nombre que anunció, que es para el que se emitió el
    /// certificado: no se puede decir de qué host es la observación.
    case outcomeWithoutAnnouncedName
}

/// Lo que se puede decir del pinning en **un** flujo, leyendo lo que el relay dejó apuntado.
///
/// No se salta el pinning de nadie (ADR 0003): los dos desenlaces de un intento de inspección ya
/// son la observación. Que la app aceptara el certificado de la CA local dice que confía en una
/// raíz instalada por el usuario; que lo rechazara, que no.
public enum PinningAssessment: Sendable, Hashable {

    /// La conexión aceptó un certificado emitido por la CA local para `host`: para ese host la app
    /// confía en una raíz instalada por el usuario. El host va normalizado.
    case absent(host: String)

    /// Una conexión a `host` rechazó el certificado de la CA local. **Es del host, no de esta
    /// conexión**: tras el primer rechazo el relay no vuelve a intentarlo con ese host mientras
    /// dure el túnel, y marca igual los flujos siguientes sin haberlos probado.
    case observed(host: String)

    case notAssessed(PinningGap)

    /// El flujo no muestra TLS ni QUIC: no hay certificado que una app pudiera fijar. Como en la
    /// versión de TLS, **no es una afirmación de que fuese en claro**.
    case notApplicable

    public init(of flow: StoredFlow, conditions: InspectionConditions) {
        guard Self.applies(to: flow) else {
            self = .notApplicable
            return
        }
        guard conditions.inspectionEnabled else {
            self = .notAssessed(.inspectionOff)
            return
        }
        guard conditions.caTrusted else {
            self = .notAssessed(.caNotTrusted)
            return
        }
        switch flow.tlsStatus {
        case .inspected:
            self = Self.announcedHost(of: flow).map { .absent(host: $0) }
                ?? .notAssessed(.outcomeWithoutAnnouncedName)
        case .notInspectable:
            self = Self.announcedHost(of: flow).map { .observed(host: $0) }
                ?? .notAssessed(.outcomeWithoutAnnouncedName)
        case .plaintext, .encrypted:
            self = .notAssessed(flow.quic != nil ? .quicNotInspected : .noInspectionOutcome)
        }
    }

    /// Un desenlace de inspección solo existe si hubo TLS, y manda sobre todo lo demás. Sin él,
    /// una petición de HTTP vista en claro descarta el flujo aunque su puerto le pusiera
    /// `encrypted`; y el resto es la misma señal de TLS que lee la comprobación de la versión.
    private static func applies(to flow: StoredFlow) -> Bool {
        if flow.tlsStatus == .inspected || flow.tlsStatus == .notInspectable { return true }
        if flow.quic != nil { return true }
        guard flow.key.proto == .tcp, flow.streamOpening != .httpRequest else { return false }
        return flow.tlsStatus != .plaintext
            || flow.streamOpening == .tlsHandshake
            || flow.clientTLS != nil
            || flow.serverTLS != nil
    }

    /// El nombre que la conexión anunció, normalizado. Un nombre deducido del DNS no sirve aquí:
    /// el certificado que la app aceptó o rechazó se emitió para el SNI.
    private static func announcedHost(of flow: StoredFlow) -> String? {
        guard let name = flow.name, name.origin == .sni else { return nil }
        return DomainPattern.normalised(host: name.text)
    }
}
