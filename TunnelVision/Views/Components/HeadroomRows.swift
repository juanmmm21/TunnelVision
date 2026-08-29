import SwiftUI

/// La cabecera de la sección *Room left* de la pantalla de capturas: la respuesta corta, la barra que
/// la dibuja y las dos cifras de las que sale.
///
/// El orden es el de la lectura y no el del cálculo: primero **cuánto queda** —que es la pregunta con
/// la que se abre esta sección—, después la forma de esa proporción, y en voz baja las cifras crudas
/// de las que se saca. Al revés, como estaban repartidas hasta ahora, el usuario tenía que hacer la
/// resta él.
struct HeadroomSummaryRow: View {

    let display: CaptureHeadroomDisplay

    /// El alto de la barra crece con la letra: es un adorno, y un adorno **cuelga de la curva de
    /// escalado de lo que acompaña** (`docs/ux/design-system.md`). Fija, a AX5 quedaba como un hilo
    /// bajo un titular tres veces mayor.
    @ScaledMetric(relativeTo: .caption) private var barHeight: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.close) {
            Text(display.headline)
                .font(.metricValue)
                .foregroundStyle(display.role.color)

            if let fill = display.fill {
                bar(fill: fill)
            }

            Text(display.usage)
                .font(.metricLabel)
                .foregroundStyle(Color(.neutral))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Un solo elemento, como las filas de esta misma pantalla: titular, barra y cifras sueltos se
        // oirían como tres cosas seguidas, y la barra —que es la misma proporción dibujada— se oiría
        // como un porcentaje suelto detrás de la frase que ya lo dice.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.headline)
        .accessibilityValue(display.usage)
    }

    /// La proporción, dibujada. No lleva rótulo ni porcentaje: lo que dice ya está escrito encima y
    /// debajo, y repetirlo aquí sería el mismo hecho tres veces.
    private func bar(fill: Double) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.surfaceSunken))
                Capsule()
                    .fill(display.role.color)
                    .frame(width: geometry.size.width * fill)
            }
        }
        .frame(height: barHeight)
        .accessibilityHidden(true)
    }
}

/// La fila que dice cuándo se va la captura más antigua.
///
/// Son **dos filas distintas y no una con el texto cambiado**: con fecha es un rótulo y un valor, que
/// es como se leen las demás cifras de la app (`ValueRow`); sin ella lo que hay es una explicación, y
/// escribirla en la columna de un valor la dejaría alineada a la derecha y con dígitos de ancho fijo.
struct HeadroomExpiryRow: View {

    let expiry: CaptureExpiryDisplay

    /// El formato de la fecha lo pone el dispositivo, igual que la hora de una fila de captura, y es
    /// **el mismo** (`Date.FormatStyle.dayAndTime`): las dos fechas de esta pantalla se leen una
    /// contra otra —cuándo empezó la más antigua y cuándo se va— y con dos formatos distintos habría
    /// que leerlas dos veces.
    var body: some View {
        switch expiry {
        case .dated(let label, let date):
            let value = date.formatted(Date.FormatStyle.dayAndTime)
            // Un solo elemento, medido con `idb ui describe-all`: sin esto el árbol entrega el
            // rótulo y la fecha como dos textos seguidos, y quien no ve la pantalla oye «Oldest
            // expires» y después una fecha suelta sin nada que diga que hablan de lo mismo. Es el
            // mismo arreglo que lleva `StorageRow` y por la misma razón.
            ValueRow(label: label, value: value)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityValue(value)

        case .stated(let text):
            Text(text)
                .font(.cardBody)
                .foregroundStyle(Color(.neutral))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
