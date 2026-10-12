import Foundation
import XCTest
import Shared

/// Tests del enganche del nombre de QUIC en el pipeline: los Initial que el dispositivo manda al
/// 443 por UDP le ponen nombre a su flujo.
///
/// El lector tiene sus propios tests (`QUICClientHelloReaderTests`); aquí se afirma lo que es del
/// pipeline: qué datagramas se le dan, dónde acaban el nombre y la oferta, cuándo se suelta lo
/// que se guardaba, el cupo de lecturas a la vez y que todo desenlace queda contado.
final class PipelineQUICNameTests: XCTestCase {

    private struct Harness {
        let pipeline: PacketPipeline
        let store: RecordingStore
        let clock: ManualClock
    }

    private static let second: UInt64 = 1_000_000_000
    private static let host = "quic.example.org"
    private static let connectionID: [UInt8] = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]

    private func makeHarness(
        limits: QUICNameReadLimits = .tunnel,
        maxFlows: Int = 4096,
        idleTimeout: UInt64 = 120 * PipelineQUICNameTests.second
    ) -> Harness {
        let clock = ManualClock(1_000)
        let table = FlowTable(config: .init(maxFlows: maxFlows, idleTimeout: idleTimeout), clock: clock)
        let store = RecordingStore()
        let pipeline = PacketPipeline(
            flowTable: table,
            liveFeed: RecordingLiveFeed(),
            capture: nil,
            store: store,
            clock: clock,
            config: .init(
                localIPv4: PipelineFixtures.localV4,
                batchSize: 1_000,
                flushInterval: .max,
                anchor: MonotonicAnchor(uptimeNanoseconds: 1_000, wallClock: Date(timeIntervalSince1970: 1_700_000_000)),
                quicNameLimits: limits
            )
        )
        return Harness(pipeline: pipeline, store: store, clock: clock)
    }

    private func key(localPort: UInt16 = 53535, remotePort: UInt16 = 443) -> FlowKey {
        PipelineFixtures.udpV4Key(localPort: localPort, remotePort: remotePort)
    }

    private func send(
        _ payload: [UInt8], through h: Harness, localPort: UInt16 = 53535, remotePort: UInt16 = 443
    ) async {
        await h.pipeline.handle(
            packet: PipelineFixtures.udpV4(outbound: true, localPort: localPort, remotePort: remotePort, payload: payload),
            protocolFamily: Int32(AF_INET)
        )
    }

    private func hello(host: String?) -> [UInt8] {
        var extensions: [ClientHelloFixtures.Extension] = [.supportedVersions, .applicationProtocols(["h3"])]
        if let host { extensions.insert(.serverName(host), at: 0) }
        return ClientHelloFixtures.handshakeMessage(body: ClientHelloFixtures.clientHelloBody(extensions: extensions))
    }

    /// Los Initial protegidos de verdad que reparten `message` en `pieces` trozos, uno por
    /// datagrama.
    private func initials(
        carrying message: [UInt8], pieces: Int = 2, connectionID: [UInt8] = PipelineQUICNameTests.connectionID
    ) throws -> [[UInt8]] {
        let size = (message.count + pieces - 1) / pieces
        return try (0..<pieces).map { index in
            let range = (index * size)..<min(message.count, (index + 1) * size)
            return try QUICFixtures.clientInitial(
                keysFrom: connectionID, destinationID: connectionID,
                packetNumber: UInt64(index), packetNumberLength: 1,
                frames: QUICFixtures.cryptoFrame(offset: range.lowerBound, data: Array(message[range]))
                    + [UInt8](repeating: 0, count: 300)
            )
        }
    }

    // MARK: - Clientes de verdad, de punta a punta

    /// Lo que motiva el paso: los datagramas de un cliente de verdad pasan por el pipeline y su
    /// flujo llega al historial con el nombre en `sni`, la oferta, cifrado y con su versión.
    func testTheDatagramsOfRealClientsNameTheirFlow() async {
        let captures = [
            (QUICClientCaptures.appleNetworkFramework, QUICClientCaptures.appleHost),
            (QUICClientCaptures.chrome, QUICClientCaptures.chromeHost),
        ]
        for (capture, host) in captures {
            let h = makeHarness()
            for datagram in capture {
                await send(datagram, through: h)
            }
            await h.pipeline.flush()

            let record = await h.store.flows[key()]
            XCTAssertEqual(record?.sni, host)
            XCTAssertEqual(record?.clientTLS?.versions, .listed([.tls13]), host)
            XCTAssertEqual(record?.clientTLS?.applicationProtocols, ["h3"], host)
            XCTAssertEqual(record?.tlsStatus, .encrypted, host)
            XCTAssertEqual(record?.quic, QUICVersionReading(version: .v1, source: .client), host)

            // Dos Initial abiertos, que son los que hacen falta; las retransmisiones ni se miran.
            var expected = QUICNameStats()
            expected.initialsOpened = 2
            expected.flowsNamed = 1
            let stats = await h.pipeline.stats
            XCTAssertEqual(stats.quicNames, expected, host)
            XCTAssertEqual(stats.quicVersionsObserved, UInt64(capture.count), host)
            let open = await h.pipeline.openQUICNameReadCount
            XCTAssertEqual(open, 0, host)
        }
    }

    /// El record que manda al historial **el paquete que completa el ClientHello** ya lleva el
    /// nombre: no hace falta que pase otro paquete del flujo.
    func testTheNameTravelsWithThePacketThatCompletesTheClientHello() async throws {
        let h = makeHarness()
        let datagrams = try initials(carrying: hello(host: Self.host))

        await send(datagrams[0], through: h)
        await h.pipeline.flush()
        var record = await h.store.flows[key()]
        XCTAssertNil(record?.sni)
        XCTAssertNil(record?.clientTLS)
        var open = await h.pipeline.openQUICNameReadCount
        XCTAssertEqual(open, 1)

        await send(datagrams[1], through: h)
        await h.pipeline.flush()
        record = await h.store.flows[key()]
        XCTAssertEqual(record?.sni, Self.host)
        XCTAssertEqual(record?.packetCount, 2)
        open = await h.pipeline.openQUICNameReadCount
        XCTAssertEqual(open, 0)
    }

    /// El nombre anunciado va en `sni` y gana al que el DNS le había dado a la dirección, que
    /// sigue en su campo: son dos hechos distintos y el flujo conserva los dos.
    func testTheAnnouncedNameWinsOverTheResolvedOneAndBothAreKept() async throws {
        let h = makeHarness()
        let reply = DNSMessageFixture.reply(
            id: 0x1234,
            name: "cdn.example.net",
            type: .a,
            answers: [.address(IPAddress(version: .v4, bytes: PipelineFixtures.remoteV4Bytes))]
        )
        await h.pipeline.record(
            reinjected: PacketFixtures.ipv4(
                proto: 17,
                source: [10, 7, 0, 1],
                destination: PipelineFixtures.localV4Bytes,
                payload: PacketFixtures.udpDatagram(sourcePort: 53, destinationPort: 50000, payload: [UInt8](reply))
            ),
            protocolFamily: Int32(AF_INET)
        )

        for datagram in try initials(carrying: hello(host: Self.host)) {
            await send(datagram, through: h)
        }
        await h.pipeline.flush()

        let stored = await h.store.flows[key()]
        let record = try XCTUnwrap(stored)
        XCTAssertEqual(record.resolvedName?.name, "cdn.example.net")
        XCTAssertEqual(record.sni, Self.host)
        let name = FlowName(sni: record.sni, resolved: record.resolvedName)
        XCTAssertEqual(name?.text, Self.host)
        XCTAssertEqual(name?.origin, .sni)
    }

    // MARK: - Desenlaces sin nombre

    /// Sin extensión de nombre no hay `sni`, y la oferta se guarda igual: es lo que deja decir
    /// «no anunciaba ninguno» en vez de «no se leyó».
    func testAClientHelloWithoutServerNameLeavesTheOfferAndIsCounted() async throws {
        let h = makeHarness()
        for datagram in try initials(carrying: hello(host: nil)) {
            await send(datagram, through: h)
        }
        await h.pipeline.flush()

        let record = await h.store.flows[key()]
        XCTAssertNil(record?.sni)
        XCTAssertEqual(record?.clientTLS?.applicationProtocols, ["h3"])
        var expected = QUICNameStats()
        expected.initialsOpened = 2
        expected.withoutServerName = 1
        let stats = await h.pipeline.stats.quicNames
        XCTAssertEqual(stats, expected)
    }

    /// Cada forma de quedarse sin nombre tiene su contador, y ninguna deja una lectura abierta.
    func testEveryWayOfEndingWithoutANameHasItsCounter() async throws {
        let message = hello(host: Self.host)
        let notAClientHello = ClientHelloFixtures.handshakeMessage(
            type: ClientHelloFixtures.serverHelloMessageType, body: [UInt8](repeating: 0, count: 40)
        )
        let perFlow = QUICClientHelloReader.Limits.tunnel
        let cases: [(String, QUICClientHelloReader.Limits, [UInt8], Int, KeyPath<QUICNameStats, UInt64>)] = [
            ("no es un ClientHello", perFlow, notAClientHello, 1, \.unreadableClientHello),
            (
                "no cabe en el stream",
                .init(maxInitialPackets: 8, stream: .init(maxStreamBytes: 30, maxPendingFragments: 32), maxHandshakeBytes: 8_192),
                message, 1, \.cryptoStreamAbandoned
            ),
            (
                "se agotan los Initial",
                .init(maxInitialPackets: 2, stream: perFlow.stream, maxHandshakeBytes: 8_192),
                message, 3, \.initialsExhausted
            ),
        ]
        for (label, limits, bytes, pieces, counter) in cases {
            let h = makeHarness(limits: .init(perFlow: limits, maxConcurrentReads: 64))
            for datagram in try initials(carrying: bytes, pieces: pieces) {
                await send(datagram, through: h)
            }
            await h.pipeline.flush()

            let record = await h.store.flows[key()]
            XCTAssertNil(record?.sni, label)
            let stats = await h.pipeline.stats.quicNames
            XCTAssertEqual(stats[keyPath: counter], 1, label)
            XCTAssertEqual(stats.flowsLeftUnnamed, 1, label)
            XCTAssertEqual(stats.flowsNamed, 0, label)
            let open = await h.pipeline.openQUICNameReadCount
            XCTAssertEqual(open, 0, label)
        }
    }

    /// Un Initial alterado por el camino se cuenta como no abierto, y tras un Retry la lectura
    /// vuelve a empezar: las dos cifras llegan a los contadores.
    func testUnopenedInitialsAndRestartsAreCounted() async throws {
        let h = makeHarness()
        let message = hello(host: Self.host)
        let retryID: [UInt8] = [0xB1, 0xB2, 0xB3, 0xB4]

        var corrupted = try initials(carrying: message)[0]
        corrupted[corrupted.count - 1] ^= 0xFF
        await send(try initials(carrying: message)[0], through: h)
        await send(corrupted, through: h)
        for datagram in try initials(carrying: message, connectionID: retryID) {
            await send(datagram, through: h)
        }
        await h.pipeline.flush()

        var expected = QUICNameStats()
        expected.initialsOpened = 3
        expected.initialsNotOpened = 1
        expected.readsRestarted = 1
        expected.flowsNamed = 1
        let stats = await h.pipeline.stats.quicNames
        XCTAssertEqual(stats, expected)
        let record = await h.store.flows[key()]
        XCTAssertEqual(record?.sni, Self.host)
    }

    // MARK: - Qué datagramas se miran

    /// Solo lo que **sale**: un Initial que llega —reinyectado— no es del cliente y no se abre.
    func testInboundInitialsAreNotRead() async {
        let h = makeHarness()
        for datagram in QUICClientCaptures.appleNetworkFramework {
            await h.pipeline.record(
                reinjected: PipelineFixtures.udpV4(outbound: false, payload: datagram),
                protocolFamily: Int32(AF_INET)
            )
        }
        await h.pipeline.flush()

        let record = await h.store.flows[key()]
        XCTAssertNil(record?.sni)
        let stats = await h.pipeline.stats
        XCTAssertEqual(stats.quicNames, QUICNameStats())
        XCTAssertEqual(stats.quicVersionsObserved, 3)
    }

    /// Fuera del 443 remoto no se mira, igual que la versión.
    func testInitialsToAnotherPortAreNotRead() async {
        let h = makeHarness()
        for datagram in QUICClientCaptures.appleNetworkFramework {
            await send(datagram, through: h, remotePort: 8443)
        }
        await h.pipeline.flush()

        let record = await h.store.flows[key(remotePort: 8443)]
        XCTAssertNil(record?.sni)
        let stats = await h.pipeline.stats.quicNames
        XCTAssertEqual(stats, QUICNameStats())
    }

    /// Lo que no es un Initial —cabecera corta, Handshake, otra versión, UDP que no es QUIC— no
    /// abre una lectura ni cuenta nada.
    func testDatagramsThatAreNotInitialsOpenNoRead() async {
        let h = makeHarness()
        let payloads: [[UInt8]] = [
            QUICFixtures.shortHeader(),
            QUICFixtures.longHeader(version: 1, firstByte: 0xE0, trailing: 80),
            QUICFixtures.longHeader(version: 0xff00_001d, trailing: 80),
            [0x16, 0xFE, 0xFD, 0x00, 0x00, 0x00, 0x00, 0x00],
        ]
        for payload in payloads {
            await send(payload, through: h)
        }

        let stats = await h.pipeline.stats.quicNames
        XCTAssertEqual(stats, QUICNameStats())
        let open = await h.pipeline.openQUICNameReadCount
        XCTAssertEqual(open, 0)
    }

    // MARK: - El cupo de lecturas a la vez

    /// Con el cupo lleno el Initial de otro flujo no se mira y se cuenta; cuando queda sitio, su
    /// retransmisión sí.
    func testAFullQuotaSkipsNewFlowsUntilThereIsRoom() async throws {
        let h = makeHarness(limits: .init(perFlow: .tunnel, maxConcurrentReads: 1))
        let first = try initials(carrying: hello(host: "first.example.org"))
        let second = try initials(
            carrying: hello(host: "second.example.org"), connectionID: [0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28]
        )

        await send(first[0], through: h)
        await send(second[0], through: h, localPort: 53536)
        // Lo que no tiene forma de Initial no cuenta como lectura perdida.
        await send(QUICFixtures.longHeader(version: 1, firstByte: 0xE0, trailing: 80), through: h, localPort: 53536)
        var stats = await h.pipeline.stats.quicNames
        XCTAssertEqual(stats.initialsSkippedAtCapacity, 1)
        XCTAssertEqual(stats.initialsOpened, 1)

        await send(first[1], through: h)
        for datagram in second {
            await send(datagram, through: h, localPort: 53536)
        }
        await h.pipeline.flush()

        let firstRecord = await h.store.flows[key()]
        let secondRecord = await h.store.flows[key(localPort: 53536)]
        XCTAssertEqual(firstRecord?.sni, "first.example.org")
        XCTAssertEqual(secondRecord?.sni, "second.example.org")
        stats = await h.pipeline.stats.quicNames
        XCTAssertEqual(stats.initialsSkippedAtCapacity, 1)
        XCTAssertEqual(stats.flowsNamed, 2)
    }

    /// Un flujo ya decidido no ocupa sitio: el cupo es de lecturas a medias.
    func testSettledFlowsDoNotCountAgainstTheQuota() async throws {
        let h = makeHarness(limits: .init(perFlow: .tunnel, maxConcurrentReads: 1))
        for port in UInt16(53535)...53540 {
            for datagram in try initials(carrying: hello(host: Self.host)) {
                await send(datagram, through: h, localPort: port)
            }
        }
        let stats = await h.pipeline.stats.quicNames
        XCTAssertEqual(stats.flowsNamed, 6)
        XCTAssertEqual(stats.initialsSkippedAtCapacity, 0)
    }

    // MARK: - Lo que se suelta, y cuándo

    /// Un flujo que se cierra con la lectura a medias la suelta: su sitio en el cupo vuelve.
    func testAFlowThatClosesMidReadReleasesIt() async throws {
        let h = makeHarness(idleTimeout: 10 * Self.second)
        await send(try initials(carrying: hello(host: Self.host))[0], through: h)
        var open = await h.pipeline.openQUICNameReadCount
        XCTAssertEqual(open, 1)

        h.clock.advance(by: 11 * Self.second)
        await h.pipeline.tick()
        open = await h.pipeline.openQUICNameReadCount
        XCTAssertEqual(open, 0)
    }

    /// Una clave se recicla: el flujo que nace después con el mismo par de puertos se lee de
    /// nuevo, aunque el anterior ya estuviera decidido.
    func testAFlowBornLaterUnderTheSameKeyIsReadAgain() async throws {
        let h = makeHarness(idleTimeout: 10 * Self.second)
        for datagram in try initials(carrying: hello(host: "earlier.example.org")) {
            await send(datagram, through: h)
        }
        h.clock.advance(by: 11 * Self.second)
        await h.pipeline.tick()

        for datagram in try initials(carrying: hello(host: "later.example.org")) {
            await send(datagram, through: h)
        }
        await h.pipeline.flush()

        let record = await h.store.flows[key()]
        XCTAssertEqual(record?.sni, "later.example.org")
        let stats = await h.pipeline.stats.quicNames
        XCTAssertEqual(stats.flowsNamed, 2)
    }

    /// El caso retorcido del reciclado: la tabla desaloja el flujo, nace otro con su misma clave
    /// **antes del volcado** y el record de cierre del viejo llega después. Lo decidido para el
    /// viejo no tapa la lectura del nuevo, y su cierre tardío no se la lleva por delante.
    func testALateCloseOfAnEarlierLifeDoesNotDisturbTheReadOfTheNewOne() async throws {
        let h = makeHarness(maxFlows: 1)
        for datagram in try initials(carrying: hello(host: "earlier.example.org")) {
            await send(datagram, through: h)
        }
        // Otro flujo desaloja al primero, que queda cerrado y sin volcar.
        await send(QUICFixtures.shortHeader(), through: h, localPort: 40000)
        h.clock.advance(by: Self.second)

        let later = try initials(carrying: hello(host: "later.example.org"))
        await send(later[0], through: h)
        var open = await h.pipeline.openQUICNameReadCount
        XCTAssertEqual(open, 1, "el flujo nuevo no hereda el «ya decidido» del anterior")

        await h.pipeline.flush()
        open = await h.pipeline.openQUICNameReadCount
        XCTAssertEqual(open, 1, "el cierre del flujo anterior no suelta la lectura del nuevo")

        await send(later[1], through: h)
        await h.pipeline.flush()
        let record = await h.store.flows[key()]
        XCTAssertEqual(record?.sni, "later.example.org")
    }

    // MARK: - Los topes del túnel

    func testTheTunnelLimitsAreNamedValues() {
        XCTAssertEqual(QUICNameReadLimits.tunnel.perFlow, .tunnel)
        XCTAssertEqual(QUICNameReadLimits.tunnel.maxConcurrentReads, 64)
        // El peor caso que el cupo admite, que es lo que justifica su valor: 1 MB.
        let perFlow = QUICNameReadLimits.tunnel.perFlow
        XCTAssertEqual(
            QUICNameReadLimits.tunnel.maxConcurrentReads * (perFlow.stream.maxStreamBytes + perFlow.maxHandshakeBytes),
            1_048_576
        )
    }
}
