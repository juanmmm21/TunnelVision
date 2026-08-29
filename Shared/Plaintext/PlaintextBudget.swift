import Foundation

/// Cuánto contenido descifrado se guarda de **un** flujo, en cada sentido.
///
/// Es la decisión que impide que persistir el plaintext sea persistirlo todo. Sin ella, una descarga
/// o un vídeo por HTTPS escribirían en claro, byte a byte, lo mismo que ocupan en la red: gigabytes en
/// el dispositivo, a coste de escritura dentro del camino de un paquete, y de lo más sensible que este
/// producto llega a tocar. El tope es lo que convierte la inspección en "lo que explica la conexión" y
/// no en "una copia de todo lo que hiciste".
///
/// ## Por sentido, no por flujo
///
/// Los dos sentidos tienen su propio presupuesto porque el reparto real es asimétrico: una petición
/// mide cientos de bytes y su respuesta puede medir megabytes, así que un tope único lo consumiría la
/// respuesta y las peticiones siguientes de esa misma conexión —lo que de verdad explica quién habló
/// con quién y para qué— se quedarían sin sitio. Separados, ninguno se come al otro.
///
/// ## El principio, no el final
///
/// Cuando el presupuesto se agota se deja de guardar; no se descarta lo viejo para hacer sitio a lo
/// nuevo. El principio de una conversación es lo que la identifica (cabeceras, método, ruta,
/// respuesta), y una ventana deslizante dejaría el final de una descarga sin nada que lo explique. Que
/// se recortó se dice siempre: el registro guarda lo que medía el trozo además de lo que se guardó, y
/// `PlaintextTruncation` cuenta lo que se quedó fuera para que la pantalla pueda decirlo con un número
/// en vez de con un "hay más".
///
/// Es un valor puro y `mutating`: lo lleva quien tiene el flujo delante (una entrada por flujo vivo),
/// y muere con él.
public struct PlaintextBudget: Sendable, Equatable {

    /// Bytes que se guardan como mucho **por sentido**. 64 KiB cubre de sobra las cabeceras y el
    /// cuerpo corto de una petición y de su respuesta, que es lo que una pantalla puede enseñar y una
    /// persona leer; por encima de eso lo que hay es un fichero, no una conversación.
    public static let defaultMaxBytesPerDirection = 64 * 1024

    private let maxBytesPerDirection: Int
    private var storedOutbound = 0
    private var storedInbound = 0

    /// - Parameter maxBytesPerDirection: el tope por sentido. Un tope de 0 es válido y significa "no
    ///   guardes nada", que es exactamente lo que hace falta para poder apagar la persistencia sin
    ///   tocar el camino por el que pasan los bytes.
    public init(maxBytesPerDirection: Int = PlaintextBudget.defaultMaxBytesPerDirection) {
        self.maxBytesPerDirection = max(0, maxBytesPerDirection)
    }

    /// Cuántos bytes de un trozo se pueden guardar, y los da por gastados.
    ///
    /// Devuelve 0 cuando el sentido ya no tiene sitio, y menos que `byteCount` cuando el trozo cabe a
    /// medias — que es un recorte y hay que anotarlo como tal, no tratarlo como una escritura normal.
    public mutating func allowance(for byteCount: Int, direction: Direction) -> Int {
        guard byteCount > 0 else { return 0 }
        let allowed = min(byteCount, remaining(direction))
        switch direction {
        case .outbound: storedOutbound += allowed
        case .inbound: storedInbound += allowed
        }
        return allowed
    }

    /// Lo que le queda a un sentido sin gastarlo.
    public func remaining(_ direction: Direction) -> Int {
        switch direction {
        case .outbound: max(0, maxBytesPerDirection - storedOutbound)
        case .inbound: max(0, maxBytesPerDirection - storedInbound)
        }
    }

    /// Bytes ya guardados de un sentido.
    public func stored(_ direction: Direction) -> Int {
        switch direction {
        case .outbound: storedOutbound
        case .inbound: storedInbound
        }
    }

    /// Que no queda sitio en ninguno de los dos sentidos. Quien lleva el flujo lo mira para dejar de
    /// copiar trozos que ya no se van a guardar: el ahorro no es el disco sino la copia en memoria
    /// dentro de la extensión.
    public var isExhausted: Bool {
        remaining(.outbound) == 0 && remaining(.inbound) == 0
    }
}

/// Lo que un flujo dejó fuera, por sentido. Es lo que permite que la pantalla diga "se guardaron los
/// primeros 64 KB de 3,2 MB" en vez de un aviso sin número, y lo que hace visible que el tope existe
/// —que un producto que descifra no puede callarse.
public struct PlaintextTruncation: Sendable, Equatable {

    public var droppedOutbound: UInt64
    public var droppedInbound: UInt64

    public init(droppedOutbound: UInt64 = 0, droppedInbound: UInt64 = 0) {
        self.droppedOutbound = droppedOutbound
        self.droppedInbound = droppedInbound
    }

    /// Anota lo que no cupo de un trozo.
    public mutating func add(dropped byteCount: Int, direction: Direction) {
        guard byteCount > 0 else { return }
        switch direction {
        case .outbound: droppedOutbound &+= UInt64(byteCount)
        case .inbound: droppedInbound &+= UInt64(byteCount)
        }
    }

    public var isEmpty: Bool { droppedOutbound == 0 && droppedInbound == 0 }
}
