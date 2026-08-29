import Foundation

/// Resultado de parsear un datagrama IP completo.
///
/// Valor transitorio del hot path: agrupa las cabeceras ya normalizadas a host-order y la
/// identidad de flujo canónica. Los `payloadRange` de las cabeceras referencian el buffer
/// original (offsets 0-based sobre el datagrama pasado a `PacketParser.parse`), sin copiar el
/// payload. `tcp`/`udp` son `nil` cuando no hay capa de transporte inspeccionable: protocolo no
/// soportado (ICMP, etc.) o fragmento no-inicial sin cabecera L4.
public struct ParsedPacket: Sendable, Hashable {
    public let ip: IPHeader
    public let tcp: TCPHeader?
    public let udp: UDPHeader?
    public let flowKey: FlowKey
    public let source: IPEndpoint       // origen tal cual viene en el paquete
    public let destination: IPEndpoint  // destino tal cual viene en el paquete

    public init(
        ip: IPHeader,
        tcp: TCPHeader?,
        udp: UDPHeader?,
        flowKey: FlowKey,
        source: IPEndpoint,
        destination: IPEndpoint
    ) {
        self.ip = ip
        self.tcp = tcp
        self.udp = udp
        self.flowKey = flowKey
        self.source = source
        self.destination = destination
    }
}
