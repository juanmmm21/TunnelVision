import Foundation

/// Qué ha hecho el túnel con los paquetes Initial de los clientes QUIC que ha visto pasar, y a
/// cuántos flujos les ha leído el nombre de su ClientHello.
///
/// Existe por lo mismo que `DNSNameStats`: para que un flujo QUIC sin nombre tenga explicación.
/// «No anunciaba ninguno» y «no se llegó a leer» no son lo mismo, y sin estas cifras los dos se
/// verían igual desde fuera.
///
/// Vive en `Shared/IPC` porque viaja dentro de `PipelineStats` por el canal de control.
public struct QUICNameStats: Sendable, Equatable, Codable {

    /// Paquetes Initial de un cliente que se abrieron.
    public var initialsOpened: UInt64 = 0
    /// Paquetes Initial que se intentaron abrir y no se dejaron: no autenticaban con las claves
    /// de su conexión ni con las de su propio Connection ID.
    public var initialsNotOpened: UInt64 = 0
    /// Veces que un flujo volvió a empezar con las claves de otro Connection ID: lo que pasa
    /// tras un Retry del servidor.
    public var readsRestarted: UInt64 = 0
    /// Datagramas con forma de Initial que no se miraron porque ya había demasiadas lecturas a
    /// medias a la vez.
    public var initialsSkippedAtCapacity: UInt64 = 0

    /// Flujos a los que se les leyó el nombre.
    public var flowsNamed: UInt64 = 0

    // Un contador por cada forma de quedarse sin nombre: flujos, no paquetes.
    /// Se leyó el ClientHello entero y no anunciaba ningún nombre.
    public var withoutServerName: UInt64 = 0
    /// Lo que llevaba el stream CRYPTO no se dejó leer como un ClientHello, o no cabía.
    public var unreadableClientHello: UInt64 = 0
    /// El stream CRYPTO se saltó uno de sus topes antes de completar el mensaje.
    public var cryptoStreamAbandoned: UInt64 = 0
    /// Se agotaron los Initial que se miran de un flujo sin que el mensaje estuviera completo.
    public var initialsExhausted: UInt64 = 0

    public init() {}

    /// Flujos cuya lectura terminó sin nombre, por el motivo que fuera.
    public var flowsLeftUnnamed: UInt64 {
        withoutServerName &+ unreadableClientHello &+ cryptoStreamAbandoned &+ initialsExhausted
    }
}
