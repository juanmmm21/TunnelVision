import Foundation

/// Errores del parser de paquetes IP. Todos son estructurales: describen un datagrama que no
/// se puede interpretar. El protocolo de transporte no soportado **no** es uno de estos errores
/// en el hot path (ver `PacketParser`): se devuelve un `ParsedPacket` sin L4 y el caller decide.
public enum PacketParseError: Error, Sendable, Equatable {
    /// El buffer es más corto que el mínimo necesario para la fase indicada.
    case tooShort(expected: Int, got: Int)
    /// El nibble de versión IP no es 4 ni 6.
    case unsupportedVersion(UInt8)
    /// La longitud de cabecera declarada es incoherente (IHL/data-offset fuera de rango, o
    /// una cadena de extension headers IPv6 absurdamente larga).
    case badHeaderLength
    /// La cabecera de transporte (o una extension header IPv6) se extiende más allá de los
    /// bytes realmente presentes en el datagrama.
    case truncatedL4
    /// Protocolo de transporte no soportado. Reservado para el contrato público: el parser
    /// **no** lo lanza en el camino caliente (colapsa a `.other`/`.icmp` y devuelve L4 ausente),
    /// pero se expone para que un caller que quiera tratar el passthrough como error pueda hacerlo.
    case unsupportedProtocol(UInt8)
}
