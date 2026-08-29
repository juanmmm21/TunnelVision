import Foundation
import XCTest
import Shared

/// Tests de **cuándo** un cambio de red merece que el túnel vuelva a anunciar el DNS.
///
/// Es la mitad pura del arreglo, y la que puede hacer daño en las dos direcciones: reanunciar de más
/// cuesta una ventana sin ajustes de red —o sea un hueco en la captura— cada vez que la Wi-Fi
/// parpadea, y reanunciar de menos deja el fallo donde estaba, con el dispositivo mandando su DNS a
/// la puerta de enlace de una red en la que ya no está.
final class NetworkPathSignatureTests: XCTestCase {

    private func signature(
        satisfied: Bool = true,
        interfaces: [String] = ["en0"],
        gateways: [String] = ["192.168.1.1"]
    ) -> NetworkPathSignature {
        NetworkPathSignature(isSatisfied: satisfied, interfaces: interfaces, gateways: gateways)
    }

    // MARK: - Lo que dispara

    /// Salir de casa: la Wi-Fi se va y queda la red móvil. Es el caso confirmado en el iPhone.
    func testSwappingWifiForCellularWarrantsAReannouncement() {
        let home = signature(interfaces: ["en0"], gateways: ["192.168.1.1"])
        let street = signature(interfaces: ["pdp_ip0"], gateways: ["10.66.0.1"])

        XCTAssertTrue(NetworkPathSignature.warrantsReannouncement(from: home, to: street))
    }

    /// Cambiar de Wi-Fi a otra Wi-Fi **no cambia el interfaz**: `en0` sigue siendo `en0`. Sin mirar el
    /// router, este caso —irse de casa a la oficina— no se vería.
    func testAnotherWifiWithADifferentRouterWarrantsAReannouncement() {
        let home = signature(gateways: ["192.168.1.1"])
        let office = signature(gateways: ["10.0.0.1"])

        XCTAssertTrue(NetworkPathSignature.warrantsReannouncement(from: home, to: office))
    }

    // MARK: - Lo que no dispara, y por qué importa

    /// Un camino que no sirve no tiene DNS que aprender, y reanunciar exige quitar los ajustes de red:
    /// hacerlo justo cuando no hay red es quedarse sin poder poner unos buenos.
    func testAnUnsatisfiedPathNeverWarrantsAReannouncement() {
        let home = signature()
        let nothing = signature(satisfied: false, interfaces: [], gateways: [])

        XCTAssertFalse(NetworkPathSignature.warrantsReannouncement(from: home, to: nothing))
    }

    /// La primera red que se ve es sobre la que `startTunnel` ya leyó y anunció: solo se apunta.
    func testTheFirstPathSeenIsRecordedAndNotActedUpon() {
        XCTAssertFalse(NetworkPathSignature.warrantsReannouncement(from: nil, to: signature()))
    }

    /// Un corte y una vuelta a la misma Wi-Fi da la misma firma, y sus resolvers son los mismos:
    /// reanunciar ahí es pagar el hueco de captura a cambio de nada.
    func testComingBackToTheSameNetworkDoesNotWarrantAnything() {
        let home = signature()

        XCTAssertFalse(NetworkPathSignature.warrantsReannouncement(from: home, to: signature()))
    }

    /// El orden en que el sistema enumera interfaces y routers no es un dato: dos listas iguales en
    /// otro orden describen la misma red, y tomarlas por distintas sería un reanuncio por cada
    /// notificación.
    func testTheOrderTheSystemEnumeratesThingsInIsNotAChange() {
        let one = signature(interfaces: ["en0", "pdp_ip0"], gateways: ["192.168.1.1", "fe80::1"])
        let other = signature(interfaces: ["pdp_ip0", "en0"], gateways: ["fe80::1", "192.168.1.1"])

        XCTAssertFalse(NetworkPathSignature.warrantsReannouncement(from: one, to: other))
    }

    /// Y el caso que esta regla **no** puede ver, escrito para que nadie lo descubra dos veces: dos
    /// redes con el mismo interfaz y el mismo router son indistinguibles desde aquí. Lo recoge el otro
    /// extremo del problema —consultas de DNS sin respuesta—, que mide el síntoma en vez de la causa.
    func testTwoNetworksThatLookIdenticalAreIndistinguishableHere() {
        let home = signature(gateways: ["192.168.1.1"])
        let anotherHouseWithTheSameRouter = signature(gateways: ["192.168.1.1"])

        XCTAssertFalse(
            NetworkPathSignature.warrantsReannouncement(from: home, to: anotherHouseWithTheSameRouter)
        )
    }
}
