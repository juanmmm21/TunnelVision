import Foundation
import XCTest
import Shared

/// Tests de la lectura de la **oferta del cliente** dentro del `Relay`. El parser tiene los suyos
/// (`ClientHelloOfferTests`); aquí se prueba lo que solo el relay puede contestar: que la oferta
/// sale por su costura con cualquier desenlace del nombre —también sin nombre, que es el flujo del
/// que no hay otra cosa que citar—, que basta su observador para que el handshake se lea, y que
/// sale una sola vez.
final class RelayClientOfferTests: XCTestCase {

    private typealias Extension = ClientHelloFixtures.Extension

    private static let clientISN: UInt32 = 1000
    private static let serverISN: UInt32 = 5000
    private static let localPort: UInt16 = 51000
    private static let host = "www.example.com"

    private struct Harness {
        let relay: Relay
        let factory: FakeConnectionFactory
        let names: RecordingSNIObserver
        let offers: RecordingClientTLSObserver
    }

    private func makeHarness(observingNames: Bool = true, observingOffers: Bool = true) -> Harness {
        let factory = FakeConnectionFactory()
        let names = RecordingSNIObserver()
        let offers = RecordingClientTLSObserver()
        let relay = Relay(
            reinject: { _, _ in },
            connectionFactory: factory,
            sniObserver: observingNames ? names : nil,
            clientTLSObserver: observingOffers ? offers : nil,
            serverISNProvider: { Self.serverISN }
        )
        return Harness(relay: relay, factory: factory, names: names, offers: offers)
    }

    /// Lleva el flujo hasta `established` (SYN → ready → ACK) para poder mandarle datos.
    private func establish(_ h: Harness, remotePort: UInt16 = 443) async {
        let (syn, synRaw) = RelayFixtures.tcpV4(
            localPort: Self.localPort, remotePort: remotePort,
            flagsByte: RelayFixtures.TCPFlagByte.syn, sequence: Self.clientISN)
        await h.relay.passthrough(syn, raw: synRaw)
        await h.factory.tcpConnections[0].fireReadyAndAwaitSynAck(from: h.relay)

        let (ack, ackRaw) = RelayFixtures.tcpV4(
            localPort: Self.localPort, remotePort: remotePort,
            flagsByte: RelayFixtures.TCPFlagByte.ack,
            sequence: Self.clientISN &+ 1, acknowledgment: Self.serverISN &+ 1)
        await h.relay.passthrough(ack, raw: ackRaw)
    }

    /// Manda un segmento con datos del dispositivo hacia el servidor.
    private func send(_ h: Harness, bytes: Data, sequence: UInt32, remotePort: UInt16 = 443) async {
        let (packet, raw) = RelayFixtures.tcpV4(
            localPort: Self.localPort, remotePort: remotePort,
            flagsByte: RelayFixtures.TCPFlagByte.pshAck,
            sequence: sequence, acknowledgment: Self.serverISN &+ 1,
            payload: [UInt8](bytes))
        await h.relay.passthrough(packet, raw: raw)
    }

    private func flowKey(remotePort: UInt16 = 443) -> FlowKey {
        FlowKey(
            proto: .tcp,
            source: RelayFixtures.localV4Endpoint(port: Self.localPort),
            destination: RelayFixtures.remoteV4Endpoint(port: remotePort)
        )
    }

    private static let modernHello = ClientHelloFixtures.clientHello(extensions: [
        .supportedVersions([0x0A0A, 0x0304, 0x0303]), .serverName(host), .applicationProtocols(["h2", "http/1.1"]),
    ])

    private static let modernOffer = ClientTLSOffer(
        versions: .listed([.tls13, .tls12]),
        applicationProtocols: ["h2", "http/1.1"],
        omittedApplicationProtocols: 0,
        hasEncryptedClientHello: false
    )

    // MARK: - El caso normal

    func testTheOfferLeavesWithTheName() async throws {
        let h = makeHarness()
        await establish(h)

        await send(h, bytes: Self.modernHello, sequence: Self.clientISN &+ 1)

        let offered = await h.offers.next()
        XCTAssertEqual(offered.offer, Self.modernOffer)
        XCTAssertEqual(offered.key, flowKey())
        let named = await h.names.next()
        XCTAssertEqual(named.sni, Self.host)
        let stats = await h.relay.stats
        XCTAssertEqual(stats.clientOfferObserved, 1)
        XCTAssertEqual(stats.sniObserved, 1)
    }

    /// El que justifica una costura propia: una conexión a una IP pelada no anuncia nombre y no
    /// pasa nunca por `observe(sni:)`, pero ha dicho qué versiones acepta.
    func testAHelloWithoutANameStillReportsItsOffer() async throws {
        let h = makeHarness()
        await establish(h)
        let hello = ClientHelloFixtures.clientHello(extensions: nil, legacyVersion: 0x0301)

        await send(h, bytes: hello, sequence: Self.clientISN &+ 1)

        let offered = await h.offers.next()
        XCTAssertEqual(offered.offer.versions, .upTo(.tls10))
        let stats = await h.relay.stats
        XCTAssertEqual(stats.clientOfferObserved, 1)
        XCTAssertEqual(stats.sniObserved, 0)
        XCTAssertEqual(stats.sniUnavailable, 1)
    }

    /// El ClientHello de hoy no cabe en un segmento: la oferta sale cuando llega el segundo.
    func testTheOfferIsReadFromAHelloSplitAcrossTwoSegments() async throws {
        let h = makeHarness()
        await establish(h)
        let hello = ClientHelloFixtures.clientHello(extensions: [
            .serverName(Self.host), .padding(1_400), .supportedVersions([0x0304]), .applicationProtocols(["h2"]),
        ])
        XCTAssertGreaterThan(hello.count, 1_460)
        let first = hello.prefix(1_460)

        await send(h, bytes: first, sequence: Self.clientISN &+ 1)
        let before = await h.relay.stats
        XCTAssertEqual(before.clientOfferObserved, 0)
        await send(h, bytes: hello.dropFirst(1_460), sequence: Self.clientISN &+ 1 &+ UInt32(first.count))

        let offered = await h.offers.next()
        XCTAssertEqual(offered.offer.versions, .listed([.tls13]))
        XCTAssertEqual(offered.offer.applicationProtocols, ["h2"])
    }

    func testTheOfferIsReportedOnlyOncePerFlow() async throws {
        let h = makeHarness()
        await establish(h)

        await send(h, bytes: Self.modernHello, sequence: Self.clientISN &+ 1)
        _ = await h.offers.next()
        // Lo que sigue en el stream ya no se mira, parezca lo que parezca.
        await send(
            h, bytes: ClientHelloFixtures.clientHello(extensions: [.supportedVersions([0x0301])]),
            sequence: Self.clientISN &+ 1 &+ UInt32(Self.modernHello.count))

        let stats = await h.relay.stats
        XCTAssertEqual(stats.clientOfferObserved, 1)
        let pending = await h.offers.count
        XCTAssertEqual(pending, 0)
    }

    // MARK: - Cuándo no hay oferta

    func testAStreamThatIsNotTLSReportsNoOffer() async throws {
        let h = makeHarness()
        await establish(h)

        await send(h, bytes: Data("GET / HTTP/1.1\r\n".utf8), sequence: Self.clientISN &+ 1)

        let stats = await h.relay.stats
        XCTAssertEqual(stats.clientOfferObserved, 0)
        XCTAssertEqual(stats.sniUnavailable, 1)
    }

    /// Un ClientHello con nombre cuya lista de versiones miente: el nombre sale, la oferta no.
    func testAnUnreadableOfferDoesNotCostTheName() async throws {
        let h = makeHarness()
        await establish(h)
        let hello = ClientHelloFixtures.clientHello(extensions: [
            .serverName(Self.host), Extension(type: 43, payload: [0x03, 0x03, 0x04, 0x03]),
        ])

        await send(h, bytes: hello, sequence: Self.clientISN &+ 1)

        let named = await h.names.next()
        XCTAssertEqual(named.sni, Self.host)
        let stats = await h.relay.stats
        XCTAssertEqual(stats.sniObserved, 1)
        XCTAssertEqual(stats.clientOfferObserved, 0)
    }

    func testFlowsOutsidePort443AreNeverScanned() async throws {
        let h = makeHarness()
        await establish(h, remotePort: 8443)

        await send(h, bytes: Self.modernHello, sequence: Self.clientISN &+ 1, remotePort: 8443)

        let stats = await h.relay.stats
        XCTAssertEqual(stats.clientOfferObserved, 0)
    }

    // MARK: - Quién arma el lector

    /// Basta con que alguien quiera la oferta para que el handshake se lea, aunque nadie quiera
    /// el nombre.
    func testTheOfferObserverAloneArmsTheScanner() async throws {
        let h = makeHarness(observingNames: false)
        await establish(h)

        await send(h, bytes: Self.modernHello, sequence: Self.clientISN &+ 1)

        let offered = await h.offers.next()
        XCTAssertEqual(offered.offer, Self.modernOffer)
    }

    /// Y al revés: con solo el observador del nombre la oferta se lee igual —sale del mismo
    /// recorrido— y se cuenta, aunque no haya a quién dársela.
    func testWithoutAnOfferObserverTheOfferIsCountedAndTheNameStillLeaves() async throws {
        let h = makeHarness(observingOffers: false)
        await establish(h)

        await send(h, bytes: Self.modernHello, sequence: Self.clientISN &+ 1)

        let named = await h.names.next()
        XCTAssertEqual(named.sni, Self.host)
        let stats = await h.relay.stats
        XCTAssertEqual(stats.clientOfferObserved, 1)
    }

    func testWithoutAnyObserverNothingIsScanned() async throws {
        let h = makeHarness(observingNames: false, observingOffers: false)
        await establish(h)

        await send(h, bytes: Self.modernHello, sequence: Self.clientISN &+ 1)

        let stats = await h.relay.stats
        XCTAssertEqual(stats.clientOfferObserved, 0)
        XCTAssertEqual(stats.sniObserved, 0)
    }

    // MARK: - El reenvío no se entera

    func testForwardedStreamIsUntouched() async throws {
        let h = makeHarness()
        await establish(h)

        await send(h, bytes: Self.modernHello, sequence: Self.clientISN &+ 1)

        XCTAssertEqual(h.factory.tcpConnections[0].sentStream, Self.modernHello)
    }
}

/// Observador doble: recoge las ofertas que el relay lee. `next()` suspende hasta que llega una,
/// porque el relay avisa desde una tarea aparte.
actor RecordingClientTLSObserver: ClientTLSObserving {
    struct Observed: Sendable, Equatable {
        let offer: ClientTLSOffer
        let key: FlowKey
    }

    private var buffer: [Observed] = []
    private var waiters: [CheckedContinuation<Observed, Never>] = []

    func observe(clientTLS: ClientTLSOffer, for key: FlowKey) async {
        let observed = Observed(offer: clientTLS, key: key)
        if waiters.isEmpty {
            buffer.append(observed)
        } else {
            waiters.removeFirst().resume(returning: observed)
        }
    }

    func next() async -> Observed {
        if !buffer.isEmpty {
            return buffer.removeFirst()
        }
        return await withCheckedContinuation { waiters.append($0) }
    }

    var count: Int { buffer.count }
}
