import SwiftUI

/// El intro de la primera ejecución (M10, `docs/ux/onboarding-and-consent.md`): tres tarjetas
/// saltables y, al final, *Start monitoring*.
///
/// La vista no decide nada: la copia, el orden, qué dice cada botón y qué significa terminar salen de
/// `IntroPresentation` y de `IntroViewModel`. Lo único que resuelve aquí es el deslizamiento entre
/// tarjetas, que es un gesto y no una decisión — y aun así se lo cuenta al view model, para que la
/// tarjeta que se ve y la que el modelo cree que se ve no puedan separarse.
///
/// Desde M11 ese deslizamiento tiene su equivalente para quien no ve el mazo: la tarjeta se recorre y
/// ofrece volver o plantarse en la última. Qué se ofrece y adónde lleva lo decide `IntroAccessibility`,
/// y las dos formas de moverse acaban en el mismo `show(_:)` — si no, lo que aplica un dedo y lo que
/// aplica VoiceOver podrían separarse.
///
/// Desde el paso 8 del roadmap lleva además el sistema visual, y es la **primera pantalla que se ve
/// de la app**: aquí una tarjeta del mazo por fin es una tarjeta de verdad
/// (`docs/ux/design-system.md`).
struct IntroView: View {

    let viewModel: IntroViewModel

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// **Dónde viven los dos botones**, que es la única decisión de layout de esta pantalla y la misma
    /// que ya tomó el flujo de la CA. Anclados abajo son lo correcto mientras ocupen lo que ocupa una
    /// fila de botones; con letra de accesibilidad *Start monitoring* es un botón de dos líneas y la
    /// banda se lleva más de un tercio de la pantalla — justo la que **es** el texto que hay que leer,
    /// que se quedaba cortado a media palabra por debajo del indicador. A esos tamaños los botones
    /// bajan al final de la tarjeta y la página entera se desplaza como una sola cosa.
    private var scrollsActions: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        VStack(spacing: 0) {
            TabView(
                selection: Binding(
                    get: { viewModel.card },
                    set: { viewModel.show($0) }
                )
            ) {
                ForEach(IntroPresentation.cards) { card in
                    IntroCardView(
                        presentation: IntroPresentation.forCard(card),
                        onGoTo: { viewModel.show($0) }
                    ) {
                        // Con letra de accesibilidad los botones viajan **dentro** de la página, así
                        // que son los de esa tarjeta y no los de la que el view model tenga por
                        // actual: solo la página visible se puede tocar, pero de este modo no hay dos
                        // fuentes para lo mismo.
                        if scrollsActions { actions(for: IntroPresentation.forCard(card)) }
                    }
                    .tag(card)
                }
            }
            // El índice del `TabView` se dibuja **encima** de la página, y el contenido de una tarjeta
            // se desplaza: con letra de accesibilidad el texto pasa por debajo de los puntos, que es el
            // solape que `docs/ux/design-system.md` prohíbe. Un hueco al final del contenido solo salva
            // la última línea, no las de en medio, así que el índice se dibuja aquí, en el flujo.
            .tabViewStyle(.page(indexDisplayMode: .never))

            // El indicador sí se queda fijo a todos los tamaños, y puede: es lo único de la pantalla
            // que **no** crece con la letra, así que nunca se come el sitio del texto.
            PageIndicator(cards: IntroPresentation.cards, current: viewModel.card)

            if !scrollsActions { actions(for: viewModel.presentation) }
        }
        // El lienzo va aquí, en el contenedor, y esta es la única pantalla donde eso no es la trampa
        // que costó tres builds: el intro se presenta a pantalla completa y **no tiene barra de
        // navegación**, así que no hay título grande que perder.
        .screenCanvas()
    }

    /// Los dos botones. La salida está en **todas** las tarjetas, incluida la última: la regla de
    /// consentimiento de la spec dice que nunca hay un solo botón.
    private func actions(for presentation: IntroPresentation) -> some View {
        VStack(spacing: Spacing.row) {
            Button {
                viewModel.performPrimaryAction()
            } label: {
                Text(presentation.actionTitle)
                    // El ancho va en el **rótulo** y no en el botón: puesto fuera, el relleno sigue
                    // ciñéndose al texto y lo único que crece es el área tocable — que es lo que le
                    // pasaba a este botón, una pastilla estrecha en mitad de la pantalla.
                    .frame(maxWidth: .infinity)
            }
            // `.brandProminentButton()` y no `.borderedProminent` a secas, por lo mismo que en el
            // flujo de la CA: el relleno por defecto es el acento global, que es la marca **como
            // tinta** y en oscuro tiene que ser clara. Este botón era rótulo blanco sobre cian claro.
            .brandProminentButton()
            .controlSize(.large)

            Button {
                viewModel.skip()
            } label: {
                Text(presentation.skipTitle)
                    // La salida **no** es el botón de segunda de esta pantalla: la regla de
                    // consentimiento de la spec dice que nunca hay un solo botón, así que es el que
                    // hace legal al de arriba — y medía 31 × 19 puntos, o sea que era lo más difícil
                    // de acertar de la pantalla. Como en las otras cuatro veces que salió esta
                    // trampa, el marco va en el **rótulo**: puesto en un botón sin relleno propio no
                    // agranda nada, porque lo que recibe el toque es el texto.
                    .frame(minWidth: TouchTarget.minimum, minHeight: TouchTarget.minimum)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, Spacing.section)
        .padding(.bottom, Spacing.section)
        .padding(.top, Spacing.close)
    }
}

/// Dónde está el mazo, dibujado en el flujo y no sobre la página. Es lo mismo que enseña el índice del
/// `TabView`, y existe aparte por una sola razón: el del sistema solo sabe flotar encima del contenido.
private struct PageIndicator: View {

    let cards: [IntroCard]
    let current: IntroCard

    var body: some View {
        HStack(spacing: Spacing.close) {
            ForEach(cards) { card in
                Circle()
                    // El punto en el que se está lleva la marca; los demás, el neutral apagado. La
                    // opacidad no es un gusto: un punto es un objeto gráfico sin texto encima, así que
                    // lo que lo separa del lienzo se mide con el 3:1 de WCAG 1.4.11, igual que las
                    // barras del eje de la Timeline — y por eso reutiliza su token en vez de un medio
                    // tono escrito aquí.
                    .fill(card == current
                        ? Color(.brand)
                        : Color(.neutral).opacity(MarkOpacity.dimmed))
                    // El punto no crece con la letra: no es texto sino una marca de posición, y a
                    // tamaño AX5 escalarla se comería el sitio que este indicador acaba de devolverle
                    // al contenido. El control de páginas del sistema tampoco escala.
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, Spacing.card)
        // Cuántas tarjetas hay y en cuál se está ya lo dice la propia tarjeta al oírla
        // (`IntroAccessibility.stepValue`), así que repetirlo aquí solo alargaría el recorrido.
        .accessibilityHidden(true)
    }
}

/// Una tarjeta: símbolo, titular y una explicación. Sin ilustración propia — el sistema de diseño
/// pide contención y SF Symbols, no cromo (`docs/ux/design-system.md`).
private struct IntroCardView<Actions: View>: View {

    let presentation: IntroPresentation

    /// Ir a otra tarjeta del mazo. La vista no elige a cuál: se lo dice `IntroAccessibility`, igual que
    /// el eje de la Timeline. Lo llama el recorrido sin vista; el deslizamiento normal ya va por la
    /// selección del `TabView`, que también acaba en `show(_:)`.
    let onGoTo: (IntroCard) -> Void

    /// Los botones, cuando con letra de accesibilidad bajan aquí dentro. Vacío el resto del tiempo.
    @ViewBuilder let actions: () -> Actions

    /// El símbolo sigue al cuerpo de letra —fijo, con letra de accesibilidad quedaría diminuto al lado
    /// del titular al que acompaña— y arranca del mismo tamaño que el de la etapa del flujo de la CA,
    /// que es la misma composición: símbolo, titular y prosa.
    ///
    /// Lo que sí cambia es **la curva**: escala como `.largeTitle`, que es la más plana de la escala,
    /// y no como el `title2` del titular. El motivo es que aquí el símbolo va dentro de un disco, o sea
    /// que ocupa más que su lado: con la curva del titular, a AX5 el adorno se llevaba **un tercio de
    /// la pantalla** antes de la primera palabra. Es la misma regla que la de los puntos del mazo,
    /// medio paso más suave — lo que no es texto no se lleva el sitio del texto.
    ///
    /// Y desde la segunda pasada esa regla se aplica también al **tamaño** y no solo a la curva: con
    /// 44 puntos de lado el conjunto medía 88 y se llevaba el 38 % del alto del contenido de la
    /// tarjeta —más que el titular y casi tanto como la prosa entera—, así que un mazo que existe
    /// para leerse empezaba por un adorno. Treinta lo deja en algo más de un cuarto.
    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize: CGFloat = 30

    /// El suelo de alto del contenido de la carta (`DeckCard.minimumContentHeight`), escalado con la
    /// prosa que lleva dentro: un suelo fijo bajo un texto que crece es un recorte esperando a
    /// ocurrir. Sigue la curva del **cuerpo**, que es lo que decide cuántas líneas tiene la carta, y
    /// no la del titular. Mide el contenido y no la carta: el relleno de la superficie va aparte.
    @ScaledMetric(relativeTo: .body) private var minimumContentHeight: CGFloat =
        DeckCard.minimumContentHeight

    var body: some View {
        // Una tarjeta que cabe se **centra**; una que no cabe se desplaza. Las dos cosas hacen falta y
        // ninguna sirve para la otra: pegada arriba, la tarjeta dejaba media pantalla de lienzo vacío
        // debajo, y centrada a la fuerza se quedaría sin sitio en cuanto la letra crece o una
        // traducción se alarga —y truncar aquí está prohibido—. `ViewThatFits` decide eso por página y
        // sin medir nada, que es lo que evita meter un `GeometryReader` dentro del `TabView` (de donde
        // salió el marco `NaN` que dejó al intro fuera de VoiceOver).
        ViewThatFits(in: .vertical) {
            page(centred: true)
            ScrollView { page(centred: false) }
        }
    }

    private func page(centred: Bool) -> some View {
        VStack(spacing: 0) {
            if centred { Spacer(minLength: 0) }

            VStack(spacing: Spacing.section) {
                card

                actions()
                    // Los botones ya traen su propio aire lateral; dentro de la página sobra el de la
                    // tarjeta.
                    .padding(.horizontal, -Spacing.card)
            }

            if centred { Spacer(minLength: 0) }
        }
        .padding(.horizontal, Spacing.card)
        .padding(.vertical, Spacing.card)
    }

    /// El símbolo sobre su disco de marca, como el círculo del número de un paso del flujo de la CA y
    /// con la misma opacidad medida: un glifo es un objeto gráfico y le bastaría el 3:1, pero
    /// `FillOpacity.tinted` está medido contra el 4,5:1 del texto (7:1 con contraste alto), así que lo
    /// cubre de sobra. Y por lo mismo que allí, el tinte solo se sostiene **encima de una tarjeta**:
    /// sobre el lienzo no llega con ninguna opacidad en la que todavía se vea.
    @ViewBuilder private var symbol: some View {
        let glyph = Image(systemName: presentation.systemImage)
            .font(.system(size: symbolSize))
            .foregroundStyle(Color(.brand))

        // Cuánto disco le hace falta a este glifo lo decide `SymbolDisc` y no esta vista: eran dos
        // constantes sueltas unidas por un comentario, y el fondo tiene que **cubrir la diagonal** de
        // la caja del glifo, que es por donde se le cortan las esquinas. Sin diámetro —un lado que
        // aún no se ha medido— se dibuja el glifo solo, que es lo peor que puede pasar aquí: un
        // símbolo sin fondo, nunca un fondo sin símbolo.
        if let diameter = SymbolDisc.diameter(forSymbolOfSide: symbolSize) {
            glyph
                .frame(width: diameter, height: diameter)
                .background(Color(.brand).opacity(FillOpacity.tinted), in: Circle())
                .accessibilityHidden(true)
        } else {
            glyph.accessibilityHidden(true)
        }
    }

    private var card: some View {
        // **Al inicio y no centrado**, que es el cambio de fondo de la segunda pasada aquí. Centrar
        // sirve para lo que se lee de un vistazo —un titular, una cifra—, no para lo que se lee línea
        // a línea: con el borde de entrada irregular, el ojo tiene que buscar dónde empieza cada
        // línea, y estas tarjetas traen cuatro y cinco de prosa (seis a AX5). Y trae detrás un efecto
        // que sí se mide: un bloque centrado se ciñe a su línea más larga, así que las tres tarjetas
        // del mazo tenían el contenido en **299, 306 y 280 puntos de ancho arrancando en tres
        // columnas distintas** — deslizar movía el texto de sitio. Es la regla de las filas de la
        // Timeline en un mazo: lo que se ve en serie se juzga contra lo anterior.
        VStack(alignment: .leading, spacing: Spacing.section) {
            symbol

            VStack(alignment: .leading, spacing: Spacing.row) {
                Text(presentation.title)
                    .font(.screenHeadline)

                Text(presentation.message)
                    .font(.prose)
                    .foregroundStyle(Color(.neutral))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // La caja es la misma en las tres tarjetas y el contenido arranca donde arranca la caja: es
        // lo que quita el baile de columnas de arriba. Y el **suelo de alto** es lo que quita el baile
        // vertical: sin él cada carta medía lo que midiera su párrafo —229, 251 y 229 puntos— y, al
        // ir centradas, deslizar movía el titular once puntos. Es un mínimo y no un alto, así que la
        // carta que no quepa sigue creciendo y `ViewThatFits` la manda a desplazarse.
        .frame(maxWidth: .infinity, minHeight: minimumContentHeight, alignment: .topLeading)
        // El elemento es **el contenido y no el `ScrollView`**: combinar los hijos del contenedor
        // daba un marco con `NaN` —la unión se calcula sobre un contenido cuya geometría dentro de
        // una página del `TabView` no está resuelta—, y un marco que no es un número es un elemento
        // que VoiceOver no puede ordenar ni enfocar. Aquí la unión es la de tres textos ya medidos.
        .accessibilityElement(children: .combine)
        // Las dos frases las compone el núcleo puro y no esta vista: desde M11 son copia traducible,
        // y unir titular y explicación —o poner "paso 2 de 3" en ese orden— es una decisión de idioma
        // que un traductor tiene que poder cambiar sin tocar SwiftUI.
        .accessibilityLabel(IntroAccessibility.cardLabel(for: presentation))
        // El sitio en la serie se dice aparte del contenido: quien escucha no ve los puntos, y sin
        // esto no hay forma de saber cuánto queda.
        .accessibilityValue(IntroAccessibility.stepValue(for: presentation))
        // Un mazo de una sola tarjeta no tendría adónde moverse y la pista sobraría; eso lo decide el
        // núcleo puro, no esta vista, y por eso puede venir vacía.
        .accessibilityHint(Text(IntroAccessibility.deckHint ?? ""))
        // El mazo se recorre: con VoiceOver la tarjeta es un solo elemento y el gesto de página no
        // llega hasta aquí, así que sin esto la única navegación del intro era el botón *Continue* —
        // una tarjeta cada vez y solo hacia delante.
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onGoTo(IntroAccessibility.moved(presentation.card, by: 1))
            case .decrement: onGoTo(IntroAccessibility.moved(presentation.card, by: -1))
            @unknown default: break
            }
        }
        .accessibilityActions {
            // Volver e ir al final, que son las dos cosas que un dedo hace de un vistazo y ningún
            // botón de la pantalla ofrece. Cuáles se ofrecen y adónde llevan lo decide el núcleo puro.
            ForEach(IntroAccessibility.actions(for: presentation.card)) { action in
                Button(action.label) {
                    guard let destination = IntroAccessibility.destination(
                        of: action, from: presentation.card
                    ) else {
                        return
                    }
                    onGoTo(destination)
                }
            }
        }
        .cardSurface(padding: Spacing.generous)
    }
}
