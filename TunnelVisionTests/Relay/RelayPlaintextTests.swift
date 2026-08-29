import Foundation
import XCTest
import Shared

/// Tests del **sumidero de contenido descifrado en el relay**: la mitad del cableado que decide si
/// una terminación copia lo que descifra, y que lo entrega en orden a quien lo guarda.
///
/// Lo que solo el relay puede contestar es esto: que sin permiso del usuario la terminación se abre
/// **sin sumidero** (y entonces no se copia ni un byte), que el trozo llega etiquetado con la
/// `FlowKey` de su flujo, que el orden de la conversación se conserva aunque los trozos entren desde
/// fuera del actor, y que apagar el interruptor deja de grabar en el acto.
final class RelayPlaintextTests: XCTestCase {

    private static let clientISN: UInt32 = 1000
    private static let serverISN: UInt32 = 5000
    private static let host = "www.example.com"

    private struct Harness {
        let relay: Relay
        let factory: FakeConnectionFactory
        let inspector: FakeFlowInspector
        let plaintext: RecordingPlaintextObserver
    }

    private func makeHarness(persisting: Bool) -> Harness {
        let factory = FakeConnectionFactory()
        let inspector = FakeFlowInspector()
        let plaintext = RecordingPlaintextObserver()
        let relay = Relay(
            reinject: { _, _ in },
            connectionFactory: factory,
            inspector: inspector,
            statusObserver: RecordingTLSStatusObserver(),
            plaintextObserver: plaintext,
            plaintextPersistenceEnabled: persisting,
            serverISNProvider: { Self.serverISN }
        )
        return Harness(relay: relay, factory: factory, inspector: inspector, plaintext: plaintext)
    }

    // MARK: - Conducción del flujo

    /// Lleva un flujo candidato hasta tener terminación instalada, que es cuando existe el sumidero.
    private func terminate(_ h: Harness, localPort: UInt16 = 51000) async {
        let (syn, synRaw) = RelayFixtures.tcpV4(
            localPort: localPort, flagsByte: RelayFixtures.TCPFlagByte.syn, sequence: Self.clientISN)
        await h.relay.inspect(syn, raw: synRaw)
        h.factory.tcpConnections.last?.fireReady()

        let (ack, ackRaw) = RelayFixtures.tcpV4(
            localPort: localPort, flagsByte: RelayFixtures.TCPFlagByte.ack,
            sequence: Self.clientISN &+ 1, acknowledgment: Self.serverISN &+ 1)
        await h.relay.inspect(ack, raw: ackRaw)

        let hello = ClientHelloFixtures.clientHello(host: Self.host)
        let (packet, raw) = RelayFixtures.tcpV4(
            localPort: localPort, flagsByte: RelayFixtures.TCPFlagByte.pshAck,
            sequence: Self.clientISN &+ 1, acknowledgment: Self.serverISN &+ 1, payload: [UInt8](hello))
        await h.relay.inspect(packet, raw: raw)

        // La terminación se construye en una tarea: se espera a que el interceptor la haya servido.
        await waitUntil { h.inspector.openRequests.count == 1 }
    }

    private func waitUntil(
        _ condition: () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        // Espera por sondeo con tope generoso: lo que se persigue es un salto de tarea, no una
        // duración, así que el tope solo existe para que un fallo no cuelgue la suite.
        for _ in 0 ..< 2_000 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("la condición no se cumplió a tiempo", file: file, line: line)
    }

    private func key(localPort: UInt16 = 51000) -> FlowKey {
        FlowKey(
            proto: .tcp,
            source: RelayFixtures.localV4Endpoint(port: localPort),
            destination: RelayFixtures.remoteV4Endpoint(port: 443)
        )
    }

    // MARK: - El interruptor

    /// Apagado —lo de fábrica, ADR 0007— la terminación se abre **sin sumidero**: no es que se tire
    /// lo descifrado, es que no se copia.
    func testWithoutPermissionNoSinkIsHandedToTheTermination() async {
        let h = makeHarness(persisting: false)
        await terminate(h)

        XCTAssertFalse(h.inspector.lastRequestHadPlaintextSink)
    }

    func testWithPermissionTheTerminationGetsASink() async {
        let h = makeHarness(persisting: true)
        await terminate(h)

        XCTAssertTrue(h.inspector.lastRequestHadPlaintextSink)
    }

    /// El trozo llega con la `FlowKey` de su flujo y su sentido: es lo único que el relay sabe de él,
    /// y es exactamente lo que el pipeline necesita para colgarlo de una fila.
    func testChunksReachTheObserverTaggedWithTheirFlow() async {
        let h = makeHarness(persisting: true)
        await terminate(h)

        h.inspector.emitPlaintext(Data("GET /".utf8), .outbound)
        h.inspector.emitPlaintext(Data("200 OK".utf8), .inbound)
        await waitUntil { await h.plaintext.observed.count == 2 }

        let observed = await h.plaintext.observed
        XCTAssertEqual(observed.map(\.key), [key(), key()])
        XCTAssertEqual(observed.map(\.direction), [.outbound, .inbound])
        XCTAssertEqual(observed.map(\.data), [Data("GET /".utf8), Data("200 OK".utf8)])
    }

    /// **El orden es la conversación.** Los trozos entran desde fuera del actor —las dos patas de la
    /// terminación tienen sus propias colas—, así que sin la cola serial llegarían barajados y lo
    /// guardado diría algo que nadie escribió.
    func testChunkOrderIsPreserved() async {
        let h = makeHarness(persisting: true)
        await terminate(h)

        let expected = (0 ..< 40).map { Data("chunk-\($0)".utf8) }
        for chunk in expected {
            h.inspector.emitPlaintext(chunk, .outbound)
        }
        await waitUntil { await h.plaintext.observed.count == expected.count }

        let observed = await h.plaintext.observed
        XCTAssertEqual(observed.map(\.data), expected)
    }

    /// Apagar la persistencia deja de grabar **en el acto**, incluso lo que ya estaba en camino: un
    /// usuario que revoca el permiso de guardar lo que dice por dentro no puede esperar a que acaben
    /// sus conexiones. (Encenderla, en cambio, empieza a valer en el flujo siguiente.)
    func testTurningPersistenceOffStopsRecordingImmediately() async {
        let h = makeHarness(persisting: true)
        await terminate(h)

        h.inspector.emitPlaintext(Data("antes".utf8), .outbound)
        await waitUntil { await h.plaintext.observed.count == 1 }

        await h.relay.setPlaintextPersistenceEnabled(false)
        h.inspector.emitPlaintext(Data("después".utf8), .outbound)

        // Se le da tiempo de sobra a la cola para entregarlo, y aun así no llega.
        try? await Task.sleep(for: .milliseconds(50))
        let observed = await h.plaintext.observed
        XCTAssertEqual(observed.map(\.data), [Data("antes".utf8)])
        let stats = await h.relay.stats
        XCTAssertEqual(stats.plaintextChunksObserved, 1)
    }

    /// Parar el túnel **vacía la cola** antes de soltarla: son bytes que el usuario ya descifró y que
    /// están a un salto de su fichero.
    func testClosingAllDrainsTheQueue() async {
        let h = makeHarness(persisting: true)
        await terminate(h)

        for index in 0 ..< 20 {
            h.inspector.emitPlaintext(Data("chunk-\(index)".utf8), .inbound)
        }
        await h.relay.closeAll()

        let drained = await h.plaintext.observed
        XCTAssertEqual(drained.count, 20)
    }

    /// Sin permiso no hay ni cola: no se arranca una tarea de fondo por si acaso.
    func testNothingIsObservedWithoutPermission() async {
        let h = makeHarness(persisting: false)
        await terminate(h)

        h.inspector.emitPlaintext(Data("nada".utf8), .outbound)
        try? await Task.sleep(for: .milliseconds(50))

        let observed = await h.plaintext.observed
        XCTAssertEqual(observed.count, 0)
        let stats = await h.relay.stats
        XCTAssertEqual(stats.plaintextChunksObserved, 0)
    }
}

/// Observador doble del contenido descifrado. Es un actor, como la conformidad de producción
/// (`PacketPipeline`), para que el orden que la cola del relay promete se pueda afirmar.
actor RecordingPlaintextObserver: PlaintextObserving {
    struct Observed: Sendable, Equatable {
        let data: Data
        let direction: Direction
        let key: FlowKey
    }

    private(set) var observed: [Observed] = []

    func observe(plaintext: Data, direction: Direction, for key: FlowKey) async {
        observed.append(Observed(data: plaintext, direction: direction, key: key))
    }
}
