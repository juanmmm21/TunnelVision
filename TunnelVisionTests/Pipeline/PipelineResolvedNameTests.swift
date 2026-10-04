import Foundation
import XCTest
import Shared

/// Tests del enganche del mapa de nombres en el pipeline: una respuesta de DNS que llega al
/// dispositivo nombra los flujos que **después** van a la dirección que contestó.
///
/// El mapa tiene sus propios tests (`ResolvedNameMapTests`); aquí se afirma lo que es del pipeline:
/// qué datagramas se le dan, cuándo recibe nombre un flujo, que el nombre llega al store en su
/// campo y no en el del SNI, y que todo desenlace queda contado.
final class PipelineResolvedNameTests: XCTestCase {

    private struct Harness {
        let pipeline: PacketPipeline
        let store: RecordingStore
        let feed: RecordingLiveFeed
        let clock: ManualClock
    }

    private static let second: UInt64 = 1_000_000_000

    /// El resolutor: una dirección distinta de la del servidor al que van los flujos.
    private static let resolverBytes: [UInt8] = [10, 7, 0, 1]
    private static let remote = IPAddress(version: .v4, bytes: PipelineFixtures.remoteV4Bytes)

    private func makeHarness(
        limits: ResolvedNameLimits = .tunnel,
        localIPv6: IPAddress? = nil,
        idleTimeout: UInt64 = 120 * PipelineResolvedNameTests.second
    ) -> Harness {
        let clock = ManualClock(1_000)
        let table = FlowTable(config: .init(maxFlows: 4096, idleTimeout: idleTimeout), clock: clock)
        let feed = RecordingLiveFeed()
        let store = RecordingStore()
        let pipeline = PacketPipeline(
            flowTable: table,
            liveFeed: feed,
            capture: nil,
            store: store,
            clock: clock,
            config: .init(
                localIPv4: PipelineFixtures.localV4,
                localIPv6: localIPv6,
                batchSize: 1_000,
                flushInterval: .max,
                anchor: MonotonicAnchor(uptimeNanoseconds: 1_000, wallClock: Date(timeIntervalSince1970: 1_700_000_000)),
                resolvedNameLimits: limits
            )
        )
        return Harness(pipeline: pipeline, store: store, feed: feed, clock: clock)
    }

    /// Un datagrama UDP que **llega** al dispositivo desde el puerto 53 del resolutor.
    private func fromResolver(_ payload: Data, sourcePort: UInt16 = 53) -> Data {
        PacketFixtures.ipv4(
            proto: 17,
            source: Self.resolverBytes,
            destination: PipelineFixtures.localV4Bytes,
            payload: PacketFixtures.udpDatagram(
                sourcePort: sourcePort,
                destinationPort: 53535,
                payload: [UInt8](payload)
            )
        )
    }

    private func reply(
        _ name: String,
        addresses: [IPAddress] = [PipelineResolvedNameTests.remote],
        responseCode: DNSResponseCode = .noError,
        timeToLive: UInt32 = 300
    ) -> Data {
        DNSMessageFixture.reply(
            id: 0x1234,
            name: name,
            type: .a,
            answers: addresses.map { .address($0) },
            responseCode: responseCode,
            timeToLive: timeToLive
        )
    }

    private func handle(_ packet: Data, in h: Harness) async {
        await h.pipeline.handle(packet: packet, protocolFamily: Int32(AF_INET))
    }

    /// El flujo UDP/443 al servidor: lo que es QUIC en un teléfono, y lo que el SNI no alcanza.
    private func quic(localPort: UInt16 = 53535) -> Data {
        PipelineFixtures.udpV4(localPort: localPort, remotePort: 443)
    }

    private func storedRecord(_ key: FlowKey, in h: Harness) async -> FlowRecord? {
        await h.pipeline.flush()
        return await h.store.flows[key]
    }

    // MARK: - Lo que este incremento existe para hacer

    /// Una respuesta y después un flujo UDP/443 a esa dirección: sale nombrado, con origen `dns`.
    func testAFlowToAnAddressTheDNSAnsweredIsNamedByIt() async {
        let h = makeHarness()

        await handle(fromResolver(reply("api.example.com")), in: h)
        await handle(quic(), in: h)

        let record = await storedRecord(PipelineFixtures.udpV4Key(remotePort: 443), in: h)
        XCTAssertEqual(record?.resolvedName, ResolvedFlowName(name: "api.example.com", otherNames: []))
        XCTAssertEqual(record?.name?.origin, .dns)
        XCTAssertNil(record?.sni, "un nombre deducido del DNS no se escribe nunca donde el SNI")
    }

    /// Las respuestas llegan al dispositivo reinyectadas por el relay, que es el camino de verdad.
    func testAReinjectedReplyFeedsTheMapToo() async {
        let h = makeHarness()

        await h.pipeline.record(
            reinjected: fromResolver(reply("api.example.com")),
            protocolFamily: Int32(AF_INET)
        )
        await handle(quic(), in: h)

        let record = await storedRecord(PipelineFixtures.udpV4Key(remotePort: 443), in: h)
        XCTAssertEqual(record?.resolvedName?.name, "api.example.com")
    }

    func testATCPFlowIsNamedTooAndItsSNIStillWins() async {
        let h = makeHarness()
        let key = PipelineFixtures.tcpV4Key()

        await handle(fromResolver(reply("api.example.com")), in: h)
        await handle(PipelineFixtures.tcpV4(), in: h)
        await h.pipeline.observe(sni: "www.example.com", for: key)
        await handle(PipelineFixtures.tcpV4(payloadBytes: 8), in: h)

        let record = await storedRecord(key, in: h)
        XCTAssertEqual(record?.resolvedName?.name, "api.example.com", "el SNI no pisa lo que dijo el DNS")
        XCTAssertEqual(record?.sni, "www.example.com")
        XCTAssertEqual(record?.name, FlowName(text: "www.example.com", origin: .sni, otherCandidates: []))
    }

    func testAnIPv6FlowIsNamedFromAnAAAAReply() async {
        let h = makeHarness(localIPv6: PipelineFixtures.localV6)
        let remoteV6 = IPAddress(version: .v6, bytes: PipelineFixtures.remoteV6Bytes)

        await handle(fromResolver(reply("v6.example.com", addresses: [remoteV6])), in: h)
        await h.pipeline.handle(packet: PipelineFixtures.tcpV6(), protocolFamily: Int32(AF_INET6))
        await h.pipeline.flush()

        let flows = await h.store.flows
        let named = flows.values.first { $0.key.proto == .tcp }
        XCTAssertEqual(named?.resolvedName?.name, "v6.example.com")
    }

    // MARK: - Cuándo se nombra

    /// Un flujo se nombra al crearse. Uno que ya existía no adquiere nombre porque después pase la
    /// respuesta, y uno nuevo a la misma dirección sí lo recibe.
    func testAFlowThatPredatesTheReplyStaysUnnamedAndALaterOneIsNamed() async {
        let h = makeHarness()

        await handle(quic(localPort: 50001), in: h)
        await handle(fromResolver(reply("api.example.com")), in: h)
        await handle(quic(localPort: 50001), in: h)
        await handle(quic(localPort: 50002), in: h)
        await h.pipeline.flush()

        let flows = await h.store.flows
        XCTAssertNil(flows[PipelineFixtures.udpV4Key(localPort: 50001, remotePort: 443)]?.resolvedName)
        XCTAssertEqual(
            flows[PipelineFixtures.udpV4Key(localPort: 50002, remotePort: 443)]?.resolvedName?.name,
            "api.example.com"
        )
    }

    /// Y uno ya nombrado no cambia de nombre cuando la dirección pasa a tener otro más reciente.
    func testANamedFlowKeepsItsNameWhenTheAddressIsResolvedAgainForAnother() async {
        let h = makeHarness()
        let key = PipelineFixtures.udpV4Key(remotePort: 443)

        await handle(fromResolver(reply("first.example.com")), in: h)
        await handle(quic(), in: h)
        h.clock.advance(by: Self.second)
        await handle(fromResolver(reply("second.example.com")), in: h)
        await handle(quic(), in: h)

        let record = await storedRecord(key, in: h)
        XCTAssertEqual(record?.resolvedName, ResolvedFlowName(name: "first.example.com", otherNames: []))
    }

    /// Una dirección compartida: gana el nombre más reciente y los demás viajan hasta el store, que
    /// es lo que la allowlist necesitará para no dar por bueno al ganador sin mirar al resto.
    func testTheOtherNamesOfASharedAddressReachTheStore() async {
        let h = makeHarness()

        await handle(fromResolver(reply("older.example.com")), in: h)
        h.clock.advance(by: Self.second)
        await handle(fromResolver(reply("newer.example.com")), in: h)
        await handle(quic(), in: h)

        let record = await storedRecord(PipelineFixtures.udpV4Key(remotePort: 443), in: h)
        XCTAssertEqual(
            record?.resolvedName,
            ResolvedFlowName(name: "newer.example.com", otherNames: ["older.example.com"])
        )
    }

    /// El instante con el que se pregunta al mapa es el del paquete: un nombre caducado no nombra.
    func testAnExpiredAnswerNamesNothing() async {
        let limits = ResolvedNameLimits(capacity: 16, namesPerAddress: 4, minimumLifetime: 1, maximumLifetime: 3_600)
        let h = makeHarness(limits: limits)

        await handle(fromResolver(reply("api.example.com", timeToLive: 30)), in: h)
        h.clock.advance(by: 30 * Self.second)
        await handle(quic(), in: h)

        let record = await storedRecord(PipelineFixtures.udpV4Key(remotePort: 443), in: h)
        XCTAssertNotNil(record)
        XCTAssertNil(record?.resolvedName)
    }

    /// Los límites son los de la configuración: con sitio para un solo par, la segunda dirección
    /// desaloja a la primera.
    func testTheMapIsBoundedByTheConfiguredLimits() async {
        let limits = ResolvedNameLimits(capacity: 1, namesPerAddress: 1, minimumLifetime: 60, maximumLifetime: 3_600)
        let h = makeHarness(limits: limits)
        let other = IPAddress(version: .v4, bytes: [198, 51, 100, 7])

        await handle(fromResolver(reply("api.example.com")), in: h)
        h.clock.advance(by: Self.second)
        await handle(fromResolver(reply("other.example.com", addresses: [other])), in: h)
        await handle(quic(), in: h)

        let record = await storedRecord(PipelineFixtures.udpV4Key(remotePort: 443), in: h)
        XCTAssertNil(record?.resolvedName)
    }

    // MARK: - Qué se le da al mapa

    /// Lo que el dispositivo **manda** no nombra nada, aunque salga de su puerto 53 y lleve dentro
    /// una respuesta bien formada: solo cuenta lo que le llega.
    func testAnOutboundDatagramIsNeverReadAsAReply() async {
        let h = makeHarness()
        let outbound = PacketFixtures.ipv4(
            proto: 17,
            source: PipelineFixtures.localV4Bytes,
            destination: Self.resolverBytes,
            payload: PacketFixtures.udpDatagram(
                sourcePort: 53,
                destinationPort: 53,
                payload: [UInt8](reply("api.example.com"))
            )
        )

        await handle(outbound, in: h)
        await handle(quic(), in: h)

        let record = await storedRecord(PipelineFixtures.udpV4Key(remotePort: 443), in: h)
        XCTAssertNil(record?.resolvedName)
        let stats = await h.pipeline.stats
        XCTAssertEqual(stats.dnsNames, DNSNameStats())
    }

    /// Ni lo que llega de otro puerto, por mucho que sea un mensaje de DNS.
    func testAnInboundDatagramFromAnotherPortIsNotRead() async {
        let h = makeHarness()

        await handle(fromResolver(reply("api.example.com"), sourcePort: 5353), in: h)
        await handle(quic(), in: h)

        let record = await storedRecord(PipelineFixtures.udpV4Key(remotePort: 443), in: h)
        XCTAssertNil(record?.resolvedName)
        let stats = await h.pipeline.stats
        XCTAssertEqual(stats.dnsNames, DNSNameStats())
    }

    // MARK: - Lo que se cuenta

    func testARecordedReplyAndTheFlowItNamesAreCounted() async {
        let h = makeHarness()
        let second = IPAddress(version: .v4, bytes: [198, 51, 100, 7])

        await handle(fromResolver(reply("api.example.com", addresses: [Self.remote, second])), in: h)
        await handle(quic(), in: h)
        await handle(quic(), in: h)

        let stats = await h.pipeline.stats.dnsNames
        XCTAssertEqual(stats.repliesRecorded, 1)
        XCTAssertEqual(stats.addressesRecorded, 2)
        XCTAssertEqual(stats.flowsNamed, 1, "un flujo se cuenta al nacer, no en cada paquete")
        XCTAssertEqual(stats.repliesIgnored, 0)
        XCTAssertEqual(stats.unreadable, 0)
    }

    /// Un NXDOMAIN se cuenta por su motivo y no nombra nada.
    func testAnErrorReplyIsCountedByItsReason() async {
        let h = makeHarness()

        await handle(fromResolver(reply("gone.example.com", addresses: [], responseCode: .nonExistentDomain)), in: h)

        let stats = await h.pipeline.stats.dnsNames
        XCTAssertEqual(stats.errorResponses, 1)
        XCTAssertEqual(stats.repliesRecorded, 0)
    }

    /// Lo que llega del 53 y no se deja leer se cuenta, y **el datagrama se registra igual**: que el
    /// mapa no saque nada de él no le quita su sitio en el historial.
    func testAnUnreadableMessageIsCountedAndThePacketIsStillRecorded() async {
        let h = makeHarness()
        let key = FlowKey(
            proto: .udp,
            source: IPEndpoint(address: IPAddress(version: .v4, bytes: Self.resolverBytes), port: 53),
            destination: IPEndpoint(address: PipelineFixtures.localV4, port: 53535)
        )

        await handle(fromResolver(Data([0xDE, 0xAD, 0xBE])), in: h)

        let pipelineStats = await h.pipeline.stats
        XCTAssertEqual(pipelineStats.dnsNames.unreadable, 1)
        XCTAssertEqual(pipelineStats.packetsHandled, 1)
        XCTAssertEqual(pipelineStats.packetsDropped, 0)
        XCTAssertEqual(h.feed.metas.count, 1)
        let record = await storedRecord(key, in: h)
        XCTAssertEqual(record?.packetCount, 1)
    }

    /// Sin DNS en claro —DoH, DoT, Private Relay— no pasa nada por el 53: los flujos salen sin
    /// nombre y los contadores dicen por qué, que es todos a cero.
    func testWithoutAnyDNSFlowsAreUnnamedAndEveryCounterStaysAtZero() async {
        let h = makeHarness()

        await handle(quic(), in: h)
        await handle(PipelineFixtures.tcpV4(), in: h)
        await h.pipeline.flush()

        let flows = await h.store.flows
        XCTAssertEqual(flows.count, 2)
        XCTAssertTrue(flows.values.allSatisfy { $0.resolvedName == nil })
        let stats = await h.pipeline.stats
        XCTAssertEqual(stats.dnsNames, DNSNameStats())
    }
}
