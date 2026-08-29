import Charts
import SwiftUI
import Shared

/// La barra de scrub de la Timeline (`docs/ux/screens.md`): un eje temporal del historial que filtra
/// la lista al tramo que se toque y **baja a él** si dentro hay algo que mirar, o al tramo que se
/// **barra** con el dedo si lo que se quiere acotar son varias barras.
///
/// Como el gráfico de la Dashboard, recibe las barras **con los huecos ya rellenos a cero** —eso lo
/// decide `TimelineActivity`, no esta vista— y no calcula nada: qué se dibuja, qué se resalta, qué
/// dice la barra de sí misma y con qué precisión se fecha son funciones puras de `ScrubPresentation`,
/// y el tramo que corresponde a un arrastre lo redondea el propio eje (`ActivityAxis.sweep`).
///
/// Lo que no depende del dedo llega además **ya compuesto** (`ScrubAxisPresentation`): este `body` se
/// reevalúa mientras se arrastra, y una cadena que sale del catálogo no se pide por fotograma. Lo que
/// sigue componiéndose aquí es lo que depende del dedo o del cursor, y solo cuando cambia.
struct ScrubBar: View {

    let axis: ActivityAxis

    /// El tramo que se resalta. No es siempre el que acota la lista: cuando se ha bajado a él, lo
    /// seleccionado es lo dibujado y no hay nada que señalar dentro del eje.
    let selection: ClosedRange<Date>?

    /// El tramo al que ha bajado el eje, o `nil` si abarca todo el historial.
    let viewing: ClosedRange<Date>?

    /// Si además de "atrás" merece la pena ofrecer la salida directa.
    let offersFullReset: Bool

    /// Lo que la barra dice de sí misma —el aviso y lo que VoiceOver oye del eje—, compuesto donde
    /// vive el eje y no aquí: son tres cadenas con sus búsquedas en el catálogo, y este `body` se
    /// reevalúa con cada fotograma de un arrastre.
    let presentation: ScrubAxisPresentation

    /// Lo que haya que contar sobre la barra ahora mismo (hoy: que la retención se llevó el tramo).
    let notice: String?

    let onSelect: (ActivityBar) -> Void
    let onSelectRange: (ClosedRange<Date>) -> Void
    let onClear: () -> Void
    let onZoomOut: () -> Void
    let onShowWholeHistory: () -> Void

    /// El tramo que el dedo está barriendo ahora mismo. Vive aquí y no en el view model porque
    /// todavía no es una decisión: la lista se acota **al soltar**, no a cada fotograma del arrastre
    /// —filtrar mientras se arrastra sería una consulta al historial por píxel recorrido—, así que
    /// mientras dura el gesto lo único que existe es lo que la barra enseña.
    @State private var sweeping: ClosedRange<Date>?

    /// El tramo que señala quien recorre el eje sin verlo, y el extremo que haya fijado. Es de la
    /// vista por lo mismo que `sweeping`: hasta que se activa no es una decisión, solo un sitio.
    @State private var cursor: ScrubCursor?

    /// Con los cuerpos de accesibilidad las filas del pie no caben en horizontal: la fecha del tramo
    /// ocupa la línea entera y los botones se quedarían sin sitio o truncarían la fecha.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// El relleno lo pone la tarjeta que la contiene (`TimelineView.scrub`) y no la barra: si lo
    /// pusieran los dos, el eje quedaría hundido dentro de su tarjeta sin que nadie hubiera decidido
    /// ese hueco.
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.close) {
            chart
            caption
        }
    }

    // MARK: - El eje

    /// Los nombres de las dimensiones del gráfico **no son copia**: el eje Y va oculto, el X se
    /// etiqueta con fechas y VoiceOver no los oye nunca —el gráfico es un solo elemento con su nombre
    /// puesto a mano—. Como literales, Swift Charts los toma por `LocalizedStringKey` y el extractor
    /// los mete en el catálogo, que es como llegaron allí *From*, *To* y *Packets*; pasándolos como
    /// `String` se elige la otra sobrecarga y dejan de ser unidades de traducción. Es el mismo cierre
    /// que `Text(verbatim:)` en el número de un paso del flujo de la CA.
    private static let startDimension = "From"
    private static let endDimension = "To"
    private static let countDimension = "Packets"

    /// **El eje no lleva etiquetas dentro: quien lo fecha es el pie**, y a todos los tamaños de letra.
    ///
    /// Empezó siendo una excepción de los cuerpos de accesibilidad —a esos tamaños dos etiquetas se
    /// tocan y se leen como una sola cadena, y la del extremo, centrada en su marca, se sale del
    /// gráfico y se recorta (`11 Aug at`)— y es la regla desde que los tramos del eje tienen que medir
    /// lo que mide un dedo. Reservar dentro del dibujo sitio para media etiqueta a cada lado costaba
    /// **84 puntos** del ancho de la pantalla, que son casi dos tramos: se gastaban en decir con menos
    /// precisión lo que el pie ya dice mejor —los **dos** extremos, con la fecha completa cuando hace
    /// falta, envolviendo en vez de truncando—. Y de paso desaparece la trampa de la etiqueta cortada,
    /// que no fechaba nada y encima se leía como si fechara.
    private var chart: some View {
        Chart(axis.bars) { bar in
            // `RectangleMark` con los dos extremos en el eje X y no `BarMark`: la anchura de la barra
            // *es* la duración del tramo, y dibujarla así hace que el eje sea continuo y que el punto
            // que el dedo toca se pueda traducir a un instante.
            RectangleMark(
                xStart: .value(Self.startDimension, bar.start),
                xEnd: .value(Self.endDimension, bar.end),
                yStart: .value(Self.countDimension, 0),
                yEnd: .value(Self.countDimension, bar.packetCount)
            )
            // La barra apagada sigue siendo un objeto gráfico que hay que ver, así que su opacidad
            // es un token medido (`MarkOpacity.dimmed`) y no un medio tono a ojo: con el que había,
            // en claro el eje sin seleccionar daba 1,98:1 sobre su fondo, por debajo del 3:1 que
            // pide WCAG para lo que se lee sin texto encima.
            .foregroundStyle(
                ScrubPresentation.isSelected(bar, selection: marked)
                    ? StatusRole.accent.color
                    : StatusRole.neutral.color.opacity(MarkOpacity.dimmed)
            )
        }
        .chartYAxis(.hidden)
        .chartXAxis(.hidden)
        // El carril por el que pasa el dedo, y por eso su altura es el mínimo táctil y no un número
        // elegido a ojo: con los 56 puntos que tenía, el eje era una franja en la que había que
        // afinar también en vertical. El doble del mínimo le da al gesto sitio de sobra y —lo que se
        // ve— le da a las barras altura para tener forma en vez de ser un borrón contra el borde.
        .frame(height: TouchTarget.minimum * 2)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        select(at: location, proxy: proxy, geometry: geometry)
                    }
                    // La distancia mínima es lo que separa los dos gestos: sin ella, cualquier toque
                    // con un temblor de un píxel se leería como un arrastre de una sola barra y
                    // dejaría de bajar el eje, que es lo que el toque existe para hacer.
                    .gesture(
                        DragGesture(minimumDistance: 12)
                            .onChanged { drag in
                                let range = sweptRange(of: drag, proxy: proxy, geometry: geometry)
                                // El tramo barrido está redondeado a barras enteras, así que un dedo
                                // que recorre una barra da el mismo valor decenas de veces. Escribir
                                // el estado igual no es gratis: invalida la barra entera —gráfico
                                // incluido— y vuelve a componer su pie, por fotograma. Con esto el
                                // arrastre solo redibuja al cruzar de tramo, que es cuando cambia
                                // algo de lo que se enseña.
                                guard range != sweeping else { return }
                                sweeping = range
                            }
                            .onEnded { drag in
                                let range = sweptRange(of: drag, proxy: proxy, geometry: geometry)
                                sweeping = nil
                                if let range { onSelectRange(range) }
                            }
                    )
            }
        }
        // El eje entero es un solo elemento para VoiceOver: leer barra a barra sería recitar decenas
        // de cuentas sin forma. El nombre dice lo que un vidente saca de un vistazo, y el valor lo que
        // señala el cursor, que es lo único que se mueve al recorrerlo.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(cursorValue)
        .accessibilityHint(presentation.accessibilityHint)
        .accessibilityAddTraits(.isButton)
        .accessibilityAdjustableAction { direction in
            guard let current = cursor else { return }
            switch direction {
            case .increment: cursor = ScrubAccessibility.moved(current, by: 1, on: axis)
            case .decrement: cursor = ScrubAccessibility.moved(current, by: -1, on: axis)
            @unknown default: break
            }
        }
        .accessibilityAction { activateCursor() }
        .accessibilityActions {
            // Las que sustituyen al arrastre: fijar un extremo, aplicar lo elegido o soltarlo. Cuáles
            // se ofrecen lo decide el núcleo puro, no esta vista.
            ForEach(cursor.map { ScrubAccessibility.actions(for: $0, on: axis) } ?? []) { action in
                Button(action.label) { perform(action) }
            }
        }
        // El cursor se reencaja cuando el eje cambia —y ahí se suelta la selección en curso, porque
        // las barras se re-alinean y el extremo fijado ya no señalaría el mismo trozo del pasado.
        .onAppear { cursor = ScrubAccessibility.rebased(cursor, on: axis) }
        .onChange(of: axis) { cursor = ScrubAccessibility.rebased(cursor, on: axis) }
        // El eje va sobre una superficie hundida: es lo que lo separa de la tarjeta que lo sostiene y
        // lo que lo hace leerse como un carril por el que se pasa el dedo, y no como un dibujo suelto
        // sobre un rectángulo blanco. Va **al final** de la cadena, después de las modificaciones del
        // gráfico y del overlay del gesto: envolver el `Chart` en un fondo antes de ellas movería el
        // origen contra el que se traduce un toque en un instante.
        .sunkenSurface(padding: Spacing.tight, radius: CornerRadius.small)
    }

    // MARK: - El recorrido sin ver

    /// Lo que VoiceOver lee del tramo señalado. La vista solo **formatea las dos fechas**, que es lo
    /// único que depende del huso y del idioma del dispositivo; qué decir después, con qué precisión
    /// fecharlas y cómo se dicen juntas es del núcleo puro, que es donde se puede afirmar.
    private var cursorValue: String {
        guard let cursor, let reading = ScrubAccessibility.reading(for: cursor, on: axis) else {
            return ScrubAccessibility.noSelectionValue
        }
        return ScrubAccessibility.cursorValue(
            interval: intervalText(reading.interval, scale: reading.scale),
            detail: reading.detail
        )
    }

    /// Activar el eje aplica lo elegido: un tramo suelto si no hay extremo fijado —lo mismo que
    /// tocarlo— o el trozo entre los dos si lo hay.
    private func activateCursor() {
        guard let current = cursor,
              let activation = ScrubAccessibility.activation(for: current, on: axis)
        else {
            return
        }
        switch activation {
        case .interval(let bar):
            onSelect(bar)
        case .range(let range):
            cursor = ScrubAccessibility.cancelledRange(current)
            onSelectRange(range)
        }
    }

    private func perform(_ action: ScrubCursorAction) {
        guard let current = cursor else { return }
        switch action {
        case .beginRange:
            cursor = ScrubAccessibility.beganRange(current)
        case .commitRange:
            activateCursor()
        case .cancelRange:
            cursor = ScrubAccessibility.cancelledRange(current)
        }
    }

    /// El tramo que se está eligiendo ahora mismo y todavía no se ha aplicado: el del dedo que barre o
    /// el del cursor accesible que ya fijó un extremo. Son el mismo estado dicho de dos maneras, así
    /// que se dibujan igual — y mientras hay uno puesto no se ofrece *Clear*, que prometería deshacer
    /// un filtro que aún no existe.
    private var pending: ClosedRange<Date>? {
        sweeping ?? cursor.flatMap { ScrubAccessibility.pendingRange(for: $0, on: axis) }
    }

    /// Lo que la barra señala ahora mismo. Una elección en curso manda sobre lo que la lista tiene
    /// acotado: es lo que el usuario está eligiendo, y hasta que se aplique es lo único que hay que
    /// enseñar — el filtro de antes ya no es lo que está mirando.
    private var marked: ClosedRange<Date>? { pending ?? selection }

    /// Traduce el punto tocado en el tramo que le corresponde. Un toque fuera del área de dibujo —o
    /// en un instante que ningún tramo cubre— no hace nada: mover el filtro a un trozo que el usuario
    /// no ha señalado sería peor que ignorar el gesto.
    private func select(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let plotFrame = proxy.plotFrame else { return }
        let origin = geometry[plotFrame].origin
        guard let date = proxy.value(atX: location.x - origin.x, as: Date.self),
              let bar = axis.bar(containing: date)
        else {
            return
        }
        onSelect(bar)
    }

    /// El tramo que barre un arrastre: los dos extremos traducidos a instantes y redondeados a barras
    /// enteras por el eje, que es quien sabe dónde empiezan y acaban.
    private func sweptRange(
        of drag: DragGesture.Value, proxy: ChartProxy, geometry: GeometryProxy
    ) -> ClosedRange<Date>? {
        guard let from = instant(atX: drag.startLocation.x, proxy: proxy, geometry: geometry),
              let to = instant(atX: drag.location.x, proxy: proxy, geometry: geometry)
        else {
            return nil
        }
        return axis.sweep(from: from, to: to)
    }

    /// El instante de una coordenada, **acotándola antes al área de dibujo**: un dedo que entra o sale
    /// por el borde del gráfico da un punto que el eje no cubre, y en un arrastre eso es un extremo y
    /// no un motivo para descartar el gesto entero. El toque no lo hace, y por eso no comparten esta
    /// función: allí no hay un extremo hacia el que el dedo iba, solo un punto que nadie señaló.
    private func instant(atX x: CGFloat, proxy: ChartProxy, geometry: GeometryProxy) -> Date? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let frame = geometry[plotFrame]
        return proxy.value(atX: min(max(x, frame.minX), frame.maxX) - frame.minX, as: Date.self)
    }

    // MARK: - El pie

    /// Lo que la barra dice de sí misma: dónde está el eje y cómo se sale, qué tramo está señalado
    /// dentro de él, y **siempre** el aviso de que las cuentas del eje no están filtradas.
    ///
    /// Son dos filas y no una porque son dos cosas distintas: bajar a un tramo cambia lo que el eje
    /// abarca, y señalar uno dentro cambia lo que la lista enseña. Normalmente solo hay una puesta
    /// —tocar un tramo con contenido hace lo primero, y lo segundo solo pasa donde ya no se puede
    /// bajar—, pero cuando coinciden, cada una lleva su salida y ninguna habla por la otra.
    @ViewBuilder
    private var caption: some View {
        // Qué tramo abarca el eje. Es lo que decían las etiquetas de dentro y lo dice mejor: los dos
        // extremos y no tres puntos sueltos. Solo si no hay ya una fila diciéndolo — bajar a un tramo
        // hace que el eje **sea** ese tramo, y la fila de abajo ya lo fecha. No lleva copia nueva —es
        // el mismo tramo fechado con la misma función— y es **invisible para VoiceOver**, que nunca
        // oyó las etiquetas que sustituye: el eje ya se presenta él solo.
        if viewing == nil, let span = axis.span {
            captionRow(symbol: "clock.arrow.circlepath", interval: span) { EmptyView() }
                .accessibilityHidden(true)
        }

        if let viewing {
            captionRow(symbol: "arrow.up.left.and.arrow.down.right", interval: viewing) {
                Button(ScrubPresentation.zoomOutActionTitle, action: onZoomOut)
                    .buttonStyle(.borderless)
                if offersFullReset {
                    Button(ScrubPresentation.showWholeHistoryActionTitle, action: onShowWholeHistory)
                        .buttonStyle(.borderless)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(ScrubPresentation.viewingStretchLabel)
        }

        if let marked {
            captionRow(symbol: "clock", interval: marked) {
                // Mientras se elige un tramo, la fila es un contador de lo que se va a acotar y no hay
                // nada que soltar todavía: ofrecer "Clear" prometería deshacer un filtro que aún no
                // se ha puesto.
                if pending == nil {
                    Button(ScrubPresentation.clearSelectionActionTitle, action: onClear)
                        .buttonStyle(.borderless)
                }
            }
        }

        if let notice {
            Text(notice)
                .font(.badge)
                .foregroundStyle(StatusRole.warning.color)
                .fixedSize(horizontal: false, vertical: true)
        }

        Text(presentation.note)
            .font(.badge)
            .foregroundStyle(Color(.neutral))
            // La barra convive en un `VStack` con la lista, que se queda con todo lo que pueda: sin
            // esto, a los cuerpos de accesibilidad el pie se comprime a una línea y **se trunca**
            // (`Activity for everyt…`), que es justo lo que el design system prohíbe a esos tamaños.
            // Pedir el alto que hace falta hace que envuelva y que sea la lista la que ceda sitio.
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Una fila del pie: el tramo fechado y sus salidas. En los cuerpos normales van en una línea con
    /// los botones a la derecha; en los de accesibilidad los botones bajan a su propia línea, porque
    /// la fecha ya ocupa la entera y en horizontal uno de los dos tendría que truncarse.
    private func captionRow(
        symbol: String,
        interval: ClosedRange<Date>,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.tight))
            : AnyLayout(HStackLayout(spacing: Spacing.close))
        return layout {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.close) {
                Image(systemName: symbol)
                    .foregroundStyle(StatusRole.accent.color)
                intervalLabel(interval)
                    // Por lo mismo que el pie: una fecha recortada (`16 Aug at 18:…`) no fecha nada
                    // y encima se lee como si fechara.
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: Spacing.row) {
                actions()
            }
        }
        .font(.metricLabel)
    }

    /// Fecha el tramo con la precisión que le toca: la hora basta si empieza y acaba el mismo día, y
    /// si lo cruza hace falta la fecha o "de 22:00 a 04:00" no diría de qué noche habla.
    private func intervalLabel(_ interval: ClosedRange<Date>) -> Text {
        // `Text` de un `String` ya compuesto, y no de un literal: lo que se pinta salió del catálogo
        // en el núcleo puro, así que volver a pasarlo por una `LocalizedStringKey` lo buscaría otra
        // vez —esta vez por una clave que es la frase entera— y metería otra entrada en el catálogo.
        Text(intervalText(interval, scale: ScrubPresentation.scale(for: interval)))
    }

    /// El mismo texto, con la precisión ya decidida. Existe aparte porque el valor accesible la recibe
    /// del núcleo puro junto al tramo, y componer dos veces la misma fecha con criterios distintos
    /// dejaría al pie y a VoiceOver diciendo cosas diferentes del mismo trozo del pasado.
    ///
    /// Aquí solo se **formatea** cada extremo; juntarlos es del núcleo, porque el separador y el orden
    /// son de un idioma.
    private func intervalText(_ interval: ClosedRange<Date>, scale: ScrubTimeScale) -> String {
        switch scale {
        case .timeOfDay:
            ScrubPresentation.interval(
                from: interval.lowerBound.formatted(.dateTime.hour().minute()),
                to: interval.upperBound.formatted(.dateTime.hour().minute())
            )
        case .dateAndTime:
            ScrubPresentation.interval(
                from: interval.lowerBound.formatted(.dateTime.month().day().hour().minute()),
                to: interval.upperBound.formatted(.dateTime.month().day().hour().minute())
            )
        }
    }
}
