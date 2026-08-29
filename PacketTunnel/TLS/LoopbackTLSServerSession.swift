import Foundation
import Network
import Security

/// Conformidad de producción de `TLSServerSession`: un servidor TLS real de Network.framework,
/// alimentado desde memoria a través de una **conexión de loopback**.
///
/// ## Por qué existe esta forma
///
/// La extensión recibe **paquetes IP**, no sockets, así que para presentarle un certificado al cliente
/// hay que meter bytes que ya están en memoria dentro de una pila TLS. Network.framework —la única
/// pila TLS mantenida que iOS expone— solo hace de **servidor** a través de un `NWListener`, y un
/// listener solo se alimenta por un socket. La salida es un **puente corto**: un listener en
/// `127.0.0.1` con nuestro leaf y una conexión TCP plana **nuestra** contra él. Por esa conexión
/// escribimos los records TLS que llegaron del túnel y leemos los que hay que devolverle al cliente;
/// por la conexión que el listener acepta entra y sale el **plaintext**. La pila TLS es de Apple; lo
/// que ponemos nosotros es el cable de un metro.
///
/// La alternativa era `SecureTransport` (`SSLCreateContext` + `SSLSetIOFuncs`), que se alimenta de
/// memoria por diseño y no necesita ningún socket. **Sigue existiendo y arranca** en iOS 26 —está
/// comprobado, no deducido—, pero está deprecada desde iOS 13, no habla TLS 1.3 y Apple dice
/// literalmente "No longer supported. Use Network.framework." Construir la inspección de la v1 sobre
/// una API que puede desaparecer en la siguiente versión del sistema es un riesgo peor que el coste de
/// este puente. Queda escrito en `docs/spec/relay-and-tls.md` por si algún día hace falta el cambio:
/// esta costura es justo lo que lo haría barato.
///
/// ## Lo que cuesta y lo que no
///
/// Un listener y dos extremos de socket **por sesión inspeccionada**, que es tráfico que nunca sale
/// del dispositivo: el loopback lo resuelve `lo0` y no entra en el túnel, así que no hay recursión
/// posible con nuestro propio `NEPacketTunnelProvider`. El listener se ata a `127.0.0.1` (nunca a
/// `0.0.0.0`) y **deja de escuchar en cuanto acepta la primera conexión**, así que no queda un puerto
/// abierto a nadie más mientras dura el flujo.
///
/// `@unchecked Sendable` con `NSLock`: los handlers de Network entran por su propia cola y los
/// `deliver`/`send` vienen del actor que la orquesta, así que el estado se protege a mano. Ningún
/// callback se invoca con el candado tomado.
public final class LoopbackTLSServerSession: TLSServerSession, @unchecked Sendable {

    /// Tope de bytes retenidos antes de que la pila esté lista, en cada sentido. Un ClientHello y sus
    /// segundos records caben de sobra; pasarse significa que el puente no arrancó, y entonces lo
    /// correcto es fallar en vez de crecer sin límite dentro de una extensión con presupuesto de
    /// memoria.
    public static let maximumPendingBytes = 64 * 1024

    /// Estados TLS que significan **"el cliente no aceptó el certificado que le presentamos"**. Todos
    /// son alertas que manda el par (`errSSLPeer*`), no evaluaciones nuestras. Va incluido
    /// `errSSLPeerHandshakeFail`: un cliente que hace pinning puede rechazarnos con un
    /// `handshake_failure` genérico en vez de una alerta de certificado, y en esta posición —servidor
    /// de un handshake que acabamos de empezar— cualquiera de las dos significa lo mismo y tiene la
    /// misma salida permanente, que es dejar de inspeccionar ese flujo (ADR 0003).
    private static let clientRejectionStatuses: Set<OSStatus> = [
        errSSLPeerHandshakeFail,
        errSSLPeerBadCert,
        errSSLPeerUnsupportedCert,
        errSSLPeerCertRevoked,
        errSSLPeerCertExpired,
        errSSLPeerCertUnknown,
        errSSLPeerUnknownCA,
        errSSLPeerAccessDenied,
    ]

    private let identity: SecIdentity
    private let queue: DispatchQueue

    private let lock = NSLock()
    private var listener: NWListener?
    /// Extremo **nuestro** del puente: TCP plano. Le escribimos los records del cliente y leemos de él
    /// los que hay que devolverle.
    private var bridge: NWConnection?
    /// Extremo que **acepta el listener**: es el lado servidor del TLS, así que por aquí va plaintext.
    private var terminated: NWConnection?
    private var pendingRecords = Data()
    private var pendingPlaintext = Data()
    private var bridgeReady = false
    private var terminatedReady = false
    private var isFinished = false
    /// El cliente cerró antes de que el puente estuviera listo; el EOF se difiere hasta que lo esté.
    private var pendingClientEnd = false

    private var onReady: (@Sendable () -> Void)?
    private var onPlaintext: (@Sendable (Data) -> Void)?
    private var onEncrypted: (@Sendable (Data) -> Void)?
    private var onClose: (@Sendable (TLSServerSessionClosure) -> Void)?

    /// - Parameters:
    ///   - identity: el leaf del host, ya emitido por `LocalCA.mintLeaf(forHost:)`. Es lo que se le
    ///     presenta al cliente, y por tanto lo único que decide si confía o no.
    ///   - queue: cola serie sobre la que corren listener y conexiones. Serie a propósito: serializa
    ///     los handlers de las dos conexiones del puente entre sí.
    public init(identity: SecIdentity, queue: DispatchQueue) {
        self.identity = identity
        self.queue = queue
    }

    // MARK: - TLSServerSession

    public func start(
        onReady: @escaping @Sendable () -> Void,
        onPlaintext: @escaping @Sendable (Data) -> Void,
        onEncrypted: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable (TLSServerSessionClosure) -> Void
    ) {
        lock.lock()
        self.onReady = onReady
        self.onPlaintext = onPlaintext
        self.onEncrypted = onEncrypted
        self.onClose = onClose
        lock.unlock()

        guard let secIdentity = sec_identity_create(identity) else {
            finish(.failed(TLSServerSessionError("sec_identity_create devolvió nil")))
            return
        }

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        // Solo loopback: el puente no debe ser alcanzable desde fuera del dispositivo ni un instante.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            finish(.failed(TLSServerSessionError("NWListener: \(error)")))
            return
        }

        lock.lock()
        self.listener = listener
        lock.unlock()

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = listener.port else {
                    self.finish(.failed(TLSServerSessionError("listener sin puerto")))
                    return
                }
                self.openBridge(to: port)
            case .failed(let error):
                self.finish(self.closure(for: error))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    public func deliver(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        if isFinished {
            lock.unlock()
            return
        }
        if bridgeReady, let bridge {
            lock.unlock()
            bridge.send(content: data, completion: .contentProcessed { _ in })
            return
        }
        pendingRecords.append(data)
        let overflowed = pendingRecords.count > Self.maximumPendingBytes
        lock.unlock()
        if overflowed {
            finish(.failed(TLSServerSessionError("records del cliente sin puente: tope de \(Self.maximumPendingBytes) B")))
        }
    }

    public func deliverEnd() {
        lock.lock()
        if isFinished {
            lock.unlock()
            return
        }
        guard bridgeReady, let bridge else {
            pendingClientEnd = true
            lock.unlock()
            return
        }
        lock.unlock()
        bridge.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
    }

    public func send(_ plaintext: Data) {
        guard !plaintext.isEmpty else { return }
        lock.lock()
        if isFinished {
            lock.unlock()
            return
        }
        if terminatedReady, let terminated {
            lock.unlock()
            terminated.send(content: plaintext, completion: .contentProcessed { _ in })
            return
        }
        pendingPlaintext.append(plaintext)
        let overflowed = pendingPlaintext.count > Self.maximumPendingBytes
        lock.unlock()
        if overflowed {
            finish(.failed(TLSServerSessionError("plaintext antes del handshake: tope de \(Self.maximumPendingBytes) B")))
        }
    }

    public func closeSend() {
        lock.lock()
        let connection = terminatedReady ? terminated : nil
        lock.unlock()
        connection?.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
    }

    public func cancel() {
        finish(.closed)
    }

    // MARK: - Puente

    /// Abre nuestro extremo del puente contra el listener recién levantado. Va **sin TLS**: por aquí
    /// viajan los records tal cual llegaron del túnel; cifrarlos otra vez sería envolver un sobre.
    private func openBridge(to port: NWEndpoint.Port) {
        let bridge = NWConnection(
            to: .hostPort(host: "127.0.0.1", port: port),
            using: NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        )
        lock.lock()
        if isFinished {
            lock.unlock()
            bridge.cancel()
            return
        }
        self.bridge = bridge
        lock.unlock()

        bridge.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.bridgeDidBecomeReady()
            case .failed(let error):
                self.finish(self.closure(for: error))
            default:
                break
            }
        }
        // Armada antes de arrancar: el ServerHello puede salir en cuanto el handshake empiece.
        receiveFromBridge(bridge)
        bridge.start(queue: queue)
    }

    private func bridgeDidBecomeReady() {
        lock.lock()
        bridgeReady = true
        let queued = pendingRecords
        pendingRecords = Data()
        let endPending = pendingClientEnd
        pendingClientEnd = false
        let bridge = self.bridge
        lock.unlock()

        if !queued.isEmpty {
            bridge?.send(content: queued, completion: .contentProcessed { _ in })
        }
        if endPending {
            bridge?.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        }
    }

    /// Lee del puente los records TLS que la pila produce (handshake incluido) y los saca por
    /// `onEncrypted`: son exactamente los bytes que hay que devolverle al cliente por el túnel.
    private func receiveFromBridge(_ bridge: NWConnection) {
        bridge.receive(minimumIncompleteLength: 1, maximumLength: 65_535) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.callbacks().encrypted?(data)
            }
            if let error {
                self.finish(self.closure(for: error))
                return
            }
            if isComplete {
                self.finish(.closed)
                return
            }
            self.receiveFromBridge(bridge)
        }
    }

    // MARK: - Lado servidor (plaintext)

    /// Acepta la conexión del puente. **Solo la primera**: el listener se para en el acto, así que el
    /// puerto deja de estar abierto en cuanto tiene a su único cliente legítimo.
    private func accept(_ connection: NWConnection) {
        lock.lock()
        let alreadyAccepted = terminated != nil || isFinished
        if !alreadyAccepted {
            terminated = connection
        }
        let listener = self.listener
        self.listener = nil
        lock.unlock()

        listener?.cancel()
        guard !alreadyAccepted else {
            connection.cancel()
            return
        }

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.terminatedDidBecomeReady()
            case .failed(let error):
                self.finish(self.closure(for: error))
            default:
                break
            }
        }
        receivePlaintext(connection)
        connection.start(queue: queue)
    }

    private func terminatedDidBecomeReady() {
        lock.lock()
        if isFinished {
            lock.unlock()
            return
        }
        terminatedReady = true
        let queued = pendingPlaintext
        pendingPlaintext = Data()
        let terminated = self.terminated
        let ready = onReady
        lock.unlock()

        ready?()
        if !queued.isEmpty {
            terminated?.send(content: queued, completion: .contentProcessed { _ in })
        }
    }

    private func receivePlaintext(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_535) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.callbacks().plaintext?(data)
            }
            if let error {
                self.finish(self.closure(for: error))
                return
            }
            if isComplete {
                self.finish(.closed)
                return
            }
            self.receivePlaintext(connection)
        }
    }

    // MARK: - Cierre y clasificación

    /// Traduce un fallo de Network a un desenlace. La distinción que importa: un rechazo del cliente
    /// es **permanente** para el flujo (ADR 0003, se marca `notInspectable` y no se reintenta) y
    /// cualquier otra cosa es transitoria.
    private func closure(for error: NWError) -> TLSServerSessionClosure {
        if case .tls(let status) = error, Self.clientRejectionStatuses.contains(status) {
            return .rejectedByClient
        }
        return .failed(TLSServerSessionError(String(describing: error)))
    }

    /// Snapshot de los callbacks de streaming para invocarlos **sin el candado** tomado.
    private func callbacks() -> (plaintext: (@Sendable (Data) -> Void)?, encrypted: (@Sendable (Data) -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return (nil, nil) }
        return (onPlaintext, onEncrypted)
    }

    /// Cierre terminal: libera las dos conexiones y el listener, y avisa **exactamente una vez**. Todo
    /// lo que llegue después de esto se ignora, que es lo que permite que `cancel()` sea idempotente y
    /// que dos fallos simultáneos (los dos extremos del puente caen juntos) no se cuenten dos veces.
    private func finish(_ closure: TLSServerSessionClosure) {
        lock.lock()
        if isFinished {
            lock.unlock()
            return
        }
        isFinished = true
        let listener = self.listener
        let bridge = self.bridge
        let terminated = self.terminated
        let notify = onClose
        self.listener = nil
        self.bridge = nil
        self.terminated = nil
        onReady = nil
        onPlaintext = nil
        onEncrypted = nil
        onClose = nil
        pendingRecords = Data()
        pendingPlaintext = Data()
        lock.unlock()

        listener?.cancel()
        bridge?.cancel()
        terminated?.cancel()
        notify?(closure)
    }
}
