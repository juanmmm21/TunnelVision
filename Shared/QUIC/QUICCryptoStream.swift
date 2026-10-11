import Foundation

/// El stream CRYPTO de un nivel de cifrado, recompuesto por desplazamiento: entran frames en el
/// orden en que viajan y salen los bytes del stream **en orden y una sola vez**.
///
/// Hace falta porque un ClientHello de hoy no cabe en un Initial —el intercambio de claves
/// poscuántico lo lleva a dos o tres— y porque sus frames llegan desordenados, repetidos y
/// solapados: los paquetes se adelantan unos a otros, una retransmisión repite lo ya visto, y hay
/// clientes que trocean y barajan el ClientHello a propósito dentro de un mismo paquete.
///
/// **No guarda lo que ya entregó**: quien lo usa se lo va dando a un lector incremental, que tiene
/// su propio tope. Aquí solo vive lo que llegó adelantado, a la espera del hueco que tiene delante.
public struct QUICCryptoStream: Sendable, Equatable {

    /// Cuánto se le deja ocupar a un stream. No tienen valor por defecto: los frames los escribe
    /// el otro extremo, esto corre en la extensión, y cuánta memoria vale el nombre de un flujo lo
    /// decide quien lo engancha.
    public struct Limits: Sendable, Equatable {
        /// Hasta qué desplazamiento del stream se acepta un byte. Como lo adelantado se guarda sin
        /// solapes, es también el techo de lo que el stream retiene.
        public let maxStreamBytes: Int
        /// Cuántos trozos separados por huecos pueden estar esperando a la vez.
        public let maxPendingFragments: Int

        public init(maxStreamBytes: Int, maxPendingFragments: Int) {
            self.maxStreamBytes = maxStreamBytes
            self.maxPendingFragments = maxPendingFragments
        }
    }

    /// El tope que un stream se saltó.
    public enum Exceeded: Sendable, Equatable {
        /// Un frame llega más allá de `maxStreamBytes`.
        case streamBytes
        /// Hay más de `maxPendingFragments` trozos esperando un hueco.
        case pendingFragments
    }

    /// Qué dio de sí un frame.
    public enum Delivery: Sendable, Equatable {
        /// Los bytes que con este frame quedan en orden, a continuación de los ya entregados.
        /// Vacío si el frame repite lo entregado o si tiene un hueco delante.
        case delivered(Data)
        /// El stream se saltó un tope y se abandonó: no entrega nada más.
        case exceeded(Exceeded)
    }

    /// Un trozo adelantado. Los pendientes van ordenados y nunca se tocan ni se solapan: dos que
    /// llegaran a tocarse se funden en uno.
    private struct Fragment: Sendable, Equatable {
        let start: Int
        var data: Data
        var end: Int { start + data.count }
    }

    public let limits: Limits
    /// Cuántos bytes del stream se han entregado ya; el siguiente que se espera está ahí.
    public private(set) var deliveredByteCount: Int
    /// El tope que acabó con el stream, si alguno lo hizo.
    public private(set) var exceeded: Exceeded?
    private var pending: [Fragment]

    public init(limits: Limits) {
        self.limits = limits
        self.deliveredByteCount = 0
        self.exceeded = nil
        self.pending = []
    }

    /// Cuántos trozos esperan un hueco.
    public var pendingFragmentCount: Int { pending.count }

    /// Mete un frame en el stream y devuelve lo que con él queda en orden.
    ///
    /// **Si dos frames traen bytes distintos para el mismo sitio, valen los que llegaron antes.**
    /// No se comparan: tratarlo como error es un MAY de quien recibe (RFC 9000 § 2.2), y aquí
    /// basta con que un frame posterior no pueda reescribir lo que ya se leyó.
    public mutating func insert(_ frame: QUICCryptoFrame) -> Delivery {
        if let exceeded { return .exceeded(exceeded) }

        // Se compara restando del tope para que un desplazamiento enorme no desborde la suma.
        let limit = UInt64(max(0, limits.maxStreamBytes))
        guard frame.offset <= limit, UInt64(frame.data.count) <= limit - frame.offset else {
            return giveUp(.streamBytes)
        }

        let start = Int(frame.offset)
        let end = start + frame.data.count
        // Lo que cae entero en lo ya entregado, y el frame sin datos, no cambian nada.
        guard end > deliveredByteCount, !frame.data.isEmpty else { return .delivered(Data()) }

        let skipped = max(0, deliveredByteCount - start)
        merge(Fragment(start: start + skipped, data: Data(frame.data.dropFirst(skipped))))

        // Tras fundir, solo el primer pendiente puede empezar donde se espera el siguiente byte.
        var delivered = Data()
        if let first = pending.first, first.start == deliveredByteCount {
            delivered = first.data
            deliveredByteCount = first.end
            pending.removeFirst()
        }
        guard pending.count <= limits.maxPendingFragments else { return giveUp(.pendingFragments) }
        return .delivered(delivered)
    }

    /// Funde `fragment` con los pendientes que solapa o toca, dejando en su sitio los bytes que
    /// ya estaban.
    private mutating func merge(_ fragment: Fragment) {
        // Los pendientes no se tocan entre sí, así que los que `fragment` alcanza son un tramo
        // seguido de la lista.
        let firstTouched = pending.firstIndex { $0.end >= fragment.start } ?? pending.endIndex
        let afterTouched = pending[firstTouched...].firstIndex { $0.start > fragment.end } ?? pending.endIndex
        let touched = pending[firstTouched..<afterTouched]

        let start = min(fragment.start, touched.first?.start ?? fragment.start)
        let end = max(fragment.end, touched.last?.end ?? fragment.end)
        var bytes = [UInt8](repeating: 0, count: end - start)
        // Primero el recién llegado y encima los que estaban: así ganan los que llegaron antes.
        // Entre los dos cubren el tramo entero, porque cada uno de los fundidos toca al nuevo.
        for piece in [fragment] + touched {
            bytes.replaceSubrange((piece.start - start)..<(piece.end - start), with: piece.data)
        }
        pending.replaceSubrange(firstTouched..<afterTouched, with: [Fragment(start: start, data: Data(bytes))])
    }

    private mutating func giveUp(_ reason: Exceeded) -> Delivery {
        // Abandonado: lo pendiente no va a entregarse nunca y no hay por qué seguir guardándolo.
        pending = []
        exceeded = reason
        return .exceeded(reason)
    }
}
