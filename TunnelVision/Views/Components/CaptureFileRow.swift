import SwiftUI

/// Una fila de la pantalla de capturas: un fichero `.pcap` con su tamaño, su hora y su salida.
///
/// La fila no decide nada — si el fichero se puede compartir, si se está escribiendo y cómo se llama
/// viene ya resuelto en el `CaptureFileDisplay` que le pasan—; solo lo pinta. El compartir sí vive
/// aquí porque `ShareLink` **es** la hoja del sistema: no hay trabajo previo que hacer, el fichero ya
/// está escrito en disco y es un `.pcap` estándar.
///
/// **Aquí no hay carril de marcas, y eso es la regla de `FlowRow` aplicada y no copiada.** En la
/// Timeline el carril se gana su sitio porque cuatro estados se reparten esa columna y lo que los
/// distingue es la marca. Una captura solo tiene un supuesto —un fichero terminado— y una excepción
/// —el que la extensión está escribiendo ahora—, así que un símbolo en todas las filas diría *esto
/// es un fichero de captura* en una lista de ficheros de captura: exactamente el adorno que la fila
/// del historial acaba de quitarse. La excepción se escribe con palabras, que es lo que se hace con una
/// desviación; el supuesto calla.
struct CaptureFileRow: View {

    let file: CaptureFileDisplay

    /// Si esta fila es la que se está borrando ahora mismo. Se enseña porque borrar toca disco y una
    /// fila que no responde durante ese rato parecería un gesto perdido.
    let isDeleting: Bool

    /// En los cuerpos de accesibilidad las columnas fijas dejan de caber: el detalle envolvía en un
    /// listón de dos palabras por debajo del icono de compartir mientras un tercio del ancho se
    /// quedaba vacío. Apilado, cada cosa dispone del ancho entero.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        content
            .accessibilityElement(children: .contain)
    }

    // MARK: - Piezas

    /// El fichero y su acción, o los mismos datos apilados cuando la letra es de accesibilidad.
    ///
    /// La forma la decide el **umbral de tamaño de letra** y no un `ViewThatFits`, por lo mismo que
    /// en `FlowRow`: una fila se lee contra las demás, así que su forma no puede depender de cuántos
    /// caracteres midió su cifra — y `2.2 MB` y `986 KB` no miden igual. Con el umbral, todas las
    /// filas cambian a la vez.
    @ViewBuilder
    private var content: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Spacing.close) {
                description
                action
            }
        } else {
            HStack(alignment: .center, spacing: Spacing.row) {
                description
                action
            }
        }
    }

    /// Lo que el fichero es, en un solo elemento de accesibilidad: el nombre arriba con su tamaño a
    /// la derecha, y debajo cuándo empezó — con la palabra del estado delante cuando lo están
    /// escribiendo.
    ///
    /// **Un elemento y no tres.** El árbol de accesibilidad se recorre por posición, así que el botón
    /// de compartir —centrado contra el alto de la fila— caía entre el nombre y su propia línea de
    /// detalle: se oía «Capture 2», «Share Capture 2», «2.2 MB · 20 Aug at 05:49». La frase entera la
    /// compone el núcleo puro (`CapturesPresentation.rowAccessibilityValue`), que es donde el orden y
    /// las palabras se pueden afirmar.
    private var description: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            headline

            secondLine
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(file.title)
        .accessibilityValue(
            CapturesPresentation.rowAccessibilityValue(
                size: file.sizeText,
                time: timeText,
                isRecording: file.isRecording
            )
        )
    }

    /// El nombre y el tamaño. En una línea mientras quepan; apilados en los cuerpos de accesibilidad,
    /// donde el nombre solo ya se lleva el ancho entero y el tamaño detrás lo dejaría en dos palabras
    /// por línea.
    private var headline: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.tight))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Spacing.close))
        return layout {
            Text(file.title)
                .font(.cardTitle)
                // Hace el trabajo del `Spacer` que separaría el nombre del tamaño, que apilado se
                // comería el alto en vez del ancho.
                .frame(maxWidth: .infinity, alignment: .leading)

            size
        }
    }

    /// Cuánto ocupa, en su propia columna y con el papel de cifra de fila densa.
    ///
    /// Se separó de la hora, con la que compartía un renglón gris unidas por un `·`, porque las dos
    /// se leen por razones distintas: la hora **sitúa** un fichero y se lee sola, el tamaño se lee
    /// **comparando** —cuál de estas capturas es la gorda— y comparar exige que las cifras caigan en
    /// la misma vertical fila tras fila. Es el mismo motivo por el que las tres cifras de la Timeline
    /// se reparten en columnas, y por el que aquí van con los dígitos de ancho fijo de `rowFigure`:
    /// un inventario existe para leerse de un vistazo, y su única cifra iba escrita como prosa.
    ///
    /// Pegada al final de la línea —el nombre se queda con el ancho sobrante— y no a continuación
    /// del nombre: una cantidad se compara por su final y no por su principio (`2.2 MB` contra
    /// `986 KB`), así que lo que tiene que caer en la misma vertical es el borde derecho.
    private var size: some View {
        Text(file.sizeText)
            .font(.rowFigure)
            .multilineTextAlignment(.trailing)
    }

    /// Cuándo empezó el fichero, con la palabra del estado delante si lo están escribiendo.
    ///
    /// Sin separador dibujado entre las dos, igual que en `FlowRow`: lo que las separa es el color, y
    /// un `·` metido aquí sería componer copia en la vista, que es donde ningún traductor llega. Un
    /// fichero cuya fecha no se pudo leer deja el renglón sin hora en vez de dejar un hueco con
    /// puntuación colgando.
    private var secondLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.close) {
            if file.isRecording {
                recordingBadge
            }

            if let createdAt = file.createdAt {
                Text(createdAt, format: Date.FormatStyle.dayAndTime)
                    .font(.metricLabel)
                    .foregroundStyle(Color(.neutral))
            }
        }
    }

    /// El estado del fichero abierto, con icono **y** etiqueta **y** color: nunca solo color
    /// (`docs/ux/design-system.md`).
    private var recordingBadge: some View {
        Label(CapturesPresentation.recordingBadgeTitle, systemImage: "record.circle")
            .font(.badge)
            .foregroundStyle(StatusRole.accent.color)
            .labelStyle(.titleAndIcon)
    }

    /// La salida de la fila, en una ranura de ancho fijo **esté o no ocupada**.
    ///
    /// El ancho se reserva aunque no haya nada que poner porque el fichero abierto no se comparte:
    /// sin reservarlo, su tamaño se iría 44 pt a la derecha de los demás y la columna de cifras — que
    /// es justo lo que este renglón viene a alinear— tendría un peldaño en la fila de arriba.
    ///
    /// Apilada, la ranura no reserva nada: ahí no hay columnas que alinear y un hueco de un dedo
    /// sobre el renglón anterior sería un vacío sin razón.
    @ViewBuilder
    private var action: some View {
        if dynamicTypeSize.isAccessibilitySize {
            trailing
        } else {
            trailing
                .frame(width: TouchTarget.minimum, alignment: .trailing)
        }
    }

    /// El botón de compartir, **medido**. El relleno vertical que la fila se ponía a mano se fue con
    /// él: existía para dar aire a dos renglones de 38 pt, y un objetivo táctil de 44 pt ya es más
    /// alto que eso — sumar los dos dejaba la fila en 82 pt para decir lo mismo.
    ///
    /// El icono suelto entregaba un objetivo táctil de **18 × 21 pt** —menos de la mitad del mínimo
    /// de la HIG— siendo la acción principal de la pantalla y estando en todas las filas.
    /// `idb ui describe-all` devuelve el marco que de verdad recibe el dedo, y el mínimo es un token
    /// desde la Dashboard (`TouchTarget.minimum`). El marco va en el **rótulo** y no en el botón, que
    /// es el otro defecto que ya costó tres sitios: puesto en el botón, lo que recibe el toque sigue
    /// siendo el icono.
    @ViewBuilder
    private var trailing: some View {
        if isDeleting {
            ProgressView()
                .frame(minWidth: TouchTarget.minimum, minHeight: TouchTarget.minimum)
        } else if file.isActionable {
            ShareLink(item: file.url) {
                shareLabel
                    .frame(minWidth: TouchTarget.minimum, minHeight: TouchTarget.minimum)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(CapturesPresentation.shareAccessibilityLabel(for: file))
        }
    }

    /// El rótulo del botón: solo el símbolo mientras el final de la fila lo explique, símbolo **y**
    /// palabra cuando la fila se apila y el botón se queda solo en el margen izquierdo.
    @ViewBuilder
    private var shareLabel: some View {
        let label = Label(CapturesPresentation.shareActionTitle, systemImage: "square.and.arrow.up")

        if dynamicTypeSize.isAccessibilitySize {
            label.labelStyle(.titleAndIcon)
        } else {
            label.labelStyle(.iconOnly)
        }
    }

    /// El día y la hora del fichero, con el formato que comparten los dos instantes de esta pantalla
    /// (`Date.FormatStyle.dayAndTime`): se leen uno contra otro, así que se escriben igual.

    /// La misma hora en texto, que es lo que oye VoiceOver: la frase de la fila la compone el núcleo
    /// puro y necesita la hora ya resuelta con el huso del dispositivo.
    private var timeText: String? {
        file.createdAt?.formatted(Date.FormatStyle.dayAndTime)
    }
}
