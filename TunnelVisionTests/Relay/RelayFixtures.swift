import Foundation
import Shared

/// Dobles y constructores para los tests del relay (M8). Una `NWConnection` no se puede ejercitar en
/// Simulator, así que el relay corre contra `FakeRelayConnection`, que captura lo enviado y permite
/// disparar la conexión (ready), respuestas y cierres del "servidor" a demanda.
enum RelayFixtures {

    static let localV4Bytes: [UInt8] = [10, 0, 0, 2]
    static let remoteV4Bytes: [UInt8] = [93, 184, 216, 34]
    static let localV6Bytes: [UInt8] = [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01]
    static let remoteV6Bytes: [UInt8] = [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x02]

    static func localV4Endpoint(port: UInt16 = 53535) -> IPEndpoint {
        IPEndpoint(address: IPAddress(version: .v4, bytes: localV4Bytes), port: port)
    }

    static func remoteV4Endpoint(port: UInt16 = 53) -> IPEndpoint {
        IPEndpoint(address: IPAddress(version: .v4, bytes: remoteV4Bytes), port: port)
    }

    // MARK: - UDP

    /// Datagrama IPv4/UDP outbound (dispositivo → servidor), ya parseado, junto a su Data cruda:
    /// justo lo que el provider entrega a `Relay.passthrough`.
    static func udpV4(localPort: UInt16 = 53535, remotePort: UInt16 = 53, payload: [UInt8] = [0xAA, 0xBB]) -> (ParsedPacket, Data) {
        let raw = PacketFixtures.ipv4(
            proto: 17,
            source: localV4Bytes,
            destination: remoteV4Bytes,
            payload: PacketFixtures.udpDatagram(sourcePort: localPort, destinationPort: remotePort, payload: payload)
        )
        return (try! PacketParser.parse(raw, protocolFamily: Int32(AF_INET)), raw)
    }

    static func udpV6(localPort: UInt16 = 40000, remotePort: UInt16 = 443, payload: [UInt8] = [0x01, 0x02, 0x03]) -> (ParsedPacket, Data) {
        let raw = PacketFixtures.ipv6(
            nextHeader: 17,
            source: localV6Bytes,
            destination: remoteV6Bytes,
            payload: PacketFixtures.udpDatagram(sourcePort: localPort, destinationPort: remotePort, payload: payload)
        )
        return (try! PacketParser.parse(raw, protocolFamily: Int32(AF_INET6)), raw)
    }

    // MARK: - TCP

    /// Bytes de flags TCP más usados en los tests del passthrough.
    enum TCPFlagByte {
        static let syn: UInt8 = 0x02
        static let ack: UInt8 = 0x10
        static let pshAck: UInt8 = 0x18
        static let finAck: UInt8 = 0x11
        static let rst: UInt8 = 0x04
    }

    /// Segmento IPv4/TCP outbound (dispositivo → servidor) ya parseado, junto a su Data cruda. Cubre
    /// todo el handshake y el cierre según `flagsByte`, `sequence`, `acknowledgment` y `payload`.
    static func tcpV4(
        localPort: UInt16 = 51000,
        remotePort: UInt16 = 443,
        flagsByte: UInt8,
        sequence: UInt32,
        acknowledgment: UInt32 = 0,
        window: UInt16 = 65535,
        payload: [UInt8] = []
    ) -> (ParsedPacket, Data) {
        let raw = PacketFixtures.ipv4(
            proto: 6,
            source: localV4Bytes,
            destination: remoteV4Bytes,
            payload: PacketFixtures.tcpHeader(
                sourcePort: localPort,
                destinationPort: remotePort,
                sequence: sequence,
                acknowledgment: acknowledgment,
                flagsByte: flagsByte,
                window: window,
                payload: payload
            )
        )
        return (try! PacketParser.parse(raw, protocolFamily: Int32(AF_INET)), raw)
    }

    // MARK: - No soportado (ni TCP ni UDP)

    /// Datagrama IPv4/ICMP outbound: sirve para probar que el relay lo cuenta como no soportado (no
    /// tiene capa de transporte inspeccionable, así que `tcp` y `udp` son ambos `nil`).
    static func icmpV4() -> (ParsedPacket, Data) {
        let raw = PacketFixtures.ipv4(
            proto: 1,
            source: localV4Bytes,
            destination: remoteV4Bytes,
            payload: [0x08, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01]   // echo request
        )
        return (try! PacketParser.parse(raw, protocolFamily: Int32(AF_INET)), raw)
    }
}

/// Conexión saliente doble: guarda los handlers que le pasa el relay, registra lo enviado y expone
/// disparadores para simular la conexión (ready), respuestas y cierres del servidor. `@unchecked
/// Sendable` con lock porque el relay (actor) la toca desde su contexto y el test dispara desde el suyo.
final class FakeRelayConnection: RelayConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var onReady: (@Sendable () -> Void)?
    private var onReceive: (@Sendable (Data) -> Void)?
    private var onClose: (@Sendable (RelayConnectionError?) -> Void)?
    private var sent: [Data] = []
    private var sendClosed = false
    private var cancelled = false

    func start(
        onReady: @escaping @Sendable () -> Void,
        onReceive: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable (RelayConnectionError?) -> Void
    ) {
        lock.lock()
        self.onReady = onReady
        self.onReceive = onReceive
        self.onClose = onClose
        lock.unlock()
    }

    func send(_ data: Data) {
        lock.lock()
        sent.append(data)
        lock.unlock()
    }

    func closeSend() {
        lock.lock()
        sendClosed = true
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    // MARK: - Estado observable por el test

    var sentPayloads: [Data] {
        lock.lock(); defer { lock.unlock() }
        return sent
    }

    /// Todo lo enviado concatenado: útil para el stream TCP (los trozos no tienen fronteras).
    var sentStream: Data {
        lock.lock(); defer { lock.unlock() }
        return sent.reduce(into: Data()) { $0.append($1) }
    }

    var isSendClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return sendClosed
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    // MARK: - Disparadores del "servidor"

    /// Simula que la conexión saliente quedó establecida (para TCP dispara el SYN-ACK diferido).
    func fireReady() {
        lock.lock(); let handler = onReady; lock.unlock()
        handler?()
    }

    /// Simula un trozo de datos de respuesta del servidor.
    func fireReceive(_ data: Data) {
        lock.lock(); let handler = onReceive; lock.unlock()
        handler?(data)
    }

    /// Simula el cierre de la conexión (con error o limpio; limpio = EOF/FIN de recepción).
    func fireClose(_ error: RelayConnectionError?) {
        lock.lock(); let handler = onClose; lock.unlock()
        handler?(error)
    }
}

/// Fábrica doble: crea `FakeRelayConnection`s (UDP o TCP) y las conserva para que el test dispare
/// eventos del servidor.
final class FakeConnectionFactory: RelayConnectionFactory, @unchecked Sendable {
    enum Kind { case udp, tcp }

    private let lock = NSLock()
    private var created: [(kind: Kind, endpoint: IPEndpoint, connection: FakeRelayConnection)] = []

    func makeUDPConnection(to endpoint: IPEndpoint) -> RelayConnection {
        make(.udp, to: endpoint)
    }

    func makeTCPConnection(to endpoint: IPEndpoint) -> RelayConnection {
        make(.tcp, to: endpoint)
    }

    private func make(_ kind: Kind, to endpoint: IPEndpoint) -> RelayConnection {
        let connection = FakeRelayConnection()
        lock.lock()
        created.append((kind, endpoint, connection))
        lock.unlock()
        return connection
    }

    /// Todas las conexiones creadas, en orden. Los tests de un solo protocolo indexan directamente.
    var connections: [FakeRelayConnection] {
        lock.lock(); defer { lock.unlock() }
        return created.map(\.connection)
    }

    var tcpConnections: [FakeRelayConnection] {
        lock.lock(); defer { lock.unlock() }
        return created.filter { $0.kind == .tcp }.map(\.connection)
    }

    var endpoints: [IPEndpoint] {
        lock.lock(); defer { lock.unlock() }
        return created.map(\.endpoint)
    }

    var tcpEndpoints: [IPEndpoint] {
        lock.lock(); defer { lock.unlock() }
        return created.filter { $0.kind == .tcp }.map(\.endpoint)
    }
}

/// Interceptor doble: en vez de montar una terminación TLS de verdad devuelve una
/// `FakeRelayConnection`, que es lo que el relay ve de una (una terminación **es** un
/// `RelayConnection`). Guarda lo que se le pidió, conserva los `onResolve` para que el test dispare
/// el desenlace cuando quiera, y puede fallar o quedarse esperando en una puerta.
final class FakeFlowInspector: FlowInspecting, @unchecked Sendable {

    struct Request: Sendable, Equatable {
        let endpoint: IPEndpoint
        let sni: String?
    }

    private let lock = NSLock()
    private var requests: [Request] = []
    private var terminations: [FakeRelayConnection] = []
    private var resolvers: [@Sendable (TLSInterceptionPolicy.Decision) -> Void] = []
    /// Los sumideros de contenido en claro que el relay le pasó, uno por `open`. Un `nil` guardado es
    /// un hecho que hay que poder afirmar —significa que esa terminación no va a copiar ni un byte—,
    /// así que se conservan también los ausentes.
    private var plaintextSinks: [(@Sendable (Data, Direction) -> Void)?] = []
    private var failure: TLSInterceptError?
    private var gate: AsyncGate?

    /// Hace que el siguiente `open` lance en vez de construir nada (razón transitoria).
    func fail(with error: TLSInterceptError) {
        lock.lock(); failure = error; lock.unlock()
    }

    /// Detiene `open` en una puerta hasta que el test la abra: es lo que deja mirar el hueco en el
    /// que el flujo ya tiene nombre pero todavía no tiene terminación.
    func hold(at gate: AsyncGate) {
        lock.lock(); self.gate = gate; lock.unlock()
    }

    func open(
        to endpoint: IPEndpoint,
        clientHelloSNI: String?,
        plaintext: (@Sendable (Data, Direction) -> Void)?,
        onResolve: @escaping @Sendable (TLSInterceptionPolicy.Decision) -> Void
    ) async throws -> any RelayConnection {
        // Tomar el candado va en métodos síncronos a propósito: no se puede sostener a través de un
        // `await`, y aquí hay uno (la puerta).
        let (failure, gate) = record(Request(endpoint: endpoint, sni: clientHelloSNI), plaintext: plaintext)

        if let gate { await gate.wait() }
        if let failure { throw failure }

        return store(onResolve)
    }

    private func record(
        _ request: Request,
        plaintext: (@Sendable (Data, Direction) -> Void)?
    ) -> (TLSInterceptError?, AsyncGate?) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        plaintextSinks.append(plaintext)
        return (failure, gate)
    }

    private func store(_ resolver: @escaping @Sendable (TLSInterceptionPolicy.Decision) -> Void) -> FakeRelayConnection {
        let termination = FakeRelayConnection()
        lock.lock()
        defer { lock.unlock() }
        terminations.append(termination)
        resolvers.append(resolver)
        return termination
    }

    // MARK: - Estado observable por el test

    var openRequests: [Request] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    var openedTerminations: [FakeRelayConnection] {
        lock.lock(); defer { lock.unlock() }
        return terminations
    }

    /// Si la última terminación pedida llegó con sumidero de contenido en claro, que es la forma que
    /// tiene el interruptor del ADR 0007 de manifestarse aquí abajo.
    var lastRequestHadPlaintextSink: Bool {
        lock.lock(); defer { lock.unlock() }
        return plaintextSinks.last.map { $0 != nil } ?? false
    }

    /// Simula un trozo descifrado saliendo de la terminación `index`, que es lo que hace la de verdad
    /// con cada pedazo de plaintext antes de reenviarlo.
    func emitPlaintext(_ data: Data, _ direction: Direction, at index: Int = 0) {
        lock.lock()
        let sink = plaintextSinks.indices.contains(index) ? plaintextSinks[index] : nil
        lock.unlock()
        sink?(data, direction)
    }

    /// Dispara el desenlace de la terminación `index`, como haría el final de un flujo real.
    func resolve(_ decision: TLSInterceptionPolicy.Decision, at index: Int = 0) {
        lock.lock(); let resolver = resolvers.indices.contains(index) ? resolvers[index] : nil; lock.unlock()
        resolver?(decision)
    }
}

/// Puerta asíncrona de un solo sentido: `wait()` suspende hasta que alguien llama a `open()`, y a
/// partir de ahí no suspende más. Sirve para congelar un `await` del código bajo prueba y mirar el
/// estado intermedio, que de otro modo no dura lo bastante para afirmar nada sobre él.
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

/// Observador doble del estado de inspección de los flujos: la mitad del enganche que le cuenta a la
/// tabla de flujos cómo acabó cada intento.
actor RecordingTLSStatusObserver: TLSStatusObserving {
    struct Observed: Sendable, Equatable {
        let status: TLSInspectionStatus
        let key: FlowKey
    }

    private(set) var observed: [Observed] = []

    func observe(tlsStatus: TLSInspectionStatus, for key: FlowKey) async {
        observed.append(Observed(status: tlsStatus, key: key))
    }
}

/// Reinyector grabador: recoge los datagramas que el relay devuelve al dispositivo. `next()` suspende
/// hasta que llega uno (vía continuación), así que los tests son deterministas sin polling.
actor RecordingReinjector {
    struct Injected: Sendable {
        let datagram: Data
        let family: Int32
    }

    private var buffer: [Injected] = []
    private var waiters: [CheckedContinuation<Injected, Never>] = []

    func record(datagram: Data, family: Int32) {
        let injected = Injected(datagram: datagram, family: family)
        if waiters.isEmpty {
            buffer.append(injected)
        } else {
            waiters.removeFirst().resume(returning: injected)
        }
    }

    func next() async -> Injected {
        if !buffer.isEmpty {
            return buffer.removeFirst()
        }
        return await withCheckedContinuation { waiters.append($0) }
    }

    var count: Int { buffer.count }
}
