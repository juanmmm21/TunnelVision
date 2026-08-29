import Foundation
import XCTest

/// Tests de la memoria de hosts que pinnean. Es un valor diminuto, pero lo que sostiene es la mitad
/// del ADR 0003 que se nota: sin ella el reintento del cliente —que llega con otra `FlowKey`— se
/// volvería a terminar, y el usuario vería su app romperse una y otra vez.
final class PinnedHostMemoryTests: XCTestCase {

    func testRemembersAHost() {
        var memory = PinnedHostMemory()
        XCTAssertFalse(memory.contains("example.com"))

        memory.remember("example.com")

        XCTAssertTrue(memory.contains("example.com"))
        XCTAssertFalse(memory.contains("otro.com"))
        XCTAssertEqual(memory.count, 1)
    }

    func testRememberingTwiceDoesNotDuplicate() {
        var memory = PinnedHostMemory(capacity: 2)

        memory.remember("a.com")
        memory.remember("a.com")
        memory.remember("b.com")

        XCTAssertEqual(memory.count, 2)
        XCTAssertTrue(memory.contains("a.com"))
        XCTAssertTrue(memory.contains("b.com"))
    }

    /// El tope existe para que una sesión larga contra muchos hosts pinneados no haga crecer la
    /// memoria de la extensión: al llenarse sale el más antiguo.
    func testTheOldestIsForgottenWhenFull() {
        var memory = PinnedHostMemory(capacity: 2)

        memory.remember("a.com")
        memory.remember("b.com")
        memory.remember("c.com")

        XCTAssertEqual(memory.count, 2)
        XCTAssertFalse(memory.contains("a.com"))
        XCTAssertTrue(memory.contains("b.com"))
        XCTAssertTrue(memory.contains("c.com"))
    }

    /// Repetir un host no lo rejuvenece: su antigüedad sigue siendo la de la primera vez, así que
    /// sigue siendo el siguiente en salir.
    func testRepeatingAHostDoesNotRefreshItsAge() {
        var memory = PinnedHostMemory(capacity: 2)

        memory.remember("a.com")
        memory.remember("b.com")
        memory.remember("a.com")
        memory.remember("c.com")

        XCTAssertFalse(memory.contains("a.com"))
        XCTAssertTrue(memory.contains("b.com"))
        XCTAssertTrue(memory.contains("c.com"))
    }

    /// Un tope no positivo dejaría la estructura inservible en silencio (nada se recordaría nunca):
    /// se colapsa a uno, que es el mínimo con el que sigue significando lo que dice.
    func testANonPositiveCapacityStillRemembersOne() {
        var memory = PinnedHostMemory(capacity: 0)

        memory.remember("a.com")

        XCTAssertTrue(memory.contains("a.com"))
        XCTAssertEqual(memory.count, 1)
    }
}
