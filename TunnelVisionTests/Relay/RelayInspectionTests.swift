import Foundation
import XCTest
import Shared

/// Tests del **enganche de la inspección TLS al relay**: la pieza que convierte un flujo candidato en
/// una terminación. La política vive en `TLSInterceptionPolicy` y el emparejamiento en
/// `TLSTerminationConnection`, y los dos tienen sus tests; aquí se prueba lo que solo el relay puede
/// contestar: **cuándo** se sustituye la conexión, qué pasa con los bytes que el dispositivo mandó
/// mientras no se sabía, y qué pasa cuando no hay nada que inspeccionar.
final class RelayInspectionTests: XCTestCase {

    private static let clientISN: UInt32 = 1000
    private static let serverISN: UInt32 = 5000
    private static let host = "www.example.com"

    private struct Harness {
        let relay: Relay
        let factory: FakeConnectionFactory
        let inspector: FakeFlowInspector
        let statuses: RecordingTLSStatusObserver
        let reinjector: RecordingReinjector
    }

    private func makeHarness(inspecting: Bool = true) -> Harness {
        let factory = FakeConnectionFactory()
        let inspector = FakeFlowInspector()
        let statuses = RecordingTLSStatusObserver()
        let reinjector = RecordingReinjector()
        let relay = Relay(
            reinject: { datagrams, protocols in
                for (datagram, family) in zip(datagrams, protocols.map(\.int32Value)) {
                    Task { await reinjector.record(datagram: datagram, family: family) }
                }
            },
            connectionFactory: factory,
            inspector: inspecting ? inspector : nil,
            statusObserver: statuses,
            serverISNProvider: { Self.serverISN }
        )
        return Harness(relay: relay, factory: factory, inspector: inspector, statuses: statuses, reinjector: reinjector)
    }

    // MARK: - Conducción del flujo

    /// Lleva el flujo hasta `established` (SYN → ready → ACK). `candidate` decide por qué puerta del
    /// relay entra, que es exactamente lo que el pipeline decide con `PacketDisposition`.
    private func establish(_ h: Harness, localPort: UInt16 = 51000, candidate: Bool = true) async {
        let (syn, synRaw) = RelayFixtures.tcpV4(
            localPort: localPort, flagsByte: RelayFixtures.TCPFlagByte.syn, sequence: Self.clientISN)
        await deliver(h, syn, synRaw, candidate: candidate)

        // La conexión llana del flujo es la última creada: los tests con dos flujos van en orden.
        h.factory.tcpConnections.last?.fireReady()

        let (ack, ackRaw) = RelayFixtures.tcpV4(
            localPort: localPort, flagsByte: RelayFixtures.TCPFlagByte.ack,
            sequence: Self.clientISN &+ 1, acknowledgment: Self.serverISN &+ 1)
        await deliver(h, ack, ackRaw, candidate: candidate)
    }

    private func send(
        _ h: Harness,
        bytes: Data,
        sequence: UInt32,
        localPort: UInt16 = 51000,
        candidate: Bool = true,
        flagsByte: UInt8 = RelayFixtures.TCPFlagByte.pshAck
    ) async {
        let (packet, raw) = RelayFixtures.tcpV4(
            localPort: localPort, flagsByte: flagsByte,
            sequence: sequence, acknowledgment: Self.serverISN &+ 1, payload: [UInt8](bytes))
        await deliver(h, packet, raw, candidate: candidate)
    }

    private func deliver(_ h: Harness, _ packet: ParsedPacket, _ raw: Data, candidate: Bool) async {
        if candidate {
            await h.relay.inspect(packet, raw: raw)
        } else {
            await h.relay.passthrough(packet, raw: raw)
        }
    }

    private func flowKey(localPort: UInt16 = 51000) -> FlowKey {
        FlowKey(
            proto: .tcp,
            source: RelayFixtures.localV4Endpoint(port: localPort),
            destination: RelayFixtures.remoteV4Endpoint(port: 443)
        )
    }

    /// El enganche cruza una tarea (construir la terminación es `async`), así que afirmar justo
    /// después de mandar el ClientHello miraría un instante anterior al que se quiere probar.
    private func waitUntil(
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @Sendable () async -> Bool
    ) async throws {
        // 10 s y no 2: instalar una terminación pasa por varios saltos de actor, y con la máquina
        // cargada —dos suites a la vez, que es lo que pasó— 2 s se agotaban sin que nada estuviera
        // mal. El presupuesto no relaja la afirmación (lo que no se cumple sigue fallando), solo
        // deja de convertir la carga de la máquina en un rojo falso.
        for _ in 0..<10_000 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("no se cumplió en 10 s: \(description)", file: file, line: line)
    }

    private func waitForTermination(_ h: Harness, count: UInt64 = 1) async throws {
        try await waitUntil("terminaciones instaladas ≥ \(count)") {
            await h.relay.stats.terminationsOpened >= count
        }
    }

    private func waitForAbandon(_ h: Harness, count: UInt64 = 1) async throws {
        try await waitUntil("inspecciones abandonadas ≥ \(count)") {
            await h.relay.stats.inspectionsAbandoned >= count
        }
    }

    // MARK: - Retener hasta saber el nombre

    /// Lo que hace posible sustituir la conexión: mientras no hay nombre, el ClientHello **no sale**.
    /// Si saliera, el servidor real ya estaría a mitad de un handshake que no es el que va a haber.
    func testTheClientHelloIsHeldWhileTheNameIsUnknown() async throws {
        let h = makeHarness()
        h.inspector.hold(at: AsyncGate())   // la terminación no llega nunca en este test
        await establish(h)

        await send(h, bytes: ClientHelloFixtures.clientHello(host: Self.host), sequence: Self.clientISN &+ 1)

        XCTAssertEqual(h.factory.tcpConnections[0].sentStream, Data())
        let stats = await h.relay.stats
        XCTAssertEqual(stats.inspectionCandidates, 1)
        XCTAssertEqual(stats.tcpBytesToServer, 0)
    }

    /// Y el flujo se abre igual que cualquier otro: conexión saliente de verdad y SYN-ACK fiel. Es lo
    /// que hace que un servidor que rechaza siga rechazando de cara al dispositivo.
    func testACandidateOpensItsPlainConnectionLikeAnyOtherFlow() async throws {
        let h = makeHarness()
        await establish(h)

        XCTAssertEqual(h.factory.tcpConnections.count, 1)
        XCTAssertEqual(h.factory.tcpEndpoints, [RelayFixtures.remoteV4Endpoint(port: 443)])
        let synAck = await h.reinjector.next()
        let parsed = try PacketParser.parse(synAck.datagram, protocolFamily: Int32(AF_INET))
        XCTAssertEqual(parsed.tcp?.flags, [.syn, .ack])
    }

    // MARK: - La sustitución

    func testTheTerminationReplacesThePlainConnectionAndReceivesTheHeldStream() async throws {
        let h = makeHarness()
        await establish(h)
        let hello = ClientHelloFixtures.clientHello(host: Self.host)

        await send(h, bytes: hello, sequence: Self.clientISN &+ 1)
        try await waitForTermination(h)

        XCTAssertEqual(h.inspector.openRequests, [
            .init(endpoint: RelayFixtures.remoteV4Endpoint(port: 443), sni: Self.host)
        ])
        // El ClientHello llega entero a la terminación, y **solo** a ella.
        XCTAssertEqual(h.inspector.openedTerminations[0].sentStream, hello)
        XCTAssertEqual(h.factory.tcpConnections[0].sentStream, Data())
        XCTAssertTrue(h.factory.tcpConnections[0].isCancelled)

        let stats = await h.relay.stats
        XCTAssertEqual(stats.terminationsOpened, 1)
        XCTAssertEqual(stats.tcpBytesToServer, UInt64(hello.count))
    }

    /// A partir de la sustitución, el stream del dispositivo va por la terminación: ese es todo el
    /// truco de que una terminación tenga forma de `RelayConnection`.
    func testAfterTheSwapTheDeviceStreamGoesToTheTermination() async throws {
        let h = makeHarness()
        await establish(h)
        let hello = ClientHelloFixtures.clientHello(host: Self.host)
        await send(h, bytes: hello, sequence: Self.clientISN &+ 1)
        try await waitForTermination(h)

        let record = Data([0x17, 0x03, 0x03, 0x00, 0x05])
        await send(h, bytes: record, sequence: Self.clientISN &+ 1 &+ UInt32(hello.count))

        XCTAssertEqual(h.inspector.openedTerminations[0].sentStream, hello + record)
        XCTAssertEqual(h.factory.tcpConnections[0].sentStream, Data())
    }

    /// El cierre de la conexión llana cancelada **no puede** derribar el flujo. Sin la marca de
    /// generación llegaría indistinguible del cierre de la conexión viva, y cancelar para inspeccionar
    /// mataría justo el flujo que se está inspeccionando.
    func testTheCancelledPlainConnectionCannotTearDownTheFlow() async throws {
        let h = makeHarness()
        await establish(h)
        await send(h, bytes: ClientHelloFixtures.clientHello(host: Self.host), sequence: Self.clientISN &+ 1)
        try await waitForTermination(h)

        let before = await h.reinjector.count
        h.factory.tcpConnections[0].fireClose(nil)
        h.factory.tcpConnections[0].fireReceive(Data([0xDE, 0xAD]))
        try await Task.sleep(nanoseconds: 20_000_000)

        let alive = await h.relay.activeTCPFlowCount
        XCTAssertEqual(alive, 1)
        let after = await h.reinjector.count
        XCTAssertEqual(after, before, "un eco de la conexión sustituida no puede emitir nada al dispositivo")
    }

    /// La terminación avisa de que su pata saliente está lista **después** de que el dispositivo ya
    /// tenga su SYN-ACK. La máquina de estados lo ignora, que es justo por lo que esta forma de
    /// engancharlo es la que menos la toca.
    func testTheTerminationReadyDoesNotResendTheSynAck() async throws {
        let h = makeHarness()
        await establish(h)
        await send(h, bytes: ClientHelloFixtures.clientHello(host: Self.host), sequence: Self.clientISN &+ 1)
        try await waitForTermination(h)

        let before = await h.reinjector.count
        h.inspector.openedTerminations[0].fireReady()
        try await Task.sleep(nanoseconds: 20_000_000)

        let after = await h.reinjector.count
        XCTAssertEqual(after, before)
    }

    /// Y lo que responde el servidor real llega al dispositivo por el camino de siempre: la
    /// terminación entrega bytes de aplicación y la máquina de estados los re-segmenta.
    func testTheTerminationsRepliesAreResegmentedToTheDevice() async throws {
        let h = makeHarness()
        await establish(h)
        await send(h, bytes: ClientHelloFixtures.clientHello(host: Self.host), sequence: Self.clientISN &+ 1)
        try await waitForTermination(h)

        let reply = Data([0x16, 0x03, 0x03, 0x00, 0x2A])
        h.inspector.openedTerminations[0].fireReceive(reply)

        try await awaitPayload(reply, in: h)
    }

    /// Espera a que el dispositivo reciba un segmento con este payload, descartando por el camino los
    /// ACKs sin datos que la máquina de estados emite.
    private func awaitPayload(
        _ payload: Data,
        in h: Harness,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<2_000 {
            while await h.reinjector.count > 0 {
                let injected = await h.reinjector.next()
                if let parsed = try? PacketParser.parse(injected.datagram, protocolFamily: Int32(AF_INET)),
                   let tcp = parsed.tcp,
                   Data(injected.datagram[tcp.payloadRange]) == payload {
                    return
                }
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("el dispositivo nunca recibió el segmento esperado", file: file, line: line)
    }

    // MARK: - Cuando no hay nada que inspeccionar

    /// Un 443 que no habla TLS —la mensajería de WhatsApp habla Noise— vuelve al passthrough **sin
    /// perder un byte**. Sin esto, encender la inspección rompería tráfico de todos los días.
    func testANonTLSFlowOn443FallsBackToPassthroughWithoutLosingAByte() async throws {
        let h = makeHarness()
        await establish(h)
        let request = Data("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n".utf8)

        await send(h, bytes: request, sequence: Self.clientISN &+ 1)

        XCTAssertEqual(h.factory.tcpConnections[0].sentStream, request)
        XCTAssertEqual(h.inspector.openRequests.count, 0)
        let stats = await h.relay.stats
        XCTAssertEqual(stats.inspectionsAbandoned, 1)
        XCTAssertEqual(stats.terminationsOpened, 0)
        XCTAssertEqual(stats.tcpBytesToServer, UInt64(request.count))
        // Y lo que sigue tampoco se retiene: el flujo ya no es candidato.
        let more = Data("GET /again HTTP/1.1\r\n\r\n".utf8)
        await send(h, bytes: more, sequence: Self.clientISN &+ 1 &+ UInt32(request.count))
        XCTAssertEqual(h.factory.tcpConnections[0].sentStream, request + more)
        let observed = await h.statuses.observed
        XCTAssertTrue(observed.isEmpty, "no inspeccionar no es lo mismo que no ser inspeccionable")
    }

    /// Una razón transitoria (la CA no está lista todavía) relaya el flujo intacto y **no** lo marca:
    /// la causa puede desaparecer, y marcarlo sería acusar de pinning a quien no lo hace.
    func testATransientFailureReturnsTheFlowToPassthroughWithoutMarkingIt() async throws {
        let h = makeHarness()
        h.inspector.fail(with: .noCA)
        await establish(h)
        let hello = ClientHelloFixtures.clientHello(host: Self.host)

        await send(h, bytes: hello, sequence: Self.clientISN &+ 1)
        try await waitForAbandon(h)

        XCTAssertEqual(h.factory.tcpConnections[0].sentStream, hello)
        let observed = await h.statuses.observed
        XCTAssertTrue(observed.isEmpty)
        let stats = await h.relay.stats
        XCTAssertEqual(stats.terminationsOpened, 0)
    }

    /// Apagar la inspección a media apertura devuelve el flujo al passthrough: el siguiente paquete ya
    /// llega enrutado a `.passthrough`, y con él sale lo retenido.
    func testTurningInspectionOffMidHandshakeReleasesWhatWasHeld() async throws {
        let h = makeHarness()
        h.inspector.hold(at: AsyncGate())
        await establish(h)

        let hello = ClientHelloFixtures.oversizedClientHello(host: Self.host)
        let first = hello.prefix(1_460)
        let second = hello.dropFirst(1_460)
        await send(h, bytes: first, sequence: Self.clientISN &+ 1)
        XCTAssertEqual(h.factory.tcpConnections[0].sentStream, Data())

        await send(h, bytes: second, sequence: Self.clientISN &+ 1 &+ UInt32(first.count), candidate: false)

        XCTAssertEqual(h.factory.tcpConnections[0].sentStream, Data(hello))
        XCTAssertEqual(h.inspector.openRequests.count, 0)
    }

    /// Un flujo que el pipeline no enruta a `.inspect` no se termina nunca, aunque sea TLS contra el
    /// 443 y traiga su nombre: quien decide quién es candidato es el pipeline.
    func testAFlowThatIsNotACandidateIsNeverTerminated() async throws {
        let h = makeHarness()
        await establish(h, candidate: false)
        let hello = ClientHelloFixtures.clientHello(host: Self.host)

        await send(h, bytes: hello, sequence: Self.clientISN &+ 1, candidate: false)

        XCTAssertEqual(h.factory.tcpConnections[0].sentStream, hello)
        XCTAssertEqual(h.inspector.openRequests.count, 0)
        let stats = await h.relay.stats
        XCTAssertEqual(stats.inspectionCandidates, 0)
    }

    /// Sin interceptor no hay inspección posible, así que un candidato se comporta como cualquier
    /// otro flujo: nada se retiene.
    func testWithoutAnInspectorACandidateIsPurePassthrough() async throws {
        let h = makeHarness(inspecting: false)
        await establish(h)
        let hello = ClientHelloFixtures.clientHello(host: Self.host)

        await send(h, bytes: hello, sequence: Self.clientISN &+ 1)

        XCTAssertEqual(h.factory.tcpConnections[0].sentStream, hello)
        let stats = await h.relay.stats
        XCTAssertEqual(stats.inspectionCandidates, 0)
    }

    /// El FIN del dispositivo que llega mientras se retiene va **detrás** de lo retenido: cerrar en el
    /// acto le enseñaría al servidor el final antes que el principio.
    func testADeviceFinDuringTheHoldReachesTheTerminationAfterTheHeldBytes() async throws {
        let h = makeHarness()
        let gate = AsyncGate()
        h.inspector.hold(at: gate)
        await establish(h)
        let hello = ClientHelloFixtures.clientHello(host: Self.host)

        await send(h, bytes: hello, sequence: Self.clientISN &+ 1)
        await send(h, bytes: Data(), sequence: Self.clientISN &+ 1 &+ UInt32(hello.count),
                   flagsByte: RelayFixtures.TCPFlagByte.finAck)
        await gate.open()
        try await waitForTermination(h)

        let termination = h.inspector.openedTerminations[0]
        XCTAssertEqual(termination.sentStream, hello)
        XCTAssertTrue(termination.isSendClosed)
        XCTAssertFalse(h.factory.tcpConnections[0].isSendClosed)
    }

    /// Degradación acotada: si el dispositivo llena el buffer mientras la terminación no acaba de
    /// levantarse, el flujo vuelve al passthrough en vez de crecer sin límite dentro de la extensión.
    func testHoldingMoreThanTheCeilingFallsBackToPassthrough() async throws {
        let h = makeHarness()
        let gate = AsyncGate()
        h.inspector.hold(at: gate)
        await establish(h)

        let hello = ClientHelloFixtures.clientHello(host: Self.host)
        await send(h, bytes: hello, sequence: Self.clientISN &+ 1)
        var sequence = Self.clientISN &+ 1 &+ UInt32(hello.count)
        let chunk = Data(repeating: 0x17, count: 40_000)
        for _ in 0..<2 {
            await send(h, bytes: chunk, sequence: sequence)
            sequence &+= UInt32(chunk.count)
        }

        try await waitForAbandon(h)
        XCTAssertEqual(h.factory.tcpConnections[0].sentStream.count, hello.count + 2 * chunk.count)

        // Y la terminación que llegue tarde se deshace sin haber arrancado.
        await gate.open()
        try await waitUntil("la terminación tardía se cancela") {
            h.inspector.openedTerminations.first?.isCancelled == true
        }
        let stats = await h.relay.stats
        XCTAssertEqual(stats.terminationsOpened, 0)
    }

    // MARK: - Desenlaces

    func testAnInspectedFlowIsReportedAsInspected() async throws {
        let h = makeHarness()
        await establish(h)
        await send(h, bytes: ClientHelloFixtures.clientHello(host: Self.host), sequence: Self.clientISN &+ 1)
        try await waitForTermination(h)

        h.inspector.resolve(.inspected)

        try await waitUntil("el estado llega a la tabla de flujos") {
            await h.statuses.observed.count == 1
        }
        let observed = await h.statuses.observed
        XCTAssertEqual(observed, [.init(status: .inspected, key: flowKey())])
        let stats = await h.relay.stats
        XCTAssertEqual(stats.flowsInspected, 1)
        XCTAssertEqual(stats.flowsPinned, 0)
    }

    /// El invariante del ADR 0003: un cliente que rechaza nuestro leaf marca el flujo y no se
    /// reintenta. No es un fallo — es el sistema de seguridad de la otra app funcionando.
    func testAPinnedClientMarksTheFlowNotInspectable() async throws {
        let h = makeHarness()
        await establish(h)
        await send(h, bytes: ClientHelloFixtures.clientHello(host: Self.host), sequence: Self.clientISN &+ 1)
        try await waitForTermination(h)

        h.inspector.resolve(.notInspectable)

        try await waitUntil("el estado llega a la tabla de flujos") {
            await h.statuses.observed.count == 1
        }
        let observed = await h.statuses.observed
        XCTAssertEqual(observed, [.init(status: .notInspectable, key: flowKey())])
        let stats = await h.relay.stats
        XCTAssertEqual(stats.flowsPinned, 1)
    }

    /// Y la otra mitad del invariante, que es la que se nota: el **reintento** del cliente llega con
    /// otro puerto de origen —otra `FlowKey`— y tampoco se termina, porque el host quedó recordado.
    func testTheRetryOfAPinnedHostIsNotTerminatedAgain() async throws {
        let h = makeHarness()
        await establish(h)
        let hello = ClientHelloFixtures.clientHello(host: Self.host)
        await send(h, bytes: hello, sequence: Self.clientISN &+ 1)
        try await waitForTermination(h)
        h.inspector.resolve(.notInspectable)
        try await waitUntil("el host queda recordado") { await h.relay.stats.flowsPinned == 1 }

        // El reintento: mismo host, otro puerto de origen.
        await establish(h, localPort: 51001)
        await send(h, bytes: hello, sequence: Self.clientISN &+ 1, localPort: 51001)

        try await waitUntil("el reintento se salta la terminación") {
            await h.relay.stats.pinnedHostSkips == 1
        }
        XCTAssertEqual(h.inspector.openRequests.count, 1, "no se vuelve a forzar al cliente que pinnea")
        XCTAssertEqual(h.factory.tcpConnections[1].sentStream, hello, "y su tráfico sale intacto")
        let retryKey = flowKey(localPort: 51001)
        try await waitUntil("el reintento también se marca") {
            await h.statuses.observed.contains(.init(status: .notInspectable, key: retryKey))
        }
    }

    /// Una razón transitoria **con la terminación ya en marcha** no marca nada: no queda flujo
    /// intacto que relayar, así que lo que se pierde es esa conexión y el cliente reintenta.
    func testATerminationThatFailsLateIsCountedButNotMarked() async throws {
        let h = makeHarness()
        await establish(h)
        await send(h, bytes: ClientHelloFixtures.clientHello(host: Self.host), sequence: Self.clientISN &+ 1)
        try await waitForTermination(h)

        h.inspector.resolve(.fail(.handshakeWithServerFailed))

        try await waitUntil("el fallo se cuenta") { await h.relay.stats.terminationsFailed == 1 }
        let observed = await h.statuses.observed
        XCTAssertTrue(observed.isEmpty)
    }

    // MARK: - La vuelta atrás: una terminación que muere sin decir nada no cuesta la conexión

    private func waitForRollback(_ h: Harness, count: UInt64 = 1) async throws {
        try await waitUntil("terminaciones deshechas ≥ \(count)") {
            await h.relay.stats.terminationsRolledBack >= count
        }
    }

    /// **El caso que decide si el teléfono navega.** Una terminación que se cae antes de que el
    /// dispositivo reciba un solo byte suyo —la pila que no levanta, el listener que el sandbox no
    /// deja abrir— no tiene por qué costar la conexión: el flujo vuelve al passthrough por una
    /// conexión llana nueva y el ClientHello sale hacia el servidor real, entero.
    func testATerminationThatDiesBeforeTheDeviceSeesAByteReturnsTheFlowToPassthrough() async throws {
        let h = makeHarness()
        await establish(h)
        let hello = ClientHelloFixtures.clientHello(host: Self.host)
        await send(h, bytes: hello, sequence: Self.clientISN &+ 1)
        try await waitForTermination(h)

        h.inspector.openedTerminations[0].fireClose(RelayConnectionError("la pila no levantó"))

        try await waitForRollback(h)
        XCTAssertEqual(h.factory.tcpConnections.count, 2, "el flujo estrena conexión llana")
        XCTAssertEqual(h.factory.tcpConnections[1].sentStream, hello, "y sale lo que el dispositivo mandó")
        let stats = await h.relay.stats
        XCTAssertEqual(stats.tcpResetsToDevice, 0, "el dispositivo no se entera: ni un RST")
        let liveFlows = await h.relay.activeTCPFlowCount
        XCTAssertEqual(liveFlows, 1, "y el flujo sigue vivo")
        let observed = await h.statuses.observed
        XCTAssertTrue(observed.isEmpty, "no se marca a nadie: la causa es transitoria")
    }

    /// La vuelta atrás lleva **todo** lo que el dispositivo mandó, no solo lo retenido antes del
    /// cambio: lo que siguió mandando mientras la terminación vivía también es suyo y va detrás.
    func testTheRollbackCarriesWhatTheDeviceSentAfterTheSwapToo() async throws {
        let h = makeHarness()
        await establish(h)
        let hello = ClientHelloFixtures.clientHello(host: Self.host)
        await send(h, bytes: hello, sequence: Self.clientISN &+ 1)
        try await waitForTermination(h)

        let more = Data([0x14, 0x03, 0x03, 0x00, 0x01, 0x01])
        await send(h, bytes: more, sequence: Self.clientISN &+ 1 &+ UInt32(hello.count))
        try await waitUntil("la terminación recibió lo segundo") {
            h.inspector.openedTerminations[0].sentStream == hello + more
        }

        h.inspector.openedTerminations[0].fireClose(RelayConnectionError("la pila no levantó"))

        try await waitForRollback(h)
        XCTAssertEqual(h.factory.tcpConnections[1].sentStream, hello + more)
    }

    /// Un cierre **limpio** de una terminación que no dijo nada también vuelve atrás: al dispositivo
    /// le daría igual el motivo — se quedaría con un FIN habiendo mandado un ClientHello y sin haber
    /// recibido una sola respuesta.
    func testACleanCloseOfATerminationThatSaidNothingAlsoRollsBack() async throws {
        let h = makeHarness()
        await establish(h)
        let hello = ClientHelloFixtures.clientHello(host: Self.host)
        await send(h, bytes: hello, sequence: Self.clientISN &+ 1)
        try await waitForTermination(h)

        h.inspector.openedTerminations[0].fireClose(nil)

        try await waitForRollback(h)
        XCTAssertEqual(h.factory.tcpConnections[1].sentStream, hello)
    }

    /// El límite de la vuelta atrás, y es el que la hace segura: en cuanto el dispositivo recibe un
    /// byte de la terminación su TLS está comprometido con nuestro leaf, así que sustituirla por una
    /// conexión llana lo dejaría hablando solo. A partir de ahí, una caída sí cuesta la conexión.
    func testOnceTheDeviceHasSeenTheTerminationThereIsNoWayBack() async throws {
        let h = makeHarness()
        await establish(h)
        await send(h, bytes: ClientHelloFixtures.clientHello(host: Self.host), sequence: Self.clientISN &+ 1)
        try await waitForTermination(h)

        let serverHello = Data([0x16, 0x03, 0x03, 0x00, 0x2A])
        h.inspector.openedTerminations[0].fireReceive(serverHello)
        try await awaitPayload(serverHello, in: h)

        h.inspector.openedTerminations[0].fireClose(RelayConnectionError("se cayó a mitad"))

        try await waitUntil("el flujo se derriba") { await h.relay.stats.tcpResetsToDevice == 1 }
        let stats = await h.relay.stats
        XCTAssertEqual(stats.terminationsRolledBack, 0)
        XCTAssertEqual(h.factory.tcpConnections.count, 1, "no se estrena conexión: ya no hay vuelta")
    }

    /// El FIN que el dispositivo mandó mientras la terminación vivía lo hereda quien la sustituye:
    /// el final va detrás de lo que mandó, igual que en la retención.
    func testADeviceFinDuringTheTerminationReachesTheConnectionThatTakesOver() async throws {
        let h = makeHarness()
        await establish(h)
        let hello = ClientHelloFixtures.clientHello(host: Self.host)
        await send(h, bytes: hello, sequence: Self.clientISN &+ 1)
        try await waitForTermination(h)

        await send(h, bytes: Data(), sequence: Self.clientISN &+ 1 &+ UInt32(hello.count),
                   flagsByte: RelayFixtures.TCPFlagByte.finAck)
        try await waitUntil("la terminación ve el EOF") { h.inspector.openedTerminations[0].isSendClosed }

        h.inspector.openedTerminations[0].fireClose(RelayConnectionError("la pila no levantó"))

        try await waitForRollback(h)
        XCTAssertEqual(h.factory.tcpConnections[1].sentStream, hello)
        XCTAssertTrue(h.factory.tcpConnections[1].isSendClosed)
    }
}
