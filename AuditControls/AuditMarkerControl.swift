import AppIntents
import SwiftUI
import WidgetKit

/// Qué marcador pone el control. Se elige al añadirlo, así que el evaluador puede tener uno por
/// marcador; el que sale sin tocar nada es el del consentimiento, que es el que contesta «¿hubo
/// actividad de red antes del consentimiento?».
struct AuditMarkerControlConfiguration: ControlConfigurationIntent {

    static let title: LocalizedStringResource = LocalizedStringResource(
        "audit.control.configuration.title",
        defaultValue: "Audit Marker",
        comment: "Title of the configuration of the Control Center control that places an audit marker."
    )

    @Parameter(
        title: LocalizedStringResource(
            "audit.control.configuration.marker",
            defaultValue: "Marker",
            comment: "Name of the setting of the audit marker control that chooses which marker it places."
        ),
        default: .consentGiven
    )
    var marker: AuditMarkerOption

    init() {}
}

/// Lo que el control enseña: el marcador que pone y si hay una sesión donde ponerlo.
struct AuditMarkerControlValue: Sendable, Equatable {
    let marker: AuditMarkerOption
    let state: AuditMarkerControlState
}

struct AuditMarkerControlProvider: AppIntentControlValueProvider {

    /// La galería de controles no lee nada: enseña el control como está casi siempre, sin sesión.
    /// Un proyecto de ejemplo aquí sería una grabación que no existe.
    func previewValue(configuration: AuditMarkerControlConfiguration) -> AuditMarkerControlValue {
        AuditMarkerControlValue(marker: configuration.marker, state: .idle)
    }

    func currentValue(configuration: AuditMarkerControlConfiguration) async throws -> AuditMarkerControlValue {
        AuditMarkerControlValue(
            marker: configuration.marker,
            state: await OpenSessionMarking.appGroup.controlState()
        )
    }
}

/// El botón del Centro de Control que pone un marcador en la sesión abierta.
///
/// Su segunda línea dice **antes de pulsar** si hay dónde marcar —el proyecto que graba, o que no
/// hay sesión—, porque un control no enseña el error de su intent: sin esa línea, pulsarlo sin sesión
/// sería exactamente el marcador que no se puso y que el evaluador cree puesto.
struct AuditMarkerControl: ControlWidget {

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: AuditControlKind.marker,
            provider: AuditMarkerControlProvider()
        ) { value in
            ControlWidgetButton(action: PlaceAuditMarkerIntent(marker: value.marker)) {
                Label(value.marker.title, systemImage: value.marker.systemImage)
                Text(AuditMarkerIntentCopy.controlStatus(value.state))
            }
        }
        .displayName(
            LocalizedStringResource(
                "audit.control.name",
                defaultValue: "Audit Marker",
                comment: "Name of the Control Center control that places a marker in the open audit session."
            )
        )
        .description(
            LocalizedStringResource(
                "audit.control.description",
                defaultValue: "Marks this instant in the audit session that is recording.",
                comment: "Description of the Control Center control that places a marker in the open audit session."
            )
        )
    }
}
