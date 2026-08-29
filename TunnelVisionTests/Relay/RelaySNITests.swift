import Foundation
import XCTest
import Shared

/// Tests de la lectura del SNI dentro del `Relay`. El parser tiene los suyos
/// (`ClientHelloScannerTests`); aquí se prueba que el relay lo **conduce**: que solo escanea lo que
/// puede ser TLS, que lo alimenta con el stream ya reensamblado —que es toda la razón de que esto
/// viva en el relay y no en el pipeline— y que el nombre sale por la costura una sola vez.
final class RelaySNITests: XCTestCase {

    private static let clientISN: UInt32 = 1000
    private static let serverISN: UInt32 = 5000
    private static let localPort: UInt16 = 51000
    private static let host = "www.example.com"

    private struct Harness {
        let relay: Relay
        let factory: FakeConnectionFactory
        let observer: RecordingSNIObserver
    }

    private func makeHarness(observing: Bool = true) -> Harness {
        let factory = FakeConnectionFactory()
        let observer = RecordingSNIObserver()
        let relay = Relay(
            reinject: { _, _ in },
            connectionFactory: factory,
            sniObserver: observing ? observer : nil,
            serverISNProvider: { Self.serverISN }
        )
        return Harness(relay: relay, factory: factory, observer: observer)
    }

    /// Lleva el flujo hasta `established` (SYN → ready → ACK) para poder mandarle datos.
    private func establish(_ h: Harness, remotePort: UInt16 = 443) async {
        let (syn, synRaw) = RelayFixtures.tcpV4(
            localPort: Self.localPort, remotePort: remotePort,
            flagsByte: RelayFixtures.TCPFlagByte.syn, sequence: Self.clientISN)
        await h.relay.passthrough(syn, raw: synRaw)
        h.factory.tcpConnections[0].fireReady()

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

    // MARK: - El caso normal

    func testReadsSNIFromASingleSegment() async throws {
        let h = makeHarness()
        await establish(h)

        await send(h, bytes: ClientHelloFixtures.clientHello(host: Self.host), sequence: Self.clientISN &+ 1)

        let observed = await h.observer.next()
        XCTAssertEqual(observed.sni, Self.host)
        XCTAssertEqual(observed.key, flowKey())
        let stats = await h.relay.stats
        XCTAssertEqual(stats.sniObserved, 1)
        XCTAssertEqual(stats.sniUnavailable, 0)
    }

    /// El caso que justifica leerlo en el relay: el ClientHello no cabe en un segmento.
    func testReadsSNIFromAHelloSplitAcrossTwoSegments() async throws {
        let h = makeHarness()
        await establish(h)

        let hello = ClientHelloFixtures.oversizedClientHello(host: Self.host)
        XCTAssertGreaterThan(hello.count, 1_460)
        let first = hello.prefix(1_460)
        let second = hello.dropFirst(1_460)

        await send(h, bytes: first, sequence: Self.clientISN &+ 1)
        await send(h, bytes: second, sequence: Self.clientISN &+ 1 &+ UInt32(first.count))

        let observed = await h.observer.next()
        XCTAssertEqual(observed.sni, Self.host)
        let stats = await h.relay.stats
        XCTAssertEqual(stats.sniObserved, 1)
    }

    /// Y el que lo justifica del todo: los segmentos llegan al revés. El reensamblador del relay los
    /// entrega en orden, así que el nombre se lee igual — leyendo payloads sueltos no habría nombre.
    func testReadsSNIWhenSegmentsArriveOutOfOrder() async throws {
        let h = makeHarness()
        await establish(h)

        let hello = ClientHelloFixtures.oversizedClientHello(host: Self.host)
        let first = hello.prefix(1_460)
        let second = hello.dropFirst(1_460)

        await send(h, bytes: second, sequence: Self.clientISN &+ 1 &+ UInt32(first.count))
        await send(h, bytes: first, sequence: Self.clientISN &+ 1)

        let observed = await h.observer.next()
        XCTAssertEqual(observed.sni, Self.host)
        let stats = await h.relay.stats
        XCTAssertEqual(stats.sniObserved, 1)
    }

    func testNameIsReportedOnlyOncePerFlow() async throws {
        let h = makeHarness()
        await establish(h)

        let hello = ClientHelloFixtures.clientHello(host: Self.host)
        await send(h, bytes: hello, sequence: Self.clientISN &+ 1)
        _ = await h.observer.next()

        // Lo que sigue en un flujo TLS ya va cifrado; que aquí vaya otro ClientHello es la forma
        // más agresiva de comprobar que el escáner ya no mira.
        await send(h, bytes: hello, sequence: Self.clientISN &+ 1 &+ UInt32(hello.count))

        let stats = await h.relay.stats
        XCTAssertEqual(stats.sniObserved, 1)
        XCTAssertEqual(stats.sniUnavailable, 0)
        let reported = await h.observer.count
        XCTAssertEqual(reported, 0)
    }

    // MARK: - Lo que no se escanea

    func testFlowsOutsideTLSPortAreNotScanned() async throws {
        let h = makeHarness()
        await establish(h, remotePort: 80)

        // Bytes que **son** un ClientHello: si el relay escanease todo, este flujo tendría nombre.
        await send(h, bytes: ClientHelloFixtures.clientHello(host: Self.host),
                   sequence: Self.clientISN &+ 1, remotePort: 80)

        let stats = await h.relay.stats
        XCTAssertEqual(stats.sniObserved, 0)
        XCTAssertEqual(stats.sniUnavailable, 0)
        let reported = await h.observer.count
        XCTAssertEqual(reported, 0)
    }

    func testNonTLSStreamOnTheTLSPortIsCountedAsUnavailable() async throws {
        let h = makeHarness()
        await establish(h)

        await send(h, bytes: Data("GET / HTTP/1.1\r\n".utf8), sequence: Self.clientISN &+ 1)

        let stats = await h.relay.stats
        XCTAssertEqual(stats.sniUnavailable, 1)
        XCTAssertEqual(stats.sniObserved, 0)
        let reported = await h.observer.count
        XCTAssertEqual(reported, 0)
    }

    func testHelloWithoutServerNameIsCountedAsUnavailable() async throws {
        let h = makeHarness()
        await establish(h)

        let body = ClientHelloFixtures.clientHelloBody(extensions: nil)
        let hello = Data(ClientHelloFixtures.record(payload: ClientHelloFixtures.handshakeMessage(body: body)))
        await send(h, bytes: hello, sequence: Self.clientISN &+ 1)

        let stats = await h.relay.stats
        XCTAssertEqual(stats.sniUnavailable, 1)
        let reported = await h.observer.count
        XCTAssertEqual(reported, 0)
    }

    /// Sin observador el relay no escanea: no hay a quién contárselo, así que no se guarda un byte.
    func testWithoutAnObserverNothingIsScanned() async throws {
        let h = makeHarness(observing: false)
        await establish(h)

        await send(h, bytes: ClientHelloFixtures.clientHello(host: Self.host), sequence: Self.clientISN &+ 1)

        let stats = await h.relay.stats
        XCTAssertEqual(stats.sniObserved, 0)
        XCTAssertEqual(stats.sniUnavailable, 0)
    }

    // MARK: - El reenvío no se entera

    /// Leer el nombre no puede cambiar lo que sale hacia el servidor: son los mismos bytes.
    func testForwardedStreamIsUntouched() async throws {
        let h = makeHarness()
        await establish(h)
        let hello = ClientHelloFixtures.clientHello(host: Self.host)

        await send(h, bytes: hello, sequence: Self.clientISN &+ 1)

        XCTAssertEqual(h.factory.tcpConnections[0].sentStream, hello)
    }
}

/// Observador doble: recoge los nombres que el relay lee. `next()` suspende hasta que llega uno,
/// porque el relay lo avisa desde una tarea aparte (el nombre sale del camino de los bytes).
actor RecordingSNIObserver: SNIObserving {
    struct Observed: Sendable, Equatable {
        let sni: String
        let key: FlowKey
    }

    private var buffer: [Observed] = []
    private var waiters: [CheckedContinuation<Observed, Never>] = []

    func observe(sni: String, for key: FlowKey) async {
        let observed = Observed(sni: sni, key: key)
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
