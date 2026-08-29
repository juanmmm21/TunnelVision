import CoreGraphics
import Foundation

/// Los tokens del sistema visual (`docs/ux/design-system.md`), como **valores puros**.
///
/// Existen por lo mismo que `StatusRole`: la decisión —qué color, qué hueco, qué radio le toca a
/// cada cosa— se toma aquí, donde se puede afirmar en un test, y la vista solo la aplica. El paso de
/// token a `Color`/`Font` es lo único que sabe SwiftUI (`Views/Theme.swift`, `Views/Palette.swift`).
///
/// Un token de color es el **nombre de un color del catálogo**, no una terna RGB: los valores viven
/// en `Resources/Assets.xcassets` con sus variantes de claro, oscuro y contraste alto, que es lo que
/// pide la spec y lo que hace que la app no tenga que decidir nada en tiempo de ejecución. Lo que sí
/// se puede probar desde aquí —y se prueba— es que **todos existan**, que ningún papel se quede sin
/// uno y que los colores que se leen encima de una superficie tengan contraste suficiente en las
/// cuatro combinaciones de apariencia (`DesignTokensTests`).
public enum ColorToken: String, CaseIterable, Sendable {
    /// El color de la marca **como tinta**: texto, iconos, monitorización activa y tinte global de
    /// la app. Está elegido para leerse *encima* del lienzo, así que en oscuro es claro.
    case brand = "Brand"
    /// El color de la marca **como relleno**, con tinta blanca encima: botones prominentes.
    ///
    /// Es un token aparte y no un capricho: una tinta y un relleno tiran en direcciones contrarias
    /// —la tinta tiene que aclararse en oscuro y el relleno tiene que **oscurecerse** para que el
    /// rótulo blanco se lea—. Con uno solo, el botón principal en modo oscuro era blanco sobre cian.
    case brandFill = "BrandFill"
    /// El fondo de una pantalla, por detrás de las tarjetas.
    case canvas = "Canvas"
    /// La superficie de una tarjeta o de una fila agrupada.
    case surface = "Surface"
    /// El filo de una superficie. No es decoración: sobre el lienzo, una tarjeta de material puro
    /// tenía el mismo valor que el fondo y **no se leía como tarjeta**.
    case surfaceStroke = "SurfaceStroke"
    /// Una superficie hundida dentro de otra: volcados hexadecimales, cuerpos de conversación.
    case surfaceSunken = "SurfaceSunken"
    /// Tráfico recibido, en todas partes: gráfico, fichas y filas de hosts.
    case trafficInbound = "TrafficInbound"
    /// Tráfico enviado.
    case trafficOutbound = "TrafficOutbound"
    /// Algo que el usuario debería mirar: descartes por back-pressure, almacenamiento lleno.
    case warning = "Warning"
    /// Estado en reposo, sin alarma.
    case neutral = "Neutral"
    /// Conexión sin cifrar.
    case statusPlaintext = "StatusPlaintext"
    /// Conexión cifrada que no se ha mirado.
    case statusEncrypted = "StatusEncrypted"
    /// Conexión descifrada con el consentimiento del usuario.
    case statusInspected = "StatusInspected"
    /// Conexión que rechazó la CA local y se relayeó intacta (ADR 0003).
    case statusNotInspectable = "StatusNotInspectable"
}

extension ColorToken {

    /// Los tokens que se leen **encima de una superficie**: texto, iconos y trazos de gráfico.
    ///
    /// Separarlos importa porque son los únicos a los que se les puede exigir contraste de lectura;
    /// pedírselo a `surface` contra sí misma no querría decir nada.
    public static let content: [ColorToken] = [
        .brand,
        .trafficInbound,
        .trafficOutbound,
        .warning,
        .neutral,
        .statusPlaintext,
        .statusEncrypted,
        .statusInspected,
        .statusNotInspectable
    ]
}

extension StatusRole {

    /// El color del papel, como token. Los cuatro estados de una conexión tienen **token propio**
    /// aunque dos de ellos coincidan hoy en valor: lo que significan es distinto, y separarlos aquí
    /// es lo que permite que mañana dejen de coincidir sin tocar una sola vista.
    public var colorToken: ColorToken {
        switch self {
        case .accent: return .brand
        case .neutral: return .neutral
        case .warning: return .warning
        case .plaintext: return .statusPlaintext
        case .encrypted: return .statusEncrypted
        case .inspected: return .statusInspected
        case .notInspectable: return .statusNotInspectable
        }
    }
}

/// La retícula de 8 puntos de la spec, con sus dos medios pasos.
///
/// Son los únicos huecos que la app usa: una vista que escriba un número suelto rompe el ritmo
/// vertical, que es lo que hace que nueve pantallas parezcan el mismo producto.
public enum Spacing {
    /// Entre una etiqueta y su valor.
    public static let tight: CGFloat = 4
    /// Entre elementos de una misma línea de lectura.
    public static let close: CGFloat = 8
    /// Entre filas de una lista dibujada a mano.
    public static let row: CGFloat = 12
    /// El relleno de una tarjeta y la separación entre tarjetas.
    public static let card: CGFloat = 16
    /// Entre secciones de una pantalla.
    public static let section: CGFloat = 24
    /// El aire de un estado vacío o de una pantalla de bienvenida.
    public static let generous: CGFloat = 32

    /// De menor a mayor. El orden es la afirmación: una escala que no crece no es una escala.
    public static let scale: [CGFloat] = [tight, close, row, card, section, generous]
}

/// Los radios de esquina. Tres, y no uno por vista: el tamaño del radio es lo que dice si algo es
/// una tarjeta, una ficha dentro de ella o un control pequeño.
public enum CornerRadius {
    /// Controles y elementos embebidos dentro de una tarjeta.
    public static let small: CGFloat = 10
    /// Fichas de métrica y filas agrupadas.
    public static let medium: CGFloat = 14
    /// Tarjetas y superficies de pantalla.
    public static let large: CGFloat = 20

    public static let scale: [CGFloat] = [small, medium, large]
}

/// El tamaño mínimo de algo que se toca con el dedo.
///
/// Los 44 puntos de la HIG, escritos una vez. No es un gusto ni un mínimo "recomendable": es el
/// tamaño por debajo del cual un toque falla al que apunta, y eso convierte un control correcto en
/// uno que no se puede usar. Está aquí y no en la vista porque lo deben **varios** sitios —el botón
/// de la franja de monitorización, los tramos del eje de la Timeline— y un mínimo copiado a mano es
/// un mínimo que un día se copia mal.
///
/// Ojo con dónde se aplica: en un botón con estilo del sistema, la altura la marca el **rótulo** más
/// el relleno del estilo, así que un `.frame(minHeight:)` puesto por fuera mueve el hueco y no el
/// objetivo. Se mide con `idb ui describe-all`, que devuelve el marco que de verdad recibe el toque.
public enum TouchTarget {
    /// El lado mínimo de un objetivo táctil (HIG).
    public static let minimum: CGFloat = 44
}

/// El suelo de alto del **contenido de una carta de mazo**: la tarjeta del intro, que es la única de
/// la app que se pasa con el dedo en vez de leerse en una lista.
///
/// Existe por una sola razón, y conviene no confundirla con la otra que parece: **una carta se ve
/// contra la anterior**. Las tres del intro medían 229, 251 y 229 puntos de contenido, así que,
/// centradas en su página, el símbolo y el titular **saltaban once puntos** al deslizar — el mazo se
/// movía bajo el dedo según lo largo que fuera el párrafo de cada carta. Con un suelo común las tres
/// miden lo mismo mientras su copia quepa, y pasar página mueve la carta y no lo que lleva dentro. Es
/// la regla de las filas de la Timeline: lo que se ve en serie se juzga contra lo anterior.
///
/// El valor es **lo que mide la copia más larga del mazo**, ni un punto más, y eso es deliberado: se
/// probó a subirlo hasta que la carta se llevara la mitad de la pantalla —el 57 % del área de
/// contenido era lienzo vacío y una carta de baraja dibujada como un sello es justo lo que el segundo
/// pase estético vino a corregir— y el resultado fue peor que el problema: la carta quedaba con un
/// pozo blanco al pie, que es vacío **con marco alrededor** en vez de aire. Llenar una pantalla no es
/// trabajo de un suelo de alto.
///
/// Mide el **contenido**, no la carta: quien lo aplica le suma el relleno de su superficie, y
/// confundir las dos cosas es lo que dejó una carta de 364 puntos para 195 de texto.
///
/// Y es un suelo, no un alto: la carta que no quepa —con letra de accesibilidad, o con una traducción
/// más larga que la copia inglesa, que es donde esta igualdad deja de estar garantizada— sigue
/// creciendo y desplazándose, que es la regla que `ViewThatFits` decide por página
/// (`docs/ux/design-system.md`). Escala con el cuerpo de letra donde se aplica, porque un suelo fijo
/// bajo un texto que crece es un recorte esperando a ocurrir.
public enum DeckCard {
    /// El alto mínimo del contenido de una carta del mazo, a cuerpo de letra normal.
    public static let minimumContentHeight: CGFloat = 220
}

/// El grosor del filo de una superficie. Un punto y no medio: a medio punto el filo desaparece en
/// claro, que es justo el caso en el que la tarjeta lo necesita.
public enum StrokeWidth {
    public static let hairline: CGFloat = 1
}

/// La opacidad de una marca **apagada** dentro de un gráfico: la barra del eje que no está en el
/// tramo señalado.
///
/// No es un gusto. Una barra del eje es un objeto gráfico que se lee sin texto encima, así que lo
/// que la separa de su fondo tiene que llegar a **3:1** (WCAG 1.4.11), y el medio tono con el que la
/// barra de scrub las dibujaba se quedaba en **1,98:1** en claro — o sea que el eje era casi
/// invisible justo en la apariencia en la que más falta hace. Es un valor y no un color porque la
/// marca apagada es el mismo token que la encendida con menos peso, no otro color de la paleta.
public enum MarkOpacity {
    /// Lo que no está seleccionado, pero sigue teniendo que verse.
    public static let dimmed: Double = 0.8
}

/// La opacidad de un relleno **teñido con la marca que lleva la propia marca escrita encima**: el
/// círculo del número de un paso del flujo de la CA.
///
/// Está medida y no elegida, y lo que la limita es el dígito: la marca sobre su propio tinte tiene
/// que llegar a 4,5:1 —**7:1** con contraste alto—, y a partir de aquí el número deja de leerse en
/// claro con contraste alto. Tiene además una consecuencia de diseño que no se ve mirando el número:
/// un relleno teñido **solo se sostiene encima de una tarjeta**. Sobre el lienzo no llega a 7:1 con
/// ninguna opacidad usable —ni al 10 %, donde el tinte ya no se distingue del fondo—, así que la
/// lista de pasos numerados va dentro de una tarjeta y no suelta sobre la pantalla.
public enum FillOpacity {
    /// Un relleno teñido con la marca, con la marca escrita encima.
    public static let tinted: Double = 0.14

    /// El relleno de una **insignia de estado**, teñida con el color de su propio estado.
    ///
    /// Es más bajo que `tinted` y no por gusto: aquel está medido contra **un** color, la marca, y una
    /// insignia se pinta con cualquiera de los nueve tokens de contenido. Los que menos margen tienen
    /// —el ámbar del tráfico sin cifrar, el verde del cifrado— se quedaban en **4,25:1** sobre su
    /// propio tinte al 12 % que la insignia usaba, o sea por debajo del mínimo de lectura. Este es el
    /// tinte más alto con el que **todos** llegan, en las cuatro apariencias.
    public static let badge: Double = 0.09
}

/// La opacidad del **filo** de una superficie teñida: el aro de una insignia de estado.
///
/// Es lo que hace que una insignia se lea como insignia y no como texto de color: con un relleno tan
/// bajo como el que la lectura permite, sin aro no queda forma. No está medido contra el 3:1 de WCAG
/// 1.4.11 **a propósito**, y esa ausencia es la decisión: el aro no es lo que identifica el estado
/// —eso lo llevan el icono, la palabra y el color, que es la regla de la spec— sino la forma del
/// recuadro que los envuelve, y exigirle 3:1 obligaría a un contorno casi opaco que convertiría cada
/// fila de la Timeline en una hilera de pastillas subrayadas.
public enum StrokeOpacity {
    /// El aro de una insignia.
    public static let tintedEdge: Double = 0.28
}
