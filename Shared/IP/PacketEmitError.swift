import Foundation

/// Errores del emisor de datagramas. Ambos son errores de programación del caller, no datos
/// corruptos de la red: describen una petición que no se puede expresar como datagrama IP.
public enum PacketEmitError: Error, Sendable, Equatable {
    /// Origen y destino de familias distintas. No existe datagrama que una una IPv4 con una IPv6;
    /// si esto salta, el estado del flujo se ha mezclado en algún punto del relay.
    case addressFamilyMismatch(source: IPVersion, destination: IPVersion)
    /// El datagrama resultante no cabe en el campo de longitud de la cabecera (16 bits). El caller
    /// debe segmentar respetando la MTU antes de emitir; el emisor no fragmenta.
    case datagramTooLarge(byteCount: Int, limit: Int)
}
