import Foundation
import XCTest
import Shared

/// Tests del relay (M8, passthrough UDP). Cubren: la apertura de conexión y el envío del payload
/// saliente, la reinyección de la respuesta como datagrama en sentido invertido (v4 y v6), la
/// reutilización de una conexión por flujo, el aislamiento entre flujos, el cierre explícito y el
/// iniciado por el servidor, el descarte de respuestas tras el cierre, el conteo de paquetes no-UDP
/// como no soportados y la degradación acotada ante un payload que no cabe en un datagrama.
final class RelayTests: XCTestCase {

    private struct Harness {
        let relay: Relay
        let factory: FakeConnectionFactory
        let reinjector: RecordingReinjector
    }

    private func makeHarness() -> Harness {
        let factory = FakeConnectionFactory()
        let reinjector = RecordingReinjector()
        let relay = Relay(
            reinject: { datagrams, families in
                for (datagram, family) in zip(datagrams, families) {
                    let fam = family.int32Value
                    Task { await reinjector.record(datagram: datagram, family: fam) }
                }
            },
            connectionFactory: factory
        )
        return Harness(relay: relay, factory: factory, reinjector: reinjector)
    }

    /// Espera activa acotada para las aserciones sobre efectos que ocurren en una tarea de fondo
    /// (recepción/cierre disparados por el servidor). Los caminos con reinyección usan `next()`, que
    /// es determinista; esto es solo para los caminos que NO reinyectan.
    private func waitUntil(_ predicate: @escaping () async -> Bool) async -> Bool {
        for _ in 0..<10_000 {
            if await predicate() { return true }
            await Task.yield()
        }
        return false
    }

    // MARK: - Salida

    func testUDPOutboundOpensConnectionAndSendsPayload() async {
        let h = makeHarness()
        let (packet, raw) = RelayFixtures.udpV4(payload: [0xDE, 0xAD, 0xBE, 0xEF])

        await h.relay.passthrough(packet, raw: raw)

        XCTAssertEqual(h.factory.connections.count, 1)
        XCTAssertEqual(h.factory.connections[0].sentPayloads, [Data([0xDE, 0xAD, 0xBE, 0xEF])])
        XCTAssertEqual(h.factory.endpoints[0], RelayFixtures.remoteV4Endpoint(port: 53))

        let active = await h.relay.activeFlowCount
        XCTAssertEqual(active, 1)
        let stats = await h.relay.stats
        XCTAssertEqual(stats.udpFlowsOpened, 1)
        XCTAssertEqual(stats.datagramsSentOutbound, 1)
    }

    // MARK: - El par que dice si hay resolución de nombres

    /// Las consultas de DNS se cuentan aparte de los demás datagramas, y con ellas sus respuestas.
    ///
    /// El par **es** el dato: consultas saliendo y ni una respuesta es la firma de un resolver
    /// anunciado que no está ahí —a donde lleva un cambio de red, porque los resolvers se leen una
    /// sola vez al arrancar— y es lo único medible de la avería que el usuario vive como páginas que
    /// no cargan.
    func testDNSQueriesAndTheirRepliesAreCountedAsAPair() async {
        let h = makeHarness()
        let (query, raw) = RelayFixtures.udpV4(localPort: 53535, remotePort: 53, payload: [0x00, 0x01])

        await h.relay.passthrough(query, raw: raw)
        var stats = await h.relay.stats
        XCTAssertEqual(stats.dnsQueriesSent, 1)
        XCTAssertEqual(stats.dnsRepliesReceived, 0, "la respuesta no ha llegado todavía")

        h.factory.connections[0].fireReceive(Data([0x00, 0x01, 0x81, 0x80]))
        _ = await h.reinjector.next()

        stats = await h.relay.stats
        XCTAssertEqual(stats.dnsQueriesSent, 1)
        XCTAssertEqual(stats.dnsRepliesReceived, 1)
    }

    /// Y lo que no es DNS no entra en ese par: si contase cualquier UDP, un teléfono con QUIC
    /// funcionando taparía para siempre un DNS que no contesta.
    func testOtherUDPTrafficIsNotCountedAsNameResolution() async {
        let h = makeHarness()
        let (packet, raw) = RelayFixtures.udpV4(localPort: 40001, remotePort: 443, payload: [0x01])

        await h.relay.passthrough(packet, raw: raw)
        h.factory.connections[0].fireReceive(Data([0x02]))
        _ = await h.reinjector.next()

        let stats = await h.relay.stats
        XCTAssertEqual(stats.dnsQueriesSent, 0)
        XCTAssertEqual(stats.dnsRepliesReceived, 0)
        XCTAssertEqual(stats.datagramsSentOutbound, 1, "sigue contando como datagrama, solo que no como DNS")
    }

    // MARK: - Respuesta del servidor

    func testServerReplyIsReinjectedAsSwappedDatagram() async throws {
        let h = makeHarness()
        let (packet, raw) = RelayFixtures.udpV4(localPort: 53535, remotePort: 53, payload: [0x00])

        await h.relay.passthrough(packet, raw: raw)
        h.factory.connections[0].fireReceive(Data([0x11, 0x22, 0x33]))

        let injected = await h.reinjector.next()
        XCTAssertEqual(injected.family, Int32(AF_INET))

        // El datagrama reinyectado se parsea de vuelta: origen = servidor, destino = dispositivo,
        // y el payload es el de la respuesta.
        let parsed = try PacketParser.parse(injected.datagram, protocolFamily: Int32(AF_INET))
        XCTAssertEqual(parsed.source, RelayFixtures.remoteV4Endpoint(port: 53))
        XCTAssertEqual(parsed.destination, RelayFixtures.localV4Endpoint(port: 53535))
        let udp = try XCTUnwrap(parsed.udp)
        XCTAssertEqual(Data(injected.datagram[udp.payloadRange]), Data([0x11, 0x22, 0x33]))
        // Mismo flujo canónico que el paquete saliente: es la misma conversación.
        XCTAssertEqual(parsed.flowKey, packet.flowKey)

        let stats = await h.relay.stats
        XCTAssertEqual(stats.datagramsReinjected, 1)
    }

    func testIPv6UDPPassthroughRoundTrips() async throws {
        let h = makeHarness()
        let (packet, raw) = RelayFixtures.udpV6(payload: [0x09])

        await h.relay.passthrough(packet, raw: raw)
        XCTAssertEqual(h.factory.connections[0].sentPayloads, [Data([0x09])])

        h.factory.connections[0].fireReceive(Data([0xFF, 0xEE]))
        let injected = await h.reinjector.next()
        XCTAssertEqual(injected.family, Int32(AF_INET6))

        let parsed = try PacketParser.parse(injected.datagram, protocolFamily: Int32(AF_INET6))
        XCTAssertEqual(parsed.ip.version, .v6)
        XCTAssertEqual(parsed.flowKey, packet.flowKey)
        let udp = try XCTUnwrap(parsed.udp)
        XCTAssertEqual(Data(injected.datagram[udp.payloadRange]), Data([0xFF, 0xEE]))
    }

    // MARK: - Reutilización y aislamiento de conexiones

    func testSameFlowReusesOneConnection() async {
        let h = makeHarness()
        let (packet, raw) = RelayFixtures.udpV4()

        await h.relay.passthrough(packet, raw: raw)
        await h.relay.passthrough(packet, raw: raw)

        XCTAssertEqual(h.factory.connections.count, 1)                 // una sola conexión
        XCTAssertEqual(h.factory.connections[0].sentPayloads.count, 2) // dos envíos por ella
        let active = await h.relay.activeFlowCount
        XCTAssertEqual(active, 1)
        let stats = await h.relay.stats
        XCTAssertEqual(stats.udpFlowsOpened, 1)
        XCTAssertEqual(stats.datagramsSentOutbound, 2)
    }

    func testDistinctFlowsGetDistinctConnections() async {
        let h = makeHarness()
        let (a, aRaw) = RelayFixtures.udpV4(localPort: 40000)
        let (b, bRaw) = RelayFixtures.udpV4(localPort: 40001)

        await h.relay.passthrough(a, raw: aRaw)
        await h.relay.passthrough(b, raw: bRaw)

        XCTAssertEqual(h.factory.connections.count, 2)
        let active = await h.relay.activeFlowCount
        XCTAssertEqual(active, 2)
        let stats = await h.relay.stats
        XCTAssertEqual(stats.udpFlowsOpened, 2)
    }

    // MARK: - Cierre

    func testCloseCancelsAndForgetsTheConnection() async {
        let h = makeHarness()
        let (packet, raw) = RelayFixtures.udpV4()

        await h.relay.passthrough(packet, raw: raw)
        await h.relay.close(packet.flowKey)

        XCTAssertTrue(h.factory.connections[0].isCancelled)
        let active = await h.relay.activeFlowCount
        XCTAssertEqual(active, 0)
    }

    /// Una respuesta que llega después de cerrar el flujo no se reinyecta: la conexión ya no existe.
    func testReplyAfterCloseIsDropped() async {
        let h = makeHarness()
        let (packet, raw) = RelayFixtures.udpV4()

        await h.relay.passthrough(packet, raw: raw)
        await h.relay.close(packet.flowKey)
        h.factory.connections[0].fireReceive(Data([0x01]))

        // Nada que reinyectar y ningún fallo del emisor: la respuesta se descarta en silencio.
        let quiet = await waitUntil {
            let stats = await h.relay.stats
            let pending = await h.reinjector.count
            return stats.datagramsReinjected == 0 && stats.emitterFailures == 0 && pending == 0
        }
        XCTAssertTrue(quiet)
    }

    func testServerInitiatedFailureFreesTheFlowAndIsCounted() async {
        let h = makeHarness()
        let (packet, raw) = RelayFixtures.udpV4()

        await h.relay.passthrough(packet, raw: raw)
        h.factory.connections[0].fireClose(RelayConnectionError("connection reset"))

        let freed = await waitUntil {
            let active = await h.relay.activeFlowCount
            return active == 0
        }
        XCTAssertTrue(freed)
        let stats = await h.relay.stats
        XCTAssertEqual(stats.connectionsClosed, 1)
        XCTAssertEqual(stats.connectionFailures, 1)
    }

    func testCleanServerCloseIsNotCountedAsFailure() async {
        let h = makeHarness()
        let (packet, raw) = RelayFixtures.udpV4()

        await h.relay.passthrough(packet, raw: raw)
        h.factory.connections[0].fireClose(nil)

        let freed = await waitUntil {
            let active = await h.relay.activeFlowCount
            return active == 0
        }
        XCTAssertTrue(freed)
        let stats = await h.relay.stats
        XCTAssertEqual(stats.connectionsClosed, 1)
        XCTAssertEqual(stats.connectionFailures, 0)
    }

    func testCloseAllCancelsEveryConnection() async {
        let h = makeHarness()
        let (a, aRaw) = RelayFixtures.udpV4(localPort: 40000)
        let (b, bRaw) = RelayFixtures.udpV4(localPort: 40001)

        await h.relay.passthrough(a, raw: aRaw)
        await h.relay.passthrough(b, raw: bRaw)
        await h.relay.closeAll()

        XCTAssertTrue(h.factory.connections.allSatisfy(\.isCancelled))
        let active = await h.relay.activeFlowCount
        XCTAssertEqual(active, 0)
    }

    // MARK: - Fuera de alcance y degradación

    func testUnsupportedProtocolIsCountedAndNotRelayed() async {
        let h = makeHarness()
        let (packet, raw) = RelayFixtures.icmpV4()   // ICMP: ni TCP ni UDP

        await h.relay.passthrough(packet, raw: raw)

        XCTAssertEqual(h.factory.connections.count, 0)
        let active = await h.relay.activeFlowCount
        XCTAssertEqual(active, 0)
        let stats = await h.relay.stats
        XCTAssertEqual(stats.unsupportedPackets, 1)
        XCTAssertEqual(stats.datagramsSentOutbound, 0)
    }

    /// Una respuesta que no cabe en un datagrama UDP (payload > 65527 B) no puede tumbar el relay: se
    /// cuenta como fallo del emisor y esa respuesta se pierde, sin reinyectar nada.
    func testOversizeReplyIsCountedAndDropped() async {
        let h = makeHarness()
        let (packet, raw) = RelayFixtures.udpV4()

        await h.relay.passthrough(packet, raw: raw)
        h.factory.connections[0].fireReceive(Data(repeating: 0x41, count: 65_528))

        let counted = await waitUntil {
            let stats = await h.relay.stats
            return stats.emitterFailures == 1
        }
        XCTAssertTrue(counted)
        let stats = await h.relay.stats
        XCTAssertEqual(stats.datagramsReinjected, 0)
        // El flujo sigue vivo: un datagrama imposible no cierra la conexión.
        let active = await h.relay.activeFlowCount
        XCTAssertEqual(active, 1)
    }
}
