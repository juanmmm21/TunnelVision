import Foundation
import Shared

/// Doble guionizado de `TunnelProviderManaging` (M9).
///
/// Sustituye a `NETunnelProviderManagerAdapter`, que necesita dispositivo, entitlement y el diálogo
/// del sistema. Guarda el status que devuelve `loadStatus`, registra las llamadas en orden para poder
/// afirmar sobre la secuencia (instalar **antes** de arrancar, no arrancar tras una denegación) y
/// permite guionizar el error de cada operación.
///
/// Es un `actor` porque el controlador lo usa desde el `MainActor` y sus contadores se leen desde los
/// tests: la serialización la da el actor, no un candado a mano.
actor FakeTunnelProviderManager: TunnelProviderManaging {

    /// Llamadas recibidas, en orden.
    enum Call: Equatable {
        case loadStatus
        case install(TunnelConfiguration)
        case start
        case stop
        case sendControl(Data)
    }

    private(set) var calls: [Call] = []

    /// Status que devuelve `loadStatus`. Los tests lo cambian para simular el efecto de `install`.
    private var status: TunnelStatus
    private var installError: TunnelControlError?
    private var startError: TunnelControlError?
    private var stopError: TunnelControlError?
    private var loadError: TunnelControlError?
    private var controlOutcome: Result<Data?, TunnelControlError> = .success(nil)
    /// Status al que salta `loadStatus` después de un `install` con éxito, como haría el sistema.
    private var statusAfterInstall: TunnelStatus = .disconnected
    /// Status al que salta `loadStatus` después de un `stop` con éxito.
    private var statusAfterStop: TunnelStatus = .disconnected

    /// El stream de status y su continuación son inmutables y `Sendable`, así que `statusUpdates()`
    /// puede ser `nonisolated` (el protocolo no la declara `async`).
    private nonisolated let stream: AsyncStream<TunnelStatus>
    private nonisolated let continuation: AsyncStream<TunnelStatus>.Continuation

    init(status: TunnelStatus = .notInstalled) {
        self.status = status
        (stream, continuation) = AsyncStream<TunnelStatus>.makeStream()
    }

    // MARK: - Guion

    func setStatus(_ status: TunnelStatus) { self.status = status }
    func setStatusAfterInstall(_ status: TunnelStatus) { statusAfterInstall = status }
    func setStatusAfterStop(_ status: TunnelStatus) { statusAfterStop = status }
    func setInstallError(_ error: TunnelControlError?) { installError = error }
    func setStartError(_ error: TunnelControlError?) { startError = error }
    func setStopError(_ error: TunnelControlError?) { stopError = error }
    func setLoadError(_ error: TunnelControlError?) { loadError = error }
    func setControlOutcome(_ outcome: Result<Data?, TunnelControlError>) { controlOutcome = outcome }

    /// Empuja un cambio de status como haría el observador del sistema.
    nonisolated func emit(_ status: TunnelStatus) { continuation.yield(status) }

    /// Cierra el stream, como cuando la cáscara se libera.
    nonisolated func finishStatusUpdates() { continuation.finish() }

    /// Comandos decodificados de lo enviado por el canal, para comprobar que viajó el comando real y
    /// no unos bytes cualesquiera.
    func sentCommands() throws -> [ControlCommand] {
        try calls.compactMap { call in
            guard case .sendControl(let payload) = call else { return nil }
            return try ControlCommand(decoding: payload)
        }
    }

    // MARK: - TunnelProviderManaging

    func loadStatus() async throws -> TunnelStatus {
        calls.append(.loadStatus)
        if let loadError { throw loadError }
        return status
    }

    func install(_ configuration: TunnelConfiguration) async throws {
        calls.append(.install(configuration))
        if let installError { throw installError }
        status = statusAfterInstall
    }

    func start() async throws {
        calls.append(.start)
        if let startError { throw startError }
        status = .connecting
    }

    func stop() async throws {
        calls.append(.stop)
        if let stopError { throw stopError }
        status = statusAfterStop
    }

    func sendControl(_ payload: Data) async throws -> Data? {
        calls.append(.sendControl(payload))
        return try controlOutcome.get()
    }

    nonisolated func statusUpdates() -> AsyncStream<TunnelStatus> { stream }
}

/// Doble del despertador del feed en vivo (M9).
///
/// Sustituye a `DarwinNotificationWakeup`, que necesita un segundo proceso emitiendo la señal. Deja
/// al test empujar despertares a mano y comprobar que el lector se engancha y se suelta.
///
/// `@unchecked Sendable` con un `NSLock`: el protocolo entrega el manejador desde el actor del lector
/// y el test lo dispara desde el suyo, igual que haría el callback C de `CFNotificationCenter`.
final class FakeLiveFeedWakeup: LiveFeedWakeup, @unchecked Sendable {

    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?
    private var starts = 0
    private var stops = 0

    func start(onWake: @escaping @Sendable () -> Void) {
        lock.lock()
        handler = onWake
        starts += 1
        lock.unlock()
    }

    func stop() {
        lock.lock()
        handler = nil
        stops += 1
        lock.unlock()
    }

    /// Emite un despertar, como la notificación Darwin tras un lote de `push`.
    func fire() {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?()
    }

    var isListening: Bool {
        lock.lock()
        defer { lock.unlock() }
        return handler != nil
    }

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stops
    }
}

/// Constructores para los tests del feed en vivo (M9): registros del ring que representan tráfico
/// real del dispositivo (una IP del túnel en un extremo) para que el reparto local/remoto tenga algo
/// que decidir.
enum LiveFeedFixtures {

    /// Host remoto por defecto. Ordena **después** de la IP del túnel, así que cae en `endpointB`.
    static let remote = IPEndpoint(
        address: IPAddress(version: .v4, bytes: [93, 184, 216, 34]),
        port: 443
    )

    /// Host remoto que ordena **antes** que la IP del túnel: ejercita la rama contraria del reparto.
    static let lowRemote = IPEndpoint(
        address: IPAddress(version: .v4, bytes: [1, 2, 3, 4]),
        port: 443
    )

    static func device(port: UInt16 = 51_000) -> IPEndpoint {
        IPEndpoint(address: TunnelAddressing.localIPv4, port: port)
    }

    static func meta(
        timestamp: UInt64,
        direction: Direction,
        length: UInt32,
        port: UInt16 = 51_000,
        peer: IPEndpoint = remote,
        proto: IPProtocolNumber = .tcp,
        tcpFlags: TCPFlags = [],
        capture: CaptureLocation? = nil
    ) -> PacketMeta {
        PacketMeta(
            timestamp: timestamp,
            flowKey: FlowKey(proto: proto, source: device(port: port), destination: peer),
            direction: direction,
            length: length,
            tcpFlags: tcpFlags,
            capture: capture
        )
    }

    /// El mismo paquete ya empaquetado como viaja por el ring.
    static func packed(
        timestamp: UInt64,
        direction: Direction,
        length: UInt32,
        port: UInt16 = 51_000,
        peer: IPEndpoint = remote,
        proto: IPProtocolNumber = .tcp,
        tcpFlags: TCPFlags = [],
        capture: CaptureLocation? = nil
    ) -> PackedPacketMeta {
        PackedPacketMeta(
            meta(
                timestamp: timestamp,
                direction: direction,
                length: length,
                port: port,
                peer: peer,
                proto: proto,
                tcpFlags: tcpFlags,
                capture: capture
            )
        )
    }

    static func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("live-feed-tests-\(UUID().uuidString).bin")
    }
}
