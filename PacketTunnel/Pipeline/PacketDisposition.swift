import Foundation
import Shared

/// Qué debe hacer el provider con un paquete después de que el pipeline lo haya registrado.
///
/// El pipeline **observa y decide**; no toca la red. Quien relaya (M8) o reinyecta con
/// `packetFlow.writePackets` es el provider, a partir de esta decisión.
///
/// Las dos rutas que reenvían llevan dentro el `ParsedPacket`: el relay lo necesita ya parseado
/// (endpoints, cabecera de transporte y rangos del payload) y el provider no tiene por qué volver a
/// parsear en el hot path un datagrama que el pipeline acaba de parsear.
public enum PacketDisposition: Sendable, Equatable {
    /// Relayar el datagrama intacto hacia internet. Es la ruta por defecto y la única para UDP,
    /// TCP fuera del 443, flujos ya marcados `notInspectable` y toda la sesión con la inspección
    /// desactivada.
    case passthrough(ParsedPacket)
    /// Entregar a la ruta TCP+TLS en userspace (M8): TCP hacia/desde el 443, con inspección
    /// activada y sin que el flujo haya rechazado ya la CA local.
    case inspect(ParsedPacket)
    /// El paquete no se reenvía. Se cuenta en `PipelineStats.packetsDropped`.
    case dropped(DropReason)

    /// El paquete que hay que entregarle al relay, o `nil` si el datagrama muere aquí.
    ///
    /// **Dice qué se reenvía, no por qué puerta.** Las dos rutas van al relay, pero desde el enganche
    /// de la inspección (2026-08-12) van por puertas distintas —`Relay.passthrough` y `Relay.inspect`,
    /// que es lo que abre el flujo como candidato a terminación—, así que el provider distingue el
    /// caso en vez de usar esto. Sigue aquí porque la pregunta "¿esto se reenvía?" tiene una sola
    /// respuesta y merece un solo sitio.
    public var packetToRelay: ParsedPacket? {
        switch self {
        case .passthrough(let packet), .inspect(let packet): return packet
        case .dropped: return nil
        }
    }
}

/// Por qué se descartó un paquete. Un descarte siempre es explícito y contable: nunca se traga.
public enum DropReason: Sendable, Equatable {
    /// El datagrama no se pudo interpretar (truncado, versión IP desconocida...).
    case parseFailed(PacketParseError)
    /// El parser lanzó algo que no es un `PacketParseError`. Inalcanzable con el contrato actual;
    /// existe para no tener que elegir entre un `fatalError` en el hot path y un error inventado.
    case unparseable
    /// No hay dirección local configurada para la familia del paquete, así que no se puede
    /// determinar el sentido. Ocurre si el túnel se levanta solo con IPv4 y llega tráfico IPv6.
    case noLocalAddress(IPVersion)
}

// `PipelineStats` vive en `Shared/IPC/ControlChannel.swift`: son los contadores que la app pide por
// el canal de control, así que forman parte del contrato entre procesos, no del pipeline.
