import Foundation
import Network
import Shared

/// Conexión saliente real sobre `NWConnection` (Network.framework): la conformidad de producción de
/// `RelayConnection`. En los tests se sustituye por un doble, porque una `NWConnection` no se puede
/// ejercitar de forma útil en Simulator; esta clase se valida solo por compilación (device-only en la
/// práctica), como el propio `PacketTunnelProvider`.
///
/// `@unchecked Sendable` es honesto: `NWConnection` está sincronizada internamente por su propia cola
/// y esta clase no tiene más estado mutable que compartir. La cola serializa `send`, `receive` y las
/// transiciones de estado.
public final class NetworkRelayConnection: RelayConnection, @unchecked Sendable {

    /// Modo de recepción: UDP tiene fronteras de mensaje (cada callback es un datagrama), TCP es un
    /// stream continuo (cada callback es un trozo arbitrario que la máquina de estados reensambla).
    public enum Mode: Sendable {
        case datagram   // UDP: receiveMessage
        case stream     // TCP: receive
    }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let mode: Mode

    public init(connection: NWConnection, queue: DispatchQueue, mode: Mode) {
        self.connection = connection
        self.queue = queue
        self.mode = mode
    }

    public func start(
        onReady: @escaping @Sendable () -> Void,
        onReceive: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable (RelayConnectionError?) -> Void
    ) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                onReady()
            case .failed(let error):
                onClose(RelayConnectionError(String(describing: error)))
            case .cancelled:
                onClose(nil)
            default:
                break
            }
        }
        // Se arma la primera recepción antes de arrancar: para UDP el primer datagrama del servidor
        // puede llegar en cuanto la conexión esté lista, y perderlo desincronizaría el flujo.
        receiveNext(onReceive: onReceive, onClose: onClose)
        connection.start(queue: queue)
    }

    /// Recibe el siguiente trozo entrante y se re-arma. Para UDP usa `receiveMessage` (fronteras de
    /// datagrama); para TCP, `receive` (stream). En ambos, `isComplete` es EOF de recepción y se
    /// reporta como cierre limpio (`onClose(nil)`), que para TCP la máquina de estados interpreta como
    /// FIN del servidor.
    private func receiveNext(
        onReceive: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable (RelayConnectionError?) -> Void
    ) {
        let completion: @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void = { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                onReceive(data)
            }
            if let error {
                onClose(RelayConnectionError(String(describing: error)))
                return
            }
            if isComplete {
                onClose(nil)
                return
            }
            self?.receiveNext(onReceive: onReceive, onClose: onClose)
        }
        switch mode {
        case .datagram:
            connection.receiveMessage(completion: completion)
        case .stream:
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_535, completion: completion)
        }
    }

    public func send(_ data: Data) {
        // Fire-and-forget: un fallo de envío se manifiesta como una transición a `.failed` del estado,
        // que ya cierra el flujo por el `stateUpdateHandler`.
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    public func closeSend() {
        // Half-close del lado de envío: el servidor ve EOF (FIN) pero seguimos recibiendo. Se marca con
        // `isComplete: true` sobre un contenido vacío, el idioma de Network.framework para "fin del stream
        // saliente".
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
    }

    public func cancel() {
        connection.cancel()
    }
}

/// Fábrica de producción: crea `NWConnection` sobre una cola serie compartida por todos los flujos del
/// relay (la propia `NWConnection` no bloquea, así que una cola basta).
public struct NetworkConnectionFactory: RelayConnectionFactory {

    private let queue: DispatchQueue

    public init(queue: DispatchQueue = DispatchQueue(label: "com.juanmmm21.tunnelvision.relay")) {
        self.queue = queue
    }

    public func makeUDPConnection(to endpoint: IPEndpoint) -> RelayConnection {
        let connection = NWConnection(host: Self.host(for: endpoint.address), port: Self.port(for: endpoint), using: .udp)
        return NetworkRelayConnection(connection: connection, queue: queue, mode: .datagram)
    }

    public func makeTCPConnection(to endpoint: IPEndpoint) -> RelayConnection {
        let connection = NWConnection(host: Self.host(for: endpoint.address), port: Self.port(for: endpoint), using: .tcp)
        return NetworkRelayConnection(connection: connection, queue: queue, mode: .stream)
    }

    /// Internos, y no privados, porque el motor de terminación TLS construye su pata saliente con los
    /// mismos endpoints: duplicar la traducción sería tener dos formas de decir a dónde va un flujo.
    static func port(for endpoint: IPEndpoint) -> NWEndpoint.Port {
        NWEndpoint.Port(rawValue: endpoint.port) ?? .any
    }

    /// Construye el host de Network.framework desde los bytes crudos de la IP. `IPAddress` se
    /// cualifica con `Shared.` porque `Network` exporta un protocolo con el mismo nombre. La familia
    /// garantiza la longitud correcta, así que el fallback solo cubre un imposible.
    static func host(for address: Shared.IPAddress) -> NWEndpoint.Host {
        let raw = Data(address.bytes)
        switch address.version {
        case .v4:
            return .ipv4(IPv4Address(raw) ?? .any)
        case .v6:
            return .ipv6(IPv6Address(raw) ?? .any)
        }
    }
}
