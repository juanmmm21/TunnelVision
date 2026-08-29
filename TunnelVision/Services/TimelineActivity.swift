import Foundation
import Shared

/// El eje temporal del historial: cuánto tráfico se guardó en cada tramo, de punta a punta de lo que
/// hay en disco. Es lo que dibuja la barra de scrub de la Timeline (`docs/ux/screens.md`).
///
/// Es al historial lo que `ThroughputWindow` es al feed en vivo, y comparte con ella las dos
/// propiedades que importan: barras de anchura fija y **huecos rellenos a cero**. Lo que cambia es de
/// dónde salen los datos —una agregación del store en vez de un anillo en memoria— y qué miden: aquí
/// se cuentan paquetes, no bytes, porque lo que el eje contesta es *cuándo hubo actividad*.
///
/// Todo lo de este fichero es puro: la consulta la hace `HistoryReader`.

/// Un tramo del eje: cuántos paquetes cayeron dentro y cuánto dura.
public struct ActivityBar: Sendable, Hashable, Identifiable {

    /// Instante en que empieza el tramo. Es el `id`: los tramos no se solapan.
    public let start: Date

    /// Anchura del tramo. Viaja con la barra —como en `ThroughputSample`— para que quien la pinta o
    /// la selecciona no tenga que conocer la política que la eligió.
    public let duration: TimeInterval

    public let packetCount: Int

    public init(start: Date, duration: TimeInterval, packetCount: Int) {
        self.start = start
        self.duration = duration
        self.packetCount = packetCount
    }

    public var id: Date { start }

    public var end: Date { start.addingTimeInterval(duration) }

    /// El intervalo **absoluto** que representa la barra, que es exactamente lo que se filtra al
    /// seleccionarla: un trozo concreto del pasado, no una regla que se recalcule.
    public var range: ClosedRange<Date> { start...end }

    /// Sin tráfico guardado en el tramo. No es lo mismo que "no se sabe": el eje cubre todo el
    /// historial, así que un cero aquí significa que en ese rato no pasó nada.
    public var isQuiet: Bool { packetCount == 0 }
}

/// El eje completo: las barras, de la más antigua a la más reciente, ya rellenas a cero.
///
/// No guarda ni el tramo total ni el máximo: los deriva de las barras. Un eje con un `span` propio
/// podría contradecir a sus barras, y la contradicción saldría dibujada.
public struct ActivityAxis: Sendable, Equatable {

    public let bars: [ActivityBar]

    public init(bars: [ActivityBar]) {
        self.bars = bars
    }

    /// Eje sin historial que enseñar. Es lo que ve la pantalla antes de la primera captura, y lo que
    /// hace que la barra de scrub no se dibuje en vez de dibujarse plana (que se leería como "no
    /// hubo tráfico" en vez de "no hay nada guardado").
    public static let empty = ActivityAxis(bars: [])

    public var isEmpty: Bool { bars.isEmpty }

    /// Desde el principio de la primera barra hasta el final de la última, o `nil` si no hay ninguna.
    public var span: ClosedRange<Date>? {
        guard let first = bars.first, let last = bars.last else { return nil }
        return first.start...last.end
    }

    /// El tramo más cargado. Es la escala del dibujo: sin él, cada barra se pintaría contra un máximo
    /// distinto en cada recarga y la forma del eje cambiaría sin que cambiara el tráfico.
    public var busiest: Int { bars.map(\.packetCount).max() ?? 0 }

    /// Paquetes que el eje representa. Es de **todo** el historial, no de lo que el filtro deja ver.
    public var totalPackets: Int { bars.reduce(0) { $0 + $1.packetCount } }

    /// La barra en la que cae un instante, o `nil` si queda fuera del eje. La usa la vista para
    /// traducir el punto que el dedo tocó en el tramo que se selecciona.
    public func bar(containing date: Date) -> ActivityBar? {
        // Un barrido lineal basta: las barras son decenas, no miles, y la aritmética de índices
        // tendría que replicar aquí la alineación que decidió `TimelineActivity`.
        bars.first { date >= $0.start && date <= $0.end }
    }

    /// El tramo que elige un arrastre entre dos instantes: desde el principio de la primera barra que
    /// toca hasta el final de la última, enteras. `nil` solo si no hay eje que barrer.
    ///
    /// **Se redondea a barras enteras** en vez de devolverse el rango crudo del dedo porque el eje es
    /// lo que el usuario está mirando: un tramo que empezase a mitad de una barra dejaría esa barra
    /// resaltada entera —el resalte es por solape— mientras la lista esconde parte de lo que esa barra
    /// cuenta, y el pie fecharía un trozo que no se corresponde con nada dibujado.
    ///
    /// **Los extremos se acotan al eje en vez de descartarse.** Un dedo que entra o sale por el borde
    /// del gráfico da un instante que ningún tramo cubre, y tirar el gesto entero por eso castigaría
    /// justo a quien quiere barrer de punta a punta. Es la diferencia con el toque, que sí se ignora
    /// fuera del eje: allí no hay un extremo hacia el que el gesto iba.
    ///
    /// El orden de los extremos da igual: se barre lo mismo de izquierda a derecha que al revés.
    public func sweep(from: Date, to: Date) -> ClosedRange<Date>? {
        guard let first = bars.first, let last = bars.last else { return nil }

        func clamped(_ date: Date) -> Date { min(max(date, first.start), last.end) }

        // Ya acotado al eje, todo instante cae dentro de alguna barra. Los extremos de reserva
        // mantienen la función total sin inventarse un tramo: son los que le tocan a cada lado.
        let start = bar(containing: clamped(min(from, to))) ?? first
        let end = bar(containing: clamped(max(from, to))) ?? last
        return start.start...end.end
    }
}

/// Cómo se elige la anchura de las barras y cómo se rellenan los huecos.
public enum TimelineActivity {

    /// Anchuras "redondas" candidatas, de la más fina a la más gruesa: segundo, 5 s, 15 s, 30 s,
    /// minuto, 5 min, 15 min, 30 min, hora, 2 h, 4 h, 6 h, 12 h, día y semana.
    ///
    /// Se prefiere una anchura redonda a repartir el tramo entre las barras porque la barra es
    /// **seleccionable**: al tocarla, su intervalo se convierte en el filtro de la lista, y "los 15
    /// minutos que empiezan aquí" es algo que se puede leer y contar; "1 minuto y 47 segundos" no.
    ///
    /// Los peldaños intermedios —30 s, 30 min, 2 h, 4 h, 12 h— no estaban, y hacen falta desde que el
    /// número de tramos lo decide el **ancho** de la pantalla (`ScrubCapacity`): con pocas barras
    /// permitidas, una escalera que salta de la hora a las seis horas contesta con dos barras a un
    /// historial de seis horas, o sea con un eje que ya no es un eje. Un peldaño intermedio no es
    /// menos redondo que sus vecinos, y es la diferencia entre cuatro tramos y dos.
    public static let bucketLadder: [TimeInterval] = [
        1, 5, 15, 30, 60, 300, 900, 1_800, 3_600, 7_200, 14_400, 21_600, 43_200, 86_400, 604_800,
    ]

    /// La anchura de barra que le toca a un tramo de `seconds` con `maxBars` barras como mucho.
    ///
    /// Devuelve el escalón redondo **más fino** que quepa. Si el historial es tan largo que ni el
    /// más grueso cabe (semanas de escala en años de historial), se reparte el tramo entre las barras
    /// disponibles: deja de ser redondo, pero el eje sigue cubriéndolo entero, que es lo que no se
    /// puede negociar — un eje que se quedase corto escondería tráfico sin decirlo.
    public static func bucketDuration(forSpan seconds: TimeInterval, maxBars: Int) -> TimeInterval {
        precondition(maxBars > 0, "maxBars debe ser positivo")
        // Un tramo nulo (un único paquete guardado, o dos con el mismo sello) es una barra del
        // escalón más fino: no hay nada que repartir, pero sí algo que enseñar.
        guard seconds.isFinite, seconds > 0 else { return bucketLadder[0] }

        for rung in bucketLadder where barCount(forSpan: seconds, bucketDuration: rung) <= maxBars {
            return rung
        }
        return seconds / Double(maxBars)
    }

    /// Si acercarse a esta barra enseñaría algo que ahora mismo no se ve.
    ///
    /// Dos motivos para decir que no, y los dos son el mismo: dentro no hay nada que mirar.
    ///
    /// - Una barra **vacía** no esconde tráfico —el eje rellena los huecos a cero, así que su cero es
    ///   una afirmación y no una laguna—, y acercarse a ella daría un eje plano en el que no se
    ///   distingue "aquí no pasó nada" de "esto ya no está guardado", que es lo que se dice cuando la
    ///   retención se lleva un tramo acercado.
    /// - Una barra que ya está en el **escalón más fino** no se puede subdividir: el eje que saldría
    ///   tendría barras de la misma anchura que la que se tocó, así que el gesto costaría una consulta
    ///   para no cambiar la resolución.
    ///
    /// Se pregunta contra `bucketDuration` y no contra la escalera directamente porque el tope de
    /// barras es de la política: con pocas barras, un escalón puede no llegar a caber y el "más fino"
    /// no ser el primero de la escalera.
    public static func canZoom(into bar: ActivityBar, maxBars: Int) -> Bool {
        precondition(maxBars > 0, "maxBars debe ser positivo")
        guard !bar.isQuiet, bar.duration.isFinite, bar.duration > 0 else { return false }
        return bucketDuration(forSpan: bar.duration, maxBars: maxBars) < bar.duration
    }

    /// Cuántas barras hacen falta para cubrir el tramo con esa anchura. El `+ 1` es lo que hace que
    /// el instante final quede **dentro** del eje y no justo detrás de su última barra.
    public static func barCount(forSpan seconds: TimeInterval, bucketDuration: TimeInterval) -> Int {
        precondition(bucketDuration > 0, "bucketDuration debe ser positiva")
        guard seconds.isFinite, seconds > 0 else { return 1 }
        return Int((seconds / bucketDuration).rounded(.down)) + 1
    }

    /// Construye el eje a partir de lo que devolvió el store.
    ///
    /// El store solo devuelve los intervalos **con** paquetes; aquí se rellenan los vacíos a cero, por
    /// el mismo motivo que en `ThroughputWindow`: sin ellos, el dibujo uniría dos picos y afirmaría
    /// una actividad continua que no hubo.
    ///
    /// La última barra **absorbe** lo que caiga justo en el instante de cierre del tramo. Es un solo
    /// caso —el paquete más nuevo del historial, que es a la vez el extremo superior del rango—, pero
    /// dejarlo fuera haría que el eje no contase el paquete que define su propio final.
    public static func axis(
        counts: [PacketBucket],
        span: ClosedRange<Date>,
        bucketDuration: TimeInterval,
        maxBars: Int
    ) -> ActivityAxis {
        precondition(bucketDuration > 0, "bucketDuration debe ser positiva")
        precondition(maxBars > 0, "maxBars debe ser positivo")

        let seconds = span.upperBound.timeIntervalSince(span.lowerBound)
        let count = min(maxBars, barCount(forSpan: seconds, bucketDuration: bucketDuration))

        var packets = [Int](repeating: 0, count: count)
        for bucket in counts {
            let offset = bucket.start.timeIntervalSince(span.lowerBound) / bucketDuration
            // Un intervalo anterior al tramo no puede venir del store (la consulta va acotada por el
            // mismo rango), pero si viniera, sumarlo a la primera barra sería inventarse cuándo pasó.
            guard offset >= -0.5 else { continue }
            let index = min(count - 1, max(0, Int(offset.rounded())))
            packets[index] += bucket.packetCount
        }

        return ActivityAxis(
            bars: packets.enumerated().map { index, count in
                ActivityBar(
                    start: span.lowerBound.addingTimeInterval(Double(index) * bucketDuration),
                    duration: bucketDuration,
                    packetCount: count
                )
            }
        )
    }
}
