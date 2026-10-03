import Foundation
import Shared

/// Qué enseña la pestaña de auditoría (`docs/ux/audit.md`) para lo que hay guardado.
///
/// Las decisiones de estas pantallas tampoco son de dibujo: **cuál es la sesión que está grabando**
/// (y por tanto etiquetando todo lo que la extensión vuelca), **qué se puede leer de una sesión sobre
/// pinning** según cómo se grabó, y **qué se pierde al borrar**. Viven aquí, en valores puros, para
/// afirmarlas sin pintar nada — el mismo reparto que `CapturesPresentation`.

/// Lo que el usuario puede hacer desde un hueco de la pantalla.
public enum AuditAction: Sendable, Equatable {
    /// Volver a leer tras un fallo.
    case retry
    /// Crear el primer proyecto, desde el vacío que lo enseña.
    case newProject
}

public typealias AuditPlaceholder = ScreenPlaceholder<AuditAction>

/// En qué punto está la lectura.
public enum AuditState: Sendable, Equatable {
    case idle
    case loading
    case loaded
    case failed(AuditLibraryError)
}

/// El cuerpo de la pantalla raíz. Exhaustivo: cada estado cae en uno y solo uno.
public enum AuditContent: Sendable, Equatable {
    case loading
    case list
    case placeholder(AuditPlaceholder)
}

/// Lo que se le cuenta al usuario tras una acción que no salió, sin tapar lo que estaba mirando.
public struct AuditNotice: Sendable, Equatable {
    public let message: String
    public let diagnostic: String?
    public let role: StatusRole

    public init(message: String, diagnostic: String? = nil, role: StatusRole) {
        self.message = message
        self.diagnostic = diagnostic
        self.role = role
    }
}

/// Una fila de la lista de proyectos.
public struct AuditProjectRow: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let name: String

    /// Cuántas sesiones tiene, en palabras.
    public let detail: String

    /// Si una de sus sesiones está grabando ahora mismo. Es la excepción de la lista, y por eso es
    /// lo único que lleva distintivo (`docs/ux/design-system.md`: el supuesto calla).
    public let isRecording: Bool

    /// Lo que se oye de la fila después del nombre.
    public let accessibilityValue: String

    public init(id: Int64, name: String, detail: String, isRecording: Bool, accessibilityValue: String) {
        self.id = id
        self.name = name
        self.detail = detail
        self.isRecording = isRecording
        self.accessibilityValue = accessibilityValue
    }
}

/// Una fila de la lista de sesiones de un proyecto.
///
/// El instante viaja como `Date`, igual que en `CaptureFileDisplay`: el huso y el formato son del
/// dispositivo y eso lo sabe la vista.
public struct AuditSessionRow: Sendable, Equatable, Identifiable {
    public let id: Int64

    /// La release observada, o que es una baseline.
    public let title: String

    public let startedAt: Date
    public let isRecording: Bool

    public init(id: Int64, title: String, startedAt: Date, isRecording: Bool) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.isRecording = isRecording
    }
}

/// Una entrada de la allowlist tal y como se enseña: el patrón como dato literal y su nota.
public struct AuditAllowlistRow: Sendable, Equatable, Identifiable {
    public var id: String { pattern }
    public let pattern: String
    public let note: String?

    public init(pattern: String, note: String?) {
        self.pattern = pattern
        self.note = note
    }
}

/// Lo que la pantalla de un proyecto enseña, compuesto una vez por carga.
public struct AuditProjectDisplay: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let name: String
    public let bundleIdentifier: String?
    public let sessions: [AuditSessionRow]
    public let allowlist: [AuditAllowlistRow]

    /// Si se puede abrir una sesión ahora. Solo hay una abierta en toda la base de datos, así que la
    /// de **otro** proyecto también lo impide.
    public let canStartSession: Bool

    /// Por qué no se puede, cuando no se puede. Va bajo el botón apagado: un botón que no responde
    /// sin decir por qué se lee como una avería.
    public let startBlockedNote: String?

    public init(
        id: Int64,
        name: String,
        bundleIdentifier: String?,
        sessions: [AuditSessionRow],
        allowlist: [AuditAllowlistRow],
        canStartSession: Bool,
        startBlockedNote: String?
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.sessions = sessions
        self.allowlist = allowlist
        self.canStartSession = canStartSession
        self.startBlockedNote = startBlockedNote
    }
}

/// Qué se puede leer de una sesión sobre **pinning**, según cómo se grabó.
///
/// Sin caso por defecto, como `MonitoringProminence`: una condición nueva en `InspectionConditions`
/// tiene que elegir qué dice de ella la pantalla. Es la misma regla que `supportsPinningEvidence`,
/// pero separando las dos maneras de no cumplirla, porque cada una tiene su salida.
public enum PinningEvidence: Sendable, Equatable {

    /// Inspección encendida y CA confiada: un flujo *not inspectable* dice algo de la app.
    case readable

    /// La inspección estaba apagada: no hubo handshake contra la CA local que nadie pudiera rechazar.
    case inspectionOff

    /// La inspección estaba encendida pero el dispositivo no confiaba en la CA: **toda** app la
    /// rechaza, pinnee o no.
    case certificateUntrusted

    public static func reading(_ conditions: InspectionConditions) -> PinningEvidence {
        guard conditions.inspectionEnabled else { return .inspectionOff }
        guard conditions.caTrusted else { return .certificateUntrusted }
        return .readable
    }
}

/// Lo que la pantalla dice sobre el pinning de una sesión: un titular y la frase que lo explica.
public struct PinningEvidenceDisplay: Sendable, Equatable {
    public let headline: String
    public let detail: String
    public let systemImage: String
    public let role: StatusRole

    public init(headline: String, detail: String, systemImage: String, role: StatusRole) {
        self.headline = headline
        self.detail = detail
        self.systemImage = systemImage
        self.role = role
    }
}

/// Un hecho de la sesión: su etiqueta y su valor. Un instante viaja como `Date` para que lo escriba
/// el dispositivo.
public struct AuditFact: Sendable, Equatable, Identifiable {

    public enum Value: Sendable, Equatable {
        case text(String)
        case instant(Date)
    }

    public var id: String { label }
    public let label: String
    public let value: Value

    public init(label: String, value: Value) {
        self.label = label
        self.value = value
    }
}

/// Un marcador ya puesto.
public struct AuditMarkerRow: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let title: String
    public let date: Date

    public init(id: Int64, title: String, date: Date) {
        self.id = id
        self.title = title
        self.date = date
    }
}

/// Uno de los marcadores con nombre fijo que la pantalla ofrece poner con un toque.
public struct AuditMarkerChoice: Sendable, Equatable, Identifiable {
    public var id: String { title }
    public let kind: SessionMarkerKind
    public let title: String
    public let systemImage: String

    public init(kind: SessionMarkerKind, title: String, systemImage: String) {
        self.kind = kind
        self.title = title
        self.systemImage = systemImage
    }
}

/// Lo que la pantalla de una sesión enseña, compuesto una vez por carga.
public struct AuditSessionDisplay: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let projectID: Int64
    public let title: String
    public let isRecording: Bool

    /// El estado, en una frase: grabando y etiquetando, o terminada.
    public let status: String
    public let statusDetail: String

    /// Cuántas conexiones lleva, que es lo que deja ver que el etiquetado está pasando.
    public let connections: String

    public let facts: [AuditFact]
    public let environment: [AuditFact]
    public let pinning: PinningEvidenceDisplay
    public let markers: [AuditMarkerRow]
    public let notes: String?

    public init(
        id: Int64,
        projectID: Int64,
        title: String,
        isRecording: Bool,
        status: String,
        statusDetail: String,
        connections: String,
        facts: [AuditFact],
        environment: [AuditFact],
        pinning: PinningEvidenceDisplay,
        markers: [AuditMarkerRow],
        notes: String?
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.isRecording = isRecording
        self.status = status
        self.statusDetail = statusDetail
        self.connections = connections
        self.facts = facts
        self.environment = environment
        self.pinning = pinning
        self.markers = markers
        self.notes = notes
    }
}

/// La sesión abierta, dicha donde se ve el túnel (`DashboardView`).
///
/// Existe porque una sesión abierta **etiqueta todo flujo** que la extensión vuelque hasta que
/// alguien la cierre, y una olvidada seguiría haciéndolo durante días sin que nada lo enseñara fuera
/// de su propia pantalla.
public struct AuditRecordingBanner: Sendable, Equatable {
    public let projectID: Int64
    public let sessionID: Int64
    public let title: String
    public let detail: String
    public let actionTitle: String

    public init(projectID: Int64, sessionID: Int64, title: String, detail: String, actionTitle: String) {
        self.projectID = projectID
        self.sessionID = sessionID
        self.title = title
        self.detail = detail
        self.actionTitle = actionTitle
    }
}

public enum AuditPresentation {

    // MARK: - Pantalla raíz

    public static var tabTitle: String {
        String(
            localized: "audit.tab",
            defaultValue: "Audit",
            comment: """
                Tab bar label of the audit screen. Same word as its title, separate key: the tab \
                bar shares its width with four other items, so it may need a shorter form.
                """
        )
    }

    public static var screenTitle: String {
        String(
            localized: "audit.screen.title",
            defaultValue: "Audit",
            comment: """
                Title of the screen listing audit projects: the apps whose network behaviour is \
                being recorded as evidence for a security assessment.
                """
        )
    }

    public static var newProjectActionTitle: String {
        String(
            localized: "audit.action.newProject",
            defaultValue: "New project",
            comment: """
                Button that opens the form to create an audit project. A project is one audited \
                app with its list of allowed domains; it is not a file or a folder.
                """
        )
    }

    public static var projectsSectionTitle: String {
        String(
            localized: "audit.projects.section",
            defaultValue: "Projects",
            comment: "Heading of the list of audit projects on the audit screen."
        )
    }

    public static var projectsFooter: String {
        String(
            localized: "audit.projects.footer",
            defaultValue: """
                A project is one app you audit. Its sessions record what the device sends while \
                you use that app, and are kept until you delete them.
                """,
            comment: """
                Note under the list of audit projects. It says what a project and a session are, \
                and that recorded sessions are exempt from the storage limits in Settings — they \
                only go when the user deletes them.
                """
        )
    }

    /// Las filas de la lista de proyectos, del más reciente al más antiguo (el orden del store).
    public static func projectRows(_ overview: AuditOverview) -> [AuditProjectRow] {
        overview.projects.map { entry in
            let isRecording = entry.sessions.contains(where: \.isOpen)
            let detail = sessionCountText(entry.sessions.count)
            return AuditProjectRow(
                id: entry.project.id,
                name: entry.project.name,
                detail: detail,
                isRecording: isRecording,
                accessibilityValue: isRecording ? recordingRowAccessibilityValue(detail: detail) : detail
            )
        }
    }

    /// Qué cuerpo le toca a la pantalla raíz. Con proyectos se pinta la lista pase lo que pase: un
    /// fallo posterior es un aviso, nunca una tarjeta que tape lo que ya se veía.
    public static func content(state: AuditState, projectCount: Int) -> AuditContent {
        if projectCount > 0 { return .list }

        switch state {
        case .idle, .loading:
            return .loading
        case .failed(let error):
            return .placeholder(failure(error))
        case .loaded:
            return .placeholder(noProjectsYet)
        }
    }

    /// Cuántas sesiones tiene un proyecto. Plural con dos claves hermanas; el cero tiene la suya
    /// porque no es una cantidad sino un estado: todavía no se ha grabado nada.
    private static func sessionCountText(_ count: Int) -> String {
        guard count != 0 else {
            return String(
                localized: "audit.project.sessions.none",
                defaultValue: "No sessions yet",
                comment: """
                    Detail of an audit project that has no recorded session. 'Yet' is load-bearing: \
                    it is the state of a project that was just created, not a fault.
                    """
            )
        }
        guard count != 1 else {
            return String(
                localized: "audit.project.sessions.one",
                defaultValue: "1 session",
                comment: """
                    Detail of an audit project with exactly one recorded session. See the plural \
                    form in the sibling key; a language with more plural forms needs both merged \
                    into one key with catalog variations.
                    """
            )
        }
        return String(
            localized: "audit.project.sessions.other",
            defaultValue: "\(DisplayFormat.count(UInt64(max(count, 0)))) sessions",
            comment: """
                Detail of an audit project with more than one recorded session. The placeholder is \
                the count, already grouped.
                """
        )
    }

    /// El distintivo de lo que está grabando ahora. Es la única excepción de las dos listas.
    public static var recordingBadge: String {
        String(
            localized: "audit.badge.recording",
            defaultValue: "Recording",
            comment: """
                Badge on the audit project or session that is open right now: every connection the \
                device makes is being tagged with it. Same word in both lists.
                """
        )
    }

    private static func recordingRowAccessibilityValue(detail: String) -> String {
        String(
            localized: "audit.project.row.recording.accessibilityValue",
            defaultValue: "Recording now. \(detail)",
            comment: """
                What VoiceOver reads after an audit project's name when one of its sessions is \
                open. The placeholder is the session count sentence ('2 sessions').
                """
        )
    }

    // MARK: - Un proyecto

    /// Lo que enseña la pantalla de un proyecto.
    ///
    /// - Parameter recording: la sesión abierta en **toda** la base de datos, sea de este proyecto o
    ///   de otro: es lo que decide si aquí se puede abrir una.
    public static func project(
        _ entry: AuditProjectOverview,
        recording: (project: AuditProject, session: AuditSession)?
    ) -> AuditProjectDisplay {
        AuditProjectDisplay(
            id: entry.project.id,
            name: entry.project.name,
            bundleIdentifier: entry.project.bundleIdentifier,
            sessions: entry.sessions.map { session in
                AuditSessionRow(
                    id: session.id,
                    title: sessionTitle(session.kind),
                    startedAt: session.startedAt,
                    isRecording: session.isOpen
                )
            },
            allowlist: entry.project.allowlist.map {
                AuditAllowlistRow(pattern: $0.pattern.text, note: $0.note)
            },
            canStartSession: recording == nil,
            startBlockedNote: recording.map { startBlockedNote(recording: $0, viewing: entry.project) }
        )
    }

    /// Cómo se llama una sesión: por la release que observó, o por ser la baseline.
    ///
    /// La versión y el build **identifican** un binario, así que van tal cual se escribieron y por el
    /// camino literal: `2.4.0 (1,870)` sería otro build.
    public static func sessionTitle(_ kind: AuditSessionKind) -> String {
        switch kind {
        case .baseline:
            return String(
                localized: "audit.session.title.baseline",
                defaultValue: "Baseline",
                comment: """
                    Name of an audit session recorded without the audited app installed: the \
                    device's background traffic, against which the app's own sessions are read.
                    """
            )
        case .audit(let release):
            return String(
                localized: "audit.session.title.release",
                defaultValue: "Version \(release.version) (\(release.build))",
                comment: """
                    Name of an audit session: the version and build number of the audited app it \
                    observed, both exactly as the assessor typed them. They identify a binary and \
                    are never reformatted.
                    """
            )
        }
    }

    private static func startBlockedNote(
        recording: (project: AuditProject, session: AuditSession),
        viewing project: AuditProject
    ) -> String {
        guard recording.project.id != project.id else {
            return String(
                localized: "audit.project.start.blocked.own",
                defaultValue: "End the session that is recording before starting another.",
                comment: """
                    Note under the disabled 'Start session' button when this project already has \
                    an open session. Only one audit session can be open at a time.
                    """
            )
        }
        return String(
            localized: "audit.project.start.blocked.other",
            defaultValue: """
                A session of \(recording.project.name) is still recording. End it before starting \
                one here.
                """,
            comment: """
                Note under the disabled 'Start session' button when another project has the open \
                session. The placeholder is that project's name. Only one audit session can be \
                open at a time, across all projects.
                """
        )
    }

    public static var sessionsSectionTitle: String {
        String(
            localized: "audit.project.sessions.section",
            defaultValue: "Sessions",
            comment: "Heading of the list of recorded sessions on an audit project's screen."
        )
    }

    public static var sessionsEmptyNote: String {
        String(
            localized: "audit.project.sessions.empty",
            defaultValue: """
                Record a baseline first, without the audited app installed: it is what tells the \
                app's traffic apart from the rest of the device's.
                """,
            comment: """
                Note shown on an audit project with no sessions. It names the first step of the \
                method: a baseline session recorded without the audited app, which the later \
                sessions are compared against.
                """
        )
    }

    public static var startSessionActionTitle: String {
        String(
            localized: "audit.project.action.startSession",
            defaultValue: "Start session",
            comment: """
                Button on an audit project that opens the form to start recording a session. \
                Recording begins when that form is confirmed, not when this is tapped.
                """
        )
    }

    public static var allowlistSectionTitle: String {
        String(
            localized: "audit.project.allowlist.section",
            defaultValue: "Allowed domains",
            comment: """
                Heading of an audit project's allowlist: the domains the audited app is expected \
                to contact. Anything else it contacts is reported as unexpected.
                """
        )
    }

    public static var allowlistEmptyNote: String {
        String(
            localized: "audit.project.allowlist.empty",
            defaultValue: "No allowed domains. Every connection will be reported as unexpected.",
            comment: """
                Shown in place of an audit project's allowlist when it has no entries. It states \
                the consequence rather than leaving an empty section.
                """
        )
    }

    public static var allowlistFooter: String {
        String(
            localized: "audit.project.allowlist.footer",
            defaultValue: """
                An exact name, or *.example.com for every subdomain. A wildcard does not cover \
                example.com itself.
                """,
            comment: """
                Note under an audit project's allowlist explaining the two accepted forms. \
                '*.example.com' and 'example.com' are literal examples and are not translated. \
                The second sentence is the certificate-wildcard convention and is the rule users \
                get wrong.
                """
        )
    }

    public static var bundleIdentifierLabel: String {
        String(
            localized: "audit.project.bundleIdentifier",
            defaultValue: "Bundle ID",
            comment: """
                Label of the audited app's bundle identifier on an audit project. It is \
                informational: it says what was audited and never filters traffic.
                """
        )
    }

    public static var detailsSectionTitle: String {
        String(
            localized: "audit.project.details.section",
            defaultValue: "Audited app",
            comment: "Heading of the section naming the app an audit project is about."
        )
    }

    public static var bundleIdentifierFooter: String {
        String(
            localized: "audit.project.bundleIdentifier.footer",
            defaultValue: """
                The bundle ID says which app was audited. TunnelVision sees packets, not apps, so \
                it does not filter by it: the baseline session is what separates this app's traffic.
                """,
            comment: """
                Note under the audited app's bundle identifier. It prevents the reading that the \
                identifier filters traffic: the tunnel cannot tell which app sent a packet, and \
                attribution is done by comparing against a baseline session.
                """
        )
    }

    public static var editProjectActionTitle: String {
        String(
            localized: "audit.project.action.edit",
            defaultValue: "Edit project",
            comment: "Menu item that opens the form to change an audit project's name and allowlist."
        )
    }

    public static var deleteProjectActionTitle: String {
        String(
            localized: "audit.project.action.delete",
            defaultValue: "Delete project",
            comment: "Destructive menu item and confirmation button that deletes an audit project."
        )
    }

    public static var projectMenuTitle: String {
        String(
            localized: "audit.project.menu",
            defaultValue: "Project actions",
            comment: """
                Accessibility label of the toolbar menu on an audit project's screen, which is \
                drawn as an ellipsis icon. It holds Edit and Delete.
                """
        )
    }

    public static func deleteProjectDialogTitle(name: String) -> String {
        String(
            localized: "audit.project.delete.title",
            defaultValue: "Delete \(name)?",
            comment: "Title of the confirmation before deleting an audit project. The placeholder is its name."
        )
    }

    /// Qué se pierde al borrar un proyecto. La frase cambia con lo que hay dentro: sin sesiones no
    /// hay evidencia que perder, y decir lo contrario sería una advertencia sin objeto.
    public static func deleteProjectPrompt(sessionCount: Int) -> String {
        guard sessionCount > 0 else {
            return String(
                localized: "audit.project.delete.prompt.empty",
                defaultValue: "Its allowed domains are deleted with it. This can't be undone.",
                comment: """
                    Message of the confirmation before deleting an audit project that has no \
                    sessions: only its allowlist is lost.
                    """
            )
        }
        return String(
            localized: "audit.project.delete.prompt",
            defaultValue: """
                Its sessions, markers and allowed domains are deleted. The connections they \
                recorded stay in your history, but stop being kept as evidence and expire with \
                your storage limits. This can't be undone.
                """,
            comment: """
                Message of the confirmation before deleting an audit project that has sessions. \
                The recorded connections are not deleted — they lose their audit tag, and with it \
                their exemption from the storage limits in Settings.
                """
        )
    }

    // MARK: - Una sesión

    /// Lo que enseña la pantalla de una sesión.
    public static func session(
        _ session: AuditSession,
        activity: AuditSessionActivity
    ) -> AuditSessionDisplay {
        var facts = [
            AuditFact(label: startedLabel, value: .instant(session.startedAt))
        ]
        if let endedAt = session.endedAt {
            facts.append(AuditFact(label: endedLabel, value: .instant(endedAt)))
        }

        let notes = session.notes.trimmingCharacters(in: .whitespacesAndNewlines)

        return AuditSessionDisplay(
            id: session.id,
            projectID: session.projectID,
            title: sessionTitle(session.kind),
            isRecording: session.isOpen,
            status: session.isOpen ? recordingStatus : endedStatus,
            statusDetail: session.isOpen ? recordingStatusDetail : endedStatusDetail,
            connections: connectionCountText(activity.flowCount),
            facts: facts,
            environment: [
                AuditFact(label: deviceLabel, value: .text(session.environment.deviceModel)),
                AuditFact(label: systemLabel, value: .text(session.environment.osVersion)),
                AuditFact(label: toolLabel, value: .text(session.environment.toolVersion)),
            ],
            pinning: pinning(PinningEvidence.reading(session.inspection)),
            markers: activity.markers.map {
                AuditMarkerRow(id: $0.id, title: markerTitle($0.kind), date: $0.date)
            },
            notes: notes.isEmpty ? nil : notes
        )
    }

    private static var recordingStatus: String {
        String(
            localized: "audit.session.status.recording",
            defaultValue: "Recording",
            comment: "Headline of an audit session that is open right now."
        )
    }

    private static var recordingStatusDetail: String {
        String(
            localized: "audit.session.status.recording.detail",
            defaultValue: """
                Every connection this device makes is being tagged with this session until you \
                end it, whichever app makes it.
                """,
            comment: """
                Sentence under the headline of an open audit session. It must say that everything \
                is tagged, not only the audited app's traffic: the tunnel cannot tell apps apart, \
                and a session left open keeps tagging.
                """
        )
    }

    private static var endedStatus: String {
        String(
            localized: "audit.session.status.ended",
            defaultValue: "Ended",
            comment: "Headline of an audit session that has been closed."
        )
    }

    private static var endedStatusDetail: String {
        String(
            localized: "audit.session.status.ended.detail",
            defaultValue: """
                Its connections and captures are kept as evidence, outside your storage limits, \
                until you delete this session.
                """,
            comment: """
                Sentence under the headline of a closed audit session. Audit evidence is exempt \
                from the storage limits set in Settings; deleting the session is what ends that.
                """
        )
    }

    private static func connectionCountText(_ count: Int) -> String {
        guard count != 1 else {
            return String(
                localized: "audit.session.connections.one",
                defaultValue: "1 connection",
                comment: """
                    How many connections an audit session holds, when exactly one. See the plural \
                    form in the sibling key.
                    """
            )
        }
        return String(
            localized: "audit.session.connections.other",
            defaultValue: "\(DisplayFormat.count(UInt64(max(count, 0)))) connections",
            comment: """
                How many connections an audit session holds, for any number other than one, zero \
                included. The placeholder is the count, already grouped.
                """
        )
    }

    public static var connectionsLabel: String {
        String(
            localized: "audit.session.connections.label",
            defaultValue: "Recorded",
            comment: """
                Label of the row saying how many connections an audit session holds. Its value is \
                a count sentence such as '42 connections'.
                """
        )
    }

    private static var startedLabel: String {
        String(
            localized: "audit.session.fact.started",
            defaultValue: "Started",
            comment: "Label of the instant an audit session began. Its value is a date."
        )
    }

    private static var endedLabel: String {
        String(
            localized: "audit.session.fact.ended",
            defaultValue: "Ended",
            comment: "Label of the instant an audit session was closed. Its value is a date."
        )
    }

    private static var deviceLabel: String {
        String(
            localized: "audit.session.fact.device",
            defaultValue: "Device",
            comment: """
                Label of the hardware model identifier an audit session was recorded on, such as \
                'iPhone18,3'.
                """
        )
    }

    private static var systemLabel: String {
        String(
            localized: "audit.session.fact.system",
            defaultValue: "iOS",
            comment: """
                Label of the operating system version an audit session was recorded on. 'iOS' is \
                the product name and is not translated.
                """
        )
    }

    private static var toolLabel: String {
        String(
            localized: "audit.session.fact.tool",
            defaultValue: "TunnelVision",
            comment: """
                Label of the version of this app an audit session was recorded with. \
                'TunnelVision' is the product name and is not translated.
                """
        )
    }

    public static var environmentSectionTitle: String {
        String(
            localized: "audit.session.environment.section",
            defaultValue: "Recorded on",
            comment: """
                Heading of the section listing where an audit session was recorded: device model, \
                system version and the version of this app.
                """
        )
    }

    public static var environmentFooter: String {
        String(
            localized: "audit.session.environment.footer",
            defaultValue: "Read from this device when the session started. It goes into the report as is.",
            comment: """
                Note under the recording environment of an audit session. The values are not \
                typed by the user and cannot be edited.
                """
        )
    }

    public static var pinningSectionTitle: String {
        String(
            localized: "audit.session.pinning.section",
            defaultValue: "Certificate pinning",
            comment: """
                Heading of the section saying whether an audit session can tell if the audited \
                app pins its certificates.
                """
        )
    }

    /// Lo que la sesión puede decir sobre pinning. Solo el caso que **no** permite leerlo lleva
    /// aviso: una sesión grabada sin las condiciones no está rota, pero quien la abra creyendo que
    /// evalúa pinning tiene que enterarse aquí y no en el informe.
    public static func pinning(_ evidence: PinningEvidence) -> PinningEvidenceDisplay {
        switch evidence {
        case .readable:
            return PinningEvidenceDisplay(
                headline: String(
                    localized: "audit.session.pinning.readable.headline",
                    defaultValue: "Can be assessed",
                    comment: """
                        Headline of the pinning section when the session was recorded with HTTPS \
                        inspection on and the local certificate trusted.
                        """
                ),
                detail: String(
                    localized: "audit.session.pinning.readable.detail",
                    defaultValue: """
                        Inspection was on and this device trusted TunnelVision's certificate. A \
                        connection that refused it pins its certificates; one that accepted it \
                        trusts certificates the user installs. Nothing was bypassed to find out.
                        """,
                    comment: """
                        Explains how pinning is read from an audit session: the app either \
                        rejected the user-installed certificate (it pins) or accepted it (it does \
                        not). The last sentence is load-bearing — TunnelVision never defeats \
                        another app's pinning, it only reports the outcome.
                        """
                ),
                systemImage: "checkmark.seal",
                role: .accent
            )

        case .inspectionOff:
            return PinningEvidenceDisplay(
                headline: String(
                    localized: "audit.session.pinning.inspectionOff.headline",
                    defaultValue: "Not assessed",
                    comment: """
                        Headline of the pinning section when the session cannot say anything about \
                        pinning. Never 'passed' or 'failed': nothing was observed.
                        """
                ),
                detail: String(
                    localized: "audit.session.pinning.inspectionOff.detail",
                    defaultValue: """
                        HTTPS inspection was off when this session started, so no app was offered \
                        TunnelVision's certificate and none could refuse it. Turn inspection on \
                        in Settings and record another session to assess pinning.
                        """,
                    comment: """
                        Explains why an audit session recorded with inspection off says nothing \
                        about pinning, and what to do about it. It names the Settings screen.
                        """
                ),
                systemImage: "minus.circle",
                role: .warning
            )

        case .certificateUntrusted:
            return PinningEvidenceDisplay(
                headline: String(
                    localized: "audit.session.pinning.untrusted.headline",
                    defaultValue: "Not assessed",
                    comment: """
                        Headline of the pinning section when the session cannot say anything about \
                        pinning because the local certificate was not trusted. Same word as the \
                        inspection-off case on purpose; separate key because the reason differs.
                        """
                ),
                detail: String(
                    localized: "audit.session.pinning.untrusted.detail",
                    defaultValue: """
                        This device did not trust TunnelVision's certificate when this session \
                        started, so every app refuses it whether it pins or not. Finish the \
                        certificate setup in Settings and record another session.
                        """,
                    comment: """
                        Explains why an audit session recorded without the certificate trusted \
                        says nothing about pinning: a refusal then means nothing about the app.
                        """
                ),
                systemImage: "minus.circle",
                role: .warning
            )
        }
    }

    /// Lo mismo, dicho **antes de grabar**: el formulario de una sesión enseña qué se va a poder leer
    /// de ella, y las frases de arriba hablan en pasado de una sesión que ya empezó. El hecho es otro
    /// —allí es lo que hubo, aquí lo que hay y todavía se puede cambiar—, así que la copia también.
    public static func pinningForecast(_ evidence: PinningEvidence) -> PinningEvidenceDisplay {
        switch evidence {
        case .readable:
            return PinningEvidenceDisplay(
                headline: String(
                    localized: "audit.sessionForm.pinning.readable.headline",
                    defaultValue: "Will be assessed",
                    comment: """
                        Headline in the audit session form, before recording starts, when HTTPS \
                        inspection is on and the local certificate is trusted.
                        """
                ),
                detail: String(
                    localized: "audit.sessionForm.pinning.readable.detail",
                    defaultValue: """
                        Inspection is on and this device trusts TunnelVision's certificate, so \
                        this session will show which connections refuse it.
                        """,
                    comment: """
                        Sentence in the audit session form when the session about to start will \
                        be able to tell whether the audited app pins its certificates.
                        """
                ),
                systemImage: "checkmark.seal",
                role: .accent
            )

        case .inspectionOff:
            return PinningEvidenceDisplay(
                headline: String(
                    localized: "audit.sessionForm.pinning.inspectionOff.headline",
                    defaultValue: "Won't be assessed",
                    comment: """
                        Headline in the audit session form, before recording starts, when the \
                        session will not be able to say anything about pinning.
                        """
                ),
                detail: String(
                    localized: "audit.sessionForm.pinning.inspectionOff.detail",
                    defaultValue: """
                        HTTPS inspection is off, so no app will be offered TunnelVision's \
                        certificate. To assess pinning, turn inspection on in Settings before \
                        you start.
                        """,
                    comment: """
                        Sentence in the audit session form when inspection is off. It is said \
                        before recording because a session cannot be fixed afterwards.
                        """
                ),
                systemImage: "minus.circle",
                role: .warning
            )

        case .certificateUntrusted:
            return PinningEvidenceDisplay(
                headline: String(
                    localized: "audit.sessionForm.pinning.untrusted.headline",
                    defaultValue: "Won't be assessed",
                    comment: """
                        Headline in the audit session form when the local certificate is not \
                        trusted. Same words as the inspection-off case; separate key because the \
                        reason differs.
                        """
                ),
                detail: String(
                    localized: "audit.sessionForm.pinning.untrusted.detail",
                    defaultValue: """
                        This device doesn't trust TunnelVision's certificate, so every app will \
                        refuse it whether it pins or not. To assess pinning, finish the \
                        certificate setup in Settings before you start.
                        """,
                    comment: """
                        Sentence in the audit session form when the local certificate is not \
                        trusted on this device.
                        """
                ),
                systemImage: "minus.circle",
                role: .warning
            )
        }
    }

    public static var markersSectionTitle: String {
        String(
            localized: "audit.session.markers.section",
            defaultValue: "Markers",
            comment: """
                Heading of the list of instants marked inside an audit session, such as the \
                moment the user gave consent in the audited app.
                """
        )
    }

    public static var markersEmptyNote: String {
        String(
            localized: "audit.session.markers.empty",
            defaultValue: "No markers.",
            comment: "Shown in place of the marker list of an audit session that has none."
        )
    }

    /// Qué explica la sección de marcadores, que no es lo mismo grabando que terminada: una sesión
    /// cerrada no admite marcadores, y la pantalla tiene que decir por qué no ofrece ponerlos.
    public static func markersFooter(isRecording: Bool) -> String {
        guard isRecording else {
            return String(
                localized: "audit.session.markers.footer.ended",
                defaultValue: """
                    Markers can only be added while a session is recording: one placed afterwards \
                    would not be an observation.
                    """,
                comment: """
                    Note under the markers of a closed audit session, explaining why none can be \
                    added now.
                    """
            )
        }
        return String(
            localized: "audit.session.markers.footer.recording",
            defaultValue: """
                Mark the moment something happens in the audited app. Every connection is then \
                reported as before or after it — which is how activity before consent is found.
                """,
            comment: """
                Note under the markers of an open audit session. It says what a marker is for: \
                splitting the recorded connections into before and after an event.
                """
        )
    }

    /// Los marcadores con nombre fijo, en el orden en que suelen ocurrir.
    public static var markerChoices: [AuditMarkerChoice] {
        [
            AuditMarkerChoice(
                kind: .consentGiven, title: markerTitle(.consentGiven), systemImage: "hand.thumbsup"
            ),
            AuditMarkerChoice(
                kind: .loggedIn, title: markerTitle(.loggedIn), systemImage: "person.crop.circle.badge.checkmark"
            ),
            AuditMarkerChoice(
                kind: .loggedOut, title: markerTitle(.loggedOut), systemImage: "person.crop.circle.badge.xmark"
            ),
        ]
    }

    /// Cómo se llama un marcador. El libre se enseña con las palabras de quien lo escribió, sin
    /// pasar por el catálogo: no es copia nuestra.
    public static func markerTitle(_ kind: SessionMarkerKind) -> String {
        switch kind {
        case .consentGiven:
            return String(
                localized: "audit.marker.consentGiven",
                defaultValue: "Consent given",
                comment: """
                    Marker of an audit session: the user accepted the audited app's consent \
                    screen at this instant.
                    """
            )
        case .loggedIn:
            return String(
                localized: "audit.marker.loggedIn",
                defaultValue: "Logged in",
                comment: "Marker of an audit session: the user signed in to the audited app at this instant."
            )
        case .loggedOut:
            return String(
                localized: "audit.marker.loggedOut",
                defaultValue: "Logged out",
                comment: "Marker of an audit session: the user signed out of the audited app at this instant."
            )
        case .custom(let label):
            return label
        }
    }

    public static var customMarkerActionTitle: String {
        String(
            localized: "audit.marker.custom.action",
            defaultValue: "Other…",
            comment: """
                Button that asks for the name of a marker the fixed list does not cover. The \
                ellipsis means a prompt follows.
                """
        )
    }

    public static var customMarkerDialogTitle: String {
        String(
            localized: "audit.marker.custom.title",
            defaultValue: "Name this marker",
            comment: "Title of the prompt asking for the label of a free-form audit marker."
        )
    }

    public static var customMarkerFieldPrompt: String {
        String(
            localized: "audit.marker.custom.field",
            defaultValue: "What happened",
            comment: """
                Placeholder of the text field for a free-form audit marker: a few words on what \
                just happened in the audited app.
                """
        )
    }

    public static var customMarkerConfirmTitle: String {
        String(
            localized: "audit.marker.custom.confirm",
            defaultValue: "Add marker",
            comment: "Button that places the free-form audit marker just named, at the current instant."
        )
    }

    public static var addMarkerSectionTitle: String {
        String(
            localized: "audit.session.addMarker.section",
            defaultValue: "Mark now",
            comment: """
                Heading over the buttons that place a marker in an open audit session. 'Now' is \
                load-bearing: the marker is stamped with the instant of the tap.
                """
        )
    }

    public static var notesSectionTitle: String {
        String(
            localized: "audit.session.notes.section",
            defaultValue: "Notes",
            comment: "Heading of the free-text notes written when an audit session was started."
        )
    }

    public static var endSessionActionTitle: String {
        String(
            localized: "audit.session.action.end",
            defaultValue: "End session",
            comment: "Button and confirmation button that closes an open audit session."
        )
    }

    public static var endSessionDialogTitle: String {
        String(
            localized: "audit.session.end.title",
            defaultValue: "End this session?",
            comment: "Title of the confirmation before closing an open audit session."
        )
    }

    public static var endSessionPrompt: String {
        String(
            localized: "audit.session.end.prompt",
            defaultValue: """
                Connections stop being tagged, and no more markers can be added. A session can't \
                be reopened.
                """,
            comment: """
                Message of the confirmation before closing an audit session. Both consequences \
                are irreversible, which is why the action is confirmed.
                """
        )
    }

    public static var deleteSessionActionTitle: String {
        String(
            localized: "audit.session.action.delete",
            defaultValue: "Delete session",
            comment: "Destructive button and confirmation button that deletes an audit session."
        )
    }

    public static var deleteSessionDialogTitle: String {
        String(
            localized: "audit.session.delete.title",
            defaultValue: "Delete this session?",
            comment: "Title of the confirmation before deleting an audit session."
        )
    }

    public static var deleteSessionPrompt: String {
        String(
            localized: "audit.session.delete.prompt",
            defaultValue: """
                The session and its markers are deleted. The connections it recorded stay in \
                your history, but stop being kept as evidence and expire with your storage \
                limits. This can't be undone.
                """,
            comment: """
                Message of the confirmation before deleting an audit session. The recorded \
                connections are not deleted — they lose their audit tag, and with it their \
                exemption from the storage limits in Settings.
                """
        )
    }

    // MARK: - La sesión abierta, donde se ve el túnel

    /// Lo que la Dashboard dice de la sesión abierta, o `nil` si no hay ninguna.
    public static func recordingBanner(_ overview: AuditOverview) -> AuditRecordingBanner? {
        guard let recording = overview.recording else { return nil }
        return AuditRecordingBanner(
            projectID: recording.project.id,
            sessionID: recording.session.id,
            title: String(
                localized: "audit.banner.title",
                defaultValue: "Audit session recording",
                comment: """
                    Headline of the strip shown on the Dashboard while an audit session is open. \
                    It exists so a session left open is noticed where the tunnel is watched.
                    """
            ),
            detail: String(
                localized: "audit.banner.detail",
                defaultValue: "Every connection is being tagged for \(recording.project.name).",
                comment: """
                    Sentence of the Dashboard strip for an open audit session. The placeholder is \
                    the audit project's name. 'Every connection' is load-bearing: all traffic is \
                    tagged, not only the audited app's.
                    """
            ),
            actionTitle: String(
                localized: "audit.banner.action",
                defaultValue: "Open",
                comment: "Button on the Dashboard strip that goes to the open audit session."
            )
        )
    }

    // MARK: - Avisos

    /// Qué contar cuando una acción no salió.
    ///
    /// Las reglas del dominio que la pantalla puede provocar tienen su frase y su salida; el resto
    /// —identificadores que ya no existen, el historial sin responder— son una sola frase con el
    /// detalle aparte, porque no hay nada que el usuario pueda corregir en lo que escribió.
    public static func failed(_ error: AuditLibraryError) -> AuditNotice {
        switch error {
        case .rule(.sessionAlreadyOpen):
            return AuditNotice(
                message: String(
                    localized: "audit.notice.sessionAlreadyOpen",
                    defaultValue: "Another session is still recording. End it before starting a new one.",
                    comment: """
                        Notice when starting an audit session was refused because one is already \
                        open. Only one can be open at a time.
                        """
                ),
                role: .warning
            )

        case .rule(.sessionAlreadyEnded):
            return AuditNotice(
                message: String(
                    localized: "audit.notice.sessionAlreadyEnded",
                    defaultValue: "This session has already ended, so nothing was changed.",
                    comment: """
                        Notice when ending an audit session or adding a marker was refused because \
                        the session is closed — typically ended elsewhere a moment ago.
                        """
                ),
                role: .warning
            )

        case .rule(.projectNotFound), .rule(.sessionNotFound):
            return AuditNotice(
                message: String(
                    localized: "audit.notice.gone",
                    defaultValue: "It no longer exists. The list has been refreshed.",
                    comment: """
                        Notice when an action targeted an audit project or session that was \
                        already deleted.
                        """
                ),
                role: .warning
            )

        case .rule(let rule):
            return AuditNotice(
                message: actionFailedMessage,
                diagnostic: String(describing: rule),
                role: .warning
            )

        case .history(let error):
            return AuditNotice(
                message: actionFailedMessage,
                diagnostic: diagnostic(for: error),
                role: .warning
            )
        }
    }

    private static var actionFailedMessage: String {
        String(
            localized: "audit.notice.failed",
            defaultValue: "That couldn't be saved. Nothing was changed.",
            comment: """
                Notice when an audit action failed for a reason the user cannot fix from the \
                screen. The technical detail travels apart, as a diagnostic.
                """
        )
    }

    /// Un refresco que falló con la lista ya pintada.
    public static func refreshFailed(_ error: AuditLibraryError) -> AuditNotice {
        AuditNotice(
            message: String(
                localized: "audit.notice.refreshFailed",
                defaultValue: "Couldn't re-read your audit projects, so this may be out of date.",
                comment: """
                    Notice when re-reading the audit projects failed while a list was already \
                    drawn. The list stays on screen, so this says what is uncertain about it.
                    """
            ),
            diagnostic: diagnostic(for: error),
            role: .warning
        )
    }

    /// El detalle técnico. **No pasa por el catálogo**, como los demás diagnósticos: es para quien
    /// recibe una captura de pantalla en un informe.
    private static func diagnostic(for error: AuditLibraryError) -> String {
        switch error {
        case .rule(let rule): String(describing: rule)
        case .history(let error): diagnostic(for: error)
        }
    }

    private static func diagnostic(for error: HistoryError) -> String {
        switch error {
        case .corruptData(let detail): detail
        case .queryFailed(let detail): detail
        }
    }

    // MARK: - Huecos

    /// El vacío que **enseña**: no hay proyectos y tampoco hay nada roto.
    private static var noProjectsYet: AuditPlaceholder {
        AuditPlaceholder(
            title: String(
                localized: "audit.empty.title",
                defaultValue: "No audit projects yet",
                comment: """
                    Title of the card shown when there are no audit projects and nothing is wrong. \
                    The audit screen is optional; this must not read as something left undone.
                    """
            ),
            message: String(
                localized: "audit.empty.message",
                defaultValue: """
                    Audit an app's network behaviour: record named sessions for a version and \
                    build, list the domains it may contact, and mark the moment consent is given.
                    """,
                comment: """
                    Message of the empty audit screen. It says what the feature is for in one \
                    sentence — evidence of an app's network behaviour for a security assessment — \
                    without naming any standard.
                    """
            ),
            systemImage: "checklist",
            role: .accent,
            actionTitle: newProjectActionTitle,
            action: .newProject
        )
    }

    private static func failure(_ error: AuditLibraryError) -> AuditPlaceholder {
        AuditPlaceholder(
            title: String(
                localized: "audit.failure.title",
                defaultValue: "Couldn't read your audit projects",
                comment: "Title of the card shown when the audit projects could not be loaded at all."
            ),
            message: String(
                localized: "audit.failure.message",
                defaultValue: "Nothing has been lost: they are stored with your history, which didn't answer.",
                comment: """
                    Message of the card shown when the audit projects could not be loaded. It \
                    reassures that this is a read failure, not data loss.
                    """
            ),
            systemImage: "exclamationmark.triangle",
            role: .warning,
            actionTitle: String(
                localized: "audit.failure.retry",
                defaultValue: "Try again",
                comment: """
                    Button that re-reads the audit projects after a failure. Kept as its own key \
                    like every other screen's retry, so a translator may word it for what is \
                    being retried here.
                    """
            ),
            action: .retry,
            diagnostic: diagnostic(for: error)
        )
    }
}
