import Foundation
import Shared

/// Reensamblador de un stream TCP en un sentido: reconstruye el orden de bytes original a partir
/// de segmentos que pueden llegar desordenados, duplicados o solapados.
///
/// Solo se instancia para flujos bajo inspección (TLS opt-in en 443 aún no marcado como pinneado,
/// o TCP en claro que sí desciframos). El TCP de puro passthrough **no** se reensambla: gastaría
/// el presupuesto de memoria de la extensión sin aportar nada.
///
/// Todo aquí está acotado por diseño. Un único flujo malicioso (un hueco enorme seguido de una
/// tormenta de segmentos fuera de orden) podría, si no, agotar los pocos MB de la extensión y
/// hacer que el sistema la mate, tirando la conectividad del usuario. Cada buffer tiene un techo
/// duro y una degradación definida (`.downgraded` ⇒ solo metadatos) en lugar de crecer sin límite.
///
/// Los números de secuencia son `UInt32` y **dan la vuelta**: todas las comparaciones usan
/// aritmética serial (RFC 1982), no `<`/`>` a secas.
public struct TCPReassembler: Sendable {

    public struct Config: Sendable {
        /// Tope duro de bytes fuera de orden retenidos por flujo (por defecto 256 KiB).
        public var maxBufferedBytes: Int
        /// Tope de fragmentos fuera de orden distintos retenidos por flujo.
        public var maxOutOfOrderSegments: Int

        public init(maxBufferedBytes: Int = 256 * 1024, maxOutOfOrderSegments: Int = 128) {
            self.maxBufferedBytes = maxBufferedBytes
            self.maxOutOfOrderSegments = maxOutOfOrderSegments
        }
    }

    public enum Outcome: Sendable, Equatable {
        /// Bytes nuevos, en orden, listos para la capa superior.
        case delivered(Data)
        /// Segmento por delante del hueco: guardado, aún no entregable.
        case buffered
        /// Sin bytes nuevos: retransmisión ya vista, segmento de control sin payload, o solape
        /// completo con lo ya bufferizado. Se ignora sin efecto.
        case duplicate
        /// Se superó un tope: se abandona el reensamblado, se libera el buffer y el flujo pasa a
        /// solo-metadatos. Todas las llamadas posteriores devuelven `.downgraded`.
        case downgraded
    }

    /// Sentido que reconstruye esta instancia (una por dirección del flujo).
    public let direction: Direction

    private let config: Config
    private var nextExpectedSeq: UInt32
    private var buffered: [BufferedSegment]
    private var bufferedBytes: Int
    private var downgraded: Bool

    /// Un segmento fuera de orden retenido. Los segmentos en `buffered` son siempre disjuntos y
    /// están por delante de `nextExpectedSeq` (la contigüidad hacia atrás se resuelve al entregar).
    private struct BufferedSegment: Sendable {
        var seq: UInt32
        var data: Data
    }

    /// - Parameter isn: ISN del SYN de este sentido. El SYN consume un número de secuencia, así
    ///   que el primer byte de datos llega en `isn + 1`.
    public init(config: Config, isn: UInt32, direction: Direction) {
        self.config = config
        self.direction = direction
        self.nextExpectedSeq = isn &+ 1
        self.buffered = []
        self.bufferedBytes = 0
        self.downgraded = false
    }

    /// `true` una vez superado un tope: el reensamblado se abandonó y el buffer se liberó.
    public var isDowngraded: Bool { downgraded }

    /// Bytes fuera de orden retenidos ahora mismo (para verificar el techo en tests/telemetría).
    public var bufferedByteCount: Int { bufferedBytes }

    /// Próximo número de secuencia esperado en orden (expuesto para inspección/tests).
    public var expectedSequence: UInt32 { nextExpectedSeq }

    /// Alimenta un segmento de este sentido y devuelve qué pudo entregarse en orden.
    public mutating func accept(sequence: UInt32, payload: Data, flags: TCPFlags) -> Outcome {
        if downgraded { return .downgraded }

        let length = payload.count
        // Un segmento de control (ACK/SYN/FIN puro) no aporta bytes al stream.
        guard length > 0 else { return .duplicate }

        let end = sequence &+ UInt32(length)

        // Todo el rango cae en lo ya entregado ⇒ retransmisión, se ignora.
        if seqLEQ(end, nextExpectedSeq) { return .duplicate }

        // Por delante del hueco ⇒ se bufferiza (con techo).
        if seqGT(sequence, nextExpectedSeq) {
            return bufferAhead(sequence: sequence, payload: payload)
        }

        // Solapa el frente (`sequence <= nextExpectedSeq < end`): se recorta el prefijo ya
        // entregado y se entrega el resto, empalmando lo que hubiera bufferizado y ahora sea
        // contiguo.
        let alreadyDelivered = Int(nextExpectedSeq &- sequence)   // >= 0 y < length
        let start = payload.startIndex + alreadyDelivered
        var delivered = payload.subdata(in: start..<payload.endIndex)
        nextExpectedSeq = end
        delivered.append(spliceContiguous())
        return .delivered(delivered)
    }

    // MARK: - Bufferizado fuera de orden

    /// Guarda la parte del segmento que aún no está en el buffer, restando los rangos ya
    /// bufferizados para no duplicar bytes ni el conteo. Devuelve `.duplicate` si todo el
    /// segmento ya estaba, `.downgraded` si añadirlo superaría un tope, o `.buffered`.
    private mutating func bufferAhead(sequence: UInt32, payload: Data) -> Outcome {
        // Se trabaja en "espacio de offset" relativo a `nextExpectedSeq`: los segmentos por
        // delante tienen offset positivo y pequeño (dentro de la ventana), lo que evita la
        // aritmética modular al calcular solapes.
        let newStart = Int(sequence &- nextExpectedSeq)
        let newEnd = newStart + payload.count

        let existing = buffered
            .map { (start: Int($0.seq &- nextExpectedSeq), end: Int($0.seq &- nextExpectedSeq) + $0.data.count) }
            .sorted { $0.start < $1.start }

        var fragments: [(offset: Int, data: Data)] = []
        var cursor = newStart
        for range in existing {
            if range.end <= cursor { continue }       // enteramente antes del cursor
            if range.start >= newEnd { break }         // más allá del segmento nuevo: fin
            if range.start > cursor {
                // El hueco [cursor, range.start) es contenido nuevo.
                fragments.append(fragment(of: payload, base: newStart, from: cursor, to: min(range.start, newEnd)))
            }
            cursor = max(cursor, range.end)
            if cursor >= newEnd { break }
        }
        if cursor < newEnd {
            fragments.append(fragment(of: payload, base: newStart, from: cursor, to: newEnd))
        }

        if fragments.isEmpty { return .duplicate }

        let addedBytes = fragments.reduce(0) { $0 + $1.data.count }
        if bufferedBytes + addedBytes > config.maxBufferedBytes
            || buffered.count + fragments.count > config.maxOutOfOrderSegments {
            downgrade()
            return .downgraded
        }

        for fragment in fragments {
            buffered.append(BufferedSegment(seq: nextExpectedSeq &+ UInt32(fragment.offset), data: fragment.data))
            bufferedBytes += fragment.data.count
        }
        return .buffered
    }

    /// Extrae `[from, to)` (en espacio de offset) del payload cuyo inicio está en `base`.
    private func fragment(of payload: Data, base: Int, from: Int, to: Int) -> (offset: Int, data: Data) {
        let lo = payload.startIndex + (from - base)
        let hi = payload.startIndex + (to - base)
        return (offset: from, data: payload.subdata(in: lo..<hi))
    }

    // MARK: - Empalme y degradado

    /// Tras avanzar `nextExpectedSeq`, entrega en cadena los segmentos bufferizados que ahora sean
    /// contiguos. Antes, purga/recorta los que hayan quedado detrás por el avance del frente.
    private mutating func spliceContiguous() -> Data {
        trimBufferedBehind()
        var out = Data()
        while let index = buffered.firstIndex(where: { $0.seq == nextExpectedSeq }) {
            let segment = buffered.remove(at: index)
            bufferedBytes -= segment.data.count
            out.append(segment.data)
            nextExpectedSeq = nextExpectedSeq &+ UInt32(segment.data.count)
        }
        return out
    }

    /// Elimina los segmentos bufferizados totalmente cubiertos por `nextExpectedSeq` y recorta el
    /// prefijo de los parcialmente cubiertos, para que ningún byte ya entregado se entregue otra vez.
    private mutating func trimBufferedBehind() {
        buffered = buffered.compactMap { segment in
            let segmentEnd = segment.seq &+ UInt32(segment.data.count)
            if seqLEQ(segmentEnd, nextExpectedSeq) {
                bufferedBytes -= segment.data.count
                return nil
            }
            if seqLT(segment.seq, nextExpectedSeq) {
                let drop = Int(nextExpectedSeq &- segment.seq)
                bufferedBytes -= drop
                let trimmed = segment.data.subdata(in: (segment.data.startIndex + drop)..<segment.data.endIndex)
                return BufferedSegment(seq: nextExpectedSeq, data: trimmed)
            }
            return segment
        }
    }

    private mutating func downgrade() {
        downgraded = true
        buffered.removeAll(keepingCapacity: false)
        bufferedBytes = 0
    }

    // MARK: - Aritmética serial (RFC 1982)

    // Los números de secuencia TCP dan la vuelta al llegar a `UInt32.max`; el orden se compara
    // sobre la diferencia con signo, válido mientras los dos valores estén a menos de 2^31.
    private func seqLT(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) < 0 }
    private func seqLEQ(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) <= 0 }
    private func seqGT(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) > 0 }
}
