import Foundation
import XCTest
import Shared

/// Tests de la ventana rodante de throughput (M9), lo que alimenta el gráfico de la Dashboard.
///
/// Lo que se verifica no es "suma bytes" sino las tres propiedades que hacen que el gráfico **no
/// mienta**: los huecos se dibujan como ceros y no como una recta entre picos, lo que se sale de la
/// ventana se descarta contándolo en vez de contaminar una barra ajena, y la memoria no crece con el
/// tráfico.
final class ThroughputWindowTests: XCTestCase {

    /// Instante alineado al segundo, para que las barras de 1 s empiecen exactamente aquí.
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func window(bucket: TimeInterval = 1, span: TimeInterval = 10) -> ThroughputWindow {
        ThroughputWindow(bucketDuration: bucket, windowDuration: span)
    }

    // MARK: - Acumulación

    func testBytesLandInTheBucketOfTheirTimestampAndKeepTheirSenseApart() {
        var window = self.window()
        window.add(date: t0, direction: .outbound, length: 100)
        window.add(date: t0.addingTimeInterval(0.4), direction: .inbound, length: 250)
        window.add(date: t0.addingTimeInterval(1.2), direction: .outbound, length: 40)

        let samples = window.samples(asOf: t0.addingTimeInterval(1.5))
        let first = samples.first { $0.start == t0 }
        let second = samples.first { $0.start == t0.addingTimeInterval(1) }

        XCTAssertEqual(first?.bytesOut, 100)
        XCTAssertEqual(first?.bytesIn, 250)
        XCTAssertEqual(second?.bytesOut, 40)
        XCTAssertEqual(second?.bytesIn, 0)
    }

    /// Las barras se alinean al reloj, no al primer paquete: así dos ejecuciones producen los mismos
    /// intervalos y el eje no baila según cuándo se creó la ventana.
    func testBucketsAreAlignedToTheClockAndNotToTheFirstPacket() {
        var window = self.window()
        window.add(date: t0.addingTimeInterval(0.73), direction: .outbound, length: 10)

        let samples = window.samples(asOf: t0.addingTimeInterval(0.9))

        XCTAssertEqual(samples.last?.start, t0)
        for sample in samples {
            XCTAssertEqual(sample.start.timeIntervalSince1970.truncatingRemainder(dividingBy: 1), 0, accuracy: 1e-9)
        }
    }

    // MARK: - Forma de la ventana

    /// El eje es fijo: sin tráfico siguen saliendo todas las barras, a cero. Si la ventana encogiera,
    /// el gráfico se estiraría y aparentaría actividad continua.
    func testAnEmptyWindowStillReportsItsFullWidth() {
        let window = self.window(bucket: 1, span: 10)

        let samples = window.samples(asOf: t0)

        XCTAssertEqual(samples.count, 10)
        XCTAssertTrue(samples.allSatisfy { $0.bytesIn == 0 && $0.bytesOut == 0 })
        XCTAssertEqual(samples.map(\.start), (0..<10).map { t0.addingTimeInterval(Double($0) - 9) })
    }

    /// El hueco entre dos picos se rellena a cero. Es la razón de ser de `samples(asOf:)`: sin las
    /// barras vacías, Swift Charts uniría los dos picos con una recta y afirmaría un tráfico que no
    /// existió.
    func testTheGapBetweenTwoBurstsIsFilledWithZeros() {
        var window = self.window()
        window.add(date: t0, direction: .outbound, length: 500)
        window.add(date: t0.addingTimeInterval(4), direction: .outbound, length: 700)

        let samples = window.samples(asOf: t0.addingTimeInterval(4))
        let byStart = Dictionary(uniqueKeysWithValues: samples.map { ($0.start, $0) })

        XCTAssertEqual(byStart[t0]?.bytesOut, 500)
        XCTAssertEqual(byStart[t0.addingTimeInterval(4)]?.bytesOut, 700)
        for offset in 1...3 {
            XCTAssertEqual(byStart[t0.addingTimeInterval(Double(offset))]?.bytesOut, 0)
        }
    }

    /// La ventana rueda: al avanzar el tiempo, la barra más vieja sale del eje aunque tuviera datos.
    func testTheOldestBucketLeavesTheWindowAsTimeAdvances() {
        var window = self.window(bucket: 1, span: 3)
        window.add(date: t0, direction: .inbound, length: 90)

        let inWindow = window.samples(asOf: t0.addingTimeInterval(2))
        let outOfWindow = window.samples(asOf: t0.addingTimeInterval(3))

        XCTAssertEqual(inWindow.first?.start, t0)
        XCTAssertEqual(inWindow.first?.bytesIn, 90)
        XCTAssertEqual(outOfWindow.first?.start, t0.addingTimeInterval(1))
        XCTAssertTrue(outOfWindow.allSatisfy { $0.bytesIn == 0 })
    }

    // MARK: - Degradación acotada

    /// Un paquete anterior a la ventana caería en una posición ya reciclada por una barra más nueva.
    /// Se descarta **y se cuenta**: sumarlo ahí inventaría tráfico en un instante equivocado, y
    /// tragárselo en silencio escondería que la ventana está mal dimensionada.
    func testAPacketOlderThanTheWindowIsCountedAsLateAndDiscarded() {
        var window = self.window(bucket: 1, span: 3)
        window.add(date: t0.addingTimeInterval(10), direction: .outbound, length: 400)

        window.add(date: t0, direction: .outbound, length: 999)

        XCTAssertEqual(window.lateRecords, 1)
        let samples = window.samples(asOf: t0.addingTimeInterval(10))
        XCTAssertEqual(samples.map(\.bytesOut).reduce(0, +), 400)
    }

    /// Un flujo sostenido no hace crecer la ventana: la memoria es la de sus barras, no la del
    /// tráfico. 20 000 paquetes repartidos en 312,5 s sobre una ventana de 10 s.
    ///
    /// El espaciado es 1/64 s —exacto en binario— para que ningún paquete cambie de barra por el
    /// redondeo del `Double` y el recuento esperado sea el mismo en cualquier máquina: 64 paquetes
    /// por barra, y la última (312) solo llega hasta 312,5 ⇒ 9·64 + 32 = 608 paquetes de 100 B.
    func testASustainedStreamDoesNotGrowTheWindow() {
        var window = self.window(bucket: 1, span: 10)
        for i in 0..<20_000 {
            window.add(
                date: t0.addingTimeInterval(Double(i) / 64),
                direction: i.isMultiple(of: 2) ? .inbound : .outbound,
                length: 100
            )
        }

        let samples = window.samples(asOf: t0.addingTimeInterval(312.5))

        XCTAssertEqual(samples.count, 10)
        XCTAssertEqual(window.lateRecords, 0)
        XCTAssertEqual(samples.map(\.bytesIn).reduce(0, +) + samples.map(\.bytesOut).reduce(0, +), 60_800)
    }

    // MARK: - Presentación

    /// La tasa se deriva de la anchura de la barra, así que la vista no necesita conocer la política.
    func testTheRateDividesByTheBucketWidth() {
        var window = self.window(bucket: 2, span: 10)
        window.add(date: t0, direction: .inbound, length: 3_000)

        let sample = window.samples(asOf: t0).last

        XCTAssertEqual(sample?.duration, 2)
        XCTAssertEqual(sample?.bytesInPerSecond ?? 0, 1_500, accuracy: 1e-9)
        XCTAssertEqual(sample?.bytesOutPerSecond ?? -1, 0, accuracy: 1e-9)
    }

    /// `reset` deja la ventana como recién creada: el gráfico es de la sesión, no del proceso.
    func testResetEmptiesTheWindowAndItsLateCounter() {
        var window = self.window(bucket: 1, span: 3)
        window.add(date: t0.addingTimeInterval(10), direction: .outbound, length: 400)
        window.add(date: t0, direction: .outbound, length: 999)
        XCTAssertEqual(window.lateRecords, 1)

        window.reset()

        XCTAssertEqual(window.lateRecords, 0)
        XCTAssertTrue(window.samples(asOf: t0.addingTimeInterval(10)).allSatisfy { $0.bytesOut == 0 })
    }
}
