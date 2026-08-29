import Foundation

/// Errores tipados del interceptor TLS. Todos representan una razón **transitoria** por la que un
/// flujo candidato no se pudo inspeccionar (a diferencia del pinning, que es permanente y se
/// modela como resultado, no como error): el llamante los trata igual —relaya el flujo intacto
/// **sin** marcarlo `notInspectable`, porque la causa puede desaparecer (el usuario instala la CA,
/// el ClientHello siguiente trae SNI, el fallo de red se resuelve)—.
///
/// Desviación consciente sobre el boceto de la spec (`noCA`, `handshakeWithServerFailed`,
/// `userspaceStackError`): se añade `noSNI`. Sin el host del ClientHello no se puede emitir el leaf
/// del SNI (`LocalCA.mintLeaf(forHost:)`), así que es una precondición propia del interceptor tan
/// real como la de la CA; tratarla como un error transitorio distinto la hace explícita en vez de
/// enterrarla en `userspaceStackError`.
public enum TLSInterceptError: Error, Sendable, Equatable {
    /// La CA local no está lista (no generada, o no instalada+confiada por el usuario). El interceptor
    /// no puede presentar un leaf de confianza, así que no lo intenta (precondición 3 de la spec).
    case noCA
    /// El ClientHello no traía SNI (o venía vacío): no hay host para el que emitir el leaf.
    case noSNI
    /// El cliente confió en nuestro leaf, pero el handshake TLS **contra el servidor real** falló
    /// (bajo confianza del sistema normal, como cualquier cliente). No es pinning del cliente.
    case handshakeWithServerFailed
    /// Fallo técnico del stack TLS userspace (no atribuible a pinning ni al servidor).
    case userspaceStackError
}

/// Resultado que devuelve la cáscara de terminación (`TLSTerminationEngine`) tras intentar terminar
/// un flujo: el desenlace del handshake **de cliente** contra nuestro servidor userspace y, si el
/// cliente confió, del handshake **de servidor** contra el destino real. Es un valor puro y
/// `Sendable` justo para mantener la decisión (abajo) separada del I/O, igual que `TCPRelayAction`
/// separa la máquina de estados TCP de la conexión real.
public enum TLSTerminationOutcome: Sendable, Equatable {
    /// El cliente confió en nuestro leaf y el flujo se terminó e inspeccionó de punta a punta.
    case inspected
    /// El cliente **rechazó** nuestro leaf: la app pinnea su certificado. Es el caso del ADR 0003 —
    /// no es un fallo, es el sistema de seguridad de la otra app funcionando— y se traduce en
    /// `notInspectable` + passthrough **sin reintentos**.
    case pinned
    /// El cliente confió, pero no pudimos completar el TLS contra el servidor real.
    case serverHandshakeFailed
    /// Fallo técnico del stack userspace durante la terminación.
    case userspaceStackError
}

/// Núcleo **puro y testeable** del interceptor TLS: toda la política de decisión sin nada de red,
/// Keychain ni `SecIdentity`. Es la mitad Simulator-testeable de `TLSInterceptor` (la otra mitad, el
/// I/O del handshake userspace, es la cáscara device-only), el mismo reparto que
/// `PacketPipeline`→`PacketTunnelProvider`, `TCPRelayFlow`→`Relay` y `CertificateAuthority`→`LocalCA`.
///
/// Concentra dos decisiones que **no pueden violarse** (son el corazón de seguridad del proyecto,
/// ver `docs/decisions/0003-no-third-party-pinning-bypass.md`):
///
/// 1. **Precondiciones (gate):** qué flujos son elegibles para intentar la terminación. El pipeline
///    (`PacketPipeline.route`, ya testeado) es dueño de tres —inspección activada, TCP contra el 443,
///    y flujo no marcado ya `notInspectable`— y solo enruta a `.inspect` los que las cumplen; aquí se
///    verifican las **residuales del interceptor**: que la CA esté lista y que haya SNI. No se
///    reverifican las del pipeline para no duplicar su contrato.
/// 2. **Resolución (decide):** cómo se traduce el desenlace del handshake a la acción final,
///    **incluido el invariante de pinning**: un cliente que rechaza ⇒ `notInspectable` + passthrough,
///    y **nunca** se reintenta forzarlo.
public enum TLSInterceptionPolicy {

    /// Qué hacer antes de tocar la red, según las precondiciones residuales del interceptor.
    public enum Gate: Sendable, Equatable {
        /// Todas las precondiciones se cumplen: terminar el flujo presentando el leaf de `sni`.
        case attempt(sni: String)
        /// Alguna precondición transitoria falla: no intentar; el llamante relaya intacto sin marcar.
        case abort(TLSInterceptError)
    }

    /// Decide si intentar la terminación. `caReady` lo aporta la app (sabe si el usuario instaló y
    /// confió el certificado raíz en Ajustes; la extensión por sí sola solo sabe si la clave existe),
    /// así que se pasa como estado, no se infiere de `LocalCA`.
    public static func gate(caReady: Bool, clientHelloSNI: String?) -> Gate {
        guard caReady else { return .abort(.noCA) }
        // Un SNI presente pero vacío es tan inservible como su ausencia: no hay host que emitir.
        guard let sni = clientHelloSNI, !sni.isEmpty else { return .abort(.noSNI) }
        return .attempt(sni: sni)
    }

    /// Qué acción final corresponde tras terminar el flujo. Separada del resultado del actor para
    /// poder probar el mapeo (incluido el de pinning) sin montar el actor entero.
    public enum Decision: Sendable, Equatable {
        /// El flujo se inspeccionó: el actor devuelve `.inspected`.
        case inspected
        /// Pinning: el actor devuelve `.notInspectable` y el llamante relaya intacto + marca el flujo.
        case notInspectable
        /// Una razón transitoria: el actor lanza este error y el llamante relaya intacto sin marcar.
        case fail(TLSInterceptError)
    }

    /// Traduce el desenlace del handshake a la acción final. El caso `pinned` es el invariante del
    /// ADR 0003: se resuelve como `notInspectable`, nunca como un error que invitase a reintentar.
    public static func decide(_ outcome: TLSTerminationOutcome) -> Decision {
        switch outcome {
        case .inspected: return .inspected
        case .pinned: return .notInspectable
        case .serverHandshakeFailed: return .fail(.handshakeWithServerFailed)
        case .userspaceStackError: return .fail(.userspaceStackError)
        }
    }
}
