import Foundation
import Shared

/// Un host del "quién está hablando ahora" de la Dashboard (`docs/ux/screens.md`), con lo que ha
/// movido en la ventana de paquetes recientes que el feed en vivo mantiene.
public struct TopTalker: Sendable, Hashable, Identifiable {

    /// Dirección del host remoto. Se agrega **por dirección y no por flujo**: al usuario le importa
    /// con quién habla el dispositivo, no cuántas conexiones abrió el navegador contra el mismo sitio.
    public let address: IPAddress

    public let bytesIn: UInt64
    public let bytesOut: UInt64
    public let packetCount: UInt64

    /// Conexiones distintas vistas contra ese host en la ventana.
    public let flowCount: Int

    public init(
        address: IPAddress,
        bytesIn: UInt64,
        bytesOut: UInt64,
        packetCount: UInt64,
        flowCount: Int
    ) {
        self.address = address
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.packetCount = packetCount
        self.flowCount = flowCount
    }

    public var id: IPAddress { address }

    /// Lo que encabeza la fila. En el feed en vivo no hay SNI —el ring no lo lleva—, así que es la IP;
    /// el nombre del host lo enseña la Timeline, que lee del store.
    public var displayHost: String { address.description }

    public var totalBytes: UInt64 { bytesIn &+ bytesOut }
}

/// La agregación de los paquetes recientes en hosts, que es lo único que la Dashboard necesita del
/// feed más allá del gráfico y los contadores.
///
/// Es pura y trabaja sobre la lista acotada que publica `LiveFeedSnapshot.recent`
/// (`LiveFeedPolicy.recentPacketCapacity`), así que su coste está acotado por construcción: no crece
/// con el tráfico, crece con el tamaño de esa ventana.
public enum TopTalkers {

    /// Los `limit` hosts que más han movido, de mayor a menor.
    ///
    /// Los paquetes cuyos extremos no se pudieron repartir se **descartan**: sin saber cuál de los dos
    /// lados es el dispositivo, atribuirle bytes a uno de ellos sería inventarse el dato — la misma
    /// regla que aplica `LiveFeedAddressing` al devolver `nil` en vez de adivinar.
    public static func compute(from packets: [LivePacket], limit: Int) -> [TopTalker] {
        precondition(limit > 0, "limit debe ser positivo")

        var bytesIn: [IPAddress: UInt64] = [:]
        var bytesOut: [IPAddress: UInt64] = [:]
        var packetCounts: [IPAddress: UInt64] = [:]
        var flows: [IPAddress: Set<FlowKey>] = [:]

        for packet in packets {
            guard let remote = packet.remoteEndpoint else { continue }
            let address = remote.address
            switch packet.direction {
            case .inbound:
                bytesIn[address, default: 0] &+= UInt64(packet.length)
            case .outbound:
                bytesOut[address, default: 0] &+= UInt64(packet.length)
            }
            packetCounts[address, default: 0] &+= 1
            flows[address, default: []].insert(packet.flowKey)
        }

        let talkers = packetCounts.keys.map { address in
            TopTalker(
                address: address,
                bytesIn: bytesIn[address] ?? 0,
                bytesOut: bytesOut[address] ?? 0,
                packetCount: packetCounts[address] ?? 0,
                flowCount: flows[address]?.count ?? 0
            )
        }

        // El desempate por dirección no es estético: sin un orden total, dos hosts empatados podrían
        // intercambiarse entre instantáneas y la lista parpadearía sola.
        return talkers
            .sorted { lhs, rhs in
                if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes > rhs.totalBytes }
                return lhs.address < rhs.address
            }
            .prefix(limit)
            .map { $0 }
    }
}
