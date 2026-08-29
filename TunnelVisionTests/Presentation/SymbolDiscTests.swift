import CoreGraphics
import XCTest

/// El disco que lleva un símbolo detrás. Es la regla que impide volver a tener dos constantes sueltas
/// —el lado del glifo por un lado y el diámetro de su fondo por otro— unidas solo por un comentario:
/// el disco tiene que **contener** el glifo, y contenerlo es cubrir la diagonal de su caja y no su
/// lado.
final class SymbolDiscTests: XCTestCase {

    /// Los lados de glifo que dibuja la app hoy, del más pequeño al más grande, y los que salen al
    /// escalar con Dynamic Type hasta AX5.
    private let symbolSides: [CGFloat] = [16, 20, 24, 28, 30, 44, 56, 72, 96]

    // MARK: - La regla

    /// Lo que este fichero existe para impedir: un disco que le corta las esquinas al glifo que lleva.
    func testTheDiscAlwaysCoversTheGlyphsDiagonal() {
        for side in symbolSides {
            guard let diameter = SymbolDisc.diameter(forSymbolOfSide: side) else {
                return XCTFail("un glifo de \(side) puntos tiene que caber en algún disco")
            }
            XCTAssertGreaterThanOrEqual(
                diameter, side * 2.0.squareRoot(),
                "a \(side) puntos de lado el disco corta las esquinas del glifo"
            )
        }
    }

    /// Y que no se pase por el otro lado, que es el defecto que trae aquí: un fondo que pesa más que
    /// lo que lleva dentro. El doble del lado era lo que había en el intro, y de ahí salía el 38 % del
    /// alto de la tarjeta que se llevaba el adorno.
    func testTheDiscNeverGrowsToTwiceTheGlyph() {
        for side in symbolSides {
            guard let diameter = SymbolDisc.diameter(forSymbolOfSide: side) else { continue }
            XCTAssertLessThan(
                diameter, side * 2,
                "a \(side) puntos de lado el disco vuelve a ser el doble del glifo"
            )
        }
    }

    /// La proporción no depende del tamaño: un glifo grande y uno pequeño llevan el mismo disco
    /// relativo, que es lo que hace que el símbolo se lea igual a tamaño normal y a AX5.
    func testTheRatioIsTheSameAtEverySize() {
        let ratios = symbolSides.compactMap { side in
            SymbolDisc.diameter(forSymbolOfSide: side).map { $0 / side }
        }
        XCTAssertEqual(ratios.count, symbolSides.count)
        for ratio in ratios {
            XCTAssertEqual(ratio, ratios[0], accuracy: 0.0001, "la proporción cambia con el tamaño")
        }
    }

    /// Crecer es crecer: un glifo mayor nunca lleva un disco menor.
    func testABiggerGlyphNeverGetsASmallerDisc() {
        let diameters = symbolSides.compactMap { SymbolDisc.diameter(forSymbolOfSide: $0) }
        XCTAssertEqual(diameters, diameters.sorted())
    }

    // MARK: - Lo que no es un tamaño

    /// Un lado que no es un número, o que no es positivo, no es un símbolo pequeño: es uno que aún no
    /// se ha medido. Contestar con un número dibujaría un disco alrededor de nada.
    func testASideThatIsNotAMeasurementHasNoDisc() {
        XCTAssertNil(SymbolDisc.diameter(forSymbolOfSide: 0))
        XCTAssertNil(SymbolDisc.diameter(forSymbolOfSide: -44))
        XCTAssertNil(SymbolDisc.diameter(forSymbolOfSide: .nan))
        XCTAssertNil(SymbolDisc.diameter(forSymbolOfSide: .infinity))
    }
}
