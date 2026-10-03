import SwiftUI

/// La sesión de auditoría abierta, dicha donde se ve el túnel (`docs/ux/audit.md`).
///
/// Una sesión abierta etiqueta **todo** flujo que la extensión vuelque hasta que alguien la cierre,
/// y hasta aquí solo se veía desde su propia pantalla: una olvidada habría seguido etiquetando días
/// sin que la Dashboard —que es donde se mira si el túnel está encendido— dijera nada. Tiene la forma
/// de la franja de `MonitoringToggle` a propósito: son dos cosas que están pasando ahora mismo, una
/// debajo de la otra, y dos formas distintas para la misma clase de hecho serían dos diseños.
struct AuditRecordingStrip: View {

    let banner: AuditRecordingBanner
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.close) {
            // `ViewThatFits` y no el umbral de accesibilidad, por lo mismo que en la franja del
            // túnel: lo que desborda es el ancho de dos textos que crecen a la vez.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.row) {
                    title
                    Spacer(minLength: Spacing.row)
                    action(expands: false)
                }
                VStack(alignment: .leading, spacing: Spacing.row) {
                    title
                    action(expands: true)
                }
            }

            Text(banner.detail)
                .font(.supporting)
                .foregroundStyle(Color(.neutral))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: Spacing.row)
    }

    private var title: some View {
        Label {
            Text(banner.title)
                .font(.cardTitle)
        } icon: {
            Image(systemName: "record.circle")
                .foregroundStyle(StatusRole.accent.color)
        }
    }

    private func action(expands: Bool) -> some View {
        Button(action: onOpen) {
            // El ancho y el mínimo táctil van en el rótulo: en un estilo del sistema, lo que crece
            // con el marco del botón es el hueco de alrededor y no el relleno que recibe el toque.
            Text(banner.actionTitle)
                .frame(maxWidth: expands ? .infinity : nil, minHeight: TouchTarget.minimum)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
