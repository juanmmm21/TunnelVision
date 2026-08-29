import SwiftUI
import Shared

/// Una conexión del historial: host, cuándo, cuánto movió en cada sentido, cuánto duró y en qué
/// estado quedó su cifrado (`docs/ux/screens.md`).
///
/// Es **un carril y tres renglones**: la marca del cifrado en una columna que se lee de arriba abajo,
/// y a su derecha el host con la hora, lo que la conexión fue, y lo que movió. La insignia entera que
/// ocupaba el renglón de en medio se fue: decía *Encrypted* en prácticamente todas las filas, o sea el
/// elemento con más contraste de la fila gastado en repetir lo que la lista ya da por supuesto
/// (`TLSStatusPresentation.emphasis`). La misma forma que `PacketRow`, y por la misma razón: son las
/// dos listas densas de la app.
struct FlowRow: View {

    /// La conexión **y su copia**, compuesta una vez por lista en el view model. La fila la pedía
    /// aquí, en el `body`: eso rehacía las cinco cadenas —cuatro de ellas una búsqueda en el
    /// catálogo— de cada fila visible en cada fotograma de scroll, incluida la que solo oye
    /// VoiceOver. Componerla sigue siendo del núcleo puro, que es donde el separador y el orden son
    /// decisiones de idioma afirmables; lo que cambia es cuándo.
    let row: TimelineRow

    /// El carril de la marca crece con el cuerpo de letra, igual que la columna del sentido de
    /// `PacketRow`: en puntos fijos, el símbolo se montaría sobre el host. Ancho fijo y no ajustado al
    /// símbolo porque los cuatro miden distinto, y lo que alinea la lista es que todos los hosts
    /// empiecen en la misma vertical.
    @ScaledMetric(relativeTo: .headline) private var markColumnWidth: CGFloat = 22

    /// En los cuerpos de accesibilidad nada de esto cabe en una línea y un `HStack` no envuelve:
    /// apilado, cada cosa dispone del ancho entero.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var presentation: TimelineRowPresentation { row.presentation }

    private var status: TLSStatusPresentation { .forStatus(row.flow.tlsStatus) }

    private var emphasis: TLSStatusEmphasis {
        TLSStatusPresentation.emphasis(
            for: row.flow.tlsStatus,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
        )
    }

    var body: some View {
        // El relleno lo pone la celda (`Theme.cardRow`) y no la fila: la superficie de la tarjeta es
        // de la lista, y dos rellenos —uno aquí y otro allí— se suman sin que nadie los vea juntos.
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.accessibilityLabel)
            .accessibilityValue(presentation.accessibilityValue)
    }

    /// La fila con carril, o la misma información apilada cuando la letra es de accesibilidad.
    ///
    /// El carril desaparece ahí y no se encoge: un símbolo en la curva del titular a AX5 se lleva el
    /// ancho que el host necesita para envolver. Lo que dice la marca pasa a decirlo la palabra, que
    /// es de lo que se ocupa `emphasis`.
    ///
    /// **El servicio y las cifras van en renglones fijos y no en un `ViewThatFits`, y esto es lo
    /// contrario de lo que decidió la Dashboard**: allí lo que desborda es el ancho de un control
    /// solo, así que medirlo es la respuesta. Aquí se probó y el resultado fue una lista **inestable**
    /// — dos filas con el mismo contenido salían con formas distintas porque la duración de una medía
    /// seis caracteres más («1 min 17 s» contra «48 s»)—. En una lista las filas se leen unas contra
    /// otras, así que la forma de una fila no puede depender de cuántos caracteres midió su cifra: lo
    /// que en un control es adaptarse, en doscientas filas es ruido.
    @ViewBuilder
    private var content: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Spacing.close) {
                header
                statusName
                service
                figures
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.row) {
                mark

                VStack(alignment: .leading, spacing: Spacing.tight) {
                    header
                    service
                    figures
                }
            }
        }
    }

    /// La marca del cifrado: el símbolo del estado, en su color, alineado con la línea del host.
    ///
    /// Es lo que convierte la lista en algo que se recorre con la vista — un candado abierto o un ojo
    /// se ven bajando por el carril sin leer una palabra—, y sigue sin depender del color: los cuatro
    /// estados llevan símbolos distintos (`TLSStatusPresentationTests`).
    private var mark: some View {
        Image(systemName: status.systemImage)
            .font(.cardTitle)
            .foregroundStyle(status.role.color)
            .frame(width: markColumnWidth)
    }

    /// Con quién habló y cuándo. Apilados en los cuerpos de accesibilidad, y ahí el host **envuelve**
    /// en vez de truncarse: recortado por el medio a una línea quedaba en `log…om`, que no nombra a
    /// nadie — y lo que el design system prohíbe a esos tamaños es exactamente truncar. En los cuerpos
    /// normales sigue siendo una línea recortada por el medio: la uniformidad de la lista vale más que
    /// el trozo de host que se pierde, y ahí se pierde poco.
    private var header: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.tight))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Spacing.close))
        return layout {
            Text(hostText)
                // El host es el titular de la tarjeta, no un renglón más: con el cuerpo llano las
                // tres líneas de la fila pesaban lo mismo y no había por dónde entrar a leerla.
                .font(.cardTitle)
                .lineLimit(stacked ? nil : 1)
                .truncationMode(.middle)
                // Hace el trabajo del `Spacer` que separaba host y hora, que apilado se comería el
                // alto en vez del ancho.
                .frame(maxWidth: .infinity, alignment: .leading)

            // La hora sí se localiza (12/24 h es del dispositivo, no de la app): es lo contrario
            // de los números de `DisplayFormat`, que son fijos para que no bailen al actualizarse.
            // El papel es el de una cifra de fila densa, el mismo con el que la lista de paquetes
            // pone sus instantes: una columna de horas que no se lee como cifras es lo único que
            // quedaba en la app escrito con el papel de una etiqueta.
            Text(row.flow.lastSeen, format: .dateTime.hour().minute())
                .font(.rowFigure)
                .foregroundStyle(Color(.neutral))
        }
    }

    /// El host, marcado como texto **sin idioma**. Un nombre de dominio no es prosa de ningún idioma y
    /// el silabeador del sistema lo trataba como si lo fuera: al envolver metía un guion dentro del
    /// nombre (`log25.exam-ple.com`), y un guion es un carácter legal en un dominio, así que el corte
    /// se lee como parte del nombre. Sin idioma no hay diccionario con el que silabear y el sistema
    /// corta por donde puede sin inventarse nada.
    private var hostText: AttributedString {
        var text = AttributedString(presentation.host)
        text.languageIdentifier = "und"
        return text
    }

    /// Qué fue la conexión, con la palabra del estado delante cuando el estado se desvía de lo que la
    /// lista da por supuesto.
    ///
    /// Las dos van juntas y sin separador dibujado: lo que las separa es el color —la palabra lleva el
    /// del estado, el servicio el neutro— y meter un `·` aquí sería componer copia en la vista, que es
    /// donde ningún traductor llega.
    private var service: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.close) {
            if emphasis == .named, !dynamicTypeSize.isAccessibilitySize {
                statusWord
            }

            Text(presentation.service)
                .font(.metricLabel)
                .foregroundStyle(Color(.neutral))
        }
    }

    /// La palabra del estado, sin su símbolo: el símbolo ya está en el carril, a la altura del host, y
    /// repetirlo dos veces en la misma fila sería decir dos veces lo mismo con más tinta.
    private var statusWord: some View {
        Text(status.label)
            .font(.metricLabel)
            .foregroundStyle(status.role.color)
    }

    /// El estado con símbolo y palabra, que es como se enseña cuando no hay carril donde poner la
    /// marca. `Label` y no las dos piezas sueltas: apilado, un símbolo suelto no tiene a qué referirse.
    private var statusName: some View {
        Label(status.label, systemImage: status.systemImage)
            .font(.metricLabel)
            .foregroundStyle(status.role.color)
    }

    /// Lo que movió y lo que duró, en **tres columnas de igual ancho**.
    ///
    /// Repartidas y no pegadas unas a otras porque así caen en la misma vertical fila tras fila: con
    /// los dígitos de ancho fijo de `rowFigure`, la lista pasa a tener columnas de cifras que se
    /// comparan de un vistazo, y de paso el renglón deja de dejar vacía media fila. Es la única cosa
    /// de la fila que se dibuja como tabla, y lo es porque es la única que se lee comparando.
    ///
    /// El reloj que acompañaba a la duración se fue: no decía nada que `1 min 17 s` no dijera ya, y un
    /// icono que solo repite su propio valor es adorno — en una fila que se repite doscientas veces,
    /// adorno doscientas veces. Las flechas se quedan porque son lo contrario: son lo único que separa
    /// lo recibido de lo enviado sin gastar dos palabras en cada fila.
    private var figures: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.tight))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Spacing.close))
        return layout {
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
            Text(presentation.duration)
                .font(.rowFigure)
                .foregroundStyle(Color(.neutral))
                .column()
        }
    }

    private func transferLabel(symbol: String, color: Color, bytes: String) -> some View {
        Label {
            Text(bytes).font(.rowFigure)
        } icon: {
            Image(systemName: symbol).font(.metricLabel).foregroundStyle(color)
        }
        .labelStyle(.titleAndIcon)
        .column()
    }
}

private extension View {

    /// Una de las columnas de igual ancho del renglón de cifras. Apilada —cuerpos de accesibilidad—
    /// no reparte nada y solo estira: ahí las cifras se leen una debajo de otra y no hay columnas que
    /// alinear.
    func column() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
    }
}
