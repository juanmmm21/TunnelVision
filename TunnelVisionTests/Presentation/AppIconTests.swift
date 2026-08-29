import Foundation
import UIKit
import XCTest

/// Tests del icono (paso 9 del roadmap).
///
/// Un icono no se puede probar entero —si es bonito, si dice lo que el producto hace, no lo dice un
/// test—, pero cuatro cosas suyas sí son afirmables, y las cuatro son fallos que se cuelan sin que
/// nadie los vea: que **exista** (el ajuste que lo nombra estuvo vacío a propósito durante todo el
/// desarrollo, y con él vacío el build sigue pasando), que no lleve **transparencia** (App Store
/// rechaza un icono con canal alfa, y eso se descubre al subirlo), que se **aclare hacia el centro**
/// —que es toda su composición: un pasillo que se aleja hacia una luz, y aplanado deja de leerse a
/// 40 pt— y que esté dibujado en el **tono de la marca**, o sea que el icono y la paleta no sean dos
/// definiciones distintas del mismo azul.
///
/// **Lo que no se puede afirmar aquí, y por qué no es un hueco**: el set trae también la variante de
/// oscuro y la teñida, y ninguna se alcanza desde el proceso. `actool` deja en la raíz del bundle el
/// PNG de siempre (`AppIcon60x60@2x.png`) y es ese el que devuelve `UIImage(named:)`, con traits o
/// sin ellos — comprobado: la misma imagen en claro y en oscuro, píxel a píxel. Las dos variantes se
/// miraron, que es lo que hay.
///
/// El catálogo se resuelve contra `Bundle.main`, que en este bundle de tests es la **app**
/// (`TEST_HOST` en `project.yml`).
final class AppIconTests: XCTestCase {

    // MARK: - Que exista

    /// El nombre del icono es un ajuste de build, no un fichero: con
    /// `ASSETCATALOG_COMPILER_APPICON_NAME` vacío el catálogo compila igual y la app se instala con
    /// el cuadro gris del sistema. Esto es lo que convierte ese descuido en un fallo de test.
    func testTheAppBundleShipsAPrimaryIcon() {
        guard let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] else {
            return XCTFail("el bundle de la app no declara ningún icono")
        }

        XCTAssertEqual(
            primary["CFBundleIconName"] as? String,
            "AppIcon",
            "el icono principal no sale del set `AppIcon` del catálogo"
        )

        let files = primary["CFBundleIconFiles"] as? [String] ?? []
        XCTAssertFalse(files.isEmpty, "el icono principal no tiene ni un fichero")

        for file in files {
            guard let image = UIImage(named: file) else {
                XCTFail("\(file) está declarado y no está en el bundle")
                continue
            }
            XCTAssertEqual(image.size.width, image.size.height, "\(file) no es cuadrado")
        }
    }

    // MARK: - Que no lleve transparencia

    /// Un icono de iOS con canal alfa lo rechaza App Store, y el rechazo llega al subirlo: es el
    /// fallo más caro de descubrir tarde de todo este fichero. Se mira el alfa **por píxel** y no el
    /// `alphaInfo` de la imagen porque `actool` recomprime y devuelve el canal de todas formas, con
    /// todo opaco dentro.
    func testTheAppIconIsFullyOpaque() throws {
        let icon = try XCTUnwrap(Self.primaryIcon(), "no hay icono que mirar")

        for row in 0..<Self.grid {
            for column in 0..<Self.grid {
                let x = (CGFloat(column) + 0.5) / CGFloat(Self.grid)
                let y = (CGFloat(row) + 0.5) / CGFloat(Self.grid)
                XCTAssertEqual(
                    icon.alpha(atX: x, y: y),
                    255,
                    "el icono es transparente en (\(x), \(y))"
                )
            }
        }
    }

    private static let grid = 16

    // MARK: - Que se aclare hacia el centro

    /// La composición del icono **es** su significado: cinco cuadros anidados de la misma forma que
    /// la máscara del propio icono, cada uno más claro que el que lo contiene, terminados en una
    /// abertura casi blanca — un túnel al que se le ve el final. Si esa rampa se aplana, lo que queda
    /// es un cuadrado con adornos que a 40 pt no dice nada, y eso es un cambio de una línea en el
    /// renderizador. Se mide en el centro de cada capa, no en sus bordes, porque el borde está
    /// suavizado.
    func testTheAppIconGetsBrighterTowardsItsCentre() throws {
        let icon = try XCTUnwrap(Self.primaryIcon(), "no hay icono que mirar")

        var previous: CGFloat = -1
        for band in Self.bands {
            let luminance = Self.luminance(icon.color(atX: 0.5 - band.offset, y: 0.5))
            XCTAssertGreaterThan(
                luminance,
                previous,
                "\(band.name) no es más claro que la capa que lo contiene"
            )
            previous = luminance
        }
    }

    /// El centro de cada capa, en fracción de ancho desde el centro del icono. Salen de los lados que
    /// escribe `Tools/AppIcon/RenderAppIcon.swift` (856, 640, 440, 256 y 132 sobre 1024).
    private static let bands: [(name: String, offset: CGFloat)] = [
        ("el fondo", 0.46),
        ("la boca del túnel", 0.365),
        ("el segundo tramo", 0.264),
        ("el tercer tramo", 0.17),
        ("el cuarto tramo", 0.095),
        ("la abertura", 0)
    ]

    // MARK: - Que hable el tono de la marca

    /// El icono se dibuja con hexadecimales escritos en el renderizador y la paleta con los del
    /// catálogo: son dos sitios, y dos sitios se separan. Lo que los ata sin congelar los valores
    /// exactos —un icono tiene que poder oscurecer su fondo sin romper un test— es el **tono**: todo
    /// el pasillo, del fondo a la abertura, es el mismo azul de `brand` a distinta luz.
    func testTheAppIconIsDrawnInTheBrandHue() throws {
        let icon = try XCTUnwrap(Self.primaryIcon(), "no hay icono que mirar")
        let brand = try XCTUnwrap(
            UIColor(named: ColorToken.brand.rawValue, in: .main, compatibleWith: nil),
            "el token de marca no está en el catálogo"
        )
        let brandHue = try XCTUnwrap(Self.hue(of: brand), "la marca no tiene tono")

        for band in Self.bands {
            let color = icon.color(atX: 0.5 - band.offset, y: 0.5)
            let hue = try XCTUnwrap(Self.hue(of: color), "\(band.name) no tiene tono")
            XCTAssertLessThan(
                Self.distance(hue, brandHue),
                Self.hueTolerance,
                "\(band.name) no está en el tono de la marca (\(hue)° contra \(brandHue)°)"
            )
        }
    }

    /// Diez grados sobre 360. Es holgado a propósito: el degradado del fondo y el halo de la abertura
    /// mueven el tono unos pocos grados, y lo que se afirma es que el icono es **de la marca**, no
    /// que sea un color concreto.
    private static let hueTolerance: CGFloat = 10

    // MARK: - Píxeles

    /// La imagen del icono tal y como quedó en el bundle, con sus píxeles ya en sRGB.
    private static func primaryIcon() -> IconBitmap? {
        guard let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let file = (primary["CFBundleIconFiles"] as? [String])?.last,
              let image = UIImage(named: file),
              let cgImage = image.cgImage else { return nil }
        return IconBitmap(cgImage)
    }

    /// Los píxeles de una imagen, dibujados una sola vez en sRGB para poder preguntar por punto.
    private struct IconBitmap {
        private let pixels: [UInt8]
        private let width: Int
        private let height: Int

        init?(_ image: CGImage) {
            // Los tamaños se copian a locales antes de dibujar: el cierre de `withUnsafeMutableBytes`
            // capturaría `self` para leerlos, y `self` no está inicializada todavía.
            let side = (width: image.width, height: image.height)
            guard side.width > 0, side.height > 0,
                  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

            var buffer = [UInt8](repeating: 0, count: side.width * side.height * 4)
            let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(
                    data: raw.baseAddress,
                    width: side.width,
                    height: side.height,
                    bitsPerComponent: 8,
                    bytesPerRow: side.width * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: side.width, height: side.height))
                return true
            }
            guard drawn else { return nil }

            width = side.width
            height = side.height
            pixels = buffer
        }

        private func index(_ x: CGFloat, _ y: CGFloat) -> Int {
            let column = min(width - 1, max(0, Int(x * CGFloat(width))))
            let row = min(height - 1, max(0, Int(y * CGFloat(height))))
            return (row * width + column) * 4
        }

        func color(atX x: CGFloat, y: CGFloat) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
            let offset = index(x, y)
            return (
                CGFloat(pixels[offset]) / 255,
                CGFloat(pixels[offset + 1]) / 255,
                CGFloat(pixels[offset + 2]) / 255
            )
        }

        func alpha(atX x: CGFloat, y: CGFloat) -> UInt8 {
            pixels[index(x, y) + 3]
        }
    }

    // MARK: - Color

    /// Luminancia relativa de WCAG, la misma con la que se mide el contraste de la paleta.
    private static func luminance(_ color: (red: CGFloat, green: CGFloat, blue: CGFloat)) -> CGFloat {
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.red) + 0.7152 * channel(color.green) + 0.0722 * channel(color.blue)
    }

    /// El tono en grados, o `nil` si el color es un gris (donde el tono no existe).
    private static func hue(of color: (red: CGFloat, green: CGFloat, blue: CGFloat)) -> CGFloat? {
        let maximum = max(color.red, color.green, color.blue)
        let minimum = min(color.red, color.green, color.blue)
        let delta = maximum - minimum
        guard delta > 0.001 else { return nil }

        let degrees: CGFloat
        switch maximum {
        case color.red: degrees = 60 * ((color.green - color.blue) / delta)
        case color.green: degrees = 60 * (2 + (color.blue - color.red) / delta)
        default: degrees = 60 * (4 + (color.red - color.green) / delta)
        }
        return degrees < 0 ? degrees + 360 : degrees
    }

    private static func hue(of color: UIColor) -> CGFloat? {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return hue(of: (red, green, blue))
    }

    /// La distancia entre dos tonos por el lado corto del círculo.
    private static func distance(_ one: CGFloat, _ other: CGFloat) -> CGFloat {
        let difference = abs(one - other).truncatingRemainder(dividingBy: 360)
        return min(difference, 360 - difference)
    }
}
