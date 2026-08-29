import Foundation
import Shared

/// La terminación TLS de **un** flujo: empareja la sesión de servidor que le presenta al cliente el
/// leaf de su host (`TLSServerSession`) con la **pata saliente** hacia el servidor real
/// (`RelayConnection` con TLS bajo confianza del sistema) y trasiega el plaintext entre las dos. Es la
/// mitad de I/O que le faltaba al motor de terminación; la decisión sigue viviendo, entera, en
/// `TLSInterceptionPolicy`.
///
/// ```
/// dispositivo ──records TLS(nuestro leaf)──▶ TLSServerSession ──plaintext──▶ pata saliente ──TLS(confianza
///            ◀──records TLS───────────────                   ◀──plaintext──               del sistema)──▶ servidor real
/// ```
///
/// ## Por qué **es** un `RelayConnection`
///
/// Desde el relay, una terminación no se distingue de una conexión saliente: recibe el stream ya
/// reensamblado que el dispositivo manda (`send`), devuelve bytes que hay que re-segmentar hacia él
/// (`onReceive`), tiene un momento en que la salida queda establecida (`onReady`) y un final
/// (`onClose`). Adoptar esa forma es lo que hace que enganchar la inspección sea **cambiar qué
/// conexión se crea** para un flujo `.inspect`, y no un segundo camino paralelo dentro del relay. Lo
/// que la terminación añade sobre una conexión normal —qué pasó con el intento de inspeccionar— sale
/// por un canal aparte (`onOutcome`), porque no es información de transporte.
///
/// ## Los dos sentidos, y qué va cifrado en cada tramo
///
/// - **Hacia el servidor:** los records que llegan del dispositivo entran por `send` y van a
///   `session.deliver`; la pila los descifra y devuelve plaintext por `onPlaintext`, que es lo que se
///   escribe en la pata saliente. Esa pata **vuelve a cifrar** con TLS del sistema, así que al servidor
///   real le somos un cliente corriente (invariante de seguridad de la spec: no ganamos confianza
///   ninguna que no tuviéramos).
/// - **Hacia el dispositivo:** lo que la pata saliente entrega ya viene descifrado por Network, y se
///   le pasa a `session.send`, que lo cifra con las claves del handshake que el cliente aceptó; los
///   records resultantes salen por `onEncrypted` y se devuelven al relay por `onReceive`.
///
/// El plaintext de los dos sentidos se ofrece a `plaintext` **antes** de reenviarlo. Hoy nadie lo
/// recoge: persistirlo es el incremento siguiente y esta es su costura, del mismo corte que los
/// sumideros del pipeline. Que sea opcional no es un adorno — sin observador no se copia ni un byte.
///
/// `@unchecked Sendable` con `NSLock` por lo mismo que `LoopbackTLSServerSession`: los handlers de las
/// dos patas entran por sus propias colas y los `send`/`cancel` vienen del actor que la orquesta.
/// Ningún callback se invoca con el candado tomado.
public final class TLSTerminationConnection: RelayConnection, @unchecked Sendable {

    /// Tope de plaintext del cliente retenido mientras la pata saliente todavía no está lista. Pasarse
    /// significa que la salida no llegó a levantarse, y entonces lo correcto es fallar en vez de crecer
    /// sin límite dentro de una extensión con presupuesto de memoria (el mismo tope, y por la misma
    /// razón, que las dos colas de `LoopbackTLSServerSession`).
    public static let maximumPendingBytes = 64 * 1024

    private let session: any TLSServerSession
    private let upstream: any RelayConnection
    /// Sumidero del contenido en claro de los dos sentidos. Nil = no se observa nada.
    private let plaintext: (@Sendable (Data, Direction) -> Void)?
    private let onOutcome: @Sendable (TLSTerminationOutcome) -> Void

    private let lock = NSLock()
    private var onReady: (@Sendable () -> Void)?
    private var onReceive: (@Sendable (Data) -> Void)?
    private var onClose: (@Sendable (RelayConnectionError?) -> Void)?
    /// El cliente aceptó nuestro leaf y el handshake terminó: a partir de ahí hubo plaintext, que es lo
    /// que separa "se inspeccionó" de "no se llegó a inspeccionar nada".
    private var clientTrusted = false
    private var upstreamReady = false
    private var pendingToServer = Data()
    private var isFinished = false

    /// - Parameters:
    ///   - session: el lado cliente, ya construido con el leaf del host (quien la construye es el
    ///     motor, que es el único que sabe emitirlo).
    ///   - upstream: la pata saliente hacia el servidor real, **con TLS y bajo confianza del sistema**.
    ///     Entra sin arrancar: la arranca `start`, igual que hace el relay con las suyas.
    ///   - plaintext: sumidero del contenido descifrado, con su sentido. Opcional a propósito.
    ///   - onOutcome: el desenlace del intento de inspección, **exactamente una vez** — salvo que sea
    ///     el propio llamante quien cancele, porque entonces ya sabe cómo terminó.
    public init(
        session: any TLSServerSession,
        upstream: any RelayConnection,
        plaintext: (@Sendable (Data, Direction) -> Void)? = nil,
        onOutcome: @escaping @Sendable (TLSTerminationOutcome) -> Void
    ) {
        self.session = session
        self.upstream = upstream
        self.plaintext = plaintext
        self.onOutcome = onOutcome
    }

    // MARK: - RelayConnection

    public func start(
        onReady: @escaping @Sendable () -> Void,
        onReceive: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable (RelayConnectionError?) -> Void
    ) {
        lock.lock()
        self.onReady = onReady
        self.onReceive = onReceive
        self.onClose = onClose
        lock.unlock()

        // La sesión primero: levantar su puente cuesta un par de saltos y el cliente puede estar
        // mandando su ClientHello ya. La pata saliente no depende de ella para nada.
        session.start(
            onReady: { [weak self] in self?.clientDidTrustLeaf() },
            onPlaintext: { [weak self] data in self?.clientDidSend(data) },
            onEncrypted: { [weak self] data in self?.deliverToClient(data) },
            onClose: { [weak self] closure in self?.sessionDidClose(closure) }
        )
        upstream.start(
            onReady: { [weak self] in self?.upstreamDidBecomeReady() },
            onReceive: { [weak self] data in self?.serverDidSend(data) },
            onClose: { [weak self] error in self?.upstreamDidClose(error) }
        )
    }

    /// Records TLS del dispositivo (stream ya reensamblado y en orden). No se miran: los descifra la
    /// pila de la sesión, que es la única que tiene las claves.
    public func send(_ data: Data) {
        guard !data.isEmpty, !finished else { return }
        session.deliver(data)
    }

    /// El dispositivo cerró su lado de envío (FIN). Se traslada tal cual a la sesión, que le enseña el
    /// EOF a la pila; **no** cierra la pata saliente: el servidor puede seguir respondiendo.
    public func closeSend() {
        guard !finished else { return }
        session.deliverEnd()
    }

    /// Cierre pedido por el llamante (el relay derriba el flujo). Libera las dos patas y **no reporta
    /// desenlace**: quien cancela ya sabe cómo terminó esto, y un desenlace de más obligaría a decidir
    /// cuál de los cuatro es "me cancelaron", que no es ninguno.
    public func cancel() {
        teardown(outcome: nil, closeWith: nil, notifiesCaller: false)
    }

    // MARK: - Lado cliente (la sesión)

    private func clientDidTrustLeaf() {
        lock.lock()
        clientTrusted = true
        lock.unlock()
    }

    /// Plaintext que mandó el dispositivo: se observa y se escribe en la pata saliente, que lo vuelve a
    /// cifrar. Si la salida aún no está lista se retiene acotado — el handshake con el cliente puede
    /// terminar antes que el TLS contra el servidor real, y perder la primera petición sería perder
    /// justo la que explica el flujo.
    private func clientDidSend(_ data: Data) {
        guard !data.isEmpty else { return }

        lock.lock()
        if isFinished {
            // Terminado el flujo no se copia ni se reenvía nada: un rezagado no lo resucita.
            lock.unlock()
            return
        }
        let established = upstreamReady
        if !established {
            pendingToServer.append(data)
        }
        let overflowed = !established && pendingToServer.count > Self.maximumPendingBytes
        lock.unlock()

        observe(data, .outbound)
        if established {
            upstream.send(data)
        } else if overflowed {
            teardown(
                outcome: .userspaceStackError,
                closeWith: RelayConnectionError("plaintext sin pata saliente: tope de \(Self.maximumPendingBytes) B"),
                notifiesCaller: true
            )
        }
    }

    /// Records que la pila produjo para el cliente (handshake incluido): son exactamente los bytes que
    /// el relay tiene que re-segmentar hacia el dispositivo.
    private func deliverToClient(_ data: Data) {
        handlers().receive?(data)
    }

    private func sessionDidClose(_ closure: TLSServerSessionClosure) {
        switch closure {
        case .rejectedByClient:
            // ADR 0003: el cliente hace pinning. No es un fallo nuestro y no se reintenta; el llamante
            // marca el flujo `notInspectable`. El cierre hacia el dispositivo va **limpio** porque el
            // cliente ya mandó su alerta y sabe por qué se acaba: un RST encima solo añadiría ruido.
            teardown(outcome: .pinned, closeWith: nil, notifiesCaller: true)
        case .closed:
            // Un cierre limpio sin handshake completado no inspeccionó nada: va al cubo transitorio
            // (relay intacto y **sin** marcar), que es la respuesta prudente cuando no se sabe por qué.
            teardown(outcome: clientCompletedHandshake ? .inspected : .userspaceStackError, closeWith: nil, notifiesCaller: true)
        case .failed(let error):
            teardown(
                outcome: .userspaceStackError,
                closeWith: RelayConnectionError(error.description),
                notifiesCaller: true
            )
        }
    }

    // MARK: - Lado servidor (la pata saliente)

    /// La pata saliente quedó establecida —lo que para una conexión con TLS incluye su handshake contra
    /// el servidor real—, así que a partir de aquí la salida existe. Es el momento en que el relay
    /// puede darle el SYN-ACK al dispositivo, exactamente igual que con una conexión de passthrough.
    private func upstreamDidBecomeReady() {
        lock.lock()
        if isFinished {
            lock.unlock()
            return
        }
        upstreamReady = true
        let queued = pendingToServer
        pendingToServer = Data()
        let ready = onReady
        lock.unlock()

        if !queued.isEmpty {
            upstream.send(queued)
        }
        ready?()
    }

    /// Plaintext del servidor real (Network ya lo descifró): se observa y se le entrega a la sesión,
    /// que lo cifra con las claves que el cliente aceptó.
    private func serverDidSend(_ data: Data) {
        guard !data.isEmpty, !finished else { return }
        observe(data, .inbound)
        session.send(data)
    }

    private func upstreamDidClose(_ error: RelayConnectionError?) {
        lock.lock()
        if isFinished {
            lock.unlock()
            return
        }
        let established = upstreamReady
        let inspected = clientTrusted
        lock.unlock()

        guard established else {
            // Caerse antes de estar lista es, para una conexión con TLS, que el handshake contra el
            // servidor real no se completó: es la razón transitoria que la política ya distingue.
            teardown(outcome: .serverHandshakeFailed, closeWith: error, notifiesCaller: true)
            return
        }
        if let error {
            teardown(outcome: inspected ? .inspected : .userspaceStackError, closeWith: error, notifiesCaller: true)
            return
        }
        // Medio cierre del servidor: se le traslada al cliente cerrando **nuestro** lado de envío y no
        // se derriba nada. Lo que quede por cifrar todavía tiene que salir, y el final del flujo lo
        // marcará el cierre de la sesión, que es el único que ve los dos sentidos.
        session.closeSend()
    }

    // MARK: - Utilidades

    private var finished: Bool {
        lock.lock(); defer { lock.unlock() }
        return isFinished
    }

    private var clientCompletedHandshake: Bool {
        lock.lock(); defer { lock.unlock() }
        return clientTrusted
    }

    private func observe(_ data: Data, _ direction: Direction) {
        plaintext?(data, direction)
    }

    /// Snapshot de los handlers del llamante para invocarlos **sin** el candado tomado.
    private func handlers() -> (ready: (@Sendable () -> Void)?, receive: (@Sendable (Data) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        guard !isFinished else { return (nil, nil) }
        return (onReady, onReceive)
    }

    /// Cierre terminal: libera las dos patas y avisa **una sola vez**. El desenlace se reporta antes que
    /// el cierre de transporte a propósito — el llamante marca el flujo con él, y hacerlo después de
    /// haberle dicho que la conexión murió sería marcarlo cuando ya lo ha soltado.
    private func teardown(
        outcome: TLSTerminationOutcome?,
        closeWith error: RelayConnectionError?,
        notifiesCaller: Bool
    ) {
        lock.lock()
        if isFinished {
            lock.unlock()
            return
        }
        isFinished = true
        let notify = notifiesCaller ? onClose : nil
        onReady = nil
        onReceive = nil
        onClose = nil
        pendingToServer = Data()
        lock.unlock()

        session.cancel()
        upstream.cancel()

        if let outcome {
            onOutcome(outcome)
        }
        notify?(error)
    }
}
