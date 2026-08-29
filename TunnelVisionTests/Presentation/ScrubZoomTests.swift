import Foundation
import XCTest
@testable import Shared

/// Tests del camino de acercamientos de la barra de scrub: qué se apila, cómo se vuelve y qué salidas
/// se ofrecen. Es una pila y se prueba como tal — lo que decide *cuándo* se apila es
/// `TimelineActivity.canZoom`, y quién lo cablea, el view model.
final class ScrubZoomTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func range(_ from: TimeInterval, _ to: TimeInterval) -> ClosedRange<Date> {
        epoch.addingTimeInterval(from)...epoch.addingTimeInterval(to)
    }

    func testItStartsOverTheWholeHistory() {
        let zoom = ScrubZoom.wholeHistory
        XCTAssertNil(zoom.current, "sin nivel apilado el eje abarca todo el historial")
        XCTAssertFalse(zoom.isZoomed)
        XCTAssertFalse(zoom.offersFullReset)
        XCTAssertEqual(zoom.depth, 0)
    }

    /// Bajar apila, y lo que el eje enseña es siempre el último nivel.
    func testZoomingKeepsTheDeepestLevelAsTheCurrentOne() {
        var zoom = ScrubZoom.wholeHistory
        zoom.zoom(into: range(0, 3_600))
        zoom.zoom(into: range(0, 300))

        XCTAssertEqual(zoom.current, range(0, 300))
        XCTAssertEqual(zoom.depth, 2)
        XCTAssertTrue(zoom.isZoomed)
    }

    /// La salida es simétrica con la entrada: se deshace el camino nivel a nivel, y cada paso dice a
    /// qué tramo se llega para que la lista pueda acotarse a lo mismo que el eje enseña.
    func testZoomingOutWalksBackTheSamePath() {
        var zoom = ScrubZoom.wholeHistory
        zoom.zoom(into: range(0, 3_600))
        zoom.zoom(into: range(0, 300))

        XCTAssertEqual(zoom.zoomOut(), range(0, 3_600))
        XCTAssertEqual(zoom.current, range(0, 3_600))
        XCTAssertNil(zoom.zoomOut(), "el último paso devuelve a todo el historial")
        XCTAssertFalse(zoom.isZoomed)
    }

    /// Subir desde todo el historial no es un error ni deja la pila en un estado raro: no hay camino
    /// que deshacer.
    func testZoomingOutWithoutAnyLevelDoesNothing() {
        var zoom = ScrubZoom.wholeHistory
        XCTAssertNil(zoom.zoomOut())
        XCTAssertEqual(zoom, .wholeHistory)
    }

    func testResettingDropsEveryLevelAtOnce() {
        var zoom = ScrubZoom.wholeHistory
        zoom.zoom(into: range(0, 3_600))
        zoom.zoom(into: range(0, 300))
        zoom.zoom(into: range(0, 15))
        zoom.reset()

        XCTAssertEqual(zoom, .wholeHistory)
    }

    /// La salida directa solo se ofrece cuando desapilar de uno en uno no lleva ya al mismo sitio: con
    /// un nivel puesto, "atrás" y "todo el historial" serían dos botones para el mismo destino.
    func testTheDirectExitIsOnlyOfferedPastTheFirstLevel() {
        var zoom = ScrubZoom.wholeHistory
        zoom.zoom(into: range(0, 3_600))
        XCTAssertFalse(zoom.offersFullReset)

        zoom.zoom(into: range(0, 300))
        XCTAssertTrue(zoom.offersFullReset)
    }
}
