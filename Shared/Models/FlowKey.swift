import Foundation

/// Identidad canónica de un flujo (5-tupla), independiente del sentido del paquete.
///
/// La canonicalización ordena los dos endpoints de forma estable (`endpointA <= endpointB`)
/// para que un paquete outbound y su respuesta inbound produzcan la MISMA clave; así la tabla
/// de flujos ve ambos sentidos como un único flujo. Por esa razón `FlowKey` **no** puede
/// almacenar nada dependiente del sentido: el sentido real (dispositivo↔internet) se reconstruye
/// con `direction(ofPacketFrom:localAddress:)`, que necesita conocer la dirección local.
public struct FlowKey: Sendable, Hashable, Codable {
    public let proto: IPProtocolNumber
    public let endpointA: IPEndpoint   // menor según orden canónico
    public let endpointB: IPEndpoint   // mayor según orden canónico

    /// Construye la clave canónica a partir del par (origen, destino) tal como vienen en el
    /// paquete. El orden de los argumentos es irrelevante para la identidad resultante:
    /// `FlowKey(proto:source:destination:)` y `FlowKey(proto:destination:source:)` son iguales.
    public init(proto: IPProtocolNumber, source: IPEndpoint, destination: IPEndpoint) {
        self.proto = proto
        if source <= destination {
            self.endpointA = source
            self.endpointB = destination
        } else {
            self.endpointA = destination
            self.endpointB = source
        }
    }

    /// Reconstruye el sentido de un paquete a partir del endpoint origen del paquete y de la
    /// dirección IP local del dispositivo: `.outbound` si el paquete sale del dispositivo
    /// (su origen es la IP local), `.inbound` en caso contrario.
    ///
    /// Requiere `localAddress` porque, siendo `FlowKey` canónico, la clave por sí sola no sabe
    /// cuál de los dos endpoints es el dispositivo. Precondición: `source` es uno de los dos
    /// endpoints de este flujo (es un error consultar el sentido de un paquete ajeno a la clave).
    public func direction(ofPacketFrom source: IPEndpoint, localAddress: IPAddress) -> Direction {
        precondition(
            source == endpointA || source == endpointB,
            "El endpoint origen \(source) no pertenece a este flujo (\(endpointA) / \(endpointB))"
        )
        return source.address == localAddress ? .outbound : .inbound
    }
}
