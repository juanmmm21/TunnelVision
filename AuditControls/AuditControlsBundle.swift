import SwiftUI
import WidgetKit

/// La extensión de widgets de TunnelVision. Solo lleva **controles** (Centro de Control, botón de
/// acción, pantalla de bloqueo), que existen desde iOS 18: por eso este target tiene su propio
/// deployment target y la app, que sigue en 17, no necesita ninguna comprobación de disponibilidad
/// para embeberlo.
@main
struct AuditControlsBundle: WidgetBundle {
    var body: some Widget {
        AuditMarkerControl()
    }
}
