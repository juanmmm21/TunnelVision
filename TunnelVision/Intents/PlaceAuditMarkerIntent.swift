import AppIntents
import Foundation

/// Pone un marcador en la sesión de auditoría abierta **sin abrir TunnelVision**: el evaluador está
/// en mitad del onboarding de la app auditada y volver aquí cambiaría lo que se está midiendo
/// (`docs/spec/audit.md` § *Marking from outside the app*).
///
/// Es el mismo tipo para las tres puertas —el control, el atajo y Siri—, así que ninguna puede
/// marcar de forma distinta a las otras.
struct PlaceAuditMarkerIntent: AppIntent {

    static let title: LocalizedStringResource = LocalizedStringResource(
        "audit.intent.title",
        defaultValue: "Place Audit Marker",
        comment: "Name of the Shortcuts action that places a marker in the open audit session."
    )

    static let description = IntentDescription(
        LocalizedStringResource(
            "audit.intent.description",
            defaultValue: """
                Marks this instant in the audit session that is recording, without opening \
                TunnelVision. If no session is recording, nothing is marked and the action says so.
                """,
            comment: "Description of the Shortcuts action that places a marker in the open audit session."
        )
    )

    static let openAppWhenRun = false

    @Parameter(
        title: LocalizedStringResource(
            "audit.intent.parameter.marker",
            defaultValue: "Marker",
            comment: "Name of the parameter of the audit marker action that chooses which marker to place."
        ),
        default: .consentGiven
    )
    var marker: AuditMarkerOption

    init() {}

    init(marker: AuditMarkerOption) {
        self.marker = marker
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // El instante es el del gesto: se toma antes de abrir la base de datos, que es lo que tarda.
        let instant = Date()
        let report = await OpenSessionMarking.appGroup.place(marker, at: instant)
        switch AuditMarkerIntentCopy.reading(report) {
        case .success(let confirmation):
            return .result(dialog: IntentDialog(confirmation))
        case .failure(let error):
            throw error
        }
    }
}
