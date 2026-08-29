import Foundation
import Shared

/// El recorrido de la barra de scrub para quien no la ve.
///
/// La barra se maneja con dos gestos que dan por supuesta la vista: **tocar** un tramo (que filtra la
/// lista y baja el eje a él) y **barrer** varios con el dedo (que acota la lista a un trozo más ancho).
/// Con VoiceOver el eje entero es un solo elemento —leer barra a barra sería recitar decenas de
/// cuentas sin forma—, así que ninguno de los dos gestos se puede hacer: no hay forma de decir *qué*
/// tramo, y menos aún de decir *desde dónde hasta dónde*.
///
/// Lo que falta no es un atajo sino un **cursor**: un tramo señalado que se mueve de uno en uno
/// (`accessibilityAdjustableAction`), que se puede activar —y entonces significa lo mismo que
/// tocarlo—, y que además puede fijar un extremo para elegir un tramo largo sin arrastrar nada. Eso es
/// lo que hay aquí, y es puro: la vista no decide dónde está el cursor ni qué se le ofrece.
///
/// Como en `ScrubPresentation`, aquí no se formatea ninguna fecha: la lectura lleva el intervalo y la
/// precisión con la que hay que decirlo, y la vista lo compone con `Text(_:format:)`, que es quien sabe
/// del idioma y del huso del dispositivo.

/// Dónde está mirando quien recorre el eje sin verlo, y si está en mitad de elegir un tramo largo.
///
/// El ancla es el **otro extremo** de una selección en curso, no un segundo cursor: mientras está
/// puesta, moverse extiende lo elegido, que es exactamente lo que hace un dedo que no se ha levantado.
public struct ScrubCursor: Sendable, Equatable {

    /// Índice de la barra señalada dentro del eje.
    public let index: Int

    /// El extremo ya fijado de una selección en curso, o `nil` si no se está eligiendo un tramo largo.
    public let anchor: Int?

    public init(index: Int, anchor: Int? = nil) {
        self.index = index
        self.anchor = anchor
    }

    public var isSelectingRange: Bool { anchor != nil }
}

/// Lo que hay que leer del tramo señalado.
///
/// El intervalo va **sin formatear** y acompañado de su precisión: fecharlo es de la vista, y la
/// precisión es una decisión sobre lo que el tramo representa (`ScrubPresentation.scale`).
public struct ScrubCursorReading: Sendable, Equatable {

    /// El tramo señalado, para que la vista lo feche.
    public let interval: ClosedRange<Date>

    /// Con cuánto detalle hay que decirlo.
    public let scale: ScrubTimeScale

    /// Lo que se dice después de la fecha: cuánto tráfico hubo, dónde está el cursor dentro del eje y,
    /// si hay una selección en curso, cuánto lleva elegido.
    public let detail: String

    public init(interval: ClosedRange<Date>, scale: ScrubTimeScale, detail: String) {
        self.interval = interval
        self.scale = scale
        self.detail = detail
    }
}

/// Una acción ofrecida sobre el eje además de la de activar.
///
/// Son las que sustituyen al arrastre. No se ofrecen todas a la vez: fijar un extremo solo tiene
/// sentido antes de haberlo fijado, y aplicar o cancelar solo después.
public enum ScrubCursorAction: Sendable, Equatable, Identifiable, CaseIterable {

    /// Fija este tramo como un extremo. A partir de aquí, moverse extiende lo elegido.
    case beginRange

    /// Acota la lista a lo elegido entre el extremo fijado y el tramo señalado.
    case commitRange

    /// Suelta el extremo fijado sin acotar nada.
    case cancelRange

    /// La identidad es el nombre del caso y **no su rótulo**: el rótulo es copia, así que una lista
    /// identificada por él cambiaría de identidad al cambiar de idioma. Es el mismo movimiento que
    /// hizo `IntroCardAction` al volverse traducible.
    public var id: String {
        switch self {
        case .beginRange: "beginRange"
        case .commitRange: "commitRange"
        case .cancelRange: "cancelRange"
        }
    }

    public var label: String {
        switch self {
        case .beginRange:
            String(
                localized: "timeline.scrub.cursorAction.beginRange",
                defaultValue: "Select from this interval",
                comment: """
                    VoiceOver action on the activity graph that fixes the focused interval as one \
                    end of a selection; moving from there extends what is chosen. It replaces the \
                    drag a sighted user does, so it names the starting point and not a mode.
                    """
            )
        case .commitRange:
            String(
                localized: "timeline.scrub.cursorAction.commitRange",
                defaultValue: "Filter the list to the selected intervals",
                comment: """
                    VoiceOver action on the activity graph that applies the stretch chosen \
                    between the fixed end and the focused interval. It says what happens to the \
                    list, which is the only visible effect.
                    """
            )
        case .cancelRange:
            String(
                localized: "timeline.scrub.cursorAction.cancelRange",
                defaultValue: "Cancel the selection",
                comment: """
                    VoiceOver action on the activity graph that releases the fixed end without \
                    filtering anything. It abandons a selection in progress, so it must read as \
                    cancelling and not as clearing a filter that was already applied.
                    """
            )
        }
    }
}

/// Qué significa activar el eje con el cursor donde está.
///
/// Activar es siempre *aplicar lo que se ha elegido*, y lo elegido depende de si hay un extremo
/// fijado: sin él, un tramo suelto —lo mismo que tocarlo—; con él, el trozo entre los dos. Que sea una
/// regla y no dos botones es lo que hace que el gesto por defecto nunca signifique una cosa distinta
/// de la que se acaba de anunciar.
public enum ScrubCursorActivation: Sendable, Equatable {

    /// Un tramo suelto, tal cual lo devolvería un toque sobre esa barra.
    case interval(ActivityBar)

    /// El trozo elegido entre el extremo fijado y el cursor, ya redondeado a barras enteras.
    case range(ClosedRange<Date>)
}

public enum ScrubAccessibility {

    /// Reencaja el cursor sobre el eje que hay ahora mismo.
    ///
    /// Dos decisiones. **(1) El cursor arranca en la barra más reciente**, que es donde está la
    /// atención de quien abre la Timeline: empezar por el principio del historial obligaría a recorrer
    /// el eje entero para llegar a lo de hoy. **(2) Un eje nuevo suelta la selección en curso.** Las
    /// barras se re-alinean cuando el historial crece o la retención corta, así que un ancla guardada
    /// puede haber pasado a señalar otro trozo del pasado; aplicarla acotaría la lista a algo que el
    /// usuario no eligió. El cursor, en cambio, solo se acota: perder el sitio es peor que quedarse
    /// cerca de donde se estaba.
    public static func rebased(_ cursor: ScrubCursor?, on axis: ActivityAxis) -> ScrubCursor? {
        guard !axis.bars.isEmpty else { return nil }
        guard let cursor else { return ScrubCursor(index: axis.bars.count - 1) }
        return ScrubCursor(index: clamped(cursor.index, in: axis))
    }

    /// Mueve el cursor `steps` tramos, acotado a los extremos del eje.
    ///
    /// Se acota en vez de dar la vuelta: quien llega al final del historial y sigue deslizando espera
    /// quedarse ahí, y saltar al otro extremo sin avisar dejaría al cursor en un sitio que nadie pidió.
    /// El ancla se conserva, que es lo que hace que moverse extienda lo elegido.
    public static func moved(_ cursor: ScrubCursor, by steps: Int, on axis: ActivityAxis) -> ScrubCursor {
        guard !axis.bars.isEmpty else { return cursor }
        return ScrubCursor(index: clamped(cursor.index + steps, in: axis), anchor: cursor.anchor)
    }

    /// Fija el tramo señalado como extremo de una selección. Volver a fijarlo mueve el extremo aquí:
    /// no hay un tercer punto que elegir, así que la única lectura posible es "empiezo otra vez".
    public static func beganRange(_ cursor: ScrubCursor) -> ScrubCursor {
        ScrubCursor(index: cursor.index, anchor: cursor.index)
    }

    /// Suelta el extremo fijado y deja el cursor donde estaba: cancelar la selección no es volver.
    public static func cancelledRange(_ cursor: ScrubCursor) -> ScrubCursor {
        ScrubCursor(index: cursor.index)
    }

    /// El tramo que la selección en curso cubre ahora mismo, o `nil` si no hay ninguna.
    ///
    /// Se redondea a barras enteras con el mismo `ActivityAxis.sweep` que usa el arrastre, y no con una
    /// aritmética propia: los dos gestos eligen lo mismo, así que tienen que redondear igual o el
    /// resalte y el filtro discreparían según cómo se hubiera elegido.
    ///
    /// Los extremos se dan por el **centro** de cada barra y no por su principio porque los tramos del
    /// eje se tocan (`ActivityBar.range` incluye los dos bordes), así que el instante en que empieza
    /// una barra pertenece también a la anterior y `sweep` lo resolvería hacia atrás: elegir "desde
    /// esta" acabaría incluyendo la de al lado. El dedo no se topa con esto porque toca dentro.
    public static func pendingRange(
        for cursor: ScrubCursor, on axis: ActivityAxis
    ) -> ClosedRange<Date>? {
        guard let anchor = cursor.anchor,
              let from = bar(at: anchor, in: axis),
              let to = bar(at: cursor.index, in: axis)
        else {
            return nil
        }
        return axis.sweep(from: midpoint(of: from), to: midpoint(of: to))
    }

    /// Lo que VoiceOver lee del cursor: cuándo es el tramo, cuánto tráfico tuvo, dónde cae dentro del
    /// eje y —si hay una selección en curso— cuánto lleva elegido.
    ///
    /// La posición (`Interval 4 of 6`) no es adorno: sin ella, deslizar por un eje de tramos parecidos
    /// no da ninguna forma de saber si uno se está moviendo ni cuánto queda.
    ///
    /// Los dos números de la posición se envuelven en `String(...)` —son sitios y no cantidades, y un
    /// entero interpolado lo agrupa el locale—, mientras que lo elegido, que sí es una cantidad, sigue
    /// pasando por `DisplayFormat.count`.
    public static func reading(
        for cursor: ScrubCursor, on axis: ActivityAxis, calendar: Calendar = .current
    ) -> ScrubCursorReading? {
        guard let bar = bar(at: cursor.index, in: axis) else { return nil }

        let traffic = packets(bar.packetCount)
        let position = cursor.index + 1
        let total = axis.bars.count
        let detail: String

        if let anchor = cursor.anchor {
            detail = String(
                localized: "timeline.scrub.cursor.detail.selecting",
                defaultValue: """
                    \(traffic). Interval \(String(position)) of \(String(total)). \
                    Selecting \(ScrubPresentation.intervalCount(abs(cursor.index - anchor) + 1)).
                    """,
                comment: """
                    VoiceOver value of the activity graph while a stretch is being selected, read \
                    after the dates of the focused interval. In order: how much traffic that \
                    interval holds, where it sits in the graph, and how much has been chosen so \
                    far — which is the only thing that tells the user moving is doing anything. \
                    The two numbers are positions in a list and carry no thousands separator.
                    """
            )
        } else {
            detail = String(
                localized: "timeline.scrub.cursor.detail",
                defaultValue: "\(traffic). Interval \(String(position)) of \(String(total)).",
                comment: """
                    VoiceOver value of the activity graph, read after the dates of the focused \
                    interval: how much traffic it holds and where it sits in the graph. The \
                    position is not decoration — without it, walking a graph of similar-looking \
                    intervals gives no way to tell one is moving. Both numbers are positions in a \
                    list and carry no thousands separator.
                    """
            )
        }

        return ScrubCursorReading(
            interval: bar.range,
            scale: ScrubPresentation.scale(for: bar.range, calendar: calendar),
            detail: detail
        )
    }

    /// Las acciones que tiene sentido ofrecer con el cursor donde está.
    ///
    /// Elegir un tramo largo solo se ofrece si hay más de una barra que elegir: en un eje de una sola,
    /// "desde aquí" y "hasta aquí" son el mismo sitio y la acción no haría nada que activar no haga ya.
    public static func actions(for cursor: ScrubCursor, on axis: ActivityAxis) -> [ScrubCursorAction] {
        guard axis.bars.count > 1 else { return [] }
        return cursor.isSelectingRange ? [.commitRange, .cancelRange] : [.beginRange]
    }

    /// Qué aplica activar el eje. `nil` si el cursor no señala ninguna barra, que solo puede pasar con
    /// un eje sin barras — y ese no se dibuja.
    public static func activation(
        for cursor: ScrubCursor, on axis: ActivityAxis
    ) -> ScrubCursorActivation? {
        if let range = pendingRange(for: cursor, on: axis) { return .range(range) }
        guard let bar = bar(at: cursor.index, in: axis) else { return nil }
        return .interval(bar)
    }

    /// Lo que se oye del cursor entero: el tramo **ya fechado por la vista** y lo que se dice después.
    ///
    /// La frase se compone aquí y no en SwiftUI, donde era `intervalText(…) + Text(" \(detail)")`: el
    /// separador y el orden son decisiones de idioma tomadas donde ningún traductor llega, y de paso
    /// desaparece la entrada `" %@"` que aquel `Text` interpolado había metido en el catálogo. La
    /// fecha la sigue poniendo la vista porque el huso y el formato son suyos.
    public static func cursorValue(interval: String, detail: String) -> String {
        String(
            localized: "timeline.scrub.cursor.value",
            defaultValue: "\(interval). \(detail)",
            comment: """
                VoiceOver value of the activity graph: the focused interval's dates followed by \
                what is said about it. The first placeholder is the already-formatted stretch, \
                the second the sentence with the traffic and the position.
                """
        )
    }

    /// Lo que se oye cuando el cursor no señala nada. Solo puede pasar sobre un eje sin barras, que no
    /// se dibuja; existe para que el valor nunca se quede vacío, que se oiría como si señalara algo.
    public static var noSelectionValue: String {
        String(
            localized: "timeline.scrub.cursor.none",
            defaultValue: "No interval selected.",
            comment: """
                VoiceOver value of the activity graph when nothing is focused. It states that \
                there is no interval to read, so it must not be confused with an interval in \
                which nothing was recorded — that one has its own wording.
                """
        )
    }

    // MARK: - Detalles

    private static func clamped(_ index: Int, in axis: ActivityAxis) -> Int {
        min(max(index, 0), axis.bars.count - 1)
    }

    private static func bar(at index: Int, in axis: ActivityAxis) -> ActivityBar? {
        axis.bars.indices.contains(index) ? axis.bars[index] : nil
    }

    /// Un instante que solo puede pertenecer a esta barra, que es lo que `ActivityAxis.sweep` necesita
    /// para no resolver un extremo hacia la vecina.
    private static func midpoint(of bar: ActivityBar) -> Date {
        bar.start.addingTimeInterval(bar.duration / 2)
    }

    /// El tráfico de un tramo dicho como una frase. Un tramo vacío se **nombra** en vez de leerse como
    /// "0 packets": el eje rellena los huecos a cero, así que ese cero es una afirmación y no una
    /// laguna, y por eso tiene clave propia en vez de caer en el plural.
    ///
    /// Lo demás sale de `ScrubPresentation.packetCount`, que es la misma cuenta que dice el nombre del
    /// eje: compartirla estructuralmente es lo que impide que una traducción mueva una y no la otra.
    private static func packets(_ count: Int) -> String {
        guard count > 0 else {
            return String(
                localized: "timeline.scrub.cursor.noPackets",
                defaultValue: "No packets",
                comment: """
                    Read of an interval of the activity graph in which nothing was recorded. The \
                    graph fills its gaps with zeros, so this is an assertion ('nothing happened \
                    here') and not a missing figure: it is named rather than counted.
                    """
            )
        }
        return ScrubPresentation.packetCount(count)
    }
}
