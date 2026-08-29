import Foundation
import Shared

/// Lo que los contadores de la sesión dicen sobre la inspección, en una sola conclusión.
///
/// Existe porque la pregunta que trae a alguien a esta pantalla no es "cuántos flujos hubo" sino
/// **"¿por qué no se inspecciona nada?"**, y esa respuesta no está en ningún contador suelto: está en
/// la relación entre ellos. Convertirla en un valor —en vez de dejarla a la vista, o al ojo de quien
/// mira una tabla de números— es lo que permite afirmarla en un test en vez de deducirla delante del
/// dispositivo, que es justo la situación cara que esto viene a abaratar.
///
/// Los contadores son **de la sesión**: nacen a cero al encender el túnel. Así que ninguna conclusión
/// de aquí es una propiedad del producto, sino de lo que ha pasado desde que se encendió, y la copia
/// lo dice.
public enum InspectionVerdict: Sendable, Equatable {
    /// El túnel no está monitorizando: no hay sesión de la que hablar.
    case notMonitoring
    /// Hubo respuesta, pero sin la mitad del relay. Es la ventana de la parada (el relay se cierra
    /// antes que el pipeline), y se dice como ausencia porque unos ceros afirmarían lo contrario de
    /// lo que se pregunta.
    case unavailable
    /// Ni un candidato: o la inspección está apagada, o no ha pasado un TLS sobre TCP desde que se
    /// encendió el túnel.
    case idle
    /// Hay terminaciones abiertas pero ninguna ha acabado todavía. El desenlace llega al cerrarse el
    /// flujo, así que esto es normal en los primeros segundos.
    case starting
    /// Se está descifrando: hay flujos inspeccionados de punta a punta.
    case working(inspected: UInt64)
    /// Todo lo que llegó a terminar acabó rechazado por el cliente: pinning (ADR 0003). No es una
    /// avería, es el producto haciendo lo que promete.
    case pinnedOnly(UInt64)
    /// Hubo candidatos y **ninguno** llegó a terminación. Es el síntoma que hay que saber leer:
    /// con nombre leído, la terminación no se pudo construir; sin él, esos 443 no hablaban TLS.
    case neverTerminates(named: Bool)
    /// Las terminaciones se abren y se caen antes de descifrar nada. `rolledBack` es cuántas de esas
    /// caídas llegaron **antes de que el dispositivo recibiera un byte** de la terminación, y por
    /// tanto devolvieron el flujo al passthrough sin costar la conexión: es lo que decide si esto se
    /// nota navegando o no, y por eso viaja con el veredicto en vez de quedarse en la tabla.
    case failing(failed: UInt64, rolledBack: UInt64)
}

/// Qué está haciendo el túnel con la resolución de nombres.
///
/// Es un veredicto aparte del de la inspección y no una rama suya, porque contesta otra pregunta y de
/// otra gravedad: la inspección es una función opcional que degrada en silencio, y esto es si el
/// dispositivo **puede resolver nombres** mientras el túnel está encendido. Un interfaz primario sin
/// resolver deja al sistema sin red, que es el fallo que tardó tres sesiones en encontrarse — y que
/// hasta ahora no lo contaba nadie.
public enum ResolverVerdict: Sendable, Equatable {
    /// No hay sesión, o la respuesta no traía el estado del DNS: nada que afirmar.
    case unknown
    /// No se anunció ninguno **y no se pudo ni preguntar** al sistema. Es una avería nuestra.
    case unreadable
    /// Se pudo preguntar y el sistema no tenía ninguno que dar.
    case noneReported
    /// El sistema dio resolvers y **ninguno se podía anunciar** (`TunnelResolvers`): el caso que la
    /// spec daba por alcanzable —una red que solo ofrezca un `fe80::`— ocurriendo de verdad.
    case noneUsable(reported: [String])
    /// Se anunciaron y las consultas se contestan: lo normal.
    case announcing([String])
    /// Las consultas de DNS salen y **no vuelve ninguna**, y además la red cambió sin que el túnel
    /// consiguiera aprender los resolvers nuevos: los que anuncia son los de la red anterior.
    ///
    /// Es el fallo confirmado en hardware el 2026-08-15, y se afirma con **causa y síntoma a la vez**
    /// a propósito. Solo con la causa —hubo un cambio de red— se avisaría también a quien cambió de
    /// Wi-Fi a otra con los mismos resolvers, que no tiene ningún problema; solo con el síntoma no se
    /// podría decir qué hacer.
    case stale(queries: UInt64, networkChanges: UInt64)
    /// Las consultas salen y no vuelve ninguna, sin un cambio de red que lo explique: el resolver
    /// anunciado no está contestando, y quien mira solo ve páginas que no cargan.
    case notAnswering(queries: UInt64)
}

/// El titular de la pantalla: el veredicto convertido en copia.
public struct DiagnosticsHeadline: Sendable, Equatable {
    public let title: String
    public let detail: String
    public let systemImage: String
    public let role: StatusRole

    public init(title: String, detail: String, systemImage: String, role: StatusRole) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.role = role
    }
}

/// Cómo se enseñan las tres listas de resolvers de la sección de DNS.
///
/// Existe porque las tres eran **siempre** tres filas, y la razón escrita para ello —"la comparación
/// es el dato"— dejaba la comparación sin hacer: tres listas idénticas, una debajo de otra, y que la
/// haga el ojo. Y en el caso normal está garantizado que sean idénticas, no es casualidad: mientras
/// monitoriza, el túnel es el interfaz primario, así que lo que el sistema contesta es **lo que el
/// túnel acaba de anunciar** (medido en hardware, ver `ResolverStatus.reportedNow`). Una fila que por
/// construcción repite a la de arriba no es una comparación: es el mismo hecho dicho tres veces, que
/// es lo que Ajustes ya había pagado en otra pantalla.
///
/// Así que la comparación **se hace**, y lo que se enseña es su resultado. Sin valor por defecto,
/// como el resto de las decisiones de esta capa.
public enum ResolverListing: Sendable, Equatable {
    /// Las tres coinciden: una sola lista, y el pie de la sección explica por qué basta con una.
    case agreeing([String])
    /// Alguna difiere — que es exactamente lo que hay que poder ver, porque es la forma que tiene un
    /// cambio de red que el túnel no aprendió. Entonces van las tres, cada una con su nombre.
    case diverging
}

/// Qué clase de cosa hay en el sitio del valor, que en una tabla de cuarenta y ocho filas no es la
/// misma para todas.
///
/// Sale de mirar la pantalla llena por primera vez: cuarenta y ocho filas dibujadas exactamente
/// igual, así que *Packets recorded*, *Database failures* y el texto que contestó el sistema pesaban
/// lo mismo, y la pregunta por la que se abre la pantalla —**qué va mal**— había que contestarla
/// leyéndolas una a una. Es la misma clase de decisión que `MonitoringProminence` o el total de
/// Ajustes: estaba escondida en que no la tomaba nadie, y **no tiene valor por defecto** para que una
/// fila nueva tenga que elegir.
///
/// Los tres casos son tres **contenidos** distintos, no tres tonos de gris. En particular no hay un
/// caso para un contador de avería a cero: un gris propio para decir que no pasa nada es la
/// definición de adorno.
public enum DiagnosticsValueRole: Sendable, Equatable {
    /// Una cifra que se lee: cuánto pasó por aquí. Ni buena noticia ni mala, que es lo que son casi
    /// todas.
    case reading
    /// Una cifra de trabajo perdido por un fallo, y **no está a cero**: lo único de la tabla que pide
    /// algo de quien la mira.
    ///
    /// Solo lo llevan los contadores que cuentan pérdidas nuestras. Deliberadamente **no** lo llevan
    /// los flujos no inspeccionables (ADR 0003: es el producto cumpliendo lo que promete), ni los
    /// límites obrando (contenido por encima del tope, capturas recuperadas), ni los fallos de red
    /// ajenos —conexiones rechazadas, conexiones que se cayeron—: marcar en ámbar lo que una sesión
    /// sana produce de todas formas convierte la marca en ruido, que es lo que la Timeline aprendió
    /// de su insignia repetida.
    case fault
    /// No es una cifra y **no es copia nuestra**: es lo que contestó el sistema, palabra por palabra.
    ///
    /// Se separa por lo mismo que el diagnóstico del llavero en el flujo de la CA: un mensaje de
    /// framework puesto en tipografía proporcional y gris se lee como una frase escrita por el
    /// producto, y es lo contrario — es material que se cita tal cual para buscarlo o pegarlo en una
    /// petición de ayuda, que es la mitad de la razón por la que esta pantalla existe.
    case systemText
}

/// Una línea de la tabla: un dato con su nombre y el papel que juega ese dato.
public struct DiagnosticsRow: Sendable, Equatable, Identifiable {
    /// Clave estable para la lista y para el test. No se traduce: identifica, no se lee.
    public let id: String
    public let label: String
    public let value: String
    public let role: DiagnosticsValueRole

    public init(id: String, label: String, value: String, role: DiagnosticsValueRole) {
        self.id = id
        self.label = label
        self.value = value
        self.role = role
    }

    /// Una lectura ya formateada.
    public static func reading(id: String, label: String, value: String) -> DiagnosticsRow {
        DiagnosticsRow(id: id, label: label, value: value, role: .reading)
    }

    /// Un contador de trabajo perdido. **Recibe el número y no su texto** porque es lo que le permite
    /// decidir: la diferencia entre un fallo que está pasando y uno que no ha pasado es el cero, y
    /// ése es el único `if` de esta decisión — escrito una vez, aquí, en vez de en cada llamada.
    public static func fault(id: String, label: String, count: UInt64) -> DiagnosticsRow {
        DiagnosticsRow(
            id: id,
            label: label,
            value: DisplayFormat.count(count),
            role: count > 0 ? .fault : .reading
        )
    }

    /// Lo que contestó el sistema, con el nombre de lo que estaba haciendo cuando contestó.
    public static func systemText(id: String, label: String, message: String) -> DiagnosticsRow {
        DiagnosticsRow(id: id, label: label, value: message, role: .systemText)
    }
}

/// Un grupo de contadores del mismo componente.
public struct DiagnosticsSection: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let rows: [DiagnosticsRow]

    /// La prosa fija de la sección, que va **debajo** de ella y nunca dentro de la tarjeta — la regla
    /// que Ajustes midió: fuera de la tarjeta el mismo texto tiene el ancho entero y ocupa menos, y
    /// dentro se lee como una fila más entre datos. `nil` cuando no hay nada que explicar, que es
    /// casi siempre: un contador con nombre no necesita pie.
    public let note: String?

    public init(id: String, title: String, rows: [DiagnosticsRow], note: String?) {
        self.id = id
        self.title = title
        self.rows = rows
        self.note = note
    }
}

/// La pantalla de diagnóstico de la sesión: el veredicto sobre la inspección y los contadores que lo
/// sostienen (`docs/spec/tunnel-provider.md` § *`handleAppMessage`*).
///
/// Todo lo que hay aquí es puro: entra un `TunnelStats` —lo que la extensión contesta a
/// `ControlCommand.stats`— y sale la copia. La vista no calcula nada, y por eso la conclusión que
/// importa se puede probar sin un dispositivo delante.
public enum DiagnosticsPresentation {

    // MARK: - Chrome de la pantalla

    public static var screenTitle: String {
        String(
            localized: "diagnostics.title",
            defaultValue: "Session diagnostics",
            comment: """
                Title of the screen that shows the tunnel's counters. 'Session' is load-bearing: \
                the numbers start at zero every time monitoring is turned on.
                """
        )
    }

    /// La fila que lleva aquí desde Ajustes.
    public static var entryTitle: String {
        String(
            localized: "diagnostics.entry",
            defaultValue: "Session diagnostics",
            comment: "Row in Settings that opens the diagnostics screen."
        )
    }

    /// Lo que se dice mientras no hay contadores que enseñar y tampoco un fallo que contar.
    public static var emptyTitle: String {
        String(
            localized: "diagnostics.empty.title",
            defaultValue: "No counters yet",
            comment: "Placeholder shown before the first successful reply from the tunnel."
        )
    }

    public static var emptyDetail: String {
        String(
            localized: "diagnostics.empty.detail",
            defaultValue: "Turn monitoring on and use the device for a moment; the counters arrive from the tunnel itself.",
            comment: "Explains why the diagnostics screen is empty and what to do about it."
        )
    }

    /// Lo que se apunta cuando la extensión contesta otra cosa a `.stats`. No es un texto del sistema
    /// —no lo hay— y por eso está aquí: sin él, una respuesta equivocada se leería como un silencio.
    public static var unexpectedReply: String {
        String(
            localized: "diagnostics.unexpectedReply",
            defaultValue: "The tunnel replied with something else, so these numbers could not be confirmed.",
            comment: """
                Shown when the extension answers a counters query with a different kind of reply. \
                It says what it costs the reader: the numbers on screen may be stale.
                """
        )
    }

    /// Lo que VoiceOver lee de una fila marcada como avería.
    ///
    /// Se compone aquí y no en la vista porque lo que la marca dice —esto no es un número más, aquí
    /// se perdió algo— lo dice con **un símbolo y un color**, y ninguna de las dos cosas se oye. La
    /// alternativa sería que quien escucha la pantalla recorriera cuarenta y ocho pares de etiqueta y
    /// número sin nada que separase el que importa.
    public static func faultDescription(label: String, value: String) -> String {
        String(
            localized: "diagnostics.row.faultDescription",
            defaultValue: "\(label): \(value). Something was lost.",
            comment: """
                What VoiceOver reads for a counter that stands for work lost to a failure and is not \
                zero. Sighted readers get a warning symbol in its place, so the last sentence is what \
                carries it.
                """
        )
    }

    /// El motivo de un fallo de consulta, en algo que se pueda leer.
    ///
    /// **Nunca es el nombre del caso del error**: `String(describing:)` sobre un error tipado da
    /// `permissionDenied` o `controlChannelFailed("…")`, que es código y no una explicación. Lo que se
    /// enseña es el texto que dio el sistema donde lo hay, y una frase corta donde no.
    public static func diagnostic(for error: TunnelControlError) -> String {
        switch error {
        case .configurationFailed(let message), .startFailed(let message), .controlChannelFailed(let message):
            return message
        case .malformedResponse:
            return String(
                localized: "diagnostics.failure.malformed",
                defaultValue: "The tunnel replied with something this version of the app cannot read.",
                comment: """
                    Reason shown when the extension's reply does not decode. It points at a version \
                    mismatch without asking the reader to know what that means.
                    """
            )
        case .permissionDenied, .notInstalled, .notRunning:
            return String(
                localized: "diagnostics.failure.unavailable",
                defaultValue: "The tunnel is not available right now.",
                comment: "Reason shown when there is no tunnel to ask, and no system message to quote."
            )
        }
    }

    /// Cuando la consulta falla. El motivo del sistema va aparte, como en el resto de la app: la copia
    /// no puede ser un mensaje de framework, pero tragárselo dejaría sin nada que contar.
    public static func unreachable(_ detail: String) -> DiagnosticsHeadline {
        DiagnosticsHeadline(
            title: String(
                localized: "diagnostics.unreachable.title",
                defaultValue: "The tunnel did not answer",
                comment: "Headline when the control channel query for counters failed."
            ),
            detail: detail,
            systemImage: "exclamationmark.triangle",
            role: .warning
        )
    }

    // MARK: - El veredicto

    /// Qué dicen los contadores sobre la inspección.
    ///
    /// El orden de las comprobaciones **es** la decisión, porque en una sesión larga varios contadores
    /// son distintos de cero a la vez y solo uno puede encabezar la pantalla. Se ordenan de lo que
    /// desmiente más a lo que desmiente menos: si algo se ha descifrado, la inspección funciona y lo
    /// demás son matices; si nada se descifró pero todo lo terminado acabó rechazado, la explicación
    /// es el pinning y no una avería; y solo cuando no hay terminación **ninguna** se está ante el
    /// síntoma que hay que mirar de cerca.
    public static func verdict(for stats: TunnelStats?, isMonitoring: Bool) -> InspectionVerdict {
        guard isMonitoring else { return .notMonitoring }
        guard let relay = stats?.relay else { return .unavailable }
        guard relay.inspectionCandidates > 0 else { return .idle }

        guard relay.terminationsOpened > 0 else {
            // Ni una terminación pese a haber candidatos. Lo que separa las dos causas es si se llegó
            // a leer un nombre: con nombre había todo lo necesario para intentarlo y aun así no se
            // construyó —la CA no está lista en la extensión, o el sistema no deja levantar el
            // listener local que necesita—; sin nombre no había nada que inspeccionar, porque ese 443
            // no hablaba TLS. `pinnedHostSkips` no entra aquí: para saltarse un host hay que haberlo
            // terminado antes, así que no puede haberlo sin `terminationsOpened`.
            return .neverTerminates(named: relay.sniObserved > 0)
        }

        if relay.flowsInspected > 0 { return .working(inspected: relay.flowsInspected) }
        if relay.flowsPinned > 0 { return .pinnedOnly(relay.flowsPinned) }
        if relay.terminationsFailed > 0 {
            return .failing(failed: relay.terminationsFailed, rolledBack: relay.terminationsRolledBack)
        }
        return .starting
    }

    /// Cuántas consultas de DNS sin una sola respuesta hacen falta para llamarlo avería.
    ///
    /// Una consulta sin contestar es lo normal en el instante en que se mira —está en vuelo—, y dos
    /// son un reintento. Cuatro sin **ninguna** respuesta ya no es ruido: el resolver anunciado no
    /// está ahí. El umbral es sobre la ausencia total de respuestas a propósito; de una pérdida
    /// parcial esta pantalla no afirma nada, porque un porcentaje de fallo necesita una ventana de
    /// tiempo y estos contadores son de toda la sesión.
    private static let dnsFailureFloor: UInt64 = 4

    /// Qué está haciendo el túnel con el DNS.
    ///
    /// El orden tiene dos escalones y el primero manda: **anunciar algo es la precondición de todo lo
    /// demás**, así que sin un resolver anunciado la pregunta no es si funciona sino si hay alguno.
    /// Solo con algo anunciado tiene sentido mirar si contesta.
    ///
    /// **Lo que ya no se hace, y es un cambio del 2026-08-16**: comparar lo anunciado con lo que el
    /// sistema reporta ahora. Estaba medido en el iPhone que con el túnel puesto esa lectura **repite
    /// lo anunciado**, porque `res_getservers` contesta por el interfaz primario, que somos nosotros;
    /// un veredicto sacado de ahí no podría saltar nunca. Lo que sostiene ahora la conclusión son
    /// hechos contados: cuántas veces cambió la red sin que se pudieran aprender resolvers nuevos, y
    /// cuántas consultas salieron sin que volviera ninguna respuesta.
    public static func resolverVerdict(for stats: TunnelStats?, isMonitoring: Bool) -> ResolverVerdict {
        guard isMonitoring, let status = stats?.resolvers else { return .unknown }

        guard !status.announced.isEmpty else {
            guard let reported = status.reportedWhenAnnounced else { return .unreadable }
            return reported.isEmpty ? .noneReported : .noneUsable(reported: reported)
        }

        // Sin la mitad del relay no hay par de consultas y respuestas que mirar, así que no se afirma
        // que algo falle: la ausencia de contadores no es un cero.
        if let relay = stats?.relay,
           relay.dnsQueriesSent >= dnsFailureFloor,
           relay.dnsRepliesReceived == 0 {
            // La causa, cuando se conoce: hubo cambios de red y **ninguno** consiguió resolvers
            // nuevos, así que lo que se está anunciando viene de la red de antes. Que `resolversRelearned`
            // sea cero es lo que lo convierte en un hecho y no en una sospecha — con un solo aprendizaje,
            // el túnel ha demostrado que sabe ponerse al día y la avería es otra.
            if status.networkChanges > 0, status.resolversRelearned == 0 {
                return .stale(queries: relay.dnsQueriesSent, networkChanges: status.networkChanges)
            }
            return .notAnswering(queries: relay.dnsQueriesSent)
        }

        return .announcing(status.announced)
    }

    /// Lo que hay que decir del DNS, o **nada** si no hay nada que decir.
    ///
    /// Devuelve `nil` cuando el túnel está anunciando resolvers y nadie los desmiente, porque esa es
    /// la situación normal y una pantalla que la anuncia enseña a ignorarse. Aparece solo cuando el
    /// dispositivo puede haberse quedado sin resolución de nombres, que es cuando alguien tiene que
    /// enterarse — hasta hoy, ese caso era silencio absoluto.
    public static func resolverNotice(for verdict: ResolverVerdict) -> DiagnosticsHeadline? {
        switch verdict {
        case .unknown, .announcing:
            return nil
        case .unreadable:
            return DiagnosticsHeadline(
                title: String(
                    localized: "diagnostics.dns.unreadable.title",
                    defaultValue: "The tunnel could not read the device's DNS servers",
                    comment: """
                        Notice shown when the tunnel could not ask the system for its DNS servers, so \
                        it announced none.
                        """
                ),
                detail: String(
                    localized: "diagnostics.dns.unreadable.detail",
                    defaultValue: "It announced none, so nothing on this device can look up names while monitoring is on. Turning monitoring off restores name resolution right away.",
                    comment: """
                        Detail for the unreadable-DNS notice. The last sentence is the way out, and it \
                        is immediate: the tunnel stops being the primary interface.
                        """
                ),
                systemImage: "exclamationmark.triangle",
                role: .warning
            )
        case .noneReported:
            return DiagnosticsHeadline(
                title: String(
                    localized: "diagnostics.dns.noneReported.title",
                    defaultValue: "This network offered no DNS servers",
                    comment: """
                        Notice shown when the system itself reported no DNS servers when monitoring \
                        started, so the tunnel had none to announce.
                        """
                ),
                detail: String(
                    localized: "diagnostics.dns.noneReported.detail",
                    defaultValue: "The system had none configured when monitoring started, so the tunnel announced none either. Names will not resolve until monitoring is turned off, or turned on again on a network that offers one.",
                    comment: "Detail for the no-DNS-offered notice. It names both ways out."
                ),
                systemImage: "exclamationmark.triangle",
                role: .warning
            )
        case .noneUsable:
            return DiagnosticsHeadline(
                title: String(
                    localized: "diagnostics.dns.noneUsable.title",
                    defaultValue: "None of this network's DNS servers could be announced",
                    comment: """
                        Notice shown when the system reported DNS servers but every one of them was \
                        unusable through a tunnel.
                        """
                ),
                detail: String(
                    localized: "diagnostics.dns.noneUsable.detail",
                    defaultValue: "The system reported servers this tunnel cannot pass on — a local resolver, or one that only means something on the network's own interface. Names will not resolve while monitoring is on.",
                    comment: """
                        Detail for the unusable-DNS notice. It names the two kinds without asking the \
                        reader to know what loopback or link-local mean.
                        """
                ),
                systemImage: "exclamationmark.triangle",
                role: .warning
            )
        case .stale(let queries, _):
            return DiagnosticsHeadline(
                title: String(
                    localized: "diagnostics.dns.stale.title",
                    defaultValue: "The tunnel is using the previous network's DNS servers",
                    comment: """
                        Notice shown when the network changed, the tunnel could not learn the new DNS \
                        servers, and lookups are now going unanswered.
                        """
                ),
                detail: String(
                    localized: "diagnostics.dns.stale.detail",
                    defaultValue: "This device joined a different network after monitoring started, and the tunnel could not pick up its DNS servers, so \(DisplayFormat.count(queries)) name lookups have gone out with no reply and pages will not load. Turn monitoring off and on again to fix it now.",
                    comment: """
                        Detail for the stale-DNS notice: cause, consequence and the gesture that fixes \
                        it. The count is what makes it a fact rather than a guess.
                        """
                ),
                systemImage: "arrow.triangle.2.circlepath",
                role: .warning
            )
        case .notAnswering(let queries):
            return DiagnosticsHeadline(
                title: String(
                    localized: "diagnostics.dns.notAnswering.title",
                    defaultValue: "Name lookups are getting no reply",
                    comment: """
                        Notice shown when DNS queries leave through the tunnel and nothing comes back, \
                        with no network change to explain it.
                        """
                ),
                detail: String(
                    localized: "diagnostics.dns.notAnswering.detail",
                    defaultValue: "\(DisplayFormat.count(queries)) name lookups have gone out through the tunnel and nothing has come back, so pages will not load. The DNS server being announced may not be reachable from this network; turning monitoring off and on again makes the tunnel read this network's servers again.",
                    comment: """
                        Detail for the unanswered-DNS notice. It offers the same gesture as the stale \
                        case without claiming the cause, which here is not known.
                        """
                ),
                systemImage: "exclamationmark.triangle",
                role: .warning
            )
        }
    }

    /// La copia del veredicto.
    public static func headline(for verdict: InspectionVerdict) -> DiagnosticsHeadline {
        switch verdict {
        case .notMonitoring:
            return DiagnosticsHeadline(
                title: String(
                    localized: "diagnostics.verdict.notMonitoring.title",
                    defaultValue: "Nothing to diagnose yet",
                    comment: "Verdict headline when the tunnel is not running."
                ),
                detail: String(
                    localized: "diagnostics.verdict.notMonitoring.detail",
                    defaultValue: "These counters belong to a monitoring session. Turn monitoring on, use the device for a minute, and come back.",
                    comment: "Verdict detail when the tunnel is not running: says what to do to get numbers."
                ),
                systemImage: "power",
                role: .neutral
            )
        case .unavailable:
            return DiagnosticsHeadline(
                title: String(
                    localized: "diagnostics.verdict.unavailable.title",
                    defaultValue: "The forwarding counters are missing",
                    comment: """
                        Verdict headline when the reply arrived without the relay's half, which \
                        happens while the tunnel is shutting down.
                        """
                ),
                detail: String(
                    localized: "diagnostics.verdict.unavailable.detail",
                    defaultValue: "The tunnel answered while it was stopping, so it had no forwarding counters to give. Pull to refresh once it is running again.",
                    comment: "Verdict detail for a reply with no relay counters. It is not an error."
                ),
                systemImage: "questionmark.circle",
                role: .neutral
            )
        case .idle:
            return DiagnosticsHeadline(
                title: String(
                    localized: "diagnostics.verdict.idle.title",
                    defaultValue: "No connection has been offered for inspection",
                    comment: "Verdict headline when no flow was ever routed to inspection."
                ),
                detail: String(
                    localized: "diagnostics.verdict.idle.detail",
                    defaultValue: "Either inspection is off, or nothing has opened an HTTPS connection over TCP since monitoring started.",
                    comment: """
                        Verdict detail when there were no inspection candidates. Both causes are \
                        ordinary, so neither is presented as a fault.
                        """
                ),
                systemImage: "moon.zzz",
                role: .neutral
            )
        case .starting:
            return DiagnosticsHeadline(
                title: String(
                    localized: "diagnostics.verdict.starting.title",
                    defaultValue: "Inspection has started",
                    comment: "Verdict headline when terminations are open but none has ended yet."
                ),
                detail: String(
                    localized: "diagnostics.verdict.starting.detail",
                    defaultValue: "Connections have been taken over, and how they ended is only known once they close. Refresh in a moment.",
                    comment: "Verdict detail explaining that outcomes arrive when the flow closes."
                ),
                systemImage: "hourglass",
                role: .accent
            )
        case .working(let inspected):
            return DiagnosticsHeadline(
                title: String(
                    localized: "diagnostics.verdict.working.title",
                    defaultValue: "Inspection is working",
                    comment: "Verdict headline when at least one flow was decrypted end to end."
                ),
                detail: String(
                    localized: "diagnostics.verdict.working.detail",
                    defaultValue: "\(DisplayFormat.count(inspected)) connections have been decrypted since monitoring started.",
                    comment: """
                        Verdict detail with the number of decrypted flows. 'Since monitoring \
                        started' matters: the counters reset with every session.
                        """
                ),
                systemImage: "checkmark.seal",
                role: .inspected
            )
        case .pinnedOnly(let pinned):
            return DiagnosticsHeadline(
                title: String(
                    localized: "diagnostics.verdict.pinnedOnly.title",
                    defaultValue: "The apps you used pin their certificates",
                    comment: """
                        Verdict headline when every finished termination was refused by the client. \
                        It names the cause without calling it a failure.
                        """
                ),
                detail: String(
                    localized: "diagnostics.verdict.pinnedOnly.detail",
                    defaultValue: "\(DisplayFormat.count(pinned)) connections refused the local certificate, so they were passed through untouched and marked not inspectable. That is by design.",
                    comment: """
                        Verdict detail for pinned-only sessions. States the product's rule: a pinned \
                        app is left alone, never forced.
                        """
                ),
                systemImage: "lock.shield",
                role: .encrypted
            )
        case .neverTerminates(let named):
            return named
                ? DiagnosticsHeadline(
                    title: String(
                        localized: "diagnostics.verdict.neverTerminates.named.title",
                        defaultValue: "Named connections are not being taken over",
                        comment: """
                            Verdict headline for the diagnosis that matters: hosts were read off the \
                            handshake and still no connection was ever decrypted.
                            """
                    ),
                    detail: String(
                        localized: "diagnostics.verdict.neverTerminates.named.detail",
                        defaultValue: "The hosts were read, so there was a name to inspect by, and no connection was taken over. The local certificate may not be available inside the tunnel, or the system may be refusing the local listener the tunnel needs. Browsing keeps working either way.",
                        comment: """
                            Verdict detail naming the two causes worth checking. The last sentence \
                            matters: this degradation is silent by design, so nothing looks broken.
                            """
                    ),
                    systemImage: "exclamationmark.triangle",
                    role: .warning
                )
                : DiagnosticsHeadline(
                    title: String(
                        localized: "diagnostics.verdict.neverTerminates.unnamed.title",
                        defaultValue: "Those connections were not TLS",
                        comment: """
                            Verdict headline when candidates never announced a host, which is what a \
                            non-TLS protocol on port 443 looks like.
                            """
                    ),
                    detail: String(
                        localized: "diagnostics.verdict.neverTerminates.unnamed.detail",
                        defaultValue: "The connections offered for inspection never announced a host, so there was nothing to inspect by. Some apps speak their own protocol over port 443, and they are forwarded untouched.",
                        comment: "Verdict detail for candidates with no SNI. It is normal, not a fault."
                    ),
                    systemImage: "questionmark.circle",
                    role: .neutral
                )
        case .failing(let failed, let rolledBack):
            // Dos situaciones que la tabla no distingue y quien mira nota muchísimo: si **todas** las
            // caídas llegaron a tiempo de deshacerse, la inspección no funciona pero no se ha perdido
            // una sola conexión; si alguna no, el precio se paga navegando. Decirlas igual mandaría a
            // buscar un internet roto que no lo está, o daría por inocuo algo que sí se nota.
            return rolledBack >= failed
                ? DiagnosticsHeadline(
                    title: String(
                        localized: "diagnostics.verdict.failing.recovered.title",
                        defaultValue: "Inspection is not taking hold",
                        comment: """
                            Verdict headline when every termination failed early enough to be undone. \
                            It names the fault without implying the connections were lost.
                            """
                    ),
                    detail: String(
                        localized: "diagnostics.verdict.failing.recovered.detail",
                        defaultValue: "\(DisplayFormat.count(failed)) connections were taken over and broke straight away, before anything reached the device, so each one was handed back to plain forwarding with nothing lost. Browsing keeps working; nothing is being decrypted.",
                        comment: """
                            Verdict detail when failed terminations were rolled back. The last \
                            sentence is the point: this looks like nothing from the outside.
                            """
                    ),
                    systemImage: "arrow.uturn.backward",
                    role: .warning
                )
                : DiagnosticsHeadline(
                    title: String(
                        localized: "diagnostics.verdict.failing.title",
                        defaultValue: "Inspection is breaking down",
                        comment: "Verdict headline when terminations open and then fail before decrypting."
                    ),
                    detail: String(
                        localized: "diagnostics.verdict.failing.detail",
                        defaultValue: "\(DisplayFormat.count(failed)) connections were taken over and then failed. Those connections are lost and the app that opened them will try again.",
                        comment: """
                            Verdict detail for failed terminations. Says the consequence plainly: unlike \
                            an abandoned candidate, a failed termination costs that connection.
                            """
                    ),
                    systemImage: "exclamationmark.triangle",
                    role: .warning
                )
        }
    }

    // MARK: - Los contadores

    /// Las tablas que sostienen el veredicto.
    ///
    /// Las secciones del relay **no aparecen** si el relay no contestó, en vez de aparecer a cero: un
    /// cero es una afirmación ("no pasó") y aquí no hay nada que afirmar.
    public static func sections(for stats: TunnelStats) -> [DiagnosticsSection] {
        var sections: [DiagnosticsSection] = []
        // El DNS va **el primero** y por delante de la inspección por lo mismo que su aviso va por
        // encima del titular: la inspección es una función que degrada en silencio, y esto es si el
        // dispositivo puede resolver nombres.
        if let resolvers = stats.resolvers {
            sections.append(nameResolutionSection(resolvers))
        }
        if let relay = stats.relay {
            sections.append(inspectionSection(relay))
            sections.append(namesSection(relay))
        }
        sections.append(decryptedSection(stats.pipeline, relay: stats.relay))
        sections.append(recordingSection(stats.pipeline))
        if let relay = stats.relay {
            sections.append(forwardingSection(relay))
        }
        if let problems = problemsSection(stats.pipeline, resolvers: stats.resolvers) {
            sections.append(problems)
        }
        return sections
    }

    /// Si las tres listas del DNS dicen lo mismo.
    ///
    /// Las tres tienen que **existir** para coincidir: una que no se pudo leer no coincide con nada,
    /// y decir que sí borraría precisamente la avería que `ResolverStatus` distingue con tanto cuidado
    /// entre "no había ninguno" y "no se pudo preguntar".
    public static func listing(for resolvers: ResolverStatus) -> ResolverListing {
        guard
            let whenAnnounced = resolvers.reportedWhenAnnounced,
            let now = resolvers.reportedNow,
            whenAnnounced == resolvers.announced,
            now == resolvers.announced
        else {
            return .diverging
        }
        return .agreeing(resolvers.announced)
    }

    /// La tabla del DNS: qué servidores hay en juego y qué ha pasado con ellos al cambiar de red.
    ///
    /// Una lista vacía se dice con palabras y no con un hueco — "ninguno" y "no se pudo leer" son
    /// cosas distintas, y un blanco no sería ninguna de las dos.
    private static func nameResolutionSection(_ resolvers: ResolverStatus) -> DiagnosticsSection {
        var rows: [DiagnosticsRow] = []

        switch listing(for: resolvers) {
        case .agreeing(let addresses):
            rows.append(
                DiagnosticsRow.reading(
                    id: "dns.inUse",
                    label: String(
                        localized: "diagnostics.row.dnsInUse",
                        defaultValue: "Servers in use",
                        comment: """
                            The DNS servers the tunnel announced, shown as one row because the system \
                            reports the same ones. Empty means the device cannot look up names.
                            """
                    ),
                    value: list(addresses)
                )
            )
        case .diverging:
            rows.append(contentsOf: [
                DiagnosticsRow.reading(
                    id: "dns.announced",
                    label: String(
                        localized: "diagnostics.row.dnsAnnounced",
                        defaultValue: "Announced by the tunnel",
                        comment: """
                            The DNS servers the tunnel handed to the system when monitoring started. \
                            Empty here means the device cannot look up names.
                            """
                    ),
                    value: list(resolvers.announced)
                ),
                DiagnosticsRow.reading(
                    id: "dns.reportedWhenAnnounced",
                    label: String(
                        localized: "diagnostics.row.dnsReportedWhenAnnounced",
                        defaultValue: "Reported by the system then",
                        comment: """
                            What the system said its DNS servers were at the moment the tunnel \
                            announced the ones above — at start, or at the last network change.
                            """
                    ),
                    value: list(resolvers.reportedWhenAnnounced)
                ),
                DiagnosticsRow.reading(
                    id: "dns.reportedNow",
                    label: String(
                        localized: "diagnostics.row.dnsReportedNow",
                        defaultValue: "Reported by the system now",
                        comment: """
                            What the system says right now, read again with the tunnel running. It \
                            normally repeats the announced row, because the tunnel is the primary \
                            interface and that is what the system reports.
                            """
                    ),
                    value: list(resolvers.reportedNow)
                )
            ])
        }

        rows.append(contentsOf: [
            DiagnosticsRow.reading(
                id: "dns.networkChanges",
                label: String(
                    localized: "diagnostics.row.dnsNetworkChanges",
                    defaultValue: "Network changes handled",
                    comment: "How many times the device changed network and the tunnel re-announced its DNS."
                ),
                value: DisplayFormat.count(resolvers.networkChanges)
            ),
            DiagnosticsRow.reading(
                id: "dns.resolversRelearned",
                label: String(
                    localized: "diagnostics.row.dnsResolversRelearned",
                    defaultValue: "New servers picked up",
                    comment: """
                        Of those, how many times the re-read produced different DNS servers. Zero \
                        after several network changes means the tunnel cannot see past itself.
                        """
                ),
                value: DisplayFormat.count(resolvers.resolversRelearned)
            ),
            DiagnosticsRow.fault(
                id: "dns.reannounceFailures",
                label: String(
                    localized: "diagnostics.row.dnsReannounceFailures",
                    defaultValue: "Re-announcements that failed",
                    comment: """
                        Network changes where the settings could not be re-applied. It matters \
                        because it leaves the tunnel recording nothing while browsing still works.
                        """
                ),
                count: resolvers.reannounceFailures
            )
        ])

        return DiagnosticsSection(
            id: "dns",
            title: String(
                localized: "diagnostics.section.dns",
                defaultValue: "Name resolution",
                comment: """
                    Section title for the DNS servers the tunnel announced and the ones the system \
                    reports. 'Name resolution' rather than 'DNS' because it says what it is for.
                    """
            ),
            rows: rows,
            note: nameResolutionNote(for: listing(for: resolvers))
        )
    }

    /// Por qué unas veces hay una lista y otras tres.
    ///
    /// Se dice **solo** cuando hay una, porque es entonces cuando falta algo por explicar: con las
    /// tres a la vista, cada fila lleva su nombre y ya dicen lo suyo. Y dice la verdad entera sobre lo
    /// que vale esa coincidencia — que el sistema conteste lo mismo no es una confirmación
    /// independiente, sino la consecuencia de que el túnel sea el interfaz primario — porque venderla
    /// como una segunda opinión sería inventar una comprobación que no se ha hecho.
    private static func nameResolutionNote(for listing: ResolverListing) -> String? {
        switch listing {
        case .diverging:
            return nil
        case .agreeing:
            return String(
                localized: "diagnostics.section.dns.note",
                defaultValue: "While monitoring, the tunnel is this device's main network interface, so the system hands these same servers back when asked. They are listed apart only when they stop matching — which is what a network change the tunnel did not learn looks like.",
                comment: """
                    Footer under the name-resolution section, shown when the announced servers and \
                    both of the system's answers are the same list. It says why one row is enough and \
                    what it would look like if it were not.
                    """
            )
        }
    }

    /// Una lista de direcciones como se lee: separadas por coma, y con palabras donde no hay ninguna.
    private static func list(_ addresses: [String]?) -> String {
        guard let addresses else {
            return String(
                localized: "diagnostics.dns.unreadableValue",
                defaultValue: "Could not be read",
                comment: """
                    Value shown where a list of DNS servers should be when the system could not be \
                    asked at all. It is not the same as having none.
                    """
            )
        }
        guard !addresses.isEmpty else {
            return String(
                localized: "diagnostics.dns.noneValue",
                defaultValue: "None",
                comment: "Value shown where a list of DNS servers should be when there are none."
            )
        }
        // Coma y espacio, no `ListFormatter`: son direcciones y no una enumeración que se lea en voz
        // alta, y el "and" final de un formateador de listas las haría parecer prosa.
        return addresses.joined(separator: ", ")
    }

    private static func inspectionSection(_ relay: RelayStats) -> DiagnosticsSection {
        DiagnosticsSection(
            id: "inspection",
            title: String(
                localized: "diagnostics.section.inspection",
                defaultValue: "Inspection",
                comment: "Section title for the counters of the TLS inspection attempt."
            ),
            rows: [
                DiagnosticsRow.reading(
                    id: "inspection.candidates",
                    label: String(
                        localized: "diagnostics.row.candidates",
                        defaultValue: "Offered for inspection",
                        comment: "Flows routed to inspection. It is the denominator of the rest."
                    ),
                    value: DisplayFormat.count(relay.inspectionCandidates)
                ),
                DiagnosticsRow.reading(
                    id: "inspection.terminationsOpened",
                    label: String(
                        localized: "diagnostics.row.terminationsOpened",
                        defaultValue: "Taken over",
                        comment: "Candidates that ended up with a TLS termination installed."
                    ),
                    value: DisplayFormat.count(relay.terminationsOpened)
                ),
                DiagnosticsRow.reading(
                    id: "inspection.flowsInspected",
                    label: String(
                        localized: "diagnostics.row.flowsInspected",
                        defaultValue: "Decrypted",
                        comment: "Flows decrypted end to end."
                    ),
                    value: DisplayFormat.count(relay.flowsInspected)
                ),
                DiagnosticsRow.reading(
                    id: "inspection.flowsPinned",
                    label: String(
                        localized: "diagnostics.row.flowsPinned",
                        defaultValue: "Not inspectable",
                        comment: """
                            Flows whose client refused the local certificate. The label is the same \
                            word the connection list uses, so the two screens agree.
                            """
                    ),
                    value: DisplayFormat.count(relay.flowsPinned)
                ),
                DiagnosticsRow.reading(
                    id: "inspection.abandoned",
                    label: String(
                        localized: "diagnostics.row.inspectionsAbandoned",
                        defaultValue: "Returned to passthrough",
                        comment: """
                            Candidates handed back to plain forwarding before anything was \
                            terminated. Nothing is lost when this happens.
                            """
                    ),
                    value: DisplayFormat.count(relay.inspectionsAbandoned)
                ),
                DiagnosticsRow.reading(
                    id: "inspection.pinnedHostSkips",
                    label: String(
                        localized: "diagnostics.row.pinnedHostSkips",
                        defaultValue: "Skipped, host already pinned",
                        comment: """
                            Candidates not even attempted because that host had already refused the \
                            certificate in this session.
                            """
                    ),
                    value: DisplayFormat.count(relay.pinnedHostSkips)
                ),
                DiagnosticsRow.fault(
                    id: "inspection.terminationsFailed",
                    label: String(
                        localized: "diagnostics.row.terminationsFailed",
                        defaultValue: "Failed after starting",
                        comment: "Terminations that opened and then broke before finishing."
                    ),
                    count: relay.terminationsFailed
                ),
                DiagnosticsRow.reading(
                    id: "inspection.terminationsRolledBack",
                    label: String(
                        localized: "diagnostics.row.terminationsRolledBack",
                        defaultValue: "Failed early, connection saved",
                        comment: """
                            Of the failures above, the ones undone before the device saw anything, so \
                            the connection survived on plain forwarding.
                            """
                    ),
                    value: DisplayFormat.count(relay.terminationsRolledBack)
                )
            ],
            note: nil
        )
    }

    private static func namesSection(_ relay: RelayStats) -> DiagnosticsSection {
        DiagnosticsSection(
            id: "names",
            title: String(
                localized: "diagnostics.section.names",
                defaultValue: "Names",
                comment: "Section title for how many connections announced the host they called."
            ),
            rows: [
                DiagnosticsRow.reading(
                    id: "names.observed",
                    label: String(
                        localized: "diagnostics.row.sniObserved",
                        defaultValue: "Host announced",
                        comment: "Flows whose ClientHello named the host, which is what the timeline shows."
                    ),
                    value: DisplayFormat.count(relay.sniObserved)
                ),
                DiagnosticsRow.reading(
                    id: "names.unavailable",
                    label: String(
                        localized: "diagnostics.row.sniUnavailable",
                        defaultValue: "No host announced",
                        comment: """
                            Flows to port 443 that never named a host, so the timeline shows their \
                            address instead.
                            """
                    ),
                    value: DisplayFormat.count(relay.sniUnavailable)
                )
            ],
            note: nil
        )
    }

    private static func decryptedSection(_ pipeline: PipelineStats, relay: RelayStats?) -> DiagnosticsSection {
        var rows: [DiagnosticsRow] = []
        if let relay {
            rows.append(
                DiagnosticsRow.reading(
                    id: "decrypted.observed",
                    label: String(
                        localized: "diagnostics.row.plaintextChunksObserved",
                        defaultValue: "Pieces handed over",
                        comment: """
                            Decrypted chunks the termination handed to whoever stores them. Zero with \
                            the recording switch off, which is the default.
                            """
                    ),
                    value: DisplayFormat.count(relay.plaintextChunksObserved)
                )
            )
            rows.append(
                DiagnosticsRow.fault(
                    id: "decrypted.queueDropped",
                    label: String(
                        localized: "diagnostics.row.plaintextChunksDropped",
                        defaultValue: "Lost, disk fell behind",
                        comment: "Chunks the bounded queue could not accept."
                    ),
                    count: relay.plaintextChunksDropped
                )
            )
        }
        rows.append(contentsOf: [
            DiagnosticsRow.reading(
                id: "decrypted.stored",
                label: String(
                    localized: "diagnostics.row.plaintextChunksStored",
                    defaultValue: "Pieces stored",
                    comment: "Decrypted chunks actually written to their file."
                ),
                value: DisplayFormat.count(pipeline.plaintextChunksStored)
            ),
            DiagnosticsRow.reading(
                id: "decrypted.bytesStored",
                label: String(
                    localized: "diagnostics.row.plaintextBytesStored",
                    defaultValue: "Content stored",
                    comment: "How much decrypted content was written."
                ),
                value: DisplayFormat.bytes(pipeline.plaintextBytesStored)
            ),
            DiagnosticsRow.reading(
                id: "decrypted.bytesDropped",
                label: String(
                    localized: "diagnostics.row.plaintextBytesDropped",
                    defaultValue: "Content over the per-connection limit",
                    comment: """
                        Decrypted bytes not kept because that connection had spent its allowance. It \
                        is the size of what the conversation screen cannot show.
                        """
                ),
                value: DisplayFormat.bytes(pipeline.plaintextBytesDropped)
            ),
            DiagnosticsRow.reading(
                id: "decrypted.expired",
                label: String(
                    localized: "diagnostics.row.plaintextChunksExpired",
                    defaultValue: "Pieces expired",
                    comment: "Stored pieces the sweep deleted because they were older than the limit."
                ),
                value: DisplayFormat.count(pipeline.plaintextChunksExpired)
            ),
            DiagnosticsRow.reading(
                id: "decrypted.filesReclaimed",
                label: String(
                    localized: "diagnostics.row.plaintextFilesReclaimed",
                    defaultValue: "Files reclaimed",
                    comment: "Files of decrypted content the sweep deleted from disk."
                ),
                value: DisplayFormat.count(pipeline.plaintextFilesReclaimed)
            ),
            DiagnosticsRow.fault(
                id: "decrypted.failures",
                label: String(
                    localized: "diagnostics.row.plaintextFailures",
                    defaultValue: "Write failures",
                    comment: "Failures writing decrypted content; the first one stops recording for the session."
                ),
                count: pipeline.plaintextFailures
            )
        ])

        return DiagnosticsSection(
            id: "decrypted",
            title: String(
                localized: "diagnostics.section.decrypted",
                defaultValue: "Decrypted content",
                comment: """
                    Section title for what was kept of the decrypted traffic. Same words as the \
                    Settings section that governs it, so the two agree.
                    """
            ),
            rows: rows,
            note: nil
        )
    }

    private static func recordingSection(_ pipeline: PipelineStats) -> DiagnosticsSection {
        DiagnosticsSection(
            id: "recording",
            title: String(
                localized: "diagnostics.section.recording",
                defaultValue: "Recording",
                comment: "Section title for what the tunnel wrote to the history and the capture."
            ),
            rows: [
                DiagnosticsRow.reading(
                    id: "recording.packetsHandled",
                    label: String(
                        localized: "diagnostics.row.packetsHandled",
                        defaultValue: "Packets recorded",
                        comment: "Packets parsed and recorded."
                    ),
                    value: DisplayFormat.count(pipeline.packetsHandled)
                ),
                DiagnosticsRow.reading(
                    id: "recording.bytesHandled",
                    label: String(
                        localized: "diagnostics.row.bytesHandled",
                        defaultValue: "Traffic recorded",
                        comment: "Total IP bytes recorded."
                    ),
                    value: DisplayFormat.bytes(pipeline.bytesHandled)
                ),
                DiagnosticsRow.fault(
                    id: "recording.packetsDropped",
                    label: String(
                        localized: "diagnostics.row.packetsDropped",
                        defaultValue: "Packets skipped",
                        comment: "Packets dropped by the pipeline for any reason."
                    ),
                    count: pipeline.packetsDropped
                ),
                DiagnosticsRow.reading(
                    id: "recording.flowsPersisted",
                    label: String(
                        localized: "diagnostics.row.flowsPersisted",
                        defaultValue: "Connections stored",
                        comment: "Flow rows confirmed by the database."
                    ),
                    value: DisplayFormat.count(pipeline.flowsPersisted)
                ),
                DiagnosticsRow.reading(
                    id: "recording.packetsPersisted",
                    label: String(
                        localized: "diagnostics.row.packetsPersisted",
                        defaultValue: "Packet rows stored",
                        comment: "Packet rows confirmed by the database."
                    ),
                    value: DisplayFormat.count(pipeline.packetsPersisted)
                ),
                DiagnosticsRow.fault(
                    id: "recording.reinjectedDropped",
                    label: String(
                        localized: "diagnostics.row.reinjectedRecordsDropped",
                        defaultValue: "Replies not recorded",
                        comment: """
                            Replies that reached the device but did not make it into the history. \
                            The packet was delivered; what was lost is its row.
                            """
                    ),
                    count: pipeline.reinjectedRecordsDropped
                ),
                DiagnosticsRow.fault(
                    id: "recording.storeFailures",
                    label: String(
                        localized: "diagnostics.row.storeFailures",
                        defaultValue: "Database failures",
                        comment: "Batches lost to a database failure."
                    ),
                    count: pipeline.storeFailures
                ),
                DiagnosticsRow.fault(
                    id: "recording.captureFailures",
                    label: String(
                        localized: "diagnostics.row.captureFailures",
                        defaultValue: "Capture failures",
                        comment: "Capture write failures; the first one turns capture off."
                    ),
                    count: pipeline.captureFailures
                ),
                DiagnosticsRow.reading(
                    id: "recording.capturesReclaimed",
                    label: String(
                        localized: "diagnostics.row.capturesReclaimed",
                        defaultValue: "Captures reclaimed",
                        comment: "Capture files the tunnel deleted to stay under the storage cap."
                    ),
                    value: DisplayFormat.count(pipeline.capturesReclaimed)
                ),
                DiagnosticsRow.fault(
                    id: "recording.retentionFailures",
                    label: String(
                        localized: "diagnostics.row.retentionFailures",
                        defaultValue: "Cleanup failures",
                        comment: "Deletions the tunnel's retention could not perform."
                    ),
                    count: pipeline.retentionFailures
                )
            ],
            note: nil
        )
    }

    private static func forwardingSection(_ relay: RelayStats) -> DiagnosticsSection {
        DiagnosticsSection(
            id: "forwarding",
            title: String(
                localized: "diagnostics.section.forwarding",
                defaultValue: "Forwarding",
                comment: """
                    Section title for the relay's own health: this is what keeps the device online \
                    while the tunnel is on.
                    """
            ),
            rows: [
                DiagnosticsRow.reading(
                    id: "forwarding.tcpFlowsOpened",
                    label: String(
                        localized: "diagnostics.row.tcpFlowsOpened",
                        defaultValue: "TCP connections opened",
                        comment: "TCP flows the relay started tracking."
                    ),
                    value: DisplayFormat.count(relay.tcpFlowsOpened)
                ),
                DiagnosticsRow.reading(
                    id: "forwarding.tcpFlowsClosed",
                    label: String(
                        localized: "diagnostics.row.tcpFlowsClosed",
                        defaultValue: "TCP connections closed",
                        comment: "TCP flows finished and released."
                    ),
                    value: DisplayFormat.count(relay.tcpFlowsClosed)
                ),
                DiagnosticsRow.reading(
                    id: "forwarding.tcpBytesToServer",
                    label: String(
                        localized: "diagnostics.row.tcpBytesToServer",
                        defaultValue: "Sent to servers",
                        comment: "Application bytes written out to the real servers."
                    ),
                    value: DisplayFormat.bytes(relay.tcpBytesToServer)
                ),
                DiagnosticsRow.reading(
                    id: "forwarding.tcpSegmentsReinjected",
                    label: String(
                        localized: "diagnostics.row.tcpSegmentsReinjected",
                        defaultValue: "Segments returned to the device",
                        comment: "TCP segments rebuilt and injected back towards the device."
                    ),
                    value: DisplayFormat.count(relay.tcpSegmentsReinjected)
                ),
                DiagnosticsRow.reading(
                    id: "forwarding.tcpResetsToDevice",
                    label: String(
                        localized: "diagnostics.row.tcpResetsToDevice",
                        defaultValue: "Connections refused",
                        comment: "Resets sent to the device, usually because the server refused."
                    ),
                    value: DisplayFormat.count(relay.tcpResetsToDevice)
                ),
                DiagnosticsRow.reading(
                    id: "forwarding.udpFlowsOpened",
                    label: String(
                        localized: "diagnostics.row.udpFlowsOpened",
                        defaultValue: "UDP conversations",
                        comment: "UDP flows for which an outbound connection was opened."
                    ),
                    value: DisplayFormat.count(relay.udpFlowsOpened)
                ),
                DiagnosticsRow.reading(
                    id: "forwarding.datagramsSentOutbound",
                    label: String(
                        localized: "diagnostics.row.datagramsSentOutbound",
                        defaultValue: "Datagrams sent",
                        comment: "UDP payloads sent to the real server."
                    ),
                    value: DisplayFormat.count(relay.datagramsSentOutbound)
                ),
                DiagnosticsRow.reading(
                    id: "forwarding.datagramsReinjected",
                    label: String(
                        localized: "diagnostics.row.datagramsReinjected",
                        defaultValue: "Datagrams returned",
                        comment: "UDP replies rebuilt and injected back towards the device."
                    ),
                    value: DisplayFormat.count(relay.datagramsReinjected)
                ),
                DiagnosticsRow.reading(
                    id: "forwarding.dnsQueriesSent",
                    label: String(
                        localized: "diagnostics.row.dnsQueriesSent",
                        defaultValue: "Name lookups sent",
                        comment: "DNS queries the device sent through the tunnel."
                    ),
                    value: DisplayFormat.count(relay.dnsQueriesSent)
                ),
                DiagnosticsRow.reading(
                    id: "forwarding.dnsRepliesReceived",
                    label: String(
                        localized: "diagnostics.row.dnsRepliesReceived",
                        defaultValue: "Name lookups answered",
                        comment: """
                            DNS replies that came back. It sits under the queries because the pair is \
                            the point: lookups going out with nothing coming back is why pages hang.
                            """
                    ),
                    value: DisplayFormat.count(relay.dnsRepliesReceived)
                ),
                DiagnosticsRow.reading(
                    id: "forwarding.connectionFailures",
                    label: String(
                        localized: "diagnostics.row.connectionFailures",
                        defaultValue: "Network failures",
                        comment: "Outbound connections that ended on a network failure."
                    ),
                    value: DisplayFormat.count(relay.connectionFailures)
                ),
                DiagnosticsRow.fault(
                    id: "forwarding.emitterFailures",
                    label: String(
                        localized: "diagnostics.row.emitterFailures",
                        defaultValue: "Replies that could not be rebuilt",
                        comment: "Replies lost because the datagram could not be serialised."
                    ),
                    count: relay.emitterFailures
                ),
                DiagnosticsRow.reading(
                    id: "forwarding.unsupportedPackets",
                    label: String(
                        localized: "diagnostics.row.unsupportedPackets",
                        defaultValue: "Packets out of scope",
                        comment: "Packets that were neither TCP nor UDP, so they were not forwarded."
                    ),
                    value: DisplayFormat.count(relay.unsupportedPackets)
                )
            ],
            note: nil
        )
    }

    /// Los últimos errores, y solo los que existen: una fila vacía diría que hubo un fallo sin texto.
    private static func problemsSection(
        _ pipeline: PipelineStats,
        resolvers: ResolverStatus?
    ) -> DiagnosticsSection? {
        var rows: [DiagnosticsRow] = []
        if let error = resolvers?.lastReannounceError {
            rows.append(
                DiagnosticsRow.systemText(
                    id: "problems.reannounce",
                    label: String(
                        localized: "diagnostics.row.lastReannounceError",
                        defaultValue: "Network change",
                        comment: """
                            Label of the last error applying network settings after a network change. \
                            Its consequence is a tunnel that records nothing, so it belongs here.
                            """
                    ),
                    message: error
                )
            )
        }
        if let error = pipeline.lastStoreError {
            rows.append(
                DiagnosticsRow.systemText(
                    id: "problems.store",
                    label: String(
                        localized: "diagnostics.row.lastStoreError",
                        defaultValue: "Database",
                        comment: "Label of the last database error message."
                    ),
                    message: error
                )
            )
        }
        if let error = pipeline.lastCaptureError {
            rows.append(
                DiagnosticsRow.systemText(
                    id: "problems.capture",
                    label: String(
                        localized: "diagnostics.row.lastCaptureError",
                        defaultValue: "Capture",
                        comment: "Label of the last capture error message."
                    ),
                    message: error
                )
            )
        }
        if let error = pipeline.lastRetentionError {
            rows.append(
                DiagnosticsRow.systemText(
                    id: "problems.retention",
                    label: String(
                        localized: "diagnostics.row.lastRetentionError",
                        defaultValue: "Cleanup",
                        comment: "Label of the last retention error message."
                    ),
                    message: error
                )
            )
        }
        if let error = pipeline.lastPlaintextError {
            rows.append(
                DiagnosticsRow.systemText(
                    id: "problems.plaintext",
                    label: String(
                        localized: "diagnostics.row.lastPlaintextError",
                        defaultValue: "Decrypted content",
                        comment: "Label of the last decrypted-content write error message."
                    ),
                    message: error
                )
            )
        }
        guard !rows.isEmpty else { return nil }

        return DiagnosticsSection(
            id: "problems",
            title: String(
                localized: "diagnostics.section.problems",
                defaultValue: "Last errors",
                comment: """
                    Section title for the raw error messages. They are framework text, kept because \
                    they are what someone can quote when asking for help.
                    """
            ),
            rows: rows,
            note: nil
        )
    }
}
