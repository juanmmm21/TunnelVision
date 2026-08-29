import Foundation
import XCTest
import Shared

/// Tests del cableado del passthrough TCP en el actor `Relay` (M8). La máquina de estados pura
/// (`TCPRelayFlow`) tiene sus propios 21 tests; aquí se prueba que el `Relay` la **conduce**
/// correctamente contra la conexión saliente inyectada: abre la `NWConnection` al ver el SYN, difiere el
/// SYN-ACK hasta `ready`, extrae el stream del dispositivo hacia el servidor, re-segmenta el del
/// servidor hacia el dispositivo (con endpoints invertidos, serializado por `PacketEmitter`), hace
/// half-close y teardown, y traduce el rechazo del servidor en un RST hacia el dispositivo.
final class RelayTCPTests: XCTestCase {

    private static let clientISN: UInt32 = 1000
    private static let serverISN: UInt32 = 5000
    private static let localPort: UInt16 = 51000
    private static let remotePort: UInt16 = 443

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
            connectionFactory: factory,
            serverISNProvider: { Self.serverISN }
        )
        return Harness(relay: relay, factory: factory, reinjector: reinjector)
    }

    /// Parsea un datagrama reinyectado hacia el dispositivo y devuelve su cabecera TCP y el payload.
    private func parseReinjected(_ injected: RecordingReinjector.Injected) throws -> (tcp: TCPHeader, payload: Data) {
        let parsed = try PacketParser.parse(injected.datagram, protocolFamily: injected.family)
        // Sentido invertido: origen = servidor, destino = dispositivo.
        XCTAssertEqual(parsed.source, RelayFixtures.remoteV4Endpoint(port: Self.remotePort))
        XCTAssertEqual(parsed.destination, RelayFixtures.localV4Endpoint(port: Self.localPort))
        let tcp = try XCTUnwrap(parsed.tcp)
        return (tcp, Data(injected.datagram[tcp.payloadRange]))
    }

    private func syn() -> (ParsedPacket, Data) {
        RelayFixtures.tcpV4(localPort: Self.localPort, remotePort: Self.remotePort,
                            flagsByte: RelayFixtures.TCPFlagByte.syn, sequence: Self.clientISN)
    }

    /// Lleva el flujo hasta `established`: SYN → (ready) SYN-ACK diferido → ACK del handshake. Devuelve
    /// la conexión saliente doble. El SYN-ACK se drena aquí; los tests que lo inspeccionan lo hacen sin
    /// este helper.
    private func establish(_ h: Harness) async throws -> FakeRelayConnection {
        let (synPacket, synRaw) = syn()
        await h.relay.passthrough(synPacket, raw: synRaw)
        let connection = h.factory.tcpConnections[0]

        connection.fireReady()
        _ = await h.reinjector.next()   // drena el SYN-ACK diferido

        let (ackPacket, ackRaw) = RelayFixtures.tcpV4(
            localPort: Self.localPort, remotePort: Self.remotePort,
            flagsByte: RelayFixtures.TCPFlagByte.ack, sequence: Self.clientISN &+ 1, acknowledgment: Self.serverISN &+ 1)
        await h.relay.passthrough(ackPacket, raw: ackRaw)
        return connection
    }

    // MARK: - Handshake

    func testSynOpensConnectionAndDefersSynAck() async throws {
        let h = makeHarness()
        let (synPacket, synRaw) = syn()

        await h.relay.passthrough(synPacket, raw: synRaw)

        // Se abrió la conexión saliente TCP hacia el servidor, pero el SYN-ACK aún no se emite.
        XCTAssertEqual(h.factory.tcpConnections.count, 1)
        XCTAssertEqual(h.factory.tcpEndpoints[0], RelayFixtures.remoteV4Endpoint(port: Self.remotePort))
        let pending = await h.reinjector.count
        XCTAssertEqual(pending, 0)

        let stats = await h.relay.stats
        XCTAssertEqual(stats.tcpFlowsOpened, 1)
        XCTAssertEqual(stats.unsupportedPackets, 0)
        let activeTCP = await h.relay.activeTCPFlowCount
        XCTAssertEqual(activeTCP, 1)
    }

    func testSynAckIsEmittedOnceServerConnects() async throws {
        let h = makeHarness()
        let (synPacket, synRaw) = syn()
        await h.relay.passthrough(synPacket, raw: synRaw)

        h.factory.tcpConnections[0].fireReady()
        let injected = await h.reinjector.next()
        let (tcp, payload) = try parseReinjected(injected)

        XCTAssertTrue(tcp.flags.contains(.syn))
        XCTAssertTrue(tcp.flags.contains(.ack))
        XCTAssertEqual(tcp.sequence, Self.serverISN)            // nuestro ISN
        XCTAssertEqual(tcp.acknowledgment, Self.clientISN &+ 1) // ACK del SYN del dispositivo
        XCTAssertTrue(payload.isEmpty)

        let stats = await h.relay.stats
        XCTAssertEqual(stats.tcpSegmentsReinjected, 1)
    }

    // MARK: - Datos dispositivo → servidor

    func testDeviceDataIsForwardedToServerAndAcked() async throws {
        let h = makeHarness()
        let connection = try await establish(h)

        let hello: [UInt8] = Array("hello".utf8)
        let (dataPacket, dataRaw) = RelayFixtures.tcpV4(
            localPort: Self.localPort, remotePort: Self.remotePort,
            flagsByte: RelayFixtures.TCPFlagByte.pshAck, sequence: Self.clientISN &+ 1,
            acknowledgment: Self.serverISN &+ 1, payload: hello)
        await h.relay.passthrough(dataPacket, raw: dataRaw)

        // El stream saliente reensamblado llega al servidor tal cual.
        XCTAssertEqual(connection.sentStream, Data(hello))

        // Y el dispositivo recibe un ACK acumulado que cubre los bytes entregados.
        let injected = await h.reinjector.next()
        let (tcp, payload) = try parseReinjected(injected)
        XCTAssertTrue(tcp.flags.contains(.ack))
        XCTAssertEqual(tcp.acknowledgment, Self.clientISN &+ 1 &+ UInt32(hello.count))
        XCTAssertTrue(payload.isEmpty)

        let stats = await h.relay.stats
        XCTAssertEqual(stats.tcpBytesToServer, UInt64(hello.count))
    }

    // MARK: - Datos servidor → dispositivo

    func testServerDataIsResegmentedToDevice() async throws {
        let h = makeHarness()
        let connection = try await establish(h)

        let world = Data("world!".utf8)
        connection.fireReceive(world)

        let injected = await h.reinjector.next()
        let (tcp, payload) = try parseReinjected(injected)
        XCTAssertTrue(tcp.flags.contains(.ack))
        XCTAssertEqual(tcp.sequence, Self.serverISN &+ 1)  // primer byte de datos tras el SYN
        XCTAssertEqual(payload, world)

        let stats = await h.relay.stats
        XCTAssertGreaterThanOrEqual(stats.tcpSegmentsReinjected, 1)
    }

    // MARK: - Cierre limpio

    func testGracefulCloseHalfClosesServerThenTearsDown() async throws {
        let h = makeHarness()
        let connection = try await establish(h)

        // 1. El dispositivo manda FIN: se hace half-close del envío al servidor y se ACKea.
        let (finPacket, finRaw) = RelayFixtures.tcpV4(
            localPort: Self.localPort, remotePort: Self.remotePort,
            flagsByte: RelayFixtures.TCPFlagByte.finAck, sequence: Self.clientISN &+ 1,
            acknowledgment: Self.serverISN &+ 1)
        await h.relay.passthrough(finPacket, raw: finRaw)
        XCTAssertTrue(connection.isSendClosed)
        _ = await h.reinjector.next()   // ACK del FIN del dispositivo

        // 2. El servidor cierra (EOF): emitimos nuestro FIN hacia el dispositivo.
        connection.fireClose(nil)
        let finInjected = await h.reinjector.next()
        let (finTcp, _) = try parseReinjected(finInjected)
        XCTAssertTrue(finTcp.flags.contains(.fin))

        // 3. El dispositivo ACKea nuestro FIN: teardown completo.
        let (lastAckPacket, lastAckRaw) = RelayFixtures.tcpV4(
            localPort: Self.localPort, remotePort: Self.remotePort,
            flagsByte: RelayFixtures.TCPFlagByte.ack, sequence: Self.clientISN &+ 2,
            acknowledgment: finTcp.sequence &+ 1)
        await h.relay.passthrough(lastAckPacket, raw: lastAckRaw)

        XCTAssertTrue(connection.isCancelled)
        let activeTCP = await h.relay.activeTCPFlowCount
        XCTAssertEqual(activeTCP, 0)
        let stats = await h.relay.stats
        XCTAssertEqual(stats.tcpFlowsClosed, 1)
    }

    // MARK: - Rechazo y RST

    func testServerRefusalBeforeSynAckSendsResetToDevice() async throws {
        let h = makeHarness()
        let (synPacket, synRaw) = syn()
        await h.relay.passthrough(synPacket, raw: synRaw)

        // El servidor falla antes de que hayamos emitido el SYN-ACK: conexión rechazada.
        h.factory.tcpConnections[0].fireClose(RelayConnectionError("connection refused"))

        let injected = await h.reinjector.next()
        let (tcp, _) = try parseReinjected(injected)
        XCTAssertTrue(tcp.flags.contains(.rst))
        // RST que responde al SYN: seq 0, ack = clientISN+1 (como haría el servidor real).
        XCTAssertEqual(tcp.sequence, 0)
        XCTAssertEqual(tcp.acknowledgment, Self.clientISN &+ 1)

        XCTAssertTrue(h.factory.tcpConnections[0].isCancelled)
        let activeTCP = await h.relay.activeTCPFlowCount
        XCTAssertEqual(activeTCP, 0)
        let stats = await h.relay.stats
        XCTAssertEqual(stats.tcpResetsToDevice, 1)
        XCTAssertEqual(stats.tcpFlowsClosed, 1)
    }

    func testDeviceResetTearsDownWithoutReply() async throws {
        let h = makeHarness()
        let connection = try await establish(h)

        let (rstPacket, rstRaw) = RelayFixtures.tcpV4(
            localPort: Self.localPort, remotePort: Self.remotePort,
            flagsByte: RelayFixtures.TCPFlagByte.rst, sequence: Self.clientISN &+ 1)
        await h.relay.passthrough(rstPacket, raw: rstRaw)

        XCTAssertTrue(connection.isCancelled)
        let activeTCP = await h.relay.activeTCPFlowCount
        XCTAssertEqual(activeTCP, 0)
        // Un RST del dispositivo no se contesta: ningún segmento de respuesta.
        let pending = await h.reinjector.count
        XCTAssertEqual(pending, 0)
    }

    // MARK: - Cierre externo (FlowTable) y ciclo de vida

    func testCloseFromFlowTableCancelsTCPConnection() async throws {
        let h = makeHarness()
        let connection = try await establish(h)
        let (synPacket, _) = syn()

        await h.relay.close(synPacket.flowKey)

        XCTAssertTrue(connection.isCancelled)
        let activeTCP = await h.relay.activeTCPFlowCount
        XCTAssertEqual(activeTCP, 0)
    }

    func testCloseAllCancelsTCPAndUDPConnections() async throws {
        let h = makeHarness()
        let tcpConnection = try await establish(h)
        let (udpPacket, udpRaw) = RelayFixtures.udpV4(localPort: 40000)
        await h.relay.passthrough(udpPacket, raw: udpRaw)

        await h.relay.closeAll()

        XCTAssertTrue(tcpConnection.isCancelled)
        XCTAssertTrue(h.factory.connections.allSatisfy(\.isCancelled))
        let active = await h.relay.activeFlowCount
        XCTAssertEqual(active, 0)
    }
}
