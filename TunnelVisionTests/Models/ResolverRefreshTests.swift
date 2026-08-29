import Foundation
import XCTest
import Shared

/// Tests de qué anuncia el túnel **después** de un cambio de red.
///
/// El contexto que da sentido a todas las reglas de aquí: cuando esto decide, el túnel ya se ha
/// quedado **sin ajustes de red aplicados** —hay que quitarlos para poder leer los resolvers de
/// verdad, medido en el iPhone el 2026-08-16—, así que ninguna respuesta puede dejar al dispositivo
/// sin resolución de nombres.
final class ResolverRefreshTests: XCTestCase {

    private func addresses(_ texts: [String]) -> [IPAddress] {
        texts.compactMap { IPAddress(parsing: $0) }
    }

    // MARK: - Cuando la relectura sirve

    /// El caso que arregla el fallo: la red nueva ofrece otros resolvers y se anuncian.
    func testResolversOfTheNewNetworkAreAnnouncedAndCountedAsLearned() {
        let decision = ResolverRefresh.decide(
            reported: ["10.11.12.13"],
            currentlyAnnounced: addresses(["192.168.1.1"])
        )

        XCTAssertEqual(decision.announce.map(\.description), ["10.11.12.13"])
        XCTAssertTrue(decision.learnedSomethingNew)
    }

    /// La misma red otra vez: se reanuncia lo mismo, pero **no** cuenta como aprendizaje. Ese
    /// contador es la medición de si quitar los ajustes sirve de algo, así que inflarlo con
    /// repeticiones lo dejaría sin significado.
    func testTheSameResolversAreNotCountedAsSomethingLearned() {
        let decision = ResolverRefresh.decide(
            reported: ["192.168.1.1"],
            currentlyAnnounced: addresses(["192.168.1.1"])
        )

        XCTAssertEqual(decision.announce.map(\.description), ["192.168.1.1"])
        XCTAssertFalse(decision.learnedSomethingNew)
    }

    /// El orden **es** la preferencia del sistema: los mismos resolvers al revés son una preferencia
    /// distinta, y anunciarlos como vienen es lo que la respeta.
    func testAChangeOfOrderCountsAsAChange() {
        let decision = ResolverRefresh.decide(
            reported: ["8.8.8.8", "1.1.1.1"],
            currentlyAnnounced: addresses(["1.1.1.1", "8.8.8.8"])
        )

        XCTAssertEqual(decision.announce.map(\.description), ["8.8.8.8", "1.1.1.1"])
        XCTAssertTrue(decision.learnedSomethingNew)
    }

    /// Lo que no se puede anunciar sigue sin poder anunciarse aquí: el filtro es el mismo de siempre.
    func testTheAnnounceableFilterStillApplies() {
        let decision = ResolverRefresh.decide(
            reported: ["fe80::1", "192.168.0.1", "127.0.0.1"],
            currentlyAnnounced: addresses(["192.168.1.1"])
        )

        XCTAssertEqual(decision.announce.map(\.description), ["192.168.0.1"])
    }

    // MARK: - Cuando no sirve, que es lo que hay que hacer bien

    /// No se pudo preguntar. Como los ajustes ya están quitados, devolver una lista vacía dejaría al
    /// dispositivo sin nombres: se conserva lo de antes, que al menos puede seguir sirviendo.
    func testAnUnreadableSystemKeepsWhatWasAlreadyAnnounced() {
        let decision = ResolverRefresh.decide(
            reported: nil,
            currentlyAnnounced: addresses(["192.168.1.1"])
        )

        XCTAssertEqual(decision.announce.map(\.description), ["192.168.1.1"])
        XCTAssertFalse(decision.learnedSomethingNew)
    }

    /// Y lo mismo si lo que contesta no contiene nada anunciable: una red que solo ofrezca un
    /// link-local IPv6 no puede convertirse en "este túnel ya no tiene DNS".
    func testNothingAnnounceableAlsoKeepsWhatWasAlreadyAnnounced() {
        let decision = ResolverRefresh.decide(
            reported: ["fe80::1"],
            currentlyAnnounced: addresses(["192.168.1.1"])
        )

        XCTAssertEqual(decision.announce.map(\.description), ["192.168.1.1"])
        XCTAssertFalse(decision.learnedSomethingNew)
    }

    /// El único caso en que se anuncia vacío es cuando ya se estaba anunciando vacío: no hay nada que
    /// conservar, y sigue sin haber nada que anunciar.
    func testWithNothingBeforeAndNothingNowTheAnnouncementStaysEmpty() {
        let decision = ResolverRefresh.decide(reported: [], currentlyAnnounced: [])

        XCTAssertTrue(decision.announce.isEmpty)
        XCTAssertFalse(decision.learnedSomethingNew)
    }
}
