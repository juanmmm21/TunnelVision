import Foundation

/// Cómo terminó una sesión de servidor TLS. Es la mitad del desenlace que el motor de terminación no
/// puede deducir de ningún otro sitio: si el cliente aceptó nuestro leaf, si lo **rechazó** (que es el
/// caso que el ADR 0003 protege) o si se rompió algo por debajo.
public enum TLSServerSessionClosure: Sendable, Equatable {
    /// El cliente cerró limpiamente (EOF) o la sesión se canceló sin error.
    case closed
    /// El cliente **no confió** en el certificado que le presentamos: o hace pinning, o el usuario no
    /// ha instalado/confiado la CA. Se distingue del fallo porque es **permanente para ese flujo**:
    /// el llamante lo marca `notInspectable` y lo relaya intacto, **sin reintentar** (ADR 0003).
    case rejectedByClient
    /// Cualquier otra rotura: no se pudo abrir la sesión, la pila falló a mitad, la red local se cayó.
    /// Es transitoria, así que el llamante relaya el flujo intacto pero **no** lo marca.
    case failed(TLSServerSessionError)
}

/// Fallo de una sesión TLS reducido a texto, por el mismo motivo que `RelayConnectionError`: no
/// arrastrar `NWError` (que no es `Sendable`) hasta el actor ni hasta los tests.
public struct TLSServerSessionError: Error, Sendable, Equatable {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// El **lado servidor** de la terminación TLS: una pila TLS alimentada desde bytes que ya tenemos en
/// memoria, no desde un socket.
///
/// Es la pieza cuya viabilidad era la única incógnita del proyecto, y por eso es una costura propia:
/// el motor de terminación (`TLSTerminationEngine`) la orquesta contra el otro lado —la conexión al
/// servidor real— sin depender de cómo se resuelve esta. La conformidad de producción es
/// `LoopbackTLSServerSession`.
///
/// **La forma es la de `RelayConnection` a propósito** (arrancar una vez registrando handlers, empujar
/// bytes, cerrar el lado de envío, cancelar), porque el problema es el mismo visto del revés: allí
/// nosotros somos el cliente de un servidor real, aquí somos el servidor de un cliente real. Lo único
/// que cambia es que hay **dos** corrientes en cada sentido —los records TLS que viajan por el túnel y
/// el plaintext que queda entre las dos patas—, y de ahí que haya un callback para cada una.
///
/// El ciclo de vida es: `start` una vez, `deliver` por cada trozo de records que llega del cliente,
/// `deliverEnd` cuando el cliente cierra su lado (FIN), `send` para escribirle plaintext (la sesión lo
/// cifra), `closeSend` para cerrar nuestro lado y `cancel` para liberar. `onReady` marca que el
/// handshake terminó: **hasta que no llega, no hay plaintext** y `send` no tiene sentido.
public protocol TLSServerSession: Sendable {
    /// Arranca la sesión y registra sus cuatro salidas. Se llama exactamente una vez.
    ///
    /// - `onReady`: el handshake con el cliente terminó y aceptó nuestro leaf. A partir de aquí hay
    ///   plaintext en los dos sentidos.
    /// - `onPlaintext`: bytes **en claro** que el cliente envió. Es lo que se inspecciona.
    /// - `onEncrypted`: records TLS que hay que **devolverle al cliente** por el túnel. Incluye los
    ///   del handshake, así que empiezan a llegar antes que `onReady`.
    /// - `onClose`: desenlace terminal, exactamente una vez.
    ///
    /// No lanza: cualquier fallo de arranque —incluido no poder formar la identidad o abrir la pila—
    /// se reporta por `onClose`, para que **la política** decida qué hacer con él y el llamante tenga
    /// un solo camino de error.
    func start(
        onReady: @escaping @Sendable () -> Void,
        onPlaintext: @escaping @Sendable (Data) -> Void,
        onEncrypted: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable (TLSServerSessionClosure) -> Void
    )

    /// Entrega records TLS recién llegados del cliente (el stream TCP ya reensamblado y en orden).
    /// Los que lleguen antes de que la pila esté lista se retienen de forma acotada.
    func deliver(_ data: Data)

    /// El cliente cerró su lado de envío (FIN): la pila ve EOF. No cierra el nuestro.
    func deliverEnd()

    /// Escribe plaintext hacia el cliente; la sesión lo cifra con las claves del handshake. Llamarlo
    /// antes de `onReady` es un error del llamante: los bytes se retienen igual, acotados.
    func send(_ plaintext: Data)

    /// Cierra nuestro lado de envío: el cliente ve el cierre TLS. La recepción sigue abierta.
    func closeSend()

    /// Cierra y libera todo. Idempotente: cancelar dos veces no es un error, y tras cancelar no se
    /// vuelve a llamar a ningún handler.
    func cancel()
}
