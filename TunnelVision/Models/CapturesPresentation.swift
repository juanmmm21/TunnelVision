import Foundation
import Shared

/// Qué enseña la pantalla de capturas (`docs/ux/screens.md`) para lo que hay en el directorio.
///
/// Las decisiones de esta pantalla no son de dibujo: **cuál de los ficheros está escribiéndose ahora
/// mismo** (y por tanto no se puede exportar ni borrar), **qué se pierde al borrar uno** y **qué se
/// le cuenta al usuario cuando una acción no sale**. Las tres viven aquí, en valores puros, para que
/// se puedan afirmar sin pintar nada — igual que `TimelinePresentation` y `MonitoringPresentation`.

/// Lo que el usuario puede hacer desde un hueco de la pantalla.
public enum CapturesAction: Sendable, Equatable {
    /// Volver a leer el directorio tras un fallo.
    case retry
}

public typealias CapturesPlaceholder = ScreenPlaceholder<CapturesAction>

/// En qué punto está la lectura del directorio.
public enum CapturesState: Sendable, Equatable {
    case idle
    case loading
    case loaded
    case failed(CaptureLibraryError)
}

/// Qué está esperando la pantalla ahora mismo. Existe para que la fila que se está borrando y el
/// botón de rotar puedan decirlo, en vez de quedarse mudos mientras el disco trabaja.
///
/// `exporting` es el estado que `docs/ux/screens.md` pedía y que hasta ahora no existía: compartir un
/// `.pcap` no prepara nada (el fichero ya está en disco y `ShareLink` **es** la hoja del sistema),
/// pero el listado de conexiones en JSON hay que escribirlo antes, y eso sí tarda.
public enum CapturesActivity: Sendable, Equatable {
    case idle
    case rotating
    case deleting(UInt32)
    case exporting
}

/// El cuerpo de la pantalla. Exhaustivo: cada estado cae en uno y solo uno.
public enum CapturesContent: Sendable, Equatable {
    case loading
    case list
    case placeholder(CapturesPlaceholder)
}

/// Una fila de la lista: un fichero de captura listo para enseñarse.
///
/// La fecha viaja como `Date` y no como texto ya formateado, al revés que el tamaño: un volumen de
/// datos se formatea de forma **determinista** a propósito (`DisplayFormat`, para que la etiqueta no
/// baile ni dependa de la región), mientras que un instante sí debe salir en el formato del
/// dispositivo del usuario, y eso lo hace la vista.
public struct CaptureFileDisplay: Sendable, Equatable, Identifiable {

    public var id: UInt32 { sequence }

    public let sequence: UInt32
    public let url: URL

    /// El nombre que ve el usuario. No es el del fichero: ese lleva la secuencia con relleno y un
    /// sello UTC, que son para reconocerlo **fuera** de la app, una vez exportado.
    public let title: String

    public let sizeText: String
    public let createdAt: Date?

    /// Si es el fichero que la extensión está escribiendo ahora mismo.
    public let isRecording: Bool

    /// Un fichero abierto no se exporta ni se borra. No es una restricción cosmética: sus últimos
    /// bytes pueden ser un registro a medio escribir, y borrarlo dejaría a la extensión escribiendo
    /// en un inodo que ya no tiene nombre — sin un solo error, y sin nada que exportar después. La
    /// salida es cerrarlo, que es exactamente para lo que existe `ControlCommand.rotateCapture`.
    public var isActionable: Bool { !isRecording }

    public init(
        sequence: UInt32,
        url: URL,
        title: String,
        sizeText: String,
        createdAt: Date?,
        isRecording: Bool
    ) {
        self.sequence = sequence
        self.url = url
        self.title = title
        self.sizeText = sizeText
        self.createdAt = createdAt
        self.isRecording = isRecording
    }
}

/// El inventario del directorio: cuántas capturas hay y cuánto ocupan.
///
/// El pie de la lista solo dice la cuenta (`text`); los bytes viajan igual porque son la mitad de la
/// comparación que la pantalla hace contra el tope de Ajustes (`CaptureHeadroom`), y ahí es donde se
/// dicen.
public struct CapturesSummary: Sendable, Equatable {
    public let fileCount: Int
    public let totalBytes: UInt64
    public let text: String

    public init(fileCount: Int, totalBytes: UInt64, text: String) {
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.text = text
    }
}

/// Lo que se le cuenta al usuario tras una acción: el resultado de rotar o de borrar, y también un
/// refresco que falló con la lista ya pintada.
///
/// Es un aviso y no un `placeholder` porque **una lista ya dibujada no se tapa** — la misma regla que
/// manda en la Timeline —: lo que ha fallado es una acción, no lo que el usuario está mirando.
public struct CapturesNotice: Sendable, Equatable {
    public let message: String
    public let diagnostic: String?
    public let role: StatusRole

    public init(message: String, diagnostic: String? = nil, role: StatusRole) {
        self.message = message
        self.diagnostic = diagnostic
        self.role = role
    }
}

/// El export ya escrito, tal y como se le enseña al usuario **antes** de compartirlo.
///
/// Existe porque un export no es una copia del historial y decirlo después no sirve de nada: el
/// fichero ya estaría fuera del dispositivo. Se enseña qué lleva dentro (cuántas conexiones, cuánto
/// ocupa, si el tope recortó) y solo entonces se ofrece compartirlo.
public struct FlowExportSummary: Sendable, Equatable, Identifiable {

    /// El fichero es su propia identidad: es lo que la hoja del sistema va a compartir.
    public var id: URL { url }

    public let url: URL
    public let fileName: String
    public let title: String
    public let detail: String

    /// El aviso del tope, si lo hubo. Aparte del detalle porque no es lo mismo un export completo
    /// que uno recortado, y mezclarlos dejaría el recorte como letra pequeña.
    public let truncationNote: String?

    public init(
        url: URL,
        fileName: String,
        title: String,
        detail: String,
        truncationNote: String?
    ) {
        self.url = url
        self.fileName = fileName
        self.title = title
        self.detail = detail
        self.truncationNote = truncationNote
    }
}

/// Lo que se dice de la caducidad de la captura más antigua.
///
/// Son **dos formas de dibujo y no dos textos**: o hay una fecha —y entonces la fila es un rótulo y un
/// valor, con la fecha formateada por la vista, que es quien sabe el huso y el formato del
/// dispositivo— o no la hay, y lo que queda es una frase que explica por qué. Escribirlo como un solo
/// texto obligaría a componer la fecha en el núcleo puro, que es justo donde el formato del
/// dispositivo no se conoce.
public enum CaptureExpiryDisplay: Sendable, Equatable {
    case dated(label: String, date: Date)
    case stated(String)
}

/// El estado de los topes, ya redactado (`CaptureHeadroom`).
public struct CaptureHeadroomDisplay: Sendable, Equatable {

    /// La respuesta corta, que es lo que se lee primero: cuánto queda libre, o el desenlace que
    /// impide decirlo.
    public let headline: String

    /// Las cifras crudas bajo el titular: cuánto se usa, y de cuánto cuando hay tope.
    public let usage: String

    /// Qué va a pasar. No repite ninguna cifra: las cifras están arriba.
    public let detail: String

    /// Qué parte del tope está ocupada, entre 0 y 1, o `nil` cuando no hay tope que llenar — y
    /// entonces no hay barra, porque una barra sin final no mide nada.
    public let fill: Double?

    /// Lo que se sabe de la caducidad, o `nil` cuando no hay ningún tope del que hablar (`unbounded`,
    /// donde la única frase que importa ya la dice `detail`).
    public let expiry: CaptureExpiryDisplay?

    public let role: StatusRole

    public init(
        headline: String,
        usage: String,
        detail: String,
        fill: Double?,
        expiry: CaptureExpiryDisplay?,
        role: StatusRole
    ) {
        self.headline = headline
        self.usage = usage
        self.detail = detail
        self.fill = fill
        self.expiry = expiry
        self.role = role
    }
}

public enum CapturesPresentation {

    // MARK: - Chrome de la pantalla

    /// El rótulo de la pestaña. Clave propia y separada del título por lo mismo que en la Timeline: la
    /// barra reparte su ancho entre cuatro, así que un idioma puede necesitar aquí una forma más corta
    /// de la misma palabra.
    public static var tabTitle: String {
        String(
            localized: "captures.tab",
            defaultValue: "Captures",
            comment: """
                Tab bar label of the third screen. Same word as its title, separate key: the tab \
                bar shares its width with three other items, so it may need a shorter form.
                """
        )
    }

    public static var screenTitle: String {
        String(
            localized: "captures.screen.title",
            defaultValue: "Captures",
            comment: """
                Title of the screen listing the .pcap files written so far. 'Captures' is what the \
                app calls those files everywhere, including the Settings row that counts them.
                """
        )
    }

    /// Qué fichero está escribiendo la extensión, si es que hay alguno.
    ///
    /// Se deduce en vez de preguntarse: el writer escribe siempre en la secuencia **más alta** del
    /// directorio (arranca por encima de la mayor que ve y solo sube al rotar), y solo hay un writer
    /// abierto mientras el túnel está vivo. Con el túnel parado no hay ninguno, por muy reciente que
    /// sea el último fichero — y darlo entonces por abierto le quitaría al usuario el único fichero
    /// que probablemente quiere exportar.
    public static func recordingSequence(files: [CaptureFileInfo], isMonitoring: Bool) -> UInt32? {
        guard isMonitoring else { return nil }
        return files.map(\.sequence).max()
    }

    /// Las filas, de la más reciente a la más antigua.
    ///
    /// El orden es el inverso al del directorio (que ordena por secuencia ascendente, su orden
    /// cronológico) por lo mismo que la Timeline va hacia atrás en el tiempo: lo último capturado es
    /// lo que el usuario viene a exportar.
    public static func rows(_ files: [CaptureFileInfo], recordingSequence: UInt32?) -> [CaptureFileDisplay] {
        files
            .sorted { $0.sequence > $1.sequence }
            .map { file in
                CaptureFileDisplay(
                    sequence: file.sequence,
                    url: file.url,
                    title: title(forSequence: file.sequence),
                    sizeText: DisplayFormat.bytes(file.byteCount),
                    createdAt: file.createdAt,
                    isRecording: file.sequence == recordingSequence
                )
            }
    }

    /// Cómo se llama un fichero para el usuario. La secuencia **identifica** —es la que distingue una
    /// captura de la siguiente y la que se nombra al borrar—, así que va sin agrupar: `Capture 20000`,
    /// nunca `Capture 20.000`. Y va envuelta en `String(...)` porque un entero interpolado en un
    /// `String(localized:)` **sí** lo formatea el locale del proceso; envolverlo elige el camino
    /// literal. La regla entera está en `docs/development/02-coding-standards.md`.
    public static func title(forSequence sequence: UInt32) -> String {
        String(
            localized: "captures.file.title",
            defaultValue: "Capture \(String(sequence))",
            comment: """
                Name of one capture file as the user sees it. The placeholder is the file's \
                sequence number, which identifies it: it is never grouped with thousands \
                separators. This is not the file's name on disk, which also carries a UTC stamp \
                and is meant to be recognised outside the app.
                """
        )
    }

    /// El distintivo del fichero que se está escribiendo ahora mismo. Es un gerundio a propósito: lo
    /// que dice es que **está pasando**, no que el fichero sea de un tipo distinto.
    public static var recordingBadgeTitle: String {
        String(
            localized: "captures.file.recording",
            defaultValue: "Recording",
            comment: """
                Badge on the capture file the extension is writing right now. It describes \
                something happening at this moment, which is why that file cannot be shared or \
                deleted; it is not a category of file.
                """
        )
    }

    /// Lo que oye VoiceOver de una fila, después del nombre de la captura: cuánto ocupa, cuándo
    /// empezó y, si es el fichero abierto, que se está escribiendo ahora mismo.
    ///
    /// Es **una sola frase para toda la fila** porque la fila es un solo elemento. Antes eran tres
    /// —el nombre, el botón de compartir y la línea de detalle—, y el orden del recorrido los
    /// entregaba así: el árbol se recorre por posición, y el botón, centrado contra el alto de la
    /// fila, cae **entre** el nombre y su propio detalle. Se oía «Capture 2», «Share Capture 2»,
    /// «2.2 MB · 20 Aug at 05:49»: la acción metida en medio de la descripción de lo que actúa.
    ///
    /// La hora llega ya formateada porque el huso y el formato son del dispositivo y eso lo sabe la
    /// vista. Lo que ya **no** decide esta función es cómo se dibujan juntas: el tamaño se fue a su
    /// propia columna de cifras y la hora se quedó sola en el renglón de debajo, así que el `·` que
    /// las unía se quedó sin trabajo. Aquí se dicen con palabras, que es lo que se puede oír.
    ///
    /// El caso de la que se está escribiendo **envuelve** al otro en vez de repetirlo, igual que
    /// `shareAccessibilityLabel` envuelve a `title(forSequence:)`: dos claves que dicen lo mismo con
    /// distintas palabras es exactamente cómo una traducción acaba diciendo dos cosas.
    public static func rowAccessibilityValue(size: String, time: String?, isRecording: Bool) -> String {
        let sizeAndTime: String = {
            guard let time else { return size }

            return String(
                localized: "captures.file.accessibilityValue",
                defaultValue: "\(size), started \(time)",
                comment: """
                    VoiceOver value of a capture's row, read after its name. Both placeholders are \
                    already formatted (a byte amount and a date in the device's own format). A \
                    capture whose date could not be read is described by its size alone.
                    """
            )
        }()

        guard isRecording else { return sizeAndTime }

        return String(
            localized: "captures.file.accessibilityValue.recording",
            defaultValue: "\(sizeAndTime), being written right now",
            comment: """
                VoiceOver value of the capture the extension is writing right now. The placeholder \
                is everything the sibling key says about any capture, wrapped rather than \
                repeated, so the two cannot drift apart in a translation. What it adds is why this \
                one offers no actions: it is still growing.
                """
        )
    }

    /// Lo que se oye del botón de compartir de una fila, que a la vista solo es un icono.
    ///
    /// **Interpola el nombre de la captura en vez de repetirlo**: el rótulo sale de `title(forSequence:)`,
    /// así que los dos no pueden acabar diciendo cosas distintas en un idioma.
    public static func shareAccessibilityLabel(for file: CaptureFileDisplay) -> String {
        String(
            localized: "captures.file.share.accessibilityLabel",
            defaultValue: "Share \(file.title)",
            comment: """
                VoiceOver label of the share button in a capture's row, which is only an icon. The \
                placeholder is that capture's own name, interpolated from the key that draws it, \
                so the two cannot drift apart.
                """
        )
    }

    public static func summary(_ files: [CaptureFileInfo]) -> CapturesSummary {
        let total = files.reduce(UInt64(0)) { $0 + $1.byteCount }
        let count = files.count
        return CapturesSummary(
            fileCount: count,
            totalBytes: total,
            text: summaryText(fileCount: count)
        )
    }

    /// El pie de la lista, en palabras: **cuántas capturas hay, y nada más**.
    ///
    /// Decía además cuánto ocupaban (`3 captures · 6.7 MB`) y ya no, desde que la pantalla compara ese
    /// tamaño con el tope de Ajustes (`headroom(_:)`): un hecho se dice **una vez**, y el sitio donde
    /// un tamaño se dice es donde está aquello con lo que se compara. La cuenta se queda porque hace
    /// la otra mitad del trabajo —**sitúa** la lista, se lee sola y no se compara con nada—, que es la
    /// misma línea por la que `StorageFigure` separa sus dos cifras.
    ///
    /// El `·` se fue con el tamaño, y eso también es a propósito: puntuación compuesta a mano entre
    /// dos datos es copia en el único sitio al que un traductor no llega.
    ///
    /// Plural con **dos claves hermanas** y jamás el marcado `inflect:`, por la razón medida que está en
    /// `docs/development/02-coding-standards.md`: sin catálogo —y el bundle de tests no lleva ninguno—
    /// ese marcado no se resuelve y saldría crudo. El día que se traduzca a un idioma con más formas de
    /// plural, este par se funde en una clave con variaciones en el catálogo.
    private static func summaryText(fileCount: Int) -> String {
        guard fileCount != 1 else {
            return String(
                localized: "captures.summary.one",
                defaultValue: "1 capture",
                comment: """
                    Footer of the capture list when there is exactly one file. It counts files and \
                    says nothing about size: how much they occupy is said once, beside the limit \
                    it is compared against. See the plural form in the sibling key; a language \
                    with more plural forms needs both merged into one key with catalog variations.
                    """
            )
        }

        return String(
            localized: "captures.summary.other",
            defaultValue: "\(DisplayFormat.count(UInt64(max(fileCount, 0)))) captures",
            comment: """
                Footer of the capture list for any number of files other than one, zero included. \
                The placeholder is how many files there are, already grouped. It says nothing \
                about size: that is said once, beside the limit it is compared against.
                """
        )
    }

    /// Qué cuerpo le toca a la pantalla. Con ficheros se pinta la lista pase lo que pase: un fallo
    /// posterior es un aviso (`CapturesNotice`), nunca una tarjeta que tape lo que ya se veía.
    public static func content(state: CapturesState, files: [CaptureFileDisplay]) -> CapturesContent {
        if !files.isEmpty { return .list }

        switch state {
        case .idle, .loading:
            return .loading
        case .failed(let error):
            return .placeholder(failure(error))
        case .loaded:
            return .placeholder(noCapturesYet)
        }
    }

    // MARK: - Sitio que queda

    /// El rótulo de la sección que compara el inventario con los topes.
    ///
    /// Nombra **lo que la sección contesta** y no lo que contiene: *Storage* diría de qué habla, que
    /// es lo que el usuario ya sabe por estar en esta pantalla, mientras que la pregunta con la que
    /// se abre es si esto le va a llenar el dispositivo.
    public static var headroomSectionTitle: String {
        String(
            localized: "captures.headroom.section",
            defaultValue: "Room left",
            comment: """
                Heading of the section that compares what the captures occupy with the storage \
                limits set in Settings. It names what the section answers — will this fill my \
                phone? — rather than what it contains.
                """
        )
    }

    /// El estado de los topes, en palabras.
    ///
    /// Las cifras se formatean con `DisplayFormat` —determinista, como en el resto de la pantalla— y
    /// la fecha de caducidad viaja como `Date`: el huso y el formato son del dispositivo del usuario
    /// y eso lo sabe la vista, igual que con la hora de una fila.
    public static func headroom(_ reading: CaptureHeadroom) -> CaptureHeadroomDisplay {
        switch reading {
        case .unbounded(let used):
            return CaptureHeadroomDisplay(
                headline: String(
                    localized: "captures.headroom.unbounded.headline",
                    defaultValue: "No limits set",
                    comment: """
                        Headline of the room summary when neither the size limit nor the expiry is \
                        set: nothing removes a capture unless the user does. It is the one case \
                        where the answer to 'will this fill my phone?' is 'yes, eventually'.
                        """
                ),
                usage: usedText(used),
                detail: String(
                    localized: "captures.headroom.unbounded.detail",
                    defaultValue: """
                        Captures keep growing until you delete them. Set a size limit or an expiry \
                        in Settings to have the oldest go on their own.
                        """,
                    comment: """
                        Sentence of the room summary when neither storage limit is set. It says \
                        what happens and where the two limits live, without repeating either \
                        figure.
                        """
                ),
                fill: nil,
                expiry: nil,
                role: .warning
            )

        case .bounded(let size, let expiry):
            return CaptureHeadroomDisplay(
                headline: headline(for: size),
                usage: usageText(for: size),
                detail: detail(for: size),
                fill: size.fill,
                expiry: expiryDisplay(for: expiry),
                role: role(for: size)
            )
        }
    }

    // MARK: - El tope de tamaño, en palabras

    /// La respuesta corta, que es la cifra por la que se lee la sección.
    ///
    /// Solo `within` puede dar un número —lo que queda libre—; los otros tres tienen que decir otra
    /// cosa, y un `0 B free` en su lugar sería una medida donde lo que hay es un desenlace.
    private static func headline(for size: CaptureSizeStanding) -> String {
        switch size {
        case .within:
            // El sitio que sobra, que es lo que de verdad se pregunta. `free` solo existe en este
            // caso, así que el `?? 0` no es un valor de reserva: es el compilador pidiendo un
            // número donde el tipo ya garantiza que lo hay.
            return String(
                localized: "captures.headroom.within.headline",
                defaultValue: "\(DisplayFormat.bytes(size.free ?? 0)) free",
                comment: """
                    Headline of the room summary while the captures fit inside the size limit. The \
                    placeholder is how much room is left before the oldest start going.
                    """
            )

        case .reached:
            return String(
                localized: "captures.headroom.reached.headline",
                defaultValue: "Limit reached",
                comment: """
                    Headline of the room summary when the captures already fill the size limit, so \
                    the oldest will be deleted to fit. It is not a failure: it is what a limit \
                    does.
                    """
            )

        case .unmeetable:
            return String(
                localized: "captures.headroom.unmeetable.headline",
                defaultValue: "Limit can't be met",
                comment: """
                    Headline of the room summary when the size limit cannot be honoured because \
                    the capture being recorded is already larger than it, and that file is never \
                    deleted.
                    """
            )

        case .unlimited:
            return String(
                localized: "captures.headroom.noSizeLimit.headline",
                defaultValue: "No size limit",
                comment: """
                    Headline of the room summary when captures may grow to any size. An expiry is \
                    still set — with neither limit the summary says so in one sentence instead.
                    """
            )
        }
    }

    /// Las cifras crudas bajo el titular: cuánto se usa y de cuánto, o solo cuánto se usa cuando no
    /// hay tope contra el que medirlo.
    private static func usageText(for size: CaptureSizeStanding) -> String {
        guard let limit = size.limit else { return usedText(size.used) }

        return String(
            localized: "captures.headroom.usage",
            defaultValue: "\(DisplayFormat.bytes(size.used)) of \(DisplayFormat.bytes(limit)) used",
            comment: """
                The two figures under the room summary's headline: how much the captures occupy \
                and the size limit they are measured against, both already formatted. This is the \
                only place the app says how much the captures occupy in total.
                """
        )
    }

    private static func usedText(_ used: UInt64) -> String {
        String(
            localized: "captures.headroom.used",
            defaultValue: "\(DisplayFormat.bytes(used)) used",
            comment: """
                How much the captures occupy, said alone because there is no size limit to measure \
                it against. The placeholder is the already formatted size.
                """
        )
    }

    /// La frase que explica el titular. **No repite ninguna cifra**: dice qué va a pasar.
    private static func detail(for size: CaptureSizeStanding) -> String {
        switch size {
        case .within:
            return String(
                localized: "captures.headroom.within.detail",
                defaultValue: """
                    When captures reach the limit, the oldest go first. Nothing else on the device \
                    is touched.
                    """,
                comment: """
                    Sentence of the room summary while the captures fit. It says what happens at \
                    the limit — the oldest go, and only captures go — and repeats no figure.
                    """
            )

        case .reached:
            return String(
                localized: "captures.headroom.reached.detail",
                defaultValue: "The oldest captures go on the next cleanup.",
                comment: """
                    Sentence of the room summary once the size limit is full. The cleanup is the \
                    one the app runs on its own; naming when it happens would tie this copy to a \
                    mechanism the user has never been shown.
                    """
            )

        case .unmeetable:
            // La misma frase que dice Ajustes al final de una limpieza, leída de su propiedad y no
            // reescrita: es el mismo hecho y la misma salida, y dos claves diciéndolo con distintas
            // palabras es cómo una traducción acaba explicando dos mecanismos donde hay uno.
            return SettingsPresentation.sizeCapUnreachableExplanation

        case .unlimited:
            return String(
                localized: "captures.headroom.noSizeLimit.detail",
                defaultValue: "Captures grow to any size, and go only when they expire.",
                comment: """
                    Sentence of the room summary when there is no size limit. There is always an \
                    expiry in this case, so it names the one thing that does remove captures.
                    """
            )
        }
    }

    /// El papel de color del titular. Solo llevan aviso los dos casos en que el dispositivo puede
    /// acabar lleno: un tope alcanzado es lo que un tope hace, y pintarlo de alarma enseñaría a
    /// ignorar el color.
    private static func role(for size: CaptureSizeStanding) -> StatusRole {
        switch size {
        case .within: .accent
        case .reached: .neutral
        case .unmeetable: .warning
        case .unlimited: .neutral
        }
    }

    // MARK: - La caducidad, en palabras

    private static func expiryDisplay(for expiry: CaptureExpiry) -> CaptureExpiryDisplay {
        switch expiry {
        case .on(let date):
            return .dated(
                label: String(
                    localized: "captures.headroom.expiry.label",
                    defaultValue: "Oldest expires",
                    comment: """
                        Label of the row saying when the oldest capture will be deleted for being \
                        too old. Its value is the date, formatted by the device.
                        """
                ),
                date: date
            )

        case .overdue(let count):
            return .stated(overdueText(count: count))

        case .undated:
            return .stated(
                String(
                    localized: "captures.headroom.expiry.undated",
                    defaultValue: """
                        The oldest capture gets an expiry date once a new capture file closes it.
                        """,
                    comment: """
                        Said when an expiry is set but no capture has a date yet: a capture file \
                        keeps growing until the next one opens, so until then there is no instant \
                        to count its age from. Saying nothing here would read as an intermittent \
                        fault.
                        """
                )
            )

        case .never:
            return .stated(
                String(
                    localized: "captures.headroom.expiry.never",
                    defaultValue: "Captures don't expire — only the size limit removes them.",
                    comment: """
                        Said when the expiry is turned off. There is always a size limit in this \
                        case, so it names the one thing that does remove captures.
                        """
                )
            )
        }
    }

    /// Cuántas han pasado ya el corte. Plural con dos claves hermanas, como el pie de la lista.
    private static func overdueText(count: Int) -> String {
        guard count != 1 else {
            return String(
                localized: "captures.headroom.expiry.overdue.one",
                defaultValue: "1 capture is past its expiry and goes on the next cleanup.",
                comment: """
                    Said when exactly one capture has already passed the expiry and is waiting for \
                    the next cleanup. See the plural form in the sibling key; a language with more \
                    plural forms needs both merged into one key with catalog variations.
                    """
            )
        }

        return String(
            localized: "captures.headroom.expiry.overdue.other",
            defaultValue: """
                \(DisplayFormat.count(UInt64(max(count, 0)))) captures are past their expiry and \
                go on the next cleanup.
                """,
            comment: """
                Said when captures have already passed the expiry and are waiting for the next \
                cleanup, for any number other than one. The placeholder is the count, already \
                grouped.
                """
        )
    }

    /// Los topes no se pudieron leer, así que no hay con qué comparar el inventario.
    ///
    /// Es un aviso y no una tarjeta de fallo por lo mismo que el refresco que falla con la lista ya
    /// pintada: lo que se ha perdido es una parte de la pantalla, no la pantalla. Y se dice en vez de
    /// dejar el hueco: un bloque que aparece unas veces y otras no se lee como una avería.
    public static func retentionUnreadable(_ error: SettingsStoreError) -> CapturesNotice {
        CapturesNotice(
            message: String(
                localized: "captures.headroom.unreadable",
                defaultValue: """
                    Your storage limits couldn't be read, so this can't say how much room is left. \
                    Open Settings to set them again.
                    """,
                comment: """
                    Notice on the captures screen when the saved storage limits cannot be read. \
                    The room summary is hidden rather than filled in with factory limits, which \
                    would state a limit the user may have changed. Settings is where they are set \
                    and where the next write repairs the saved value.
                    """
            ),
            diagnostic: retentionDiagnostic(for: error),
            role: .warning
        )
    }

    /// El detalle técnico del fallo de los topes. **No pasa por el catálogo**, por lo mismo que
    /// `diagnostic(for:)`: es un identificador de App Group o el error de un descodificador, escrito
    /// para quien recibe una captura de pantalla en un informe.
    private static func retentionDiagnostic(for error: SettingsStoreError) -> String {
        switch error {
        case .containerUnavailable(let identifier):
            return "App Group \(identifier) unavailable"
        case .corruptData(let detail):
            return detail
        case .writeFailed(let detail):
            return detail
        }
    }

    // MARK: - Acciones

    /// El menú de la barra, que a la vista es un icono de tres puntos.
    public static var actionsMenuTitle: String {
        String(
            localized: "captures.action.menu",
            defaultValue: "Actions",
            comment: """
                Label of the toolbar menu holding the two actions that are not about one file: \
                closing the open capture and exporting the connection list. It names the menu, \
                not what it does.
                """
        )
    }

    /// La palabra del botón de compartir de una fila, que solo se **dibuja** en los cuerpos de
    /// accesibilidad.
    ///
    /// A tamaños normales el icono se explica solo por dónde está —al final de una fila, en el color
    /// de la marca—; apilado ese sitio deja de existir y lo que queda es un símbolo suelto en el
    /// margen izquierdo, que es justo lo que el design system prohíbe en todo lo demás. Es corta a
    /// propósito y **no** es lo que oye VoiceOver: eso lo dice `shareAccessibilityLabel`, que además
    /// nombra la captura, porque un lector que salta de botón en botón no tiene la fila delante.
    public static var shareActionTitle: String {
        String(
            localized: "captures.action.share",
            defaultValue: "Share",
            comment: """
                Word on a capture row's share button, drawn only at accessibility text sizes, \
                where the button leaves the end of the row and a bare icon would have nothing to \
                explain it. VoiceOver reads the longer sibling label instead, which also names \
                the capture.
                """
        )
    }

    /// Cerrar el fichero abierto y empezar otro. Se nombra por lo que **deja**, no por el verbo
    /// interno ("rotar"), que no significa nada fuera de aquí.
    public static var rotateActionTitle: String {
        String(
            localized: "captures.action.rotate",
            defaultValue: "New capture file",
            comment: """
                Menu item that closes the file being written and starts another, so the closed one \
                can be shared without stopping monitoring. It names the result, never the internal \
                verb ('rotate'), which means nothing to a reader.
                """
        )
    }

    /// Borrar una captura. **Una sola propiedad para los dos sitios que la dicen** —el gesto de
    /// deslizar la fila y el botón que confirma—: son la misma acción, y compartirla estructuralmente
    /// es lo que impide que un idioma mueva una y no la otra.
    public static var deleteActionTitle: String {
        String(
            localized: "captures.action.delete",
            defaultValue: "Delete",
            comment: """
                Destructive action on a capture, shown both as the row's swipe action and as the \
                confirming button of the dialog it opens. One key for both on purpose: they are \
                the same action, and the second one is what actually deletes the file.
                """
        )
    }

    /// La pregunta de la confirmación. Es el título del diálogo; lo que se pierde lo dice el cuerpo
    /// (`deletionPrompt(for:)`), porque no cabe aquí y porque es lo que hay que leer despacio.
    public static var deletionDialogTitle: String {
        String(
            localized: "captures.delete.confirm.title",
            defaultValue: "Delete this capture?",
            comment: """
                Title of the confirmation dialog opened by deleting one capture. It asks about \
                this one file, not about the captures as a whole: Settings has its own, separate \
                dialog for deleting everything.
                """
        )
    }

    /// Lo que hay que decirle al usuario **antes** de borrar. La consecuencia real no es obvia y no
    /// se puede deshacer, así que se nombra entera: se van los bytes, se queda el historial.
    public static func deletionPrompt(for file: CaptureFileDisplay) -> String {
        String(
            localized: "captures.delete.confirm.message",
            defaultValue: """
                \(file.title) holds \(file.sizeText) of raw packets. The connections recorded \
                while it was being written stay in your history — only the packet bytes are \
                deleted, and they can't be brought back.
                """,
            comment: """
                Body of the confirmation dialog for deleting one capture. The placeholders are \
                that capture's name and how much it occupies. Both halves matter: what is lost \
                (the packet bytes, for good) and what is not (the connections, which stay in the \
                history) — a reader who takes 'delete' to mean the history would keep the file \
                out of fear.
                """
        )
    }

    // MARK: - Export del listado de conexiones

    /// Lo que dice el botón. **Nombra el trozo que se exporta**, y no genéricamente "exportar": desde
    /// esta pantalla no hay ningún filtro puesto, así que lo que sale es el historial entero — y un
    /// botón que no lo dijera dejaría al usuario suponiendo que exporta lo que estaba mirando.
    public static var exportActionTitle: String {
        String(
            localized: "captures.action.export",
            defaultValue: "Export all connections (JSON)",
            comment: """
                Menu item that writes the whole connection history to a JSON file. It says 'all' \
                because this screen has no filters: what comes out is everything, not what the \
                user was last looking at on the Timeline. JSON is a format name and stays as is.
                """
        )
    }

    /// El texto que acompaña al botón, donde caben las dos cosas que hay que saber antes de pulsarlo:
    /// que son metadatos y no contenido, y que el `.pcap` es lo otro (los bytes).
    public static var exportActionDescription: String {
        String(
            localized: "captures.export.description",
            defaultValue: """
                A JSON list of every connection in your history: hosts, ports, times and volumes. \
                It never includes packet contents — those live in the .pcap captures.
                """,
            comment: """
                Explanation shown with the connection export, before it is shared. It draws the \
                line this product is built on: what leaves the device here is metadata about \
                connections, never what travelled inside them. '.pcap' is a file extension and \
                stays as is.
                """
        )
    }

    /// El título de la hoja que enseña el export antes de compartirlo. Nombra **lo que hay dentro del
    /// fichero**, que es lo que el usuario está a punto de sacar del dispositivo.
    public static var exportSheetTitle: String {
        String(
            localized: "captures.export.sheet.title",
            defaultValue: "Connection list",
            comment: """
                Title of the sheet shown after the connection export is written and before it is \
                shared. It names what is inside the file — the list of connections — and not the \
                act of exporting.
                """
        )
    }

    /// El botón que abre la hoja del sistema. Es *compartir* y no *guardar*: quien la abre elige entre
    /// Ficheros, Mail o cualquier otra cosa, y el sistema no distingue una de otra.
    public static var exportShareTitle: String {
        String(
            localized: "captures.export.share",
            defaultValue: "Share",
            comment: """
                Button that hands the written export to the system share sheet. It must read as \
                'send this somewhere', not as 'save': from there the file can go anywhere on or \
                off the device, and this is the moment it leaves.
                """
        )
    }

    /// Qué se ha escrito, antes de compartirlo.
    public static func exportPrepared(_ result: FlowExportResult) -> FlowExportSummary {
        FlowExportSummary(
            url: result.url,
            fileName: result.url.lastPathComponent,
            title: exportTitle(connectionCount: result.connectionCount),
            detail: String(
                localized: "captures.export.summary.detail",
                defaultValue: """
                    \(DisplayFormat.bytes(result.byteCount)) · JSON · metadata only, no packet \
                    contents
                    """,
                comment: """
                    Secondary line of the export sheet: how big the file is, what format it is and \
                    what it carries. The placeholder is the formatted size; 'JSON' is a format \
                    name and stays as is. The order and the separators are translatable, the \
                    promise at the end is not optional.
                    """
            ),
            truncationNote: result.truncated
                ? exportTruncationNote(connectionCount: result.connectionCount)
                : nil
        )
    }

    /// Cuántas conexiones lleva el fichero, en palabras. Plural con dos claves hermanas, como el pie
    /// de la lista.
    private static func exportTitle(connectionCount: Int) -> String {
        guard connectionCount != 1 else {
            return String(
                localized: "captures.export.summary.title.one",
                defaultValue: "1 connection ready to share",
                comment: """
                    Headline of the export sheet when the file carries exactly one connection. See \
                    the plural form in the sibling key; a language with more plural forms needs \
                    both merged into one key with catalog variations.
                    """
            )
        }

        return String(
            localized: "captures.export.summary.title.other",
            defaultValue: """
                \(DisplayFormat.count(UInt64(max(connectionCount, 0)))) connections ready to share
                """,
            comment: """
                Headline of the export sheet for any number of connections other than one. The \
                placeholder is how many the file carries, already grouped.
                """
        )
    }

    /// El aviso de que el tope dejó fuera parte del historial. Se dice **antes** de compartir: después
    /// el fichero ya estaría fuera del dispositivo y el usuario lo creería completo.
    private static func exportTruncationNote(connectionCount: Int) -> String {
        guard connectionCount != 1 else {
            return String(
                localized: "captures.export.truncation.one",
                defaultValue: """
                    Your history holds more than this. The export carries the most recent \
                    connection; the older ones aren't in the file.
                    """,
                comment: """
                    Warning on the export sheet when the cap left part of the history out, in the \
                    case of exactly one exported connection. See the plural form in the sibling \
                    key; a language with more plural forms needs both merged into one key with \
                    catalog variations.
                    """
            )
        }

        return String(
            localized: "captures.export.truncation.other",
            defaultValue: """
                Your history holds more than this. The export carries the \
                \(DisplayFormat.count(UInt64(max(connectionCount, 0)))) most recent connections; \
                the older ones aren't in the file.
                """,
            comment: """
                Warning on the export sheet when the cap left part of the history out. The \
                placeholder is how many connections the file carries, already grouped. Which end \
                of the history was kept is the load-bearing part: the file has the recent ones.
                """
        )
    }

    /// Un historial vacío no da un fichero que compartir. Ofrecer la hoja del sistema con un JSON de
    /// cero conexiones sería un gesto que no lleva a ninguna parte: es más corto decirlo aquí.
    public static var nothingToExport: CapturesNotice {
        CapturesNotice(
            message: String(
                localized: "captures.export.notice.nothingToExport",
                defaultValue: """
                    There are no connections in your history yet, so there's nothing to export.
                    """,
                comment: """
                    Notice shown when the export is asked for with an empty history. Nothing is \
                    broken and nothing is offered to retry: it says why no file was written.
                    """
            ),
            role: .neutral
        )
    }

    public static func exportFailed(_ error: FlowExportError) -> CapturesNotice {
        let message: String
        switch error {
        case .historyUnreadable:
            message = String(
                localized: "captures.export.failure.historyUnreadable",
                defaultValue: """
                    Couldn't read your history, so the connection list wasn't written.
                    """,
                comment: """
                    Notice when the export failed while reading the history. It says nothing was \
                    written, which is what tells it apart from the sibling key about failing to \
                    write: there, the reading had worked.
                    """
            )
        case .writeFailed:
            message = String(
                localized: "captures.export.failure.writeFailed",
                defaultValue: "Couldn't write the connection list.",
                comment: """
                    Notice when the history was read but the export file couldn't be written. The \
                    system's own message travels apart, as a diagnostic.
                    """
            )
        }
        return CapturesNotice(
            message: message,
            diagnostic: diagnostic(for: error),
            role: .warning
        )
    }

    public static func diagnostic(for error: FlowExportError) -> String {
        switch error {
        case .historyUnreadable(let historyError):
            return String(describing: historyError)
        case .writeFailed(let detail):
            return detail
        }
    }

    // MARK: - Avisos

    public static var rotated: CapturesNotice {
        CapturesNotice(
            message: String(
                localized: "captures.notice.rotated",
                defaultValue: """
                    Started a new capture file. The previous one is closed and ready to share.
                    """,
                comment: """
                    Notice confirming that the open file was closed and another one started. Both \
                    halves are said because closing is only the means: what the user asked for is \
                    a file they can share, and that is the one that just closed.
                    """
            ),
            role: .accent
        )
    }

    /// Rotar con el túnel parado no es una avería: no hay nadie escribiendo a quien pedirle nada.
    public static var rotateUnavailable: CapturesNotice {
        CapturesNotice(
            message: String(
                localized: "captures.notice.rotateUnavailable",
                defaultValue: "Monitoring isn't running, so there's no capture to close.",
                comment: """
                    Notice when closing the open capture is asked for while the tunnel is stopped. \
                    Nothing failed: there is simply no file being written, so it must not read as \
                    a fault.
                    """
            ),
            role: .neutral
        )
    }

    public static func rotateFailed(_ detail: String) -> CapturesNotice {
        CapturesNotice(
            message: String(
                localized: "captures.notice.rotateFailed",
                defaultValue: "Couldn't start a new capture file.",
                comment: """
                    Notice when the extension was asked to close the open capture and it did not. \
                    The system's own message travels apart, as a diagnostic: what the user reads \
                    is never a system string.
                    """
            ),
            diagnostic: detail,
            role: .warning
        )
    }

    public static func deletionFailed(_ detail: String) -> CapturesNotice {
        CapturesNotice(
            message: String(
                localized: "captures.notice.deletionFailed",
                defaultValue: "Couldn't delete that capture.",
                comment: """
                    Notice when deleting a capture failed and the file is still there. The \
                    system's own message travels apart, as a diagnostic.
                    """
            ),
            diagnostic: detail,
            role: .warning
        )
    }

    /// El fichero abierto no se toca. La copia dice la salida en vez de limitarse a negarse.
    public static var cannotDeleteRecording: CapturesNotice {
        CapturesNotice(
            message: String(
                localized: "captures.notice.cannotDeleteRecording",
                defaultValue: """
                    This capture is still being written. Start a new one first, then delete it.
                    """,
                comment: """
                    Notice when deleting the file the extension is writing is refused. It names \
                    the way out rather than only refusing: starting a new file closes this one, \
                    and then it can be deleted.
                    """
            ),
            role: .neutral
        )
    }

    /// El refresco que falla con la lista ya pintada. La lista se queda: puede estar desfasada, pero
    /// desfasada dice más que vacía.
    public static func refreshFailed(_ error: CaptureLibraryError) -> CapturesNotice {
        CapturesNotice(
            message: String(
                localized: "captures.notice.refreshFailed",
                defaultValue: """
                    Couldn't check the capture folder, so this list may be out of date.
                    """,
                comment: """
                    Notice when re-reading the folder failed while a list was already drawn. The \
                    list stays on screen, so this says what is uncertain about it — it may be \
                    stale — instead of claiming anything is lost.
                    """
            ),
            diagnostic: diagnostic(for: error),
            role: .warning
        )
    }

    // MARK: - Copia

    /// El vacío que **enseña**: no hay capturas y tampoco hay nada roto.
    private static var noCapturesYet: CapturesPlaceholder {
        CapturesPlaceholder(
            title: String(
                localized: "captures.empty.title",
                defaultValue: "No captures yet",
                comment: """
                    Title of the card shown when the capture folder is empty and nothing is wrong. \
                    'Yet' is load-bearing: files appear on their own once monitoring runs, so this \
                    must not read as something the user failed to do.
                    """
            ),
            message: String(
                localized: "captures.empty.message",
                defaultValue: """
                    While monitoring is on, the raw packets are written here as standard .pcap \
                    files — the ones Wireshark and tcpdump read. They never leave the device \
                    unless you share them.
                    """,
                comment: """
                    Body of that card: what will appear here and when. '.pcap', 'Wireshark' and \
                    'tcpdump' are a file format and two tool names and stay as is. The last \
                    sentence is a promise about where the files live and must not be softened.
                    """
            ),
            systemImage: "externaldrive",
            role: .neutral
        )
    }

    /// La tarjeta de fallo. Como todas las de la app, ofrece salida.
    private static func failure(_ error: CaptureLibraryError) -> CapturesPlaceholder {
        let title: String
        let message: String

        switch error {
        case .containerUnavailable:
            title = String(
                localized: "captures.failure.containerUnavailable.title",
                defaultValue: "Couldn't reach the capture folder",
                comment: """
                    Title of the failure card when the shared folder the captures live in could \
                    not be opened at all, so nothing can be listed.
                    """
            )
            message = String(
                localized: "captures.failure.containerUnavailable.message",
                defaultValue: """
                    The shared folder where captures are written couldn't be opened, so there's \
                    nothing to list. Monitoring and your history aren't affected.
                    """,
                comment: """
                    Body of that card. The second sentence is the point: this failure is about one \
                    folder, and the reader must not conclude that the traffic being recorded or \
                    the connections already saved are gone too.
                    """
            )

        case .deletionFailed:
            title = String(
                localized: "captures.failure.deletionFailed.title",
                defaultValue: "Couldn't delete that capture",
                comment: """
                    Title of the failure card when a deletion failed and it is the only thing on \
                    screen. Its sibling notice says the same thing over a drawn list.
                    """
            )
            message = String(
                localized: "captures.failure.deletionFailed.message",
                defaultValue: "The file is still there. Try again.",
                comment: """
                    Body of that card: nothing changed, and the card's own button repeats the \
                    reading. 'Try again' here is a sentence, not the button — the button has its \
                    own key.
                    """
            )

        case .notFound:
            title = String(
                localized: "captures.failure.notFound.title",
                defaultValue: "That capture is gone",
                comment: """
                    Title of the failure card when the file asked for is no longer in the folder. \
                    It states a fact about the file, not a fault of the app.
                    """
            )
            message = String(
                localized: "captures.failure.notFound.message",
                defaultValue: "It was deleted while this screen was open.",
                comment: """
                    Body of that card: why the file is missing. Deleting captures is something the \
                    user does from this very screen, so the most likely answer is said plainly.
                    """
            )

        // Solo lo puede ver quien pide **un registro** de un fichero, que es la pantalla de un
        // paquete y no esta. Aquí se cuenta como un fichero que no se deja leer, que es lo único
        // que significaría para el listado.
        case .recordUnreadable:
            title = String(
                localized: "captures.failure.recordUnreadable.title",
                defaultValue: "Couldn't read that capture",
                comment: """
                    Title of the failure card when part of a capture file cannot be read. The \
                    file exists; what failed is reading a piece of it.
                    """
            )
            message = String(
                localized: "captures.failure.recordUnreadable.message",
                defaultValue: """
                    The file is there, but part of it can't be read. The rest of the list is fine.
                    """,
                comment: """
                    Body of that card. The second sentence bounds the damage to one file: the \
                    other captures are unaffected, and a reader must not take this for the folder \
                    being lost.
                    """
            )
        }

        return CapturesPlaceholder(
            title: title,
            message: message,
            systemImage: "exclamationmark.triangle",
            role: .warning,
            // Clave propia, como en las cuatro pantallas ya migradas que también reintentan: el listón
            // de `CommonCopy` es significar lo mismo en todos los sitios, y aquí se vuelve a leer un
            // directorio mientras que en la Dashboard se reintenta encender el túnel. Ahora son cinco
            // pantallas con esta frase y esa es la vez de decidir si son la misma: se hace con las
            // cinco delante, cuando migre Ajustes.
            actionTitle: String(
                localized: "captures.failure.retry",
                defaultValue: "Try again",
                comment: """
                    Button on the failure card of the captures screen that reads the folder again. \
                    It repeats one directory listing; it does not touch the files or the tunnel.
                    """
            ),
            action: .retry,
            diagnostic: diagnostic(for: error)
        )
    }

    /// El detalle técnico, aparte de la copia: como en `MonitoringPresentation`, lo que el usuario lee
    /// nunca es un mensaje de sistema, pero tragárselo lo dejaría sin nada que contar si pide ayuda.
    ///
    /// **No pasa por el catálogo y no es un descuido**: es un identificador de App Group y un número
    /// de secuencia con las palabras justas para colocarlos, escrito para quien recibe una captura de
    /// pantalla en un informe. Traducirlo solo crearía una unidad que se puede equivocar sin que
    /// nadie lo note.
    public static func diagnostic(for error: CaptureLibraryError) -> String {
        switch error {
        case .containerUnavailable(let identifier):
            return "App Group \(identifier) unavailable"
        case .deletionFailed(let detail):
            return detail
        case .notFound(let sequence):
            return "capture \(sequence) not found"
        case .recordUnreadable(let detail):
            return detail
        }
    }
}
