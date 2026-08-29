import Foundation
import XCTest
import Shared

/// Tests del presupuesto de contenido descifrado por flujo. Lo que se afirma aquí es la decisión, no
/// la aritmética: que cada sentido tiene el suyo (una respuesta enorme no puede dejar sin sitio a las
/// peticiones siguientes), que lo que se conserva es el principio, y que lo que se queda fuera se
/// cuenta en vez de desaparecer sin más.
final class PlaintextBudgetTests: XCTestCase {

    func testAChunkThatFitsIsAllowedWhole() {
        var budget = PlaintextBudget(maxBytesPerDirection: 1_000)

        XCTAssertEqual(budget.allowance(for: 300, direction: .outbound), 300)
        XCTAssertEqual(budget.stored(.outbound), 300)
        XCTAssertEqual(budget.remaining(.outbound), 700)
    }

    func testAChunkThatOverflowsIsAllowedInPart() {
        var budget = PlaintextBudget(maxBytesPerDirection: 100)

        XCTAssertEqual(budget.allowance(for: 60, direction: .inbound), 60)
        XCTAssertEqual(budget.allowance(for: 60, direction: .inbound), 40)
        XCTAssertEqual(budget.allowance(for: 60, direction: .inbound), 0)
        XCTAssertEqual(budget.stored(.inbound), 100)
    }

    /// La decisión que da forma al tipo: dos presupuestos y no uno.
    func testEachDirectionHasItsOwnBudget() {
        var budget = PlaintextBudget(maxBytesPerDirection: 100)

        XCTAssertEqual(budget.allowance(for: 100, direction: .inbound), 100)
        XCTAssertEqual(budget.remaining(.inbound), 0)
        // La descarga se ha comido lo suyo y la petición siguiente sigue teniendo su sitio entero.
        XCTAssertEqual(budget.remaining(.outbound), 100)
        XCTAssertEqual(budget.allowance(for: 100, direction: .outbound), 100)
    }

    func testExhaustionNeedsBothDirections() {
        var budget = PlaintextBudget(maxBytesPerDirection: 10)

        XCTAssertEqual(budget.allowance(for: 10, direction: .outbound), 10)
        XCTAssertFalse(budget.isExhausted)

        XCTAssertEqual(budget.allowance(for: 10, direction: .inbound), 10)
        XCTAssertTrue(budget.isExhausted)
    }

    /// Con tope 0 no se copia ni un byte, que es lo que hace que apagar la persistencia no necesite
    /// tocar el camino por el que pasan los bytes.
    func testAZeroBudgetKeepsNothing() {
        var budget = PlaintextBudget(maxBytesPerDirection: 0)

        XCTAssertEqual(budget.allowance(for: 4_096, direction: .outbound), 0)
        XCTAssertTrue(budget.isExhausted)
    }

    func testANegativeBudgetIsReadAsZero() {
        var budget = PlaintextBudget(maxBytesPerDirection: -10)
        XCTAssertEqual(budget.allowance(for: 1, direction: .inbound), 0)
    }

    func testAnEmptyChunkSpendsNothing() {
        var budget = PlaintextBudget(maxBytesPerDirection: 10)

        XCTAssertEqual(budget.allowance(for: 0, direction: .outbound), 0)
        XCTAssertEqual(budget.remaining(.outbound), 10)
    }

    func testTheDefaultBudgetIs64KiBPerDirection() {
        var budget = PlaintextBudget()

        XCTAssertEqual(budget.remaining(.outbound), 64 * 1024)
        XCTAssertEqual(budget.allowance(for: 1_000_000, direction: .inbound), 64 * 1024)
    }

    /// Que se guarde el principio y no el final es una decisión, y esta es su afirmación: lo primero
    /// que llegó sigue dentro cuando el presupuesto se agota.
    func testItIsTheBeginningThatIsKept() {
        var budget = PlaintextBudget(maxBytesPerDirection: 10)

        XCTAssertEqual(budget.allowance(for: 4, direction: .outbound), 4)
        XCTAssertEqual(budget.allowance(for: 4, direction: .outbound), 4)
        XCTAssertEqual(budget.allowance(for: 4, direction: .outbound), 2)
        XCTAssertEqual(budget.allowance(for: 4, direction: .outbound), 0)
        XCTAssertEqual(budget.stored(.outbound), 10)
    }

    // MARK: - Lo que se quedó fuera

    func testTruncationCountsWhatDidNotFit() {
        var budget = PlaintextBudget(maxBytesPerDirection: 100)
        var truncation = PlaintextTruncation()
        XCTAssertTrue(truncation.isEmpty)

        for _ in 0..<3 {
            let chunk = 60
            let allowed = budget.allowance(for: chunk, direction: .inbound)
            truncation.add(dropped: chunk - allowed, direction: .inbound)
        }

        XCTAssertEqual(truncation.droppedInbound, 80)   // 0 + 20 + 60
        XCTAssertEqual(truncation.droppedOutbound, 0)
        XCTAssertFalse(truncation.isEmpty)
    }

    func testTruncationIgnoresNonPositiveAmounts() {
        var truncation = PlaintextTruncation()
        truncation.add(dropped: 0, direction: .inbound)
        truncation.add(dropped: -5, direction: .outbound)
        XCTAssertTrue(truncation.isEmpty)
    }
}
