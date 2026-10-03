import Foundation

/// Lo que se audita: una app, la allowlist de dominios contra la que se juzgan sus conexiones y el
/// catálogo de requisitos contra el que se evalúa. Todas las sesiones de un proyecto comparten esa
/// allowlist, que es lo que permite comparar dos releases entre sí.
public struct AuditProject: Sendable, Hashable, Identifiable {

    /// `rowid` del proyecto.
    public let id: Int64

    public let name: String

    /// El bundle identifier de la app auditada. **Informativo**: dice qué se auditó, nunca filtra
    /// tráfico — el túnel ve paquetes, no procesos (ADR 0008).
    public let bundleIdentifier: String?

    /// El catálogo de requisitos contra el que se evalúa, o `nil` si todavía no se ha elegido
    /// ninguno. Es un identificador de recurso, no un texto libre que se enseñe.
    public let catalogueVersion: String?

    /// En el orden en que se escribió, que es el orden en que el evaluador la pensó.
    public let allowlist: [AllowlistEntry]

    public let createdAt: Date

    public init(
        id: Int64,
        name: String,
        bundleIdentifier: String?,
        catalogueVersion: String?,
        allowlist: [AllowlistEntry],
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.catalogueVersion = catalogueVersion
        self.allowlist = allowlist
        self.createdAt = createdAt
    }

    /// La primera entrada de la allowlist que cubre un nombre observado, o `nil` si ninguna lo hace.
    /// Devuelve la entrada y no un `Bool` porque el informe cita **por qué** una conexión es esperada.
    public func allowlistEntry(matching host: String) -> AllowlistEntry? {
        allowlist.first { $0.pattern.matches(host) }
    }
}

/// Lo que hace falta para crear un proyecto: todo menos lo que asigna el store.
public struct AuditProjectDraft: Sendable, Hashable {
    public let name: String
    public let bundleIdentifier: String?
    public let catalogueVersion: String?
    public let allowlist: [AllowlistEntry]

    public init(
        name: String,
        bundleIdentifier: String?,
        catalogueVersion: String?,
        allowlist: [AllowlistEntry]
    ) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.catalogueVersion = catalogueVersion
        self.allowlist = allowlist
    }
}
