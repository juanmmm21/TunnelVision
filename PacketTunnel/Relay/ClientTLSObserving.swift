import Foundation
import Shared

/// Por dónde sale del relay lo que el **cliente ofreció** en el ClientHello de un flujo: las
/// versiones de TLS que acepta y sus protocolos de aplicación.
///
/// Es la tercera costura sobre el mismo handshake, del mismo corte que `SNIObserving` y
/// `ServerTLSObserving`, y existe por lo mismo: el relay tiene el stream saliente en orden y la
/// tabla de flujos es del pipeline.
///
/// **No se fundió con `SNIObserving`** aunque las dos lecturas salgan del mismo mensaje y en el
/// mismo instante: una existe sin la otra. Un ClientHello sin extensión de nombre —una conexión a
/// una IP pelada— no pasa nunca por `observe(sni:)` y aun así ha dicho qué versiones acepta, que
/// es justo el flujo del que un informe no tiene otra cosa que citar.
///
/// Es `async` por la misma razón que sus hermanas, y se llama **una sola vez por flujo**, en cuanto
/// el ClientHello está completo. Un ClientHello cuya oferta no se dejó leer no pasa por aquí: el
/// flujo se queda sin nada apuntado, que no es lo mismo que una oferta vacía.
public protocol ClientTLSObserving: Sendable {
    func observe(clientTLS: ClientTLSOffer, for key: FlowKey) async
}
