import Foundation

/// Qué protocolo se vio viajar sin cifrar. Hoy solo hay uno que la herramienta sepa reconocer; el
/// tipo existe para que el hallazgo diga **qué** se vio y no solo que algo iba en claro.
public enum CleartextProtocol: String, Sendable, Hashable, Codable {
    /// El stream empezó por una línea de petición de HTTP legible (`StreamOpening.httpRequest`).
    case http
}

/// Qué prueba que un flujo iba cifrado.
public enum EncryptionBasis: Sendable, Hashable {
    /// El cliente abrió con un handshake de TLS, o hay cualquier otra lectura que solo existe si
    /// lo hubo: su oferta, la respuesta del servidor, o un desenlace de inspección.
    case tls
    /// El flujo habla una versión de QUIC de las que se sabe que cifran todo lo que transportan.
    case quic(QUICVersion)
}

/// Por qué no se pudo decir si un flujo iba cifrado.
public enum EncryptionGap: Sendable, Hashable {
    /// El stream TCP empezó por algo que no es ni TLS ni HTTP. Puede ir cifrado a su manera (SSH,
    /// Noise) o no: no se afirma ninguna de las dos cosas.
    case unrecognisedOpening
    /// No se leyó el arranque del stream TCP: el dispositivo no llegó a mandar bytes suficientes,
    /// la conexión ya estaba abierta cuando el túnel arrancó, o el flujo se grabó antes de que el
    /// arranque se leyera. En el 443 el estado `encrypted` lo pone el puerto y no cuenta.
    case openingNotRead
    /// La versión de QUIC no es una de las que se sabe que cifran.
    case unrecognisedQUICVersion(QUICVersion)
    /// Un flujo UDP sin cabecera larga de QUIC reconocida. Fuera de eso, de un datagrama no se
    /// mira nada: aquí cae también el DNS del puerto 53.
    case datagramsNotRead
}

/// Lo que se puede decir de si **un** flujo iba cifrado.
///
/// `cleartext` solo sale de una **observación**: alguien vio una petición de HTTP legible. Ni el
/// puerto ni el estado del flujo bastan —`TLSInspectionStatus` nace del puerto—, así que todo lo
/// que no se vio es `notAssessed` con su motivo, nunca «en claro» y nunca «cifrado».
public enum EncryptionAssessment: Sendable, Hashable {

    case cleartext(CleartextProtocol)
    case encrypted(EncryptionBasis)
    case notAssessed(EncryptionGap)

    /// Ni TCP ni UDP: no hay stream ni datagrama de aplicación que mirar.
    case notApplicable

    public init(of flow: StoredFlow) {
        // Lo visto en claro manda sobre cualquier otra cosa que el flujo lleve apuntada.
        if flow.streamOpening == .httpRequest {
            self = .cleartext(.http)
            return
        }
        switch flow.key.proto {
        case .tcp:
            if Self.showsTLS(flow) {
                self = .encrypted(.tls)
            } else if flow.streamOpening == .unrecognised {
                self = .notAssessed(.unrecognisedOpening)
            } else {
                self = .notAssessed(.openingNotRead)
            }
        case .udp:
            guard let quic = flow.quic else {
                self = .notAssessed(.datagramsNotRead)
                return
            }
            self = quic.version.hasKnownPacketProtection
                ? .encrypted(.quic(quic.version))
                : .notAssessed(.unrecognisedQUICVersion(quic.version))
        case .icmp, .icmpv6, .other:
            self = .notApplicable
        }
    }

    /// Hay alguna lectura que solo existe si el cliente negoció TLS. El estado `encrypted` **no**
    /// está en la lista: en TCP contra el 443 lo pone el puerto.
    private static func showsTLS(_ flow: StoredFlow) -> Bool {
        flow.streamOpening == .tlsHandshake
            || flow.clientTLS != nil
            || flow.serverTLS != nil
            || flow.tlsStatus == .inspected
            || flow.tlsStatus == .notInspectable
    }
}
