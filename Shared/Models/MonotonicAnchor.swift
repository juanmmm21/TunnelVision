import Foundation

/// Ancla entre el reloj monotónico con el que se sellan los paquetes y la hora de pared.
///
/// `PacketMeta.timestamp` y `FlowRecord.firstSeen`/`lastSeen` son nanosegundos de `CLOCK_UPTIME_RAW`
/// (ver `SystemMonotonicClock`), **no** un epoch: interpretarlos como tal situaría todo el tráfico en
/// 1970. `CLOCK_UPTIME_RAW` mide el uptime de la máquina, así que es el mismo reloj en los dos
/// procesos y basta leerlo una vez junto a la hora de pared para poder convertir.
///
/// Se ancla **una sola vez por sesión** (no por paquete ni por lote) para que el espaciado relativo
/// entre paquetes se conserve exacto: re-anclar en cada lote metería el jitter del propio muestreo en
/// un eje temporal que hoy es fiel. A cambio, el ancla envejece si el dispositivo se suspende
/// (`CLOCK_UPTIME_RAW` se para mientras la hora de pared avanza), y por eso quien la usa toma una
/// nueva al empezar una sesión: `LiveFeedReader.start()` en la app, y la apertura del `FlowStore` en
/// la extensión.
///
/// Vive en `Shared/Models` porque la necesitan los **dos** procesos —la app para fechar el feed en
/// vivo, la extensión para fechar lo que escribe en el store—, el mismo motivo por el que acabaron
/// aquí `TunnelAddressing` y el codec del canal de control.
public struct MonotonicAnchor: Sendable, Equatable {

    /// Lectura del reloj monotónico en el instante del anclaje.
    public let uptimeNanoseconds: UInt64

    /// Hora de pared en ese mismo instante.
    public let wallClock: Date

    public init(uptimeNanoseconds: UInt64, wallClock: Date) {
        self.uptimeNanoseconds = uptimeNanoseconds
        self.wallClock = wallClock
    }

    /// Toma el ancla ahora mismo, leyendo el mismo reloj que sella los paquetes en la extensión.
    public static func now() -> MonotonicAnchor {
        MonotonicAnchor(uptimeNanoseconds: clock_gettime_nsec_np(CLOCK_UPTIME_RAW), wallClock: Date())
    }

    /// Hora de pared correspondiente a un sello monotónico.
    ///
    /// La resta se hace con signo (`Int64(bitPattern:)` sobre la resta envolvente) porque un paquete
    /// puede ser anterior al ancla —los que ya estaban en el ring cuando la app arrancó— o posterior.
    ///
    /// El desplazamiento se aplica **sobre la `Date` del ancla**, no reconstruyendo la fecha desde
    /// nanosegundos absolutos: el segundo camino redondearía cada instante a la resolución de `Date`
    /// para el epoch actual (~256 ns) y se cargaría el espaciado relativo entre paquetes, que es
    /// justo la propiedad por la que existe el ancla. Para el disco, donde lo que hace falta es un
    /// instante absoluto, está `nanosecondsSince1970(forUptime:)`.
    public func date(forUptime nanoseconds: UInt64) -> Date {
        let delta = Int64(bitPattern: nanoseconds &- uptimeNanoseconds)
        return wallClock.addingTimeInterval(Double(delta) / 1_000_000_000)
    }

    /// El instante del anclaje en nanosegundos desde el epoch.
    public var wallClockNanoseconds: Int64 {
        WallClock.nanosecondsSince1970(from: wallClock)
    }

    /// Nanosegundos desde el epoch correspondientes a un sello monotónico.
    ///
    /// Es la conversión que aplica el `FlowStore` al escribir: en disco los sellos son absolutos, para
    /// que el historial siga siendo fechable y ordenable después de un reinicio (el uptime vuelve a
    /// cero, la hora de pared no). Toda la aritmética es entera, así que el **espaciado relativo entre
    /// dos sellos es exacto**; la única imprecisión es la de la lectura de pared del propio ancla.
    public func nanosecondsSince1970(forUptime nanoseconds: UInt64) -> Int64 {
        let delta = Int64(bitPattern: nanoseconds &- uptimeNanoseconds)
        return wallClockNanoseconds &+ delta
    }
}

/// Conversión entre `Date` y nanosegundos desde el epoch, que es como se guardan los instantes en
/// disco (ver `docs/spec/persistence.md`).
///
/// El paso por `Double` pierde resolución por debajo de ~256 ns para fechas actuales (el mantisa de
/// 53 bits no cubre 1,8·10¹⁸), pero `Date` no ofrece más: es el límite del propio tipo, no de esta
/// conversión, y por eso la aritmética entre sellos se hace siempre en enteros antes de convertir.
public enum WallClock {

    public static func nanosecondsSince1970(from date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000_000_000).rounded())
    }

    public static func date(fromNanosecondsSince1970 nanoseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(nanoseconds) / 1_000_000_000)
    }
}
