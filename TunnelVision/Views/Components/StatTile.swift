import SwiftUI

/// Una métrica con su etiqueta (`docs/ux/design-system.md`). Dígitos monoespaciados para que el
/// número no baile al actualizarse.
struct StatTile: View {

    let title: String
    let value: String
    let systemImage: String
    var tint: Color = Color(.neutral)

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Label(title, systemImage: systemImage)
                .font(.metricLabel)
                .foregroundStyle(Color(.neutral))
                .labelStyle(.titleAndIcon)
            Text(value)
                .font(.metricValue)
                .foregroundStyle(tint)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: Spacing.row, radius: CornerRadius.medium)
        .accessibilityElement(children: .combine)
    }
}

/// La señal de back-pressure: registros que la extensión descartó porque el ring estaba lleno.
///
/// "Honesta, no alarmante" (principio 4 de `docs/ux/00-ux-principles.md`): se enseña solo si de
/// verdad se ha perdido algo, explica qué significa en una línea y no interrumpe nada. La frase la
/// compone el núcleo puro: meter la cifra dentro de una oración es decidir un orden que solo el
/// idioma manda.
struct DropIndicator: View {

    let droppedRecords: UInt64

    var body: some View {
        Label {
            Text(DashboardPresentation.droppedRecordsNotice(droppedRecords))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.circle")
        }
        .foregroundStyle(StatusRole.warning.color)
        .accessibilityElement(children: .combine)
    }
}
