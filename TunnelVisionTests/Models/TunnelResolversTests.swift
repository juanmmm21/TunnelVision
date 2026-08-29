import Foundation
import XCTest
import Shared

/// Tests de **qué resolvers puede anunciar el túnel**, que es la mitad pura de la decisión tomada el
/// 2026-08-15: el interfaz virtual se lleva las dos rutas por defecto, así que sin ofrecer resolución
/// de nombres deja al dispositivo sin red — y la salida es reanunciar los del sistema, no fijar uno
/// público.
///
/// Lo que aquí se afirma es lo que sobrevive al filtro y lo que no, con su motivo. La lectura de la
/// configuración real (`SystemResolvers` + el shim de C) no está aquí a propósito: lo que hay debajo
/// es el estado del dispositivo, que un Simulator no puede guionizar.
final class TunnelResolversTests: XCTestCase {

    // MARK: - Lo que pasa el filtro

    func testOrdinaryResolversSurviveInTheOrderTheSystemGaveThem() {
        let announceable = TunnelResolvers.announceable(from: ["192.168.1.1", "1.1.1.1", "2001:db8::53"])

        XCTAssertEqual(announceable.map(\.description), ["192.168.1.1", "1.1.1.1", "2001:db8::53"])
    }

    /// El orden **es** la preferencia del sistema, así que el filtro no ordena: solo descarta.
    func testTheOrderIsNeverRearranged() {
        let announceable = TunnelResolvers.announceable(from: ["9.9.9.9", "1.1.1.1"])

        XCTAssertEqual(announceable.map(\.description), ["9.9.9.9", "1.1.1.1"])
    }

    /// Una IP privada o link-local **IPv4** se anuncia tal cual: el relay la alcanza desde el
    /// interfaz real, igual que alcanza cualquier otro destino, y no necesita zona para significar
    /// algo. Es justo la línea que la separa del `fe80::`.
    func testPrivateAndIPv4LinkLocalResolversAreKept() {
        let announceable = TunnelResolvers.announceable(from: ["10.0.0.1", "169.254.1.1", "192.168.0.254"])

        XCTAssertEqual(announceable.count, 3)
    }

    // MARK: - Lo que se cae, y por qué

    /// Un resolver de loopback anunciado por el túnel manda las consultas a la propia máquina en vez
    /// de al túnel: sería exactamente el síntoma que esto existe para arreglar.
    func testLoopbackResolversAreDropped() {
        let announceable = TunnelResolvers.announceable(from: ["127.0.0.1", "127.0.0.53", "::1", "8.8.8.8"])

        XCTAssertEqual(announceable.map(\.description), ["8.8.8.8"])
    }

    /// El loopback escrito en la otra familia es el mismo destino y tiene la misma consecuencia.
    func testIPv4MappedLoopbackIsDroppedToo() {
        let announceable = TunnelResolvers.announceable(from: ["::ffff:127.0.0.1"])

        XCTAssertTrue(announceable.isEmpty)
    }

    /// `fe80::/10` solo significa algo dentro de un interfaz concreto, y la zona que lo diría
    /// (`%en0`) no cabe en `NEDNSSettings.servers`. Anunciarla a secas mandaría la consulta por el
    /// interfaz equivocado.
    func testIPv6LinkLocalResolversAreDropped() {
        let announceable = TunnelResolvers.announceable(
            from: ["fe80::1", "febf::1", "fec0::1", "2001:db8::1"]
        )

        // `fec0::/10` ya no es link-local (es el site-local retirado), así que no lo toca este filtro.
        XCTAssertEqual(announceable.map(\.description), ["fec0::1", "2001:db8::1"])
    }

    func testUnspecifiedAddressesAreDropped() {
        let announceable = TunnelResolvers.announceable(from: ["0.0.0.0", "::", "1.1.1.1"])

        XCTAssertEqual(announceable.map(\.description), ["1.1.1.1"])
    }

    /// El origen es `inet_ntop`, así que esto no debería ocurrir nunca; pero un resolver inventado
    /// es peor que un resolver de menos.
    func testTextThatIsNotAnAddressIsDropped() {
        let announceable = TunnelResolvers.announceable(from: ["dns.example.com", "", "1.1.1.1", "1.1.1"])

        XCTAssertEqual(announceable.map(\.description), ["1.1.1.1"])
    }

    /// Se conserva la primera aparición, que es la de mayor preferencia. Y el duplicado se detecta
    /// por la **dirección**, no por el texto: `2001:db8::1` y `2001:0db8:0:0:0:0:0:1` son la misma.
    func testDuplicatesAreDroppedKeepingTheFirstOne() {
        let announceable = TunnelResolvers.announceable(
            from: ["1.1.1.1", "2001:db8::1", "1.1.1.1", "2001:0db8:0000:0000:0000:0000:0000:0001"]
        )

        XCTAssertEqual(announceable.map(\.description), ["1.1.1.1", "2001:db8::1"])
    }

    /// El caso que deja al túnel sin nada que anunciar: se devuelve vacío y no se inventa un
    /// resolver público. Quien llama decide qué hacer con eso.
    func testEverythingUnusableProducesAnEmptyListAndNotAFallback() {
        let announceable = TunnelResolvers.announceable(from: ["127.0.0.1", "fe80::1", "::"])

        XCTAssertTrue(announceable.isEmpty)
    }

    func testNothingInNothingOut() {
        XCTAssertTrue(TunnelResolvers.announceable(from: []).isEmpty)
    }
}
