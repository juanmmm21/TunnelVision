import Charts
import SwiftUI

/// El gráfico de throughput en vivo: dos series (recibido/enviado) sobre la ventana rodante que
/// publica el feed.
///
/// La ventana llega **con los huecos ya rellenos a cero** desde `ThroughputWindow.samples(asOf:)`;
/// eso no es un detalle del servicio sino la condición para que este gráfico no mienta: sin las
/// barras vacías, Swift Charts uniría dos picos con una recta y afirmaría un tráfico que no existió.
struct ThroughputChart: View {

    let samples: [ThroughputSample]
    let rateIn: Double
    let rateOut: Double

    /// Con Reduce Motion activo el gráfico se actualiza sin transición: el movimiento aquí es
    /// decorativo, y el dato se lee igual de bien apareciendo de golpe.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// En los cuerpos de accesibilidad las dos tasas no caben lado a lado sin encoger el número, así
    /// que bajan a dos líneas.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Los nombres de las dimensiones **no son copia**: los ejes se etiquetan con fechas y con tasas
    /// formateadas, y VoiceOver no los oye nunca porque el gráfico es un solo elemento con su nombre
    /// puesto a mano. Como literales, Swift Charts los toma por `LocalizedStringKey` y el extractor los
    /// mete en el catálogo —así llegaron allí *Time*, *Bytes per second* y *Direction*—; pasándolos como
    /// `String` se elige la otra sobrecarga y dejan de ser unidades de traducción. Es el mismo cierre
    /// que ya hizo `ScrubBar` con los suyos.
    private static let timeDimension = "Time"
    private static let rateDimension = "Bytes per second"
    private static let seriesDimension = "Direction"

    /// El relleno se desvanece hacia abajo en vez de ser un bloque plano: separa de un vistazo el
    /// área (recibido) de la línea (enviado) sin añadir un tercer color. Constante y no expresión en
    /// el cuerpo del gráfico: dentro del `ForEach` el comprobador de tipos de Swift no termina.
    private static let inboundFill = LinearGradient(
        colors: [
            TrafficDirectionStyle.inboundColor.opacity(0.28),
            TrafficDirectionStyle.inboundColor.opacity(0.02)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.close) {
            rates

            Chart {
                ForEach(samples) { sample in
                    AreaMark(
                        x: .value(Self.timeDimension, sample.start),
                        y: .value(Self.rateDimension, sample.bytesInPerSecond),
                        series: .value(Self.seriesDimension, TrafficDirectionStyle.inboundLabel)
                    )
                    .foregroundStyle(Self.inboundFill)

                    LineMark(
                        x: .value(Self.timeDimension, sample.start),
                        y: .value(Self.rateDimension, sample.bytesInPerSecond),
                        series: .value(Self.seriesDimension, TrafficDirectionStyle.inboundLabel)
                    )
                    .foregroundStyle(TrafficDirectionStyle.inboundColor)

                    LineMark(
                        x: .value(Self.timeDimension, sample.start),
                        y: .value(Self.rateDimension, sample.bytesOutPerSecond),
                        series: .value(Self.seriesDimension, TrafficDirectionStyle.outboundLabel)
                    )
                    .foregroundStyle(TrafficDirectionStyle.outboundColor)
                }
            }
            // Los ejes se leen pero no compiten con el dato: rejilla en el gris neutro del sistema
            // visual y etiquetas en el cuerpo más pequeño, que es lo que deja el trazo al frente.
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) {
                    AxisGridLine().foregroundStyle(Color(.surfaceStroke))
                    AxisValueLabel(format: .dateTime.minute().second())
                        .font(.caption2)
                        .foregroundStyle(Color(.neutral))
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Color(.surfaceStroke))
                    AxisValueLabel {
                        if let bytesPerSecond = value.as(Double.self) {
                            Text(DisplayFormat.rate(bytesPerSecond: bytesPerSecond))
                                .font(.caption2)
                                .foregroundStyle(Color(.neutral))
                        }
                    }
                }
            }
            .frame(height: 180)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: samples)
            // VoiceOver lee los valores, no "gráfico": el resumen es el dato que el vidente ve arriba.
            // Las dos frases las compone el núcleo puro, que es donde el orden de las dos tasas deja
            // de ser una decisión de esta vista.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(DashboardPresentation.chartAccessibilityLabel)
            .accessibilityValue(
                DashboardPresentation.chartAccessibilityValue(rateIn: rateIn, rateOut: rateOut)
            )
        }
    }

    private var rates: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.close))
            : AnyLayout(HStackLayout(spacing: Spacing.row))
        return layout {
            rateLabel(
                TrafficDirectionStyle.inboundLabel,
                symbol: TrafficDirectionStyle.inboundSymbol,
                color: TrafficDirectionStyle.inboundColor,
                rate: rateIn
            )
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: Spacing.row)
            }
            rateLabel(
                TrafficDirectionStyle.outboundLabel,
                symbol: TrafficDirectionStyle.outboundSymbol,
                color: TrafficDirectionStyle.outboundColor,
                rate: rateOut
            )
        }
    }

    private func rateLabel(_ title: String, symbol: String, color: Color, rate: Double) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.metricLabel)
                    .foregroundStyle(Color(.neutral))
                // `readingValue` trae los dígitos monoespaciados de fábrica: el valor cambia varias
                // veces por segundo y sin ellos la etiqueta cambiaría de anchura en cada
                // actualización.
                Text(DisplayFormat.rate(bytesPerSecond: rate))
                    .font(.readingValue)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
    }
}
