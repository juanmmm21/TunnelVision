import Foundation

/// Un trozo de contenido descifrado **ya escrito en disco**, listo para indexarse.
///
/// Es al contenido descifrado lo que `PacketMeta` es a un paquete: lo que el hot path acumula y el
/// volcado por lotes mete en la BD. Y por la misma razón lleva **dónde quedaron los bytes** y no los
/// bytes: la fila del índice existe para poder volver a ellos, no para duplicarlos.
///
/// El sello es **monotónico**, como el de `PacketMeta`, porque es lo único que existe en el camino de
/// un paquete; lo convierte a hora de pared el store al escribir, con el ancla de la sesión. Ojo a que
/// **el fichero guarda el instante absoluto** (`PlaintextFormat`): el fichero sobrevive a su sesión y
/// la fila no puede fecharse de dos maneras distintas, así que quien escribe convierte una vez para
/// cada destino y con la misma ancla.
public struct PlaintextChunkMeta: Sendable, Hashable, Codable {

    /// Nanosegundos monotónicos, la convención de `PacketMeta.timestamp`.
    public let timestamp: UInt64

    public let direction: Direction

    /// La conversación dentro de los ficheros: lo que el escritor repartió con `openStream()`. Se
    /// guarda en la fila para poder **validar** que el registro que hay en esa posición es el que se
    /// buscaba, y para agrupar sin la BD delante si alguna vez hace falta.
    public let stream: UInt64

    /// Fichero y posición del registro.
    public let location: PlaintextLocation

    /// Bytes que se guardaron de verdad.
    public let storedLength: UInt32

    /// Bytes que traía el trozo. `storedLength < originalLength` es "recortado", y las dos formas de
    /// que pase —el tope por registro y el presupuesto del flujo— se cuentan igual aquí: lo que la
    /// pantalla necesita saber es cuánto falta, no cuál de los dos topes lo cortó.
    public let originalLength: UInt32

    public init(
        timestamp: UInt64,
        direction: Direction,
        stream: UInt64,
        location: PlaintextLocation,
        storedLength: UInt32,
        originalLength: UInt32
    ) {
        self.timestamp = timestamp
        self.direction = direction
        self.stream = stream
        self.location = location
        self.storedLength = storedLength
        self.originalLength = originalLength
    }

    public var isTruncated: Bool { storedLength < originalLength }
}
