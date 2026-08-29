import Foundation
import UIKit
import XCTest

/// Tests del sistema visual (paso 8 del roadmap): que la paleta **exista**, que ningún papel se
/// quede sin color y que lo que se lee encima de una superficie tenga contraste suficiente en las
/// cuatro apariencias (claro, oscuro, y las dos con contraste alto).
///
/// Aquí se prueba lo que de un diseño **se puede afirmar**. Que la app quede bonita no lo dice un
/// test; que un color exista, que dos estados no acaben del mismo color y que un texto se pueda leer
/// sobre su fondo, sí — y son justo los tres defectos que una pasada visual introduce sin querer.
///
/// El catálogo se resuelve contra `Bundle.main`, que en este bundle de tests es la **app**
/// (`TEST_HOST` en `project.yml`): los colores viven en el catálogo de la app, no en el del test.
final class DesignTokensTests: XCTestCase {

    // MARK: - Apariencias

    private static func traits(
        _ style: UIUserInterfaceStyle,
        _ contrast: UIAccessibilityContrast
    ) -> UITraitCollection {
        UITraitCollection { mutable in
            mutable.userInterfaceStyle = style
            mutable.accessibilityContrast = contrast
        }
    }

    private static let appearances: [(name: String, traits: UITraitCollection)] = [
        ("claro", traits(.light, .normal)),
        ("oscuro", traits(.dark, .normal)),
        ("claro, contraste alto", traits(.light, .high)),
        ("oscuro, contraste alto", traits(.dark, .high))
    ]

    /// El color del token en esa apariencia.
    ///
    /// **`resolvedColor(with:)` y no `compatibleWith:`**: el segundo devuelve la variante clara pase
    /// lo que pase, así que un test escrito con él afirma cuatro veces lo mismo y da por buena una
    /// paleta que no tiene variantes. Costó un rojo descubrirlo, y se deja escrito para no repetirlo.
    private func color(_ token: ColorToken, _ traits: UITraitCollection) -> UIColor? {
        UIColor(named: token.rawValue, in: .main, compatibleWith: nil)?.resolvedColor(with: traits)
    }

    // MARK: - Que la paleta exista

    func testEveryColorTokenResolvesInTheAssetCatalog() {
        for token in ColorToken.allCases {
            for appearance in Self.appearances {
                XCTAssertNotNil(
                    color(token, appearance.traits),
                    "\(token.rawValue) no está en el catálogo (\(appearance.name))"
                )
            }
        }
    }

    /// Un colorset sin variante de oscuro **compila igual** y se ve mal solo cuando alguien mira la
    /// app de noche: el catálogo devuelve el mismo color en las dos apariencias sin quejarse. Esto es
    /// lo que convierte ese olvido en un fallo de test.
    func testEveryColorTokenHasADistinctDarkVariant() {
        let light = Self.appearances[0].traits
        let dark = Self.appearances[1].traits

        for token in ColorToken.allCases {
            guard let inLight = color(token, light), let inDark = color(token, dark) else {
                XCTFail("\(token.rawValue) no está en el catálogo")
                continue
            }
            XCTAssertNotEqual(
                Self.components(of: inLight),
                Self.components(of: inDark),
                "\(token.rawValue) es el mismo color en claro y en oscuro"
            )
        }
    }

    // MARK: - Que ningún papel se quede sin color

    func testEveryStatusRoleMapsToATokenThatExists() {
        let roles: [StatusRole] = [
            .accent, .neutral, .warning, .plaintext, .encrypted, .inspected, .notInspectable
        ]

        for role in roles {
            XCTAssertNotNil(
                color(role.colorToken, Self.appearances[0].traits),
                "el papel \(role) apunta a \(role.colorToken.rawValue), que no está en el catálogo"
            )
        }
    }

    /// Los cuatro estados de una conexión tienen token propio. No es una formalidad: es lo que
    /// permite que dejen de compartir valor sin tocar una sola vista, y lo que impide que alguien
    /// "simplifique" el mapeo colapsando dos estados que significan cosas distintas.
    func testTheFourConnectionStatesHaveTokensOfTheirOwn() {
        let tokens = [
            StatusRole.plaintext.colorToken,
            StatusRole.encrypted.colorToken,
            StatusRole.inspected.colorToken,
            StatusRole.notInspectable.colorToken
        ]

        XCTAssertEqual(Set(tokens).count, 4)
    }

    // MARK: - Que se pueda leer

    /// Contraste de lectura de todo lo que se pinta **encima de una tarjeta**.
    ///
    /// 4,5:1 es el mínimo de WCAG AA para texto normal, y estos colores llevan texto: la cifra de una
    /// ficha, la etiqueta de una insignia, el rótulo de una sección. Con contraste alto se exige 7:1,
    /// que es AAA — si no, la variante de contraste alto sería un gesto y no una ayuda.
    func testContentTokensAreLegibleOnTheSurfaceInEveryAppearance() {
        for appearance in Self.appearances {
            let isHighContrast = appearance.traits.accessibilityContrast == .high
            let minimum = isHighContrast ? 7.0 : 4.5

            guard let surface = color(.surface, appearance.traits) else {
                XCTFail("Surface no está en el catálogo (\(appearance.name))")
                continue
            }

            for token in ColorToken.content {
                guard let content = color(token, appearance.traits) else {
                    XCTFail("\(token.rawValue) no está en el catálogo (\(appearance.name))")
                    continue
                }
                let ratio = Self.contrastRatio(content, surface)
                XCTAssertGreaterThanOrEqual(
                    ratio,
                    minimum,
                    "\(token.rawValue) sobre Surface da \(String(format: "%.2f", ratio)):1 "
                        + "en \(appearance.name); hace falta \(minimum):1"
                )
            }
        }
    }

    /// El filo de una tarjeta tiene que verse. Es la línea que hace que una tarjeta se lea como
    /// tarjeta, y es exactamente lo que faltaba antes del sistema visual: con material del sistema
    /// sobre el fondo agrupado, en claro, la tarjeta y su fondo tenían prácticamente el mismo valor.
    func testTheSurfaceStrokeIsVisibleAgainstTheSurfaceInEveryAppearance() {
        for appearance in Self.appearances {
            guard let stroke = color(.surfaceStroke, appearance.traits),
                  let surface = color(.surface, appearance.traits) else {
                XCTFail("faltan colores de superficie (\(appearance.name))")
                continue
            }
            XCTAssertGreaterThanOrEqual(
                Self.contrastRatio(stroke, surface),
                1.2,
                "el filo no se distingue de la superficie en \(appearance.name)"
            )
        }
    }

    /// El botón principal lleva rótulo **blanco** sobre `brandFill`, y eso solo se sostiene si el
    /// relleno es oscuro en las cuatro apariencias. Es el defecto que hizo falta separar la marca en
    /// dos tokens: con el acento de tinta, en oscuro el botón salía blanco sobre cian claro.
    func testTheProminentButtonLabelIsLegibleOnTheBrandFill() {
        for appearance in Self.appearances {
            let minimum = appearance.traits.accessibilityContrast == .high ? 7.0 : 4.5
            guard let fill = color(.brandFill, appearance.traits) else {
                XCTFail("BrandFill no está en el catálogo (\(appearance.name))")
                continue
            }
            let ratio = Self.contrastRatio(.white, fill)
            XCTAssertGreaterThanOrEqual(
                ratio,
                minimum,
                "el rótulo blanco sobre BrandFill da \(String(format: "%.2f", ratio)):1 "
                    + "en \(appearance.name); hace falta \(minimum):1"
            )
        }
    }

    /// Lo mismo, pero **sobre el lienzo**: desde que las pantallas de lista se pusieron encima de él
    /// (Timeline, Captures), hay texto que no cae sobre una tarjeta —el pie de la lista, el final del
    /// historial, el aviso de un fallo de paginación—. Es otro fondo y por tanto otra afirmación: un
    /// color puede leerse sobre la tarjeta y perderse sobre el lienzo, que es más oscuro en claro.
    func testContentTokensAreLegibleOnTheCanvasInEveryAppearance() {
        for appearance in Self.appearances {
            let minimum = appearance.traits.accessibilityContrast == .high ? 7.0 : 4.5

            guard let canvas = color(.canvas, appearance.traits) else {
                XCTFail("Canvas no está en el catálogo (\(appearance.name))")
                continue
            }

            for token in ColorToken.content {
                guard let content = color(token, appearance.traits) else {
                    XCTFail("\(token.rawValue) no está en el catálogo (\(appearance.name))")
                    continue
                }
                let ratio = Self.contrastRatio(content, canvas)
                XCTAssertGreaterThanOrEqual(
                    ratio,
                    minimum,
                    "\(token.rawValue) sobre Canvas da \(String(format: "%.2f", ratio)):1 "
                        + "en \(appearance.name); hace falta \(minimum):1"
                )
            }
        }
    }

    /// Y lo mismo **sobre la superficie hundida**, que es el tercer fondo del sistema y desde el Flow
    /// Inspector es el que más texto lleva: el volcado hexadecimal de un paquete y el cuerpo de un
    /// turno de conversación se leen ahí dentro, no sobre la tarjeta que los rodea.
    ///
    /// No es redundante con las dos de arriba, y lo demostró en cuanto se escribió: lo hundido está
    /// **entre** el lienzo y la tarjeta en claro, así que un tono que llegaba justo sobre la tarjeta
    /// blanca se queda corto aquí. Cinco tokens fallaban en claro con contraste alto y se oscurecieron.
    func testContentTokensAreLegibleOnTheSunkenSurfaceInEveryAppearance() {
        for appearance in Self.appearances {
            let minimum = appearance.traits.accessibilityContrast == .high ? 7.0 : 4.5

            guard let sunken = color(.surfaceSunken, appearance.traits) else {
                XCTFail("SurfaceSunken no está en el catálogo (\(appearance.name))")
                continue
            }

            for token in ColorToken.content {
                guard let content = color(token, appearance.traits) else {
                    XCTFail("\(token.rawValue) no está en el catálogo (\(appearance.name))")
                    continue
                }
                let ratio = Self.contrastRatio(content, sunken)
                XCTAssertGreaterThanOrEqual(
                    ratio,
                    minimum,
                    "\(token.rawValue) sobre SurfaceSunken da \(String(format: "%.2f", ratio)):1 "
                        + "en \(appearance.name); hace falta \(minimum):1"
                )
            }
        }
    }

    /// El filo de una tarjeta se ve **contra el lienzo**, que es contra lo que de verdad recorta.
    /// Sobre la superficie el filo separa la tarjeta de sí misma; lo que dice dónde acaba una tarjeta
    /// es su filo contra el fondo de la pantalla, y en una lista de tarjetas eso se repite en cada
    /// fila.
    func testTheSurfaceStrokeIsVisibleAgainstTheCanvasInEveryAppearance() {
        for appearance in Self.appearances {
            guard let stroke = color(.surfaceStroke, appearance.traits),
                  let canvas = color(.canvas, appearance.traits) else {
                XCTFail("faltan colores de superficie (\(appearance.name))")
                continue
            }
            XCTAssertGreaterThanOrEqual(
                Self.contrastRatio(stroke, canvas),
                1.2,
                "el filo no se distingue del lienzo en \(appearance.name)"
            )
        }
    }

    /// Una superficie hundida tiene que **hundirse**: si vale lo mismo que la tarjeta que la
    /// contiene, el carril del eje de la Timeline o el volcado de un paquete son un rectángulo que no
    /// está ahí. Es el mismo defecto que tenían las tarjetas antes del sistema visual, un nivel más
    /// adentro.
    func testTheSunkenSurfaceIsNeverTheSameValueAsTheSurface() {
        for appearance in Self.appearances {
            guard let sunken = color(.surfaceSunken, appearance.traits),
                  let surface = color(.surface, appearance.traits) else {
                XCTFail("faltan colores de superficie (\(appearance.name))")
                continue
            }
            XCTAssertGreaterThanOrEqual(
                Self.contrastRatio(sunken, surface),
                1.04,
                "la superficie hundida y la tarjeta son el mismo valor en \(appearance.name)"
            )
        }
    }

    /// La barra **apagada** del eje de la Timeline sigue siendo un objeto gráfico que hay que ver, y
    /// lo que no lleva texto encima se mide con el 3:1 de WCAG 1.4.11 y no con el 4,5:1 del texto.
    ///
    /// El test existe porque el defecto ya estaba puesto: con el medio tono con el que se dibujaban,
    /// en claro daban **1,98:1** sobre el carril — o sea que el eje casi no se veía justo en la
    /// apariencia en la que más falta hace. `MarkOpacity.dimmed` es el valor que lo arregla, y esto
    /// es lo que impide que alguien lo baje otra vez "porque se ve mejor" en oscuro.
    func testTheDimmedAxisMarkIsVisibleOnItsTrackInEveryAppearance() {
        for appearance in Self.appearances {
            guard let mark = color(.neutral, appearance.traits),
                  let track = color(.surfaceSunken, appearance.traits) else {
                XCTFail("faltan colores del eje (\(appearance.name))")
                continue
            }
            let dimmed = Self.blend(mark, over: track, alpha: MarkOpacity.dimmed)
            let ratio = Self.contrastRatio(dimmed, track)
            XCTAssertGreaterThanOrEqual(
                ratio,
                3.0,
                "la barra apagada da \(String(format: "%.2f", ratio)):1 sobre su carril "
                    + "en \(appearance.name); hace falta 3:1"
            )
        }
    }

    /// Y la misma marca apagada **sobre el lienzo**, que es donde la pone el intro: los puntos del
    /// mazo van sobre el fondo de la pantalla y no dentro de un carril hundido.
    ///
    /// Es otro fondo y por tanto otra afirmación, igual que el texto tuvo que medirse tres veces —una
    /// por superficie—: el lienzo es más claro que un carril en claro, así que una marca apagada tiene
    /// menos margen encima. Aquí llega sin tocar nada, y lo que el test protege es que nadie baje la
    /// opacidad "porque en oscuro se ve de sobra", que es exactamente lo que le pasó al eje.
    func testTheDimmedMarkIsVisibleOnTheCanvasInEveryAppearance() {
        for appearance in Self.appearances {
            guard let mark = color(.neutral, appearance.traits),
                  let canvas = color(.canvas, appearance.traits) else {
                XCTFail("faltan colores del indicador (\(appearance.name))")
                continue
            }
            let dimmed = Self.blend(mark, over: canvas, alpha: MarkOpacity.dimmed)
            let ratio = Self.contrastRatio(dimmed, canvas)
            XCTAssertGreaterThanOrEqual(
                ratio,
                3.0,
                "el punto apagado del mazo da \(String(format: "%.2f", ratio)):1 sobre el lienzo "
                    + "en \(appearance.name); hace falta 3:1"
            )
        }
    }

    /// El círculo del número de un paso del flujo de la CA es la marca escrita **sobre su propio
    /// tinte**, así que lo que hay que medir no es la marca contra la tarjeta sino contra la mezcla.
    ///
    /// Es una afirmación distinta de la del texto sobre la superficie, y no redundante: el tinte
    /// acerca el fondo al color de la tinta, o sea que come contraste justo donde parecía que no
    /// pasaba nada. `FillOpacity.tinted` es el valor que la mantiene en pie, y esto es lo que impide
    /// que alguien lo suba "para que el círculo se vea mejor".
    func testTheTintedFillKeepsItsNumeralLegibleOnACard() {
        for appearance in Self.appearances {
            let minimum = appearance.traits.accessibilityContrast == .high ? 7.0 : 4.5
            guard let brand = color(.brand, appearance.traits),
                  let surface = color(.surface, appearance.traits) else {
                XCTFail("faltan colores del relleno teñido (\(appearance.name))")
                continue
            }
            let fill = Self.blend(brand, over: surface, alpha: FillOpacity.tinted)
            let ratio = Self.contrastRatio(brand, fill)
            XCTAssertGreaterThanOrEqual(
                ratio,
                minimum,
                "el número sobre su relleno teñido da \(String(format: "%.2f", ratio)):1 "
                    + "en \(appearance.name); hace falta \(minimum):1"
            )
        }
    }

    /// La insignia de estado es lo mismo un paso más allá: su rótulo se escribe **sobre su propio
    /// color al tinte**, pero el color no es siempre la marca sino cualquiera de los nueve de
    /// contenido. Así que lo que hay que exigirle no es a un tinte, sino a nueve.
    ///
    /// El test se escribió porque la insignia llevaba un 12 % puesto a mano en la vista, y al medirlo
    /// dos estados —el ámbar del tráfico sin cifrar y el verde del cifrado— dejaban su rótulo en
    /// **4,25:1** en claro. `FillOpacity.badge` es el tinte más alto con el que llegan todos.
    func testEveryBadgeKeepsItsLabelLegibleOnItsOwnTint() {
        for appearance in Self.appearances {
            let minimum = appearance.traits.accessibilityContrast == .high ? 7.0 : 4.5
            guard let surface = color(.surface, appearance.traits) else {
                XCTFail("Surface no está en el catálogo (\(appearance.name))")
                continue
            }

            for token in ColorToken.content {
                guard let ink = color(token, appearance.traits) else {
                    XCTFail("\(token.rawValue) no está en el catálogo (\(appearance.name))")
                    continue
                }
                let fill = Self.blend(ink, over: surface, alpha: FillOpacity.badge)
                let ratio = Self.contrastRatio(ink, fill)
                XCTAssertGreaterThanOrEqual(
                    ratio,
                    minimum,
                    "el rótulo de una insignia de \(token.rawValue) sobre su tinte da "
                        + "\(String(format: "%.2f", ratio)):1 en \(appearance.name); "
                        + "hace falta \(minimum):1"
                )
            }
        }
    }

    /// Y por qué son **dos** opacidades y no una: el tinte de los pasos numerados está medido contra
    /// un solo color —la marca, que es el que más margen tiene— y aplicado a una insignia dejaría
    /// ilegible el rótulo de los estados de menos margen.
    ///
    /// Como el de la tarjeta de los pasos, este test afirma la **causa** de la decisión y no su
    /// efecto: si algún día la paleta subiera de contraste hasta que un solo valor sirviera para las
    /// dos cosas, se pondría rojo y las dos opacidades podrían por fin fundirse en una.
    func testTheBadgeTintIsLowerThanTheStepTintForAReason() {
        XCTAssertLessThan(FillOpacity.badge, FillOpacity.tinted)

        let light = Self.appearances[0]
        guard let ink = color(.statusPlaintext, light.traits),
              let surface = color(.surface, light.traits) else {
            XCTFail("faltan colores de la insignia")
            return
        }
        let fill = Self.blend(ink, over: surface, alpha: FillOpacity.tinted)
        XCTAssertLessThan(
            Self.contrastRatio(ink, fill),
            4.5,
            "el tinte de los pasos ya sirve para una insignia: sobra una de las dos opacidades"
        )
    }

    /// Y la razón por la que ese relleno **solo va en tarjeta**: sobre el lienzo no llega.
    ///
    /// El test no afirma que falle —afirmar un fallo no protege de nada—, sino la consecuencia de
    /// diseño que se sigue de ello: si algún día la paleta cambiara y el tinte sobre el lienzo pasara
    /// a leerse, este test se pondría rojo y la regla "los pasos van en tarjeta" dejaría de tener
    /// motivo. Es la forma de que la decisión no sobreviva a su causa.
    func testTheTintedFillIsTheReasonTheStepListLivesOnACard() {
        let lightHighContrast = Self.appearances[2]
        guard let brand = color(.brand, lightHighContrast.traits),
              let canvas = color(.canvas, lightHighContrast.traits) else {
            XCTFail("faltan colores del relleno teñido")
            return
        }
        let fill = Self.blend(brand, over: canvas, alpha: FillOpacity.tinted)
        XCTAssertLessThan(
            Self.contrastRatio(brand, fill),
            7.0,
            "el relleno teñido ya se lee sobre el lienzo: los pasos numerados no necesitan tarjeta"
        )
    }

    func testTheCanvasIsNeverTheSameValueAsTheSurface() {
        for appearance in Self.appearances {
            guard let canvas = color(.canvas, appearance.traits),
                  let surface = color(.surface, appearance.traits) else {
                XCTFail("faltan colores de superficie (\(appearance.name))")
                continue
            }
            XCTAssertGreaterThanOrEqual(
                Self.contrastRatio(canvas, surface),
                1.04,
                "el lienzo y la superficie son el mismo valor en \(appearance.name)"
            )
        }
    }

    // MARK: - Las escalas

    func testTheSpacingScaleGrowsAndSitsOnTheGrid() {
        XCTAssertEqual(Spacing.scale, Spacing.scale.sorted())
        XCTAssertEqual(Set(Spacing.scale).count, Spacing.scale.count)
        for step in Spacing.scale {
            XCTAssertEqual(step.truncatingRemainder(dividingBy: 4), 0, "\(step) no cae en la retícula")
        }
    }

    func testTheCornerRadiusScaleGrows() {
        XCTAssertEqual(CornerRadius.scale, CornerRadius.scale.sorted())
        XCTAssertEqual(Set(CornerRadius.scale).count, CornerRadius.scale.count)
        XCTAssertGreaterThan(CornerRadius.small, 0)
    }

    /// El mínimo táctil de la HIG. Lo que este test impide no es que alguien escriba 43: es que
    /// alguien lo baje "un poco" para que una franja quepa mejor, que es exactamente la presión que
    /// tiene un pase de diseño cuyo encargo es **quitar sitio**.
    func testTheTouchTargetMinimumIsTheOneTheHIGAsks() {
        XCTAssertEqual(TouchTarget.minimum, 44)
    }

    // MARK: - Contraste (WCAG 2.1)

    private static func components(of color: UIColor) -> [CGFloat] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue, alpha]
    }

    /// El color que resulta de pintar uno translúcido encima de otro. Es lo que hace el sistema al
    /// dibujar una marca con opacidad, y hay que reproducirlo aquí porque `UIColor.withAlphaComponent`
    /// **no compone**: devuelve el mismo color con un alfa dentro, y su luminancia sigue siendo la del
    /// color opaco. Un test escrito con eso daría por buena cualquier opacidad.
    private static func blend(_ color: UIColor, over background: UIColor, alpha: Double) -> UIColor {
        let top = components(of: color)
        let bottom = components(of: background)
        let mix = (0..<3).map { CGFloat(alpha) * top[$0] + (1 - CGFloat(alpha)) * bottom[$0] }
        return UIColor(red: mix[0], green: mix[1], blue: mix[2], alpha: 1)
    }

    /// Luminancia relativa de sRGB, tal y como la define WCAG.
    private static func luminance(_ color: UIColor) -> Double {
        let channels = components(of: color).prefix(3).map { channel -> Double in
            let value = Double(channel)
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }

    private static func contrastRatio(_ first: UIColor, _ second: UIColor) -> Double {
        let one = luminance(first)
        let other = luminance(second)
        let lighter = max(one, other)
        let darker = min(one, other)
        return (lighter + 0.05) / (darker + 0.05)
    }
}
