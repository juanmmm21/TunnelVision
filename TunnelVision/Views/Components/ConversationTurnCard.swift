import SwiftUI
import Shared

/// Una cosa dicha por uno de los dos lados de una conexión inspeccionada: quién habló, cuándo, y lo
/// que dijo.
///
/// **No se pinta como una burbuja de chat.** Alinear un lado a la derecha regala la mitad del ancho, y
/// lo que aquí se lee muchas veces es un volcado hexadecimal o una cabecera HTTP, que necesitan la
/// línea entera y unas columnas que cuadren. Quién habló lo lleva la cabecera —el icono del sentido,
/// la misma palabra que usa toda la app y la altura dentro de la conexión—, que es como se dice en el
/// resto de las listas de este producto.
///
/// **El color va en la marca y no en el titular** (segunda pasada, 2026-08-20). La cabecera pintaba
/// icono *y* palabra en el color del sentido y a cuerpo de titular, así que el elemento con más
/// contraste de una pantalla que existe para enseñar lo que se dijo era la palabra *Sent* — repetida,
/// alternándose y previsible— por encima del material que describe. Es la misma corrección que la fila
/// de la Timeline: la tinta de color se queda en el símbolo, que es lo que se sigue con la vista
/// bajando por la lista, y el titular va en tinta normal como el host de una conexión o el nombre de
/// una captura.
struct ConversationTurnCard: View {

    let row: ConversationTurnRow

    /// La cabecera se apila con letra de accesibilidad, por lo mismo que la fila de un paquete: tres
    /// cosas en una línea y un `HStack` que no envuelve acaban recortando la primera.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var presentation: ConversationTurnPresentation { row.presentation }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.close) {
            header
            body(of: row.body)
            notes
        }
    }

    // MARK: - Cabecera

    /// Quién habló y su salida. La acción va **fuera** del elemento que se lee de una vez, que es lo
    /// único que la deja alcanzable con VoiceOver: es la misma forma que la fila de una captura.
    private var header: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.tight))
            : AnyLayout(HStackLayout(alignment: .center, spacing: Spacing.close))

        return layout {
            speaker
            action
        }
    }

    /// Quién habló, cuándo dentro de la conexión y cuánto se guardó, **en un elemento y no en tres**.
    ///
    /// El árbol de accesibilidad se recorría como *«Sent», «2.694 s», «111 B»* — tres paradas para
    /// una frase que el núcleo puro ya componía, tenía test y **no usaba nadie**
    /// (`ConversationTurnPresentation.accessibilityLabel`): la cabecera decía en un comentario que se
    /// oía como una sola frase, y `children: .contain` es justo lo que **no** hace eso. Es el mismo
    /// defecto que la fila de una captura se quitó, y se arregla igual.
    private var speaker: some View {
        // Apilado con letra de accesibilidad, por lo mismo que la fila de un paquete y la de una
        // captura: un `HStack` no envuelve, así que ahí la palabra del sentido se partía por la
        // mitad —*S / ent*— con dos cifras al lado quedándose sin ancho. Y apilada no hay columna
        // que cuadrar, así que la cifra deja de tirar hacia el margen.
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.tight))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Spacing.close))

        return layout {
            Label {
                Text(presentation.direction)
                    .font(.cardTitle)
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(tint)
            }
            .font(.cardTitle)

            // Sitúa el turno dentro de la conexión, y por eso se queda pegado a quien habló: es el
            // mismo dato —y el mismo papel— que el instante de un paquete en su lista. Hace además
            // el trabajo del `Spacer` que empujaba la cifra al margen, que apilado se comería el
            // alto en vez del ancho.
            Text(presentation.offset)
                .font(.rowFigure)
                .foregroundStyle(Color(.neutral))
                .frame(maxWidth: .infinity, alignment: .leading)

            size
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    /// Cuánto se guardó del turno, al final de la línea y con los dígitos de ancho fijo de la cifra de
    /// fila densa.
    ///
    /// Iba pegada al instante, en el mismo cuerpo y el mismo gris, y las dos se leen por razones
    /// distintas: el instante **sitúa** el turno y se lee solo, el tamaño se lee **comparando** —quién
    /// dijo más, y dónde está el turno gordo—, y comparar exige que las cifras caigan en la misma
    /// vertical tarjeta tras tarjeta. Medido en el Simulator, tres turnos seguidos ponían su tamaño en
    /// tres verticales distintas, porque cada uno empezaba donde acabara el instante de antes. Es la
    /// misma corrección que la fila de una captura, y por el mismo motivo.
    ///
    /// Un turno que no se pudo leer no lleva cifra: no hay nada cuyo tamaño describa, que es lo que
    /// dice también la frase que oye VoiceOver.
    @ViewBuilder
    private var size: some View {
        if case .unavailable = row.body {
            EmptyView()
        } else {
            Text(presentation.size)
                .font(.rowFigure)
                .multilineTextAlignment(.trailing)
        }
    }

    /// La salida del turno, en una ranura de ancho fijo **esté o no ocupada**.
    ///
    /// Se reserva el ancho porque un turno sin nada que compartir —el que no dijo un solo byte— dejaría
    /// su tamaño 44 pt a la derecha del de los demás, y la columna que la cifra viene a formar tendría
    /// un peldaño justo ahí. Apilada no se reserva nada: ahí no hay columna que alinear.
    @ViewBuilder
    private var action: some View {
        if dynamicTypeSize.isAccessibilitySize {
            share
        } else {
            share
                .frame(width: TouchTarget.minimum, alignment: .trailing)
        }
    }

    /// El sentido, con el mismo símbolo que el gráfico, las fichas y la lista de paquetes: leerlos
    /// juntos exige que los dos sentidos se digan igual en toda la app.
    private var icon: String {
        row.turn.direction == .inbound
            ? TrafficDirectionStyle.inboundSymbol
            : TrafficDirectionStyle.outboundSymbol
    }

    /// Y el mismo color, por lo mismo: en una lista larga es lo que deja seguir la conversación sin
    /// leer cada cabecera.
    private var tint: Color {
        row.turn.direction == .inbound
            ? TrafficDirectionStyle.inboundColor
            : TrafficDirectionStyle.outboundColor
    }

    /// Solo cuando hay algo que sacar: compartir un hueco daría una cadena vacía. Lo que entrega es
    /// **todo** lo que se guardó del turno y no la vista previa de debajo, que es lo que hace que el
    /// aviso de recorte pueda decir dónde está el resto.
    ///
    /// **Medido**: el icono suelto entregaba un objetivo táctil de **19 × 22 pt**, menos de la mitad
    /// del mínimo de la HIG, siendo la única acción de la pantalla y estando en todas las tarjetas.
    /// El marco va en el **rótulo** y no en el botón, que es el defecto que ya costó cuatro sitios:
    /// puesto en el botón, lo que recibe el toque sigue siendo el icono.
    @ViewBuilder
    private var share: some View {
        if let text = row.shareable {
            ShareLink(item: text) {
                shareLabel
                    .frame(minWidth: TouchTarget.minimum, minHeight: TouchTarget.minimum)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
        }
    }

    /// Solo el símbolo mientras la cifra de al lado explique el final de la línea; símbolo **y**
    /// palabra cuando la cabecera se apila y el botón se queda solo en el margen izquierdo. Igual que
    /// en la fila de una captura.
    @ViewBuilder
    private var shareLabel: some View {
        let label = Label(ConversationPresentation.shareTitle, systemImage: "square.and.arrow.up")

        if dynamicTypeSize.isAccessibilitySize {
            label.labelStyle(.titleAndIcon)
        } else {
            label.labelStyle(.iconOnly)
        }
    }

    // MARK: - Cuerpo

    @ViewBuilder
    private func body(of body: ConversationBody) -> some View {
        switch body {
        case .text(let text):
            // Seleccionable a propósito: copiar un trozo de una cabecera es el gesto natural aquí, y
            // sin esto la única salida sería compartir el turno entero.
            //
            // Hundido dentro de la tarjeta por lo mismo que el volcado de un paquete: lo que se dijo
            // por dentro de la conexión no es la descripción del turno sino el material que la
            // cabecera describe, y el escalón lo dice sin gastar una línea.
            Text(text)
                .font(.literal)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .sunkenSurface()

        case .hex(let lines):
            // Se desplaza en horizontal como un bloque, igual que en la pantalla de un paquete: partir
            // una línea de 16 bytes en dos renglones destruye lo único que hace legible un volcado.
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    ForEach(lines) { line in
                        HexDumpRow(line: line)
                    }
                }
            }
            .sunkenSurface()

        case .unavailable(let reason):
            // Y esto **no** se hunde: no hay material que enseñar, así que un carril vacío sería un
            // hueco que promete algo que no está.
            Text(ConversationPresentation.placeholder(for: reason).title)
                .font(.supporting)
                .foregroundStyle(Color(.neutral))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Avisos

    /// Los dos recortes, y en este orden: primero lo que **no se guardó** (que no vuelve) y después lo
    /// que solo **no se dibuja** (que sigue en el dispositivo). Confundirlos es lo que la pantalla del
    /// paquete ya separa en dos claves.
    @ViewBuilder
    private var notes: some View {
        if let note = presentation.truncationNote {
            // Lo que **no se guardó** lleva icono y lo que solo no se dibuja no: es la diferencia
            // entre algo que no vuelve y algo que sigue en el dispositivo, y sin una marca las dos
            // notas eran dos líneas grises seguidas que nadie distingue. El color va en el icono y no
            // en el párrafo, como en *Session diagnostics*: un texto entero en el token de aviso se
            // lee como una alarma, y esto no lo es.
            Label {
                Text(note)
                    .font(.supporting)
                    .foregroundStyle(Color(.neutral))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "scissors")
                    .foregroundStyle(Color(.warning))
            }
            .font(.supporting)
        }
        if let note = presentation.bodyNote {
            Text(note)
                .font(.supporting)
                .foregroundStyle(Color(.neutral))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
