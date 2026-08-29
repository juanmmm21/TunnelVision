import Foundation
import Shared

/// Las opciones de filtro que ofrece la Timeline, como valores puros.
///
/// `HistoryFilter` (el servicio) sabe **filtrar**; esto sabe qué opciones se le ofrecen al usuario y
/// en qué se traducen. Van separadas porque son cosas distintas: el rango temporal de "última hora"
/// no es un dato del filtro sino una regla que hay que evaluar contra el instante en que se aplica,
/// y los protocolos que la pantalla agrupa bajo una casilla son una decisión de presentación.

/// Los protocolos que se pueden marcar. Son tres casillas y no una por cada `IPProtocolNumber`
/// porque ICMP y compañía no son algo que el usuario distinga: los agrupa "Other", y así ninguna
/// conexión guardada se queda fuera de todos los filtros a la vez.
public enum TimelineProtocolFilter: String, Sendable, CaseIterable, Identifiable, Hashable {
    case tcp
    case udp
    case other

    public var id: String { rawValue }

    /// Se usan los nombres de protocolo tal cual: la Timeline es la pantalla en la que el usuario
    /// curioso baja al detalle (principio 3), y traducir TCP por "tráfico de apps" sería falso —
    /// QUIC, que es UDP, también lo es.
    ///
    /// Por eso **TCP y UDP no pasan por el catálogo**: son el nombre del protocolo en el cable, igual
    /// en todos los idiomas, y meterlos como unidades de traducción solo abriría la puerta a que
    /// alguien los "tradujera". La casilla que sí es copia es la tercera, y no dice lo mismo que el
    /// `other` de una fila: aquí es un **cajón** que incluye ICMP, y allí es un protocolo que no
    /// sabemos nombrar. Dos significados, dos claves.
    public var label: String {
        switch self {
        case .tcp: return "TCP"
        case .udp: return "UDP"
        case .other:
            return String(
                localized: "timeline.filter.protocol.other",
                defaultValue: "Other",
                comment: """
                    Third protocol checkbox in the Timeline's filter menu. It is a bucket for \
                    everything that is neither TCP nor UDP (ICMP included), and it exists so no \
                    saved connection is invisible to every filter at once. TCP and UDP are the \
                    protocols' own names and are deliberately not translatable.
                    """
            )
        }
    }

    public var protocols: Set<IPProtocolNumber> {
        switch self {
        case .tcp: return [.tcp]
        case .udp: return [.udp]
        case .other: return [.icmp, .icmpv6, .other]
        }
    }

    /// Los protocolos de una selección de casillas. Vacía = sin filtro, que es lo que `HistoryFilter`
    /// entiende por "todos".
    public static func protocols(for selection: Set<TimelineProtocolFilter>) -> Set<IPProtocolNumber> {
        selection.reduce(into: Set<IPProtocolNumber>()) { $0.formUnion($1.protocols) }
    }
}

extension IPProtocolNumber {

    /// Cómo se nombra el protocolo en una fila. `other` no se enseña con su número crudo: el valor de
    /// cable vive en `IPHeader.rawProtocol` y no llega al historial, así que fingir precisión ahí sería
    /// inventarse un dato.
    ///
    /// Los cuatro acrónimos son el nombre del protocolo y no copia —no se traducen en ningún idioma—,
    /// así que no pasan por el catálogo. El quinto sí: "Other" es una palabra nuestra que dice *no
    /// sabemos cuál*, y es una clave distinta de la casilla del filtro, que agrupa a propósito.
    public var displayName: String {
        switch self {
        case .tcp: return "TCP"
        case .udp: return "UDP"
        case .icmp: return "ICMP"
        case .icmpv6: return "ICMPv6"
        case .other:
            return String(
                localized: "traffic.protocol.other",
                defaultValue: "Other",
                comment: """
                    Name of a protocol the app does not model, shown where a connection names its \
                    protocol (the Timeline row, the Flow Inspector header). It means 'we cannot \
                    name this one', not the filter checkbox that groups several protocols. TCP, \
                    UDP, ICMP and ICMPv6 are the protocols' own names and are not translatable.
                    """
            )
        }
    }
}

/// Lo que la pantalla tiene puesto ahora mismo como criterio temporal, que puede venir de dos sitios
/// que **no** se comportan igual.
///
/// Un preset del menú es una **regla**: "última hora" tiene que significar la hora anterior a *ahora*,
/// así que su intervalo se recalcula en cada recarga. Un tramo tocado en la barra de scrub es lo
/// contrario: el usuario ha señalado un trozo concreto del pasado, y recalcularlo lo movería solo bajo
/// el dedo — la lista dejaría de enseñar lo que se pidió sin que nadie hubiese tocado nada. Por eso
/// son dos casos y no un `ClosedRange` con una bandera: el que es absoluto no tiene nada que
/// recalcular, y el tipo lo dice.
public enum TimelineDateFilter: Sendable, Equatable, Hashable {

    /// Una de las opciones del menú, evaluada contra el instante de cada recarga.
    case preset(TimelineTimeRange)

    /// Un tramo absoluto elegido en la barra de scrub. No se recalcula nunca.
    case interval(ClosedRange<Date>)

    /// Sin acotar: con lo que arranca la pantalla.
    public static let anyTime = TimelineDateFilter.preset(.anyTime)

    /// El preset marcado en el menú, o `nil` si lo que acota es un tramo de la barra. La vista lo usa
    /// para no dejar marcada una opción que ya no manda.
    public var preset: TimelineTimeRange? {
        switch self {
        case .preset(let range): return range
        case .interval: return nil
        }
    }

    /// El tramo elegido en la barra, o `nil` si el criterio es un preset.
    public var interval: ClosedRange<Date>? {
        switch self {
        case .preset: return nil
        case .interval(let range): return range
        }
    }

    /// Si acota algo. `.preset(.anyTime)` no acota, y es el único caso que no.
    public var isActive: Bool {
        switch self {
        case .preset(let range): return range != .anyTime
        case .interval: return true
        }
    }

    /// El intervalo que hay que pasarle al filtro del historial en este instante.
    public func range(now: Date, calendar: Calendar = .current) -> ClosedRange<Date>? {
        switch self {
        case .preset(let preset): return preset.range(now: now, calendar: calendar)
        case .interval(let range): return range
        }
    }
}

/// Los rangos temporales que ofrece la pantalla.
///
/// Es un **preset y no un intervalo fijo**: "última hora" tiene que significar la hora anterior al
/// momento en que se consulta, así que el intervalo se calcula al aplicar el filtro y se recalcula en
/// cada recarga. Guardar el `ClosedRange` una sola vez haría que la lista dejase de incluir el
/// tráfico nuevo sin decir por qué.
public enum TimelineTimeRange: String, Sendable, CaseIterable, Identifiable, Hashable {
    case anyTime
    case lastHour
    case today
    case last7Days

    public var id: String { rawValue }

    /// El rótulo de la opción en el menú. El "7" de `last7Days` va **dentro** de la cadena y no
    /// interpolado: es parte de la frase y hay idiomas que lo escriben en otro sitio o con otra forma.
    public var label: String {
        switch self {
        case .anyTime:
            return String(
                localized: "timeline.timeRange.anyTime",
                defaultValue: "Any time",
                comment: """
                    Option in the Timeline's time filter that bounds nothing: the whole saved \
                    history. It is the one the screen starts with, so it must read as 'no limit' \
                    and not as a period of time.
                    """
            )
        case .lastHour:
            return String(
                localized: "timeline.timeRange.lastHour",
                defaultValue: "Last hour",
                comment: """
                    Option in the Timeline's time filter: the sixty minutes before now. It is \
                    relative and re-evaluated on every reload, so it must not read as a fixed \
                    clock hour.
                    """
            )
        case .today:
            return String(
                localized: "timeline.timeRange.today",
                defaultValue: "Today",
                comment: """
                    Option in the Timeline's time filter: from midnight in the device's own \
                    calendar until now — the user's today, not the last 24 hours.
                    """
            )
        case .last7Days:
            return String(
                localized: "timeline.timeRange.last7Days",
                defaultValue: "Last 7 days",
                comment: """
                    Option in the Timeline's time filter: the seven days before now. The number \
                    is part of the sentence rather than a placeholder, so a language can write it \
                    wherever it belongs.
                    """
            )
        }
    }

    /// El intervalo que le corresponde en un instante dado, o `nil` si no acota nada.
    ///
    /// El extremo superior es `now` y no el futuro: una fila fechada por delante del reloj solo puede
    /// venir de un desfase, y darla por buena dentro de "hoy" sería enseñar como reciente algo que no
    /// se sabe cuándo pasó. El extremo inferior lo redondea el calendario en `today`, que es lo que
    /// el usuario entiende por hoy — no "las últimas 24 horas".
    public func range(now: Date, calendar: Calendar = .current) -> ClosedRange<Date>? {
        switch self {
        case .anyTime:
            return nil
        case .lastHour:
            return now.addingTimeInterval(-3_600)...now
        case .today:
            return calendar.startOfDay(for: now)...now
        case .last7Days:
            let start = calendar.date(byAdding: .day, value: -7, to: now)
                ?? now.addingTimeInterval(-7 * 86_400)
            return start...now
        }
    }
}
