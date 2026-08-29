import SwiftUI
import Shared

/// Un paquete de una conexión: qué fue, en qué sentido, cuándo dentro de la conexión y cuánto ocupó.
///
/// El titular es lo que el paquete **significó** (`PacketEvent`), no sus siglas: esas van debajo, en
/// terciario, para quien las sepa leer. Ni el texto ni el color los decide esta vista.
struct PacketRow: View {

    /// El paquete **y su copia**, compuesta una vez por carga en el view model. La fila la pedía aquí,
    /// en el `body`: eso rehacía el titular, las dos cifras y la frase que solo oye VoiceOver —cuatro
    /// búsquedas en el catálogo— de cada fila visible en cada fotograma de scroll, sobre una lista de
    /// hasta 500 filas. Componerla sigue siendo del núcleo puro, que es donde el separador y el orden
    /// son decisiones de idioma afirmables; lo que cambia es cuándo.
    let row: PacketListRow

    /// La columna del sentido crece con el cuerpo de letra: fija en 16 pt, con los tamaños de
    /// accesibilidad la flecha desbordaría sobre el texto de al lado.
    @ScaledMetric(relativeTo: .caption) private var directionColumnWidth: CGFloat = 16

    /// En los cuerpos de accesibilidad el titular del suceso y las dos cifras no caben en la misma
    /// línea y un `HStack` no envuelve: el titular se recortaba por la izquierda y se leía `ata` por
    /// `Data`. Apiladas, cada cosa dispone del ancho entero.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var packet: PacketSummary { row.packet }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.close))
            : AnyLayout(HStackLayout(spacing: Spacing.row))
        return layout {
            event
            metrics
        }
        .padding(.vertical, Spacing.tight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.presentation.accessibilityLabel)
    }

    /// El sentido y lo que el paquete significó. El icono del sentido acompaña al titular también
    /// apilado: separarlo dejaría una flecha suelta sin nada a lo que referirse.
    private var event: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.row) {
            Image(systemName: directionSymbol)
                .font(.metricLabel)
                .foregroundStyle(directionColor)
                .frame(width: directionColumnWidth)

            VStack(alignment: .leading, spacing: Spacing.tight) {
                // El icono y el papel de color salen del suceso aquí mismo, y siguen así a propósito:
                // son `switch`es sobre un enum que ni buscan en el catálogo ni asignan nada, al
                // contrario que el titular. Es la misma raya que traza `FlowRow` con su badge de
                // cifrado.
                Label(row.presentation.event, systemImage: packet.event.systemImage)
                    .font(.cardBody)
                    .foregroundStyle(packet.event.role.color)

                // Las siglas no son copia y ya vienen resueltas con el paquete: no hay nada que
                // componer para enseñarlas. Y **no** van monoespaciadas aunque sean un literal del
                // protocolo: se probó, y como cada carácter ocupa lo mismo, la coma de `SYN, ACK`
                // abre un hueco que separa las dos siglas como si fueran dos datos distintos.
                if let flags = packet.flagsDetail {
                    Text(flags)
                        .font(.metricLabel)
                        .foregroundStyle(Color(.neutral))
                }
            }
        }
        // Hace el trabajo del `Spacer` que había entre las dos mitades —empujar las cifras al borde
        // derecho— sin ser un `Spacer`, que apilado se comería el alto en vez del ancho.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Cuándo dentro de la conexión y cuánto ocupó. Alineadas a la derecha mientras son una columna;
    /// apiladas se alinean con todo lo demás, porque ya no hay columna con la que cuadrar.
    private var metrics: some View {
        VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: Spacing.tight) {
            // Las dos al mismo tamaño y separadas por el color, que es como se separan en el resto de
            // la app una cifra y su acompañante: antes se distinguían además por el cuerpo, y eso
            // metía un cuarto tamaño de letra en una fila de tres líneas.
            Text(row.presentation.offset)
                .font(.rowFigure)
            Text(row.presentation.length)
                .font(.rowFigure)
                .foregroundStyle(Color(.neutral))
        }
    }

    private var directionSymbol: String {
        packet.direction == .inbound
            ? TrafficDirectionStyle.inboundSymbol
            : TrafficDirectionStyle.outboundSymbol
    }

    private var directionColor: Color {
        packet.direction == .inbound
            ? TrafficDirectionStyle.inboundColor
            : TrafficDirectionStyle.outboundColor
    }
}
