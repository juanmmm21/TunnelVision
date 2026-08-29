import Foundation
import Shared

/// Qué enseña la barra de scrub de la Timeline y qué dice de sí misma.
///
/// La barra es un eje temporal del historial que además **filtra y se acerca**: al tocar un tramo, la
/// lista de abajo pasa a enseñar solo las conexiones de ese trozo del pasado y el eje se redibuja
/// dentro de él si hay algo que mirar ahí (`ScrubZoom`, `TimelineActivity.canZoom`). Eso obliga a
/// varias cosas que se deciden aquí, y no en la vista: cuándo no hay eje que dibujar, qué se resalta
/// cuando lo seleccionado es justo lo que se está enseñando, y cómo se dice de qué habla el eje —que
/// deja de ser todo el historial en cuanto uno se acerca— sin dejar de decir que no está filtrado.
///
/// Como en el resto de la app, aquí no se formatea ninguna fecha: eso lo hace la vista, que sí sabe
/// del idioma y del huso del dispositivo. Lo que se decide aquí es con qué **precisión** hay que
/// enseñarla —que depende de lo que la barra representa— y cómo se **dicen juntos** los dos extremos
/// ya formateados (`interval(from:to:)`), porque el separador y el orden son de un idioma y no de una
/// vista.

/// El cuerpo de la barra.
public enum ScrubContent: Sendable, Equatable {

    /// No hay nada guardado todavía: la barra no se dibuja.
    ///
    /// Un eje vacío pintado a cero se leería como "en todo este rato no hubo tráfico", que es una
    /// afirmación distinta de "aún no hay historial" — y la que enseña el vacío de la lista.
    case hidden

    /// Hay historial: se dibuja el eje.
    case axis(ActivityAxis)

    /// El eje no se pudo leer y no hay ninguno dibujado. Se dice en una línea y sin botón: quien
    /// recarga la lista vuelve a pedirlo, y una tarjeta de error para un eje decorativo taparía la
    /// pantalla que sí funciona.
    case unavailable(String)
}

/// Con cuánto detalle hay que fechar el tramo seleccionado.
public enum ScrubTimeScale: Sendable, Equatable {

    /// El tramo cabe en un día: basta la hora.
    case timeOfDay

    /// El tramo cruza días: sin la fecha, "de 22:00 a 04:00" no dice de qué noche habla.
    case dateAndTime
}

/// Lo que la barra dice de sí misma sin que nadie la toque: el aviso que lleva siempre debajo y lo
/// que VoiceOver oye del eje —su nombre y lo que promete activarlo—.
///
/// Son tres cadenas que dependen de lo mismo (qué abarca el eje, si se ha bajado a un tramo y si aún
/// se puede bajar más) y que la vista pedía **una por evaluación de su `body`**, así que un arrastre
/// las rehacía enteras, con sus búsquedas en el catálogo, fotograma a fotograma. Viajan juntas porque
/// cambian juntas y porque separarlas es cómo el nombre y el aviso acaban diciendo cosas distintas de
/// la misma barra: el aviso deja de prometer todo el historial en cuanto uno se acerca, y el nombre
/// tiene que hacer lo mismo.
public struct ScrubAxisPresentation: Sendable, Equatable {

    /// El aviso permanente bajo la barra, que se lee con los ojos.
    public let note: String

    public let accessibilityLabel: String

    public let accessibilityHint: String

    public init(note: String, accessibilityLabel: String, accessibilityHint: String) {
        self.note = note
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
    }
}

public enum ScrubPresentation {

    /// Todo lo que la barra dice de sí misma para un eje dado, compuesto de una vez.
    ///
    /// No decide nada que las tres funciones de debajo no decidieran ya —siguen siendo públicas y
    /// probadas una a una—: lo que añade es un solo sitio donde se piden, que es el sitio donde se
    /// sabe cuándo el eje ha cambiado.
    public static func forAxis(
        _ axis: ActivityAxis, zoomed: Bool, zoomable: Bool
    ) -> ScrubAxisPresentation {
        ScrubAxisPresentation(
            note: note(zoomed: zoomed),
            accessibilityLabel: axisLabel(for: axis, zoomed: zoomed),
            accessibilityHint: axisHint(zoomable: zoomable)
        )
    }


    /// Si la barra se dibuja, y con qué eje.
    ///
    /// Un eje ya dibujado gana al último fallo, igual que una lista ya pintada gana a la tarjeta de
    /// error (`TimelinePresentation.content`): que una recarga no consiguiese cuentas nuevas no
    /// convierte en mentira las que se están enseñando.
    public static func content(for axis: ActivityAxis, error: HistoryError? = nil) -> ScrubContent {
        if !axis.isEmpty { return .axis(axis) }
        guard error != nil else { return .hidden }
        return .unavailable(
            String(
                localized: "timeline.scrub.unavailable",
                defaultValue: "Couldn't read the activity for this history.",
                comment: """
                    One line shown where the activity graph above the connection list would go, \
                    when its counts could not be read. It is deliberately not a card with a \
                    button: the list below still works and the graph is a way to navigate it, \
                    not the screen's content.
                    """
            )
        )
    }

    /// Con qué detalle fechar un tramo. El criterio es si empieza y acaba el mismo día natural, no su
    /// duración: media hora a caballo de la medianoche necesita la fecha igual que una semana entera.
    public static func scale(
        for range: ClosedRange<Date>, calendar: Calendar = .current
    ) -> ScrubTimeScale {
        calendar.isDate(range.lowerBound, inSameDayAs: range.upperBound) ? .timeOfDay : .dateAndTime
    }

    /// Si un tramo del eje cae dentro de lo seleccionado, que es lo que la vista resalta.
    ///
    /// Por solape y no por contención, igual que el filtro del historial: la selección nace de una
    /// barra, así que normalmente coinciden, pero después de una recarga las barras pueden haberse
    /// re-alineado (el historial creció) y una selección que ya no encaja tiene que seguir señalando
    /// el trozo del eje al que corresponde.
    public static func isSelected(_ bar: ActivityBar, selection: ClosedRange<Date>?) -> Bool {
        guard let selection else { return false }
        return bar.end >= selection.lowerBound && bar.start <= selection.upperBound
    }

    /// Qué tramo hay que resaltar, dado lo que la lista tiene acotado y lo que el eje está enseñando.
    ///
    /// Acercarse a un tramo acota la lista a él, así que después del gesto lo seleccionado y lo
    /// dibujado son lo mismo: resaltarlo pintaría el eje entero de color, que no señala nada. Lo que
    /// dice dónde se está es el pie de la barra, y el resalte se guarda para lo que sí es una parte
    /// del eje — un tramo elegido en el que no se pudo entrar (`TimelineActivity.canZoom`).
    public static func highlight(
        _ selection: ClosedRange<Date>?, viewing: ClosedRange<Date>?
    ) -> ClosedRange<Date>? {
        selection == viewing ? nil : selection
    }

    /// El aviso que acompaña siempre a la barra.
    ///
    /// No es una nota al pie que se pueda omitir: el eje cuenta **todos** los paquetes guardados,
    /// también los de conexiones que los filtros de la lista esconden (el de host se resuelve en
    /// memoria, así que no se puede empujar a la consulta que agrega). Sin decirlo, un usuario con un
    /// filtro puesto leería los picos del eje como suyos.
    ///
    /// Lo que cambia al acercarse es **de cuánto** habla el eje, no de si está filtrado: sigue
    /// contándolo todo, pero ya solo dentro del tramo al que se ha bajado. Dejar la frase de siempre
    /// afirmaría que las barras cubren el historial entero, y desde el segundo nivel de acercamiento
    /// eso es falso.
    public static func note(zoomed: Bool) -> String {
        guard zoomed else {
            return String(
                localized: "timeline.scrub.note.wholeHistory",
                defaultValue: "Activity for everything recorded — filters don't change it.",
                comment: """
                    Permanent caption under the activity graph while it spans the whole history. \
                    Its job is the second half: the graph counts every saved packet, including \
                    those of connections the list's filters hide, so without saying it a user \
                    with a filter on would read the peaks as theirs.
                    """
            )
        }

        return String(
            localized: "timeline.scrub.note.zoomed",
            defaultValue: "Activity for this stretch only — filters don't change it.",
            comment: """
                Same caption once the graph has been zoomed into one stretch of the history. \
                What changes is how much it covers, not that it is unfiltered: keeping the other \
                sentence would claim the bars still cover everything saved, which is false here.
                """
        )
    }

    /// De qué habla el eje, que es lo que encabeza su nombre accesible. Son dos claves y no un
    /// fragmento con una palabra intercambiada: el trozo entero es una frase que un idioma puede
    /// necesitar decir de otra manera según lo que abarque.
    private static var wholeHistoryScope: String {
        String(
            localized: "timeline.scrub.axis.scope.wholeHistory",
            defaultValue: "Activity over the whole history",
            comment: """
                Opening of the activity graph's VoiceOver name while it spans everything saved. \
                It is interpolated into the sentences that follow it (see the sibling keys with \
                the counts), so it carries no final punctuation.
                """
        )
    }

    private static var selectedStretchScope: String {
        String(
            localized: "timeline.scrub.axis.scope.zoomed",
            defaultValue: "Activity over the selected stretch",
            comment: """
                Opening of the activity graph's VoiceOver name once it has been zoomed into one \
                stretch of the history. Same shape as its sibling key: no final punctuation, it \
                is interpolated into the sentences that carry the counts.
                """
        )
    }

    /// Lo que VoiceOver anuncia como nombre de la barra: qué abarca el eje y qué forma tiene.
    ///
    /// Va aquí y no en la vista por lo mismo que la nota: es la misma afirmación sobre qué abarca el
    /// eje, dicha para quien no lo ve. Y el total va en el **nombre** y no en el valor porque el valor
    /// es lo que cambia al recorrer el eje (`ScrubAccessibility.reading`): un valor que repitiese el
    /// total en cada tramo escondería lo único que se está moviendo.
    public static func axisLabel(for axis: ActivityAxis, zoomed: Bool) -> String {
        let scope = zoomed ? selectedStretchScope : wholeHistoryScope

        guard !axis.isEmpty else {
            return String(
                localized: "timeline.scrub.axis.empty",
                defaultValue: "\(scope). No recorded activity yet.",
                comment: """
                    VoiceOver name of the activity graph when there are no bars to read. The \
                    placeholder is what the graph covers (see the scope keys). 'Yet' is \
                    load-bearing: nothing is broken, nothing has been recorded so far.
                    """
            )
        }

        return String(
            localized: "timeline.scrub.axis.summary",
            defaultValue: """
                \(scope). \(packetCount(axis.totalPackets)) recorded across \
                \(intervalCount(axis.bars.count)).
                """,
            comment: """
                VoiceOver name of the activity graph: what it covers, how much traffic it counts \
                and in how many intervals it is drawn — everything a sighted user gets from one \
                look. The three placeholders are the scope, the packet count and the interval \
                count, each already a phrase of its own (see the sibling keys). The amount goes \
                in the name and not in the value because the value is what changes while walking \
                the graph.
                """
        )
    }

    /// Lo que VoiceOver dice que pasa al activar el eje.
    ///
    /// La promesa depende de si se puede bajar más: anunciar un acercamiento en un eje que ya está en
    /// el escalón más fino sería ofrecer un gesto que no hace nada.
    public static func axisHint(zoomable: Bool) -> String {
        guard zoomable else {
            return String(
                localized: "timeline.scrub.axis.hint.filterOnly",
                defaultValue: "Filters the list to the interval you pick.",
                comment: """
                    VoiceOver hint on the activity graph when no interval of it can be \
                    subdivided any further. It promises only what activating does here, since \
                    announcing a zoom that cannot happen offers a dead gesture. Like every hint \
                    in this language it describes the result and never gives an order.
                    """
            )
        }

        return String(
            localized: "timeline.scrub.axis.hint.zoomable",
            defaultValue: "Filters the list to the interval you pick and zooms into it.",
            comment: """
                VoiceOver hint on the activity graph where picking an interval also redraws the \
                graph inside it. Both halves matter: filtering and zooming are the same gesture \
                here, so a hint that named only one would surprise on the other.
                """
        )
    }

    /// Lo que se dice cuando la retención se lleva por delante el tramo al que se había bajado.
    ///
    /// El eje se dibuja sobre lo que hay guardado, así que un tramo del que ya no queda ningún paquete
    /// no se puede enseñar: quedaría un eje plano a cero, que es exactamente lo que la barra no dibuja
    /// nunca porque se lee como "aquí no hubo tráfico". Se vuelve a todo el historial **diciéndolo**,
    /// que es lo que distingue una salida de un salto inexplicado.
    /// Es una `var` calculada y no una `static let`, como toda la copia de la app: una constante se
    /// resuelve la primera vez que alguien la lee y dejaría el idioma congelado en el que hubiera
    /// entonces.
    public static var expiredZoomNotice: String {
        String(
            localized: "timeline.scrub.notice.expiredZoom",
            defaultValue: """
                The stretch you were viewing is no longer stored. Showing the whole history.
                """,
            comment: """
                Warning shown when retention deleted the stretch of history the graph had been \
                zoomed into. Both sentences are needed: what happened, and where the graph went \
                instead — a graph that jumps somewhere else without saying why reads as a fault.
                """
        )
    }

    // MARK: - El pie de la barra

    /// Sube un nivel del acercamiento. Se llama por lo que hace y no *Zoom out* porque el pie ya dice
    /// dónde se está: el botón es la salida de ahí.
    public static var zoomOutActionTitle: String {
        String(
            localized: "timeline.scrub.action.zoomOut",
            defaultValue: "Back",
            comment: """
                Button under the activity graph that leaves the stretch it is showing and goes up \
                one level, taking the list with it. It undoes the last zoom, so it must not read \
                as 'go back to the previous screen'.
                """
        )
    }

    /// Sale de todos los niveles de golpe. Solo se ofrece pasado el primero: con un solo nivel puesto
    /// *Back* ya lleva ahí, y dos botones para el mismo destino se leen como dos destinos.
    public static var showWholeHistoryActionTitle: String {
        String(
            localized: "timeline.scrub.action.showWholeHistory",
            defaultValue: "All",
            comment: """
                Button under the activity graph that leaves every level of zoom at once and shows \
                the whole history again. It sits next to the one that goes up a single level, so \
                the two must not read as the same destination.
                """
        )
    }

    /// Suelta el tramo al que la lista está acotada. No se ofrece mientras se está eligiendo uno:
    /// prometería deshacer un filtro que todavía no se ha puesto.
    public static var clearSelectionActionTitle: String {
        String(
            localized: "timeline.scrub.action.clearSelection",
            defaultValue: "Clear",
            comment: """
                Button under the activity graph that releases the stretch the list is narrowed \
                to. It undoes one selection made on the graph, not the filters of the menu above \
                (those have their own wording) and not the history.
                """
        )
    }

    /// Lo que VoiceOver oye de la fila que dice a qué tramo se ha bajado. La fila entera es un solo
    /// elemento —el icono, la fecha y sus salidas—, así que sin nombre se leería como una fecha suelta.
    public static var viewingStretchLabel: String {
        String(
            localized: "timeline.scrub.viewing.accessibilityLabel",
            defaultValue: "Viewing one stretch of the history",
            comment: """
                VoiceOver name of the row under the activity graph that says which stretch of the \
                history the graph has been zoomed into. The dates themselves are read after it as \
                the value, so this names what they are.
                """
        )
    }

    // MARK: - Piezas que se dicen en varios sitios

    /// Un tramo fechado, con las dos fechas **ya formateadas** por la vista.
    ///
    /// La composición vive aquí y no en SwiftUI —donde era `Text(a) + Text(" – ") + Text(b)`— porque
    /// el separador y el orden de los extremos son propiedades de un idioma, y ahí no llega ningún
    /// traductor. De paso desaparece la entrada `" – "` que el `Text` literal había convertido en
    /// unidad de traducción. Formatear las fechas sigue siendo de la vista: es quien sabe del huso y
    /// del idioma del dispositivo, y con qué precisión hacerlo lo decide `scale(for:)`.
    public static func interval(from start: String, to end: String) -> String {
        String(
            localized: "timeline.scrub.interval",
            defaultValue: "\(start) – \(end)",
            comment: """
                A stretch of time, shown under the activity graph and read out by VoiceOver. The \
                placeholders are the start and the end, already formatted for the device's locale \
                and time zone. Only the separator and the order are translatable here.
                """
        )
    }

    /// Cuántos paquetes, en palabras. Lo leen el nombre del eje y la lectura del cursor, y es **una
    /// sola propiedad** para que las dos no puedan discrepar al traducirse.
    ///
    /// Es un plural escrito como **dos claves hermanas**, la excepción consciente que documenta
    /// `docs/development/02-coding-standards.md`: el marcado de concordancia automática no se resuelve
    /// sin catálogo y el bundle de tests no lleva ninguno, así que saldría crudo. Correcto para inglés
    /// y español; el primer idioma con más formas obliga a fundir el par en una clave con variaciones
    /// en el catálogo.
    public static func packetCount(_ count: Int) -> String {
        guard count != 1 else {
            return String(
                localized: "timeline.scrub.packets.one",
                defaultValue: "1 packet",
                comment: """
                    How much traffic an interval or the whole graph holds, when it is exactly one \
                    packet. See the plural form in the sibling key; a language with more plural \
                    forms needs both merged into one key with catalog variations.
                    """
            )
        }

        return String(
            localized: "timeline.scrub.packets.other",
            defaultValue: "\(DisplayFormat.count(UInt64(max(0, count)))) packets",
            comment: """
                How much traffic an interval or the whole graph holds, for any count other than \
                one. The placeholder is the already-grouped number of packets. An interval with \
                none is named rather than counted, and has its own key.
                """
        )
    }

    /// Cuántos tramos, en palabras. Lo leen el nombre del eje (en cuántos está dibujado) y la lectura
    /// del cursor (cuántos lleva elegidos), que son la misma cuenta dicha en dos sitios.
    public static func intervalCount(_ count: Int) -> String {
        guard count != 1 else {
            return String(
                localized: "timeline.scrub.intervals.one",
                defaultValue: "1 interval",
                comment: """
                    How many intervals of the activity graph something covers, when it is exactly \
                    one. See the plural form in the sibling key; a language with more plural \
                    forms needs both merged into one key with catalog variations.
                    """
            )
        }

        return String(
            localized: "timeline.scrub.intervals.other",
            defaultValue: "\(DisplayFormat.count(UInt64(max(0, count)))) intervals",
            comment: """
                How many intervals of the activity graph something covers, for any count other \
                than one. The placeholder is the number of intervals.
                """
        )
    }
}
