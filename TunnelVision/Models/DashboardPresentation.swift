import Foundation

/// Un vacío que enseña, ya resuelto en copia (principio 7 de `docs/ux/00-ux-principles.md`).
///
/// Existe para que la decisión de **qué vacío es este** viva donde se puede probar y no en un `if` de
/// la vista: los dos huecos de la Dashboard dicen cosas distintas —uno espera a la extensión, el otro
/// afirma que no ha pasado tráfico— y confundirlos es exactamente el vacío que miente.
public struct EmptyStatePresentation: Sendable, Equatable {

    public let title: String
    public let message: String
    public let systemImage: String

    public init(title: String, message: String, systemImage: String) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
    }
}

/// Una fila del "quién está hablando ahora", con su copia ya compuesta.
///
/// La fila la pintaba SwiftUI componiendo frases a mano (`"\(x). Received \(y), sent \(z)"`), que es
/// una decisión de idioma —separadores y orden— tomada donde ningún traductor llega. Desde M11 la
/// compone este valor, que además es donde se puede afirmar.
public struct TopTalkerPresentation: Sendable, Equatable {

    /// La dirección del host, que encabeza la fila. No es copia: no se traduce ni se compone.
    public let host: String

    /// Cuántas conexiones distintas se han visto contra ese host en la ventana.
    public let connections: String

    public let bytesIn: String
    public let bytesOut: String

    /// Lo que VoiceOver anuncia como nombre de la fila: el host y nada más, porque el resto es su
    /// valor y se lee después.
    public var accessibilityLabel: String { host }

    /// Las tres cifras en una sola frase, que es como se oyen seguidas.
    public let accessibilityValue: String

    public init(
        host: String,
        connections: String,
        bytesIn: String,
        bytesOut: String,
        accessibilityValue: String
    ) {
        self.host = host
        self.connections = connections
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.accessibilityValue = accessibilityValue
    }
}

/// Toda la copia de la Dashboard que no es del control de monitorización (esa es de
/// `MonitoringPresentation`): el título, las fichas, la señal de back-pressure, el gráfico, los hosts
/// y los dos vacíos.
///
/// Es un tipo puro por lo mismo que sus vecinos, y desde M11 por una razón más: la copia sale del
/// código hacia el catálogo de cadenas por `String(localized:defaultValue:comment:)`, y el extractor
/// solo ve esas llamadas cuando clave, texto y comentario son literales **en el sitio de la llamada**
/// (`docs/development/02-coding-standards.md`, *Product copy*). Aquí caben, se prueban y llevan al
/// lado el comentario que las justifica; en una vista serían literales sueltos con el inglés de clave.
public enum DashboardPresentation {

    // MARK: - Rótulos de la pantalla

    /// El título de la pantalla y de su pestaña.
    ///
    /// Es `var` calculada y no `let`: una constante estática se resuelve una sola vez, la primera vez
    /// que alguien la lee, y dejaría el idioma congelado en el que hubiera entonces.
    public static var screenTitle: String {
        String(
            localized: "dashboard.title",
            defaultValue: "Dashboard",
            comment: "Title of the first screen and of its tab: the live view of what is happening now."
        )
    }

    /// El rótulo de la pestaña. Dice lo mismo que el título y es **otra clave**: la pestaña tiene un
    /// ancho de cuatro elementos y un idioma puede necesitar acortar ahí sin acortar el titular.
    public static var tabTitle: String {
        String(
            localized: "dashboard.tab",
            defaultValue: "Dashboard",
            comment: """
                Tab bar label of the first screen. Same word as its title, separate key: the tab \
                bar shares its width with three other items, so it may need a shorter form.
                """
        )
    }

    /// La ficha del contador de paquetes. Las otras dos las nombra `DirectionLabel`, que es la misma
    /// palabra que usan el gráfico y las filas de host.
    public static var packetsCounterLabel: String {
        String(
            localized: "dashboard.counter.packets",
            defaultValue: "Packets",
            comment: """
                Label of the counter tile showing how many packets have been seen this session. \
                'Packet' is the standard networking word and stays in the copy.
                """
        )
    }

    /// El encabezado del grupo de contadores.
    ///
    /// Existe desde la segunda pasada de diseño (2026-08-18) y su trabajo es **desambiguar**: las
    /// palabras *Received* y *Sent* aparecen dos veces seguidas en la pantalla —arriba como una tasa
    /// por segundo dentro del gráfico, aquí como el total acumulado— y sin un rótulo que diga de qué
    /// periodo habla cada grupo, la Dashboard enseña dos veces lo mismo. El grupo de al lado ya se
    /// llamaba *Busiest right now*; este era el único anónimo.
    public static var countersTitle: String {
        String(
            localized: "dashboard.counters.title",
            defaultValue: "This session",
            comment: """
                Heading of the three counter tiles (received, sent, packets). It names the period \
                they cover — everything since monitoring was switched on — which is what tells them \
                apart from the per-second rates shown in the chart right above.
                """
        )
    }

    /// El encabezado de la lista de hosts.
    public static var talkersTitle: String {
        String(
            localized: "dashboard.talkers.title",
            defaultValue: "Busiest right now",
            comment: """
                Heading of the list of hosts moving the most data at this moment. 'Right now' is \
                load-bearing: the list covers a rolling window of recent packets, not the history.
                """
        )
    }

    // MARK: - Los dos vacíos

    /// Qué hueco le toca a la lista de hosts cuando está vacía.
    ///
    /// Se distinguen sin inventarse nada: `isAttached` dice si el feed llegó a abrir el ring, que solo
    /// existe una vez la extensión ha arrancado. Sin ring, la app **espera**; con ring y sin paquetes,
    /// es que de verdad no ha pasado tráfico todavía. Decirlo al revés sería el vacío que miente.
    public static func talkersEmptyState(isAttached: Bool) -> EmptyStatePresentation {
        if isAttached {
            return EmptyStatePresentation(
                title: String(
                    localized: "dashboard.talkers.empty.noTraffic.title",
                    defaultValue: "No traffic yet",
                    comment: """
                        Heading of the empty list of hosts while monitoring is already running: \
                        there is a live feed, nothing has crossed it yet.
                        """
                ),
                message: String(
                    localized: "dashboard.talkers.empty.noTraffic.message",
                    defaultValue: "Connections show up here as soon as your apps talk to the network.",
                    comment: """
                        Body of the empty list of hosts while monitoring is running. It states \
                        that nothing else is needed from the user: waiting is the whole action.
                        """
                ),
                systemImage: "antenna.radiowaves.left.and.right"
            )
        }

        return EmptyStatePresentation(
            title: String(
                localized: "dashboard.talkers.empty.waiting.title",
                defaultValue: "Nothing to show yet",
                comment: """
                    Heading of the empty list of hosts before monitoring has ever run, when there \
                    is no live feed to read from.
                    """
            ),
            message: String(
                localized: "dashboard.talkers.empty.waiting.message",
                defaultValue: "Start monitoring and the connections your device makes will appear here.",
                comment: """
                    Body of the empty list of hosts before monitoring has ever run. It names the \
                    action that fills it, which is the button at the top of the same screen.
                    """
            ),
            systemImage: "shield.lefthalf.filled"
        )
    }

    // MARK: - Back-pressure

    /// La señal de que el ring se llenó y la extensión descartó registros.
    ///
    /// "Honesta, no alarmante" (principio 4 de `docs/ux/00-ux-principles.md`): dice qué se perdió y,
    /// sobre todo, qué **no** se perdió — los contadores los lleva la extensión antes del ring, así
    /// que siguen siendo exactos aunque la lista no enseñe esos paquetes.
    public static func droppedRecordsNotice(_ droppedRecords: UInt64) -> String {
        String(
            localized: "dashboard.backPressure.notice",
            defaultValue: """
                \(DisplayFormat.count(droppedRecords)) records skipped while traffic peaked — \
                counters stay accurate, the list below doesn't show them.
                """,
            comment: """
                Shown only when the live feed had to drop records because traffic outran it. The \
                placeholder is the number of dropped records. The reassurance is the point: the \
                counters are computed before the queue, so they remain exact.
                """
        )
    }

    // MARK: - El gráfico

    /// Lo que VoiceOver anuncia como nombre del gráfico. Nunca "gráfico": lo que se lee son los datos.
    public static var chartAccessibilityLabel: String {
        String(
            localized: "dashboard.chart.accessibilityLabel",
            defaultValue: "Traffic over the last minute",
            comment: """
                VoiceOver name of the live throughput chart. It names the data and the window, \
                never the widget: 'chart' would tell a blind user nothing they can use.
                """
        )
    }

    /// Las dos tasas actuales en una sola frase, que es como se oyen seguidas.
    public static func chartAccessibilityValue(rateIn: Double, rateOut: Double) -> String {
        String(
            localized: "dashboard.chart.accessibilityValue",
            defaultValue: """
                Receiving \(DisplayFormat.rate(bytesPerSecond: rateIn)), \
                sending \(DisplayFormat.rate(bytesPerSecond: rateOut))
                """,
            comment: """
                VoiceOver value of the throughput chart: the current inbound and outbound rates, \
                in that order. First placeholder is the inbound rate, second the outbound one.
                """
        )
    }

    // MARK: - Los hosts

    /// La copia de una fila de host, compuesta aquí y no en SwiftUI.
    public static func topTalker(_ talker: TopTalker) -> TopTalkerPresentation {
        let connections = connectionsSummary(talker.flowCount)
        let bytesIn = DisplayFormat.bytes(talker.bytesIn)
        let bytesOut = DisplayFormat.bytes(talker.bytesOut)

        return TopTalkerPresentation(
            host: talker.displayHost,
            connections: connections,
            bytesIn: bytesIn,
            bytesOut: bytesOut,
            accessibilityValue: String(
                localized: "dashboard.topTalker.accessibilityValue",
                defaultValue: "\(connections). Received \(bytesIn), sent \(bytesOut)",
                comment: """
                    VoiceOver value of a row in the busiest-hosts list. First placeholder is the \
                    connection count sentence, then the bytes received and the bytes sent.
                    """
            )
        )
    }

    /// Cuántas conexiones, en palabras.
    ///
    /// **Excepción consciente a la regla de que el inglés vive en el código** (la única del proyecto
    /// hasta ahora, y `docs/development/02-coding-standards.md` la nombra): esto es un plural, y un
    /// plural bien hecho se escribe como variaciones **en el catálogo**, no como dos claves. Aquí se
    /// hace con dos claves a propósito, y la razón está medida: el marcado de concordancia automática
    /// (`^[\(n) connection](inflect: true)`) **no se resuelve cuando no hay catálogo**, y el bundle de
    /// tests no lo lleva —sale el marcado crudo—, así que la copia que afirman los tests dejaría de
    /// ser la que enseña la app, que es justo lo que la regla existe para impedir. Dos claves son
    /// correctas para inglés y español; el día que se traduzca a un idioma con más formas de plural,
    /// este par tiene que fundirse en una sola clave con variaciones en el catálogo.
    private static func connectionsSummary(_ flowCount: Int) -> String {
        guard flowCount != 1 else {
            return String(
                localized: "dashboard.topTalker.connections.one",
                defaultValue: "1 connection",
                comment: """
                    Secondary line of a row in the busiest-hosts list when exactly one connection \
                    was seen against that host. See the plural form in the sibling key; a language \
                    with more plural forms needs both merged into one key with catalog variations.
                    """
            )
        }

        return String(
            localized: "dashboard.topTalker.connections.other",
            defaultValue: "\(DisplayFormat.count(UInt64(max(flowCount, 0)))) connections",
            comment: """
                Secondary line of a row in the busiest-hosts list for any count other than one, \
                zero included. The placeholder is the number of distinct connections seen against \
                that host in the recent window.
                """
        )
    }
}
