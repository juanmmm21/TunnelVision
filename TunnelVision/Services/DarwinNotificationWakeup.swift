import Foundation
import Shared

/// Conformidad de producción de `LiveFeedWakeup` sobre el centro de notificaciones Darwin.
///
/// Es la cáscara: solo I/O, ninguna decisión. Como `NETunnelProviderManagerAdapter` o
/// `NetworkRelayConnection`, se valida **por compilación** bajo concurrencia estricta; su corrección
/// viva exige los dos procesos (la extensión emitiendo, la app escuchando) y por tanto un
/// dispositivo, así que no lleva tests ejecutables propios.
///
/// `@unchecked Sendable`: el único estado mutable es el manejador, protegido por un `NSLock`. Hace
/// falta un candado y no un actor porque el callback de `CFNotificationCenter` es una función C que
/// llega en un hilo arbitrario y no puede ser `async`.
public final class DarwinNotificationWakeup: LiveFeedWakeup, @unchecked Sendable {

    private let name: String
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?

    /// El nombre se guarda como `String` y se puentea a `CFString` en el punto de uso: un `CFString`
    /// global no es seguro bajo concurrencia estricta (misma decisión que en `DarwinSignal`).
    public init(name: String = DarwinSignal.liveDataAvailable) {
        self.name = name
    }

    deinit {
        // Un observador que sobreviva al objeto es un puntero colgante en el centro Darwin: el
        // siguiente aviso saltaría sobre memoria liberada. Se retira sí o sí, aunque falte `stop()`.
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    public func start(onWake: @escaping @Sendable () -> Void) {
        lock.lock()
        handler = onWake
        lock.unlock()

        // El callback es una función C: no captura contexto, así que la instancia viaja como el
        // puntero `observer` y se recupera sin retenerla (el centro no gestiona su ciclo de vida).
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<DarwinNotificationWakeup>.fromOpaque(observer).takeUnretainedValue().fire()
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    public func stop() {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(name as CFString),
            nil
        )
        lock.lock()
        handler = nil
        lock.unlock()
    }

    private func fire() {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?()
    }
}
