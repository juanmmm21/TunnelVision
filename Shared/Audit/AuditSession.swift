import Foundation

/// La release de la app auditada que se observó en una sesión. La pareja completa a propósito: dos
/// builds de la misma versión son binarios distintos, y el diff entre releases compara builds.
public struct AppRelease: Sendable, Hashable {
    public let version: String
    public let build: String

    public init(version: String, build: String) {
        self.version = version
        self.build = build
    }
}

/// Qué papel juega una sesión en la atribución del tráfico (ADR 0008).
///
/// Una `baseline` no lleva release porque se graba **sin** la app auditada: es el ruido de fondo del
/// dispositivo, contra el que se lee la sesión de auditoría. Que el caso no pueda llevar una versión
/// es lo que impide que una baseline acabe en un diff entre releases.
public enum AuditSessionKind: Sendable, Hashable {
    case baseline
    case audit(AppRelease)

    public var release: AppRelease? {
        switch self {
        case .baseline: return nil
        case .audit(let release): return release
        }
    }
}

/// Dónde se grabó la sesión. Va en el informe tal cual: una evidencia sin el dispositivo, el sistema
/// y la versión de la herramienta que la produjo no se puede reproducir.
public struct AuditEnvironment: Sendable, Hashable {
    public let deviceModel: String
    public let osVersion: String
    public let toolVersion: String

    public init(deviceModel: String, osVersion: String, toolVersion: String) {
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.toolVersion = toolVersion
    }
}

/// En qué condiciones de inspección TLS se grabó la sesión.
public struct InspectionConditions: Sendable, Hashable {
    public let inspectionEnabled: Bool
    public let caTrusted: Bool

    public init(inspectionEnabled: Bool, caTrusted: Bool) {
        self.inspectionEnabled = inspectionEnabled
        self.caTrusted = caTrusted
    }

    /// Si de esta sesión se puede leer algo sobre pinning.
    ///
    /// Sin inspección no hay handshake contra la CA local, y con la CA sin confiar **toda** app la
    /// rechaza, pinnee o no: en los dos casos un `notInspectable` no dice nada de la app, y el informe
    /// tiene que decir que no se evaluó en vez de dar el pinning por observado.
    public var supportsPinningEvidence: Bool { inspectionEnabled && caTrusted }
}

/// Una sesión de auditoría: una grabación con nombre, de un proyecto, en unas condiciones declaradas.
///
/// No confundir con la **sesión de captura** del `FlowStore` (la columna `session` de `flows`), que
/// es el instante de apertura del store y solo existe para que una 5-tupla reciclada no fusione dos
/// conexiones. Una sesión de auditoría la abre y la cierra una persona, y puede abarcar varias de
/// aquellas.
public struct AuditSession: Sendable, Hashable, Identifiable {

    /// `rowid` de la sesión: lo que llevan los flujos que se vieron mientras estuvo abierta.
    public let id: Int64

    public let projectID: Int64
    public let kind: AuditSessionKind
    public let environment: AuditEnvironment
    public let inspection: InspectionConditions
    public let startedAt: Date

    /// `nil` mientras la sesión sigue abierta.
    public let endedAt: Date?

    public let notes: String

    public init(
        id: Int64,
        projectID: Int64,
        kind: AuditSessionKind,
        environment: AuditEnvironment,
        inspection: InspectionConditions,
        startedAt: Date,
        endedAt: Date?,
        notes: String
    ) {
        self.id = id
        self.projectID = projectID
        self.kind = kind
        self.environment = environment
        self.inspection = inspection
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.notes = notes
    }

    public var isOpen: Bool { endedAt == nil }
}

/// Lo que hace falta para abrir una sesión: todo menos lo que asigna el store y cuándo empieza.
public struct AuditSessionDraft: Sendable, Hashable {
    public let projectID: Int64
    public let kind: AuditSessionKind
    public let environment: AuditEnvironment
    public let inspection: InspectionConditions
    public let notes: String

    public init(
        projectID: Int64,
        kind: AuditSessionKind,
        environment: AuditEnvironment,
        inspection: InspectionConditions,
        notes: String
    ) {
        self.projectID = projectID
        self.kind = kind
        self.environment = environment
        self.inspection = inspection
        self.notes = notes
    }
}

/// Qué pasó en la app auditada en un instante de la sesión.
public enum SessionMarkerKind: Sendable, Hashable {
    case consentGiven
    case loggedIn
    case loggedOut
    case custom(String)
}

/// Un instante señalado dentro de una sesión. Es lo que hace contestable «¿hubo actividad de red
/// antes del consentimiento?»: cada flujo queda antes o después del marcador `consentGiven`.
public struct SessionMarker: Sendable, Hashable, Identifiable {
    public let id: Int64
    public let sessionID: Int64
    public let date: Date
    public let kind: SessionMarkerKind

    public init(id: Int64, sessionID: Int64, date: Date, kind: SessionMarkerKind) {
        self.id = id
        self.sessionID = sessionID
        self.date = date
        self.kind = kind
    }
}

/// La sesión que está grabando, con el nombre de su proyecto: lo que hace falta para decir *en qué*
/// se va a marcar sin leer el proyecto entero (su allowlist puede tener decenas de entradas, y quien
/// lo pregunta es un control del sistema con el presupuesto de una extensión de widgets).
public struct AuditRecording: Sendable, Hashable {
    public let session: AuditSession
    public let projectName: String

    public init(session: AuditSession, projectName: String) {
        self.session = session
        self.projectName = projectName
    }
}

/// Lo que pasó al marcar «en la sesión abierta» sin saber de antemano cuál es — el gesto de quien
/// marca desde fuera de la app (`docs/spec/audit.md` § *Marking from outside the app*).
///
/// Que no haya sesión es un **desenlace** y no un error: es la respuesta esperable de un botón que
/// se puede pulsar en cualquier momento, y quien la recibe está obligado a decirla. Un marcador que
/// no se puso y que el evaluador cree puesto es peor que un fallo.
public enum OpenSessionMarkerOutcome: Sendable, Hashable {
    case placed(SessionMarker, in: AuditRecording)
    case noOpenSession
}
