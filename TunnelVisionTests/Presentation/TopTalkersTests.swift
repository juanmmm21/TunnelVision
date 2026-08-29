import Foundation
import XCTest
import Shared

/// La agregación de los paquetes recientes en "quién está hablando ahora". Se prueba contra
/// `LivePacket`s construidos como los construye el lector —desde un registro empaquetado del ring y
/// las IPs del túnel—, no a mano, para que el reparto local/remoto sea el real.
final class TopTalkersTests: XCTestCase {

    private let anchor = MonotonicAnchor(uptimeNanoseconds: 0, wallClock: Date(timeIntervalSince1970: 1_700_000_000))

    private func packet(
        _ sequence: UInt64,
        peer: IPEndpoint,
        direction: Direction,
        length: UInt32,
        port: UInt16 = 51_000
    ) -> LivePacket {
        LivePacket(
            LiveFeedFixtures.packed(
                timestamp: sequence * 1_000,
                direction: direction,
                length: length,
                port: port,
                peer: peer
            ),
            sequence: sequence,
            anchor: anchor,
            localAddresses: TunnelAddressing.localAddresses
        )
    }

    private func remote(_ lastByte: UInt8, port: UInt16 = 443) -> IPEndpoint {
        IPEndpoint(address: IPAddress(version: .v4, bytes: [93, 184, 216, lastByte]), port: port)
    }

    // MARK: - Agregación

    /// Se agrega por **host**, no por conexión: al usuario le importa con quién habla el dispositivo,
    /// no cuántos sockets abrió el navegador contra el mismo sitio.
    func testPacketsOfDifferentFlowsToTheSameHostAddUp() {
        let packets = [
            packet(1, peer: remote(34), direction: .outbound, length: 100, port: 51_000),
            packet(2, peer: remote(34, port: 80), direction: .outbound, length: 200, port: 52_000),
            packet(3, peer: remote(34), direction: .inbound, length: 400, port: 51_000),
        ]

        let talkers = TopTalkers.compute(from: packets, limit: 5)

        XCTAssertEqual(talkers.count, 1)
        XCTAssertEqual(talkers[0].bytesOut, 300)
        XCTAssertEqual(talkers[0].bytesIn, 400)
        XCTAssertEqual(talkers[0].totalBytes, 700)
        XCTAssertEqual(talkers[0].packetCount, 3)
        // Tres paquetes pero dos conexiones: el primero y el tercero son la misma 5-tupla en sentidos
        // opuestos, y la clave de flujo es canónica precisamente para que eso no cuente dos veces.
        XCTAssertEqual(talkers[0].flowCount, 2)
        XCTAssertEqual(talkers[0].displayHost, "93.184.216.34")
    }

    func testHostsAreSortedByTotalBytes() {
        let packets = [
            packet(1, peer: remote(10), direction: .outbound, length: 100),
            packet(2, peer: remote(20), direction: .inbound, length: 900),
            packet(3, peer: remote(30), direction: .outbound, length: 500),
        ]

        let talkers = TopTalkers.compute(from: packets, limit: 5)

        XCTAssertEqual(talkers.map(\.displayHost), ["93.184.216.20", "93.184.216.30", "93.184.216.10"])
    }

    /// Sin un orden total, dos hosts empatados podrían intercambiarse entre instantáneas y la lista
    /// parpadearía sola mientras el usuario la mira.
    func testTiesAreBrokenDeterministically() {
        let packets = [
            packet(1, peer: remote(50), direction: .outbound, length: 300),
            packet(2, peer: remote(20), direction: .outbound, length: 300),
        ]

        let first = TopTalkers.compute(from: packets, limit: 5)
        let second = TopTalkers.compute(from: packets.reversed(), limit: 5)

        XCTAssertEqual(first.map(\.displayHost), ["93.184.216.20", "93.184.216.50"])
        XCTAssertEqual(first, second)
    }

    func testOnlyTheRequestedNumberOfHostsIsReturned() {
        let packets = (1...6).map { index in
            packet(UInt64(index), peer: remote(UInt8(index * 10)), direction: .inbound, length: UInt32(index) * 100)
        }

        let talkers = TopTalkers.compute(from: packets, limit: 3)

        XCTAssertEqual(talkers.count, 3)
        XCTAssertEqual(talkers.map(\.displayHost), ["93.184.216.60", "93.184.216.50", "93.184.216.40"])
    }

    /// Un paquete cuyos extremos no se pudieron repartir no se le atribuye a nadie: sin saber cuál de
    /// los dos lados es el dispositivo, contarle los bytes a uno sería inventarse el dato.
    func testPacketsWhoseEndpointsCouldNotBeSplitAreIgnored() {
        let foreign = PacketMeta(
            timestamp: 1_000,
            flowKey: FlowKey(proto: .tcp, source: remote(10, port: 40_000), destination: remote(20)),
            direction: .outbound,
            length: 5_000,
            tcpFlags: [],
            capture: nil
        )
        let packets = [
            LivePacket(
                PackedPacketMeta(foreign),
                sequence: 1,
                anchor: anchor,
                localAddresses: TunnelAddressing.localAddresses
            ),
            packet(2, peer: remote(34), direction: .inbound, length: 100),
        ]

        let talkers = TopTalkers.compute(from: packets, limit: 5)

        XCTAssertEqual(talkers.count, 1)
        XCTAssertEqual(talkers[0].displayHost, "93.184.216.34")
        XCTAssertEqual(talkers[0].totalBytes, 100)
    }

    func testAnEmptyFeedHasNoTalkers() {
        XCTAssertTrue(TopTalkers.compute(from: [], limit: 5).isEmpty)
    }
}
