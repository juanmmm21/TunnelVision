import Foundation
import Shared

/// Qué enseña la pantalla de Ajustes (`docs/ux/screens.md`) y qué le dice al usuario antes y después
/// de cada acción.
///
/// Las decisiones de esta pantalla no son de dibujo. Son **qué se pierde al aplicar un tope** (borrar
/// es irreversible y hay que decirlo antes), **qué se puede afirmar de un ajuste recién guardado**
/// (uno que la sesión viva no aplica no se puede enseñar como aplicado) y **por qué la inspección TLS
/// todavía no se puede encender**. Las tres viven aquí, en valores puros, para poder afirmarse sin
/// pintar nada — igual que `CapturesPresentation` y `MonitoringPresentation`.
///
/// Toda la copia sale por el catálogo (`String(localized:defaultValue:comment:)`,
/// `docs/development/02-coding-standards.md`), incluida la que hasta ahora escribía `SettingsView`:
/// los rótulos de las secciones, los de los dos interruptores, los de los tres selectores y los dos
/// diálogos de confirmación. Una vista no decide copia, y menos la de la pantalla que gobierna lo que
/// se borra.

/// Qué está haciendo la pantalla ahora mismo. Existe para que un botón que borra ficheros pueda
/// decirlo en vez de quedarse mudo mientras el disco trabaja.
public enum SettingsActivity: Sendable, Equatable {
    case idle
    /// La primera lectura: ajustes, disponibilidad de la CA y uso de disco.
    case loading
    case saving
    case enforcing
    case clearing
}

/// Si la inspección TLS se puede **encender** ahora mismo.
///
/// El ajuste guardado no basta para afirmarlo: mirar dentro del tráfico cifrado exige que el usuario
/// haya generado la CA local y la haya instalado y confiado en los Ajustes de iOS (ADR 0003), y eso
/// es un hecho del dispositivo, no una preferencia. Por eso la pantalla lo consulta aparte de leer
/// los ajustes.
public enum TLSInspectionAvailability: Sendable, Equatable {
    case ready
    /// No hay CA instalada y confiada, o no hay todavía forma de llegar a ella: el flujo guiado de
    /// instalación es M10 (`docs/ux/onboarding-and-consent.md`).
    case certificateNotReady
}

/// Qué disparó una limpieza. Cambia **solo** lo que se le cuenta al usuario: una limpieza automática
/// que no encontró nada que borrar no tiene por qué decir nada, mientras que una que el usuario ha
/// pedido con el dedo tiene que contestarle aunque la respuesta sea "no había nada".
public enum RetentionTrigger: Sendable, Equatable {
    case automatic
    case manual
}

/// Lo que se le cuenta al usuario tras una acción. Mismo tipo y mismo papel que `CapturesNotice`: es
/// un aviso descartable y nunca una tarjeta que tape la pantalla, porque lo que ha pasado (o fallado)
/// es una acción, no lo que el usuario está mirando.
public struct SettingsNotice: Sendable, Equatable {
    public let message: String
    public let diagnostic: String?
    public let role: StatusRole

    public init(message: String, diagnostic: String? = nil, role: StatusRole) {
        self.message = message
        self.diagnostic = diagnostic
        self.role = role
    }
}

/// Lo que ocupa una de las cosas que la app guarda, y —cuando la unidad significa algo— de cuántas
/// se compone.
///
/// Las dos cifras van **separadas** y no unidas en una frase porque no se leen por lo mismo. El
/// tamaño se lee **comparando** (cuál de las tres se está comiendo el disco, y cuánto suman), así que
/// tiene que caer en una columna; la cuenta **sitúa** ese tamaño y se lee sola. Es la misma decisión
/// que sacó el `·` de una fila de Captures el 2026-08-20, y llega aquí porque el código que lo escribe
/// citaba justamente aquella fila como su razón para escribirlo.
///
/// El separador desaparece del catálogo con ellas: lo que separa las dos cifras es el papel
/// tipográfico y el color, y un `·` compuesto en la vista sería copia en el único sitio al que un
/// traductor no llega.
public struct StorageFigure: Sendable, Equatable {

    /// De cuántas cosas se compone lo que ocupa, ya formateado y con su plural resuelto, o `nil`
    /// cuando contarlas no ayudaría: lo descifrado se mide en trozos de conversación —contarlos
    /// obligaría a entender el troceo para poder ignorar el número— y el total suma ficheros,
    /// conexiones y trozos, que no son la misma cosa y no tienen una cuenta común.
    public let count: String?

    /// Lo que ocupa. Es la cifra por la que se lee la tabla.
    public let size: String

    public init(count: String? = nil, size: String) {
        self.count = count
        self.size = size
    }
}

/// El bloque de almacenamiento, ya formateado.
///
/// Las dos mitades van separadas porque se recortan con políticas distintas y el usuario tiene que
/// poder ver por qué: las capturas se borran fichero a fichero y por tamaño o antigüedad, el
/// historial solo por antigüedad (`RetentionSize` explica por qué un tope en bytes sobre SQLite no se
/// podría cumplir).
public struct StorageDisplay: Sendable, Equatable {
    public let captures: StorageFigure
    public let history: StorageFigure

    /// El contenido descifrado, o `nil` si no hay ninguno. Es la única fila que puede faltar: las
    /// otras dos existen desde la primera sesión, y esta solo aparece cuando el usuario ha pedido dos
    /// veces que exista (inspeccionar y guardar), así que enseñarla siempre a cero contaría de una
    /// función que puede no haber encendido nunca.
    public let plaintext: StorageFigure?

    /// La suma de las filas de arriba, y **nunca** una cuenta: sumar ficheros con conexiones y con
    /// trozos de conversación daría un número que no cuenta nada.
    public let total: StorageFigure

    public init(
        captures: StorageFigure,
        history: StorageFigure,
        plaintext: StorageFigure? = nil,
        total: StorageFigure
    ) {
        self.captures = captures
        self.history = history
        self.plaintext = plaintext
        self.total = total
    }
}

public enum SettingsPresentation {

    // MARK: - Chrome de la pantalla

    /// El rótulo de la pestaña. Clave propia y separada del título por lo mismo que en la Timeline y en
    /// Captures: la barra reparte su ancho entre cuatro, así que un idioma puede necesitar aquí una
    /// forma más corta de la misma palabra.
    public static var tabTitle: String {
        String(
            localized: "settings.tab",
            defaultValue: "Settings",
            comment: """
                Tab bar label of the fourth screen. Same word as its title, separate key: the tab \
                bar shares its width with three other items, so it may need a shorter form.
                """
        )
    }

    public static var screenTitle: String {
        String(
            localized: "settings.screen.title",
            defaultValue: "Settings",
            comment: """
                Title of the screen holding what the app records, what it occupies on the device \
                and the two ways to cut it back. It is also the word iOS uses for its own Settings \
                app, which this screen sends the user to more than once: they should read alike.
                """
        )
    }

    // MARK: - Tráfico seguro

    public static var secureTrafficSectionTitle: String {
        String(
            localized: "settings.secureTraffic.section",
            defaultValue: "Secure traffic",
            comment: """
                Heading of the section holding the HTTPS inspection switch and the way into the \
                certificate setup. 'Secure' is what the user's own apps call it; this section is \
                about looking inside their own encrypted traffic, never anyone else's.
                """
        )
    }

    /// El interruptor que gobierna la inspección. Clave propia y **no** la del titular de la etapa 0
    /// del flujo guiado, que dice hoy estas mismas palabras: una fila de una lista y el titular de una
    /// pantalla pueden necesitar largos distintos — el mismo listón que dejó fuera de `CommonCopy` el
    /// título del flujo de la CA.
    public static var tlsInspectionToggleTitle: String {
        String(
            localized: "settings.secureTraffic.toggle",
            defaultValue: "Look inside secure traffic",
            comment: """
                Label of the switch that turns HTTPS inspection on. Same words today as the \
                headline of the certificate flow's first stage, deliberately a separate key: this \
                one is a row in a list and can need a shorter form. It must read as looking inside \
                traffic that is the user's own — nothing here reaches another person's.
                """
        )
    }

    // MARK: - Contenido descifrado

    /// El rótulo de la sección donde vive el segundo interruptor.
    ///
    /// Nombra **lo que se guarda** y no la acción de guardarlo, que es lo que la separa de la sección
    /// de arriba: allí se decide mirar dentro del tráfico cifrado, aquí qué pasa con lo que se vio.
    public static var decryptedContentSectionTitle: String {
        String(
            localized: "settings.plaintext.section",
            defaultValue: "Decrypted content",
            comment: """
                Heading of the section governing what happens to the contents of inspected \
                connections: whether they are written to the device, for how long, and the way to \
                delete just them. It names what is kept, not the act of keeping it, which is what \
                tells it apart from the section above.
                """
        )
    }

    /// El segundo interruptor del ADR 0007. **Dice *save*, no *record* ni *inspect***: el primero es
    /// el verbo del interruptor de arriba y el segundo es el de las capturas, y la pantalla entera
    /// depende de que estas tres cosas no se confundan.
    public static var plaintextPersistenceToggleTitle: String {
        String(
            localized: "settings.plaintext.toggle",
            defaultValue: "Save decrypted content",
            comment: """
                Label of the switch that writes the contents of inspected connections to the device. \
                'Save' is deliberate and must stay distinct from the verb of the inspection switch \
                above ('look inside') and from the capture switch ('record'): the whole screen \
                depends on those three not blurring together.
                """
        )
    }

    /// La frase que hace legible la diferencia entre *inspeccionar* y *guardar lo inspeccionado*.
    ///
    /// Es la copia que el ADR 0007 nombra como el precio de tener dos interruptores: sin ella el
    /// segundo es un misterio, y esconder la consecuencia más grande de la función detrás de la
    /// decisión más suave es justo lo que la decisión no quiere. Depende de la de arriba porque con
    /// la inspección apagada no hay nada que guardar, y ofrecerlo entonces sería ofrecer un
    /// interruptor que no hace nada.
    public static func plaintextFooter(isInspectionEnabled: Bool) -> String {
        guard isInspectionEnabled else {
            return String(
                localized: "settings.plaintext.footer.inspectionOff",
                defaultValue: """
                    Looking inside secure traffic is off, so nothing is being decrypted and there's \
                    nothing to save. Turn it on above and this decides whether what it decrypts is \
                    written to this device or only shown while it happens.
                    """,
                comment: """
                    Footer of the decrypted-content section while inspection is off. It says why the \
                    switch does nothing yet and, in the same breath, what it will decide — the \
                    difference between seeing traffic as it happens and keeping a copy of it.
                    """
            )
        }

        return String(
            localized: "settings.plaintext.footer.inspectionOn",
            defaultValue: """
                Inspection shows what your own apps send while it happens. This keeps a copy on the \
                device so you can read a connection after it's over — the requests, the replies, and \
                whatever was inside them. Off unless you ask for it.
                """,
            comment: """
                Footer of the decrypted-content section while inspection is on: the difference \
                between inspecting and keeping what was inspected. It must not soften what is kept — \
                the contents of the user's own traffic — and the last sentence says the default is \
                off, which is the decision of ADR 0007.
                """
        )
    }

    public static var plaintextAgePickerTitle: String {
        String(
            localized: "settings.plaintext.age.picker",
            defaultValue: "Keep for",
            comment: """
                Label of the picker choosing how long decrypted content is kept. Same words today as \
                the retention picker of the limits section, deliberately a separate key: they govern \
                different things and only one of them can be turned off.
                """
        )
    }

    public static func label(for age: PlaintextRetentionAge) -> String {
        switch age {
        case .oneHour:
            return String(
                localized: "settings.plaintext.age.oneHour",
                defaultValue: "1 hour",
                comment: """
                    Option of the decrypted-content retention picker: keep it for one hour. The \
                    number never varies, so this is one key and not a plural pair. It is the \
                    shortest option and has no sibling in the captures' picker.
                    """
            )
        case .oneDay:
            return String(
                localized: "settings.plaintext.age.oneDay",
                defaultValue: "1 day",
                comment: """
                    Option of the decrypted-content retention picker: keep it for one day, which is \
                    the default. Same words as the captures' one-day option and a separate key: the \
                    two pickers are different settings and a language may need to word them apart.
                    """
            )
        case .oneWeek:
            return String(
                localized: "settings.plaintext.age.oneWeek",
                defaultValue: "1 week",
                comment: """
                    Option of the decrypted-content retention picker: keep it for one week, its \
                    longest. Same words as the captures' one-week option and a separate key, for the \
                    same reason as its siblings.
                    """
            )
        }
    }

    /// Las dos cosas que el usuario **no** decide sobre lo descifrado, dichas donde elige lo que sí:
    /// que no hay un "para siempre" y que hay un techo de disco por encima de su plazo.
    ///
    /// La cifra va escrita y no interpolada desde la constante, igual que las del selector de tamaño
    /// de las capturas: `DisplayFormat` cuenta en unidades decimales (la convención de red) y el techo
    /// está en binarias, así que interpolarlo diría *537 MB* — un número que nadie eligió. Lo que
    /// impide que se desvíen es un test que ata las dos cosas.
    public static var plaintextRetentionFooter: String {
        String(
            localized: "settings.plaintext.age.footer",
            defaultValue: """
                Decrypted content is always deleted in the end — there is no "keep forever" here. It \
                also never takes more than 512 MB on this device, whichever option you pick, and the \
                oldest goes first when it has to.
                """,
            comment: """
                Footer of the decrypted-content retention picker: the two things the user does not \
                get to decide. The absence of an unlimited option is a decision (ADR 0007) and is \
                said outright rather than left to be noticed. The figure is the fixed disk ceiling — \
                a figure with its unit, the same in every language — and a test ties it to the \
                constant the sweep enforces.
                """
        )
    }

    /// Encender el segundo interruptor con la inspección apagada. No es una avería: es que lo que
    /// gobierna todavía no existe.
    public static var plaintextCannotBeEnabled: SettingsNotice {
        SettingsNotice(
            message: String(
                localized: "settings.plaintext.notice.cannotEnable",
                defaultValue: """
                    There's nothing to save until inspection is on — turn on looking inside secure \
                    traffic first.
                    """,
                comment: """
                    Notice shown when saving decrypted content is switched on while inspection is \
                    off. Nothing is broken: the switch governs the output of a feature that is not \
                    running, so it names the switch that has to come first.
                    """
            ),
            role: .neutral
        )
    }

    // MARK: - Etiquetas de las opciones

    public static func label(for detail: CaptureDetail) -> String {
        switch detail {
        case .metadataOnly:
            return String(
                localized: "settings.capture.detail.metadataOnly",
                defaultValue: "Headers only",
                comment: """
                    Option that records only the start of every packet. 'Headers' is what the part \
                    of a packet that carries hosts, ports and flags is called; the option names \
                    what is kept, never the pcap term for the cut ('snaplen').
                    """
            )
        case .fullPayload:
            return String(
                localized: "settings.capture.detail.fullPayload",
                defaultValue: "Full packets",
                comment: """
                    Option that records every byte of every packet. It is the sibling of the \
                    headers-only option and the two must stay clearly different words: they differ \
                    in how much space a capture takes and in whether contents are saved.
                    """
            )
        }
    }

    /// Qué cuesta y qué da cada nivel de detalle. Se dice en espacio y no en jerga: el `snaplen` es
    /// un número del formato `.pcap` y no significa nada para quien abre esta pantalla.
    public static func explanation(for detail: CaptureDetail) -> String {
        switch detail {
        case .metadataOnly:
            // La cifra sale del propio ajuste y es una **cantidad**, así que se agrupa con
            // `DisplayFormat.count` en vez de interpolar el entero: un `String(localized:)` con un
            // entero dentro lo formatearía con el locale del proceso.
            return String(
                localized: "settings.capture.detail.explanation.metadataOnly",
                defaultValue: """
                    Saves only the first \(DisplayFormat.count(UInt64(detail.snaplen))) bytes of \
                    each packet — enough to see the connection, its ports and its flags, but not \
                    what was sent. Uses far less space.
                    """,
                comment: """
                    Explanation under the capture detail picker for the headers-only option. The \
                    placeholder is how many bytes of each packet are kept, an amount and therefore \
                    grouped. It says what is gained and what is lost in space and in contents, and \
                    never in the pcap term for the cut ('snaplen'), which means nothing here.
                    """
            )
        case .fullPayload:
            return String(
                localized: "settings.capture.detail.explanation.fullPayload",
                defaultValue: """
                    Saves every byte of each packet, so an exported capture can be replayed in \
                    full. Uses much more space, and your history and timeline look exactly the \
                    same either way.
                    """,
                comment: """
                    Explanation under the capture detail picker for the full-packets option. The \
                    last clause is the point: this setting changes only the capture files, so a \
                    reader must not expect the other two screens to show more because of it.
                    """
            )
        }
    }

    public static func label(for age: RetentionAge) -> String {
        switch age {
        case .oneDay:
            return String(
                localized: "settings.limits.age.oneDay",
                defaultValue: "1 day",
                comment: """
                    Option of the retention age picker: keep captures and connections for one day. \
                    The number never varies, so this is one key and not a plural pair.
                    """
            )
        case .oneWeek:
            return String(
                localized: "settings.limits.age.oneWeek",
                defaultValue: "1 week",
                comment: """
                    Option of the retention age picker: keep captures and connections for one \
                    week. The number never varies, so this is one key and not a plural pair.
                    """
            )
        case .oneMonth:
            return String(
                localized: "settings.limits.age.oneMonth",
                defaultValue: "1 month",
                comment: """
                    Option of the retention age picker: keep captures and connections for one \
                    month. The number never varies, so this is one key and not a plural pair.
                    """
            )
        case .unlimited:
            return String(
                localized: "settings.limits.age.unlimited",
                defaultValue: "No limit",
                comment: """
                    Option of the retention age picker: nothing is ever deleted for being old. \
                    Same words as the sibling option of the size picker and deliberately a \
                    separate key: this one says 'never deleted for its age', that one says 'the \
                    capture folder may grow without bound'.
                    """
            )
        }
    }

    /// El tope de tamaño, en palabras.
    ///
    /// Las tres cifras **no son copia**: un número con su unidad se dice igual en todos los idiomas, y
    /// meterlo en el catálogo solo crearía una unidad de traducción que alguien puede equivocar — la
    /// misma regla que deja fuera los nombres de protocolo (`docs/development/02-coding-standards.md`).
    /// Lo único que es copia aquí es *No limit*, que sí es una palabra nuestra.
    public static func label(for size: RetentionSize) -> String {
        switch size {
        case .megabytes256: return "256 MB"
        case .gigabyte1: return "1 GB"
        case .gigabytes4: return "4 GB"
        case .unlimited:
            return String(
                localized: "settings.limits.size.unlimited",
                defaultValue: "No limit",
                comment: """
                    Option of the capture size picker: the capture folder may grow without bound. \
                    Same words as the sibling option of the age picker and deliberately a separate \
                    key: that one is about how old a file may get, this one about how much room \
                    the files may take.
                    """
            )
        }
    }

    // MARK: - Rótulos de las secciones y de los controles

    public static var captureSectionTitle: String {
        String(
            localized: "settings.capture.section",
            defaultValue: "Capture",
            comment: """
                Heading of the section that governs the .pcap files: whether they are written at \
                all and how much of each packet goes into them. Singular: it names the activity, \
                not the files, which the storage section counts as 'Captures'.
                """
        )
    }

    public static var captureToggleTitle: String {
        String(
            localized: "settings.capture.toggle",
            defaultValue: "Record packet files",
            comment: """
                Label of the switch that turns the writing of .pcap files on and off. It names the \
                files rather than 'capture' so that turning it off cannot be read as turning \
                monitoring off — the footer says so outright.
                """
        )
    }

    public static var captureDetailPickerTitle: String {
        String(
            localized: "settings.capture.detail.picker",
            defaultValue: "Detail",
            comment: """
                Label of the picker choosing how much of every packet is written to the capture \
                files. Short by necessity: it shares its row with the chosen option.
                """
        )
    }

    public static var storageSectionTitle: String {
        String(
            localized: "settings.storage.section",
            defaultValue: "Storage",
            comment: """
                Heading of the section that says how much room the app is taking on the device. It \
                only reports; the section below it is where anything gets cut back.
                """
        )
    }

    /// El rótulo de la fila que cuenta los ficheros. **Clave propia** y no la de la pestaña ni la del
    /// título de la pantalla de capturas, que dicen hoy esta misma palabra: aquí nombra una cantidad de
    /// ficheros dentro de una fila y allí nombran una pantalla, y son sitios distintos.
    public static var storageCapturesRowTitle: String {
        String(
            localized: "settings.storage.captures",
            defaultValue: "Captures",
            comment: """
                Label of the storage row counting the capture files and their size. Same word as \
                the captures screen and its tab, deliberately a separate key: here it names an \
                amount of files inside a row, there it names a screen.
                """
        )
    }

    public static var storageHistoryRowTitle: String {
        String(
            localized: "settings.storage.history",
            defaultValue: "History",
            comment: """
                Label of the storage row counting the saved connections and the size of the \
                database holding them. 'History' is what the app calls the connections it has \
                recorded, on the Timeline and here alike.
                """
        )
    }

    /// El rótulo de la fila que cuenta lo descifrado. Clave propia y no la del título de su sección,
    /// por lo mismo que en las capturas: aquí nombra una cantidad dentro de una fila y allí encabeza
    /// un bloque de controles.
    public static var storagePlaintextRowTitle: String {
        String(
            localized: "settings.storage.plaintext",
            defaultValue: "Decrypted content",
            comment: """
                Label of the storage row measuring the contents of inspected connections. Same words \
                as the heading of the section that governs them, deliberately a separate key: here \
                it names an amount inside a row, there it heads a block of controls.
                """
        )
    }

    public static var storageTotalRowTitle: String {
        String(
            localized: "settings.storage.total",
            defaultValue: "Total",
            comment: """
                Label of the storage row adding the two rows above it. It is the figure that \
                answers 'how much room is this app taking', so it must not read as a third, \
                separate thing.
                """
        )
    }

    public static var limitsSectionTitle: String {
        String(
            localized: "settings.limits.section",
            defaultValue: "Limits",
            comment: """
                Heading of the section holding the two retention caps. Everything under it deletes \
                things, which is what tells it apart from the storage section above, which only \
                reports.
                """
        )
    }

    public static var retentionAgePickerTitle: String {
        String(
            localized: "settings.limits.age.picker",
            defaultValue: "Keep for",
            comment: """
                Label of the picker choosing how long captures and connections are kept. It reads \
                into its own value ('Keep for — 1 week'), so a language that cannot do that needs \
                a form that stands on its own.
                """
        )
    }

    public static var retentionSizePickerTitle: String {
        String(
            localized: "settings.limits.size.picker",
            defaultValue: "Capture size limit",
            comment: """
                Label of the picker choosing how much room the capture files may take in total. It \
                names the captures because it governs only those: the history is bounded by age, \
                as the footer explains.
                """
        )
    }

    public static var introSectionTitle: String {
        String(
            localized: "settings.intro.section",
            defaultValue: "Introduction",
            comment: """
                Heading of the section that brings back the three first-run cards. It names the \
                thing being brought back, which the cards themselves call the introduction.
                """
        )
    }

    public static var introReplayTitle: String {
        String(
            localized: "settings.intro.replay",
            defaultValue: "Show the introduction again",
            comment: """
                Button that plays the three first-run cards once more. 'Again' is load-bearing: it \
                is what makes skipping them safe, because nothing is lost for good.
                """
        )
    }

    /// Por qué hay una pantalla de números al final de los ajustes. Dice a qué pregunta responde, que
    /// es la única forma de que alguien la abra el día que la necesita.
    public static var diagnosticsFooter: String {
        String(
            localized: "settings.diagnostics.footer",
            defaultValue: "What the tunnel counted since you turned monitoring on, and whether looking inside secure traffic is actually working.",
            comment: """
                Footer under the row that opens the diagnostics screen. It names the two questions \
                that screen answers, in the same words the switches above use.
                """
        )
    }

    public static var privacySectionTitle: String {
        String(
            localized: "settings.privacy.section",
            defaultValue: "Privacy",
            comment: """
                Heading of the last section, which holds the promise about where everything the \
                app records stays. It is a statement of fact and offers no controls.
                """
        )
    }

    // MARK: - Copia fija

    /// Lo que hacen los dos topes, dicho **antes** de que borren nada: la pantalla los aplica sola al
    /// abrirse y al cambiarlos, así que quien los toca tiene que saber lo que va a pasar.
    public static var retentionFooter: String {
        String(
            localized: "settings.limits.footer",
            defaultValue: """
                Captures and connections older than this are deleted automatically, and captures \
                over the size limit are deleted oldest first. The capture being recorded right now \
                is never deleted.
                """,
            comment: """
                Footer of the limits section: what the two caps do, said before they delete \
                anything, because the screen applies them on its own when it opens and whenever \
                they change. The last sentence is a guarantee that holds everywhere in the app.
                """
        )
    }

    /// El tope de tamaño no gobierna la base de datos, y decirlo evita que se lea como un descuido.
    ///
    /// **Dice la consecuencia y no el mecanismo**, que es lo que la acorta a la mitad: por qué el
    /// espacio de una fila borrada no vuelve lo cuenta `historyDoesNotShrinkNote`, pegado a la cifra
    /// del historial que es donde se ve. Estaba escrito en los dos sitios, a 400 pt uno del otro, y un
    /// hueco en una pantalla se cierra quitando un dato y no repartiéndolo.
    public static var sizeCapFooter: String {
        String(
            localized: "settings.limits.sizeCap.note",
            defaultValue: """
                The size limit covers your capture files. Your history is bounded by age instead, \
                for the reason given under \(storageSectionTitle).
                """,
            comment: """
                Note under the size picker: why the size cap covers only the capture files. \
                Without it, the cap reads as an oversight. It states the consequence and points at \
                the storage section for the mechanism, which is written there beside the figure it \
                explains; saying it in both places said one fact twice on one screen. The \
                placeholder is that section's own heading, interpolated from its key so this \
                sentence cannot call it something the screen does not.
                """
        )
    }

    /// Por qué el historial no encoge tras una limpieza. Sin esto, borrar 10 000 conexiones y ver el
    /// mismo número en pantalla se lee como que la limpieza no hizo nada.
    public static var historyDoesNotShrinkNote: String {
        String(
            localized: "settings.storage.footer",
            defaultValue: """
                Removing connections doesn't shrink this file straight away: the space is reused \
                for new traffic instead of being handed back to the system.
                """,
            comment: """
                Footer of the storage section: why the history's size does not drop after a \
                cleanup. Without it, deleting ten thousand connections and seeing the same figure \
                reads as the cleanup having done nothing.
                """
        )
    }

    public static var captureFooter: String {
        String(
            localized: "settings.capture.footer",
            defaultValue: """
                Turning this off keeps monitoring and your history working — only the raw packet \
                files stop being written.
                """,
            comment: """
                Footer of the capture section: what turning the switch off does not affect. It \
                exists so that the switch cannot be read as turning the whole app off.
                """
        )
    }

    public static var privacyNote: String {
        String(
            localized: "settings.privacy.note",
            defaultValue: """
                Everything TunnelVision records stays on this device. Nothing is uploaded, and \
                captures only leave the device if you share them yourself.
                """,
            comment: """
                The privacy section's only text: where what the app records lives. It is a promise \
                the product is built on and must not be softened into something conditional. \
                'TunnelVision' is the app's name and stays as is.
                """
        )
    }

    // MARK: - El intro

    /// Que el intro se puede volver a ver. Es lo que hace que saltarlo sea seguro (M10): sin esta
    /// salida, marcarlo como visto al primer toque lo perdería para siempre.
    public static var introFooter: String {
        String(
            localized: "settings.intro.footer",
            defaultValue: """
                The three cards you saw when you first opened TunnelVision. Nothing changes when \
                you read them again.
                """,
            comment: """
                Footer of the introduction section: what the button brings back and that it is \
                safe. The second sentence is what makes skipping the intro reversible — replaying \
                it resets no setting.
                """
        )
    }

    /// Que no se pudo dejar constancia de haberlo visto. Se dice **aquí** y no durante el intro: en
    /// medio de la primera ejecución sería una avería incomprensible sobre algo que el usuario aún no
    /// sabe que existe, y la consecuencia (que vuelva a aparecer) se explica mejor junto al botón que
    /// lo trae de vuelta a propósito.
    public static var introCannotBeRemembered: String {
        String(
            localized: "settings.intro.cannotBeRemembered",
            defaultValue: """
                TunnelVision couldn't save that you've seen the introduction, so it may appear \
                again next time you open the app.
                """,
            comment: """
                Note shown when the app could not record that the intro was seen. It is said here \
                and not during the first run, where it would be an incomprehensible fault about \
                something the user does not yet know exists. It states the consequence, not the \
                cause.
                """
        )
    }

    // MARK: - Inspección TLS

    /// Qué se puede decir hoy del interruptor de inspección. La copia del caso no disponible **no**
    /// se lee como una avería: no mirar dentro del tráfico cifrado es el estado correcto por defecto,
    /// y encenderlo exige un certificado que el usuario instala él mismo (ADR 0003).
    public static func tlsFooter(_ availability: TLSInspectionAvailability) -> String {
        switch availability {
        case .ready:
            return String(
                localized: "settings.secureTraffic.footer.ready",
                defaultValue: """
                    Decrypts your own HTTPS traffic using the certificate you installed. Apps that \
                    pin their certificates are never decrypted — they stay private and are \
                    labelled "Protected by the app".
                    """,
                comment: """
                    Footer of the secure traffic section once inspection can be turned on. 'Your \
                    own' is load-bearing and so is the pinning sentence: apps that pin are never \
                    decrypted (ADR 0003), and that is told as a guarantee, not as a shortcoming. \
                    The quoted words are the badge a connection carries on the Timeline.
                    """
            )
        case .certificateNotReady:
            return String(
                localized: "settings.secureTraffic.footer.certificateNotReady",
                defaultValue: """
                    Looking inside encrypted traffic needs a certificate that you create here and \
                    install yourself in iOS Settings. Until iOS trusts it this stays off and every \
                    connection is recorded as it is — the setup below walks you through it.
                    """,
                comment: """
                    Footer of the secure traffic section while inspection cannot be turned on. It \
                    must not read as a fault: staying out of encrypted traffic is the correct \
                    default, and what is missing is a step the user takes themselves. 'iOS \
                    Settings' is the system's own app and its name comes from the system.
                    """
            )
        }
    }

    /// El rótulo de la fila que abre el flujo guiado (M10).
    ///
    /// Cambia con lo que la pantalla **ya** sabe y no afirma más que eso: `certificateNotReady` no
    /// distingue "no hay certificado" de "lo hay y iOS no lo confía" (iOS no deja saberlo), así que el
    /// rótulo dice *configurar* en los dos casos, que es verdad en ambos. Con la inspección lista, lo
    /// que se abre no es una configuración sino lo que ya está puesto.
    public static func certificateSetupTitle(_ availability: TLSInspectionAvailability) -> String {
        switch availability {
        case .ready:
            return String(
                localized: "settings.secureTraffic.setup.ready",
                defaultValue: "Manage your certificate",
                comment: """
                    Row that opens the certificate flow once inspection is ready. What it opens is \
                    no longer a setup but what is already installed — where the certificate is \
                    remade and where it is removed.
                    """
            )
        case .certificateNotReady:
            return String(
                localized: "settings.secureTraffic.setup.notReady",
                defaultValue: "Set up secure traffic inspection",
                comment: """
                    Row that opens the certificate flow while inspection cannot be turned on. It \
                    says 'set up' in both the never-created and the created-but-not-trusted cases, \
                    which is true of both: iOS does not let the app tell them apart.
                    """
            )
        }
    }

    public static var tlsCannotBeEnabled: SettingsNotice {
        SettingsNotice(
            message: String(
                localized: "settings.secureTraffic.notice.cannotEnable",
                defaultValue: """
                    Inspection needs a certificate you install and trust yourself. Open the setup \
                    below and it will walk you through it.
                    """,
                comment: """
                    Notice shown when the inspection switch is turned on without a trusted \
                    certificate. Nothing is broken: it names the missing step and points at the \
                    row right below that starts it.
                    """
            ),
            role: .neutral
        )
    }

    /// La inspección estaba encendida y se ha apagado sola porque el sistema ya no acepta la CA.
    ///
    /// Se dice **siempre** que ocurre, aunque el usuario no estuviera mirando esta pantalla: apagar
    /// una función que él encendió sin contárselo es peor que no apagarla. Y se dice sin culpar a
    /// nadie — la causa normal es que retiró la confianza desde los Ajustes de iOS, que es un gesto
    /// legítimo y además el que esta app le pide que pueda hacer cuando quiera.
    public static var tlsTurnedOffByTrust: SettingsNotice {
        SettingsNotice(
            message: String(
                localized: "settings.secureTraffic.notice.turnedOffByTrust",
                defaultValue: """
                    Inspection turned itself off: iOS no longer accepts your certificate. Traffic is \
                    flowing normally again. Set the certificate up below to turn it back on.
                    """,
                comment: """
                    Notice shown when inspection was on and the certificate stopped being trusted, so \
                    the app turned inspection off by itself. It must say what happened, that browsing \
                    is fine now — that is the reassuring half — and where to go. Not an error: \
                    withdrawing trust is a legitimate thing the user may have just done.
                    """
            ),
            role: .neutral
        )
    }

    // MARK: - Confirmaciones

    public static var applyCapsButtonTitle: String {
        String(
            localized: "settings.limits.apply.button",
            defaultValue: "Apply limits now",
            comment: """
                Button that applies the two retention caps immediately instead of waiting for the \
                screen to do it on its own. 'Now' is what tells it apart from the caps themselves, \
                which are always in force; the button only opens the confirmation.
                """
        )
    }

    public static var applyCapsDialogTitle: String {
        String(
            localized: "settings.limits.apply.confirm.title",
            defaultValue: "Apply your limits now?",
            comment: """
                Title of the confirmation dialog opened by the apply-limits button. It asks; what \
                will be deleted is spelled out in the body, which is what has to be read slowly.
                """
        )
    }

    /// El botón que **borra**. Clave propia y no la del botón que abre el diálogo: aquel dice *ahora*
    /// porque adelanta una limpieza que ya estaba prevista, y este es el que la hace.
    public static var applyCapsConfirmTitle: String {
        String(
            localized: "settings.limits.apply.confirm.action",
            defaultValue: "Apply limits",
            comment: """
                Confirming button of the apply-limits dialog: the one that actually deletes. \
                Separate key from the row that opened the dialog, which says 'now' because it \
                brings forward a cleanup that was going to happen anyway.
                """
        )
    }

    /// Lo que hay que decir **antes** de aplicar los topes a mano. Nombra los dos cortes con los
    /// valores elegidos, porque "aplicar los topes" no dice qué se lleva.
    public static func applyCapsPrompt(_ settings: RetentionSettings) -> String {
        guard !settings.isUnlimited else {
            return String(
                localized: "settings.limits.apply.confirm.nothing",
                defaultValue: "Both limits are off, so there's nothing to delete.",
                comment: """
                    Body of the apply-limits dialog when neither cap is set. Nothing will happen, \
                    so it says why instead of asking the user to confirm an empty action.
                    """
            )
        }

        var sentences: [String] = []
        if settings.maxAge.maxAge != nil {
            // El rótulo del selector se **interpola** en vez de reescribirse: es el mismo valor que el
            // usuario acaba de elegir dos filas más arriba, y dos literales iguales son justo lo que
            // una traducción mueve de uno en uno.
            sentences.append(
                String(
                    localized: "settings.limits.apply.confirm.age",
                    defaultValue: """
                        Captures and connections older than \(label(for: settings.maxAge)) will be \
                        deleted.
                        """,
                    comment: """
                        Sentence of the apply-limits dialog naming the age cut. The placeholder is \
                        the chosen option of the 'Keep for' picker, interpolated from that \
                        picker's own key so the two cannot drift apart; a language that needs a \
                        different case or capitalisation for it must reword the sentence around it.
                        """
                )
            )
        }
        if settings.maxCaptureSize.maxBytes != nil {
            sentences.append(
                String(
                    localized: "settings.limits.apply.confirm.size",
                    defaultValue: """
                        Captures over \(label(for: settings.maxCaptureSize)) will be deleted, \
                        oldest first.
                        """,
                    comment: """
                        Sentence of the apply-limits dialog naming the size cut. The placeholder \
                        is the chosen option of the size picker — a figure with its unit, the same \
                        in every language. 'Oldest first' is the order the files go in and the \
                        only thing that makes the outcome predictable.
                        """
                )
            )
        }
        sentences.append(irreversible)
        return joined(sentences)
    }

    /// Borrar **solo** lo descifrado. Una sola propiedad para el botón de la sección y el que
    /// confirma, como en "borrarlo todo": son la misma acción.
    public static var clearPlaintextTitle: String {
        String(
            localized: "settings.plaintext.clear.action",
            defaultValue: "Delete decrypted content",
            comment: """
                Destructive action that deletes the contents of inspected connections and nothing \
                else, shown both as the button in the list and as the confirming button of the \
                dialog it opens. One key for both: they are the same action.
                """
        )
    }

    public static var clearPlaintextDialogTitle: String {
        String(
            localized: "settings.plaintext.clear.confirm.title",
            defaultValue: "Delete decrypted content?",
            comment: """
                Title of the confirmation dialog for deleting the contents of inspected connections. \
                It asks about that alone, which is what tells it apart from the delete-everything \
                dialog below it.
                """
        )
    }

    /// Lo que hay que decir antes de borrar lo descifrado. Dice **lo que se queda** además de lo que
    /// se va: el gesto existe para no tener que tirar el historial entero (ADR 0007, punto 3), así que
    /// sin esa frase la acción se lee como la de abajo.
    public static func clearPlaintextPrompt(usage: StorageUsage?, isMonitoring: Bool) -> String {
        var sentences: [String] = []

        if let usage, usage.plaintextBytes > 0 {
            sentences.append(
                String(
                    localized: "settings.plaintext.clear.confirm.counted",
                    defaultValue: """
                        Everything TunnelVision decrypted from your own traffic will be deleted, \
                        freeing \(DisplayFormat.bytes(usage.plaintextBytes)). Your history and your \
                        captures stay.
                        """,
                    comment: """
                        Body of the delete-decrypted-content dialog when its files could be \
                        measured. The placeholder is how much room they free. The second sentence \
                        is the point of the whole action: it is the one deletion that leaves \
                        everything else in place. 'TunnelVision' is the app's name.
                        """
                )
            )
        } else {
            sentences.append(
                String(
                    localized: "settings.plaintext.clear.confirm.uncounted",
                    defaultValue: """
                        Everything TunnelVision decrypted from your own traffic will be deleted. \
                        Your history and your captures stay.
                        """,
                    comment: """
                        Body of the delete-decrypted-content dialog when there is nothing measured \
                        on disk — its files may already be gone while the index still names them. \
                        It promises no figure it cannot measure.
                        """
                )
            )
        }

        if isMonitoring {
            sentences.append(
                String(
                    localized: "settings.plaintext.clear.confirm.recordingKept",
                    defaultValue: """
                        What the session in progress has decrypted goes once you stop monitoring: \
                        the file being written right now is never deleted.
                        """,
                    comment: """
                        Sentence of the delete-decrypted-content dialog while monitoring is running. \
                        The file the extension is writing is never touched, here or anywhere, so \
                        what it already holds survives this deletion — said before the user accepts, \
                        not discovered afterwards.
                        """
                )
            )
        }

        sentences.append(irreversible)
        return joined(sentences)
    }

    public static var clearEverythingDialogTitle: String {
        String(
            localized: "settings.clear.confirm.title",
            defaultValue: "Delete everything?",
            comment: """
                Title of the confirmation dialog for deleting the history and every capture. It \
                asks about all of it at once, which is what tells it apart from the captures \
                screen's dialog for deleting one file.
                """
        )
    }

    /// Borrarlo todo. **Una sola propiedad para los dos sitios que la dicen** —el botón de la sección y
    /// el que confirma—, como en Captures: son la misma acción y compartirla estructuralmente es lo que
    /// impide que un idioma mueva una y no la otra.
    public static var clearEverythingTitle: String {
        String(
            localized: "settings.clear.action",
            defaultValue: "Delete everything",
            comment: """
                Destructive action that deletes the history and every capture file, shown both as \
                the button in the list and as the confirming button of the dialog it opens. One \
                key for both on purpose: they are the same action, and the second one is what \
                actually deletes.
                """
        )
    }

    /// Lo mismo para "borrarlo todo", que es otra frase y no la misma: aquí se va el historial entero
    /// y todas las capturas menos la que se esté escribiendo, que sigue siendo intocable por lo mismo
    /// que en la pantalla de capturas.
    public static func clearEverythingPrompt(usage: StorageUsage?, isMonitoring: Bool) -> String {
        var sentences: [String] = []

        if let usage, usage.totalBytes > 0 {
            sentences.append(
                String(
                    localized: "settings.clear.confirm.counted",
                    defaultValue: """
                        Every connection in your history \
                        (\(DisplayFormat.count(UInt64(usage.historyFlowCount)))) and every capture \
                        file will be deleted, freeing about \(DisplayFormat.bytes(usage.captureBytes)).
                        """,
                    comment: """
                        Body of the delete-everything dialog when the disk could be measured. The \
                        placeholders are how many connections are saved, already grouped, and how \
                        much the captures occupy. 'About' is deliberate: the history's own file \
                        does not hand its space back, so the figure covers the captures only.
                        """
                )
            )
        } else {
            sentences.append(
                String(
                    localized: "settings.clear.confirm.uncounted",
                    defaultValue: """
                        Every connection in your history and every capture file will be deleted.
                        """,
                    comment: """
                        Body of the delete-everything dialog when the disk could not be measured, \
                        so nothing can be counted. It names what goes without promising how much \
                        room it frees — a figure that could not be measured must not be invented.
                        """
                )
            )
        }

        // Lo descifrado va **antes** que la salvedad de la grabación y en frase propia: es lo que un
        // usuario que ha inspeccionado más querría estar seguro de que se va, y la frase de arriba
        // nombra el historial y las capturas, así que sin esto se leería como que sobrevive.
        if let usage, usage.hasPlaintext {
            sentences.append(
                String(
                    localized: "settings.clear.confirm.plaintext",
                    defaultValue: """
                        The decrypted content of your inspected connections goes too \
                        (\(DisplayFormat.bytes(usage.plaintextBytes))).
                        """,
                    comment: """
                        Sentence of the delete-everything dialog when decrypted content is stored. \
                        The placeholder is how much it occupies. It is named separately because the \
                        sentence above it lists the history and the captures, and a reader would \
                        otherwise assume the contents of inspected connections survive.
                        """
                )
            )
        }

        if isMonitoring {
            // Nombra la pantalla de capturas leyendo **su** clave: una instrucción que nombra un sitio
            // al que el usuario tiene que ir no puede llamarlo de otra manera que la propia pestaña.
            sentences.append(
                String(
                    localized: "settings.clear.confirm.recordingKept",
                    defaultValue: """
                        The capture being recorded right now is kept — close it from \
                        \(CapturesPresentation.tabTitle) first if you want it gone too.
                        """,
                    comment: """
                        Sentence of the delete-everything dialog while monitoring is running. The \
                        placeholder is the name of the captures tab, interpolated from that tab's \
                        own key so this instruction cannot send the user to a screen the app calls \
                        something else. The open file is never deleted, here or anywhere.
                        """
                )
            )
        }

        sentences.append(irreversible)
        return joined(sentences)
    }

    // MARK: - Almacenamiento

    public static func storage(_ usage: StorageUsage) -> StorageDisplay {
        StorageDisplay(
            captures: StorageFigure(
                count: captureCountText(usage.captureFileCount),
                size: DisplayFormat.bytes(usage.captureBytes)
            ),
            history: StorageFigure(
                count: historyCountText(usage.historyFlowCount),
                size: DisplayFormat.bytes(usage.historyBytes)
            ),
            // Sin cuenta de nada: la unidad de lo descifrado es un trozo de una conversación, y
            // contarlos obligaría al usuario a entender el troceo para poder ignorar el número — la
            // misma decisión que en el resultado del barrido.
            plaintext: usage.hasPlaintext
                ? StorageFigure(size: DisplayFormat.bytes(usage.plaintextBytes))
                : nil,
            total: StorageFigure(size: DisplayFormat.bytes(usage.totalBytes))
        )
    }

    /// Lo que se oye de una fila de almacenamiento, detrás de su rótulo.
    ///
    /// La frase se compone **aquí** y no en la vista porque la fila dejó de ser un rótulo y un valor:
    /// separar la cuenta del tamaño para que las cifras se comparen de un vistazo dejaba tres
    /// elementos seguidos en el árbol, y el árbol se recorre por posición sin decir que dos de ellos
    /// hablan del primero. El orden es el de la vista: primero lo que ocupa, que es por lo que se lee
    /// la tabla, y después de cuántas cosas se compone.
    public static func storageRowAccessibilityValue(_ figure: StorageFigure) -> String {
        guard let count = figure.count else { return figure.size }

        return String(
            localized: "settings.storage.row.accessibilityValue",
            defaultValue: "\(figure.size), \(count)",
            comment: """
                VoiceOver value of a storage row, read after its label. The placeholders are how \
                much it occupies and how many things make it up, both already formatted. A row \
                that counts nothing — decrypted content, and the total — is described by its size \
                alone.
                """
        )
    }

    /// Cuántos ficheros hay. Plural con dos claves hermanas, nunca el marcado `inflect:`
    /// (`docs/development/02-coding-standards.md`).
    private static func captureCountText(_ fileCount: Int) -> String {
        guard fileCount != 1 else {
            return String(
                localized: "settings.storage.captures.count.one",
                defaultValue: "1 file",
                comment: """
                    How many capture files there are, beside the size of the storage row, when \
                    there is exactly one. See the plural form in the sibling key; a language with \
                    more plural forms needs both merged into one key with catalog variations.
                    """
            )
        }

        return String(
            localized: "settings.storage.captures.count.other",
            defaultValue: "\(DisplayFormat.count(UInt64(max(fileCount, 0)))) files",
            comment: """
                How many capture files there are, beside the size of the storage row, for any \
                number other than one, zero included. The placeholder is the count, already grouped.
                """
        )
    }

    private static func historyCountText(_ flowCount: Int) -> String {
        guard flowCount != 1 else {
            return String(
                localized: "settings.storage.history.count.one",
                defaultValue: "1 connection",
                comment: """
                    How many connections are saved, beside the size of the storage row, when there \
                    is exactly one. See the plural form in the sibling key; a language with more \
                    plural forms needs both merged into one key with catalog variations.
                    """
            )
        }

        return String(
            localized: "settings.storage.history.count.other",
            defaultValue: "\(DisplayFormat.count(UInt64(max(flowCount, 0)))) connections",
            comment: """
                How many connections are saved, beside the size of the storage row, for any number \
                other than one, zero included. The placeholder is the count, already grouped.
                """
        )
    }

    /// Por qué un tope de tamaño no se puede cumplir: la captura que se está grabando ya pesa por sí
    /// sola más que él, y ésa no se borra nunca.
    ///
    /// **Es pública y la leen dos pantallas.** Aquí es una frase del resultado de una limpieza; en
    /// Captures es el estado en que está el tope ahora mismo (`CapturesPresentation.headroom`). El
    /// hecho es el mismo y la salida también, así que se comparte **estructuralmente**: dos claves
    /// diciendo esto con distintas palabras es exactamente cómo una traducción acaba explicando el
    /// mismo mecanismo de dos maneras. El listón de `CommonCopy` no la admite —no es una palabra de
    /// la app entera, es una frase sobre la retención—, así que vive donde vive la retención.
    public static var sizeCapUnreachableExplanation: String {
        String(
            localized: "settings.retention.sizeCapUnreachable",
            defaultValue: """
                The capture being recorded is already larger than your size limit, so it \
                can't be met until you start a new capture file.
                """,
            comment: """
                Why a size limit cannot be met: the open capture alone is over it, and that file \
                is never deleted. Read in two places — the cleanup result in Settings and the room \
                summary on the captures screen — so it names the way out (a new capture file \
                closes this one) rather than leaving the user with an unmet limit and no \
                explanation.
                """
        )
    }

    // MARK: - Resultado de una limpieza

    /// Qué contarle al usuario tras aplicar los topes.
    ///
    /// Devuelve `nil` **solo** cuando una limpieza automática no encontró nada que hacer: la pantalla
    /// aplica los topes sola al abrirse, y anunciar "no había nada que borrar" cada vez la convertiría
    /// en ruido. Lo que el usuario pide con el dedo siempre contesta.
    public static func retention(
        _ outcome: RetentionOutcome,
        plaintext: PlaintextSweepOutcome = PlaintextSweepOutcome(),
        trigger: RetentionTrigger
    ) -> SettingsNotice? {
        var sentences: [String] = []

        if !outcome.deletedFiles.isEmpty {
            sentences.append(
                deletedCapturesText(
                    count: outcome.deletedFiles.count,
                    bytesReclaimed: outcome.bytesReclaimed
                )
            )
        }
        if outcome.prunedFlows > 0 {
            sentences.append(prunedFlowsText(count: outcome.prunedFlows))
        }
        // Lo descifrado se cuenta aparte de las conexiones y **antes** que el aviso del techo, porque
        // son dos frases de la misma historia: qué se fue, y por qué se fue algo que la caducidad
        // habría conservado.
        if plaintext.didChangeAnything {
            sentences.append(deletedPlaintextText(bytesReclaimed: plaintext.bytesReclaimed))
        }
        // El ADR 0007 pide decir esto en vez de dejar que parezca un fallo: el techo del contenido
        // descifrado no es un ajuste, así que un usuario que ve desaparecer conversaciones dentro de
        // su plazo no tiene ninguna pantalla donde encontrar la explicación.
        if plaintext.ceilingEnforced {
            sentences.append(
                String(
                    localized: "settings.retention.plaintextCeiling",
                    defaultValue: """
                        Some of it went before its time: decrypted content has a fixed limit on how \
                        much room it may take, and the oldest goes first.
                        """,
                    comment: """
                        Sentence of the cleanup result when the fixed ceiling on decrypted content \
                        deleted more than the user's own expiry would have. The limit is not a \
                        setting, so this is the only place the user can learn why conversations \
                        inside their retention window are gone.
                        """
                )
            )
        }
        // El tope incumplido se dice y se nombra la salida, en vez de dejar al usuario con su tope
        // sin cumplir y sin explicación: la grabación en curso no se borra nunca.
        if outcome.sizeCapUnreachable {
            sentences.append(sizeCapUnreachableExplanation)
        }

        // Los dos barridos comparten frase de fallo: para el usuario lo que ha pasado es uno solo —
        // pidió limpiar y parte no salió—, y separarlo en dos avisos le haría distinguir dos
        // mecanismos que la pantalla nunca le ha nombrado.
        let failures = outcome.failures + plaintext.failures
        if !failures.isEmpty {
            sentences.append(
                String(
                    localized: "settings.retention.partialFailure",
                    defaultValue: "Some of it couldn't be deleted.",
                    comment: """
                        Sentence appended to the cleanup result when part of it failed. It follows \
                        whatever was deleted, so it says 'some': losing count of what did get \
                        freed would be worse than not reporting the failure. The system's own \
                        message travels apart, as a diagnostic.
                        """
                )
            )
            return SettingsNotice(
                message: joined(sentences),
                diagnostic: failures.joined(separator: "\n"),
                role: .warning
            )
        }

        if sentences.isEmpty {
            guard trigger == .manual else { return nil }
            return SettingsNotice(
                message: String(
                    localized: "settings.retention.nothingToDelete",
                    defaultValue: "Nothing to delete — you're already within your limits.",
                    comment: """
                        Answer to a cleanup the user asked for that found nothing to do. It is \
                        said only then: the screen also applies the caps on its own when it opens, \
                        and announcing this every time would make it noise.
                        """
                ),
                role: .neutral
            )
        }

        return SettingsNotice(
            message: joined(sentences),
            role: outcome.sizeCapUnreachable ? .warning : .accent
        )
    }

    /// Cuántas capturas se fueron y cuánto liberaron. Plural con dos claves hermanas.
    private static func deletedCapturesText(count: Int, bytesReclaimed: UInt64) -> String {
        let freed = DisplayFormat.bytes(bytesReclaimed)

        guard count != 1 else {
            return String(
                localized: "settings.retention.deleted.one",
                defaultValue: "Deleted 1 capture and freed \(freed).",
                comment: """
                    Sentence of the cleanup result when exactly one capture file was deleted. The \
                    placeholder is how much room it freed. See the plural form in the sibling key; \
                    a language with more plural forms needs both merged into one key with catalog \
                    variations.
                    """
            )
        }

        return String(
            localized: "settings.retention.deleted.other",
            defaultValue: """
                Deleted \(DisplayFormat.count(UInt64(max(count, 0)))) captures and freed \(freed).
                """,
            comment: """
                Sentence of the cleanup result for any number of deleted captures other than one. \
                The placeholders are how many files went, already grouped, and how much room they \
                freed.
                """
        )
    }

    /// Qué se llevó el barrido del contenido descifrado.
    ///
    /// **No lleva cuenta de trozos**, a diferencia de las capturas y las conexiones: un "trozo" es un
    /// pedazo de una conversación tal y como salió de la terminación, y decir "se borraron 812 trozos"
    /// obligaría al usuario a entender el troceo para poder ignorar el número. Lo que sí significa
    /// algo es cuánto sitio se recuperó, y solo se dice cuando se recuperó alguno: la caducidad puede
    /// llevarse filas del índice sin que ningún fichero entero deje de servir todavía.
    private static func deletedPlaintextText(bytesReclaimed: UInt64) -> String {
        guard bytesReclaimed > 0 else {
            return String(
                localized: "settings.retention.plaintext.deleted",
                defaultValue: "Deleted decrypted content that was past its limit.",
                comment: """
                    Sentence of the cleanup result when expired decrypted content was deleted but \
                    no whole file stopped being needed, so nothing was freed yet. 'Decrypted \
                    content' is what the app calls the contents of inspected connections \
                    everywhere, and it is kept apart from captures and connections because it is \
                    the one thing here that was never encrypted on disk.
                    """
            )
        }

        return String(
            localized: "settings.retention.plaintext.deletedAndFreed",
            defaultValue: """
                Deleted decrypted content that was past its limit and freed \
                \(DisplayFormat.bytes(bytesReclaimed)).
                """,
            comment: """
                Sentence of the cleanup result when expired decrypted content was deleted and its \
                files went with it. The placeholder is how much room they freed. There is no count \
                of items on purpose: the unit would be a slice of a conversation, which the user \
                has no reason to know about.
                """
        )
    }

    /// Cuántas conexiones salieron del historial. Plural con dos claves hermanas.
    private static func prunedFlowsText(count: Int) -> String {
        guard count != 1 else {
            return String(
                localized: "settings.retention.pruned.one",
                defaultValue: "Removed 1 connection from your history.",
                comment: """
                    Sentence of the cleanup result when exactly one connection was removed from \
                    the history. See the plural form in the sibling key; a language with more \
                    plural forms needs both merged into one key with catalog variations.
                    """
            )
        }

        return String(
            localized: "settings.retention.pruned.other",
            defaultValue: """
                Removed \(DisplayFormat.count(UInt64(max(count, 0)))) connections from your history.
                """,
            comment: """
                Sentence of the cleanup result for any number of removed connections other than \
                one. The placeholder is how many left, already grouped. 'Removed' rather than \
                'deleted' because the database keeps their space for new traffic, which the \
                storage footer explains.
                """
        )
    }

    /// Lo mismo para "borrarlo todo". No comparte función con `retention` a propósito: un borrado
    /// completo que no se llevó nada **no** es "estabas dentro de tus topes", es que no había nada.
    public static func cleared(
        _ outcome: RetentionOutcome,
        plaintext: PlaintextSweepOutcome = PlaintextSweepOutcome()
    ) -> SettingsNotice {
        let failures = outcome.failures + plaintext.failures
        guard failures.isEmpty else {
            return SettingsNotice(
                message: String(
                    localized: "settings.clear.failure",
                    defaultValue: """
                        Some of it couldn't be deleted, so part of your data is still on the device.
                        """,
                    comment: """
                        Answer to 'delete everything' when part of it failed. The second half is \
                        the point: after asking for everything to go, the user has to be told \
                        plainly that some of it is still there. The system's own message travels \
                        apart, as a diagnostic.
                        """
                ),
                diagnostic: failures.joined(separator: "\n"),
                role: .warning
            )
        }
        guard outcome.didChangeAnything || plaintext.didChangeAnything else {
            return SettingsNotice(
                message: String(
                    localized: "settings.clear.nothingLeft",
                    defaultValue: "There was nothing left to delete.",
                    comment: """
                        Answer to 'delete everything' when there was nothing to delete. It is not \
                        the sibling sentence about being within your limits: nothing was kept back \
                        by a cap here, there was simply nothing stored.
                        """
                ),
                role: .neutral
            )
        }
        // Va como segunda frase y no dentro de la primera: aquella lleva ya dos cuentas con sus
        // cuatro claves de plural, y meterle una tercera las multiplicaría por dos sin que el usuario
        // ganase nada — lo descifrado no se cuenta en unidades que él conozca.
        var sentences = [clearedText(outcome)]
        if !plaintext.deletedFiles.isEmpty {
            sentences.append(
                String(
                    localized: "settings.clear.plaintext",
                    defaultValue: """
                        The decrypted content went too, freeing \(DisplayFormat.bytes(plaintext.bytesReclaimed)).
                        """,
                    comment: """
                        Sentence appended to the 'delete everything' result when files of decrypted \
                        content were deleted as well. The placeholder is how much room they freed. \
                        It is said separately because deleting the record of what was inside the \
                        user's own traffic is the part of 'everything' they are most likely to have \
                        meant.
                        """
                )
            )
        }
        return SettingsNotice(message: joined(sentences), role: .accent)
    }

    /// Lo que se llevó borrar **solo** lo descifrado.
    ///
    /// No comparte función con `cleared` por lo mismo que aquella no la comparte con `retention`: lo
    /// que hay que contestar aquí es otra cosa. Un borrado completo que no encontró nada es "no había
    /// nada guardado"; este puede además **dejar algo detrás a propósito** —el fichero que la
    /// extensión está escribiendo— y callarlo dejaría al usuario creyendo que se fue todo.
    public static func plaintextCleared(
        _ outcome: PlaintextClearOutcome,
        isMonitoring: Bool
    ) -> SettingsNotice {
        guard outcome.failures.isEmpty else {
            return SettingsNotice(
                message: String(
                    localized: "settings.plaintext.clear.failure",
                    defaultValue: """
                        Some of it couldn't be deleted, so part of the decrypted content is still on \
                        the device.
                        """,
                    comment: """
                        Answer to deleting the decrypted content when part of it failed. After \
                        asking for the most sensitive thing the app stores to go, the user has to be \
                        told plainly that some of it is still there. The system's own message \
                        travels apart, as a diagnostic.
                        """
                ),
                diagnostic: outcome.failures.joined(separator: "\n"),
                role: .warning
            )
        }

        guard outcome.didChangeAnything else {
            return SettingsNotice(
                message: String(
                    localized: "settings.plaintext.clear.nothingLeft",
                    defaultValue: "There was no decrypted content to delete.",
                    comment: """
                        Answer to deleting the decrypted content when there was none. It is the \
                        normal state of the product — saving it is off by default — so it reads as a \
                        fact and not as a failure.
                        """
                ),
                role: .neutral
            )
        }

        var sentences = [deletedAllPlaintextText(bytesReclaimed: outcome.bytesReclaimed)]
        // Lo que se queda solo se puede explicar mientras se está grabando: fuera de ahí, unos bytes
        // que sobreviven al borrado son un fallo, y ese camino ya salió por arriba con su aviso.
        if isMonitoring, outcome.bytesKept > 0 {
            sentences.append(
                String(
                    localized: "settings.plaintext.clear.recordingKept",
                    defaultValue: """
                        What the session in progress decrypted is still in the file being written; \
                        it goes once you stop monitoring.
                        """,
                    comment: """
                        Sentence appended to the deletion result when monitoring left a file behind. \
                        It is not a failure — the open file is never deleted — but leaving it unsaid \
                        would let the user believe every decrypted byte is gone when some is not.
                        """
                )
            )
        }
        return SettingsNotice(message: joined(sentences), role: .accent)
    }

    /// Cuánto sitio liberó el borrado del contenido descifrado. Sin cuenta de trozos, igual que en el
    /// barrido: la unidad sería un pedazo de una conversación.
    private static func deletedAllPlaintextText(bytesReclaimed: UInt64) -> String {
        guard bytesReclaimed > 0 else {
            return String(
                localized: "settings.plaintext.clear.done",
                defaultValue: "The decrypted content was deleted.",
                comment: """
                    Answer to deleting the decrypted content when its index went but no file stopped \
                    being needed, so nothing was freed on disk yet. It states what happened without \
                    promising room that was not recovered.
                    """
            )
        }

        return String(
            localized: "settings.plaintext.clear.doneAndFreed",
            defaultValue: """
                The decrypted content was deleted, freeing \(DisplayFormat.bytes(bytesReclaimed)).
                """,
            comment: """
                Answer to deleting the decrypted content when its files went with it. The \
                placeholder is how much room they freed. No count of items on purpose: the unit \
                would be a slice of a conversation.
                """
        )
    }

    /// Lo que se llevó "borrarlo todo", en una sola frase con **dos** cuentas.
    ///
    /// Por eso son cuatro claves y no dos: el plural de cada mitad se elige por separado y las dos
    /// mitades van en la misma frase, así que las combinaciones son 2×2. Partirla en dos frases sería
    /// cambiar lo que el usuario lee, y sacar los trozos contados a placeholders sueltos dejaría al
    /// traductor una unidad que no es una frase. La regla del plural es la de siempre
    /// (`docs/development/02-coding-standards.md`): claves hermanas, nunca el marcado `inflect:`, y el
    /// primer idioma con más formas obliga a fundir las cuatro en una clave con variaciones.
    private static func clearedText(_ outcome: RetentionOutcome) -> String {
        let captures = outcome.deletedFiles.count
        let connections = outcome.prunedFlows
        let capturesText = DisplayFormat.count(UInt64(max(captures, 0)))
        let connectionsText = DisplayFormat.count(UInt64(max(connections, 0)))

        switch (captures == 1, connections == 1) {
        case (true, true):
            return String(
                localized: "settings.clear.done.one.one",
                defaultValue: "Deleted 1 capture and 1 connection.",
                comment: """
                    Answer to 'delete everything' when exactly one capture and exactly one \
                    connection went. One of four sibling keys: the sentence carries two counts, so \
                    each half has its own singular and plural. A language with more plural forms \
                    needs all four merged into one key with catalog variations.
                    """
            )
        case (true, false):
            return String(
                localized: "settings.clear.done.one.other",
                defaultValue: "Deleted 1 capture and \(connectionsText) connections.",
                comment: """
                    Answer to 'delete everything' when exactly one capture went along with any \
                    other number of connections. The placeholder is how many connections, already \
                    grouped. One of four sibling keys; see the others for the remaining \
                    combinations.
                    """
            )
        case (false, true):
            return String(
                localized: "settings.clear.done.other.one",
                defaultValue: "Deleted \(capturesText) captures and 1 connection.",
                comment: """
                    Answer to 'delete everything' when exactly one connection went along with any \
                    other number of captures. The placeholder is how many captures, already \
                    grouped. One of four sibling keys; see the others for the remaining \
                    combinations.
                    """
            )
        case (false, false):
            return String(
                localized: "settings.clear.done.other.other",
                defaultValue: "Deleted \(capturesText) captures and \(connectionsText) connections.",
                comment: """
                    Answer to 'delete everything' for any number of captures and connections other \
                    than one each, zero included. The placeholders are the two counts, already \
                    grouped. One of four sibling keys; see the others for the remaining \
                    combinations.
                    """
            )
        }
    }

    // MARK: - Fallos

    /// Lo guardado no se pudo leer. Se distingue de "no hay nada guardado" (una instalación nueva,
    /// que es el estado normal y silencioso) porque significa que lo que el usuario eligió se ha
    /// perdido, y la salida es que la siguiente escritura lo repara.
    public static func settingsUnreadable(_ detail: String) -> SettingsNotice {
        SettingsNotice(
            message: String(
                localized: "settings.notice.settingsUnreadable",
                defaultValue: """
                    Your saved settings couldn't be read, so these are the defaults. Changing \
                    anything here saves them again.
                    """,
                comment: """
                    Notice when the saved settings could not be read. Both halves matter: what is \
                    on screen is not what the user chose, and the way out is any change at all, \
                    which writes the file again. The system's own message travels apart, as a \
                    diagnostic.
                    """
            ),
            diagnostic: detail,
            role: .warning
        )
    }

    /// Una escritura que falla deja el ajuste **como estaba**, y la pantalla vuelve a enseñar el
    /// valor anterior: un interruptor que se queda en la posición nueva afirmaría que se guardó.
    public static func saveFailed(_ detail: String) -> SettingsNotice {
        SettingsNotice(
            message: String(
                localized: "settings.notice.saveFailed",
                defaultValue: "That setting couldn't be saved, so it's still as it was.",
                comment: """
                    Notice when writing one setting failed. The second half says what the screen \
                    now shows: the control went back to its previous position, because leaving it \
                    in the new one would claim the change was saved.
                    """
            ),
            diagnostic: detail,
            role: .warning
        )
    }

    public static func storageUnavailable(_ detail: String) -> SettingsNotice {
        SettingsNotice(
            message: String(
                localized: "settings.notice.storageUnavailable",
                defaultValue: "The capture folder couldn't be read, so nothing was deleted.",
                comment: """
                    Notice when the capture folder could not be listed during a cleanup. Nothing \
                    was touched, which is what the user needs to know before deciding whether to \
                    try again.
                    """
            ),
            diagnostic: detail,
            role: .warning
        )
    }

    /// Sin listado no se sabe qué fichero está abierto, y borrar sin saberlo podría llevarse el que la
    /// extensión está escribiendo. Se prefiere no tocar nada.
    public static var recordingFileUnknown: SettingsNotice {
        SettingsNotice(
            message: String(
                localized: "settings.notice.recordingFileUnknown",
                defaultValue: """
                    The capture folder couldn't be read while monitoring is running, so nothing \
                    was deleted — the file being recorded can't be identified right now.
                    """,
                comment: """
                    Notice when a cleanup was refused because the open capture could not be \
                    identified. Deleting blind could take the file the extension is writing, so \
                    nothing is touched; the reason is said rather than only the refusal.
                    """
            ),
            role: .warning
        )
    }

    // MARK: - Ajustes que cuestan algo visible

    /// El detalle de captura se fija cuando se **crea** el fichero: el `snaplen` va en su cabecera
    /// global, no en cada registro. Aplicarlo en caliente obliga por tanto a empezar un fichero nuevo,
    /// y eso el usuario lo va a ver en su lista de capturas, así que se dice antes de que lo descubra.
    public static var captureDetailStartedANewFile: SettingsNotice {
        SettingsNotice(
            message: String(
                localized: "settings.notice.captureDetailNewFile",
                defaultValue: """
                    Applied. How much of each packet is recorded is fixed when a capture file is \
                    created, so a new one was started — you'll see it under Captures.
                    """,
                comment: """
                    Notice after changing the capture detail while monitoring is running. The \
                    change takes effect immediately, at the cost of closing the capture file and \
                    opening another: that extra file shows up on the Captures screen, so it is \
                    named here rather than left to be discovered. 'Captures' is this app's own \
                    screen, named by its tab.
                    """
            ),
            role: .neutral
        )
    }

    /// Guardado, pero la sesión viva no lo aceptó. El ajuste **sí** está guardado: se dice lo uno y
    /// lo otro, porque tragarse el fallo dejaría al usuario creyendo que ya está capturando distinto.
    public static func liveChangeNotApplied(_ detail: String) -> SettingsNotice {
        SettingsNotice(
            message: String(
                localized: "settings.notice.liveChangeNotApplied",
                defaultValue: """
                    Saved, but monitoring didn't take the change — it applies the next time you \
                    start it.
                    """,
                comment: """
                    Notice when a setting was saved but the running session refused it. Both \
                    halves are said: swallowing the failure would leave the user believing the \
                    change is already in force. The system's own message travels apart, as a \
                    diagnostic.
                    """
            ),
            diagnostic: detail,
            role: .warning
        )
    }

    // MARK: - Las piezas que componen un aviso

    /// Que no hay vuelta atrás, que es lo último que se lee antes de aceptar cualquiera de las dos
    /// confirmaciones. Una sola propiedad para las dos: significa exactamente lo mismo en ambas, y dos
    /// literales iguales son justo lo que una traducción mueve de uno en uno.
    private static var irreversible: String {
        String(
            localized: "settings.prompt.irreversible",
            defaultValue: "This can't be undone.",
            comment: """
                Last sentence of both destructive confirmations on this screen. One key for both: \
                it says the same thing in each, and it is what the user reads immediately before \
                accepting. Deleted captures and pruned connections cannot be brought back.
                """
        )
    }

    /// Junta varias frases en un párrafo **por el catálogo**.
    ///
    /// Pegarlas con un `joined(separator: " ")` en Swift decidiría fuera del catálogo el orden y el
    /// separador, que son propiedades de un idioma: es la misma regla que `ScrubAccessibility.cursorValue`
    /// y `PacketBytesPresentation.truncationNote`, con la única diferencia de que aquí las frases pueden
    /// ser hasta tres y la clave se aplica en cascada, de dos en dos.
    private static func joined(_ sentences: [String]) -> String {
        guard var paragraph = sentences.first else { return "" }

        for sentence in sentences.dropFirst() {
            paragraph = String(
                localized: "settings.prompt.join",
                defaultValue: "\(paragraph) \(sentence)",
                comment: """
                    Joins two of this screen's sentences into one paragraph. The placeholders are \
                    two already-translated sentences; only their order and what goes between them \
                    are translatable here. It is applied repeatedly when a message carries three \
                    sentences, so the first placeholder may itself be a pair already joined.
                    """
            )
        }

        return paragraph
    }
}
