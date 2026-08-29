import Foundation
import XCTest
import Shared

/// Tests de la máquina de estados TCP en userspace (`TCPRelayFlow`, M8, passthrough TCP). Cubren el
/// handshake (SYN → connect diferido → SYN-ACK → established), el reenvío del stream del dispositivo con
/// ACK acumulado (en orden, fuera de orden y retransmitido), la segmentación del stream del servidor
/// respetando MSS y la ventana del dispositivo, el cierre limpio en ambos órdenes, el RST del
/// dispositivo, el fallo/rechazo del servidor, las degradaciones acotadas (desborde del reensamblador y
/// del buffer hacia el dispositivo) y el wraparound de secuencias. Un test cierra el círculo emitiendo
/// un segmento con `PacketEmitter` y reparseándolo con `PacketParser`.
final class TCPRelayFlowTests: XCTestCase {

    // MARK: - Constructores de segmentos entrantes

    private func syn(seq: UInt32, window: UInt16 = 65535) -> InboundSegment {
        InboundSegment(sequence: seq, acknowledgment: 0, flags: [.syn], window: window)
    }

    private func ack(seq: UInt32, ack: UInt32, window: UInt16 = 65535) -> InboundSegment {
        InboundSegment(sequence: seq, acknowledgment: ack, flags: [.ack], window: window)
    }

    private func data(seq: UInt32, ack: UInt32, window: UInt16 = 65535, _ payload: [UInt8]) -> InboundSegment {
        InboundSegment(sequence: seq, acknowledgment: ack, flags: [.ack, .psh], window: window, payload: Data(payload))
    }

    private func fin(seq: UInt32, ack: UInt32, window: UInt16 = 65535) -> InboundSegment {
        InboundSegment(sequence: seq, acknowledgment: ack, flags: [.fin, .ack], window: window)
    }

    private func rst(seq: UInt32) -> InboundSegment {
        InboundSegment(sequence: seq, acknowledgment: 0, flags: [.rst], window: 0)
    }

    /// Lleva un flujo recién creado hasta `established`. Devuelve el flujo listo para la fase de datos.
    private func established(
        serverISN: UInt32 = 1000,
        clientISN: UInt32 = 5000,
        deviceWindow: UInt16 = 65535,
        config: TCPRelayFlow.Config = TCPRelayFlow.Config()
    ) -> TCPRelayFlow {
        var flow = TCPRelayFlow(config: config, serverISN: serverISN)
        _ = flow.receiveFromDevice(syn(seq: clientISN, window: deviceWindow))
        _ = flow.serverDidConnect()
        _ = flow.receiveFromDevice(ack(seq: clientISN &+ 1, ack: serverISN &+ 1, window: deviceWindow))
        XCTAssertEqual(flow.state, .established)
        return flow
    }

    private func outbound(_ seq: UInt32, _ ack: UInt32, _ flags: TCPFlags, _ window: UInt16, _ payload: [UInt8] = []) -> TCPRelayAction {
        .segmentToDevice(OutboundSegment(sequence: seq, acknowledgment: ack, flags: flags, window: window, payload: Data(payload)))
    }

    // MARK: - Handshake

    func testSynTriggersServerConnectAndDefersSynAck() {
        var flow = TCPRelayFlow(serverISN: 1000)
        let actions = flow.receiveFromDevice(syn(seq: 5000))
        XCTAssertEqual(actions, [.connectToServer])
        XCTAssertEqual(flow.state, .connecting)
    }

    func testServerConnectSendsSynAck() {
        var flow = TCPRelayFlow(serverISN: 1000)
        _ = flow.receiveFromDevice(syn(seq: 5000))
        let actions = flow.serverDidConnect()
        XCTAssertEqual(actions, [outbound(1000, 5001, [.syn, .ack], 65535)])
        XCTAssertEqual(flow.state, .synReceived)
    }

    func testHandshakeCompletesOnDeviceAck() {
        var flow = TCPRelayFlow(serverISN: 1000)
        _ = flow.receiveFromDevice(syn(seq: 5000))
        _ = flow.serverDidConnect()
        let actions = flow.receiveFromDevice(ack(seq: 5001, ack: 1001))
        XCTAssertEqual(actions, [])
        XCTAssertEqual(flow.state, .established)
    }

    func testRetransmittedSynResendsSynAck() {
        var flow = TCPRelayFlow(serverISN: 1000)
        _ = flow.receiveFromDevice(syn(seq: 5000))
        _ = flow.serverDidConnect()
        let actions = flow.receiveFromDevice(syn(seq: 5000))
        XCTAssertEqual(actions, [outbound(1000, 5001, [.syn, .ack], 65535)])
        XCTAssertEqual(flow.state, .synReceived)
    }

    func testServerRefusalBeforeHandshakeRstsToDevice() {
        var flow = TCPRelayFlow(serverISN: 1000)
        _ = flow.receiveFromDevice(syn(seq: 5000))
        let actions = flow.serverDidFail()
        // Rechazo de conexión: RST+ACK en respuesta al SYN (seq 0, ack = clientISN+1), como el servidor.
        XCTAssertEqual(actions, [outbound(0, 5001, [.rst, .ack], 0), .teardown])
        XCTAssertEqual(flow.state, .closed)
    }

    // MARK: - Dispositivo → servidor

    func testDeviceDataForwardedAndAcked() {
        var flow = established()
        let actions = flow.receiveFromDevice(data(seq: 5001, ack: 1001, [0x01, 0x02, 0x03]))
        XCTAssertEqual(actions, [
            .sendToServer(Data([0x01, 0x02, 0x03])),
            outbound(1001, 5004, [.ack], 65535),
        ])
    }

    func testOutOfOrderDeviceDataBuffersThenDeliversInOrder() {
        var flow = established()
        // Segmento adelantado (falta [5001,5004)): se bufferiza y se manda un dup-ACK del hueco.
        let gap = flow.receiveFromDevice(data(seq: 5004, ack: 1001, [0x04, 0x05, 0x06]))
        XCTAssertEqual(gap, [outbound(1001, 5001, [.ack], 65535)])

        // Llega el hueco: se entrega todo en orden y se ACKea el frente avanzado.
        let fill = flow.receiveFromDevice(data(seq: 5001, ack: 1001, [0x01, 0x02, 0x03]))
        XCTAssertEqual(fill, [
            .sendToServer(Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06])),
            outbound(1001, 5007, [.ack], 65535),
        ])
    }

    func testRetransmittedDeviceDataNotForwardedTwice() {
        var flow = established()
        _ = flow.receiveFromDevice(data(seq: 5001, ack: 1001, [0x01, 0x02, 0x03]))
        let again = flow.receiveFromDevice(data(seq: 5001, ack: 1001, [0x01, 0x02, 0x03]))
        // Sin reenvío al servidor: solo un ACK del mismo punto acumulado.
        XCTAssertEqual(again, [outbound(1001, 5004, [.ack], 65535)])
    }

    // MARK: - Servidor → dispositivo

    func testServerDataSegmentedToDevice() {
        var flow = established()
        let actions = flow.receiveFromServer(Data([0xAA, 0xBB, 0xCC]))
        XCTAssertEqual(actions, [outbound(1001, 5001, [.ack, .psh], 65535, [0xAA, 0xBB, 0xCC])])
    }

    func testServerDataSplitByMSS() {
        var config = TCPRelayFlow.Config()
        config.mss = 2
        var flow = established(config: config)
        let actions = flow.receiveFromServer(Data([1, 2, 3, 4, 5]))
        XCTAssertEqual(actions, [
            outbound(1001, 5001, [.ack, .psh], 65535, [1, 2]),
            outbound(1003, 5001, [.ack, .psh], 65535, [3, 4]),
            outbound(1005, 5001, [.ack, .psh], 65535, [5]),
        ])
    }

    func testServerDataLimitedByDeviceWindowThenDrains() {
        var flow = established(deviceWindow: 3)
        // La ventana del dispositivo (3) solo limita cuántos bytes van en vuelo: se emiten 3 y se
        // retienen 2. La ventana anunciada en el segmento es la nuestra (advertisedWindow), no la suya.
        let first = flow.receiveFromServer(Data([1, 2, 3, 4, 5]))
        XCTAssertEqual(first, [outbound(1001, 5001, [.ack, .psh], 65535, [1, 2, 3])])

        // El dispositivo ACKea los 3 (abre la ventana): se drenan los 2 pendientes.
        let drained = flow.receiveFromDevice(ack(seq: 5001, ack: 1004, window: 3))
        XCTAssertEqual(drained, [outbound(1004, 5001, [.ack, .psh], 65535, [4, 5])])
    }

    // MARK: - Cierre

    func testDeviceFinAcksAndClosesServerSend() {
        var flow = established()
        let actions = flow.receiveFromDevice(fin(seq: 5001, ack: 1001))
        XCTAssertEqual(actions, [
            .closeServerSend,
            outbound(1001, 5002, [.ack], 65535),
        ])
        XCTAssertEqual(flow.state, .closing)
    }

    func testDataAndFinInSameSegment() {
        var flow = established()
        let segment = InboundSegment(sequence: 5001, acknowledgment: 1001, flags: [.ack, .psh, .fin], window: 65535, payload: Data([0x01, 0x02, 0x03]))
        let actions = flow.receiveFromDevice(segment)
        XCTAssertEqual(actions, [
            .sendToServer(Data([0x01, 0x02, 0x03])),
            .closeServerSend,
            outbound(1001, 5005, [.ack], 65535),
        ])
        XCTAssertEqual(flow.state, .closing)
    }

    func testGracefulCloseDeviceFirst() {
        var flow = established()
        // 1. El dispositivo cierra su envío.
        _ = flow.receiveFromDevice(fin(seq: 5001, ack: 1001))
        // 2. El servidor cierra: emitimos FIN al dispositivo.
        let serverClose = flow.serverDidClose()
        XCTAssertEqual(serverClose, [outbound(1001, 5002, [.fin, .ack], 65535)])
        // 3. El dispositivo ACKea nuestro FIN: el flujo se derriba.
        let teardown = flow.receiveFromDevice(ack(seq: 5002, ack: 1002))
        XCTAssertEqual(teardown, [.teardown])
        XCTAssertEqual(flow.state, .closed)
    }

    func testGracefulCloseServerFirst() {
        var flow = established()
        // 1. El servidor cierra primero: FIN al dispositivo.
        let serverClose = flow.serverDidClose()
        XCTAssertEqual(serverClose, [outbound(1001, 5001, [.fin, .ack], 65535)])
        // 2. El dispositivo ACKea nuestro FIN pero aún no cierra su lado: nada que derribar.
        let ackOnly = flow.receiveFromDevice(ack(seq: 5001, ack: 1002))
        XCTAssertEqual(ackOnly, [])
        XCTAssertEqual(flow.state, .closing)
        // 3. El dispositivo cierra su lado: ACK del FIN, cierre del envío al servidor y derribo.
        let deviceFin = flow.receiveFromDevice(fin(seq: 5001, ack: 1002))
        XCTAssertEqual(deviceFin, [
            .closeServerSend,
            outbound(1002, 5002, [.ack], 65535),
            .teardown,
        ])
        XCTAssertEqual(flow.state, .closed)
    }

    func testDeviceRstTearsDownWithoutReply() {
        var flow = established()
        let actions = flow.receiveFromDevice(rst(seq: 5001))
        XCTAssertEqual(actions, [.teardown])
        XCTAssertEqual(flow.state, .closed)
    }

    func testServerFailureMidConnectionRstsToDevice() {
        var flow = established()
        let actions = flow.serverDidFail()
        XCTAssertEqual(actions, [outbound(1001, 5001, [.rst, .ack], 0), .teardown])
        XCTAssertEqual(flow.state, .closed)
    }

    // MARK: - Degradaciones acotadas

    func testReassemblerDowngradeAbortsFlow() {
        var config = TCPRelayFlow.Config()
        config.reassembly = TCPReassembler.Config(maxBufferedBytes: 256 * 1024, maxOutOfOrderSegments: 1)
        var flow = established(config: config)

        // Primer fuera de orden: se bufferiza (1 fragmento, el techo).
        _ = flow.receiveFromDevice(data(seq: 5004, ack: 1001, [0x0A]))
        // Segundo fuera de orden disjunto: supera el tope de fragmentos ⇒ downgrade ⇒ abortar con RST.
        let actions = flow.receiveFromDevice(data(seq: 5010, ack: 1001, [0x0B]))
        XCTAssertEqual(actions, [outbound(1001, 5001, [.rst, .ack], 0), .teardown])
        XCTAssertEqual(flow.state, .closed)
    }

    func testPendingToDeviceOverflowAbortsFlow() {
        var config = TCPRelayFlow.Config()
        config.maxPendingToDeviceBytes = 4
        // Ventana cerrada (0): nada se emite, todo queda pendiente y supera el techo.
        var flow = established(deviceWindow: 0, config: config)
        let actions = flow.receiveFromServer(Data([1, 2, 3, 4, 5]))
        XCTAssertEqual(actions, [outbound(1001, 5001, [.rst, .ack], 0), .teardown])
        XCTAssertEqual(flow.state, .closed)
    }

    // MARK: - Aritmética serial

    func testSequenceWraparound() {
        let serverISN: UInt32 = 0xFFFF_FFFE
        let clientISN: UInt32 = 0xFFFF_FFFA
        var flow = established(serverISN: serverISN, clientISN: clientISN)

        // Servidor → dispositivo: sendNext = serverISN+1 = 0xFFFFFFFF; 3 bytes dan la vuelta a 0x2.
        let out = flow.receiveFromServer(Data([1, 2, 3]))
        XCTAssertEqual(out, [outbound(0xFFFF_FFFF, clientISN &+ 1, [.ack, .psh], 65535, [1, 2, 3])])

        // Dispositivo → servidor: expected = clientISN+1 = 0xFFFFFFFB; el ACK y el sendNext ya envueltos.
        let inbound = flow.receiveFromDevice(data(seq: clientISN &+ 1, ack: 0x2, [0x09, 0x09]))
        XCTAssertEqual(inbound, [
            .sendToServer(Data([0x09, 0x09])),
            outbound(0x2, clientISN &+ 3, [.ack], 65535),
        ])
    }

    // MARK: - Round-trip con el emisor y el parser

    func testOutboundSegmentRoundTripsThroughEmitterAndParser() throws {
        var flow = established()
        let actions = flow.receiveFromServer(Data([0xDE, 0xAD, 0xBE, 0xEF]))
        guard case .segmentToDevice(let segment) = actions.first else {
            return XCTFail("Se esperaba un segmento hacia el dispositivo")
        }

        // El relay serializará con origen = servidor y destino = dispositivo (sentido invertido).
        let server = IPEndpoint(address: IPAddress(version: .v4, bytes: [93, 184, 216, 34]), port: 443)
        let device = IPEndpoint(address: IPAddress(version: .v4, bytes: [10, 0, 0, 2]), port: 51000)
        let datagram = try PacketEmitter.tcp(
            source: server,
            destination: device,
            sequence: segment.sequence,
            acknowledgment: segment.acknowledgment,
            flags: segment.flags,
            windowSize: segment.window,
            payload: segment.payload
        )

        let parsed = try PacketParser.parse(datagram, protocolFamily: Int32(AF_INET))
        let tcp = try XCTUnwrap(parsed.tcp)
        XCTAssertEqual(parsed.source, server)
        XCTAssertEqual(parsed.destination, device)
        XCTAssertEqual(tcp.sequence, segment.sequence)
        XCTAssertEqual(tcp.acknowledgment, segment.acknowledgment)
        XCTAssertEqual(tcp.flags, [.ack, .psh])
        XCTAssertEqual(tcp.windowSize, segment.window)
        XCTAssertEqual(Data(datagram[tcp.payloadRange]), Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }
}
