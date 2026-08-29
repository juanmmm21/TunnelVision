import Foundation
import XCTest
@testable import Shared

/// Tests del núcleo puro del eje temporal: la anchura de barra que se elige, el relleno a cero y lo
/// que el eje deriva de sus barras. Todo se afirma directamente, sin store: la consulta se prueba en
/// `FlowStoreTests` y el acoplamiento entre las dos mitades, en `HistoryReaderTests`.
final class TimelineActivityTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func span(_ seconds: TimeInterval) -> ClosedRange<Date> {
        epoch...epoch.addingTimeInterval(seconds)
    }

    private func bucket(_ offset: TimeInterval, _ count: Int) -> PacketBucket {
        PacketBucket(start: epoch.addingTimeInterval(offset), packetCount: count)
    }

    // MARK: - Anchura de la barra

    /// Se elige el escalón redondo más fino que quepa, no el que dé exactamente `maxBars` barras: la
    /// resolución se gasta solo hasta donde el tramo la aprovecha.
    func testTheFinestRoundRungThatFitsIsChosen() {
        // 40 s con 48 barras: el segundo cabe (41 barras) y es el más fino.
        XCTAssertEqual(TimelineActivity.bucketDuration(forSpan: 40, maxBars: 48), 1)
        // 10 min: el segundo daría 601 barras; los 15 s dan 41.
        XCTAssertEqual(TimelineActivity.bucketDuration(forSpan: 600, maxBars: 48), 15)
        // Un día: la hora da 25 barras.
        XCTAssertEqual(TimelineActivity.bucketDuration(forSpan: 86_400, maxBars: 48), 3_600)
        // Una semana: 4 h dan 43.
        XCTAssertEqual(TimelineActivity.bucketDuration(forSpan: 604_800, maxBars: 48), 14_400)
    }

    /// Por qué la escalera tiene peldaños intermedios. Desde que el número de tramos lo decide el
    /// **ancho** de la pantalla (`ScrubCapacity`), el eje pide cinco o seis barras y no cuarenta y
    /// ocho, y una escalera que saltase de la hora a las seis horas contestaría a un historial de seis
    /// horas con **dos** barras: un eje que ya no es un eje. Se afirma sobre el tramo que la app
    /// enseña de verdad y sobre el que cabe en el iPhone más estrecho.
    func testFewBarsStillGetAnAxisWithShapeAndNotTwoBlocks() {
        let sixHours: TimeInterval = 21_600
        for maxBars in 4...9 {
            let duration = TimelineActivity.bucketDuration(forSpan: sixHours, maxBars: maxBars)
            let bars = TimelineActivity.barCount(forSpan: sixHours, bucketDuration: duration)
            XCTAssertLessThanOrEqual(bars, maxBars)
            XCTAssertGreaterThanOrEqual(
                bars, maxBars - 3,
                "con \(maxBars) tramos permitidos, seis horas se quedan en \(bars) barras"
            )
        }
    }

    /// Todos los escalones son redondos, que es lo que hace legible el tramo que se selecciona.
    func testEveryRungIsARoundAmountOfTime() {
        for rung in TimelineActivity.bucketLadder {
            XCTAssertEqual(rung, rung.rounded(), "el escalón \(rung) no es un número entero de segundos")
        }
        XCTAssertEqual(TimelineActivity.bucketLadder, TimelineActivity.bucketLadder.sorted())
    }

    /// Un historial más largo que lo que cubre el escalón más grueso se reparte entre las barras
    /// disponibles: deja de ser redondo, pero el eje sigue cubriéndolo entero.
    func testAHistoryTooLongForTheLadderIsSharedOutAcrossTheBars() {
        let tenYears: TimeInterval = 10 * 365 * 86_400
        let duration = TimelineActivity.bucketDuration(forSpan: tenYears, maxBars: 48)

        XCTAssertFalse(TimelineActivity.bucketLadder.contains(duration))
        XCTAssertEqual(duration, tenYears / 48, accuracy: 0.001)

        let axis = TimelineActivity.axis(
            counts: [], span: span(tenYears), bucketDuration: duration, maxBars: 48
        )
        XCTAssertEqual(axis.bars.count, 48)
        XCTAssertEqual(axis.span?.upperBound.timeIntervalSince(epoch) ?? 0, tenYears, accuracy: 0.001)
    }

    /// Un solo paquete guardado (o dos con el mismo sello) es un tramo nulo: una barra, no cero.
    func testAZeroLengthSpanStillGetsOneBar() {
        let duration = TimelineActivity.bucketDuration(forSpan: 0, maxBars: 48)
        XCTAssertEqual(duration, TimelineActivity.bucketLadder[0])

        let axis = TimelineActivity.axis(
            counts: [bucket(0, 3)], span: span(0), bucketDuration: duration, maxBars: 48
        )
        XCTAssertEqual(axis.bars.count, 1)
        XCTAssertEqual(axis.bars.first?.packetCount, 3)
    }

    /// El `+1` de la cuenta de barras es lo que mete el instante final **dentro** del eje.
    func testTheBarCountCoversTheClosingInstant() {
        XCTAssertEqual(TimelineActivity.barCount(forSpan: 60, bucketDuration: 10), 7)
        XCTAssertEqual(TimelineActivity.barCount(forSpan: 59, bucketDuration: 10), 6)
        XCTAssertEqual(TimelineActivity.barCount(forSpan: 0, bucketDuration: 10), 1)
    }

    // MARK: - Relleno a cero

    /// La razón de ser del relleno: sin las barras vacías, el dibujo uniría dos picos y afirmaría una
    /// actividad continua que no hubo (el mismo motivo que en `ThroughputWindow`).
    func testEmptyIntervalsAreFilledWithZeroes() {
        let axis = TimelineActivity.axis(
            counts: [bucket(0, 5), bucket(40, 2)],
            span: span(50),
            bucketDuration: 10,
            maxBars: 48
        )
        XCTAssertEqual(axis.bars.map(\.packetCount), [5, 0, 0, 0, 2, 0])
        XCTAssertEqual(axis.bars.map(\.duration), Array(repeating: 10, count: 6))
        XCTAssertEqual(
            axis.bars.map(\.start),
            (0..<6).map { epoch.addingTimeInterval(Double($0) * 10) }
        )
    }

    /// La última barra absorbe lo que caiga en el instante de cierre: ese paquete es el que define el
    /// final del eje, y dejarlo fuera sería no contar lo que marca su propio extremo.
    func testTheLastBarAbsorbsTheClosingInstant() {
        // El tramo pediría 4 barras de 10 s (0, 10, 20 y la del instante 30), pero el tope las deja
        // en 3: la cuenta del borde tiene que seguir contándose en la última.
        let axis = TimelineActivity.axis(
            counts: [bucket(0, 1), bucket(30, 4)],
            span: span(30),
            bucketDuration: 10,
            maxBars: 3
        )
        XCTAssertEqual(axis.bars.count, 3)
        XCTAssertEqual(axis.bars.map(\.packetCount), [1, 0, 4])
        XCTAssertEqual(axis.totalPackets, 5, "ninguna cuenta se pierde al recortar")
    }

    /// Un intervalo anterior al tramo no lo puede devolver la consulta (va acotada por el mismo
    /// rango), pero si llegase, sumarlo a la primera barra inventaría cuándo pasó.
    func testCountsBeforeTheSpanAreDiscardedRatherThanMoved() {
        let axis = TimelineActivity.axis(
            counts: [bucket(-100, 9), bucket(0, 2)],
            span: span(20),
            bucketDuration: 10,
            maxBars: 48
        )
        XCTAssertEqual(axis.totalPackets, 2)
    }

    func testAnAxisWithoutCountsIsAllZeroesAndNotEmpty() {
        let axis = TimelineActivity.axis(
            counts: [], span: span(30), bucketDuration: 10, maxBars: 48
        )
        XCTAssertFalse(axis.isEmpty, "hay tramo que enseñar: lo que no hubo es tráfico")
        XCTAssertEqual(axis.busiest, 0)
        XCTAssertTrue(axis.bars.allSatisfy(\.isQuiet))
    }

    // MARK: - Lo que el eje deriva

    func testTheAxisDerivesItsSpanScaleAndTotal() {
        let axis = TimelineActivity.axis(
            counts: [bucket(0, 3), bucket(20, 7)],
            span: span(30),
            bucketDuration: 10,
            maxBars: 48
        )
        XCTAssertEqual(axis.span?.lowerBound, epoch)
        // El extremo superior es el **final** de la última barra, no su principio.
        XCTAssertEqual(axis.span?.upperBound, epoch.addingTimeInterval(40))
        XCTAssertEqual(axis.busiest, 7)
        XCTAssertEqual(axis.totalPackets, 10)
    }

    func testTheEmptyAxisHasNoSpan() {
        XCTAssertTrue(ActivityAxis.empty.isEmpty)
        XCTAssertNil(ActivityAxis.empty.span)
        XCTAssertEqual(ActivityAxis.empty.busiest, 0)
        XCTAssertEqual(ActivityAxis.empty.totalPackets, 0)
    }

    /// Lo que traduce el punto que el dedo tocó en el tramo que se selecciona.
    func testTheBarContainingAnInstantIsFound() {
        let axis = TimelineActivity.axis(
            counts: [], span: span(30), bucketDuration: 10, maxBars: 48
        )
        XCTAssertEqual(axis.bar(containing: epoch)?.start, epoch)
        XCTAssertEqual(
            axis.bar(containing: epoch.addingTimeInterval(15))?.start,
            epoch.addingTimeInterval(10)
        )
        // Fuera del eje no hay tramo que devolver: mover el filtro a uno que el usuario no señaló
        // sería peor que ignorar el gesto.
        XCTAssertNil(axis.bar(containing: epoch.addingTimeInterval(-1)))
        XCTAssertNil(axis.bar(containing: epoch.addingTimeInterval(1_000)))
    }

    /// Una barra es un intervalo absoluto: es lo que se convierte en filtro al tocarla.
    func testABarKnowsItsAbsoluteRange() {
        let bar = ActivityBar(start: epoch, duration: 900, packetCount: 12)
        XCTAssertEqual(bar.range, epoch...epoch.addingTimeInterval(900))
        XCTAssertEqual(bar.end, epoch.addingTimeInterval(900))
        XCTAssertEqual(bar.id, epoch)
        XCTAssertFalse(bar.isQuiet)
        XCTAssertTrue(ActivityBar(start: epoch, duration: 900, packetCount: 0).isQuiet)
    }

    // MARK: - El tramo que barre un arrastre

    /// Un eje de 5 barras de 10 s desde el ancla, que es sobre el que se afirma el arrastre.
    private func sweepAxis() -> ActivityAxis {
        TimelineActivity.axis(counts: [], span: span(40), bucketDuration: 10, maxBars: 48)
    }

    /// Lo que el arrastre añade al toque: acotar varias barras de una vez. El tramo va de barra
    /// entera a barra entera, no de donde el dedo tocó — un filtro que empezase a mitad de una barra
    /// la dejaría resaltada entera mientras esconde parte de lo que esa barra cuenta.
    func testASweepCoversEveryBarItTouchesWhole() {
        let axis = sweepAxis()
        let range = axis.sweep(
            from: epoch.addingTimeInterval(13), to: epoch.addingTimeInterval(37)
        )
        XCTAssertEqual(range, epoch.addingTimeInterval(10)...epoch.addingTimeInterval(40))
    }

    /// El dedo va en los dos sentidos y el tramo que elige es el mismo: lo que se barre es un trozo
    /// del eje, no un camino con principio y final.
    func testASweepReadsTheSameInBothDirections() {
        let axis = sweepAxis()
        let forward = axis.sweep(from: epoch.addingTimeInterval(13), to: epoch.addingTimeInterval(37))
        let backward = axis.sweep(from: epoch.addingTimeInterval(37), to: epoch.addingTimeInterval(13))
        XCTAssertEqual(forward, backward)
    }

    /// Un dedo que entra o sale por el borde del gráfico da un instante que ningún tramo cubre: se
    /// acota al extremo del eje en vez de descartar el gesto, que es lo que distingue el arrastre del
    /// toque (ese sí se ignora fuera del eje, porque no iba hacia ningún extremo).
    func testASweepPastTheEdgesIsClampedToTheAxis() {
        let axis = sweepAxis()

        XCTAssertEqual(
            axis.sweep(from: epoch.addingTimeInterval(-3_600), to: epoch.addingTimeInterval(5)),
            epoch...epoch.addingTimeInterval(10)
        )
        XCTAssertEqual(
            axis.sweep(from: epoch.addingTimeInterval(35), to: epoch.addingTimeInterval(3_600)),
            epoch.addingTimeInterval(30)...epoch.addingTimeInterval(50)
        )
        // De punta a punta: el gesto más natural del que quiere volver a verlo todo.
        XCTAssertEqual(
            axis.sweep(from: epoch.addingTimeInterval(-1_000), to: epoch.addingTimeInterval(1_000)),
            axis.span
        )
    }

    /// Barrer dentro de una sola barra la elige entera: es el mismo tramo que daría tocarla, aunque
    /// el gesto no signifique lo mismo (el arrastre no baja el eje).
    func testASweepInsideOneBarSelectsThatBar() {
        let axis = sweepAxis()
        let range = axis.sweep(from: epoch.addingTimeInterval(21), to: epoch.addingTimeInterval(24))
        XCTAssertEqual(range, epoch.addingTimeInterval(20)...epoch.addingTimeInterval(30))
    }

    /// Sin barras no hay nada que barrer, y no hay extremo al que acotar. Es el mismo eje que hace
    /// que la barra ni siquiera se dibuje.
    func testAnEmptyAxisHasNothingToSweep() {
        XCTAssertNil(ActivityAxis.empty.sweep(from: epoch, to: epoch.addingTimeInterval(10)))
    }

    // MARK: - Cuándo se puede bajar a una barra

    private func bar(_ duration: TimeInterval, packets: Int = 3) -> ActivityBar {
        ActivityBar(start: epoch, duration: duration, packetCount: packets)
    }

    /// Bajar a un tramo tiene sentido mientras el eje que salga sea más fino que la barra que se tocó.
    func testABarIsZoomableWhileThereIsResolutionLeftBelowIt() {
        XCTAssertTrue(TimelineActivity.canZoom(into: bar(604_800), maxBars: 48))
        XCTAssertTrue(TimelineActivity.canZoom(into: bar(3_600), maxBars: 48))
        XCTAssertTrue(TimelineActivity.canZoom(into: bar(5), maxBars: 48))
    }

    /// En el escalón más fino no se puede subdividir nada: el eje que saldría tendría barras de la
    /// misma anchura que la que se tocó, así que el gesto costaría una consulta para no cambiar nada.
    func testTheFinestRungIsTheFloorOfTheZoom() {
        XCTAssertFalse(TimelineActivity.canZoom(into: bar(TimelineActivity.bucketLadder[0]), maxBars: 48))
    }

    /// Una barra vacía no esconde tráfico —los huecos van rellenos a cero—, así que dentro no hay nada
    /// que mirar; y un eje plano a cero es justo lo que se dice cuando la retención se lleva un tramo.
    func testAQuietBarIsNeverZoomable() {
        XCTAssertFalse(TimelineActivity.canZoom(into: bar(3_600, packets: 0), maxBars: 48))
    }

    /// El suelo lo pone la política y no la escalera: con muy pocas barras, el escalón de debajo puede
    /// no llegar a caber, y entonces bajar tampoco daría resolución nueva.
    func testTheFloorFollowsThePolicysBarsAndNotTheLadder() {
        // 5 s en 2 barras: el segundo daría 6 barras y no cabe, así que se queda en los 5 s.
        XCTAssertFalse(TimelineActivity.canZoom(into: bar(5), maxBars: 2))
        XCTAssertTrue(TimelineActivity.canZoom(into: bar(5), maxBars: 6))
    }

    /// Las barras de un historial larguísimo no son redondas (se reparte el tramo), pero se puede
    /// bajar a ellas igual: cualquier escalón de la escalera es más fino que eso.
    func testABarFromTheNonRoundFallbackIsZoomable() {
        let width = TimelineActivity.bucketDuration(forSpan: 604_800 * 500, maxBars: 48)
        XCTAssertGreaterThan(width, TimelineActivity.bucketLadder.last ?? 0)
        XCTAssertTrue(TimelineActivity.canZoom(into: bar(width), maxBars: 48))
    }
}
