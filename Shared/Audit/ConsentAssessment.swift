import Foundation

/// Entre qué dos instantes se dio el consentimiento en una sesión: el primer marcador
/// `consentGiven` y el último. Con un solo marcador son el mismo.
///
/// Son dos y no uno porque varios marcadores no dicen cuál es el bueno —un toque de más, un
/// segundo diálogo de consentimiento, uno retirado y vuelto a dar—, y elegir uno aquí sería
/// decidirlo por el evaluador.
public struct ConsentInterval: Sendable, Hashable {

    public let first: Date
    public let last: Date

    /// `nil` si la sesión no tiene ningún marcador `consentGiven`. Los marcadores de otra sesión
    /// se ignoran: el consentimiento de una grabación no fecha los flujos de otra.
    public init?(markers: [SessionMarker], of session: AuditSession) {
        let instants = markers
            .filter { $0.sessionID == session.id && $0.kind == .consentGiven }
            .map(\.date)
        guard let first = instants.min(), let last = instants.max() else { return nil }
        self.first = first
        self.last = last
    }
}

/// Por qué no se pudo decir si un flujo empezó antes del consentimiento.
public enum ConsentGap: String, Sendable, Hashable, Codable {
    /// La sesión no tiene marcador `consentGiven`: sin él no hay «antes». Que nadie lo pusiera no
    /// es que no hubiera actividad previa.
    case noConsentMarker
    /// La sesión tiene varios marcadores `consentGiven` y el flujo empezó entre el primero y el
    /// último: es anterior a uno y posterior a otro.
    case betweenConsentMarkers
}

/// Lo que se puede decir de **un** flujo frente al consentimiento marcado en su sesión.
///
/// Se compara el **primer paquete** del flujo (`firstSeen`). Lo que se afirma es que la conexión
/// se abrió antes; si además siguió llevando tráfico después lo dice el propio flujo (`lastSeen`).
public enum ConsentAssessment: Sendable, Hashable {

    /// El flujo empezó antes de **todos** los marcadores de consentimiento.
    case beforeConsent

    /// El flujo empezó en el instante del último marcador de consentimiento o después.
    case afterConsent

    case notAssessed(ConsentGap)

    /// La sesión es una `baseline`: se graba sin la app auditada, así que no hay consentimiento
    /// de nadie al que un flujo pueda adelantarse.
    case notApplicable

    public init(of flow: StoredFlow, sessionKind: AuditSessionKind, consent: ConsentInterval?) {
        guard case .audit = sessionKind else {
            self = .notApplicable
            return
        }
        guard let consent else {
            self = .notAssessed(.noConsentMarker)
            return
        }
        if flow.firstSeen < consent.first {
            self = .beforeConsent
        } else if flow.firstSeen >= consent.last {
            self = .afterConsent
        } else {
            self = .notAssessed(.betweenConsentMarkers)
        }
    }
}
