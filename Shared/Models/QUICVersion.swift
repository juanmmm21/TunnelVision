import Foundation

/// Una versión de QUIC tal y como viaja en la cabecera larga: cuatro bytes (RFC 8999 § 5.1).
///
/// Es una estructura sobre el valor crudo y no un enum cerrado por lo mismo que
/// `TLSProtocolVersion`: el valor lo elige el otro extremo, y un borrador, una versión de un
/// fabricante o un número inventado para forzar una negociación (RFC 9000 § 15) son evidencia que
/// se conserva tal cual. `0` no es una versión —es la marca de un paquete Version Negotiation— y
/// quien lee la cabecera no la entrega.
public struct QUICVersion: RawRepresentable, Sendable, Hashable, Codable {

    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    // Los dos valores están comprobados contra el registro «QUIC Versions» de IANA
    // (https://www.iana.org/assignments/quic), que es de donde salen, no de memoria.

    /// QUIC versión 1 (RFC 9000).
    public static let v1 = QUICVersion(rawValue: 0x0000_0001)
    /// QUIC versión 2 (RFC 9369).
    public static let v2 = QUICVersion(rawValue: 0x6b33_43cf)

    /// La versión es una de las que esta herramienta **sabe** que cifran todo lo que transportan:
    /// las dos del IETF, que protegen cada paquete con TLS 1.3 (RFC 9001, RFC 9369 § 3).
    ///
    /// De cualquier otro número —los provisionales del registro, un borrador, uno desconocido— no
    /// se afirma nada: unos bytes con forma de cabecera larga y una versión que no se conoce no
    /// prueban que el flujo vaya cifrado, y decirlo sin saberlo escondería justo lo que una
    /// auditoría busca. Si el registro gana una versión, se añade aquí.
    public var hasKnownPacketProtection: Bool {
        self == .v1 || self == .v2
    }
}

/// Qué extremo mandó la cabecera larga de la que se leyó una versión de QUIC.
///
/// Importa porque no dicen lo mismo: la del cliente es la versión que **propuso**, y el servidor
/// puede no aceptarla (contesta con un Version Negotiation y el cliente repite con otra) o
/// cambiarla por una compatible (RFC 9368); la del servidor es la que el servidor **está
/// hablando**.
public enum QUICVersionSource: String, Sendable, Hashable, Codable {
    case client
    case server
}

/// La versión de QUIC de un flujo, con el extremo del que se leyó.
public struct QUICVersionReading: Sendable, Hashable, Codable {

    public let version: QUICVersion
    public let source: QUICVersionSource

    public init(version: QUICVersion, source: QUICVersionSource) {
        self.version = version
        self.source = source
    }

    /// Si esta lectura debe quedarse en el sitio de la que el flujo ya llevaba.
    ///
    /// Una del servidor sustituye a cualquiera: es la versión en uso, y si cambia es que hay una
    /// conexión nueva sobre la misma 5-tupla. Una del cliente solo sustituye a otra del cliente
    /// —el reintento tras un Version Negotiation—, nunca a una del servidor: lo que el cliente
    /// propone no desmiente lo que el servidor ya contestó.
    public func replaces(_ current: QUICVersionReading?) -> Bool {
        guard let current else { return true }
        switch source {
        case .server: return true
        case .client: return current.source == .client
        }
    }
}
