import Foundation
import Shared

/// Por dónde sale del relay el nombre de host que un flujo TLS anunció en su ClientHello.
///
/// El relay sabe *leer* el nombre —los bytes del handshake pasan por él, ya reensamblados y en
/// orden— pero no sabe nada de flujos guardados: la tabla que agrega un flujo y el store que lo
/// escribe son del pipeline. Esta es la costura entre las dos mitades, y es del mismo corte que los
/// tres sumideros del pipeline (`PipelineSinks.swift`) y que la fábrica de conexiones del propio
/// relay: un protocolo estrecho que el productor recibe inyectado, así que la mitad que decide se
/// ejercita en Simulator contra un doble.
///
/// Es `async` porque quien lo implementa en producción es un actor (`PacketPipeline`) y quien lo
/// llama es otro (`Relay`): el nombre cruza de un aislamiento al otro. Se llama **una sola vez por
/// flujo**, en cuanto el ClientHello está completo, así que no hay orden que preservar ni coste que
/// medir en el camino de un paquete.
public protocol SNIObserving: Sendable {
    func observe(sni: String, for key: FlowKey) async
}
