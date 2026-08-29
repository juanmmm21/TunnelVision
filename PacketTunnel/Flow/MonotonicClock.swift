import Foundation

/// Fuente de tiempo monotónica inyectable, en nanosegundos.
///
/// La tabla de flujos sella cada paquete y decide la evicción por inactividad a partir de este
/// reloj. Se abstrae en un protocolo para que los tests fijen el tiempo de forma determinista
/// (un reloj manual) en vez de depender del reloj de pared, que puede saltar hacia atrás.
public protocol MonotonicClock: Sendable {
    /// Nanosegundos desde un origen arbitrario pero estable dentro del proceso. Monótono
    /// creciente: nunca retrocede aunque cambie la hora del sistema.
    func now() -> UInt64
}

/// Reloj monotónico del sistema respaldado por `CLOCK_UPTIME_RAW`.
///
/// `CLOCK_UPTIME_RAW` no avanza mientras el dispositivo duerme, que es justo lo que queremos
/// para el timeout de inactividad de un flujo: no penaliza a un flujo por el tiempo que el
/// equipo estuvo suspendido. No está sujeto a ajustes de NTP ni a cambios de zona horaria.
public struct SystemMonotonicClock: MonotonicClock {
    public init() {}

    public func now() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }
}
