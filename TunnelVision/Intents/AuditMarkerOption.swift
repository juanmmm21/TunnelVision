import AppIntents
import Shared

/// Los marcadores que se pueden poner **desde fuera de la app**: los tres de nombre fijo.
///
/// El libre (`SessionMarkerKind.custom`) se queda en la pantalla de la sesión a propósito: hay que
/// teclearlo, y quien está en mitad del onboarding de la app auditada no puede pararse a escribir sin
/// que el instante deje de ser el del gesto.
///
/// Los nombres de los casos se repiten aquí, y no salen de `AuditPresentation.markerTitle`, porque
/// App Intents extrae estos textos **al compilar** y solo acepta literales. Que digan lo mismo que la
/// pantalla lo afirma `AuditMarkerOptionTests`.
enum AuditMarkerOption: String, AppEnum, CaseIterable, Sendable {
    case consentGiven
    case loggedIn
    case loggedOut

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource(
            "audit.intent.marker.type",
            defaultValue: "Audit Marker",
            comment: "Name of the kind of value an audit marker is, as the Shortcuts app shows it."
        )
    )

    static let caseDisplayRepresentations: [AuditMarkerOption: DisplayRepresentation] = [
        .consentGiven: DisplayRepresentation(
            title: LocalizedStringResource(
                "audit.intent.marker.consentGiven",
                defaultValue: "Consent given",
                comment: """
                    Audit marker offered by the Shortcuts action and the Control Center control: the \
                    user accepted the audited app's consent screen at this instant.
                    """
            )
        ),
        .loggedIn: DisplayRepresentation(
            title: LocalizedStringResource(
                "audit.intent.marker.loggedIn",
                defaultValue: "Logged in",
                comment: """
                    Audit marker offered by the Shortcuts action and the Control Center control: the \
                    user signed in to the audited app at this instant.
                    """
            )
        ),
        .loggedOut: DisplayRepresentation(
            title: LocalizedStringResource(
                "audit.intent.marker.loggedOut",
                defaultValue: "Logged out",
                comment: """
                    Audit marker offered by the Shortcuts action and the Control Center control: the \
                    user signed out of the audited app at this instant.
                    """
            )
        ),
    ]

    /// Lo que se guarda.
    var kind: SessionMarkerKind {
        switch self {
        case .consentGiven: return .consentGiven
        case .loggedIn: return .loggedIn
        case .loggedOut: return .loggedOut
        }
    }

    /// El mismo símbolo que lleva su botón en la pantalla de la sesión.
    var systemImage: String {
        switch self {
        case .consentGiven: return "hand.thumbsup"
        case .loggedIn: return "person.crop.circle.badge.checkmark"
        case .loggedOut: return "person.crop.circle.badge.xmark"
        }
    }

    /// El nombre del caso, ya resuelto.
    var title: String {
        guard let representation = Self.caseDisplayRepresentations[self] else {
            // El diccionario de arriba es exhaustivo y lo afirma un test; esto solo evita un `!`.
            return rawValue
        }
        return String(localized: representation.title)
    }
}
