import Foundation
import GRDB

/// Lo que puede salir mal al escribir un proyecto, una sesión o un marcador de auditoría. Va aparte
/// de `FlowStore.StoreError` porque aquéllos son fallos del almacén y éstos son reglas del dominio
/// que una pantalla tiene que poder contarle a quien las ha incumplido.
public enum AuditStoreError: Error, Sendable, Equatable {
    case emptyProjectName
    /// El mismo patrón dos veces en la allowlist de un borrador (ya normalizado).
    case duplicateAllowlistPattern(String)
    case projectNotFound(Int64)
    case sessionNotFound(Int64)
    /// Ya hay una sesión abierta, y solo puede haber una: lleva su identificador para poder
    /// ofrecer cerrarla.
    case sessionAlreadyOpen(Int64)
    case sessionAlreadyEnded(Int64)
    /// Un final o un marcador fechado antes del principio de su sesión.
    case dateBeforeSessionStart
    case emptyMarkerLabel
}

/// La mitad de auditoría del store (esquema `v6`, ADR 0008): proyectos con su allowlist, sesiones con
/// nombre y marcadores. La escribe la **app**; la extensión solo la lee de pasada, dentro de
/// `upsertFlow`, para etiquetar cada flujo con la sesión abierta.
extension FlowStore {

    // MARK: - Proyectos

    public func createAuditProject(_ draft: AuditProjectDraft, at date: Date) throws -> AuditProject {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AuditStoreError.emptyProjectName }
        var seen: Set<DomainPattern> = []
        for entry in draft.allowlist where !seen.insert(entry.pattern).inserted {
            throw AuditStoreError.duplicateAllowlistPattern(entry.pattern.text)
        }

        let createdAt = WallClock.nanosecondsSince1970(from: date)
        return try dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO audit_projects (name, bundle_id, catalogue_version, created_at)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [name, draft.bundleIdentifier, draft.catalogueVersion, createdAt]
            )
            let projectID = db.lastInsertedRowID
            let statement = try db.makeStatement(
                sql: "INSERT INTO audit_allowlist (project_id, position, pattern, note) VALUES (?, ?, ?, ?)"
            )
            for (position, entry) in draft.allowlist.enumerated() {
                try statement.execute(arguments: [projectID, position, entry.pattern.text, entry.note])
            }
            return AuditProject(
                id: projectID,
                name: name,
                bundleIdentifier: draft.bundleIdentifier,
                catalogueVersion: draft.catalogueVersion,
                allowlist: draft.allowlist,
                // Lo que se devuelve es lo que quedó en disco, no la `Date` de entrada: así quien
                // crea y quien relee ven el mismo instante.
                createdAt: WallClock.date(fromNanosecondsSince1970: createdAt)
            )
        }
    }

    /// Todos los proyectos, el más reciente primero.
    public func auditProjects() throws -> [AuditProject] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT * FROM audit_projects ORDER BY created_at DESC, id DESC"
            )
            return try rows.map { try AuditSerialization.project(from: $0, in: db) }
        }
    }

    public func auditProject(id: Int64) throws -> AuditProject? {
        try dbPool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM audit_projects WHERE id = ?", arguments: [id])
                .map { try AuditSerialization.project(from: $0, in: db) }
        }
    }

    /// Borra un proyecto con su allowlist, sus sesiones y los marcadores de éstas. Los **flujos** que
    /// llevaban sus sesiones se quedan en el historial, sin etiqueta.
    public func deleteAuditProject(id: Int64) throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM audit_projects WHERE id = ?", arguments: [id])
            guard db.changesCount > 0 else { throw AuditStoreError.projectNotFound(id) }
        }
    }

    // MARK: - Sesiones

    /// Abre una sesión. Desde este instante, cada flujo que la extensión vuelque queda etiquetado
    /// con ella hasta que se cierre.
    public func startAuditSession(_ draft: AuditSessionDraft, at date: Date) throws -> AuditSession {
        let startedAt = WallClock.nanosecondsSince1970(from: date)
        return try dbPool.write { db in
            guard try Bool.fetchOne(
                db, sql: "SELECT EXISTS (SELECT 1 FROM audit_projects WHERE id = ?)", arguments: [draft.projectID]
            ) == true else {
                throw AuditStoreError.projectNotFound(draft.projectID)
            }
            // El índice único del esquema ya lo impediría, pero con un error de SQLite que no dice
            // cuál es la sesión que estorba.
            if let open = try Int64.fetchOne(db, sql: "SELECT id FROM audit_sessions WHERE ended_at IS NULL") {
                throw AuditStoreError.sessionAlreadyOpen(open)
            }
            try db.execute(
                sql: """
                INSERT INTO audit_sessions
                    (project_id, kind, app_version, build_number, device_model, os_version, tool_version,
                     inspection_enabled, ca_trusted, started_at, ended_at, notes)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?)
                """,
                arguments: [
                    draft.projectID,
                    AuditSerialization.rawValue(of: draft.kind),
                    draft.kind.release?.version, draft.kind.release?.build,
                    draft.environment.deviceModel, draft.environment.osVersion, draft.environment.toolVersion,
                    draft.inspection.inspectionEnabled, draft.inspection.caTrusted,
                    startedAt, draft.notes,
                ]
            )
            return AuditSession(
                id: db.lastInsertedRowID,
                projectID: draft.projectID,
                kind: draft.kind,
                environment: draft.environment,
                inspection: draft.inspection,
                startedAt: WallClock.date(fromNanosecondsSince1970: startedAt),
                endedAt: nil,
                notes: draft.notes
            )
        }
    }

    /// Cierra una sesión. Los flujos nuevos dejan de etiquetarse; los que ya lo estaban lo siguen
    /// estando, aunque sigan vivos.
    public func endAuditSession(id: Int64, at date: Date) throws -> AuditSession {
        let endedAt = WallClock.nanosecondsSince1970(from: date)
        return try dbPool.write { db in
            let session = try AuditSerialization.requireSession(id: id, in: db)
            guard session.isOpen else { throw AuditStoreError.sessionAlreadyEnded(id) }
            guard endedAt >= WallClock.nanosecondsSince1970(from: session.startedAt) else {
                throw AuditStoreError.dateBeforeSessionStart
            }
            try db.execute(
                sql: "UPDATE audit_sessions SET ended_at = ? WHERE id = ?", arguments: [endedAt, id]
            )
            return try AuditSerialization.requireSession(id: id, in: db)
        }
    }

    /// La sesión abierta, o `nil` si no hay ninguna. Nunca hay más de una.
    public func openAuditSession() throws -> AuditSession? {
        try dbPool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM audit_sessions WHERE ended_at IS NULL")
                .map(AuditSerialization.session(from:))
        }
    }

    public func auditSession(id: Int64) throws -> AuditSession? {
        try dbPool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM audit_sessions WHERE id = ?", arguments: [id])
                .map(AuditSerialization.session(from:))
        }
    }

    /// Las sesiones de un proyecto, la más reciente primero.
    public func auditSessions(forProject projectID: Int64) throws -> [AuditSession] {
        try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM audit_sessions WHERE project_id = ? ORDER BY started_at DESC, id DESC",
                arguments: [projectID]
            ).map(AuditSerialization.session(from:))
        }
    }

    // MARK: - Marcadores

    /// Señala un instante de una sesión **abierta**. Sobre una cerrada es un error y no una
    /// corrección tardía: un marcador puesto después de mirar el tráfico ya no es una observación.
    public func addMarker(
        _ kind: SessionMarkerKind, toSession sessionID: Int64, at date: Date
    ) throws -> SessionMarker {
        var stored = kind
        if case .custom(let label) = kind {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw AuditStoreError.emptyMarkerLabel }
            stored = .custom(trimmed)
        }
        let timestamp = WallClock.nanosecondsSince1970(from: date)
        return try dbPool.write { [stored] db in
            let session = try AuditSerialization.requireSession(id: sessionID, in: db)
            guard session.isOpen else { throw AuditStoreError.sessionAlreadyEnded(sessionID) }
            guard timestamp >= WallClock.nanosecondsSince1970(from: session.startedAt) else {
                throw AuditStoreError.dateBeforeSessionStart
            }
            let (rawKind, label) = AuditSerialization.columns(of: stored)
            try db.execute(
                sql: "INSERT INTO audit_markers (session_id, ts, kind, label) VALUES (?, ?, ?, ?)",
                arguments: [sessionID, timestamp, rawKind, label]
            )
            return SessionMarker(
                id: db.lastInsertedRowID,
                sessionID: sessionID,
                date: WallClock.date(fromNanosecondsSince1970: timestamp),
                kind: stored
            )
        }
    }

    /// Los marcadores de una sesión, en el orden en que ocurrieron.
    public func markers(forSession sessionID: Int64) throws -> [SessionMarker] {
        try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM audit_markers WHERE session_id = ? ORDER BY ts ASC, id ASC",
                arguments: [sessionID]
            ).map(AuditSerialization.marker(from:))
        }
    }
}

/// Conversión entre los tipos de auditoría y sus columnas. Los valores crudos de los enums viven
/// **aquí** y no en los tipos: son formato de disco, y un caso con valor asociado no puede llevar
/// `rawValue` de todos modos.
private enum AuditSerialization {

    private static let sessionKindAudit = 0
    private static let sessionKindBaseline = 1

    private static let markerConsentGiven = 0
    private static let markerLoggedIn = 1
    private static let markerLoggedOut = 2
    private static let markerCustom = 3

    static func rawValue(of kind: AuditSessionKind) -> Int {
        switch kind {
        case .audit: return sessionKindAudit
        case .baseline: return sessionKindBaseline
        }
    }

    static func columns(of kind: SessionMarkerKind) -> (kind: Int, label: String?) {
        switch kind {
        case .consentGiven: return (markerConsentGiven, nil)
        case .loggedIn: return (markerLoggedIn, nil)
        case .loggedOut: return (markerLoggedOut, nil)
        case .custom(let label): return (markerCustom, label)
        }
    }

    static func project(from row: Row, in db: Database) throws -> AuditProject {
        let id: Int64 = row["id"]
        let entries = try Row.fetchAll(
            db,
            sql: "SELECT pattern, note FROM audit_allowlist WHERE project_id = ? ORDER BY position ASC, id ASC",
            arguments: [id]
        ).map { entry -> AllowlistEntry in
            let text: String = entry["pattern"]
            do {
                return AllowlistEntry(pattern: try DomainPattern(parsing: text), note: entry["note"])
            } catch {
                throw FlowStore.StoreError.corruptRow("patrón de allowlist ilegible: \(text)")
            }
        }
        return AuditProject(
            id: id,
            name: row["name"],
            bundleIdentifier: row["bundle_id"],
            catalogueVersion: row["catalogue_version"],
            allowlist: entries,
            createdAt: WallClock.date(fromNanosecondsSince1970: row["created_at"])
        )
    }

    static func requireSession(id: Int64, in db: Database) throws -> AuditSession {
        guard let row = try Row.fetchOne(
            db, sql: "SELECT * FROM audit_sessions WHERE id = ?", arguments: [id]
        ) else {
            throw AuditStoreError.sessionNotFound(id)
        }
        return try session(from: row)
    }

    static func session(from row: Row) throws -> AuditSession {
        let id: Int64 = row["id"]
        let rawKind: Int = row["kind"]
        let version: String? = row["app_version"]
        let build: String? = row["build_number"]

        let kind: AuditSessionKind
        switch rawKind {
        case sessionKindBaseline:
            kind = .baseline
        case sessionKindAudit:
            guard let version, let build else {
                throw FlowStore.StoreError.corruptRow("sesión de auditoría \(id) sin versión o build")
            }
            kind = .audit(AppRelease(version: version, build: build))
        default:
            throw FlowStore.StoreError.corruptRow("tipo de sesión de auditoría inválido: \(rawKind)")
        }

        let endedAt: Int64? = row["ended_at"]
        return AuditSession(
            id: id,
            projectID: row["project_id"],
            kind: kind,
            environment: AuditEnvironment(
                deviceModel: row["device_model"],
                osVersion: row["os_version"],
                toolVersion: row["tool_version"]
            ),
            inspection: InspectionConditions(
                inspectionEnabled: row["inspection_enabled"],
                caTrusted: row["ca_trusted"]
            ),
            startedAt: WallClock.date(fromNanosecondsSince1970: row["started_at"]),
            endedAt: endedAt.map(WallClock.date(fromNanosecondsSince1970:)),
            notes: row["notes"]
        )
    }

    static func marker(from row: Row) throws -> SessionMarker {
        let rawKind: Int = row["kind"]
        let label: String? = row["label"]

        let kind: SessionMarkerKind
        switch rawKind {
        case markerConsentGiven: kind = .consentGiven
        case markerLoggedIn: kind = .loggedIn
        case markerLoggedOut: kind = .loggedOut
        case markerCustom:
            guard let label else {
                throw FlowStore.StoreError.corruptRow("marcador libre sin etiqueta")
            }
            kind = .custom(label)
        default:
            throw FlowStore.StoreError.corruptRow("tipo de marcador inválido: \(rawKind)")
        }
        return SessionMarker(
            id: row["id"],
            sessionID: row["session_id"],
            date: WallClock.date(fromNanosecondsSince1970: row["ts"]),
            kind: kind
        )
    }
}
