import Foundation
import Shared

/// Lo que puede salir mal al leer o escribir la auditoría, ya separado en las dos cosas que la
/// pantalla cuenta de forma distinta.
public enum AuditLibraryError: Error, Sendable, Equatable {

    /// Una regla del dominio: lo que se pidió no se puede hacer, y tiene arreglo desde la pantalla
    /// (cerrar la sesión abierta, corregir un patrón).
    case rule(AuditStoreError)

    /// El historial no respondió. No es culpa de lo que se pidió.
    case history(HistoryError)

    static func classifying(_ error: any Error) -> AuditLibraryError {
        if let libraryError = error as? AuditLibraryError { return libraryError }
        if let rule = error as? AuditStoreError { return .rule(rule) }
        return .history(HistoryError.classifying(error))
    }
}

/// Un proyecto con sus sesiones, de la más reciente a la más antigua.
public struct AuditProjectOverview: Sendable, Equatable, Identifiable {
    public var id: Int64 { project.id }
    public let project: AuditProject
    public let sessions: [AuditSession]

    public init(project: AuditProject, sessions: [AuditSession]) {
        self.project = project
        self.sessions = sessions
    }
}

/// Todo lo que la pestaña de auditoría enseña, leído de una vez.
public struct AuditOverview: Sendable, Equatable {

    /// Del proyecto más reciente al más antiguo.
    public let projects: [AuditProjectOverview]

    public init(projects: [AuditProjectOverview]) {
        self.projects = projects
    }

    /// La sesión que está grabando ahora mismo, con su proyecto. Nunca hay más de una
    /// (`docs/spec/audit.md`), así que la primera que aparezca es la única.
    public var recording: (project: AuditProject, session: AuditSession)? {
        for overview in projects {
            if let session = overview.sessions.first(where: \.isOpen) {
                return (overview.project, session)
            }
        }
        return nil
    }
}

/// Lo que solo se lee al abrir una sesión: sus marcadores y cuántas conexiones lleva.
public struct AuditSessionActivity: Sendable, Equatable {
    public let markers: [SessionMarker]
    public let flowCount: Int

    public init(markers: [SessionMarker], flowCount: Int) {
        self.markers = markers
        self.flowCount = flowCount
    }
}

/// La auditoría vista desde la app: proyectos, sesiones y marcadores sobre el `FlowStore` compartido.
///
/// Es un `actor` y **abre el store en cada operación**, por lo mismo que `StorageManager`: lo que
/// hay aquí nace de gestos del usuario, una conexión viva toda la vida de la app no compra nada, y
/// una apertura fallida guardada pegaría ese fallo a la pantalla para siempre. Lo único que añade
/// sobre el store es clasificar lo que lanza, para que por encima no viaje un error sin tipar.
public actor AuditLibrary {

    private let openStore: @Sendable () throws -> FlowStore

    public init(openingStore: @escaping @Sendable () throws -> FlowStore) {
        self.openStore = openingStore
    }

    public init(appGroupID: String = AppGroup.identifier) {
        self.init(openingStore: { try FlowStore(appGroupID: appGroupID) })
    }

    // MARK: - Lectura

    public func overview() async throws -> AuditOverview {
        try await perform { store in
            var projects: [AuditProjectOverview] = []
            for project in try await store.auditProjects() {
                projects.append(
                    AuditProjectOverview(
                        project: project,
                        sessions: try await store.auditSessions(forProject: project.id)
                    )
                )
            }
            return AuditOverview(projects: projects)
        }
    }

    public func activity(ofSession id: Int64) async throws -> AuditSessionActivity {
        try await perform { store in
            AuditSessionActivity(
                markers: try await store.markers(forSession: id),
                flowCount: try await store.flowCount(inAuditSession: id)
            )
        }
    }

    // MARK: - Proyectos

    @discardableResult
    public func createProject(_ draft: AuditProjectDraft, at date: Date) async throws -> AuditProject {
        try await perform { try await $0.createAuditProject(draft, at: date) }
    }

    @discardableResult
    public func updateProject(id: Int64, with draft: AuditProjectDraft) async throws -> AuditProject {
        try await perform { try await $0.updateAuditProject(id: id, with: draft) }
    }

    public func deleteProject(id: Int64) async throws {
        try await perform { try await $0.deleteAuditProject(id: id) }
    }

    // MARK: - Sesiones

    @discardableResult
    public func startSession(_ draft: AuditSessionDraft, at date: Date) async throws -> AuditSession {
        try await perform { try await $0.startAuditSession(draft, at: date) }
    }

    @discardableResult
    public func endSession(id: Int64, at date: Date) async throws -> AuditSession {
        try await perform { try await $0.endAuditSession(id: id, at: date) }
    }

    public func deleteSession(id: Int64) async throws {
        try await perform { try await $0.deleteAuditSession(id: id) }
    }

    @discardableResult
    public func addMarker(
        _ kind: SessionMarkerKind, toSession id: Int64, at date: Date
    ) async throws -> SessionMarker {
        try await perform { try await $0.addMarker(kind, toSession: id, at: date) }
    }

    // MARK: - Interno

    /// Abre el store, hace el trabajo y clasifica lo que salga mal. Abrir es parte de la operación:
    /// un historial que no se deja abrir tiene que llegar tipado igual que una consulta que falla.
    private func perform<Value: Sendable>(
        _ work: (FlowStore) async throws -> Value
    ) async throws -> Value {
        do {
            return try await work(try openStore())
        } catch {
            throw AuditLibraryError.classifying(error)
        }
    }
}
