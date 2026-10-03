import AppIntents
import Foundation

/// El error con el que el intent termina cuando **no puso** el marcador. Atajos y Siri enseñan su
/// frase; es lo que impide que un marcador ausente pase por puesto.
enum AuditMarkerIntentError: Error, Sendable, Equatable, CustomLocalizedStringResourceConvertible {
    case noOpenSession
    case notPlaced

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noOpenSession:
            return LocalizedStringResource(
                "audit.intent.error.noOpenSession",
                defaultValue: "No marker was placed: no audit session is recording. Start one in TunnelVision first.",
                comment: """
                    Error shown by Shortcuts or Siri when the audit marker action ran with no audit \
                    session open. It must say plainly that nothing was recorded.
                    """
            )
        case .notPlaced:
            return LocalizedStringResource(
                "audit.intent.error.notPlaced",
                defaultValue: "No marker was placed: TunnelVision couldn't write to its history. Open the app and try again.",
                comment: """
                    Error shown by Shortcuts or Siri when the audit marker action could not write the \
                    marker. It must say plainly that nothing was recorded.
                    """
            )
        }
    }
}

/// Lo que el marcador de fuera de la app **dice**, decidido sin pintar nada.
enum AuditMarkerIntentCopy {

    /// Qué se le dice a quien pulsó: la confirmación, o el error con el que el intent termina.
    static func reading(_ report: AuditMarkerReport) -> Result<LocalizedStringResource, AuditMarkerIntentError> {
        switch report {
        case .placed(let title, let date, let projectName):
            // La hora llega al segundo y la escribe el sistema: es lo que deja cotejar el marcador
            // con lo que se estaba haciendo en la app auditada.
            let time = date.formatted(date: .omitted, time: .standard)
            return .success(
                LocalizedStringResource(
                    "audit.intent.placed",
                    defaultValue: "“\(title)” marked at \(time) in \(projectName).",
                    comment: """
                        Confirmation after an audit marker was placed from Shortcuts, Siri or a \
                        control. First the marker's name, then the time to the second, then the \
                        audit project's name.
                        """
                )
            )
        case .noOpenSession:
            return .failure(.noOpenSession)
        case .notPlaced:
            return .failure(.notPlaced)
        }
    }

    /// La línea de estado del control: en qué se va a marcar, o por qué no se puede.
    static func controlStatus(_ state: AuditMarkerControlState) -> String {
        switch state {
        case .recording(let projectName):
            // El nombre del proyecto lo escribió el usuario: no es copia nuestra.
            return projectName
        case .idle:
            return String(
                localized: "audit.control.status.idle",
                defaultValue: "No session recording",
                comment: """
                    Status line of the Control Center control that places an audit marker, when no \
                    audit session is open: pressing it will record nothing.
                    """
            )
        case .unavailable:
            return String(
                localized: "audit.control.status.unavailable",
                defaultValue: "History unavailable",
                comment: """
                    Status line of the Control Center control that places an audit marker, when the \
                    app's database could not be read.
                    """
            )
        }
    }
}

/// El identificador del control, compartido por la extensión que lo declara y por la app que le pide
/// que se relea cuando una sesión se abre o se cierra.
enum AuditControlKind {
    static let marker = "com.juanmmm21.tunnelvision.AuditControls.marker"
}
