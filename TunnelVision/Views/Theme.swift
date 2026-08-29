import SwiftUI

/// Donde un token del sistema visual se convierte en algo que SwiftUI entiende
/// (`docs/ux/design-system.md`).
///
/// Es la única frontera: `Models/DesignTokens.swift` decide, esto pinta. Ninguna vista escribe un
/// color, un tamaño de letra ni un radio por su cuenta — no por purismo, sino porque el catálogo es
/// lo que hace que claro, oscuro y contraste alto sean tres apariencias del mismo diseño y no tres
/// diseños distintos.
extension Color {

    /// El color del token, resuelto por el catálogo con la apariencia y el contraste del momento.
    init(_ token: ColorToken) {
        self.init(token.rawValue, bundle: .main)
    }
}

extension ShapeStyle where Self == Color {

    /// Azúcar para `.foregroundStyle(.token(.brand))`, que es como se lee en las vistas.
    static func token(_ token: ColorToken) -> Color { Color(token) }
}

// MARK: - Instantes

extension Date.FormatStyle {

    /// Cómo escribe esta app un instante que el usuario va a leer: **el día y la hora, sin año**.
    ///
    /// Lo formatea la vista y no el núcleo puro —al revés que las cifras de `DisplayFormat`, que son
    /// deterministas a propósito— porque el huso y el reloj de 12 o 24 horas son del dispositivo, no
    /// de la app. Y se comparte estructuralmente en vez de escribirse en cada vista porque los dos
    /// instantes que enseña la pantalla de capturas —cuándo empezó un fichero y cuándo caduca el más
    /// antiguo— se leen uno contra otro: con dos formatos distintos, comparar los dos obligaría a
    /// leer dos veces.
    ///
    /// Sin año a conciencia: los tres topes de retención miden como mucho un mes, así que una fecha
    /// de caducidad cae siempre a semanas vista y el año sería una columna que nunca cambia.
    static var dayAndTime: Date.FormatStyle {
        Date.FormatStyle.dateTime.month().day().hour().minute()
    }
}

// MARK: - Tipografía

/// La escala tipográfica: **papeles**, no tamaños.
///
/// Todos salen de los estilos de texto del sistema, así que Dynamic Type sigue funcionando sin que
/// ninguna vista tenga que acordarse. Lo que añaden es el peso y —en las cifras— el diseño redondo y
/// los dígitos de ancho fijo, que es lo que evita que un número baile mientras se actualiza.
extension Font {

    /// El titular de una pantalla que no es una lista: la etapa del flujo de la CA.
    ///
    /// Es el papel más grande de la escala y solo lo lleva **una** cosa por pantalla. Una pantalla con
    /// dos titulares de este tamaño no tiene titular.
    static let screenHeadline: Font = .title2.weight(.semibold)

    /// El titular de una tarjeta.
    static let cardTitle: Font = .headline

    /// El párrafo que explica una pantalla entera: lo que hay que entender antes de tocar nada.
    ///
    /// Es el único papel que usa el cuerpo de letra por defecto del sistema, y por eso está reservado
    /// a la prosa de verdad; una fila de lista con este papel se lee como si fuera lo importante.
    static let prose: Font = .body

    /// El cuerpo explicativo de una tarjeta.
    static let cardBody: Font = .subheadline

    /// El texto de apoyo de un control: el pie de una sección, la nota que dice qué hace un
    /// interruptor, la advertencia que acompaña a una acción.
    static let supporting: Font = .footnote

    /// El valor de una fila de tabla, al lado de su etiqueta.
    ///
    /// Lleva dígitos de ancho fijo por lo mismo que las cifras de una ficha: estas filas —lo que
    /// ocupa el disco, los contadores del diagnóstico— se releen al refrescar, y sin ellos el número
    /// cambia de ancho a cada lectura. Redondo, además, para que una cifra se lea como cifra en toda
    /// la app y no según la pantalla en la que caiga.
    static let rowValue: Font = .system(.subheadline, design: .rounded, weight: .medium).monospacedDigit()

    /// La cifra de una ficha de métrica.
    static let metricValue: Font = .system(.title2, design: .rounded, weight: .semibold).monospacedDigit()

    /// La cifra grande de una lectura en vivo (las tasas del gráfico).
    static let readingValue: Font = .system(.title3, design: .rounded, weight: .semibold).monospacedDigit()

    /// La cifra pequeña de una fila densa: el instante de un paquete dentro de su conexión y lo que
    /// ocupó.
    ///
    /// Es el último escalón de las cifras —title2, title3, subheadline y esto—, y lleva lo mismo que
    /// los otros tres: diseño redondo y dígitos de ancho fijo. Sin él, una lista de quinientas filas
    /// con una columna de horas era lo único de la app donde las cifras no se leían como cifras.
    static let rowFigure: Font = .system(.caption, design: .rounded, weight: .medium).monospacedDigit()

    /// La etiqueta de una métrica, encima o al lado de su cifra.
    static let metricLabel: Font = .caption

    /// El rótulo de una sección dibujada a mano (las de `List` las pone el sistema).
    static let sectionHeader: Font = .footnote.weight(.semibold)

    /// Un dato que se lee **carácter a carácter** y que muchas veces se copia tal cual: la huella de
    /// un certificado, el nombre de un fichero exportado, el cuerpo descifrado de un turno.
    ///
    /// Monoespaciado porque en estos textos una `l` y un `1` significan cosas distintas, y proporcional
    /// se confunden. Existe como papel porque cuatro vistas lo escribían a mano y **con dos tamaños
    /// distintos**, así que el mismo tipo de dato se leía más pequeño según la pantalla en la que
    /// cayera.
    static let literal: Font = .footnote.monospaced()

    /// Una línea de volcado hexadecimal.
    ///
    /// Es el único papel cuyo tamaño no lo decide la lectura sino **el ancho**: una línea son dieciséis
    /// pares hexadecimales más su lectura en ASCII, y con un cuerpo mayor no cabe ni desplazándose. Por
    /// eso es un papel aparte de `literal` y no el mismo con otro tamaño.
    static let dumpLine: Font = .caption.monospaced()

    /// El texto de una insignia de estado.
    static let badge: Font = .caption2.weight(.medium)
}

// MARK: - Superficies

extension View {

    /// La tarjeta del sistema visual: relleno, superficie, radio y **filo**.
    ///
    /// El filo no es adorno. Antes de esto las tarjetas eran `.regularMaterial` sobre el fondo
    /// agrupado del sistema, y en claro ese material tiene prácticamente el mismo valor que el fondo:
    /// las tarjetas **no se veían**. Con superficie propia y una línea de un punto, una tarjeta se lee
    /// como tarjeta en las cuatro apariencias.
    func cardSurface(
        padding: CGFloat = Spacing.card,
        radius: CGFloat = CornerRadius.large
    ) -> some View {
        self
            .padding(padding)
            .background(Color(.surface), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color(.surfaceStroke), lineWidth: StrokeWidth.hairline)
            }
    }

    /// El botón principal de una pantalla: relleno con la marca y rótulo blanco.
    ///
    /// El tinte es `brandFill` y no el acento global porque el acento está elegido para leerse como
    /// **tinta** sobre el lienzo —y en oscuro eso lo obliga a ser claro—, mientras que un botón
    /// relleno lleva el rótulo en blanco encima. Con el acento, el botón de la Dashboard salía blanco
    /// sobre cian claro en modo oscuro.
    func brandProminentButton() -> some View {
        buttonStyle(.borderedProminent).tint(Color(.brandFill))
    }

    /// El fondo de una pantalla, por detrás de sus tarjetas.
    func screenCanvas() -> some View {
        background(Color(.canvas).ignoresSafeArea())
    }

    /// Una `List` puesta sobre el lienzo de la pantalla.
    ///
    /// El fondo de una lista lo pinta el sistema y es **otro gris**, así que una pantalla de lista
    /// dejada como viene mezcla dos diseños: el nuestro en las tarjetas y el de fábrica detrás. Se
    /// quita aquí, una vez, para que la decisión no se tome pantalla por pantalla — que es como se
    /// acaba con dos listas del mismo producto sobre fondos distintos.
    ///
    /// **Va en la propia `List`, nunca en la vista que la contiene.** Un fondo puesto en el
    /// contenedor deja la barra de navegación sin título grande —y sin título en línea que lo
    /// sustituya—, así que la pantalla pierde su nombre. Costó tres builds averiguarlo.
    func listCanvas() -> some View {
        scrollContentBackground(.hidden).screenCanvas()
    }

    /// Una superficie hundida dentro de una tarjeta: volcados, cuerpos de conversación, ejes.
    func sunkenSurface(
        padding: CGFloat = Spacing.row,
        radius: CGFloat = CornerRadius.small
    ) -> some View {
        self
            .padding(padding)
            .background(
                Color(.surfaceSunken),
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
    }
}

/// El fondo de una fila que tiene que leerse como **tarjeta** dentro de una `List`.
///
/// Va por `.listRowBackground` y no envolviendo el contenido en `.cardSurface()` por dos razones que
/// se ven en cuanto se prueba al revés: un fondo puesto en la fila cubre la celda **entera** —el
/// chevron del `NavigationLink` incluido, que si no se queda fuera de la tarjeta y la parte en dos—,
/// y es lo único que el resaltado del toque respeta. Los huecos entre tarjetas los pone este fondo
/// apartándose, no los `listRowInsets`, que solo mueven el contenido.
struct CardRowBackground: View {

    /// Lo que la tarjeta se aparta del borde de la pantalla.
    var horizontal: CGFloat = Spacing.card

    /// La mitad del hueco entre dos tarjetas seguidas.
    var vertical: CGFloat = Spacing.tight

    /// El radio de una fila agrupada, que es menor que el de una tarjeta de pantalla: en una lista
    /// hay muchas seguidas y el radio grande las convierte en una hilera de pastillas.
    var radius: CGFloat = CornerRadius.medium

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color(.surface))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color(.surfaceStroke), lineWidth: StrokeWidth.hairline)
            }
            .padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
    }
}

extension View {

    /// Una fila de `List` que se lee como **tarjeta**: su fondo, sin separador y con el aire de dentro
    /// ya sumado.
    ///
    /// Las tres cosas van juntas porque separadas se olvida una: el separador sobra cuando lo que
    /// separa las filas es el hueco entre superficies, y los `listRowInsets` tienen que llevar **la
    /// suma** de lo que la tarjeta se aparta del borde de la pantalla y de lo que el texto se aparta
    /// del filo de su tarjeta — si solo se pone lo segundo, el texto queda pegado al filo.
    func cardRow() -> some View {
        listRowBackground(CardRowBackground())
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(
                top: Spacing.tight + Spacing.row,
                leading: Spacing.card + Spacing.row,
                bottom: Spacing.tight + Spacing.row,
                trailing: Spacing.card + Spacing.row
            ))
    }
}

/// El rótulo de una sección dibujada a mano.
///
/// Existe como vista y no como modificador porque el estilo de una sección no es solo la letra: son
/// también las mayúsculas y el espaciado entre ellas, que es lo que la separa del titular de una
/// tarjeta sin necesidad de hacerla más grande. La copia llega ya traducida desde la capa pura; esto
/// no compone texto, solo lo pone en mayúsculas para pintarlo.
struct SectionHeader: View {

    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.sectionHeader)
            .tracking(0.8)
            .foregroundStyle(Color(.neutral))
            // Lo que VoiceOver debe leer es el rótulo, no su versión en mayúsculas: algunos motores
            // deletrean las mayúsculas sostenidas.
            .accessibilityLabel(title)
    }
}
