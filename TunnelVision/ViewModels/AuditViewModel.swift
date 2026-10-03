import Foundation
import Observation
import Shared

/// El view model de la pestaña de auditoría (`docs/ux/audit.md`): la capa entre `AuditLibrary` —un
/// **actor**— y las tres pantallas que cuelgan de ella (proyectos, un proyecto, una sesión).
///
/// Es **uno para las tres** y vive en el entorno, no uno por pantalla: lo que las tres enseñan es el
/// mismo dato —qué proyectos hay y cuál de sus sesiones está grabando—, y esa sesión abierta se
/// enseña además en la Dashboard. Con un view model por pantalla, cerrar una sesión en su pantalla
/// dejaría a la lista de detrás y a la Dashboard diciendo que sigue grabando hasta que alguien las
/// refrescara.
///
/// Las condiciones con las que se abre una sesión entran como closures por lo mismo que rotar en
/// `CapturesViewModel`: son lo que no se puede provocar sobre un dispositivo sano (una CA sin
/// confiar, unos ajustes ilegibles), y de ellas cuelga lo que el informe dirá sobre pinning.
@MainActor
@Observable
public final class AuditViewModel {

    // MARK: - Lo que pintan las vistas

    public private(set) var state: AuditState = .idle

    /// Lo último que se leyó. Se guarda entero y no ya compuesto porque de él derivan tres
    /// pantallas distintas; lo que cada una enseña sí se compone **una vez por carga** (abajo).
    public private(set) var overview = AuditOverview(projects: [])

    public private(set) var projectRows: [AuditProjectRow] = []

    /// Lo que la Dashboard dice de la sesión abierta, o `nil` si no hay ninguna.
    public private(set) var recordingBanner: AuditRecordingBanner?

    /// Las condiciones de inspección con las que se abriría una sesión **ahora**. Se leen al abrir
    /// el formulario para enseñarlas antes de grabar, y otra vez al confirmar: entre las dos el
    /// usuario puede haber ido a Ajustes.
    public private(set) var currentInspection: InspectionConditions?

    /// El resultado de la última acción que no salió. Lo descarta el usuario.
    public private(set) var notice: AuditNotice?

    /// Si hay una escritura en curso. Apaga los botones que escriben: dos toques seguidos en
    /// *Start recording* no pueden abrir dos sesiones, pero sí enseñar el error de la segunda.
    public private(set) var isWorking = false

    // MARK: - Lo que se lee al abrir una sesión

    /// La pantalla de sesión que está abierta, compuesta. Es de una sola sesión a la vez porque la
    /// navegación solo enseña una; al entrar en otra se sustituye.
    public private(set) var sessionDisplay: AuditSessionDisplay?

    // MARK: - Dependencias

    private let library: AuditLibrary
    private let environment: @MainActor @Sendable () -> AuditEnvironment
    private let inspection: @Sendable () async -> InspectionConditions
    private let now: @Sendable () -> Date

    public init(
        library: AuditLibrary,
        environment: @escaping @MainActor @Sendable () -> AuditEnvironment,
        inspection: @escaping @Sendable () async -> InspectionConditions,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.library = library
        self.environment = environment
        self.inspection = inspection
        self.now = now
    }

    // MARK: - Carga

    /// Vuelve a leer proyectos y sesiones. La disparan la aparición de la pestaña, la de la
    /// Dashboard, tirar para refrescar y cada escritura de este view model.
    public func refresh() async {
        if overview.projects.isEmpty { state = .loading }
        do {
            apply(try await library.overview())
            state = .loaded
        } catch {
            let classified = AuditLibraryError.classifying(error)
            if overview.projects.isEmpty {
                state = .failed(classified)
            } else {
                state = .loaded
                notice = AuditPresentation.refreshFailed(classified)
            }
        }
    }

    public func perform(_ action: AuditAction) async {
        switch action {
        case .retry:
            await refresh()
        case .newProject:
            // Abrir el formulario es de la vista, que es quien tiene la hoja; aquí no hay nada que
            // hacer salvo no dejar el caso sin atender.
            break
        }
    }

    public func dismissNotice() {
        notice = nil
    }

    // MARK: - Derivados

    public var content: AuditContent {
        AuditPresentation.content(state: state, projectCount: overview.projects.count)
    }

    /// Lo que enseña la pantalla de un proyecto, o `nil` si ya no existe.
    ///
    /// Se compone al pedirlo y no se guarda: la pantalla de un proyecto lo lee una vez por cambio de
    /// `overview` (es `@Observable`), no una vez por fila ni por fotograma.
    public func projectDisplay(id: Int64) -> AuditProjectDisplay? {
        guard let entry = overview.projects.first(where: { $0.id == id }) else { return nil }
        return AuditPresentation.project(entry, recording: overview.recording)
    }

    public func project(id: Int64) -> AuditProjectOverview? {
        overview.projects.first { $0.id == id }
    }

    // MARK: - Proyectos

    /// Guarda un formulario de proyecto: lo crea, o reescribe el que se está editando. Devuelve lo
    /// que el formulario tiene mal —para que la hoja lo señale y se quede abierta— o `nil` si se
    /// guardó o si el fallo no era del formulario (y entonces va al aviso).
    public func save(_ form: AuditProjectForm, editing projectID: Int64?) async -> AuditFormIssue? {
        let draft: AuditProjectDraft
        switch form.draft() {
        case .failure(let issue): return issue
        case .success(let value): draft = value
        }

        await write {
            if let projectID {
                try await library.updateProject(id: projectID, with: draft)
            } else {
                try await library.createProject(draft, at: now())
            }
        }
        return nil
    }

    public func deleteProject(id: Int64) async {
        await write { try await library.deleteProject(id: id) }
    }

    // MARK: - Sesiones

    /// Relee las condiciones de inspección para enseñarlas en el formulario antes de grabar.
    public func prepareSessionForm() async {
        currentInspection = await inspection()
    }

    /// Abre una sesión. Mismo contrato que `save`: devuelve lo que el formulario tiene mal, o `nil`.
    public func startSession(_ form: AuditSessionForm, projectID: Int64) async -> AuditFormIssue? {
        let kind: AuditSessionKind
        switch form.kind() {
        case .failure(let issue): return issue
        case .success(let value): kind = value
        }

        // Las condiciones se releen aquí y no se reutilizan las del formulario: son lo que el
        // informe dará por cierto sobre pinning, y tienen que ser las del instante en que empieza.
        let conditions = await inspection()
        currentInspection = conditions
        let draft = AuditSessionDraft(
            projectID: projectID,
            kind: kind,
            environment: environment(),
            inspection: conditions,
            notes: form.trimmedNotes
        )
        await write { try await library.startSession(draft, at: now()) }
        return nil
    }

    public func endSession(id: Int64) async {
        await write { try await library.endSession(id: id, at: now()) }
        await loadSession(id: id)
    }

    public func deleteSession(id: Int64) async {
        await write { try await library.deleteSession(id: id) }
        if sessionDisplay?.id == id { sessionDisplay = nil }
    }

    /// Pone un marcador con el instante de **ahora**: el del toque, no el de cuando la base de datos
    /// termine de escribir.
    public func addMarker(_ kind: SessionMarkerKind, toSession id: Int64) async {
        let instant = now()
        await write { try await library.addMarker(kind, toSession: id, at: instant) }
        await loadSession(id: id)
    }

    /// Lee lo que la pantalla de una sesión enseña: sus marcadores y cuántas conexiones lleva.
    ///
    /// La dispara la aparición de la pantalla y tirar para refrescar. No hay observación viva: quien
    /// etiqueta es la extensión, en otro proceso, y una cuenta que subiera sola costaría una
    /// consulta periódica para un número que nadie lee al segundo.
    public func loadSession(id: Int64) async {
        guard let session = overview.projects.lazy.flatMap(\.sessions).first(where: { $0.id == id }) else {
            if sessionDisplay?.id == id { sessionDisplay = nil }
            return
        }
        do {
            let activity = try await library.activity(ofSession: id)
            sessionDisplay = AuditPresentation.session(session, activity: activity)
        } catch {
            notice = AuditPresentation.refreshFailed(AuditLibraryError.classifying(error))
        }
    }

    // MARK: - Interno

    /// Una escritura y la relectura que la sigue. Lo que falle va al aviso; la relectura se hace
    /// **también** cuando falla, porque los fallos que una pantalla puede provocar aquí son casi
    /// siempre que lo que se ve ya no es lo que hay (una sesión que otro gesto cerró, un proyecto
    /// que ya no existe).
    private func write(_ work: () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            try await work()
            notice = nil
        } catch {
            notice = AuditPresentation.failed(AuditLibraryError.classifying(error))
        }
        await refresh()
    }

    private func apply(_ fresh: AuditOverview) {
        // No se reescribe con un valor igual: una escritura igual invalida las vistas igualmente
        // (`docs/development/02-coding-standards.md`), y esta lectura se repite en cada aparición.
        guard fresh != overview || state != .loaded else { return }
        overview = fresh
        projectRows = AuditPresentation.projectRows(fresh)
        recordingBanner = AuditPresentation.recordingBanner(fresh)
    }
}
