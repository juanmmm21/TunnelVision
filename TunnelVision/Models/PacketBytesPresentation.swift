import Foundation
import Shared

/// Qué enseña la pantalla de **un paquete**: sus bytes tal y como quedaron en el `.pcap`
/// (`docs/ux/screens.md`, *Packet detail*), y las cuatro razones por las que puede no haberlos.
///
/// Todo lo que decide *qué se lee* vive aquí, en valores puros, igual que en el resto de pantallas.
/// Lo que esta añade y las demás no es una comprobación: los bytes que se pintan tienen que ser los
/// **de este paquete**, y decir eso es una decisión, no un detalle de implementación.

/// Lo que se puede hacer desde un hueco de esta pantalla: volver a pedir los bytes.
public enum PacketBytesAction: Sendable, Equatable {
    case retry
}

public typealias PacketBytesPlaceholder = ScreenPlaceholder<PacketBytesAction>

/// Por qué no hay bytes que enseñar.
///
/// Son cuatro casos y **solo uno es una avería**. Los otros tres son estados normales de un sistema
/// donde el usuario puede borrar capturas y donde no todo paquete se guarda entero, así que ninguno se
/// pinta como error ni ofrece un reintento que no cambiaría nada: repetir la lectura de un fichero
/// borrado solo enseña a desconfiar del botón.
public enum PacketBytesUnavailable: Sendable, Equatable {
    /// El paquete no llegó a guardarse en ninguna captura (la captura estaba apagada, había fallado,
    /// o la fila viene de antes de que se guardara el fichero y la migración anuló su localización).
    case notCaptured
    /// El fichero que tenía sus bytes ya no está: lo borró su dueño desde la pantalla de capturas.
    case fileDeleted(UInt32)
    /// El registro leído **no es el de este paquete**. No debería pasar —la secuencia de un fichero
    /// borrado no se reutiliza—, pero si pasa, enseñar esos bytes sería atribuirle a una conexión el
    /// tráfico de otra, que es justo lo que `CaptureLocation` existe para impedir.
    case mismatched(expected: UInt32, found: UInt32)
    /// La lectura falló de verdad: el fichero no se deja abrir, o el registro está a medias.
    case failed(CaptureLibraryError)
}

/// En qué punto está la lectura de los bytes.
public enum PacketBytesState: Sendable, Equatable {
    case idle
    case loading
    case loaded(CaptureRecord)
    case unavailable(PacketBytesUnavailable)
}

/// Una línea del volcado hexadecimal: la posición, los bytes y su lectura como texto.
///
/// Se parte en tres porque la vista los alinea en tres columnas de ancho fijo, y componer la línea
/// entera aquí obligaría a la vista a volver a partirla para poder alinearla.
public struct HexDumpLine: Sendable, Equatable, Identifiable {

    /// Posición del primer byte de la línea dentro del paquete.
    public let offset: Int

    /// Los bytes en hexadecimal, separados por espacios y con un hueco doble a la mitad: la columna
    /// central es lo que permite contar bytes con el dedo sin ir de uno en uno.
    public let hex: String

    /// Los mismos bytes leídos como ASCII imprimible, con `.` en todo lo demás. Es lo que hace visible
    /// de un vistazo un `Host:` o un `GET /` dentro de una petición en claro.
    public let ascii: String

    public var id: Int { offset }

    public init(offset: Int, hex: String, ascii: String) {
        self.offset = offset
        self.hex = hex
        self.ascii = ascii
    }

    /// La posición en hexadecimal y con relleno, que es como la enseñan `xxd` y Wireshark: `"0010"`.
    public var offsetLabel: String { String(format: "%04X", offset) }

    /// Lo que VoiceOver oye de una línea del volcado: la posición y su lectura como texto, **nunca** los
    /// dieciséis pares hexadecimales — leerlos uno a uno es un minuto por línea y no se retiene nada.
    ///
    /// La componía `HexDumpRow` dentro de SwiftUI, y con ello el `Text` literal había convertido
    /// `Offset %@: %@` en una unidad de traducción: formato que un traductor ve y con el que no puede
    /// hacer nada bueno. Es la misma familia que `" – "` en la barra de scrub y la misma salida —
    /// componer en el núcleo puro, que además es donde se puede afirmar.
    public var accessibilityLabel: String {
        String(
            localized: "packetDetail.hexDump.line.accessibilityLabel",
            defaultValue: "Offset \(offsetLabel): \(ascii)",
            comment: """
                What VoiceOver reads of one line of the hex dump. The first placeholder is the \
                line's position inside the packet, in hexadecimal as xxd and Wireshark show it; \
                the second is those bytes read as text, with a dot wherever a byte is not \
                printable. The hexadecimal pairs themselves are deliberately not spoken. 'Offset' \
                is the term used for a position inside a packet.
                """
        )
    }
}

/// El volcado hexadecimal de unos bytes. Puro y determinista: ni localiza nada ni consulta reloj.
public enum HexDump {

    public static let bytesPerLine = 16

    /// Cuántos bytes se llegan a pintar.
    ///
    /// Un paquete puede medir hasta el `snaplen` del writer (256 KB), y volcar eso son 16.000 líneas
    /// que nadie va a leer y que la pantalla sí tiene que construir. El tope es del mismo tipo que el
    /// de paquetes por conexión, y se cumple la misma regla: **si se recorta, se dice**.
    public static let maxBytesShown = 2_048

    /// Las líneas del volcado, cortadas a `maxBytesShown`.
    public static func lines(_ data: Data, limit: Int = maxBytesShown) -> [HexDumpLine] {
        let shown = data.prefix(max(0, limit))
        return stride(from: 0, to: shown.count, by: bytesPerLine).map { start in
            let chunk = Array(shown[(shown.startIndex + start)..<min(shown.startIndex + start + bytesPerLine, shown.endIndex)])
            return HexDumpLine(offset: start, hex: hex(chunk), ascii: ascii(chunk))
        }
    }

    /// `"45 00 00 3c 1c 46 40 00  40 06 b1 e6 c0 a8 00 68"`. Una línea corta no se rellena con
    /// espacios: alinear columnas es de la vista, que es quien sabe con qué fuente se pinta.
    private static func hex(_ bytes: [UInt8]) -> String {
        var parts: [String] = []
        for (index, byte) in bytes.enumerated() {
            // El hueco doble a mitad de línea es la referencia visual para contar; sin él, dieciséis
            // pares iguales se leen como una tira sin marcas.
            if index > 0, index == bytesPerLine / 2 { parts.append("") }
            parts.append(String(format: "%02x", byte))
        }
        return parts.joined(separator: " ")
    }

    /// Todo lo que no sea ASCII imprimible se enseña como `.`, incluidos los saltos de línea: un salto
    /// real partiría la fila y descuadraría la única columna que hace legible el volcado.
    private static func ascii(_ bytes: [UInt8]) -> String {
        String(bytes.map { $0 >= 0x20 && $0 <= 0x7e ? Character(UnicodeScalar($0)) : "." })
    }

    /// Ancho de la columna hexadecimal de una línea llena: 16 pares (32) + los 16 separadores que deja
    /// el hueco de la mitad. Se rellena la última línea hasta aquí para que la columna de texto siga
    /// cuadrando en el volcado compartido, donde ya no hay una vista que alinee nada.
    private static let hexColumnWidth = bytesPerLine * 2 + bytesPerLine

    /// El volcado como texto plano, en el formato en que lo imprimen `xxd` y `tcpdump -X`.
    ///
    /// No pasa por el catálogo y no es copia: es un artefacto para pegar en otra herramienta, igual que
    /// los sellos ISO de `FlowExport`. Traducirlo solo podría estropearlo.
    ///
    /// Comparte **lo que se está viendo**, líneas ya recortadas incluidas, y no el registro entero: el
    /// botón sale al lado del volcado, y que diese más de lo que hay en pantalla haría imposible saber
    /// qué se acaba de compartir.
    public static func text(_ lines: [HexDumpLine]) -> String {
        lines
            .map { line in
                let hex = line.hex.padding(toLength: hexColumnWidth, withPad: " ", startingAt: 0)
                return "\(line.offsetLabel)  \(hex)  \(line.ascii)"
            }
            .joined(separator: "\n")
    }
}

/// El cuerpo de la pantalla. Exhaustivo: cada estado cae en uno y solo uno.
public enum PacketBytesContent: Sendable, Equatable {
    case loading
    case bytes([HexDumpLine])
    case placeholder(PacketBytesPlaceholder)
}

public enum PacketBytesPresentation {

    // MARK: - Qué se lee

    /// Comprueba que el registro leído es el del paquete que se pidió, comparando lo que medía.
    ///
    /// Es barato y es el único cotejo posible: el pipeline escribe `orig_len` con el mismo
    /// `packet.count` que guarda en `PacketMeta.length`, así que si no coinciden, el offset ha llevado
    /// a otro registro. Ante eso no se enseñan los bytes — una lectura equivocada de los bytes de otra
    /// conexión es peor que no enseñar ninguno, la misma regla por la que un flujo sin host se queda
    /// sin host en vez de adivinarlo.
    public static func verify(_ record: CaptureRecord, expectedLength: UInt32) -> PacketBytesState {
        guard record.originalLength == expectedLength else {
            return .unavailable(.mismatched(expected: expectedLength, found: record.originalLength))
        }
        return .loaded(record)
    }

    /// Traduce el fallo del servicio al estado de la pantalla. Un fichero que ya no está **no** es un
    /// fallo aquí: es lo que le pasa a cualquier paquete cuya captura el usuario haya borrado.
    public static func unavailable(for error: CaptureLibraryError) -> PacketBytesUnavailable {
        switch error {
        case .notFound(let sequence):
            return .fileDeleted(sequence)
        case .containerUnavailable, .deletionFailed, .recordUnreadable:
            return .failed(error)
        }
    }

    // MARK: - Cuerpo

    public static func content(state: PacketBytesState) -> PacketBytesContent {
        switch state {
        case .idle, .loading:
            return .loading
        case .loaded(let record):
            return .bytes(HexDump.lines(record.bytes))
        case .unavailable(let reason):
            return .placeholder(placeholder(for: reason))
        }
    }

    /// Lo que se dice cuando no se enseñan todos los bytes, o `nil` si están todos.
    ///
    /// Son dos recortes distintos y se cuentan los dos: el del `snaplen`, que ocurrió **al capturar**
    /// y ya no tiene vuelta, y el de la pantalla, que solo afecta a lo que se pinta. Confundirlos
    /// dejaría al usuario creyendo que un paquete de 9 KB midió 2 KB.
    ///
    /// Los dos avisos pueden salir solos o juntos, así que juntarlos **también** es una clave: pegar
    /// dos frases con un espacio en Swift decide fuera del catálogo el orden y el separador, que son de
    /// un idioma. Es la misma forma que `ScrubAccessibility.cursorValue`.
    public static func truncationNote(for record: CaptureRecord, limit: Int = HexDump.maxBytesShown) -> String? {
        var notes: [String] = []

        if record.isTruncated {
            notes.append(
                String(
                    localized: "packetDetail.bytes.truncation.whenCaptured",
                    defaultValue: """
                        Only \(DisplayFormat.bytes(UInt64(record.capturedLength))) of this \
                        \(DisplayFormat.bytes(UInt64(record.originalLength))) packet were saved — \
                        captures keep a limited amount of every packet.
                        """,
                    comment: """
                        Footer under the hex dump when the capture itself kept only the start of \
                        the packet. The placeholders are how much was saved and how big the packet \
                        was. This one happened when the packet went by and cannot be undone, which \
                        is what tells it apart from the sibling key about what the screen draws.
                        """
                )
            )
        }

        if record.bytes.count > limit {
            notes.append(
                String(
                    localized: "packetDetail.bytes.truncation.whenShown",
                    defaultValue: "Showing the first \(DisplayFormat.bytes(UInt64(limit))).",
                    comment: """
                        Footer under the hex dump when the screen draws only the start of what was \
                        saved. The placeholder is how much is drawn. Unlike its sibling key, \
                        nothing was lost here: the rest of the bytes are in the capture file.
                        """
                )
            )
        }

        guard let first = notes.first else { return nil }
        guard let second = notes.dropFirst().first else { return first }

        return String(
            localized: "packetDetail.bytes.truncation.both",
            defaultValue: "\(first) \(second)",
            comment: """
                The two footers above, shown together when both apply. The placeholders are those \
                two sentences; only their order and the space between them are translatable here. \
                Both are said: confusing them would leave the user believing a 9 KB packet was 2 KB.
                """
        )
    }

    /// Lo que se sabe del paquete **sin abrir ningún fichero**: cuándo pasó dentro de la conexión, en
    /// qué sentido y cuánto medía.
    ///
    /// Está siempre, incluso cuando no hay bytes que enseñar, y por eso la fila del Flow Inspector
    /// lleva a esta pantalla aunque el paquete no se capturase: una lista donde solo algunas filas
    /// responden al toque no deja adivinar cuáles, y aquí siempre hay algo que contar.
    ///
    /// **Son tres y son siempre tres**, y esa cifra fija es lo que resuelve la fila suelta que esta
    /// pantalla arrastraba. Antes eran cuatro *o* tres —las siglas solo existen si el paquete las
    /// trae—, así que una rejilla de dos columnas dejaba un hueco en todos los paquetes que no son
    /// TCP, que son justo los más comunes después de él (DNS y QUIC van sobre UDP). Las siglas se han
    /// ido con el titular, que es **su lectura**: *Connection opened* es lo que significa `SYN`, y un
    /// dato pegado a su interpretación es una pareja, no dos datos sueltos — es donde `PacketRow` ya
    /// las pone en la lista de la que se llega.
    public static func packetFacts(_ packet: PacketSummary) -> [FlowFact] {
        [
            FlowFact(
                id: "when",
                label: String(
                    localized: "packetDetail.fact.when",
                    defaultValue: "When",
                    comment: """
                        Label of how far into the connection this packet happened, next to a value \
                        like '0.004 s'. It is a position within the connection, not a clock time: \
                        the absolute hour of a single packet says nothing.
                        """
                ),
                value: .text(DisplayFormat.offset(packet.offset))
            ),
            FlowFact(
                id: "direction",
                label: String(
                    localized: "packetDetail.fact.direction",
                    defaultValue: "Direction",
                    comment: """
                        Label of which way the packet travelled, next to the shared direction word \
                        ('Received' / 'Sent'), which has its own key.
                        """
                ),
                value: .text(DirectionLabel.of(packet.direction))
            ),
            FlowFact(
                id: "size",
                label: String(
                    localized: "packetDetail.fact.size",
                    defaultValue: "Size",
                    comment: """
                        Label of how big the packet was on the wire, next to a formatted byte \
                        amount. It is the whole packet, which is not the same as how much of it \
                        reached the capture file — when those differ, the footer under the hex \
                        dump says so in words, with both figures.
                        """
                ),
                value: .text(DisplayFormat.bytes(UInt64(packet.length)))
            ),
        ]
    }

    /// Lo que VoiceOver oye de las siglas de control que el paquete traía.
    ///
    /// Existe porque las siglas dejaron de ser una celda de la rejilla —que llevaba su rótulo puesto—
    /// y pasaron a acompañar al titular, donde en pantalla se leen solas: `SYN` junto a *Connection
    /// opened* se entiende por vecindad, pero dicho en voz alta y sin nada delante es una sílaba
    /// suelta. La frase se compone **aquí** y no en la vista por lo mismo que la de una línea del
    /// volcado: los dos puntos y el orden son de un idioma.
    public static func flagsAccessibilityLabel(_ flags: String) -> String {
        String(
            localized: "packetDetail.flags.accessibilityLabel",
            defaultValue: "Flags: \(flags)",
            comment: """
                What VoiceOver reads of the TCP control flags a packet carried, beside the \
                headline that interprets them. The placeholder is a value like 'SYN, ACK'; those \
                acronyms are the protocol's own names on the wire and are never translated. \
                'Flags' is the term the protocol uses for them.
                """
        )
    }

    /// **De dónde salieron estos bytes**: qué fichero los tiene y en qué punto de él empiezan.
    ///
    /// Ya no describen el paquete sino el **registro en disco**, así que se leen bajo el encabezado
    /// *Raw bytes* y no en el resumen: explican la procedencia de lo que hay justo debajo, que es lo
    /// único a lo que se refieren. En el resumen eran tres datos de otra cosa metidos entre los del
    /// paquete, y de paso lo que dejaba una fila suelta al final de una rejilla de dos columnas.
    ///
    /// **Y son dos porque *Bytes saved* se ha ido del todo, no se ha mudado.** Decía lo mismo que
    /// *Size* en todo paquete que quepa entero —o sea en casi todos—, y en el único donde decía otra
    /// cosa, el pie del volcado ya lo cuenta con palabras y con las **dos** cifras
    /// (`truncationNote`). Un hueco en una rejilla se cierra quitando un dato, y este sobraba en las
    /// dos ramas.
    ///
    /// El fichero se nombra igual que en la pantalla de capturas para que el usuario pueda ir a
    /// buscarlo ahí, y el offset va en bytes, que es lo que significa.
    public static func recordFacts(_ record: CaptureRecord) -> [FlowFact] {
        [
            FlowFact(
                id: "captureFile",
                label: String(
                    localized: "packetDetail.fact.captureFile",
                    defaultValue: "Capture file",
                    comment: """
                        Label of which capture file holds this packet's bytes, next to the file's \
                        number. The user can go and find that file on the captures screen, so this \
                        must name the same thing that screen does.
                        """
                ),
                value: .text(fileLabel(record.location.fileSequence))
            ),
            FlowFact(
                id: "positionInFile",
                label: String(
                    localized: "packetDetail.fact.positionInFile",
                    defaultValue: "Position in file",
                    comment: """
                        Label of where inside that capture file this packet's record begins, next \
                        to a byte count. It is a position, which is why it is measured in bytes \
                        and not in packets.
                        """
                ),
                value: .text("\(DisplayFormat.count(record.location.recordOffset)) B")
            ),
        ]
    }

    /// El fichero, con el mismo relleno que lleva en su nombre: así lo que se lee aquí es lo que se ve
    /// en la pantalla de capturas y en el fichero exportado.
    public static func fileLabel(_ sequence: UInt32) -> String {
        String(format: "%0\(CaptureFileName.sequenceDigits)u", sequence)
    }

    // MARK: - Copia

    /// Los cuatro huecos. Solo el último ofrece reintentar, porque es el único que un reintento
    /// puede arreglar; los otros tres explican algo que ya pasó y no va a cambiar.
    public static func placeholder(for reason: PacketBytesUnavailable) -> PacketBytesPlaceholder {
        switch reason {
        case .notCaptured:
            return PacketBytesPlaceholder(
                title: String(
                    localized: "packetDetail.empty.notCaptured.title",
                    defaultValue: "No bytes saved for this packet",
                    comment: """
                        Title of the empty state on a packet's screen when its raw bytes were \
                        never written to a capture file. Nothing is broken and nothing is missing, \
                        so it must not read as a failure.
                        """
                ),
                message: String(
                    localized: "packetDetail.empty.notCaptured.message",
                    defaultValue: """
                        This packet was recorded, but its raw bytes weren't written to a capture \
                        file — capture was off or had stopped when it went through.
                        """,
                    comment: """
                        Body of that empty state. It names both ordinary reasons: recording packet \
                        files is a setting of the app, and it may also have stopped on its own \
                        (out of storage, for instance) before this packet went by.
                        """
                ),
                systemImage: "tray",
                role: .neutral
            )

        case .fileDeleted(let sequence):
            return PacketBytesPlaceholder(
                title: String(
                    localized: "packetDetail.empty.fileDeleted.title",
                    defaultValue: "Those bytes are gone",
                    comment: """
                        Title of the empty state when the capture file holding this packet was \
                        deleted by the user. It states a fact about a deliberate action, so it \
                        must not read as an accident or as data loss.
                        """
                ),
                message: String(
                    localized: "packetDetail.empty.fileDeleted.message",
                    defaultValue: """
                        The capture file that held this packet was deleted. The connection and its \
                        packets stay in your history — only the raw bytes were removed.
                        """,
                    comment: """
                        Body of that empty state. The second sentence is the important half: it \
                        says what was *not* lost, so deleting a capture does not read as having \
                        deleted the history too.
                        """
                ),
                systemImage: "trash",
                role: .neutral,
                // El diagnóstico no es copia: nombra el fichero para poder buscarlo, igual que el
                // del llavero en el flujo de la CA, y no pasa por el catálogo.
                diagnostic: "capture \(fileLabel(sequence))"
            )

        case .mismatched(let expected, let found):
            return PacketBytesPlaceholder(
                title: String(
                    localized: "packetDetail.empty.mismatched.title",
                    defaultValue: "Those bytes don't match this packet",
                    comment: """
                        Title of the state where the record read from the capture file describes a \
                        different packet. This should never happen; showing those bytes would \
                        attribute another connection's traffic to this one, which is why nothing \
                        is shown.
                        """
                ),
                message: String(
                    localized: "packetDetail.empty.mismatched.message",
                    defaultValue: """
                        What's stored at that position describes a different packet, so it isn't \
                        shown — it would be another connection's traffic.
                        """,
                    comment: """
                        Body of that state: what was found and why nothing is drawn. The reason \
                        matters more than the fault — showing the wrong bytes is worse than \
                        showing none.
                        """
                ),
                systemImage: "exclamationmark.triangle",
                role: .warning,
                diagnostic: "expected \(expected) B, record says \(found) B"
            )

        case .failed(let error):
            return PacketBytesPlaceholder(
                title: String(
                    localized: "packetDetail.failure.unreadable.title",
                    defaultValue: "Couldn't read those bytes",
                    comment: """
                        Title of the only state on this screen that is a real failure: the capture \
                        file is there but the packet's record could not be read from it. It is the \
                        only one of the four that offers a retry.
                        """
                ),
                message: String(
                    localized: "packetDetail.failure.unreadable.message",
                    defaultValue: """
                        The capture file is there, but this packet's record couldn't be read from \
                        it right now.
                        """,
                    comment: """
                        Body of that failure card. 'Right now' is load-bearing: the card offers a \
                        retry, so it says the read failed this time and not that the bytes are \
                        lost — the file itself is still there.
                        """
                ),
                systemImage: "exclamationmark.triangle",
                role: .warning,
                actionTitle: String(
                    localized: "packetDetail.failure.retry",
                    defaultValue: "Try again",
                    comment: """
                        Button that reads this packet's bytes from the capture file again. It \
                        repeats one file read, and it is offered only where repeating it could \
                        give a different answer.
                        """
                ),
                action: .retry,
                diagnostic: CapturesPresentation.diagnostic(for: error)
            )
        }
    }

    /// El botón que saca los bytes de la app.
    ///
    /// Es un `ShareLink` sobre texto y no sobre un fichero, que es lo que lo hace barato: la hoja del
    /// sistema ya trae *Copiar* dentro, así que copiar y compartir son el mismo gesto y no hay temporal
    /// que limpiar después — al contrario que el export de un `.pcap` o del listado de conexiones, donde
    /// lo que viaja sí es un fichero.
    public static var shareBytesTitle: String {
        String(
            localized: "packetDetail.shareBytes",
            defaultValue: "Share hex dump",
            comment: """
                Button that sends the packet's hex dump out of the app through the system share \
                sheet, from which the user can also copy it. It shares exactly the dump drawn \
                below it, so it names the dump and not the packet.
                """
        )
    }

    /// El encabezado del volcado.
    public static var rawBytesSectionTitle: String {
        String(
            localized: "packetDetail.section.rawBytes",
            defaultValue: "Raw bytes",
            comment: """
                Heading of the hex dump on a packet's screen. 'Raw' says these are the bytes \
                exactly as they travelled — the bare IP datagram — and not an interpretation of \
                them, which is what everything above the heading is.
                """
        )
    }
}
