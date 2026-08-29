import Foundation
import Shared

/// Por dónde sale del relay el **contenido en claro** que produce una terminación TLS.
///
/// Es la tercera costura del mismo corte que `SNIObserving` y `TLSStatusObserving`, y existe por lo
/// mismo que las otras dos: el relay es quien tiene los bytes —la terminación se los ofrece trozo a
/// trozo— pero no sabe nada de flujos guardados. Quien puede atar un trozo a una fila del historial
/// es el pipeline, que es el dueño de la tabla de flujos y del volcado por lotes: el relay conoce la
/// `FlowKey`, y el id de la fila **solo existe en el volcado**, cuando `upsertFlow` lo devuelve.
///
/// Son tres protocolos y no uno porque son tres hechos distintos sobre un flujo: a quién llamó, si se
/// pudo inspeccionar, y qué dijo por dentro. El tercero además es el único que el usuario apaga por
/// separado (ADR 0007), así que fundirlo con los otros dos habría atado su interruptor al de ellos.
///
/// Es `async` por la misma razón que sus hermanas: quien lo implementa en producción es un actor
/// (`PacketPipeline`) y quien lo llama es otro (`Relay`). A diferencia de ellas se llama **muchas
/// veces por flujo**, así que el orden importa —los trozos *son* la conversación— y quien la usa
/// tiene que preservarlo; el relay lo hace con una cola serial.
public protocol PlaintextObserving: Sendable {
    func observe(plaintext: Data, direction: Direction, for key: FlowKey) async
}

/// La cola por la que los trozos descifrados cruzan del hilo que los produce al actor que los
/// guarda. **Serial y acotada**, por las mismas dos razones que la de las respuestas reinyectadas
/// del provider, y aquí la primera pesa más todavía:
///
/// - **Serial**, porque los trozos *son* la conversación. La terminación los entrega desde las colas
///   de sus dos patas, así que un `Task` por trozo los dejaría llegar en cualquier orden y el
///   contenido guardado diría algo que nadie escribió — que es peor que no guardarlo.
/// - **Acotada**, porque escribir toca disco y el hilo que descifra no puede quedarse esperándolo:
///   sin tope, un servidor rápido detrás de un disco lento haría crecer la memoria de la extensión
///   hasta que el sistema la mate. Llena, se descarta **lo nuevo** —se guarda el principio, que es la
///   misma regla que el presupuesto por flujo— y se cuenta, porque un hueco que nadie explica en algo
///   que el usuario va a leer es peor que un contador.
///
/// El candado justifica el `@unchecked Sendable`: protege el único campo mutable, y el descarte se
/// anota en el `yield`, que corre fuera del actor.
final class PlaintextChunkQueue: @unchecked Sendable {

    struct Chunk: Sendable {
        let key: FlowKey
        let data: Data
        let direction: Direction
    }

    /// Trozos que caben sin escribir. Un trozo es como mucho un record TLS descifrado (~16 KiB), así
    /// que 64 son ~1 MB en el peor caso: el mismo orden de magnitud que la cola de respuestas
    /// reinyectadas, y lo que la extensión puede permitirse si el disco se retrasa.
    static let capacity = 64

    let stream: AsyncStream<Chunk>
    private let continuation: AsyncStream<Chunk>.Continuation
    private let lock = NSLock()
    private var dropped: UInt64 = 0

    init(capacity: Int = PlaintextChunkQueue.capacity) {
        let (stream, continuation) = AsyncStream<Chunk>.makeStream(
            bufferingPolicy: .bufferingOldest(capacity)
        )
        self.stream = stream
        self.continuation = continuation
    }

    func enqueue(_ chunk: Chunk) {
        guard case .dropped = continuation.yield(chunk) else { return }
        lock.lock()
        dropped &+= 1
        lock.unlock()
    }

    /// Cierra la entrada. Lo ya encolado se sigue entregando: son bytes que el usuario ya descifró.
    func finish() {
        continuation.finish()
    }

    var droppedCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return dropped
    }
}
