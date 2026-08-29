import SwiftUI

/// Una fila del "quién está hablando ahora": host, conexiones y lo movido en cada sentido.
///
/// Ni compone copia ni formatea cifras: desde M11 todo eso llega resuelto en un
/// `TopTalkerPresentation`. La frase que oye VoiceOver —tres datos seguidos con sus separadores— y
/// el plural de las conexiones son decisiones de idioma, y esta vista no es sitio para tomarlas.
struct TopTalkerRow: View {

    let talker: TopTalker

    /// **Decidido en M11: esta fila sí pide su copia dentro del `body`, y se queda así.** Tiene la
    /// misma forma que la de la Timeline y la de un paquete —que la reciben ya compuesta desde su view
    /// model— pero no el mismo problema: la Dashboard se redibuja entera con cada instantánea del feed
    /// en vivo, así que la copia se rehace de todas formas, y estas filas son cinco en un `VStack` y no
    /// una lista que se desplaza. Repartirlo por simetría no ahorraría un solo trabajo.
    private var presentation: TopTalkerPresentation {
        DashboardPresentation.topTalker(talker)
    }

    var body: some View {
        let presentation = self.presentation
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.host)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(presentation.connections)
                    .font(.metricLabel)
                    .foregroundStyle(Color(.neutral))
            }

            Spacer(minLength: Spacing.close)

            VStack(alignment: .trailing, spacing: 2) {
                transferLabel(
                    symbol: TrafficDirectionStyle.inboundSymbol,
                    color: TrafficDirectionStyle.inboundColor,
                    bytes: presentation.bytesIn
                )
                transferLabel(
                    symbol: TrafficDirectionStyle.outboundSymbol,
                    color: TrafficDirectionStyle.outboundColor,
                    bytes: presentation.bytesOut
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.accessibilityValue)
    }

    private func transferLabel(symbol: String, color: Color, bytes: String) -> some View {
        Label {
            Text(bytes).monospacedDigit()
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .font(.metricLabel)
    }
}
