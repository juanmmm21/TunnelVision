import CoreGraphics
import XCTest

/// Cuántos tramos puede ofrecer el eje de la Timeline. Es la regla que impide que un pase de diseño
/// —o un historial más largo— vuelva a dejar tramos de catorce puntos, que es lo que Juan encontró
/// usando la app: el eje existe para **tocar** un trozo del pasado, así que un tramo es un objetivo
/// táctil y le debe los 44 puntos de la HIG.
final class ScrubCapacityTests: XCTestCase {

    /// Los anchos de pantalla que existen de verdad, del iPhone más estrecho que iOS 17 admite al más
    /// ancho. No es una lista decorativa: es contra lo que se afirma que ningún tramo baja del mínimo.
    private let phoneWidths: [CGFloat] = [320, 375, 390, 393, 402, 428, 430, 440]

    // MARK: - La regla

    /// Lo que este fichero existe para impedir: que un tramo sea más estrecho que un dedo.
    func testNoIntervalIsEverNarrowerThanTheTouchMinimum() {
        for width in phoneWidths {
            guard let intervals = ScrubCapacity.intervals(inScreenOfWidth: width) else {
                return XCTFail("un iPhone de \(width) puntos tiene que dar algún tramo")
            }
            let drawable = width - ScrubCapacity.horizontalBudget
            XCTAssertGreaterThanOrEqual(
                drawable / CGFloat(intervals), TouchTarget.minimum,
                "a \(width) puntos, \(intervals) tramos salen a menos de 44"
            )
        }
    }

    /// Y que no se pase por el otro lado: pedir menos de los que caben sería tirar resolución que el
    /// dedo sí podía usar.
    func testOneMoreIntervalWouldNotFit() {
        for width in phoneWidths {
            guard let intervals = ScrubCapacity.intervals(inScreenOfWidth: width) else { continue }
            let drawable = width - ScrubCapacity.horizontalBudget
            XCTAssertLessThan(
                drawable / CGFloat(intervals + 1), TouchTarget.minimum,
                "a \(width) puntos cabía un tramo más de los \(intervals) que se ofrecen"
            )
        }
    }

    /// Cuantos más puntos, más tramos: una pantalla más ancha nunca puede ofrecer menos.
    func testAWiderScreenNeverOffersFewerIntervals() {
        let counts = phoneWidths.compactMap { ScrubCapacity.intervals(inScreenOfWidth: $0) }
        XCTAssertEqual(counts.count, phoneWidths.count)
        XCTAssertEqual(counts, counts.sorted())
    }

    // MARK: - Lo que no se sabe todavía

    /// Una anchura que no dice nada devuelve `nil` y **no** un uno de reserva: quien pregunta se queda
    /// con lo que tenía en vez de redibujar el eje con un tramo único antes de que nadie lo mire.
    func testAnUnmeasuredWidthAnswersNothingRatherThanOne() {
        XCTAssertNil(ScrubCapacity.intervals(inScreenOfWidth: 0))
        XCTAssertNil(ScrubCapacity.intervals(inScreenOfWidth: -320))
        XCTAssertNil(ScrubCapacity.intervals(inScreenOfWidth: .nan))
        XCTAssertNil(ScrubCapacity.intervals(inScreenOfWidth: .infinity))
        // Ancha, pero no lo bastante para un solo tramo con sus márgenes puestos.
        XCTAssertNil(
            ScrubCapacity.intervals(
                inScreenOfWidth: ScrubCapacity.horizontalBudget + TouchTarget.minimum - 1
            )
        )
    }

    /// El límite exacto sí cuenta: justo un tramo es un eje, aunque sea uno.
    func testExactlyOneIntervalStillCounts() {
        XCTAssertEqual(
            ScrubCapacity.intervals(
                inScreenOfWidth: ScrubCapacity.horizontalBudget + TouchTarget.minimum
            ),
            1
        )
    }

    // MARK: - De dónde sale el presupuesto

    /// Lo que se descuenta son los huecos que el eje tiene puestos —los márgenes de su tarjeta, el
    /// relleno de la tarjeta y el del carril hundido—, y no un número redondeado a ojo. Si alguien
    /// cambia un token, el presupuesto tiene que moverse con él.
    func testTheBudgetIsMadeOfTheSpacingsTheAxisActuallyHas() {
        XCTAssertEqual(
            ScrubCapacity.horizontalBudget,
            2 * Spacing.card + 2 * Spacing.row + 2 * Spacing.tight
        )
    }
}
