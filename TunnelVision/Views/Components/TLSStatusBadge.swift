import SwiftUI
import Shared

/// El estado de inspección de una conexión: **icono + etiqueta + color**, nunca color solo
/// (`docs/ux/design-system.md`). Toda la copia y el papel de color vienen de `TLSStatusPresentation`;
/// aquí solo se pinta.
struct TLSStatusBadge: View {

    let status: TLSInspectionStatus

    private var presentation: TLSStatusPresentation { .forStatus(status) }

    var body: some View {
        Label(presentation.label, systemImage: presentation.systemImage)
            .font(.badge)
            .foregroundStyle(presentation.role.color)
            .padding(.horizontal, Spacing.close)
            .padding(.vertical, Spacing.tight)
            // El tinte está **medido** (`FillOpacity.badge`) y no elegido: la insignia se pinta con
            // cualquiera de los colores de estado, y al 12 % que llevaba antes los dos de menos margen
            // dejaban su propio rótulo por debajo del mínimo de lectura sobre la mezcla.
            .background(presentation.role.color.opacity(FillOpacity.badge), in: Capsule())
            // Con un relleno tan bajo, el aro es lo único que hace que esto se lea como insignia y no
            // como texto de color. Del mismo color, para no meter uno nuevo.
            .overlay {
                Capsule().strokeBorder(
                    presentation.role.color.opacity(StrokeOpacity.tintedEdge),
                    lineWidth: StrokeWidth.hairline
                )
            }
            // VoiceOver lee también el porqué: la etiqueta sola no dice si eso es bueno o malo.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.accessibilityDescription)
    }
}
