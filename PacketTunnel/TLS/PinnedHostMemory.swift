import Foundation

/// Los hosts que ya rechazaron nuestro leaf en esta sesión del túnel, para no volver a intentarlo.
///
/// **Por qué hace falta, y por qué va por host y no por flujo.** El ADR 0003 dice que un cliente que
/// pinnea se relaya intacto y se marca `notInspectable`, y eso el relay ya lo hace sobre *ese* flujo.
/// Pero el cliente que acaba de ver su handshake fallar **reintenta**, y su reintento sale con otro
/// puerto de origen: otra `FlowKey`, otro flujo, y sin memoria volveríamos a terminarlo y a romperle
/// la conexión otra vez. Recordar por host es lo que convierte "no forzamos a nadie" en algo que se
/// cumple también en el segundo intento, que es el que el usuario nota.
///
/// **Su caducidad es la sesión**, y es una decisión: la alternativa (un TTL) obligaría a elegir un
/// número que ninguna observación respalda, mientras que el arranque del túnel es un momento real en
/// el que todo lo demás también se vuelve a preguntar — si el usuario acaba de instalar la CA, o la
/// app dejó de pinnear con una actualización, encender y apagar el túnel vuelve a intentarlo.
///
/// Es un valor puro y acotado: sin tope, una sesión larga contra muchos hosts pinneados haría crecer
/// la memoria de la extensión sin límite. Lleno, sale el más antiguo — no el menos usado: mantener un
/// orden de uso costaría más que el olvido que evita, y olvidar un host solo cuesta un intento.
public struct PinnedHostMemory: Sendable, Equatable {

    /// Tope de hosts recordados. 256 hosts pinneados en una sesión es holgadamente más de lo que un
    /// dispositivo produce, y son unos pocos KB.
    public static let defaultCapacity = 256

    private let capacity: Int
    private var hosts: Set<String>
    /// Orden de entrada, para saber a quién olvidar al llenarse. Va aparte del `Set` porque el `Set`
    /// no tiene orden y recorrerlo para elegir víctima sería elegir al azar.
    private var arrivals: [String]

    public init(capacity: Int = defaultCapacity) {
        // Un tope no positivo dejaría la memoria inservible en silencio; se colapsa a 1, que es el
        // mínimo con el que la estructura sigue significando lo que dice.
        self.capacity = max(1, capacity)
        self.hosts = []
        self.arrivals = []
    }

    /// Anota que `host` rechazó nuestro leaf. Repetirlo no lo reordena ni lo duplica: ya está
    /// recordado y su antigüedad sigue siendo la de la primera vez.
    public mutating func remember(_ host: String) {
        guard !hosts.contains(host) else { return }
        if arrivals.count >= capacity {
            let evicted = arrivals.removeFirst()
            hosts.remove(evicted)
        }
        hosts.insert(host)
        arrivals.append(host)
    }

    /// Si `host` ya rechazó nuestro leaf en esta sesión.
    public func contains(_ host: String) -> Bool {
        hosts.contains(host)
    }

    /// Cuántos hosts se recuerdan. Expuesto para verificar el tope en tests.
    public var count: Int { hosts.count }
}
