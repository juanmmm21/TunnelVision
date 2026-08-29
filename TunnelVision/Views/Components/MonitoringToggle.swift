import SwiftUI

/// El control de encender/apagar de la Dashboard (`docs/ux/design-system.md`).
///
/// No decide nada: recibe la presentación ya resuelta (`MonitoringPresentation.forState`) y avisa de
/// la acción pulsada. Toda la copia y todas las reglas —que un fallo siempre ofrezca salida, que el
/// diálogo del sistema vaya precedido de la hoja de explicación, y **cuánto sitio merece el control
/// en cada estado**— viven en el valor, donde se pueden probar.
///
/// Tiene dos formas y la elige `presentation.prominence`. La **tarjeta** es la de un estado que
/// ofrece algo: encender, o salir de un fallo. La **franja** es la del túnel ya trabajando, que es
/// donde el control pasaba de grande a excesivo — se toca una vez y luego la pantalla existe por el
/// gráfico, los contadores y los hosts (`docs/ux/screens.md` § *Dashboard*). Lo que cambia entre las
/// dos es el peso: las dos llevan el mismo titular, la misma explicación y la misma acción.
struct MonitoringToggle: View {

    let presentation: MonitoringPresentation
    let onAction: (MonitoringAction) -> Void

    var body: some View {
        switch presentation.prominence {
        case .offer: offerCard
        case .status: statusStrip
        }
    }

    // MARK: - Las dos formas

    /// La tarjeta: titular, explicación, el mensaje del sistema si lo hubo y la acción ocupando el
    /// ancho. Es lo primero que ofrece una Dashboard vacía, así que aquí el tamaño sí es el mensaje.
    private var offerCard: some View {
        VStack(alignment: .leading, spacing: Spacing.row) {
            titleLabel

            Text(presentation.detail)
                .font(.cardBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let diagnostic = presentation.diagnostic {
                Text(diagnostic)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let action = presentation.action, let title = presentation.actionTitle {
                Button { onAction(action) } label: {
                    // El ancho va en el **rótulo** y no en el botón: un `.frame(maxWidth:)` puesto
                    // fuera estira el hueco del control pero no su relleno, así que la pastilla salía
                    // estrecha en mitad de la tarjeta y el objetivo táctil era solo ella. Es el mismo
                    // defecto que ya se pagó en el intro.
                    Text(title).frame(maxWidth: .infinity)
                }
                .brandProminentButton()
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    /// La franja: el titular y la acción en una línea, con la explicación debajo. Sigue siendo una
    /// tarjeta —lo demás de la pantalla lo es— pero de la altura de lo que dice.
    ///
    /// Que el titular y el botón quepan en una línea lo decide `ViewThatFits` y no el umbral de
    /// accesibilidad: lo que los desborda es el **ancho** de dos textos que crecen a la vez, y eso
    /// pasa antes de AX1 en un idioma con palabras largas. Cuando no caben, el botón baja y ocupa el
    /// ancho, que es lo que le devuelve el objetivo táctil.
    private var statusStrip: some View {
        VStack(alignment: .leading, spacing: Spacing.close) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.row) {
                    titleLabel
                    Spacer(minLength: Spacing.row)
                    stripAction(expands: false)
                }
                VStack(alignment: .leading, spacing: Spacing.row) {
                    titleLabel
                    stripAction(expands: true)
                }
            }

            Text(presentation.detail)
                .font(.supporting)
                .foregroundStyle(Color(.neutral))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: Spacing.row)
    }

    // MARK: - Piezas comunes

    /// El símbolo y el titular. Es el mismo en las dos formas: lo que dice en qué estado está el túnel
    /// no puede depender del sitio que se le dé.
    private var titleLabel: some View {
        Label {
            Text(presentation.title)
                .font(.cardTitle)
        } icon: {
            if presentation.isBusy {
                ProgressView()
            } else {
                Image(systemName: presentation.systemImage)
                    .foregroundStyle(presentation.role.color)
            }
        }
    }

    /// La acción de la franja. No lleva el relleno de la marca: en un estado que ya está funcionando,
    /// lo prominente sería *parar*, y parar no es lo que la pantalla quiere sugerir.
    ///
    /// `expands` es para cuando el botón ha bajado a su propia línea: ahí ocupa el ancho, y el ancho va
    /// en el **rótulo**, que es lo único que estira el relleno del control y con él el objetivo táctil.
    @ViewBuilder
    private func stripAction(expands: Bool) -> some View {
        if let action = presentation.action, let title = presentation.actionTitle {
            Button { onAction(action) } label: {
                // El ancho y el mínimo táctil van los dos en el **rótulo**: en un estilo del sistema,
                // lo que crece con el marco del botón es el hueco alrededor, no el relleno que recibe
                // el toque. Sin esto la pastilla medía **34 pt** de alto (medido con
                // `idb ui describe-all`), o sea diez por debajo del mínimo de la HIG.
                Text(title)
                    .frame(maxWidth: expands ? .infinity : nil, minHeight: TouchTarget.minimum)
            }
            .buttonStyle(.bordered)
            // El tamaño pequeño solo quita relleno propio del estilo: el rótulo no encoge y el
            // objetivo lo marca ya el mínimo de arriba. Es lo que impide que la pastilla acabe siendo
            // más alta que el titular al que acompaña, que es el defecto que esta franja viene a
            // arreglar.
            .controlSize(.small)
        }
    }
}
