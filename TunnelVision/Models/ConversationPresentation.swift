import Foundation
import Shared

/// Qué enseña la mitad **descifrada** del Flow Inspector: lo que se dijo por dentro de una conexión
/// inspeccionada (`docs/ux/screens.md`, *Flow Inspector*), leído de los ficheros `.tvpt` que escribió
/// la extensión (`docs/spec/plaintext.md`).
///
/// Es la pieza (4) de la inspección y la única cuyas decisiones son de **pantalla** y no de bytes: el
/// camino de vuelta ya existe entero (`HistoryReader.plaintext(forFlow:)` da las filas en el orden en
/// que ocurrieron y `PlaintextLibrary.record(for:)` las convierte en sus bytes). Lo que hacía falta
/// decidir es qué se enseña con eso, y son tres cosas.
///
/// **(1) Qué es un turno.** Un trozo **no** lo es. La terminación los emite según le llegan de sus dos
/// patas, así que varios seguidos del mismo lado son una sola cosa dicha, y pintarlos uno a uno
/// enseñaría el ritmo de las lecturas del socket en vez del de la conversación. Un turno es, por tanto,
/// una **racha máxima de trozos consecutivos del mismo sentido**, y el único corte es el cambio de
/// sentido. Se valoró cortar también por un hueco de tiempo y se descartó: el umbral sería un número
/// inventado, y una respuesta lenta sigue siendo **una** respuesta.
///
/// **(2) Qué se dice de lo que no cupo.** No se dice ninguna cifra por conexión, y esa ausencia *es* la
/// decisión. Lo que se sabe con exactitud es lo de **un trozo** —sus dos longitudes—, y lo que no se
/// sabe es cuánto se dijo después de agotarse el presupuesto, porque agotado no queda fila que contar.
/// La única cifra derivable hoy (la suma de las filas que existen) es una **cota inferior**, y una cota
/// inferior presentada como total es mentira; decir la de verdad exigiría una columna por flujo que el
/// esquema `v5` no tiene, y migrarlo para una frase no lo vale. Lo que sí se afirma es lo que sí se
/// sabe: cuánto se guardó de **este** turno, y que a partir de él **ese lado dejó de guardarse**. Es
/// deducible sin cifra ninguna: el presupuesto corta antes de escribir, así que un trozo recortado es
/// siempre el último de su sentido.
///
/// **(3) Compartir.** Lo que se puede leer se puede sacar de la app —es el tráfico del dueño del
/// dispositivo—, pero **de un turno cada vez y nunca de la conversación entera**: no hay un artefacto
/// dibujado que sea "la conversación", así que no hay nada que un botón suyo pudiera prometer, y el
/// gesto en bloque es lo único que convertiría un toque en mover a otra app todo lo que este producto
/// llega a descifrar. Lo que sí da entero es **el turno**, no solo su vista previa: la pantalla dibuja
/// el principio para poder leerse de un vistazo, y un turno llega a 64 KiB, así que si compartir
/// diese lo dibujado no habría forma de sacar lo demás.

// MARK: - Navegación

/// El valor que lleva del Flow Inspector a la conversación descifrada.
///
/// Lleva **los trozos** y no solo el id del flujo porque el Flow Inspector ya los consultó para poder
/// contar su sección, y volver a pedirlos aquí gastaría una consulta para obtener lo mismo. Es la misma
/// decisión que apilar el `PacketSummary` entero en vez de su id, y por el mismo motivo: lo que se
/// apila no tiene que volver a buscarse en una lista que puede haberse recargado por debajo.
public struct ConversationRoute: Hashable, Sendable {

    public let flow: HistoryFlow
    public let chunks: [StoredPlaintextChunk]

    public init(flow: HistoryFlow, chunks: [StoredPlaintextChunk]) {
        self.flow = flow
        self.chunks = chunks
    }
}

// MARK: - Acciones y huecos

/// Lo que se puede hacer desde un hueco de esta pantalla: volver a leer los ficheros.
public enum ConversationAction: Sendable, Equatable {
    case retry
}

public typealias ConversationPlaceholder = ScreenPlaceholder<ConversationAction>

/// Por qué no están los bytes de un turno.
///
/// Los tres salen de `PlaintextLibraryError` y **solo el último es una avería**. El primero es la vida
/// normal del ADR 0007: el contenido descifrado caduca con un plazo corto y propio, así que una
/// conexión conserva sus filas mucho después de que sus bytes se barrieran.
public enum ConversationTurnUnavailable: Sendable, Equatable {

    /// El fichero que tenía esos bytes ya no está: el barrido se lo llevó al caducar.
    case swept(UInt32)

    /// Hay un registro legible en esa posición y **no es el de esta conversación**. No se enseña: sería
    /// el contenido descifrado de otra conexión bajo esta cabecera, que es la peor avería posible aquí.
    case mismatched(String)

    /// La lectura falló de verdad: el fichero no se deja abrir o el registro está a medias.
    case unreadable(String)
}

/// Lo que la lectura dejó de un turno: sus bytes tal y como se guardaron, o por qué no están.
///
/// Van **enteros** y no recortados a lo que se dibuja porque de aquí salen dos cosas distintas —la
/// vista previa y lo que se comparte— y solo una de las dos está acotada por la pantalla.
public enum ConversationTurnBytes: Sendable, Equatable {
    case read(Data)
    case unavailable(ConversationTurnUnavailable)
}

/// Cómo se pinta lo que se leyó de un turno.
///
/// La regla es la del contenido y no la del protocolo: lo que la terminación trasiega es carga de
/// aplicación, que unas veces es texto (HTTP, JSON) y otras no (HTTP/2, gRPC, un binario cualquiera).
/// Enseñar un binario como texto lo convierte en ruido con rombos, y enseñar una petición HTTP como
/// hexadecimal esconde justo lo que esta pantalla existe para enseñar.
public enum ConversationBody: Sendable, Equatable {

    /// Se lee como texto.
    case text(String)

    /// No se lee como texto: se vuelca en hexadecimal, con el mismo formato que la pantalla de un
    /// paquete.
    case hex([HexDumpLine])

    /// No hay bytes que pintar, y por qué. El turno **conserva su sitio y su cabecera**: quitarlo
    /// dejaría la conversación con forma de completa sin serlo.
    case unavailable(ConversationTurnUnavailable)
}

/// Lo que se dibuja del cuerpo de un turno **y cuánto del turno cubre** lo dibujado.
///
/// Son dos cifras y no una desde que el dibujo descuenta el cierre del texto (`material(of:)`): lo
/// que se quita del final no es material que se deje de enseñar, así que no puede contar como
/// recortado. Si contara, un turno dibujado **entero** anunciaría que solo se ve una parte porque dos
/// saltos de línea no se dibujan — que es exactamente la confusión entre *no se guardó* y *no se
/// dibuja* que esta pantalla ya separa en dos claves.
public struct ConversationBodyPreview: Sendable, Equatable {

    /// Lo que la tarjeta pinta.
    public let body: ConversationBody

    /// Cuántos bytes del turno se leyeron para pintarlo. Es la cifra contra la que se decide si hay
    /// algo que decir de lo que no se dibuja, y la que esa frase enseña.
    public let covered: Int

    public init(body: ConversationBody, covered: Int) {
        self.body = body
        self.covered = covered
    }
}

// MARK: - El turno

/// Una cosa dicha por uno de los dos lados: la racha de trozos consecutivos del mismo sentido.
///
/// Es el equivalente de `PacketSummary` en esta mitad de la pantalla —lo que se sabe **sin abrir
/// ningún fichero**— y por eso lleva los trozos y no los bytes: quién los lee es el view model, y lo
/// hace solo de lo que se vaya a enseñar.
public struct ConversationTurn: Sendable, Equatable, Identifiable {

    /// El `rowid` del primer trozo del turno. Dos turnos pueden empezar en el mismo instante (los dos
    /// lados hablan a la vez), así que la identidad de las filas no puede salir del tiempo.
    public let id: Int64

    public let direction: Direction

    /// Cuándo empezó a decirse, según el primer trozo.
    public let date: Date

    /// Segundos desde el primer paquete de la conexión, como en la lista de paquetes: la hora absoluta
    /// de un trozo no sitúa nada, y "a los 0,3 s" sí.
    public let offset: TimeInterval

    /// Los trozos que lo componen, en el orden en que ocurrieron. Van enteros porque cada uno sabe
    /// dónde están sus bytes, que es lo que hay que pedirle a `PlaintextLibrary`.
    public let chunks: [StoredPlaintextChunk]

    public init(
        id: Int64,
        direction: Direction,
        date: Date,
        offset: TimeInterval,
        chunks: [StoredPlaintextChunk]
    ) {
        self.id = id
        self.direction = direction
        self.date = date
        self.offset = offset
        self.chunks = chunks
    }

    /// Lo que se guardó del turno.
    public var storedLength: UInt64 {
        chunks.reduce(UInt64(0)) { $0 + UInt64($1.storedLength) }
    }

    /// Lo que el turno medía antes de recortarlo, sumando lo que dice cada trozo. **No** es lo que ese
    /// lado dijo en total: lo que se dijo después de agotarse el presupuesto no dejó fila (ver el
    /// encabezado de este fichero).
    public var originalLength: UInt64 {
        chunks.reduce(UInt64(0)) { $0 + UInt64($1.originalLength) }
    }

    /// Que algún trozo del turno se quedó a medias.
    ///
    /// Y como el presupuesto corta **antes** de escribir, un trozo recortado es el último de su
    /// sentido: esto significa además que a partir de aquí ese lado dejó de guardarse.
    public var isTruncated: Bool { chunks.contains { $0.isTruncated } }
}

/// El turno tal y como se pinta: lo que se sabía de él, lo que se leyó y la copia ya compuesta.
///
/// Existe por lo mismo que `PacketListRow` y `TimelineRow`: componer la cabecera, la cifra y la frase
/// que oye VoiceOver son búsquedas en el catálogo, y hacerlas dentro de un `body` es trabajo por
/// fotograma de scroll. Aquí, además, el cuerpo se decide leyendo los bytes —decodificar UTF-8 o
/// volcar hexadecimal—, que es lo último que puede hacerse mientras se dibuja.
public struct ConversationTurnRow: Sendable, Equatable, Identifiable {

    public let turn: ConversationTurn

    public let body: ConversationBody

    /// Lo que sale de la app al compartir, o `nil` si no hay nada que sacar. Es **todo** lo que se
    /// guardó del turno y no la vista previa de arriba.
    public let shareable: String?

    public let presentation: ConversationTurnPresentation

    public var id: ConversationTurn.ID { turn.id }

    public init(
        turn: ConversationTurn,
        body: ConversationBody,
        shareable: String?,
        presentation: ConversationTurnPresentation
    ) {
        self.turn = turn
        self.body = body
        self.shareable = shareable
        self.presentation = presentation
    }
}

/// La copia de un turno, compuesta fuera de SwiftUI.
public struct ConversationTurnPresentation: Sendable, Equatable {

    /// Quién habló: la misma palabra que usa toda la app para el sentido (*Sent* / *Received*).
    public let direction: String

    /// A qué altura de la conexión.
    public let offset: String

    /// Cuánto se guardó de lo que se dijo aquí.
    public let size: String

    /// Lo que hay que decir del recorte, o `nil` si el turno está entero. Cuando lo hay dice **las dos
    /// cosas en una frase**, porque son inseparables: el presupuesto corta antes de escribir, así que
    /// un turno recortado es siempre el último que se guardó de ese lado.
    public let truncationNote: String?

    /// Lo que se dice cuando el cuerpo se pinta a medias por ser largo. Es un recorte **de pantalla** y
    /// no de lo guardado, al contrario que el anterior, y por eso son dos frases distintas.
    public let bodyNote: String?

    /// El turno entero en una frase, que es lo único que hace legible la lista con VoiceOver: sin ella
    /// se oirían una palabra, una cifra y un muro de texto sin decir de quién es.
    public let accessibilityLabel: String

    public init(
        direction: String,
        offset: String,
        size: String,
        truncationNote: String?,
        bodyNote: String?,
        accessibilityLabel: String
    ) {
        self.direction = direction
        self.offset = offset
        self.size = size
        self.truncationNote = truncationNote
        self.bodyNote = bodyNote
        self.accessibilityLabel = accessibilityLabel
    }
}

/// El cuerpo de la pantalla. Exhaustivo: cada estado cae en uno y solo uno.
public enum ConversationContent: Sendable, Equatable {
    case loading
    case turns([ConversationTurnRow])
    case placeholder(ConversationPlaceholder)
}

/// En qué punto está la lectura de los ficheros.
///
/// No tiene `failed`, al contrario que el Flow Inspector: aquí no hay **una** lectura que falle, sino
/// una por turno, y cada fallo viaja dentro de su cuerpo. Lo que decide si la pantalla entera es un
/// hueco es `ConversationPresentation.content`, cuando resulta que **ningún** turno se pudo leer.
public enum ConversationState: Sendable, Equatable {
    case idle
    case loading
    case loaded([ConversationTurnRow])
}

// MARK: - La composición

public enum ConversationPresentation {

    /// Cuántos bytes de un turno se llegan a **pintar**.
    ///
    /// El presupuesto ya acota un turno a 64 KiB (`PlaintextBudget`), así que esto no defiende la
    /// memoria: defiende la lectura. Lo que se dibuja es una **vista previa** —cuatro kilobytes de
    /// JSON repetido son noventa líneas envueltas, mirado en el Simulator, y debajo hay más turnos—,
    /// y lo que hay más allá **sale entero por el botón de compartir**. Ese es el reparto: la pantalla
    /// deja leer el principio de un vistazo y la hoja del sistema entrega lo que se guardó.
    ///
    /// Es lo contrario del volcado de un paquete, que comparte lo que dibuja, y la diferencia es que
    /// allí lo dibujado **es** el registro entero: aquí un turno llega a 64 KiB y no hay ninguna
    /// pantalla donde eso quepa.
    public static let maxBytesShown = 1_024

    /// Y cuántos cuando lo que se pinta es un volcado.
    ///
    /// Es **la mitad** y no un descuido: una línea de texto lleva sesenta o setenta caracteres y una
    /// de volcado lleva dieciséis bytes, así que el mismo número de bytes ocupa cuatro veces más alto.
    public static let maxHexBytesShown = 512

    // MARK: Los turnos

    /// Agrupa los trozos en turnos. El único corte es el **cambio de sentido** (ver el encabezado).
    ///
    /// El origen del reloj es `firstSeen` del flujo y no el primer trozo, por lo mismo que en la lista
    /// de paquetes: cuando no coinciden —la conexión empezó antes de que hubiera nada que descifrar,
    /// que es siempre, porque antes va el handshake— lo honesto es medir contra lo que la cabecera
    /// enseña como comienzo.
    public static func turns(_ chunks: [StoredPlaintextChunk], flow: HistoryFlow) -> [ConversationTurn] {
        var turns: [ConversationTurn] = []
        var run: [StoredPlaintextChunk] = []

        func closeRun() {
            guard let first = run.first else { return }
            turns.append(
                ConversationTurn(
                    id: first.id,
                    direction: first.direction,
                    date: first.date,
                    offset: first.date.timeIntervalSince(flow.firstSeen),
                    chunks: run
                )
            )
            run = []
        }

        for chunk in chunks {
            if let current = run.first, current.direction != chunk.direction {
                closeRun()
            }
            run.append(chunk)
        }
        closeRun()

        return turns
    }

    /// Los trozos de un turno cuyos bytes hay que leer.
    ///
    /// Se para en el **primer trozo recortado**, y esa es una regla de corrección y no de coste: los
    /// bytes de un trozo recortado no continúan en el siguiente, así que concatenarlos empalmaría dos
    /// posiciones distintas del stream y enseñaría una frase que nadie escribió. Hoy no puede pasar
    /// —el presupuesto corta antes de escribir y deja al trozo recortado de último—, y precisamente por
    /// eso la regla no cuesta nada y cubre el día que ese invariante cambie.
    ///
    /// No se para por bytes: lo que acota un turno es el presupuesto del escritor (64 KiB por sentido),
    /// y leer solo la vista previa dejaría al botón de compartir sin nada que entregar más allá de
    /// ella.
    public static func readable(_ turn: ConversationTurn) -> [StoredPlaintextChunk] {
        var wanted: [StoredPlaintextChunk] = []

        for chunk in turn.chunks {
            wanted.append(chunk)
            if chunk.isTruncated { break }
        }

        return wanted
    }

    // MARK: El cuerpo

    /// Cómo se pinta un trozo de conversación: texto si se lee como texto, hexadecimal si no.
    ///
    /// La prueba tiene dos mitades y las dos hacen falta. **(1) Decodifica como UTF-8**, permitiendo
    /// que le falten hasta tres bytes del final: un turno acaba donde el presupuesto o el socket lo
    /// cortaron, y eso parte por la mitad el último carácter de cualquier idioma que no sea inglés —
    /// tirar el texto entero por ese byte sería mandar a hexadecimal media web del mundo. **(2) No
    /// lleva bytes de control** más allá del tabulador y los saltos de línea: un binario que pase por
    /// casualidad la primera prueba (los hay: un `NUL` es UTF-8 válido) se delata en la segunda, y
    /// pintarlo como texto sería pintar una fila vacía con rombos.
    /// Los dos topes son distintos y por eso el corte se hace **después** de decidir: recortar antes
    /// obligaría a elegir un solo número, y el bueno depende de la respuesta que todavía no se tiene.
    public static func preview(
        for bytes: Data, limit: Int = maxBytesShown, hexLimit: Int = maxHexBytesShown
    ) -> ConversationBodyPreview {
        let read = Data(bytes.prefix(max(0, limit)))
        if let text = readableText(read) {
            return ConversationBodyPreview(body: .text(material(of: text)), covered: read.count)
        }

        let lines = HexDump.lines(bytes, limit: max(0, hexLimit))
        return ConversationBodyPreview(
            body: .hex(lines), covered: lines.reduce(0) { $0 + $1.ascii.count }
        )
    }

    /// Cómo se pinta, sin la cuenta de lo que cubre. La puerta sigue siendo `preview(for:)`: quien
    /// necesite decir algo de lo que no se dibuja necesita las dos cifras, y separarlas es lo que
    /// dejaría a esa frase contando saltos de línea como material perdido.
    public static func body(
        for bytes: Data, limit: Int = maxBytesShown, hexLimit: Int = maxHexBytesShown
    ) -> ConversationBody {
        preview(for: bytes, limit: limit, hexLimit: hexLimit).body
    }

    /// El material de un texto: lo mismo sin el cierre.
    ///
    /// Un protocolo de texto termina su cabecera con **una línea en blanco**, así que toda petición y
    /// toda respuesta HTTP acaban en saltos de línea; dibujados, son un carril de aire al pie del
    /// pozo. Medido en el Simulator, el turno de cuatro líneas de la conexión de ejemplo pintaba
    /// **seis**: 35 pt de nada, y distintos en cada turno, así que dos tarjetas con la misma forma no
    /// medían igual. Lo que se quita es solo el final: el salto de **dentro** es la estructura que
    /// separa la cabecera del cuerpo y es lo que hace legible una respuesta.
    ///
    /// **Recortar no vacía nunca un turno.** Si no queda nada delante del cierre, no había cierre que
    /// quitar sino un turno que solo dijo espacios, y ése se dibuja tal cual: enmarcar la nada no es
    /// lo mismo que no haber dicho nada.
    private static func material(of text: String) -> String {
        guard let end = text.lastIndex(where: { !$0.isWhitespace }) else { return text }
        return String(text[...end])
    }

    /// El texto de unos bytes, o `nil` si no son texto.
    private static func readableText(_ bytes: Data) -> String? {
        // Sin bytes no hay nada que decidir, y devolver texto vacío es más honesto que un volcado
        // hexadecimal de cero líneas: la fila dirá que ese lado no dijo nada.
        guard !bytes.isEmpty else { return "" }

        // Los tres bytes son el tamaño máximo que le falta a un carácter UTF-8 partido por el final.
        // Recortar más sería empezar a esconder basura de verdad.
        for missing in 0...3 where missing < bytes.count {
            let candidate = bytes.prefix(bytes.count - missing)
            guard let text = String(data: candidate, encoding: .utf8) else { continue }
            guard isPrintable(text) else { return nil }
            return text
        }
        return nil
    }

    /// Que el texto no lleva bytes de control. El tabulador y los dos saltos de línea sí, porque son la
    /// estructura de cualquier protocolo de texto (una cabecera HTTP por línea) y quitarlos convertiría
    /// una petición legible en un párrafo.
    private static func isPrintable(_ text: String) -> Bool {
        !text.unicodeScalars.contains { scalar in
            switch scalar {
            case "\t", "\n", "\r":
                return false
            default:
                // C0 (incluido `NUL`) y `DEL`. Los C1 no se miran: en UTF-8 son escalares normales de
                // idiomas reales, no bytes crudos.
                return scalar.value < 0x20 || scalar.value == 0x7F
            }
        }
    }

    /// Traduce el fallo del servicio a la razón que la fila enseña. Un fichero que ya no está **no** es
    /// un fallo: es lo que el barrido del ADR 0007 le hace a todo contenido descifrado que cumple su
    /// plazo, y esta pantalla lo ve más que ninguna otra.
    public static func unavailable(for error: PlaintextLibraryError) -> ConversationTurnUnavailable {
        switch error {
        case .notFound(let sequence):
            return .swept(sequence)
        case .recordMismatch(let detail):
            return .mismatched(detail)
        case .containerUnavailable(let detail):
            return .unreadable(detail)
        case .recordUnreadable(let detail):
            return .unreadable(detail)
        }
    }

    // MARK: La fila

    /// Un turno con su cuerpo, lo que se puede sacar de él y su copia: lo que la vista pinta.
    ///
    /// Es el **único** sitio donde un turno se convierte en fila, por lo mismo que
    /// `FlowInspectorPresentation.rows(for:)`: así hay un solo lugar que sepa cuándo hay que rehacerla.
    public static func row(_ turn: ConversationTurn, bytes: ConversationTurnBytes) -> ConversationTurnRow {
        let direction = DirectionLabel.of(turn.direction)
        let offset = DisplayFormat.offset(turn.offset)
        let size = DisplayFormat.bytes(turn.storedLength)

        let preview: ConversationBodyPreview
        let shareable: String?
        switch bytes {
        case .read(let data):
            preview = self.preview(for: data)
            shareable = shareableText(data, drawnAs: preview.body)
        case .unavailable(let reason):
            // Sin bytes no se leyó nada, y `bodyNote` no mira la cuenta de un cuerpo que no está.
            preview = ConversationBodyPreview(body: .unavailable(reason), covered: 0)
            shareable = nil
        }

        return ConversationTurnRow(
            turn: turn,
            body: preview.body,
            shareable: shareable,
            presentation: ConversationTurnPresentation(
                direction: direction,
                offset: offset,
                size: size,
                truncationNote: truncationNote(for: turn),
                bodyNote: bodyNote(for: turn, preview: preview),
                accessibilityLabel: accessibilityLabel(
                    direction: direction, offset: offset, size: size, body: preview.body
                )
            )
        )
    }

    /// Lo que se dice del recorte de un turno, o `nil` si está entero.
    ///
    /// Las dos mitades van en **una sola frase y una sola clave** porque son inseparables: el
    /// presupuesto corta antes de escribir, así que el turno que se quedó a medias es el último que se
    /// guardó de ese lado. Y son dos claves hermanas, una por sentido, porque la segunda mitad nombra a
    /// quien habló y ahí una palabra interpolada (*Sent*, *Received*) no cabe en ninguna frase.
    public static func truncationNote(for turn: ConversationTurn) -> String? {
        guard turn.isTruncated else { return nil }

        let stored = DisplayFormat.bytes(turn.storedLength)
        let original = DisplayFormat.bytes(turn.originalLength)

        switch turn.direction {
        case .outbound:
            return String(
                localized: "conversation.turn.truncation.sent",
                defaultValue: """
                    Only the first \(stored) of \(original) was kept here, and nothing this device \
                    sent afterwards was kept at all.
                    """,
                comment: """
                    Footer of one side's turn in a decrypted conversation, when the recording \
                    budget cut it. The placeholders are how much was kept and how much that piece \
                    measured. The second half is the load-bearing one and is not optional: once the \
                    budget runs out nothing further is recorded, and no figure exists for how much \
                    that was — saying one would be a guess. The sibling key covers the other \
                    direction.
                    """
            )
        case .inbound:
            return String(
                localized: "conversation.turn.truncation.received",
                defaultValue: """
                    Only the first \(stored) of \(original) was kept here, and nothing this device \
                    received afterwards was kept at all.
                    """,
                comment: """
                    The same footer for a turn the device received rather than sent. It is a \
                    separate key because the direction is named inside the sentence, not \
                    interpolated: no single phrasing fits both.
                    """
            )
        }
    }

    /// Lo que se dice cuando el cuerpo se pinta a medias, o `nil` si se pinta entero.
    ///
    /// Es un recorte **de pantalla** y nada se ha perdido: los bytes siguen en su fichero y salen
    /// enteros por el botón de compartir. Por eso es otra frase que la de arriba — confundir "no se
    /// guardó" con "no se dibuja" es exactamente lo que la pantalla del paquete ya separa en dos claves.
    public static func bodyNote(
        for turn: ConversationTurn, preview: ConversationBodyPreview
    ) -> String? {
        if case .unavailable = preview.body { return nil }

        // Contra lo que se **leyó** del turno y no contra lo que se pintó: entre las dos hay el
        // cierre que `material(of:)` descuenta, y medir por lo pintado haría que una petición HTTP
        // entera —que siempre acaba en una línea en blanco— anunciara que se ve a medias.
        guard turn.storedLength > UInt64(preview.covered) else { return nil }

        return String(
            localized: "conversation.turn.bodyTruncation",
            defaultValue: """
                Showing the first \(DisplayFormat.bytes(UInt64(preview.covered))) — sharing hands \
                over all of it.
                """,
            comment: """
                Footer of a turn whose contents are too long to draw in full. The placeholder is \
                how much is drawn. Nothing is lost here, which is what tells it apart from the \
                sibling keys about the recording budget: the second half says where the rest is, \
                and it is the share button beside this very turn.
                """
        )
    }

    /// El turno entero en una frase.
    ///
    /// El contenido **no** entra: puede ser un megabyte de JSON o un volcado hexadecimal, y ninguno de
    /// los dos se oye. Lo que se dice es de quién es, cuándo y cuánto, que es lo que permite recorrer
    /// la lista y decidir dónde pararse; el cuerpo lo lee VoiceOver aparte, que es donde el usuario ya
    /// eligió leerlo. Es la misma regla por la que una línea del volcado no deletrea sus pares.
    private static func accessibilityLabel(
        direction: String, offset: String, size: String, body: ConversationBody
    ) -> String {
        if case .unavailable = body {
            return String(
                localized: "conversation.turn.accessibilityLabel.unavailable",
                defaultValue: "\(direction) at \(offset). Contents not available.",
                comment: """
                    What VoiceOver reads of a turn whose contents could not be read. The \
                    placeholders are the direction word ('Sent' / 'Received', its own key) and how \
                    far into the connection it happened. The size is left out on purpose: there is \
                    nothing here whose size it would describe.
                    """
            )
        }

        return String(
            localized: "conversation.turn.accessibilityLabel",
            defaultValue: "\(direction) \(size) at \(offset).",
            comment: """
                What VoiceOver reads of one turn of a decrypted conversation. The placeholders are, \
                in order: the direction word ('Sent' / 'Received', which has its own key), how much \
                of it was kept, and how far into the connection it happened. The contents \
                themselves are deliberately not part of this: they are read separately, where the \
                user chose to read them.
                """
        )
    }

    // MARK: El cuerpo de la pantalla

    /// Qué le toca a la pantalla.
    ///
    /// Manda la misma regla que en las otras listas —**si hay algo que enseñar, se enseña**— con un
    /// añadido propio: cuando **ningún** turno se pudo leer, la lista entera sería una columna de filas
    /// repitiendo la misma frase, así que se colapsa en un hueco solo. Y colapsa por la razón que
    /// comparten: un barrido y una avería no se dicen igual, y solo la segunda ofrece reintentar.
    public static func content(state: ConversationState) -> ConversationContent {
        switch state {
        case .idle, .loading:
            return .loading

        case .loaded(let rows):
            guard !rows.isEmpty else { return .placeholder(nothingKept) }

            let reasons = rows.map(\.body).compactMap { body -> ConversationTurnUnavailable? in
                guard case .unavailable(let reason) = body else { return nil }
                return reason
            }
            guard reasons.count == rows.count, let first = reasons.first else {
                return .turns(rows)
            }
            // Con razones distintas manda la avería: un hueco que dijera "caducó" tapando un fichero
            // ilegible se llevaría por delante el reintento, que es la única salida que hay aquí.
            let faults = reasons.filter { reason in
                switch reason {
                case .swept: return false
                case .mismatched, .unreadable: return true
                }
            }
            return .placeholder(placeholder(for: faults.first ?? first))
        }
    }

    /// Lo que se dice cuando la lista de trozos vino recortada por el tope de la consulta, o `nil` si
    /// llegó entera.
    ///
    /// Sin cifra a propósito, y por un motivo distinto al del presupuesto: la consulta pide `limit` y
    /// devuelve `limit`, así que lo único que se sabe es que **había más**. Es un caso de laboratorio
    /// —hacen falta miles de trozos diminutos, porque lo que acota de verdad es el presupuesto— pero
    /// callarlo dejaría una conversación cortada con aspecto de completa.
    public static func chunkLimitNote(shown: Int, limit: Int) -> String? {
        guard shown >= limit else { return nil }

        return String(
            localized: "conversation.truncation.chunkLimit",
            defaultValue: """
                This connection recorded more pieces of conversation than the app shows at once, so \
                this is its beginning.
                """,
            comment: """
                Footer of the decrypted conversation when the query hit its row limit. It carries \
                no figure on purpose: the query asked for a maximum and got exactly that, so all \
                that is known is that there was more. 'Pieces of conversation' are the fragments \
                the app records as each side speaks.
                """
        )
    }

    // MARK: - Copia

    /// El título de la pantalla. Dice **las mismas palabras** que la sección de Ajustes que la produce
    /// y que la fila que la cuenta en almacenamiento, con clave propia: aquí titula una pantalla, allí
    /// encabeza un bloque de controles. Que coincidan es lo que ata el interruptor a lo que hace.
    public static var title: String {
        String(
            localized: "conversation.title",
            defaultValue: "Decrypted content",
            comment: """
                Title of the screen showing what was said inside one inspected connection. Same \
                words as the settings section that governs recording it, deliberately a separate \
                key: here it titles a screen, there it heads a block of controls.
                """
        )
    }

    /// El botón que saca un turno de la app.
    ///
    /// Da **lo que está en pantalla**, igual que el del volcado hexadecimal, y por eso no promete la
    /// conversación: no hay un artefacto dibujado que sea la conversación entera, y el gesto en bloque
    /// es lo único que convertiría un toque en mover a otra app todo lo que se llegó a descifrar.
    public static var shareTitle: String {
        String(
            localized: "conversation.share",
            defaultValue: "Share what's shown",
            comment: """
                Button that sends one side's turn out of the app through the system share sheet, \
                from which the user can also copy it. It hands over exactly what is drawn above it \
                — not the whole conversation and not the bytes that were left out of the drawing — \
                so it names the drawing.
                """
        )
    }

    /// Lo que sale de la app al compartir un turno, o `nil` si no hay nada que sacar.
    ///
    /// Es **todo** lo que se guardó del turno y no lo dibujado, que es lo que separa a esta pantalla
    /// del volcado de un paquete: allí lo dibujado *es* el registro entero, y aquí un turno llega a
    /// 64 KiB y ninguna pantalla lo aguanta. Si compartir diese la vista previa, lo demás quedaría
    /// guardado en el dispositivo y fuera del alcance de su dueño, que es lo contrario de lo que hace
    /// esta app.
    ///
    /// Un binario sale como volcado y no como bytes crudos, por lo mismo que `HexDump.text`: lo que se
    /// comparte es para pegarlo en otra herramienta, y unos bytes sin estructura no se pegan en
    /// ninguna. Cómo se dibujó decide cómo se comparte, así que las dos cosas no pueden discrepar.
    public static func shareableText(_ bytes: Data, drawnAs body: ConversationBody) -> String? {
        guard !bytes.isEmpty else { return nil }

        switch body {
        case .text:
            return String(decoding: bytes, as: UTF8.self)
        case .hex:
            return HexDump.text(HexDump.lines(bytes, limit: bytes.count))
        case .unavailable:
            return nil
        }
    }

    /// Los tres huecos de un turno ilegible, y los mismos tres cuando lo son todos. Solo el último
    /// ofrece reintentar, porque es el único que un reintento podría cambiar.
    public static func placeholder(for reason: ConversationTurnUnavailable) -> ConversationPlaceholder {
        switch reason {
        case .swept(let sequence):
            return ConversationPlaceholder(
                title: String(
                    localized: "conversation.empty.swept.title",
                    defaultValue: "That content has been deleted",
                    comment: """
                        Title of the empty state when the file holding a connection's decrypted \
                        content was already deleted by the app's own expiry. It states something \
                        the user asked for when they chose how long to keep it, so it must not \
                        read as a fault or as an accident.
                        """
                ),
                message: String(
                    localized: "conversation.empty.swept.message",
                    defaultValue: """
                        Decrypted content is deleted sooner than the rest of your history — you \
                        choose how much sooner in Settings. The connection and its packets are \
                        still here; only what was said inside it is gone.
                        """,
                    comment: """
                        Body of that empty state. The second sentence is the important half: it \
                        says what was not lost, so a short expiry does not read as having taken \
                        the history with it. 'Decrypted content' is the same wording as the \
                        settings section that governs the expiry.
                        """
                ),
                systemImage: "clock.badge.xmark",
                role: .neutral,
                // No es copia: nombra el fichero para poder buscarlo, igual que el del llavero en el
                // flujo de la CA.
                diagnostic: "plaintext \(PacketBytesPresentation.fileLabel(sequence))"
            )

        case .mismatched(let detail):
            return ConversationPlaceholder(
                title: String(
                    localized: "conversation.empty.mismatched.title",
                    defaultValue: "That content doesn't match this connection",
                    comment: """
                        Title of the state where what is stored at that position belongs to another \
                        conversation. This should not happen; showing it would put one connection's \
                        decrypted contents under another's heading, which is the worst thing this \
                        app could do, so nothing is shown.
                        """
                ),
                message: String(
                    localized: "conversation.empty.mismatched.message",
                    defaultValue: """
                        What's stored at that position belongs to a different conversation, so it \
                        isn't shown — it would be someone else's content under this connection.
                        """,
                    comment: """
                        Body of that state: what was found and what follows from it. The reason \
                        matters more than the fault; showing the wrong contents is far worse than \
                        showing none.
                        """
                ),
                systemImage: "exclamationmark.triangle",
                role: .warning,
                diagnostic: detail
            )

        case .unreadable(let detail):
            return ConversationPlaceholder(
                title: String(
                    localized: "conversation.failure.unreadable.title",
                    defaultValue: "Couldn't read that content",
                    comment: """
                        Title of the only state on this screen that is a real failure: the file is \
                        there but its records could not be read. It is the only one of the three \
                        that offers a retry.
                        """
                ),
                message: String(
                    localized: "conversation.failure.unreadable.message",
                    defaultValue: """
                        What was saved of this connection is on the device, but it couldn't be read \
                        right now.
                        """,
                    comment: """
                        Body of that failure card. 'Right now' is load-bearing: the card offers a \
                        retry, so it says the read failed this time and not that the content is \
                        gone — the file itself is still there.
                        """
                ),
                systemImage: "exclamationmark.triangle",
                role: .warning,
                actionTitle: String(
                    localized: "conversation.failure.retry",
                    defaultValue: "Try again",
                    comment: """
                        Button that reads this connection's decrypted content from its files again. \
                        It repeats a handful of file reads; it does not reload the connection or \
                        the screen.
                        """
                ),
                action: .retry,
                diagnostic: detail
            )
        }
    }

    /// La conversación no tiene ni un turno. Es alcanzable desde la pantalla porque el Flow Inspector
    /// solo ofrece entrar cuando hay filas, y entre que se contaron y que se abrió la pantalla puede
    /// haber pasado un barrido.
    private static var nothingKept: ConversationPlaceholder {
        ConversationPlaceholder(
            title: String(
                localized: "conversation.empty.nothing.title",
                defaultValue: "Nothing was kept",
                comment: """
                    Title of the empty state when a connection has no decrypted content at all. \
                    'Kept' rather than 'found': nothing is missing or broken — it was either never \
                    saved or has since been deleted.
                    """
            ),
            message: String(
                localized: "conversation.empty.nothing.message",
                defaultValue: """
                    Nothing was saved of what was said inside this connection, or it has already \
                    been deleted.
                    """,
                comment: """
                    Body of that empty state. It names both ordinary reasons so it does not read \
                    as a fault: saving decrypted content is a setting of its own, and what is \
                    saved expires sooner than the rest of the history.
                    """
            ),
            systemImage: "tray",
            role: .neutral
        )
    }
}
