import Foundation
import Shared

/// Lo que pasó al marcar desde fuera de la app, ya reducido a lo que hay que **decir**.
enum AuditMarkerReport: Sendable, Equatable {

    /// El marcador está escrito.
    case placed(title: String, date: Date, projectName: String)

    /// No hay ninguna sesión grabando: no se puso nada.
    case noOpenSession

    /// La base de datos no respondió, o rechazó el marcador: no se puso nada.
    case notPlaced
}

/// Lo que el control enseña **antes** de que nadie lo pulse.
enum AuditMarkerControlState: Sendable, Equatable {
    case recording(projectName: String)
    case idle
    case unavailable
}

/// Marcar en la sesión abierta sobre el `FlowStore` compartido, desde el proceso que sea.
///
/// El intent que lo usa corre en la app (Atajos, Siri) o en la extensión de widgets (el control), y
/// **da igual cuál**: lo único que necesita es la base de datos del App Group, que los dos tienen. Por
/// eso no pasa por `AuditLibrary`, que es de la app, y por eso abre el store en cada operación — no
/// hay proceso de larga vida que lo guarde.
///
/// No lanza: todo lo que puede salir mal acaba en un desenlace con su frase, porque quien llama es un
/// botón del sistema y lo único que no puede hacer es callarse.
struct OpenSessionMarking: Sendable {

    private let openStore: @Sendable () throws -> FlowStore

    init(openingStore: @escaping @Sendable () throws -> FlowStore) {
        self.openStore = openingStore
    }

    /// El store de verdad: el del contenedor compartido con la app y con el túnel.
    static let appGroup = OpenSessionMarking(
        openingStore: { try FlowStore(appGroupID: AppGroup.identifier) }
    )

    /// Pone un marcador en la sesión abierta con el instante que se le da — el del gesto, que quien
    /// llama toma **antes** de abrir nada.
    func place(_ option: AuditMarkerOption, at date: Date) async -> AuditMarkerReport {
        do {
            switch try await openStore().addMarkerToOpenSession(option.kind, at: date) {
            case .placed(let marker, in: let recording):
                return .placed(title: option.title, date: marker.date, projectName: recording.projectName)
            case .noOpenSession:
                return .noOpenSession
            }
        } catch {
            return .notPlaced
        }
    }

    func controlState() async -> AuditMarkerControlState {
        do {
            guard let recording = try await openStore().auditRecording() else { return .idle }
            return .recording(projectName: recording.projectName)
        } catch {
            return .unavailable
        }
    }
}
