import Foundation

/// Familia de direcciones IP del paquete.
public enum IPVersion: UInt8, Sendable, Codable, Hashable {
    case v4 = 4
    case v6 = 6

    /// Longitud en bytes de una dirección de esta familia.
    public var addressByteCount: Int {
        switch self {
        case .v4: return 4
        case .v6: return 16
        }
    }
}

/// Número de protocolo de la capa de transporte (campo `protocol`/`next header`).
public enum IPProtocolNumber: UInt8, Sendable, Codable, Hashable {
    case tcp = 6
    case udp = 17
    case icmp = 1
    case icmpv6 = 58
    case other = 255   // cualquier otro; el valor real se guarda aparte en `IPHeader.rawProtocol`

    /// Mapea un valor crudo de la cabecera IP a un caso conocido, colapsando cualquier
    /// protocolo no soportado en `.other`. El valor original se conserva aparte
    /// (`IPHeader.rawProtocol`), así que este colapso no pierde información en el hot path.
    public init(wireValue: UInt8) {
        self = IPProtocolNumber(rawValue: wireValue) ?? .other
    }
}

/// Sentido del paquete relativo al dispositivo.
public enum Direction: UInt8, Sendable, Codable, Hashable {
    case outbound = 0   // del dispositivo hacia internet
    case inbound = 1    // de internet hacia el dispositivo
}

/// Estado de inspección TLS de un flujo.
public enum TLSInspectionStatus: UInt8, Sendable, Codable, Hashable {
    case plaintext = 0        // no cifrado (p. ej. HTTP)
    case encrypted = 1        // cifrado y no inspeccionado (inspección off o no es 443)
    case inspected = 2        // cifrado y descifrado con consentimiento vía CA local
    case notInspectable = 3   // rechazó nuestra CA (pinning): se relayea intacto
}
