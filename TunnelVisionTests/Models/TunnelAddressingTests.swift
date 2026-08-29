import Foundation
import XCTest
import Shared

/// Tests del direccionamiento del túnel (M7). El provider en sí es device-only, pero esto no: es
/// el punto donde la misma dirección existe en dos representaciones —bytes para el pipeline, texto
/// para `NEPacketTunnelNetworkSettings`— y lo que se verifica es que no puedan divergir.
final class TunnelAddressingTests: XCTestCase {

    /// La cadena que se le anuncia a iOS tiene que ser exactamente la IP contra la que el pipeline
    /// compara para decidir el sentido. Si esto falla, el túnel se levanta con una IP y el
    /// historial registra todo el tráfico al revés.
    func testIPv4StringMatchesTheAddressGivenToThePipeline() {
        XCTAssertEqual(TunnelAddressing.ipv4AddressString, "10.7.0.2")
        XCTAssertEqual(TunnelAddressing.localIPv4.version, .v4)
        XCTAssertEqual(TunnelAddressing.localIPv4.bytes, [10, 7, 0, 2])
    }

    func testIPv6StringMatchesTheAddressGivenToThePipeline() {
        XCTAssertEqual(TunnelAddressing.ipv6AddressString, "fd00:7::2")
        XCTAssertEqual(TunnelAddressing.localIPv6.version, .v6)
        XCTAssertEqual(
            TunnelAddressing.localIPv6.bytes,
            [0xfd, 0x00, 0x00, 0x07, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x02]
        )
    }

    /// La IPv4 del túnel vive dentro de la máscara que se anuncia junto a ella; si no, iOS no
    /// enruta la subred.
    func testIPv4AddressIsConsistentWithItsSubnetMask() {
        XCTAssertEqual(TunnelAddressing.ipv4SubnetMask, "255.255.255.0")

        // Máscara /24 ⇒ los tres primeros bytes son la red y el cuarto es el host, que no puede ser
        // ni la dirección de red (.0) ni la de broadcast (.255).
        let host = TunnelAddressing.localIPv4.bytes[3]
        XCTAssertNotEqual(host, 0)
        XCTAssertNotEqual(host, 255)
    }

    /// Ambas direcciones tienen que ser de rango privado: son las de un interfaz virtual que no
    /// existe fuera del dispositivo, así que anunciar espacio público colisionaría con destinos reales.
    func testTunnelAddressesAreInPrivateRanges() {
        // RFC 1918: 10.0.0.0/8.
        XCTAssertEqual(TunnelAddressing.localIPv4.bytes[0], 10)
        // RFC 4193: fc00::/7 (fd00::/8 en la práctica).
        XCTAssertEqual(TunnelAddressing.localIPv6.bytes[0] & 0xfe, 0xfc)
    }

    func testGeometryMatchesTheSpec() {
        XCTAssertEqual(TunnelAddressing.ipv6PrefixLength, 64)
        XCTAssertEqual(TunnelAddressing.mtu, 1500)
        XCTAssertEqual(TunnelAddressing.tunnelRemoteAddress, "127.0.0.1")
    }
}
