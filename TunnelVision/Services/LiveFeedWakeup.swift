import Foundation

/// El despertador del feed en vivo: la costura inyectada del lector.
///
/// En producción es la notificación Darwin que la extensión postea tras cada lote de `push`
/// (`DarwinSignal.liveDataAvailable`, ver `docs/spec/ipc.md`). Se abstrae porque
/// `CFNotificationCenter` no es ejercitable de forma útil en un test —hace falta un segundo proceso
/// que la emita—, mientras que todo lo que decide el lector sí lo es: con esta costura, un test
/// empuja despertares a mano contra un ring de fichero temporal.
///
/// La señal no lleva datos (una notificación Darwin no puede llevarlos) y viene coalescida por el
/// emisor: un despertar puede corresponder a muchos registros, y por eso el lector drena en bucle
/// hasta vaciar en vez de asumir un registro por aviso.
public protocol LiveFeedWakeup: Sendable {

    /// Empieza a avisar. `onWake` puede invocarse desde cualquier hilo y en cualquier momento entre
    /// esta llamada y `stop()`. Llamarla dos veces reemplaza al manejador anterior.
    func start(onWake: @escaping @Sendable () -> Void)

    /// Deja de avisar y suelta el manejador.
    func stop()
}
