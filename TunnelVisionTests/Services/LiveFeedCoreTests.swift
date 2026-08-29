import Foundation
import XCTest
import Shared

/// Tests del núcleo puro del feed en vivo (M9): el ancla temporal, el reparto de endpoints y la
/// conversión del registro del ring al modelo que pinta la UI.
///
/// Son las tres cosas que `PackedPacketMeta` **no** sabe: en qué momento de la hora de pared ocurrió
/// el paquete, cuál de sus dos extremos es el dispositivo, y cómo se le presenta eso a una vista.
final class LiveFeedCoreTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Ancla temporal

    /// El sello de un paquete es uptime en nanosegundos, no un epoch. Sin ancla, todo el tráfico
    /// aterrizaría en 1970 y el eje temporal de la UI sería basura.
    func testTheAnchorTurnsTheMonotonicStampIntoWallClock() {
        let anchor = MonotonicAnchor(uptimeNanoseconds: 1_000_000_000, wallClock: epoch)

        let date = anchor.date(forUptime: 3_500_000_000)

        XCTAssertEqual(date.timeIntervalSince(epoch), 2.5, accuracy: 1e-9)
    }

    /// Un paquete que ya estaba en el ring cuando la app arrancó es **anterior** al ancla. La resta
    /// tiene que hacerse con signo: sin eso, un `UInt64` envolvente lo situaría 584 años en el futuro.
    func testAPacketOlderThanTheAnchorLandsInThePast() {
        let anchor = MonotonicAnchor(uptimeNanoseconds: 1_000_000_000, wallClock: epoch)

        let date = anchor.date(forUptime: 500_000_000)

        XCTAssertEqual(date.timeIntervalSince(epoch), -0.5, accuracy: 1e-9)
    }

    /// La razón de anclar una sola vez: el espaciado relativo entre paquetes se conserva exacto,
    /// que es lo que hace creíble el gráfico. Re-anclar por lote metería el jitter del muestreo.
    func testTheAnchorPreservesTheSpacingBetweenPackets() {
        let anchor = MonotonicAnchor(uptimeNanoseconds: 0, wallClock: epoch)

        let first = anchor.date(forUptime: 10_000_000_000)
        let second = anchor.date(forUptime: 10_250_000_000)

        XCTAssertEqual(second.timeIntervalSince(first), 0.25, accuracy: 1e-9)
    }

    // MARK: - Reparto de endpoints

    /// El endpoint local es el que lleva una IP del túnel, esté en A o en B: `FlowKey` es canónico y
    /// el orden lo decide la dirección, no el sentido.
    func testTheDeviceIsWhicheverEndpointCarriesATunnelAddress() {
        let device = LiveFeedFixtures.device()
        let highKey = FlowKey(proto: .tcp, source: device, destination: LiveFeedFixtures.remote)
        let lowKey = FlowKey(proto: .tcp, source: device, destination: LiveFeedFixtures.lowRemote)

        // 10.7.0.2 < 93.184.216.34 ⇒ el dispositivo es A; 1.2.3.4 < 10.7.0.2 ⇒ el dispositivo es B.
        XCTAssertEqual(highKey.endpointA, device)
        XCTAssertEqual(lowKey.endpointB, device)

        let high = LiveFeedAddressing.endpoints(of: highKey, localAddresses: TunnelAddressing.localAddresses)
        let low = LiveFeedAddressing.endpoints(of: lowKey, localAddresses: TunnelAddressing.localAddresses)

        XCTAssertEqual(high?.local, device)
        XCTAssertEqual(high?.remote, LiveFeedFixtures.remote)
        XCTAssertEqual(low?.local, device)
        XCTAssertEqual(low?.remote, LiveFeedFixtures.lowRemote)
    }

    /// La IP v6 del túnel cuenta igual que la v4: `localAddresses` lleva las dos.
    func testTheIPv6TunnelAddressIsRecognisedToo() {
        let device = IPEndpoint(address: TunnelAddressing.localIPv6, port: 51_000)
        let peer = IPEndpoint(
            address: IPAddress(version: .v6, bytes: [0x20, 0x01, 0x0d, 0xb8] + [UInt8](repeating: 0, count: 11) + [1]),
            port: 443
        )
        let key = FlowKey(proto: .tcp, source: device, destination: peer)

        let endpoints = LiveFeedAddressing.endpoints(of: key, localAddresses: TunnelAddressing.localAddresses)

        XCTAssertEqual(endpoints?.local, device)
        XCTAssertEqual(endpoints?.remote, peer)
    }

    /// Sin ninguna IP local reconocible no se adivina: enseñar como "host" al propio dispositivo
    /// invertiría lo que el usuario lee, y una fila sin host es menos dañina que una fila mentirosa.
    func testAFlowWithNoTunnelAddressHasNoEndpointsInsteadOfAGuess() {
        let key = FlowKey(proto: .udp, source: LiveFeedFixtures.lowRemote, destination: LiveFeedFixtures.remote)

        XCTAssertNil(LiveFeedAddressing.endpoints(of: key, localAddresses: TunnelAddressing.localAddresses))
    }

    // MARK: - Conversión

    /// Todo lo que porta el registro llega intacto al modelo de la UI: si algo se perdiera aquí, la
    /// pantalla de detalle no podría saltar al `pcap` ni enseñar las banderas TCP.
    func testTheConversionCarriesEveryFieldOfTheRecord() {
        let anchor = MonotonicAnchor(uptimeNanoseconds: 1_000_000_000, wallClock: epoch)
        let meta = LiveFeedFixtures.meta(
            timestamp: 4_000_000_000,
            direction: .outbound,
            length: 1_420,
            tcpFlags: [.syn, .ack],
            capture: CaptureLocation(fileSequence: 4, recordOffset: 24)
        )

        let packet = LivePacket(
            PackedPacketMeta(meta),
            sequence: 7,
            anchor: anchor,
            localAddresses: TunnelAddressing.localAddresses
        )

        XCTAssertEqual(packet.id, 7)
        XCTAssertEqual(packet.flowKey, meta.flowKey)
        XCTAssertEqual(packet.direction, .outbound)
        XCTAssertEqual(packet.length, 1_420)
        XCTAssertEqual(packet.tcpFlags, [.syn, .ack])
        XCTAssertEqual(packet.capture, CaptureLocation(fileSequence: 4, recordOffset: 24))
        XCTAssertEqual(packet.date.timeIntervalSince(epoch), 3.0, accuracy: 1e-9)
        XCTAssertEqual(packet.remoteEndpoint, LiveFeedFixtures.remote)
    }

    /// Un paquete y su respuesta comparten flujo y host remoto pero no sentido. Es la prueba de que
    /// el reparto no se deduce del sentido (que sería circular) sino de la IP local.
    func testAPacketAndItsReplyShareTheHostButNotTheSense() {
        let anchor = MonotonicAnchor(uptimeNanoseconds: 0, wallClock: epoch)
        let out = LiveFeedFixtures.packed(timestamp: 1_000, direction: .outbound, length: 100)
        let back = LiveFeedFixtures.packed(timestamp: 2_000, direction: .inbound, length: 1_500)

        let sent = LivePacket(out, sequence: 1, anchor: anchor, localAddresses: TunnelAddressing.localAddresses)
        let received = LivePacket(back, sequence: 2, anchor: anchor, localAddresses: TunnelAddressing.localAddresses)

        XCTAssertEqual(sent.flowKey, received.flowKey)
        XCTAssertEqual(sent.remoteEndpoint, received.remoteEndpoint)
        XCTAssertEqual(sent.endpoints?.local, received.endpoints?.local)
        XCTAssertEqual(sent.direction, .outbound)
        XCTAssertEqual(received.direction, .inbound)
    }
}
