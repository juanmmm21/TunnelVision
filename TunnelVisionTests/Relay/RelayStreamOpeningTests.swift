import Foundation
import XCTest
import Shared

/// Tests de la lectura del **arranque del stream** dentro del `Relay`. El escáner tiene los suyos
/// (`StreamOpeningScannerTests`); aquí se prueba lo que solo el relay puede contestar: que se lee
/// en **cualquier** puerto —es para lo que existe—, que sale una sola vez por su costura, que un
/// flujo candidato a inspección también lo dice aunque sus bytes estén retenidos, y que leerlo no
/// cambia lo que llega al servidor.
final class RelayStreamOpeningTests: XCTestCase {

    private static let clientISN: UInt32 = 1000
    private static let serverISN: UInt32 = 5000
    private static let localPort: UInt16 = 51000

    private static let clientHello = ClientHelloFixtures.clientHello(host: "www.example.com")
    private static let httpRequest = Data("GET /status HTTP/1.1\r\nHost: example.com\r\n\r\n".utf8)

    private struct Harness {
        let relay: Relay
        let factory: FakeConnectionFactory
        let openings: RecordingStreamOpeningObserver
    }

    private func makeHarness(observing: Bool = true, inspecting: Bool = false) -> Harness {
        let factory = FakeConnectionFactory()
        let openings = RecordingStreamOpeningObserver()
        let relay = Relay(
            reinject: { _, _ in },
            connectionFactory: factory,
            streamOpeningObserver: observing ? openings : nil,
            inspector: inspecting ? FakeFlowInspector() : nil,
            serverISNProvider: { Self.serverISN }
        )
        return Harness(relay: relay, factory: factory, openings: openings)
    }

    private func deliver(_ h: Harness, _ packet: ParsedPacket, _ raw: Data, candidate: Bool) async {
        if candidate {
            await h.relay.inspect(packet, raw: raw)
        } else {
            await h.relay.passthrough(packet, raw: raw)
        }
    }

    /// Lleva el flujo hasta `established` (SYN → ready → ACK) para poder mandarle datos.
    private func establish(_ h: Harness, remotePort: UInt16, candidate: Bool = false) async {
        let (syn, synRaw) = RelayFixtures.tcpV4(
            localPort: Self.localPort, remotePort: remotePort,
            flagsByte: RelayFixtures.TCPFlagByte.syn, sequence: Self.clientISN)
        await deliver(h, syn, synRaw, candidate: candidate)
        await h.factory.tcpConnections[0].fireReadyAndAwaitSynAck(from: h.relay)

        let (ack, ackRaw) = RelayFixtures.tcpV4(
            localPort: Self.localPort, remotePort: remotePort,
            flagsByte: RelayFixtures.TCPFlagByte.ack,
            sequence: Self.clientISN &+ 1, acknowledgment: Self.serverISN &+ 1)
        await deliver(h, ack, ackRaw, candidate: candidate)
    }

    private func send(
        _ h: Harness, bytes: Data, sequence: UInt32, remotePort: UInt16, candidate: Bool = false
    ) async {
        let (packet, raw) = RelayFixtures.tcpV4(
            localPort: Self.localPort, remotePort: remotePort,
            flagsByte: RelayFixtures.TCPFlagByte.pshAck,
            sequence: sequence, acknowledgment: Self.serverISN &+ 1,
            payload: [UInt8](bytes))
        await deliver(h, packet, raw, candidate: candidate)
    }

    private func flowKey(remotePort: UInt16) -> FlowKey {
        FlowKey(
            proto: .tcp,
            source: RelayFixtures.localV4Endpoint(port: Self.localPort),
            destination: RelayFixtures.remoteV4Endpoint(port: remotePort)
        )
    }

    // MARK: - Cualquier puerto

    func testAnHTTPRequestOnPort80IsObserved() async {
        let h = makeHarness()
        await establish(h, remotePort: 80)

        await send(h, bytes: Self.httpRequest, sequence: Self.clientISN &+ 1, remotePort: 80)

        let observed = await h.openings.next()
        XCTAssertEqual(observed, .init(opening: .httpRequest, key: flowKey(remotePort: 80)))
        let stats = await h.relay.stats
        XCTAssertEqual(stats.streamOpeningsHTTP, 1)
        XCTAssertEqual(stats.streamOpeningsTLS, 0)
        XCTAssertEqual(stats.streamOpeningsUnrecognised, 0)
    }

    /// El caso para el que se hizo: un TLS fuera del 443, del que hasta ahora solo se sabía el
    /// puerto.
    func testATLSHandshakeOffPort443IsObserved() async {
        for port in [UInt16(5223), 8443, 993] {
            let h = makeHarness()
            await establish(h, remotePort: port)

            await send(h, bytes: Self.clientHello, sequence: Self.clientISN &+ 1, remotePort: port)

            let observed = await h.openings.next()
            XCTAssertEqual(observed, .init(opening: .tlsHandshake, key: flowKey(remotePort: port)))
            let stats = await h.relay.stats
            XCTAssertEqual(stats.streamOpeningsTLS, 1)
        }
    }

    func testATLSHandshakeOnPort443IsObserved() async {
        let h = makeHarness()
        await establish(h, remotePort: 443)

        await send(h, bytes: Self.clientHello, sequence: Self.clientISN &+ 1, remotePort: 443)

        let observed = await h.openings.next()
        XCTAssertEqual(observed.opening, .tlsHandshake)
    }

    /// Un 443 que no habla TLS no es «en claro»: es que no se reconoce.
    func testAnythingElseIsUnrecognisedOnAnyPort() async {
        for port in [UInt16(443), 22] {
            let h = makeHarness()
            await establish(h, remotePort: port)

            await send(h, bytes: Data([0x00, 0x2A, 0xFF, 0x10]), sequence: Self.clientISN &+ 1, remotePort: port)

            let observed = await h.openings.next()
            XCTAssertEqual(observed.opening, .unrecognised)
            let stats = await h.relay.stats
            XCTAssertEqual(stats.streamOpeningsUnrecognised, 1)
        }
    }

    // MARK: - Una vez, y sin tocar el stream

    func testARequestLineSplitAcrossSegmentsIsObservedOnce() async {
        let h = makeHarness()
        await establish(h, remotePort: 80)
        let first = Self.httpRequest.prefix(9)
        let rest = Self.httpRequest.dropFirst(9)

        await send(h, bytes: Data(first), sequence: Self.clientISN &+ 1, remotePort: 80)
        var stats = await h.relay.stats
        XCTAssertEqual(stats.streamOpeningsHTTP, 0, "con media línea todavía no se afirma nada")

        await send(h, bytes: Data(rest), sequence: Self.clientISN &+ 1 &+ UInt32(first.count), remotePort: 80)
        _ = await h.openings.next()

        // Lo que venga detrás ya no se mira.
        await send(
            h, bytes: Self.clientHello,
            sequence: Self.clientISN &+ 1 &+ UInt32(Self.httpRequest.count), remotePort: 80)
        stats = await h.relay.stats
        XCTAssertEqual(stats.streamOpeningsHTTP, 1)
        XCTAssertEqual(stats.streamOpeningsTLS, 0)
        let pending = await h.openings.count
        XCTAssertEqual(pending, 0)
    }

    func testReadingTheOpeningDoesNotChangeWhatReachesTheServer() async {
        let h = makeHarness()
        await establish(h, remotePort: 80)

        await send(h, bytes: Self.httpRequest, sequence: Self.clientISN &+ 1, remotePort: 80)
        _ = await h.openings.next()

        XCTAssertEqual(h.factory.tcpConnections[0].sentStream, Self.httpRequest)
    }

    func testAFlowThatSendsNothingHasNoOpening() async {
        let h = makeHarness()
        await establish(h, remotePort: 80)

        let stats = await h.relay.stats
        XCTAssertEqual(stats.streamOpeningsHTTP + stats.streamOpeningsTLS + stats.streamOpeningsUnrecognised, 0)
        let pending = await h.openings.count
        XCTAssertEqual(pending, 0)
    }

    /// Sin nadie a quien contárselo no se crea el lector: ni se cuenta ni se guarda estado.
    func testWithoutAnObserverNothingIsRead() async {
        let h = makeHarness(observing: false)
        await establish(h, remotePort: 80)

        await send(h, bytes: Self.httpRequest, sequence: Self.clientISN &+ 1, remotePort: 80)

        let stats = await h.relay.stats
        XCTAssertEqual(stats.streamOpeningsHTTP, 0)
        XCTAssertEqual(h.factory.tcpConnections[0].sentStream, Self.httpRequest)
    }

    // MARK: - Con inspección

    /// Un candidato retiene lo que el dispositivo manda hasta saber si se inspecciona; el
    /// arranque se lee igual, porque es del dispositivo vaya adonde vaya después.
    func testACandidateForInspectionStillSaysHowItOpened() async {
        let h = makeHarness(inspecting: true)
        await establish(h, remotePort: 443, candidate: true)

        await send(h, bytes: Self.clientHello, sequence: Self.clientISN &+ 1, remotePort: 443, candidate: true)

        let observed = await h.openings.next()
        XCTAssertEqual(observed, .init(opening: .tlsHandshake, key: flowKey(remotePort: 443)))
    }
}

/// Observador doble: recoge los arranques que el relay lee. `next()` suspende hasta que llega
/// uno, porque el relay avisa desde una tarea aparte.
actor RecordingStreamOpeningObserver: StreamOpeningObserving {
    struct Observed: Sendable, Equatable {
        let opening: StreamOpening
        let key: FlowKey
    }

    private var buffer: [Observed] = []
    private var waiters: [CheckedContinuation<Observed, Never>] = []

    func observe(streamOpening: StreamOpening, for key: FlowKey) async {
        let observed = Observed(opening: streamOpening, key: key)
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
