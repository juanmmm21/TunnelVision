import Foundation

/// Identificador del App Group compartido por app y extensión. **Única fuente de verdad**: tanto
/// la persistencia (`FlowStore`) como el IPC (ring buffer) resuelven su contenedor a partir de aquí.
public enum AppGroup {
    public static let identifier = "group.com.juanmmm21.tunnelvision"
}

/// Nombre de la notificación Darwin usada solo como *wakeup* sin payload: la extensión la publica
/// (coalescida) tras un lote de `push`; la app la observa y programa un `drain` del ring.
///
/// Las notificaciones Darwin **no transportan datos** — son una señal cross-proceso desnuda. Los
/// bytes viajan por el ring buffer mmap; esta señal solo dice "hay algo nuevo, ven a drenar".
///
/// Se expone como `String` (Sendable) y no como `CFString`: bajo concurrencia estricta un `CFString`
/// global no es seguro. El puente a `CFString` (`name as CFString`) se hace en el punto de uso, al
/// registrar/postear con `CFNotificationCenter` (app/extensión), que es donde la API lo requiere.
public enum DarwinSignal {
    /// La publica la extensión cuando hay registros nuevos en el ring.
    public static let liveDataAvailable = "com.juanmmm21.tunnelvision.live-data"
}
