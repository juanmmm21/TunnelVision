import Foundation
import Shared

/// Por dónde sale del relay **con qué empezó** el stream saliente de un flujo TCP: un handshake de
/// TLS, una petición de HTTP en claro, o ninguna de las dos.
///
/// Es del mismo corte que `SNIObserving` y sus hermanas, y existe por lo mismo: el relay tiene el
/// stream en orden y la tabla de flujos es del pipeline.
///
/// **No se fundió con `ClientTLSObserving`** aunque en el 443 las dos miren los mismos primeros
/// bytes: esta lectura existe en **cualquier** puerto, que es justo para lo que se hizo, y de un
/// stream que no es TLS no hay oferta que contar.
///
/// Se llama **una sola vez por flujo**, en cuanto el arranque se deja decidir. Un flujo en el que
/// el dispositivo no llegó a mandar bytes suficientes no pasa por aquí: se queda sin lectura, que
/// no es lo mismo que `unrecognised`.
public protocol StreamOpeningObserving: Sendable {
    func observe(streamOpening: StreamOpening, for key: FlowKey) async
}
