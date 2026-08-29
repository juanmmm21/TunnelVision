import Foundation
import Shared

/// Una conexión saliente de un flujo hacia internet, abstraída sobre `NWConnection`.
///
/// El relay habla con la red a través de este protocolo y no directamente contra `Network.framework`
/// por la misma razón que el pipeline (M7) inyecta sus sumideros: una `NWConnection` no se puede
/// ejercitar de forma útil en Simulator, así que la lógica del relay corre en tests contra un doble
/// que captura lo enviado y simula las respuestas del servidor. La conformidad de producción es
/// `NetworkRelayConnection`.
///
/// El ciclo de vida es: `start` una vez (registra los handlers), `send` por cada trozo saliente,
/// opcionalmente `closeSend` (half-close TCP) y `cancel` para liberar. Los handlers de `start` los
/// invoca la conexión desde su propia cola, así que el relay los reenvía a su contexto de actor.
///
/// **UDP vs TCP:** el mismo protocolo sirve para ambos. Para UDP, `onReady` es irrelevante (el relay
/// envía sin esperar) y cada `send` es un datagrama; `closeSend` no aplica (default no-op). Para TCP,
/// `onReady` marca que la conexión saliente quedó establecida —recién entonces la máquina de estados
/// difiere el SYN-ACK hacia el dispositivo—, `send` escribe en el stream y `closeSend` hace half-close
/// del envío (el servidor ve EOF). `onClose(nil)` es un cierre limpio o EOF de recepción; `onClose(err)`
/// es un fallo de red.
public protocol RelayConnection: Sendable {
    /// Arranca la conexión y registra los callbacks: `onReady` (conexión establecida, relevante para
    /// TCP), `onReceive` (bytes entrantes del servidor) y `onClose` (terminación o fallo, con `nil` si
    /// el cierre fue limpio o fue un EOF de recepción). Se llama exactamente una vez por conexión.
    func start(
        onReady: @escaping @Sendable () -> Void,
        onReceive: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable (RelayConnectionError?) -> Void
    )

    /// Envía bytes de transporte hacia el servidor real. Para UDP, cada llamada es un datagrama; para
    /// TCP, un trozo del stream saliente.
    func send(_ data: Data)

    /// Cierra el lado de envío de la conexión (half-close TCP): el servidor ve EOF pero la recepción
    /// sigue abierta. No aplica a UDP, de ahí el default no-op.
    func closeSend()

    /// Cierra y libera la conexión. Idempotente: cancelar dos veces no es un error.
    func cancel()
}

extension RelayConnection {
    /// Por defecto un half-close no hace nada: solo TCP lo implementa (UDP no tiene sentido de cierre
    /// parcial), así que su conformidad de producción y el doble de tests no están obligados a definirlo.
    public func closeSend() {}
}

/// Fábrica de conexiones salientes. Inyectable para que el relay no dependa de `Network.framework`
/// en los tests; la conformidad de producción es `NetworkConnectionFactory`.
public protocol RelayConnectionFactory: Sendable {
    /// Crea (sin arrancar) una conexión UDP hacia `endpoint`. El relay la arranca con `start`.
    func makeUDPConnection(to endpoint: IPEndpoint) -> RelayConnection

    /// Crea (sin arrancar) una conexión TCP hacia `endpoint`. A diferencia de la UDP, su recepción es
    /// por stream (`receive`, no `receiveMessage`) y su `onReady` sí importa: hasta que la conexión
    /// saliente no está establecida no emitimos el SYN-ACK hacia el dispositivo.
    func makeTCPConnection(to endpoint: IPEndpoint) -> RelayConnection
}

/// Fallo de una conexión saliente, reducido a texto para no arrastrar `NWError` (que no es
/// `Sendable`) hasta el actor del relay ni hasta los tests.
public struct RelayConnectionError: Error, Sendable, Equatable {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}
