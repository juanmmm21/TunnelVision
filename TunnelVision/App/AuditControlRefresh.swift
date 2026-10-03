import WidgetKit

/// Pide al sistema que relea el control del marcador de auditoría.
///
/// Un control no se entera solo de que su valor cambió: el sistema lo relee cuando se pulsa o cuando
/// la app se lo pide. Los controles existen desde iOS 18 y la app arranca en 17, donde no hay nada
/// que recargar.
enum AuditControlRefresh {

    @MainActor
    static func reload() {
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadControls(ofKind: AuditControlKind.marker)
        }
    }
}
