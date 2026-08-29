#!/usr/bin/env swift
//
//  RenderAppIcon.swift — el icono de TunnelVision, dibujado desde la paleta.
//
//  Se ejecuta en macOS y escribe los tres PNG de 1024×1024 que van al `AppIcon.appiconset`:
//
//      swift Tools/AppIcon/RenderAppIcon.swift TunnelVision/Resources/Assets.xcassets/AppIcon.appiconset
//
//  Por qué un renderizador y no un PNG suelto: el icono es la única pieza del sistema visual que
//  vive fuera del catálogo de colores, y un binario opaco no se puede revisar, ni retocar, ni
//  volver a derivar cuando la marca cambie. Aquí las medidas y los colores están escritos, y el
//  fichero es el que manda.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Color

/// Un color sRGB escrito como se escribe en el catálogo, en hexadecimal.
struct RGB {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat

    init(_ hex: UInt32) {
        red = CGFloat((hex >> 16) & 0xFF) / 255
        green = CGFloat((hex >> 8) & 0xFF) / 255
        blue = CGFloat(hex & 0xFF) / 255
    }

    func cgColor(alpha: CGFloat = 1) -> CGColor {
        CGColor(
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            components: [red, green, blue, alpha]
        )!
    }
}

// MARK: - La forma

/// Una superelipse: la familia a la que pertenece la máscara del propio icono de iOS.
///
/// Se usa en vez de un rectángulo de esquinas circulares porque el dibujo son cuadros **anidados**:
/// con la superelipse la esquina se redondea en proporción al tamaño, así que las capas interiores
/// son la misma forma vista más lejos, que es justo lo que hace que se lean como un pasillo. Con un
/// radio fijo, las pequeñas salen casi cuadradas y el efecto de fuga se pierde.
func superellipse(center: CGPoint, side: CGFloat, exponent: CGFloat, segments: Int = 720) -> CGPath {
    let path = CGMutablePath()
    let radius = side / 2

    for step in 0...segments {
        let angle = 2 * CGFloat.pi * CGFloat(step) / CGFloat(segments)
        let cosine = cos(angle)
        let sine = sin(angle)
        // |x|^n + |y|^n = 1 en forma paramétrica: el signo se conserva y el módulo se eleva a 2/n.
        let x = copysign(pow(abs(cosine), 2 / exponent), cosine) * radius
        let y = copysign(pow(abs(sine), 2 / exponent), sine) * radius
        let point = CGPoint(x: center.x + x, y: center.y + y)
        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }

    path.closeSubpath()
    return path
}

// MARK: - La receta

/// Las cinco capas del túnel, de fuera adentro, más el fondo y el halo.
///
/// El icono es un **pasillo que se aleja hacia una luz**: cuadros anidados de la misma forma que la
/// máscara del icono, cada uno más claro que el que lo contiene, terminados en una abertura casi
/// blanca. Es el nombre del producto dicho con la paleta y sin una sola letra — un túnel al que se
/// puede ver dentro — y se sostiene a 20 pt, donde lo único que sobrevive es el punto encendido en
/// un cuadrado oscuro.
struct IconRecipe {
    let backgroundTop: RGB
    let backgroundBottom: RGB
    /// De fuera adentro. El último es la abertura.
    let layers: [(side: CGFloat, color: RGB)]
    let glow: RGB
    let glowAlpha: CGFloat

    /// El icono por defecto: la marca sobre su propio azul, oscurecido hasta que el cian se enciende.
    static let standard = IconRecipe(
        backgroundTop: RGB(0x05303B),
        backgroundBottom: RGB(0x01161B),
        layers: [
            (856, RGB(0x07414F)),
            (640, RGB(0x0B5E70)),
            (440, RGB(0x1596AE)),
            (256, RGB(0x4BDCEE)),
            (132, RGB(0xEDFEFF))
        ],
        glow: RGB(0x7FE8F7),
        glowAlpha: 0.50
    )

    /// La variante de oscuro. Mismo tono y misma geometría, con el fondo más hundido: un icono
    /// pensado para una pantalla apagada, no el de siempre con menos luz.
    static let dark = IconRecipe(
        backgroundTop: RGB(0x03212A),
        backgroundBottom: RGB(0x000A0D),
        layers: [
            (856, RGB(0x052F3A)),
            (640, RGB(0x084756)),
            (440, RGB(0x10788C)),
            (256, RGB(0x3FD0E3)),
            (132, RGB(0xE4FDFF))
        ],
        glow: RGB(0x6FE4F4),
        glowAlpha: 0.44
    )

    /// La variante teñida. Va en **grises** a propósito: el sistema no aplica un tinte encima del
    /// color, sino que mapea la luminosidad de esta imagen sobre el tinte que elija el usuario, así
    /// que lo que aquí decide el resultado es el escalón de luz entre capa y capa — el mismo que en
    /// las otras dos, medido en gris.
    static let tinted = IconRecipe(
        backgroundTop: RGB(0x0D0D0D),
        backgroundBottom: RGB(0x000000),
        layers: [
            (856, RGB(0x1E1E1E)),
            (640, RGB(0x3C3C3C)),
            (440, RGB(0x6F6F6F)),
            (256, RGB(0xC6C6C6)),
            (132, RGB(0xFFFFFF))
        ],
        glow: RGB(0xFFFFFF),
        glowAlpha: 0.30
    )
}

/// El exponente de la superelipse. 5 es el que deja una esquina como la de la máscara de iOS: más
/// bajo se acerca al círculo y más alto al cuadrado.
let squircleExponent: CGFloat = 5

// MARK: - Dibujo

func render(_ recipe: IconRecipe, side: CGFloat) -> CGImage? {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    // Sin canal alfa: un icono de iOS con transparencia lo rechaza App Store, y aquí es imposible
    // por construcción en vez de por revisión.
    guard let context = CGContext(
        data: nil,
        width: Int(side),
        height: Int(side),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return nil }

    let scale = side / 1024
    let center = CGPoint(x: side / 2, y: side / 2)

    // Fondo: degradado vertical, lo bastante corto como para leerse como una sola superficie.
    guard let background = CGGradient(
        colorsSpace: colorSpace,
        colors: [recipe.backgroundTop.cgColor(), recipe.backgroundBottom.cgColor()] as CFArray,
        locations: [0, 1]
    ) else { return nil }
    context.drawLinearGradient(
        background,
        start: CGPoint(x: 0, y: side),
        end: CGPoint(x: 0, y: 0),
        options: []
    )

    // El pasillo, de fuera adentro. El halo va antes de la abertura para que sea la abertura la que
    // ilumina, y no una mancha encima de ella.
    for (index, layer) in recipe.layers.enumerated() {
        if index == recipe.layers.count - 1 {
            drawGlow(recipe, in: context, at: center, radius: 250 * scale, colorSpace: colorSpace)
        }
        context.addPath(superellipse(center: center, side: layer.side * scale, exponent: squircleExponent))
        context.setFillColor(layer.color.cgColor())
        context.fillPath()
    }

    return context.makeImage()
}

func drawGlow(
    _ recipe: IconRecipe,
    in context: CGContext,
    at center: CGPoint,
    radius: CGFloat,
    colorSpace: CGColorSpace
) {
    guard let glow = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            recipe.glow.cgColor(alpha: recipe.glowAlpha),
            recipe.glow.cgColor(alpha: 0)
        ] as CFArray,
        locations: [0, 1]
    ) else { return }

    context.drawRadialGradient(
        glow,
        startCenter: center,
        startRadius: 0,
        endCenter: center,
        endRadius: radius,
        options: []
    )
}

func write(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw RenderError.cannotCreateFile(url)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw RenderError.cannotWriteFile(url)
    }
}

enum RenderError: Error, CustomStringConvertible {
    case missingOutputDirectory
    case cannotRender(String)
    case cannotCreateFile(URL)
    case cannotWriteFile(URL)

    var description: String {
        switch self {
        case .missingOutputDirectory:
            return "uso: swift RenderAppIcon.swift <directorio de salida>"
        case .cannotRender(let name):
            return "no se pudo dibujar \(name)"
        case .cannotCreateFile(let url):
            return "no se pudo crear \(url.path)"
        case .cannotWriteFile(let url):
            return "no se pudo escribir \(url.path)"
        }
    }
}

// MARK: - Entrada

do {
    guard CommandLine.arguments.count == 2 else { throw RenderError.missingOutputDirectory }
    let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let variants: [(name: String, recipe: IconRecipe)] = [
        ("AppIcon", .standard),
        ("AppIcon-Dark", .dark),
        ("AppIcon-Tinted", .tinted)
    ]

    for variant in variants {
        guard let image = render(variant.recipe, side: 1024) else {
            throw RenderError.cannotRender(variant.name)
        }
        let url = directory.appendingPathComponent("\(variant.name).png")
        try write(image, to: url)
        print("escrito \(url.path) (\(image.width)×\(image.height))")
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
