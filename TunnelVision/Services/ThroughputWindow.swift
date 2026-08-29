import Foundation
import Shared

/// Una barra del gráfico de throughput: los bytes de un intervalo, por sentido.
public struct ThroughputSample: Sendable, Hashable, Identifiable {

    /// Instante en que empieza el intervalo. Es el `id`: los intervalos no se solapan.
    public let start: Date

    /// Anchura del intervalo, para poder convertir los bytes en una tasa sin conocer la política.
    public let duration: TimeInterval

    public let bytesIn: UInt64
    public let bytesOut: UInt64

    public var id: Date { start }

    public init(start: Date, duration: TimeInterval, bytesIn: UInt64, bytesOut: UInt64) {
        self.start = start
        self.duration = duration
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }

    public var bytesInPerSecond: Double { Double(bytesIn) / duration }
    public var bytesOutPerSecond: Double { Double(bytesOut) / duration }
}

/// Ventana rodante de throughput: lo que alimenta el gráfico en tiempo real de la Dashboard.
///
/// Es un anillo de barras de anchura fija, indexado por el número de intervalo desde el epoch
/// (`floor(t / bucketDuration)`), así que:
///
/// - el coste de acumular un paquete es O(1) y la memoria es fija (`windowDuration / bucketDuration`
///   barras), da igual el tráfico — la misma filosofía acotada que el resto del proyecto;
/// - la alineación de las barras no depende de cuándo se creó la ventana, lo que hace el resultado
///   determinista y comparable entre ejecuciones;
/// - un paquete más viejo que la ventana **se descarta contándolo** (`lateRecords`) en vez de
///   contaminar una barra que no le corresponde. El criterio es su distancia al intervalo más nuevo
///   visto, no la colisión de posiciones: dos índices separados por menos de una vuelta del anillo
///   caen en posiciones distintas, así que la colisión sola dejaría pasar en silencio a la mitad de
///   los tardíos, que acabarían en una barra fuera del eje y nadie los vería.
///
/// `samples(asOf:)` rellena a cero los intervalos sin tráfico: sin ellos, Swift Charts uniría dos
/// picos con una recta y el gráfico afirmaría un tráfico continuo que no existió.
public struct ThroughputWindow: Sendable, Equatable {

    private struct Bucket: Sendable, Equatable {
        /// Índice de intervalo que ocupa la posición, o `nil` si nunca se usó.
        var index: Int64?
        var bytesIn: UInt64
        var bytesOut: UInt64
    }

    public let bucketDuration: TimeInterval
    public let bucketCount: Int

    /// Paquetes descartados por llegar fuera de la ventana. Monótono; lo publica el snapshot.
    public private(set) var lateRecords: UInt64 = 0

    private var buckets: [Bucket]

    /// Intervalo más nuevo que ha entrado. Define dónde acaba la ventana viva y, con ella, qué cuenta
    /// como tardío.
    private var newestIndex: Int64?

    public init(bucketDuration: TimeInterval = 1, windowDuration: TimeInterval = 60) {
        precondition(bucketDuration > 0, "bucketDuration debe ser positiva")
        precondition(windowDuration >= bucketDuration, "la ventana no cabe en una barra")
        self.bucketDuration = bucketDuration
        self.bucketCount = max(1, Int((windowDuration / bucketDuration).rounded()))
        self.buckets = Array(repeating: Bucket(index: nil, bytesIn: 0, bytesOut: 0), count: bucketCount)
    }

    /// Acumula un paquete en su barra. Ignorar el sentido no es opción: el gráfico dibuja dos series.
    public mutating func add(date: Date, direction: Direction, length: UInt32) {
        let index = bucketIndex(for: date)

        if let newest = newestIndex, index <= newest - Int64(bucketCount) {
            lateRecords &+= 1
            return
        }
        if newestIndex == nil || index > newestIndex! {
            newestIndex = index
        }

        // Superado ese filtro, cualquier ocupante distinto de esta posición es necesariamente más
        // antiguo (dos índices que colisionan distan un múltiplo de `bucketCount`), así que se recicla.
        let slot = slotIndex(for: index)
        if buckets[slot].index != index {
            buckets[slot] = Bucket(index: index, bytesIn: 0, bytesOut: 0)
        }

        switch direction {
        case .inbound:
            buckets[slot].bytesIn &+= UInt64(length)
        case .outbound:
            buckets[slot].bytesOut &+= UInt64(length)
        }
    }

    /// Las barras de la ventana que termina en `now`, de la más antigua a la más reciente, con los
    /// intervalos vacíos a cero. Siempre devuelve `bucketCount` muestras: el eje del gráfico es fijo y
    /// no encoge cuando cesa el tráfico.
    public func samples(asOf now: Date) -> [ThroughputSample] {
        let last = bucketIndex(for: now)
        let first = last - Int64(bucketCount - 1)
        return (first...last).map { index in
            let slot = slotIndex(for: index)
            let bucket = buckets[slot]
            let matches = bucket.index == index
            return ThroughputSample(
                start: Date(timeIntervalSince1970: Double(index) * bucketDuration),
                duration: bucketDuration,
                bytesIn: matches ? bucket.bytesIn : 0,
                bytesOut: matches ? bucket.bytesOut : 0
            )
        }
    }

    /// Vacía la ventana. La llama el lector al empezar una sesión nueva: el gráfico es de la sesión.
    public mutating func reset() {
        buckets = Array(repeating: Bucket(index: nil, bytesIn: 0, bytesOut: 0), count: bucketCount)
        newestIndex = nil
        lateRecords = 0
    }

    private func bucketIndex(for date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 / bucketDuration).rounded(.down))
    }

    /// Posición en el anillo. El resto se corrige a positivo porque un índice puede ser negativo
    /// (fechas anteriores a 1970 que llegarían de un sello corrupto) y `%` conserva el signo en Swift.
    private func slotIndex(for index: Int64) -> Int {
        let count = Int64(bucketCount)
        return Int(((index % count) + count) % count)
    }
}
