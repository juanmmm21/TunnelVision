import Foundation
import XCTest
import Shared

/// Tests de la lectura del ServerHello dentro del `Relay`. El parser tiene los suyos
/// (`ServerHelloScannerTests`); aquí se prueba que el relay lo **conduce**: que lo alimenta con el
/// stream entrante tal y como lo entrega la conexión saliente, que la respuesta sale por la costura
/// una sola vez, y —lo que solo el relay puede garantizar— que **nunca lee el ServerHello de
/// nuestra propia terminación** como si fuera el del servidor.
final class RelayServerHelloTests: XCTestCase {

    private static let clientISN: UInt32 = 1000
    private static let serverISN: UInt32 = 5000
    private static let localPort: UInt16 = 51000
    private static let host = "www.example.com"

    private struct Harness {
        let relay: Relay
        let factory: FakeConnectionFactory
        let inspector: FakeFlowInspector
        let observer: RecordingServerTLSObserver
    }

    private func makeHarness(observing: Bool = true, inspecting: Bool = false) -> Harness {
        let factory = FakeConnectionFactory()
        let inspector = FakeFlowInspector()
        let observer = RecordingServerTLSObserver()
        let relay = Relay(
            reinject: { _, _ in },
            connectionFactory: factory,
            serverTLSObserver: observing ? observer : nil,
            inspector: inspecting ? inspector : nil,
            serverISNProvider: { Self.serverISN }
        )
        return Harness(relay: relay, factory: factory, inspector: inspector, observer: observer)
    }

    // MARK: - Conducción del flujo

    private func deliver(_ h: Harness, _ packet: ParsedPacket, _ raw: Data, candidate: Bool) async {
        if candidate {
            await h.relay.inspect(packet, raw: raw)
        } else {
            await h.relay.passthrough(packet, raw: raw)
        }
    }

    /// Lleva el flujo hasta `established` (SYN → ready → SYN-ACK → ACK).
    private func establish(_ h: Harness, remotePort: UInt16 = 443, candidate: Bool = false) async {
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

    /// El dispositivo manda su ClientHello: es lo que convierte a un candidato en terminación.
    private func sendClientHello(_ h: Harness, candidate: Bool) async {
        let (packet, raw) = RelayFixtures.tcpV4(
            localPort: Self.localPort, remotePort: 443,
            flagsByte: RelayFixtures.TCPFlagByte.pshAck,
            sequence: Self.clientISN &+ 1, acknowledgment: Self.serverISN &+ 1,
            payload: [UInt8](ClientHelloFixtures.clientHello(host: Self.host)))
        await deliver(h, packet, raw, candidate: candidate)
    }

    private func flowKey(remotePort: UInt16 = 443) -> FlowKey {
        FlowKey(
            proto: .tcp,
            source: RelayFixtures.localV4Endpoint(port: Self.localPort),
            destination: RelayFixtures.remoteV4Endpoint(port: remotePort)
        )
    }

    /// Lo que llega del servidor entra al relay por una tarea, así que afirmar justo después de
    /// `fireReceive` miraría un instante anterior al que se quiere probar.
    private func waitUntil(
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<10_000 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("no se cumplió en 10 s: \(description)", file: file, line: line)
    }

    /// Espera a que el relay haya procesado `count` trozos del servidor. Cada trozo de estos tests
    /// cabe en un segmento, así que se reinyecta como uno: es la señal de que el trozo ya pasó por
    /// el relay entero, lector incluido, y sirve también cuando lo que se afirma es que **no** se
    /// leyó nada.
    private func waitForServerData(_ h: Harness, chunks count: UInt64) async throws {
        // +1: el SYN-ACK de `establish` también es un segmento reinyectado.
        try await waitUntil("trozos del servidor reinyectados ≥ \(count)") {
            await h.relay.stats.tcpSegmentsReinjected >= count + 1
        }
    }

    // MARK: - El caso normal

    func testReadsTheVersionAndSuiteTheServerChose() async throws {
        let h = makeHarness()
        await establish(h)

        h.factory.tcpConnections[0].fireReceive(ServerHelloFixtures.tls13(cipherSuite: 0x1302))

        let observed = await h.observer.next()
        XCTAssertEqual(observed.key, flowKey())
        XCTAssertEqual(
            observed.answer,
            .negotiated(NegotiatedTLS(
                version: .tls13, cipherSuite: TLSCipherSuite(rawValue: 0x1302), fromHelloRetryRequest: false, source: .serverHello
            ))
        )
        let stats = await h.relay.stats
        XCTAssertEqual(stats.serverHelloObserved, 1)
        XCTAssertEqual(stats.serverHelloRefused, 0)
        XCTAssertEqual(stats.serverHelloUnavailable, 0)
    }

    /// El caso que justifica que el lector sea incremental y viva aquí: en TLS 1.2 el ServerHello
    /// llega en un record que no cabe en una lectura, y la conexión lo entrega a trozos.
    func testReadsAServerHelloThatArrivesInTwoChunks() async throws {
        let h = makeHarness()
        await establish(h)
        let hello = ServerHelloFixtures.tls12(cipherSuite: 0xC030)
        let first = hello.prefix(20)
        let second = hello.dropFirst(20)

        h.factory.tcpConnections[0].fireReceive(Data(first))
        try await waitForServerData(h, chunks: 1)
        let early = await h.relay.stats
        XCTAssertEqual(early.serverHelloObserved, 0, "con medio mensaje todavía no hay respuesta")

        h.factory.tcpConnections[0].fireReceive(Data(second))

        let observed = await h.observer.next()
        XCTAssertEqual(
            observed.answer,
            .negotiated(NegotiatedTLS(
                version: .tls12, cipherSuite: TLSCipherSuite(rawValue: 0xC030), fromHelloRetryRequest: false, source: .serverHello
            ))
        )
    }

    func testAHelloRetryRequestIsReportedAndMarked() async throws {
        let h = makeHarness()
        await establish(h)

        h.factory.tcpConnections[0].fireReceive(
            ServerHelloFixtures.tls13(random: ServerHelloFixtures.helloRetryRequestRandom)
        )

        let observed = await h.observer.next()
        guard case .negotiated(let negotiated) = observed.answer else {
            return XCTFail("se esperaba una negociación, llegó \(observed.answer)")
        }
        XCTAssertTrue(negotiated.fromHelloRetryRequest)
        XCTAssertEqual(negotiated.version, .tls13)
    }

    func testTheAnswerIsReportedOnlyOncePerFlow() async throws {
        let h = makeHarness()
        await establish(h)
        h.factory.tcpConnections[0].fireReceive(ServerHelloFixtures.tls13())
        _ = await h.observer.next()

        // Lo que sigue ya va cifrado; que aquí llegue otro ServerHello —con otra suite— es la forma
        // más agresiva de comprobar que el lector ya no mira.
        h.factory.tcpConnections[0].fireReceive(ServerHelloFixtures.tls12())
        try await waitForServerData(h, chunks: 2)

        let stats = await h.relay.stats
        XCTAssertEqual(stats.serverHelloObserved, 1)
        let pending = await h.observer.count
        XCTAssertEqual(pending, 0)
    }

    // MARK: - Una negativa también es una respuesta

    func testAnAlertIsReportedAsTheServerRefusing() async throws {
        let h = makeHarness()
        await establish(h)

        h.factory.tcpConnections[0].fireReceive(ServerHelloFixtures.alert(description: 70))

        let observed = await h.observer.next()
        XCTAssertEqual(observed.answer, .refused(alert: 70))
        let stats = await h.relay.stats
        XCTAssertEqual(stats.serverHelloRefused, 1)
        XCTAssertEqual(stats.serverHelloObserved, 0)
        XCTAssertEqual(stats.serverHelloUnavailable, 0)
    }

    // MARK: - Lo que no dice nada del servidor

    /// Un 443 que no habla TLS se cuenta, pero al flujo no se le apunta nada: «esto no era TLS» no
    /// es una respuesta sobre TLS.
    func testANonTLSStreamIsCountedAndNothingIsReported() async throws {
        let h = makeHarness()
        await establish(h)

        h.factory.tcpConnections[0].fireReceive(Data("HTTP/1.1 400 Bad Request\r\n".utf8))
        try await waitForServerData(h, chunks: 1)

        let stats = await h.relay.stats
        XCTAssertEqual(stats.serverHelloUnavailable, 1)
        XCTAssertEqual(stats.serverHelloObserved, 0)
        XCTAssertEqual(stats.serverHelloRefused, 0)
        let pending = await h.observer.count
        XCTAssertEqual(pending, 0)
    }

    func testFlowsOutsideTheTLSPortAreNotScanned() async throws {
        let h = makeHarness()
        await establish(h, remotePort: 80)

        // Bytes que **son** un ServerHello: si el relay escanease todo, este flujo tendría respuesta.
        h.factory.tcpConnections[0].fireReceive(ServerHelloFixtures.tls13())
        try await waitForServerData(h, chunks: 1)

        let stats = await h.relay.stats
        XCTAssertEqual(stats.serverHelloObserved, 0)
        XCTAssertEqual(stats.serverHelloUnavailable, 0)
        let pending = await h.observer.count
        XCTAssertEqual(pending, 0)
    }

    /// Sin observador el relay no escanea: no hay a quién contárselo, así que no se guarda un byte.
    func testWithoutAnObserverNothingIsScanned() async throws {
        let h = makeHarness(observing: false)
        await establish(h)

        h.factory.tcpConnections[0].fireReceive(ServerHelloFixtures.tls13())
        try await waitForServerData(h, chunks: 1)

        let stats = await h.relay.stats
        XCTAssertEqual(stats.serverHelloObserved, 0)
        XCTAssertEqual(stats.serverHelloRefused, 0)
        XCTAssertEqual(stats.serverHelloUnavailable, 0)
    }

    // MARK: - La inspección: solo se lee al servidor de verdad

    /// **El caso que no puede fallar.** En un flujo inspeccionado lo que el dispositivo recibe es
    /// el ServerHello de nuestra terminación, firmado con nuestro leaf: leerlo sería apuntarle al
    /// servidor la versión y la suite que elegimos nosotros.
    func testTheServerHelloOfOurOwnTerminationIsNeverRead() async throws {
        let h = makeHarness(inspecting: true)
        await establish(h, candidate: true)
        await sendClientHello(h, candidate: true)
        try await waitUntil("terminación instalada") { await h.relay.stats.terminationsOpened == 1 }

        h.inspector.openedTerminations[0].fireReceive(ServerHelloFixtures.tls13())
        try await waitForServerData(h, chunks: 1)

        let stats = await h.relay.stats
        XCTAssertEqual(stats.serverHelloObserved, 0)
        XCTAssertEqual(stats.serverHelloUnavailable, 0)
        let pending = await h.observer.count
        XCTAssertEqual(pending, 0)
    }

    // MARK: - La inspección: la cifra la da la conexión de subida

    private static let upstreamTLS13 = NegotiatedTLS(
        version: .tls13, cipherSuite: TLSCipherSuite(rawValue: 0x1302),
        fromHelloRetryRequest: false, source: .upstreamConnection
    )

    /// Lleva un candidato hasta tener su terminación instalada.
    private func terminate(_ h: Harness) async throws {
        await establish(h, candidate: true)
        await sendClientHello(h, candidate: true)
        try await waitUntil("terminación instalada") { await h.relay.stats.terminationsOpened == 1 }
    }

    /// Deja que el relay atienda lo que una tarea le haya dejado pendiente. Lo que la terminación
    /// cuenta entra por una tarea, y cuando lo que se afirma es que **no** hizo nada no hay señal
    /// que esperar: se le da tiempo y se pasa por el actor.
    private func settle(_ h: Harness) async throws {
        try await Task.sleep(nanoseconds: 50_000_000)
        _ = await h.relay.stats
    }

    /// Lo que un flujo inspeccionado sabe de su TLS es lo que la terminación negoció con el
    /// servidor real, y sale por la misma costura que un ServerHello leído del stream.
    func testAnInspectedFlowCarriesWhatItsUpstreamNegotiated() async throws {
        let h = makeHarness(inspecting: true)
        try await terminate(h)
        XCTAssertTrue(h.inspector.lastRequestHadUpstreamTLSSink)

        h.inspector.emitUpstreamTLS(Self.upstreamTLS13)

        let observed = await h.observer.next()
        XCTAssertEqual(observed.key, flowKey())
        XCTAssertEqual(observed.answer, .negotiated(Self.upstreamTLS13))
        let stats = await h.relay.stats
        XCTAssertEqual(stats.upstreamTLSObserved, 1)
        XCTAssertEqual(stats.serverHelloObserved, 0, "no se leyó de ningún stream")
    }

    /// Un cliente que rechaza nuestro leaf deja el flujo `notInspectable`, pero el servidor ya
    /// había contestado a la pata saliente: esa lectura se conserva. Es por lo que el origen
    /// viaja con ella y no se deduce del estado de inspección.
    func testAFlowWhoseClientPinsStillCarriesTheUpstreamReading() async throws {
        let h = makeHarness(inspecting: true)
        try await terminate(h)

        h.inspector.emitUpstreamTLS(Self.upstreamTLS13)
        let observed = await h.observer.next()
        h.inspector.resolve(.notInspectable)
        try await waitUntil("flujo marcado como pinning") { await h.relay.stats.flowsPinned == 1 }

        XCTAssertEqual(observed.answer, .negotiated(Self.upstreamTLS13))
        let extra = await h.observer.count
        XCTAssertEqual(extra, 0, "el desenlace no vuelve a contar ni borra la lectura")
    }

    /// Sin observador no se le pide a la terminación: no hay a quién contárselo.
    func testWithoutAnObserverTheTerminationIsNotAskedForItsTLS() async throws {
        let h = makeHarness(observing: false, inspecting: true)
        try await terminate(h)

        XCTAssertFalse(h.inspector.lastRequestHadUpstreamTLSSink)
    }

    /// Una terminación deshecha deja el flujo en manos de una conexión llana cuyo ServerHello
    /// contesta al ClientHello **de la app**. Si la lectura de la terminación muerta llega tarde,
    /// no se apunta: podría pisar a la que vale.
    func testAnUpstreamReadingThatArrivesAfterARollbackIsDropped() async throws {
        let h = makeHarness(inspecting: true)
        try await terminate(h)
        h.inspector.openedTerminations[0].fireClose(RelayConnectionError("la pila no levantó"))
        try await waitUntil("terminación deshecha") { await h.relay.stats.terminationsRolledBack == 1 }

        h.inspector.emitUpstreamTLS(Self.upstreamTLS13)
        try await settle(h)

        let stats = await h.relay.stats
        XCTAssertEqual(stats.upstreamTLSObserved, 0)
        let pending = await h.observer.count
        XCTAssertEqual(pending, 0)
    }

    /// Y lo mismo si el flujo ya no existe: una lectura rezagada no puede caer sobre otro flujo
    /// que haya heredado la misma 5-tupla sin ser una terminación.
    func testAnUpstreamReadingForAFlowAlreadyGoneIsDropped() async throws {
        let h = makeHarness(inspecting: true)
        try await terminate(h)
        await h.relay.close(flowKey())

        h.inspector.emitUpstreamTLS(Self.upstreamTLS13)
        try await settle(h)

        let stats = await h.relay.stats
        XCTAssertEqual(stats.upstreamTLSObserved, 0)
        let pending = await h.observer.count
        XCTAssertEqual(pending, 0)
    }

    // MARK: - La inspección: lo que vuelve al passthrough

    /// Un candidato que vuelve al passthrough sin haberse terminado habla con el servidor de
    /// verdad por su conexión llana de siempre, así que su ServerHello sí se lee.
    func testACandidateThatFallsBackToPassthroughIsRead() async throws {
        let h = makeHarness(inspecting: true)
        h.inspector.fail(with: .noCA)
        await establish(h, candidate: true)
        await sendClientHello(h, candidate: true)
        try await waitUntil("inspección abandonada") { await h.relay.stats.inspectionsAbandoned == 1 }

        h.factory.tcpConnections[0].fireReceive(ServerHelloFixtures.tls13())

        let observed = await h.observer.next()
        XCTAssertEqual(observed.key, flowKey())
        let stats = await h.relay.stats
        XCTAssertEqual(stats.serverHelloObserved, 1)
    }

    /// Y uno cuya terminación muere antes de decirle nada al dispositivo estrena conexión llana:
    /// esa sí es la del servidor, y su ServerHello se lee desde el principio.
    func testAfterARollbackTheRealServerIsRead() async throws {
        let h = makeHarness(inspecting: true)
        await establish(h, candidate: true)
        await sendClientHello(h, candidate: true)
        try await waitUntil("terminación instalada") { await h.relay.stats.terminationsOpened == 1 }
        h.inspector.openedTerminations[0].fireClose(RelayConnectionError("la pila no levantó"))
        try await waitUntil("terminación deshecha") { await h.relay.stats.terminationsRolledBack == 1 }

        h.factory.tcpConnections[1].fireReceive(ServerHelloFixtures.tls12())

        let observed = await h.observer.next()
        XCTAssertEqual(
            observed.answer,
            .negotiated(NegotiatedTLS(
                version: .tls12, cipherSuite: TLSCipherSuite(rawValue: 0xC02F), fromHelloRetryRequest: false, source: .serverHello
            ))
        )
    }
}

/// Observador doble: recoge lo que el relay lee del ServerHello. `next()` suspende hasta que llega
/// una respuesta, porque el relay la avisa desde una tarea aparte.
actor RecordingServerTLSObserver: ServerTLSObserving {
    struct Observed: Sendable, Equatable {
        let answer: ServerTLSAnswer
        let key: FlowKey
    }

    private var buffer: [Observed] = []
    private var waiters: [CheckedContinuation<Observed, Never>] = []

    func observe(serverTLS: ServerTLSAnswer, for key: FlowKey) async {
        let observed = Observed(answer: serverTLS, key: key)
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
