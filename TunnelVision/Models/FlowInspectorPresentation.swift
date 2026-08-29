import Foundation
import Shared

/// Qué enseña el Flow Inspector (`docs/ux/screens.md`): la 5-tupla en lenguaje humano, la explicación
/// del cifrado y la lista de paquetes de una conexión.
///
/// Todo lo que decide *qué se lee* vive aquí, en valores puros, por lo mismo que en la Timeline: la
/// traducción de un paquete a lo que significó en la vida de la conexión es una decisión de producto
/// —y la que más fácilmente se convierte en jerga—, así que se afirma en un test en vez de revisarse
/// a ojo.

/// Lo que se puede hacer desde un hueco de esta pantalla. Solo hay una salida: volver a pedir los
/// paquetes. No hay filtros que limpiar aquí.
public enum FlowInspectorAction: Sendable, Equatable {
    case retry
}

public typealias FlowInspectorPlaceholder = ScreenPlaceholder<FlowInspectorAction>

/// En qué punto está la carga de los paquetes de la conexión.
///
/// Al contrario que la Timeline —cuyas acciones de carga nunca lanzan—, aquí `failed` es un estado de
/// primera clase: `HistoryReader.packets(forFlow:)` **sí** lanza, porque quien lo llama abrió una
/// pantalla justo para enseñar eso (`docs/spec/app-services.md`).
public enum FlowInspectorState: Sendable, Equatable {
    case idle
    case loading
    case loaded
    case failed(HistoryError)
}

/// Lo que un paquete significó en la vida de la conexión.
///
/// Es la decisión de copia de la pantalla. `TCPFlags` es un `OptionSet` de siglas (SYN/FIN/RST/...) y
/// enseñarlas crudas es jerga (principio 3 de `docs/ux/00-ux-principles.md`): lo que le importa al
/// usuario es que la conexión se abrió, movió datos o la cortaron. Las siglas siguen estando, pero
/// como detalle secundario de la fila, no como su titular.
public enum PacketEvent: Sendable, Hashable, CaseIterable {
    /// SYN sin ACK: alguien pide abrir la conexión.
    case opened
    /// SYN+ACK: el otro extremo acepta abrirla.
    case accepted
    /// Lleva datos (PSH en TCP, o cualquier datagrama en UDP: un datagrama *es* su carga).
    case data
    /// Solo ACK: confirma lo recibido, sin datos propios.
    case acknowledged
    /// FIN: un lado dice que ya no tiene más que enviar.
    case closing
    /// RST: la conexión se corta en seco, sin cierre ordenado.
    case reset
    /// Un TCP sin ningún flag: no debería existir, y nombrarlo es más honesto que colarlo como dato.
    case other

    /// Clasifica un paquete guardado. El orden de las comprobaciones **es** la decisión: `RST` gana a
    /// todo porque cortar la conexión es lo que el usuario tiene que leer aunque el paquete traiga
    /// además un ACK, y `SYN` gana a `FIN` porque abrir es lo que define ese paquete.
    public static func classify(flags: TCPFlags, proto: IPProtocolNumber) -> PacketEvent {
        // Fuera de TCP no hay flags que interpretar: el store guarda un `TCPFlags` vacío y el
        // datagrama es, él solo, la carga que se envió.
        guard proto == .tcp else { return .data }

        if flags.contains(.rst) { return .reset }
        if flags.contains(.syn) { return flags.contains(.ack) ? .accepted : .opened }
        if flags.contains(.fin) { return .closing }
        if flags.contains(.psh) { return .data }
        if flags.contains(.ack) { return .acknowledged }
        return .other
    }

    /// El titular de la fila, y el título de la pantalla del paquete. Las siglas del cable (`SYN`,
    /// `ACK`, …) **no** entran aquí: eso es justo lo que esta traducción existe para quitar, y viajan
    /// aparte en `flagsDetail`, que no es copia y no pasa por el catálogo.
    public var label: String {
        switch self {
        case .opened:
            return String(
                localized: "packet.event.opened.label",
                defaultValue: "Connection opened",
                comment: """
                    Headline of a packet that asks to start a connection (a TCP SYN), shown as the \
                    row's title and as the title of the packet's own screen. It says what the \
                    packet did, never its acronym: the acronyms are shown separately and are not \
                    translated.
                    """
            )
        case .accepted:
            return String(
                localized: "packet.event.accepted.label",
                defaultValue: "Connection accepted",
                comment: """
                    Headline of the packet in which the other end agrees to open the connection (a \
                    TCP SYN+ACK). It must not collapse into the sibling key for the packet that \
                    asked: the two are the two halves of a handshake and a reader tells them apart \
                    by these words alone.
                    """
            )
        case .data:
            return String(
                localized: "packet.event.data.label",
                defaultValue: "Data",
                comment: """
                    Headline of a packet that carries payload. It is also what every UDP datagram \
                    is called, since a datagram is its own payload, so it must read as a noun on \
                    its own and not as part of a longer phrase.
                    """
            )
        case .acknowledged:
            return String(
                localized: "packet.event.acknowledged.label",
                defaultValue: "Delivery confirmed",
                comment: """
                    Headline of a packet that only confirms what arrived and carries nothing of \
                    its own (a bare TCP ACK). 'Delivery' is the traffic that had already been \
                    received, not a courier.
                    """
            )
        case .closing:
            return String(
                localized: "packet.event.closing.label",
                defaultValue: "Finished sending",
                comment: """
                    Headline of a packet in which one side says it has nothing more to send (a TCP \
                    FIN). It is one side finishing, not the connection ending: the sibling key for \
                    a dropped connection is the one that reads as a fault.
                    """
            )
        case .reset:
            return String(
                localized: "packet.event.reset.label",
                defaultValue: "Connection cut off",
                comment: """
                    Headline of a packet that drops the connection outright (a TCP RST). It is the \
                    only event on this screen drawn as a warning, so it must read as abrupt and \
                    must not soften into the wording used for an orderly close.
                    """
            )
        case .other:
            return String(
                localized: "packet.event.other.label",
                defaultValue: "Unusual packet",
                comment: """
                    Headline of a TCP packet carrying no control flags at all, which should not \
                    happen. Naming it is more honest than filing it under data; it should read as \
                    'we cannot say what this was', not as an error of the app.
                    """
            )
        }
    }

    /// Una frase de contexto: la lee VoiceOver y la pantalla del paquete la enseña bajo el titular.
    public var detail: String {
        switch self {
        case .opened:
            return String(
                localized: "packet.event.opened.detail",
                defaultValue: "A request to start the connection.",
                comment: """
                    One-sentence explanation under the headline for the packet that opens a \
                    connection, read out by VoiceOver after it. Plain language on purpose: this \
                    screen exists so the packet list can be read without knowing TCP.
                    """
            )
        case .accepted:
            return String(
                localized: "packet.event.accepted.detail",
                defaultValue: "The other side agreed to start it.",
                comment: """
                    Explanation for the packet in which the remote end accepts the connection. \
                    'The other side' is the server the device was talking to.
                    """
            )
        case .data:
            return String(
                localized: "packet.event.data.detail",
                defaultValue: "Carries part of what was sent over the connection.",
                comment: """
                    Explanation for a packet carrying payload. 'Part of' is load-bearing: what was \
                    sent is normally split across many packets, and this one is a piece of it.
                    """
            )
        case .acknowledged:
            return String(
                localized: "packet.event.acknowledged.detail",
                defaultValue: "Confirms what arrived, without carrying data.",
                comment: """
                    Explanation for a bare acknowledgement. The second half is the whole point: it \
                    is what tells this event apart from the one that carries payload.
                    """
            )
        case .closing:
            return String(
                localized: "packet.event.closing.detail",
                defaultValue: "One side has nothing more to send.",
                comment: """
                    Explanation for the packet that ends one direction of the connection. It says \
                    one side, not both: the other end may still be sending.
                    """
            )
        case .reset:
            return String(
                localized: "packet.event.reset.detail",
                defaultValue: "The connection was dropped without a proper close.",
                comment: """
                    Explanation for a connection cut off abruptly. It states what happened without \
                    blaming either end, which the app cannot know.
                    """
            )
        case .other:
            return String(
                localized: "packet.event.other.detail",
                defaultValue: "A packet with no control flags set.",
                comment: """
                    Explanation for a TCP packet with no control flags. 'Control flags' is the \
                    protocol's own term for the bits listed elsewhere in the row (SYN, ACK, …), \
                    which stay untranslated.
                    """
            )
        }
    }

    public var systemImage: String {
        switch self {
        case .opened: return "arrow.up.right.circle"
        case .accepted: return "checkmark.circle"
        case .data: return "shippingbox"
        case .acknowledged: return "checkmark"
        case .closing: return "arrow.down.right.circle"
        case .reset: return "bolt.horizontal.circle"
        case .other: return "questionmark.circle"
        }
    }

    /// Solo el corte tiene papel de aviso. Un cierre ordenado o un ACK son la vida normal de una
    /// conexión y pintarlos de alarma enseñaría a ignorar el color.
    public var role: StatusRole {
        switch self {
        case .reset, .other: return .warning
        case .opened, .accepted, .data, .acknowledged, .closing: return .neutral
        }
    }
}

/// Un paquete tal y como se enseña en la lista.
///
/// Es `Hashable` porque es también el **valor de navegación** hacia la pantalla de sus bytes: es lo que
/// SwiftUI apila, y apilar el paquete entero en vez de su `id` evita tener que volver a buscarlo en una
/// lista que puede haberse recargado por debajo.
///
/// Y por eso mismo **no lleva copia**: lo que identifica no es lo que se enseña. La frase que oye
/// VoiceOver era una `var` calculada de aquí —cuatro búsquedas en el catálogo compuestas en cada
/// lectura—, y estando en el valor de navegación era además una invitación permanente a llamarla desde
/// un `body`, que es exactamente lo que hacía `PacketRow`. Vive en `PacketRowPresentation`.
public struct PacketSummary: Sendable, Hashable, Identifiable {

    /// El `rowid` del paquete: dos paquetes pueden compartir instante, así que la identidad de las
    /// filas de SwiftUI no puede salir del tiempo.
    public let id: Int64

    public let date: Date

    /// Segundos desde el primer paquete de la conexión. Es lo que se enseña: la hora absoluta de un
    /// paquete no dice nada, pero "a los 0,004 s" sitúa el paquete dentro de lo que pasó.
    public let offset: TimeInterval

    public let direction: Direction
    public let length: UInt32
    public let event: PacketEvent

    /// Las siglas TCP (`"SYN, ACK"`), o `nil` si no hay ninguna — que es lo normal fuera de TCP.
    public let flagsDetail: String?

    /// Dónde están sus bytes, o `nil` si no se capturaron. Viaja con la fila porque es lo que decide
    /// si la fila lleva a alguna parte: sin localización no hay pantalla de bytes que abrir, y una
    /// fila pulsable que no enseña nada es peor que una fila que no invita al toque.
    public let capture: CaptureLocation?

    public init(
        id: Int64,
        date: Date,
        offset: TimeInterval,
        direction: Direction,
        length: UInt32,
        event: PacketEvent,
        flagsDetail: String?,
        capture: CaptureLocation?
    ) {
        self.id = id
        self.date = date
        self.offset = offset
        self.direction = direction
        self.length = length
        self.event = event
        self.flagsDetail = flagsDetail
        self.capture = capture
    }
}

/// La copia de una fila de la lista de paquetes, ya compuesta.
///
/// Lleva solo lo que hay que **componer**: el titular (una búsqueda en el catálogo), las dos cifras
/// (que formatea `DisplayFormat`) y la frase que oye VoiceOver (cuatro búsquedas más). Lo que la fila
/// dibuja y no compone —el icono del suceso, su papel de color y el sentido— se queda en la vista: son
/// `switch`es sobre enums que ni buscan ni asignan, igual que el badge de cifrado que `FlowRow` sigue
/// pidiendo por su cuenta.
public struct PacketRowPresentation: Sendable, Equatable {

    /// Qué fue el paquete, que es el titular de la fila.
    public let event: String

    /// A qué altura de la conexión ocurrió.
    public let offset: String

    /// Cuánto ocupó.
    public let length: String

    /// La fila entera en una frase: sin esto VoiceOver leería cuatro trozos sueltos sin decir qué
    /// fueron.
    public let accessibilityLabel: String

    public init(event: String, offset: String, length: String, accessibilityLabel: String) {
        self.event = event
        self.offset = offset
        self.length = length
        self.accessibilityLabel = accessibilityLabel
    }
}

/// Una fila de la lista de paquetes tal y como se pinta: el paquete y la copia que enseña de él.
///
/// Existe por lo mismo que `TimelineRow`, y esta es la tercera lista con el mismo defecto: la fila
/// componía su copia dentro del `body`, así que un scroll rehacía cinco cadenas —cuatro de ellas una
/// búsqueda en el catálogo, incluida la frase larga que solo oye VoiceOver— por cada fila visible y por
/// cada fotograma, sobre una lista que llega hasta `HistoryPolicy.packetsPerFlow` filas.
///
/// La invalidación aquí es más simple que la de la Timeline y no hace falta comparar nada: esta lista
/// no pagina ni se refresca sola, así que se compone **una vez por carga** y solo cambia cuando la
/// consulta vuelve a traer paquetes.
///
/// El paquete viaja con su copia y no aparte —ni en un diccionario por id al lado de la lista— porque
/// es lo que hace imposible pintar una fila con la copia de otra.
public struct PacketListRow: Identifiable, Sendable, Equatable {

    /// El paquete, que la vista sigue necesitando entero: es el valor que apila el `NavigationLink`
    /// hacia sus bytes, y de él salen el icono, el color y el sentido.
    public let packet: PacketSummary

    public let presentation: PacketRowPresentation

    /// La identidad es la del paquete: la copia es un derivado suyo y no puede distinguir dos filas
    /// que la lista considera la misma.
    public var id: PacketSummary.ID { packet.id }

    public init(packet: PacketSummary, presentation: PacketRowPresentation) {
        self.packet = packet
        self.presentation = presentation
    }
}

/// Un dato de la cabecera: la 5-tupla y los totales de la conexión, en lenguaje humano.
///
/// El valor puede ser texto ya formateado, un instante o un tramo entre dos. La distinción no es
/// cosmética: los números los formatea `DisplayFormat` de forma determinista y sin depender de la
/// región, mientras que una hora **sí** se localiza (12/24 h es del dispositivo), así que esa la
/// formatea la vista.
///
/// **No lleva icono, y esa ausencia es una decisión.** Cada dato traía un símbolo al lado de su
/// rótulo —una regla junto a *Size*, una almohadilla junto a *Sequence*, un reloj junto a
/// *Duration*—, o sea un pictograma inventado para acompañar a una palabra que ya estaba escrita:
/// la misma regla que sacó el reloj de la duración en las filas de la Timeline, aquí trece veces
/// entre las dos pantallas. Y aquí además tenía un coste medible: el icono se lleva la sangría del
/// rótulo, así que **ningún valor de la rejilla caía debajo del suyo** — dos columnas en las que lo
/// único alineado era el borde de la columna. El símbolo se queda donde **sustituye** a una palabra
/// (las flechas de `PacketRow`, la marca de cifrado en el carril de `FlowRow`), no donde la repite.
public struct FlowFact: Sendable, Equatable, Identifiable {

    public enum Value: Sendable, Equatable {
        case text(String)
        case moment(Date)

        /// Dos instantes que son **un** dato: el principio y el final de algo. La vista los formatea
        /// con el estilo de intervalo del sistema, que es quien sabe cómo se escribe un tramo en cada
        /// idioma — un guion puesto a mano entre dos horas sería copia escrita en una vista.
        case span(Range<Date>)
    }

    /// Qué dato es, con un nombre que no cambia con el idioma. **Era el propio rótulo**, y eso deja de
    /// valer en cuanto el rótulo se traduce: la rejilla cambiaría de identidad al cambiar de idioma —el
    /// mismo arreglo que necesitaron `IntroCardAction` y `ScrubCursorAction`— y, peor, la pantalla del
    /// paquete concatena dos listas de datos, así que dos rótulos que un idioma dijera igual colisionarían
    /// en un `ForEach`.
    public let id: String

    public let label: String
    public let value: Value

    public init(id: String, label: String, value: Value) {
        self.id = id
        self.label = label
        self.value = value
    }
}

/// Por qué una conexión no tiene contenido descifrado que enseñar.
///
/// Son cuatro y **ninguno es una avería**: son los cuatro finales normales de un producto donde
/// inspeccionar es opcional, guardar lo inspeccionado es otra decisión aparte (ADR 0007) y lo guardado
/// caduca antes que el resto. Se separan porque cada uno se arregla en un sitio distinto —o no se
/// arregla, que es el caso del pinning— y un solo "no hay nada" los haría indistinguibles.
public enum FlowContentAbsence: Sendable, Equatable {

    /// La conexión no iba cifrada, así que no hubo nada que descifrar. Lo que viajó está en sus
    /// paquetes, que sí se guardan.
    case notEncrypted

    /// Iba cifrada y no se miró dentro: la inspección estaba apagada, o no era una conexión que se
    /// inspeccione.
    case notInspected

    /// La app de la otra punta comprueba su propio certificado, así que su contenido se quedó donde
    /// estaba. Es el ADR 0003 visto desde la pantalla, y se cuenta como garantía y no como límite.
    case notInspectable

    /// Se inspeccionó y no quedó nada guardado: el interruptor de guardar estaba apagado, o lo que se
    /// guardó ya cumplió su plazo. Los dos se dicen juntos porque desde aquí no se distinguen.
    case notSaved
}

/// Lo que el Flow Inspector dice de la mitad descifrada de una conexión.
///
/// Es una sección y no una pantalla porque lo que hay que contestar de un vistazo es *si* hay algo; lo
/// que se dijo es una lista larga que merece su propio sitio (`ConversationPresentation`).
public enum FlowContentSection: Sendable, Equatable {

    /// Hay contenido, y cuánto se guardó de él.
    case conversation(storedBytes: UInt64)

    /// No lo hay, y por qué.
    case absent(FlowContentAbsence)
}

/// El cuerpo de la lista de paquetes. Exhaustivo: cada combinación de estado y lista cae en uno solo.
///
/// Las filas viajan **dentro** del caso y no publicadas aparte (como sí hace la Timeline, cuyo `.list`
/// no lleva carga): así no hay dos fuentes que puedan desparejarse en la vista.
public enum FlowInspectorContent: Sendable, Equatable {
    case loading
    case packets([PacketListRow])
    case placeholder(FlowInspectorPlaceholder)
}

public enum FlowInspectorPresentation {

    // MARK: - Cabecera

    /// Los datos de la conexión, **en pares**: la rejilla los reparte en dos columnas leyendo por
    /// filas, así que el orden no es una lista sino cuatro vecindades — lo que fue y cuándo, cuánto
    /// duró y cuántos paquetes costó, y los dos sentidos uno al lado del otro, que es la única
    /// comparación que esta cabecera pide.
    ///
    /// **Son seis y antes eran siete**, y las dos cosas que arregla ese cambio salieron de mirar la
    /// pantalla. La séptima dejaba una **fila suelta** al final de una rejilla de dos columnas. Y
    /// *Started* y *Last packet* eran los dos extremos de un mismo tramo repartidos en **distinta
    /// fila y distinta columna** —arriba a la derecha el principio, abajo a la izquierda el final—,
    /// o sea un intervalo que había que leer en diagonal. Juntos son un dato solo, y al irse uno la
    /// fila suelta se va con él: la rejilla se llena sin rellenar nada.
    public static func facts(for flow: HistoryFlow) -> [FlowFact] {
        [
            FlowFact(
                id: "service",
                label: String(
                    localized: "flowInspector.fact.service",
                    defaultValue: "Service",
                    comment: """
                        Label of the connection's destination in the header grid, next to a value \
                        like 'HTTPS · example.com' or 'TCP · port 8080'. It names what was being \
                        talked to, not the protocol on its own.
                        """
                ),
                value: .text(FlowDisplay.service(flow))
            ),
            FlowFact(
                id: "seen",
                // **No dice *Started* ni *Ended*, y esa precisión es la que costó las dos claves que
                // sustituye.** Lo que la app sabe es cuándo vio el primer paquete y cuándo el último;
                // que la conexión siga abierta después del último no lo puede saber nadie desde aquí.
                label: String(
                    localized: "flowInspector.fact.seen",
                    defaultValue: "First to last packet",
                    comment: """
                        Label of the span between the connection's first and last packet, in the \
                        header grid, next to a value like '10:02:57 – 10:04:14'. It is deliberately \
                        not 'Started' or 'Duration': a connection whose packets stopped may still \
                        be open, and the app cannot tell.
                        """
                ),
                // El tramo se acota aquí y no en la vista: un `Range` exige que el final no sea
                // anterior al principio, y un historial es una fuente externa que puede traer
                // cualquier par de fechas. Recortarlo donde se construye deja la vista sin decisión
                // que tomar y el recorte donde un test lo alcanza.
                value: .span(flow.firstSeen ..< Swift.max(flow.firstSeen, flow.lastSeen))
            ),
            FlowFact(
                id: "duration",
                label: String(
                    localized: "flowInspector.fact.duration",
                    defaultValue: "Duration",
                    comment: """
                        Label of how long the connection was seen for — the length of the span \
                        named above it in the same grid.
                        """
                ),
                value: .text(DisplayFormat.duration(flow.duration))
            ),
            FlowFact(
                id: "packetCount",
                // Clave propia y no la del encabezado de la lista, aunque hoy digan la misma palabra:
                // aquí rotula una cifra y allí nombra la sección que hay debajo, y un idioma puede
                // necesitar decirlas distinto. Es el mismo listón por el que el título del flujo de la
                // CA no se fundió con la fila de Ajustes que lleva a él.
                label: String(
                    localized: "flowInspector.fact.packetCount",
                    defaultValue: "Packets",
                    comment: """
                        Label of how many packets the connection recorded, in the header grid, \
                        next to a number. A different key from the heading of the packet list \
                        below on the same screen: this one labels a figure, that one names a \
                        section.
                        """
                ),
                value: .text(DisplayFormat.count(flow.stored.packetCount))
            ),
            FlowFact(
                id: "bytesIn",
                label: DirectionLabel.inbound,
                value: .text(DisplayFormat.bytes(flow.stored.bytesIn))
            ),
            FlowFact(
                id: "bytesOut",
                label: DirectionLabel.outbound,
                value: .text(DisplayFormat.bytes(flow.stored.bytesOut))
            ),
        ]
    }

    /// El encabezado de la lista de paquetes.
    public static var packetsSectionTitle: String {
        String(
            localized: "flowInspector.section.packets",
            defaultValue: "Packets",
            comment: """
                Heading of the list of individual packets on a connection's screen. It names the \
                section below it, not a figure — the header grid above has its own key for the \
                packet count.
                """
        )
    }

    // MARK: - Contenido descifrado

    /// Qué enseña la sección del contenido descifrado.
    ///
    /// Basta con las filas del índice: decir *si* hay algo y *cuánto* no necesita abrir un fichero, y
    /// no abrirlo es lo que permite que esta sección esté en una pantalla que ya carga paquetes. Los
    /// bytes se leen al entrar (`ConversationPresentation`).
    ///
    /// **Las filas mandan sobre el estado TLS**: si hay contenido guardado, se ofrece, diga lo que diga
    /// el `tlsStatus` de hoy. Una conexión puede haberse marcado `notInspectable` al final —el cliente
    /// rechazó nuestro certificado después de hablar— y lo que se descifró antes sigue siendo suyo.
    public static func contentSection(
        for flow: HistoryFlow, chunks: [StoredPlaintextChunk]
    ) -> FlowContentSection {
        let stored = chunks.reduce(UInt64(0)) { $0 + UInt64($1.storedLength) }
        guard stored == 0 else { return .conversation(storedBytes: stored) }

        switch flow.tlsStatus {
        case .plaintext:
            return .absent(.notEncrypted)
        case .encrypted:
            return .absent(.notInspected)
        case .notInspectable:
            return .absent(.notInspectable)
        case .inspected:
            return .absent(.notSaved)
        }
    }

    /// El encabezado de la sección. Dice las mismas palabras que el título de la pantalla que abre y
    /// que la sección de Ajustes que la produce, con clave propia: aquí encabeza un bloque dentro de
    /// otra pantalla, y un idioma puede necesitar decirlo más corto por eso.
    public static var contentSectionTitle: String {
        String(
            localized: "flowInspector.section.content",
            defaultValue: "Decrypted content",
            comment: """
                Heading of the section on a connection's screen that leads to what was said inside \
                it. Same words as the screen it opens and as the settings section that governs \
                recording it, deliberately a separate key: here it heads a block inside another \
                screen.
                """
        )
    }

    /// El rótulo de la fila que lleva a la conversación.
    ///
    /// Dice **cuánto se guardó** y no cuántos turnos hay: el número de turnos es un detalle del ritmo
    /// de la conexión que no significa nada antes de entrar, y una cifra de bytes contesta lo único que
    /// se pregunta desde fuera — si merece la pena abrirlo.
    public static func conversationRowTitle(storedBytes: UInt64) -> String {
        String(
            localized: "flowInspector.content.summary",
            defaultValue: "\(DisplayFormat.bytes(storedBytes)) saved",
            comment: """
                Label of the row that opens what was said inside an inspected connection. The \
                placeholder is how much of it the app kept. It says the amount rather than a count \
                of exchanges: the amount is what tells the user whether it is worth opening.
                """
        )
    }

    /// La frase de la sección cuando no hay contenido descifrado. Ninguna ofrece una acción: las cuatro
    /// explican algo que ya pasó, y tres de ellas se cambian en Ajustes y no aquí.
    public static func absenceMessage(_ absence: FlowContentAbsence) -> String {
        switch absence {
        case .notEncrypted:
            return String(
                localized: "flowInspector.content.absent.notEncrypted",
                defaultValue: """
                    This connection wasn't encrypted, so there was nothing to decrypt. What it sent \
                    travelled in the open and is in the packets below.
                    """,
                comment: """
                    Shown on a connection's screen in place of its decrypted contents, when the \
                    connection was not encrypted in the first place. The second sentence points at \
                    what the user can read instead, which is on the same screen.
                    """
            )

        case .notInspected:
            return String(
                localized: "flowInspector.content.absent.notInspected",
                defaultValue: """
                    This connection was encrypted and the app didn't look inside it, so its \
                    contents stayed private.
                    """,
                comment: """
                    Shown when an encrypted connection was never inspected — the inspection switch \
                    was off, or it was not a connection the app inspects. It states a fact without \
                    inviting anything: turning inspection on is a decision made in Settings, after \
                    installing a certificate, and not something to nudge from here.
                    """
            )

        case .notInspectable:
            return String(
                localized: "flowInspector.content.absent.notInspectable",
                defaultValue: """
                    The app on the other end checks its own certificate, so its contents stayed \
                    private — TunnelVision never works around that.
                    """,
                comment: """
                    Shown when the remote app pins its certificate, so nothing could be decrypted. \
                    It is written as a guarantee rather than a limitation: never defeating another \
                    app's protection is a decision of this product, not a missing feature.
                    """
            )

        case .notSaved:
            return String(
                localized: "flowInspector.content.absent.notSaved",
                defaultValue: """
                    The app looked inside this connection but kept nothing of what it saw — saving \
                    decrypted content is off by default, and what is saved is deleted sooner than \
                    the rest of your history.
                    """,
                comment: """
                    Shown when a connection was inspected but none of its contents are on the \
                    device. It names both ordinary reasons, because from here they cannot be told \
                    apart: the separate switch may be off, or what was saved may already have \
                    expired. 'Decrypted content' is the wording of the settings section that \
                    governs both.
                    """
            )
        }
    }

    // MARK: - Lista

    /// Traduce los paquetes guardados a filas, contando el tiempo desde el arranque de la conexión.
    ///
    /// El origen es `firstSeen` del flujo y no el primer paquete de la lista: son casi siempre el
    /// mismo instante, pero cuando no lo son —la lista viene recortada por el tope de la política— lo
    /// honesto es medir contra lo que la cabecera enseña como comienzo.
    public static func summaries(_ packets: [StoredPacket], flow: HistoryFlow) -> [PacketSummary] {
        packets.map { packet in
            PacketSummary(
                id: packet.id,
                date: packet.date,
                offset: packet.date.timeIntervalSince(flow.firstSeen),
                direction: packet.direction,
                length: packet.length,
                event: PacketEvent.classify(flags: packet.tcpFlags, proto: flow.proto),
                flagsDetail: flagsDetail(packet.tcpFlags),
                capture: packet.capture
            )
        }
    }

    /// La copia de una fila, compuesta aquí y no en SwiftUI.
    ///
    /// La frase accesible se compone **dentro** de la clave y no alrededor de ella: el orden de las
    /// piezas y el punto que separa el titular de su explicación son propiedades de un idioma. Las
    /// siglas van en una clave hermana en vez de pegarse al final, por lo mismo — un idioma puede
    /// necesitar decirlas antes.
    public static func row(_ packet: PacketSummary) -> PacketRowPresentation {
        let event = packet.event.label
        let length = DisplayFormat.bytes(UInt64(packet.length))
        let offset = DisplayFormat.offset(packet.offset)

        let spoken = String(
            localized: "flowInspector.packetRow.accessibilityLabel",
            defaultValue: """
                \(event). \(DirectionLabel.of(packet.direction)) \(length) at \(offset). \
                \(packet.event.detail)
                """,
            comment: """
                What VoiceOver reads of one packet in a connection's packet list. The \
                placeholders are, in order: what the packet was, the direction word ('Received' / \
                'Sent'), its size, how far into the connection it happened, and the one-sentence \
                explanation of what it was. Every piece is already a phrase of its own (see the \
                sibling keys); only their order and the punctuation between them are translatable \
                here.
                """
        )

        return PacketRowPresentation(
            event: event,
            offset: offset,
            length: length,
            accessibilityLabel: packet.flagsDetail.map { flags in
                String(
                    localized: "flowInspector.packetRow.accessibilityLabel.withFlags",
                    defaultValue: "\(spoken) Flags \(flags).",
                    comment: """
                        The same spoken description for a TCP packet that carries control flags. \
                        The first placeholder is the whole sentence from the sibling key and the \
                        second is the list of flags (SYN, ACK, FIN, …), which are the protocol's \
                        own names on the wire and are never translated. 'Flags' is the term the \
                        protocol uses for them.
                        """
                )
            } ?? spoken
        )
    }

    /// La lista entera, cada paquete con su copia. Es lo que el view model publica y la vista pinta.
    ///
    /// No decide nada que `row(_:)` no decidiera ya: existe para que haya **un solo sitio** donde los
    /// paquetes se convierten en filas, que es el sitio donde se sabe cuándo hay que rehacerlas.
    public static func rows(for packets: [PacketSummary]) -> [PacketListRow] {
        packets.map { PacketListRow(packet: $0, presentation: row($0)) }
    }

    /// Las siglas TCP en el orden en que se leen, o `nil` si el paquete no lleva ninguna.
    public static func flagsDetail(_ flags: TCPFlags) -> String? {
        let named: [(TCPFlags, String)] = [
            (.syn, "SYN"), (.ack, "ACK"), (.fin, "FIN"),
            (.rst, "RST"), (.psh, "PSH"), (.urg, "URG"),
        ]
        let present = named.filter { flags.contains($0.0) }.map(\.1)
        return present.isEmpty ? nil : present.joined(separator: ", ")
    }

    /// Qué cuerpo le toca a la lista.
    ///
    /// Manda la misma regla que en la Timeline: **si hay paquetes, se pintan**. Un fallo al recargar
    /// no puede tapar la lista que el usuario ya estaba leyendo.
    public static func content(
        state: FlowInspectorState, rows: [PacketListRow]
    ) -> FlowInspectorContent {
        if !rows.isEmpty { return .packets(rows) }

        switch state {
        case .idle, .loading:
            return .loading
        case .failed(let error):
            return .placeholder(failure(error))
        case .loaded:
            return .placeholder(noPackets)
        }
    }

    /// Lo que se dice cuando la lista viene recortada, o `nil` si está entera.
    ///
    /// El tope existe para que abrir una conexión larga no traiga media base de datos
    /// (`HistoryPolicy.packetsPerFlow`), pero callarlo dejaría al usuario creyendo que una conexión de
    /// miles de paquetes tuvo 500 — el mismo motivo por el que se publican los registros descartados
    /// del feed en vivo.
    ///
    /// El plural va como **dos claves hermanas** y no con el marcado de concordancia automática, que es
    /// la excepción medida que documentan los estándares: sin catálogo no se resuelve y el bundle de
    /// tests no lleva ninguno. La forma singular es alcanzable —una conexión con un paquete contado y
    /// ninguno guardado—, así que no es una rama muerta.
    public static func truncationNote(shown: Int, recorded: UInt64) -> String? {
        guard recorded > UInt64(shown) else { return nil }

        let first = DisplayFormat.count(UInt64(max(0, shown)))

        guard recorded != 1 else {
            return String(
                localized: "flowInspector.packets.truncation.one",
                defaultValue: """
                    Showing the first \(first) of 1 packet recorded for this connection.
                    """,
                comment: """
                    Footer of the packet list when it shows fewer packets than the connection \
                    recorded, in the case of exactly one recorded packet. The placeholder is how \
                    many are shown. See the plural form in the sibling key; a language with more \
                    plural forms needs both merged into one key with catalog variations.
                    """
            )
        }

        return String(
            localized: "flowInspector.packets.truncation.other",
            defaultValue: """
                Showing the first \(first) of \(DisplayFormat.count(recorded)) packets recorded \
                for this connection.
                """,
            comment: """
                Footer of the packet list when it shows fewer packets than the connection \
                recorded, for any count other than one. The placeholders are how many are shown \
                and how many exist, both already grouped. Saying it is not optional: without it a \
                connection of thousands of packets would read as having had a few hundred.
                """
        )
    }

    // MARK: - Copia

    /// La conexión está guardada, pero sus paquetes no. Pasa cuando la captura estaba en
    /// metadatos-solo o cuando la retención ya se los llevó: no hay nada roto y no hay nada que
    /// reintentar, así que el hueco explica y no ofrece salida.
    /// Es una `var` calculada y no una `static let`, como toda la copia de la app: una constante se
    /// resuelve la primera vez que alguien la lee y dejaría el idioma congelado en el que hubiera
    /// entonces.
    private static var noPackets: FlowInspectorPlaceholder {
        FlowInspectorPlaceholder(
            title: String(
                localized: "flowInspector.empty.noPackets.title",
                defaultValue: "No packets kept",
                comment: """
                    Title of the empty state on a connection's screen when the connection is in \
                    the history but its individual packets are not. 'Kept' rather than 'found': \
                    nothing is missing or broken, they were never stored or have been cleaned up.
                    """
            ),
            message: String(
                localized: "flowInspector.empty.noPackets.message",
                defaultValue: """
                    This connection was recorded, but its individual packets aren't stored any \
                    more — either capture detail was off, or they've since been cleaned up.
                    """,
                comment: """
                    Body of that empty state: it names both ordinary reasons so the user does not \
                    read it as a fault. 'Capture detail' is the app's own setting for recording \
                    packets and not only connections.
                    """
            ),
            systemImage: "tray",
            role: .neutral
        )
    }

    /// El fallo de la consulta. Como todos los de la app, **siempre** ofrece salida.
    private static func failure(_ error: HistoryError) -> FlowInspectorPlaceholder {
        let title: String
        let message: String
        let diagnostic: String

        switch error {
        case .queryFailed(let detail):
            title = String(
                localized: "flowInspector.failure.queryFailed.title",
                defaultValue: "Couldn't load the packets",
                comment: """
                    Title of the failure card on a connection's screen when the query for its \
                    packets failed. Nothing is known to be damaged here, so it must not read as \
                    data loss: the sibling key covers the case where what was read is corrupt.
                    """
            )
            message = String(
                localized: "flowInspector.failure.queryFailed.message",
                defaultValue: """
                    The packets saved for this connection couldn't be read right now.
                    """,
                comment: """
                    Body of that failure card. 'Right now' is load-bearing: the card offers a \
                    retry, so it says the reading failed this time and not that it cannot be done.
                    """
            )
            diagnostic = detail

        case .corruptData(let detail):
            title = String(
                localized: "flowInspector.failure.corruptData.title",
                defaultValue: "Some packets couldn't be read",
                comment: """
                    Title of the failure card when part of what was saved for this connection is \
                    damaged. 'Some' is deliberate: the rest of the history is fine, and this must \
                    not read as the whole connection being lost.
                    """
            )
            message = String(
                localized: "flowInspector.failure.corruptData.message",
                defaultValue: """
                    Part of what was saved for this connection is damaged, so it can't be shown.
                    """,
                comment: """
                    Body of that failure card: what is wrong and what follows from it. Showing \
                    damaged rows would attribute one connection's traffic to another, which the \
                    app never does.
                    """
            )
            diagnostic = detail
        }

        return FlowInspectorPlaceholder(
            title: title,
            message: message,
            systemImage: "exclamationmark.triangle",
            role: .warning,
            // Cada pantalla dice su reintento con clave propia, como las cuatro ya migradas: no entra
            // en `CommonCopy` porque el listón de ahí es significar lo mismo en todas, y aquí se
            // reintenta la consulta de unos paquetes mientras que en Ajustes se reintenta encender el
            // túnel. El día que se demuestre que las cinco son la misma frase, se funden.
            actionTitle: String(
                localized: "flowInspector.failure.retry",
                defaultValue: "Try again",
                comment: """
                    Button on the failure card of a connection's screen that asks for its packets \
                    again. It repeats one database read; it does not reload the history or the \
                    screen.
                    """
            ),
            action: .retry,
            diagnostic: diagnostic
        )
    }
}
