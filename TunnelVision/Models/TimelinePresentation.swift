import Foundation
import Shared

/// Qué enseña la Timeline para una instantánea dada del historial.
///
/// Los estados de `docs/ux/screens.md` (`empty` / `loading older` / `populated`) no son casos de un
/// enum del servicio: salen de combinar `HistoryState` con si la lista tiene filas y con si hay algún
/// filtro puesto. Esa combinación es exactamente donde se cuela un vacío que miente —decir "no hay
/// conexiones" cuando lo que pasa es que el filtro no encuentra nada, o tapar una lista ya pintada
/// con una tarjeta de error—, así que vive aquí, en un valor puro, y no repartida por la vista.

/// Lo que el usuario puede hacer desde un hueco de la pantalla.
public enum TimelineAction: Sendable, Equatable {
    /// Volver a intentar la carga que falló.
    case retry
    /// Quitar todos los filtros y volver a la lista completa.
    case clearFilters
    /// Seguir buscando más atrás en el historial. Es la salida del vacío que **todavía** no es un
    /// vacío: una carga recorre un número acotado de páginas, así que un filtro muy selectivo puede
    /// no encontrar nada sin que eso signifique que no hay nada.
    case searchFurtherBack
}

/// Un hueco de la pantalla con su copia: el vacío que enseña y el error accionable del principio 7.
/// La forma es la misma en todas las pantallas (`ScreenPlaceholder`); lo que la Timeline pone es su
/// conjunto de acciones.
public typealias TimelinePlaceholder = ScreenPlaceholder<TimelineAction>

/// El cuerpo de la pantalla. Exhaustivo a propósito: cada instantánea cae en uno y solo uno.
public enum TimelineContent: Sendable, Equatable {
    /// Primera carga sin nada que enseñar todavía.
    case loading
    /// Hay filas: se pinta la lista.
    case list
    /// No hay filas y hay algo que explicar.
    case placeholder(TimelinePlaceholder)
}

/// Una fila de la lista con su copia ya compuesta.
///
/// La fila la pintaba SwiftUI componiendo a mano lo que oye VoiceOver —`"\(estado) \(servicio).
/// Received \(x), sent \(y), lasted \(z)."`—, que es una decisión de idioma (separadores y orden)
/// tomada donde ningún traductor llega. Desde M11 la compone este valor, que además es donde se puede
/// afirmar. Es el mismo movimiento que hizo `TopTalkerPresentation` en la Dashboard.
public struct TimelineRowPresentation: Sendable, Equatable {

    /// La dirección del host, que encabeza la fila. No es copia salvo cuando no se pudo repartir los
    /// extremos, y entonces la pone `FlowDisplay.unknownHost`.
    public let host: String

    /// El protocolo y, si se sabe, el puerto.
    public let service: String

    public let bytesIn: String
    public let bytesOut: String
    public let duration: String

    /// Lo que VoiceOver anuncia como nombre de la fila: el host y nada más, porque todo lo demás es
    /// su valor y se lee después.
    public var accessibilityLabel: String { host }

    /// El estado del cifrado y las tres cifras en una sola frase, que es como se oyen seguidas.
    public let accessibilityValue: String

    public init(
        host: String,
        service: String,
        bytesIn: String,
        bytesOut: String,
        duration: String,
        accessibilityValue: String
    ) {
        self.host = host
        self.service = service
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.duration = duration
        self.accessibilityValue = accessibilityValue
    }
}

/// Una fila de la lista tal y como se pinta: el flujo que la respalda y la copia que enseña, ya
/// compuesta.
///
/// Existe para que la copia se componga **una vez por lista** y no una vez por fotograma. La fila la
/// pedía en su `body` (`TimelinePresentation.row(flow)`), así que un scroll rápido rehacía las cinco
/// cadenas de cada fila visible en cada fotograma —incluida la frase larga que solo oye VoiceOver,
/// hubiera o no alguien escuchando—, y desde la migración al catálogo cada una de ellas es además una
/// búsqueda en el bundle. Componerlas donde vive la lista es trabajo por decisión: cuando el
/// historial cambia, y no cuando el dedo se mueve.
///
/// El flujo viaja con su copia y no aparte porque son lo mismo dicho dos veces: mientras el par sea
/// el valor que la vista recibe, no hay forma de pintar una fila con la copia de otra ni de que una
/// fila dibujada se quede con la de antes.
public struct TimelineRow: Identifiable, Sendable, Equatable {

    /// La conexión guardada. La vista todavía la necesita entera: la hora la fecha ella (12/24 h es
    /// del dispositivo) y el estado del cifrado es un icono, no una cadena.
    public let flow: HistoryFlow

    public let presentation: TimelineRowPresentation

    /// La identidad es la del flujo: la copia es un derivado suyo y no puede distinguir dos filas que
    /// el historial considera la misma.
    public var id: HistoryFlow.ID { flow.id }

    public init(flow: HistoryFlow, presentation: TimelineRowPresentation) {
        self.flow = flow
        self.presentation = presentation
    }
}

/// El pie de la lista, que solo existe cuando ya hay filas pintadas.
public enum TimelineFooter: Sendable, Equatable {
    case none
    /// Queda historial por detrás: es lo que dispara `loadMore()` al llegar al final.
    case loadMore
    case loadingOlder
    /// Se acabó el historial guardado.
    case endOfHistory
    /// Falló al traer más, con la lista ya pintada.
    case failed(String)
}

public enum TimelinePresentation {

    /// Qué cuerpo le toca a la instantánea.
    ///
    /// La regla que manda sobre todas: **si hay filas, se pintan**. Una lista ya dibujada vale más
    /// que cualquier tarjeta, incluida la de error — el fallo de una carga posterior se cuenta en el
    /// pie sin quitarle al usuario lo que ya estaba leyendo.
    public static func content(for snapshot: HistorySnapshot) -> TimelineContent {
        if !snapshot.flows.isEmpty { return .list }

        switch snapshot.state {
        case .idle, .loading, .loadingOlder:
            // `loadingOlder` sin filas no debería darse (el lector marca `loading` cuando la lista
            // está vacía), pero si se diera, lo honesto sigue siendo "cargando" y no un vacío.
            return .loading

        case .failed(let error):
            return .placeholder(failure(error))

        case .loaded:
            guard snapshot.filter.isActive else { return .placeholder(noHistoryYet) }
            // Una carga recorre como mucho `maxPagesPerLoad` páginas, así que con un filtro muy
            // selectivo puede volver **vacía y con historial detrás**. Decir "no matches" ahí es el
            // vacío que miente: no se ha mirado todo, y el usuario cerraría la búsqueda creyendo que
            // sí. Se separan por `hasMore`, que es exactamente lo que distingue los dos casos.
            return .placeholder(snapshot.hasMore ? noMatchesYet : noMatches)
        }
    }

    /// Qué le toca al pie de la lista. Sin filas no hay pie: lo que haya que decir lo dice el cuerpo.
    public static func footer(for snapshot: HistorySnapshot) -> TimelineFooter {
        guard !snapshot.flows.isEmpty else { return .none }

        switch snapshot.state {
        case .loadingOlder:
            return .loadingOlder
        case .failed:
            return .failed(
                String(
                    localized: "timeline.footer.olderFailed",
                    defaultValue: "Couldn't load older connections. Pull down to try again.",
                    comment: """
                        Shown at the bottom of a drawn list when fetching the next page failed. \
                        It never replaces the list, so it has to say both things: what did not \
                        arrive, and the gesture that retries it (the pull-to-refresh every list \
                        on iOS has).
                        """
                )
            )
        case .idle, .loading, .loaded:
            return snapshot.hasMore ? .loadMore : .endOfHistory
        }
    }

    /// La copia de una fila, compuesta aquí y no en SwiftUI.
    public static func row(_ flow: HistoryFlow) -> TimelineRowPresentation {
        let service = FlowDisplay.service(flow)
        let bytesIn = DisplayFormat.bytes(flow.stored.bytesIn)
        let bytesOut = DisplayFormat.bytes(flow.stored.bytesOut)
        let duration = DisplayFormat.duration(flow.duration)

        return TimelineRowPresentation(
            host: FlowDisplay.host(flow),
            service: service,
            bytesIn: bytesIn,
            bytesOut: bytesOut,
            duration: duration,
            accessibilityValue: String(
                localized: "timeline.row.accessibilityValue",
                defaultValue: """
                    \(TLSStatusPresentation.forStatus(flow.tlsStatus).accessibilityDescription) \
                    \(service). Received \(bytesIn), sent \(bytesOut), lasted \(duration).
                    """,
                comment: """
                    VoiceOver value of a connection row, read after the host. In order: what the \
                    encryption badge says, what the connection was (protocol and port), the bytes \
                    received, the bytes sent and how long it lasted.
                    """
            )
        )
    }

    /// La lista entera, cada flujo con su copia. Es lo que el view model publica y la vista pinta.
    ///
    /// No decide nada que `row(_:)` no decidiera ya: existe para que haya **un solo sitio** donde la
    /// lista se convierte en filas, que es el sitio donde se sabe cuándo hay que rehacerla.
    public static func rows(for flows: [HistoryFlow]) -> [TimelineRow] {
        flows.map { TimelineRow(flow: $0, presentation: row($0)) }
    }

    // MARK: - Rótulos de la pantalla

    /// El título de la pantalla. Son `var` calculadas y no `let`: una constante estática se resuelve
    /// la primera vez que alguien la lee y dejaría el idioma congelado en el que hubiera entonces.
    public static var screenTitle: String {
        String(
            localized: "timeline.title",
            defaultValue: "Timeline",
            comment: """
                Title of the second screen: the saved connections, most recent first. It names \
                what is shown (a history going backwards in time), not a widget.
                """
        )
    }

    /// El rótulo de la pestaña. Dice lo mismo que el título y es **otra clave**, por lo mismo que en
    /// la Dashboard: la pestaña comparte su ancho con otras tres y un idioma puede necesitar acortar
    /// ahí sin acortar el titular.
    public static var tabTitle: String {
        String(
            localized: "timeline.tab",
            defaultValue: "Timeline",
            comment: """
                Tab bar label of the second screen. Same word as its title, separate key: the tab \
                bar shares its width with three other items, so it may need a shorter form.
                """
        )
    }

    /// La pista de la barra de búsqueda. Dice **hosts** y no "conexiones" porque es lo único por lo
    /// que busca: el texto se compara contra el host que la fila enseña, no contra todo lo guardado.
    public static var searchPrompt: String {
        String(
            localized: "timeline.search.prompt",
            defaultValue: "Search hosts",
            comment: """
                Placeholder of the Timeline's search field. It names hosts on purpose: the text is \
                matched against the host shown on each row (the SNI or the remote address) and \
                against nothing else, so a broader word would promise a search that does not exist.
                """
        )
    }

    // MARK: - El menú de filtros

    public static var filterMenuTitle: String {
        String(
            localized: "timeline.filters.menu",
            defaultValue: "Filters",
            comment: """
                Name of the toolbar button that opens the filter menu, read by VoiceOver. Its \
                icon fills in when something is filtered, so the word must work for both states.
                """
        )
    }

    public static var timeSectionTitle: String {
        String(
            localized: "timeline.filters.section.time",
            defaultValue: "Time",
            comment: "Heading of the filter menu's first section: when the connections happened."
        )
    }

    public static var protocolSectionTitle: String {
        String(
            localized: "timeline.filters.section.protocol",
            defaultValue: "Protocol",
            comment: """
                Heading of the filter menu's second section, whose checkboxes are TCP, UDP and \
                Other. 'Protocol' here is the networking sense of the word.
                """
        )
    }

    public static var encryptionSectionTitle: String {
        String(
            localized: "timeline.filters.section.encryption",
            defaultValue: "Encryption",
            comment: """
                Heading of the filter menu's third section, whose checkboxes are the four \
                encryption states a connection can be in.
                """
        )
    }

    /// Quitar los filtros se ofrece en dos sitios —el menú y el vacío que no encuentra nada— y es
    /// **una sola propiedad** que leen los dos, no dos literales iguales: compartir por coincidencia
    /// es cómo una traducción mueve uno y deja el otro sin que nada avise.
    public static var clearFiltersActionTitle: String {
        String(
            localized: "timeline.filters.clear",
            defaultValue: "Clear filters",
            comment: """
                Removes every filter and brings the whole list back. Shown in the filter menu and \
                also as the way out of the empty state a filter produced, so it must read the \
                same in both: it undoes the filters, it does not clear the history.
                """
        )
    }

    // MARK: - Los vacíos

    /// El vacío que **enseña**: no hay historial y tampoco hay nada roto.
    private static var noHistoryYet: TimelinePlaceholder {
        TimelinePlaceholder(
            title: String(
                localized: "timeline.empty.noHistory.title",
                defaultValue: "No connections yet",
                comment: """
                    Heading of the Timeline when nothing has ever been recorded. Nothing is \
                    broken and there is nothing to fix: 'yet' is load-bearing.
                    """
            ),
            message: String(
                localized: "timeline.empty.noHistory.message",
                defaultValue: """
                    Once monitoring is on, every connection this device makes is recorded here — \
                    on the device, and nowhere else.
                    """,
                comment: """
                    Body of the empty Timeline before anything was recorded. The second half is \
                    the product's core promise and is repeated here on purpose: nothing is \
                    uploaded anywhere.
                    """
            ),
            systemImage: "clock.arrow.circlepath",
            role: .neutral
        )
    }

    /// El otro vacío: se ha recorrido el historial **entero** y el filtro no deja pasar nada. La salida
    /// es quitarlo, y por eso la ofrece aquí mismo en vez de dejar al usuario buscándola en la barra.
    ///
    /// Que sea entero es lo que lo separa de `noMatchesYet`, y lo decide `hasMore`: sin esa condición
    /// esta tarjeta salía también a mitad de búsqueda, dando por respuesta lo que era una página.
    private static var noMatches: TimelinePlaceholder {
        TimelinePlaceholder(
            title: String(
                localized: "timeline.empty.noMatches.title",
                defaultValue: "No matches",
                comment: """
                    Heading of the Timeline when there is history but the filters let nothing \
                    through. It must not read as 'nothing was recorded': that is the other empty \
                    state, and confusing them makes the user blame the app for their own filter.
                    """
            ),
            message: String(
                localized: "timeline.empty.noMatches.message",
                defaultValue: "No recorded connection matches the filters you set.",
                comment: """
                    Body of the Timeline when the filters match nothing. 'You set' names who did \
                    it, which is what points at the way out offered just below.
                    """
            ),
            systemImage: "line.3.horizontal.decrease.circle",
            role: .neutral,
            actionTitle: clearFiltersActionTitle,
            action: .clearFilters
        )
    }

    /// El tercer vacío, y el único que no es definitivo: el filtro no ha encontrado nada **en lo que
    /// se ha mirado**, y queda historial por detrás.
    ///
    /// Existe porque una carga no recorre la base entera: se para a las `maxPagesPerLoad` páginas para
    /// no dejar la pantalla colgada en una consulta larga. Con un filtro poco selectivo eso no se nota
    /// nunca; con uno que casa una conexión de cada mil, la primera carga vuelve vacía. Enseñar ahí
    /// "no matches" sería contar como respuesta lo que solo es el final de una página.
    ///
    /// La salida que ofrece es **seguir buscando** y no limpiar el filtro: quitarlo está a un toque en
    /// la barra, y ofrecerlo aquí insinuaría que la búsqueda ya terminó.
    private static var noMatchesYet: TimelinePlaceholder {
        TimelinePlaceholder(
            title: String(
                localized: "timeline.empty.noMatchesYet.title",
                defaultValue: "Nothing yet in the most recent connections",
                comment: """
                    Heading of the Timeline when the filters matched nothing in the part of the \
                    history that has been read so far, and there is older history left. 'Yet' and \
                    'most recent' are both load-bearing: this is not the answer, it is how far the \
                    search has got. The sibling key without 'yet' is the state where the whole \
                    history really was searched.
                    """
            ),
            message: String(
                localized: "timeline.empty.noMatchesYet.message",
                defaultValue: """
                    The search reads your history a chunk at a time. Nothing matched in the most \
                    recent one — there's older history left to look through.
                    """,
                comment: """
                    Body of that state. It explains why the answer is not final without naming an \
                    internal limit the user cannot act on: what they can do is keep looking, which \
                    the button below offers.
                    """
            ),
            systemImage: "text.magnifyingglass",
            role: .neutral,
            actionTitle: String(
                localized: "timeline.empty.noMatchesYet.action",
                defaultValue: "Keep looking",
                comment: """
                    Button that reads the next chunk of older history with the same filters still \
                    applied. It continues a search rather than starting one, which is why it does \
                    not say 'Search'.
                    """
            ),
            action: .searchFurtherBack
        )
    }

    /// La tarjeta de fallo. Como la del control de monitorización, **siempre** ofrece salida.
    private static func failure(_ error: HistoryError) -> TimelinePlaceholder {
        let title: String
        let message: String
        let diagnostic: String

        switch error {
        case .queryFailed(let detail):
            title = String(
                localized: "timeline.failure.queryFailed.title",
                defaultValue: "Couldn't open the history",
                comment: """
                    Heading when the database of saved connections could not be read at all. It \
                    is about reading the history, not about monitoring, which keeps running.
                    """
            )
            message = String(
                localized: "timeline.failure.queryFailed.message",
                defaultValue: """
                    The connections saved on this device couldn't be read. Monitoring keeps \
                    recording while you're here.
                    """,
                comment: """
                    Body when the saved history could not be read. The second sentence is the \
                    point: the failure is in showing the history, and nothing is being lost \
                    meanwhile.
                    """
            )
            diagnostic = detail

        case .corruptData(let detail):
            title = String(
                localized: "timeline.failure.corruptData.title",
                defaultValue: "Some history couldn't be read",
                comment: """
                    Heading when part of the saved history is damaged. 'Some' is deliberate and \
                    distinguishes this from a history that could not be opened at all.
                    """
            )
            message = String(
                localized: "timeline.failure.corruptData.message",
                defaultValue: "Part of the saved history is damaged, so it can't be shown.",
                comment: """
                    Body when part of the saved history is damaged. It states the consequence \
                    (it cannot be shown) and claims nothing about repairing it.
                    """
            )
            diagnostic = detail
        }

        return TimelinePlaceholder(
            title: title,
            message: message,
            systemImage: "exclamationmark.triangle",
            role: .warning,
            actionTitle: String(
                localized: "timeline.failure.retry",
                defaultValue: "Try again",
                comment: """
                    Retries opening the history after a failure. Every failure on this screen \
                    offers it: a card with no way out is the dead end the UX principles forbid.
                    """
            ),
            action: .retry,
            diagnostic: diagnostic
        )
    }

    // MARK: - El pie y el destino que no se alcanza

    /// Lo que dice el pie cuando ya no queda historial por detrás. Es una **afirmación** y no un
    /// hueco: la lista se acabó porque eso es todo lo que hay guardado, no porque algo fallase.
    public static var endOfHistoryMessage: String {
        String(
            localized: "timeline.footer.endOfHistory",
            defaultValue: "That's every connection saved on this device.",
            comment: """
                Last line of the list once the whole saved history has been loaded. It states \
                that the list is complete, so it must not read as 'nothing more could be loaded'.
                """
        )
    }

    /// El destino de una fila cuyo historial ya no está abierto. En la práctica no se alcanza —una
    /// fila solo existe si hubo lector—, pero una pantalla en blanco sería peor que decirlo.
    public static var connectionUnavailable: TimelinePlaceholder {
        TimelinePlaceholder(
            title: String(
                localized: "timeline.connectionUnavailable.title",
                defaultValue: "Connection unavailable",
                comment: """
                    Heading of the screen reached by tapping a row whose history has since been \
                    closed. It says the connection cannot be opened right now, not that it is gone.
                    """
            ),
            message: String(
                localized: "timeline.connectionUnavailable.message",
                defaultValue: "The saved history closed before this connection could be opened.",
                comment: """
                    Body of the screen reached by tapping a row whose history has since been \
                    closed. It names what happened rather than blaming the connection, which is \
                    still recorded.
                    """
            ),
            systemImage: "questionmark.folder",
            role: .neutral
        )
    }
}
