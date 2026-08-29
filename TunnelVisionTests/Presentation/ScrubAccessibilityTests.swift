import Foundation
import XCTest
@testable import Shared

/// Tests del recorrido de la barra de scrub para quien no la ve: dónde está el cursor, qué se lee de
/// él, qué se le ofrece y qué aplica activarlo.
///
/// Lo que aquí se afirma es justo lo que el dedo hace sin ayuda de nadie —tocar un tramo y barrer
/// varios— dicho como decisiones, que es la única forma de que las dos maneras de elegir no acaben
/// eligiendo cosas distintas.
final class ScrubAccessibilityTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func axis(_ counts: [Int], duration: TimeInterval = 60) -> ActivityAxis {
        ActivityAxis(
            bars: counts.enumerated().map { index, count in
                ActivityBar(
                    start: epoch.addingTimeInterval(Double(index) * duration),
                    duration: duration,
                    packetCount: count
                )
            }
        )
    }

    // MARK: - Dónde arranca y dónde se queda el cursor

    /// El cursor empieza en lo más reciente, que es donde está la atención de quien abre la Timeline:
    /// arrancar por el principio del historial obligaría a recorrer el eje entero para llegar a hoy.
    func testTheCursorStartsOnTheNewestInterval() {
        let drawn = axis([1, 2, 3, 4])
        let cursor = ScrubAccessibility.rebased(nil, on: drawn)

        XCTAssertEqual(cursor?.index, 3)
        XCTAssertNil(cursor?.anchor)
    }

    /// Sin barras no hay dónde ponerse. Es el eje que no se dibuja, así que en la práctica no ocurre,
    /// pero un cursor sobre la nada sería un valor que VoiceOver leería como si señalase algo.
    func testAnEmptyAxisHasNoCursor() {
        XCTAssertNil(ScrubAccessibility.rebased(nil, on: .empty))
        XCTAssertNil(ScrubAccessibility.rebased(ScrubCursor(index: 2), on: .empty))
    }

    /// Un eje que encoge (la retención se llevó lo viejo) no deja al cursor fuera: se acota, porque
    /// perder el sitio es peor que quedarse cerca de donde se estaba.
    func testTheCursorIsClampedOntoAShorterAxis() {
        XCTAssertEqual(ScrubAccessibility.rebased(ScrubCursor(index: 9), on: axis([1, 2]))?.index, 1)
    }

    /// Un eje nuevo **suelta** la selección en curso: las barras se re-alinean cuando el historial
    /// crece, así que el extremo fijado puede haber pasado a señalar otro trozo del pasado y aplicarlo
    /// acotaría la lista a algo que nadie eligió.
    func testANewAxisReleasesASelectionInProgress() {
        let cursor = ScrubCursor(index: 3, anchor: 0)
        let rebased = ScrubAccessibility.rebased(cursor, on: axis([1, 2, 3, 4, 5]))

        XCTAssertEqual(rebased?.index, 3, "el sitio se conserva")
        XCTAssertNil(rebased?.anchor, "el extremo fijado no")
    }

    // MARK: - Moverse

    func testMovingWalksTheAxisOneIntervalAtATime() {
        let drawn = axis([1, 2, 3])
        let cursor = ScrubCursor(index: 1)

        XCTAssertEqual(ScrubAccessibility.moved(cursor, by: 1, on: drawn).index, 2)
        XCTAssertEqual(ScrubAccessibility.moved(cursor, by: -1, on: drawn).index, 0)
    }

    /// En los extremos se para en vez de dar la vuelta: quien llega al final del historial y sigue
    /// deslizando espera quedarse ahí, no aparecer en el otro extremo sin que nada lo diga.
    func testMovingStopsAtTheEndsInsteadOfWrappingAround() {
        let drawn = axis([1, 2, 3])

        XCTAssertEqual(ScrubAccessibility.moved(ScrubCursor(index: 2), by: 1, on: drawn).index, 2)
        XCTAssertEqual(ScrubAccessibility.moved(ScrubCursor(index: 0), by: -1, on: drawn).index, 0)
    }

    /// Moverse con un extremo ya fijado **extiende** lo elegido, que es lo que hace un dedo que no se
    /// ha levantado: si el ancla se perdiera al moverse, no habría forma de elegir más de una barra.
    func testMovingKeepsTheAnchorSoTheSelectionGrows() {
        let drawn = axis([1, 2, 3, 4])
        let moved = ScrubAccessibility.moved(ScrubCursor(index: 1, anchor: 1), by: 2, on: drawn)

        XCTAssertEqual(moved.anchor, 1)
        XCTAssertEqual(
            ScrubAccessibility.pendingRange(for: moved, on: drawn),
            drawn.bars[1].start...drawn.bars[3].end
        )
    }

    // MARK: - Elegir un tramo largo

    func testWithoutAnAnchorNothingIsBeingSelected() {
        XCTAssertNil(ScrubAccessibility.pendingRange(for: ScrubCursor(index: 1), on: axis([1, 2, 3])))
    }

    /// El tramo elegido sin ver es **el mismo** que barrería un dedo puesto dentro de esas dos barras:
    /// las dos formas de elegir pasan por `ActivityAxis.sweep`, así que redondean igual.
    func testTheSelectedStretchIsWhatAFingerWouldSweep() {
        let drawn = axis([1, 2, 3, 4, 5])
        let cursor = ScrubCursor(index: 3, anchor: 1)

        XCTAssertEqual(
            ScrubAccessibility.pendingRange(for: cursor, on: drawn),
            drawn.sweep(
                from: drawn.bars[1].start.addingTimeInterval(30),
                to: drawn.bars[3].start.addingTimeInterval(30)
            )
        )
    }

    /// Los tramos del eje **se tocan**, así que el instante en que empieza una barra pertenece también
    /// a la anterior: elegir por el principio del tramo arrastraría a la vecina de al lado, que es una
    /// barra que el usuario no ha señalado y que además no se ve resaltada al elegirla.
    func testSelectingOneIntervalDoesNotDragInItsNeighbour() {
        let drawn = axis([1, 2, 3])

        XCTAssertEqual(
            ScrubAccessibility.pendingRange(for: ScrubCursor(index: 1, anchor: 1), on: drawn),
            drawn.bars[1].range
        )
    }

    /// El orden de los extremos da igual, como en el arrastre: se elige lo mismo hacia atrás que hacia
    /// adelante.
    func testSelectingBackwardsPicksTheSameStretch() {
        let drawn = axis([1, 2, 3, 4])

        XCTAssertEqual(
            ScrubAccessibility.pendingRange(for: ScrubCursor(index: 0, anchor: 2), on: drawn),
            ScrubAccessibility.pendingRange(for: ScrubCursor(index: 2, anchor: 0), on: drawn)
        )
    }

    func testFixingTheAnchorAgainRestartsTheSelectionHere() {
        let restarted = ScrubAccessibility.beganRange(ScrubCursor(index: 2, anchor: 0))

        XCTAssertEqual(restarted.anchor, 2)
        XCTAssertEqual(restarted.index, 2)
    }

    /// Cancelar suelta el extremo y **no** mueve el cursor: cancelar la selección no es volver.
    func testCancellingReleasesTheAnchorWithoutMovingTheCursor() {
        let cancelled = ScrubAccessibility.cancelledRange(ScrubCursor(index: 3, anchor: 0))

        XCTAssertEqual(cancelled.index, 3)
        XCTAssertNil(cancelled.anchor)
    }

    // MARK: - Lo que se ofrece

    func testBeforeFixingAnEndTheOnlyOfferIsToStart() {
        XCTAssertEqual(
            ScrubAccessibility.actions(for: ScrubCursor(index: 1), on: axis([1, 2, 3])),
            [.beginRange]
        )
    }

    func testWhileSelectingTheOffersAreApplyAndCancel() {
        XCTAssertEqual(
            ScrubAccessibility.actions(for: ScrubCursor(index: 2, anchor: 0), on: axis([1, 2, 3])),
            [.commitRange, .cancelRange]
        )
    }

    /// En un eje de una sola barra, "desde aquí" y "hasta aquí" son el mismo sitio: la acción no haría
    /// nada que activar no haga ya, y ofrecerla sería un gesto muerto.
    func testWithASingleIntervalThereIsNoRangeToSelect() {
        XCTAssertTrue(ScrubAccessibility.actions(for: ScrubCursor(index: 0), on: axis([7])).isEmpty)
    }

    // MARK: - Activar

    /// Sin extremo fijado, activar significa lo mismo que tocar esa barra — y tiene que devolver **la
    /// barra**, no su rango, porque tocar es lo que baja el eje y eso se decide sobre la barra.
    func testActivatingWithoutASelectionPicksTheFocusedInterval() {
        let drawn = axis([1, 2, 3])

        XCTAssertEqual(
            ScrubAccessibility.activation(for: ScrubCursor(index: 1), on: drawn),
            .interval(drawn.bars[1])
        )
    }

    /// Con un extremo fijado, activar aplica lo elegido. Es la misma regla dicha una sola vez: activar
    /// es *aplicar lo que se ha elegido*, y lo elegido depende de si hay ancla.
    func testActivatingWhileSelectingAppliesTheStretch() {
        let drawn = axis([1, 2, 3, 4])

        XCTAssertEqual(
            ScrubAccessibility.activation(for: ScrubCursor(index: 3, anchor: 1), on: drawn),
            .range(drawn.bars[1].start...drawn.bars[3].end)
        )
    }

    func testAnEmptyAxisHasNothingToActivate() {
        XCTAssertNil(ScrubAccessibility.activation(for: ScrubCursor(index: 0), on: .empty))
    }

    // MARK: - Lo que se lee

    /// La lectura lleva el tramo **sin formatear** y su precisión: fecharlo es de la vista, que es
    /// quien sabe del huso y del idioma.
    func testTheReadingCarriesTheIntervalUnformatted() {
        let drawn = axis([1, 2, 3])
        let reading = ScrubAccessibility.reading(for: ScrubCursor(index: 1), on: drawn)

        XCTAssertEqual(reading?.interval, drawn.bars[1].range)
        XCTAssertEqual(reading?.scale, ScrubPresentation.scale(for: drawn.bars[1].range))
    }

    /// La posición dentro del eje no es adorno: sin ella, deslizar por tramos parecidos no daría
    /// ninguna forma de saber si uno se está moviendo ni cuánto le queda.
    func testTheReadingSaysWhereInTheAxisTheCursorIs() {
        let detail = ScrubAccessibility.reading(for: ScrubCursor(index: 2), on: axis([1, 2, 3, 4]))?.detail

        XCTAssertEqual(detail, "3 packets. Interval 3 of 4.")
    }

    /// Un tramo vacío se **nombra**: el eje rellena los huecos a cero, así que ese cero es una
    /// afirmación —"aquí no pasó nada"— y no una laguna que haya que leer como un número.
    func testAQuietIntervalIsNamedAndNotReadAsAZero() {
        let detail = ScrubAccessibility.reading(for: ScrubCursor(index: 0), on: axis([0, 5]))?.detail

        XCTAssertEqual(detail, "No packets. Interval 1 of 2.")
    }

    func testASinglePacketIsNotSaidInPlural() {
        let detail = ScrubAccessibility.reading(for: ScrubCursor(index: 0), on: axis([1]))?.detail

        XCTAssertEqual(detail, "1 packet. Interval 1 of 1.")
    }

    /// Mientras se elige, la lectura dice **cuánto** se lleva elegido: es lo único que informa de que
    /// moverse está haciendo algo, ya que el tramo del cursor cambia igual con ancla que sin ella.
    func testWhileSelectingTheReadingCountsWhatIsChosen() {
        let drawn = axis([1, 2, 3, 4, 5])

        XCTAssertEqual(
            ScrubAccessibility.reading(for: ScrubCursor(index: 3, anchor: 1), on: drawn)?.detail,
            "4 packets. Interval 4 of 5. Selecting 3 intervals."
        )
        XCTAssertEqual(
            ScrubAccessibility.reading(for: ScrubCursor(index: 1, anchor: 1), on: drawn)?.detail,
            "2 packets. Interval 2 of 5. Selecting 1 interval."
        )
    }

    func testACursorOutsideTheAxisReadsNothing() {
        XCTAssertNil(ScrubAccessibility.reading(for: ScrubCursor(index: 4), on: axis([1, 2])))
    }

    // MARK: - La copia por el catálogo (M11)

    /// Lo que identifica no es lo que se enseña: el `id` de una acción **era su rótulo**, y al volverse
    /// traducible la lista habría cambiado de identidad al cambiar de idioma.
    func testAnActionIsIdentifiedByItsCaseAndNotByItsLabel() {
        for action in ScrubCursorAction.allCases {
            XCTAssertNotEqual(action.id, action.label, "el id no puede ser copia")
            XCTAssertFalse(action.id.contains(" "), "un id no es una frase: \(action.id)")
        }
        XCTAssertEqual(Set(ScrubCursorAction.allCases.map(\.id)).count, ScrubCursorAction.allCases.count)
    }

    /// Las tres acciones dicen cosas distintas, y eso es el listón de este recorrido: dos cosas que se
    /// llaman igual y hacen distinto son justo la confusión que existe para quitar.
    func testTheThreeActionsAreNamedApart() {
        XCTAssertEqual(Set(ScrubCursorAction.allCases.map(\.label)).count, 3)
    }

    /// **Un número que es una posición se interpola pero no se agrupa**: `Interval 12000 of 12000` es
    /// un sitio dentro del eje y no una cantidad. En la misma frase, lo elegido **sí** es una cantidad
    /// y va agrupado. En la práctica la política acota el eje a decenas de barras, así que esto no se
    /// ve nunca — y por eso se afirma: el día que se rompa, no lo va a contar nadie.
    ///
    /// **Las dos cifras son la misma frase y se dicen distinto**, que es lo que hace a este test el
    /// ejemplo trabajado de la regla: la posición va verbatim porque la envuelve un `String(...)`, y lo
    /// elegido va agrupado porque lo dice `DisplayFormat.count`.
    ///
    /// El caso de cuatro dígitos es el que estuvo roto y solo vuelve a ser afirmable desde que el
    /// scheme fija el locale del bundle de tests (`CopyLocaleTests`): con el idioma de la máquina
    /// —español aquí, que no agrupa los millares de cuatro dígitos— pasaba por casualidad mientras el
    /// inglés, el único idioma que la app enseña, habría dicho `Interval 1,200`.
    func testAPositionInTheAxisIsNotGroupedButACountIs() {
        let wide = axis(Array(repeating: 1, count: 12_000))
        let detail = ScrubAccessibility.reading(
            for: ScrubCursor(index: 11_999, anchor: 0), on: wide
        )?.detail

        XCTAssertEqual(detail, "1 packet. Interval 12000 of 12000. Selecting 12,000 intervals.")

        let narrower = axis(Array(repeating: 1, count: 1_200))
        let fourDigits = ScrubAccessibility.reading(
            for: ScrubCursor(index: 1_199, anchor: 0), on: narrower
        )?.detail

        XCTAssertEqual(fourDigits, "1 packet. Interval 1200 of 1200. Selecting 1,200 intervals.")
    }

    /// La frase entera se compone en el núcleo puro y no en SwiftUI, que era donde el valor se armaba
    /// con `intervalText(…) + Text(" \(detail)")`: el separador y el orden son propiedades de un
    /// idioma, y ahí no llega ningún traductor.
    func testTheSpokenValueJoinsTheDatesAndWhatIsSaidAboutThem() {
        let value = ScrubAccessibility.cursorValue(interval: "10:00 – 10:15", detail: "3 packets.")

        XCTAssertTrue(value.hasPrefix("10:00 – 10:15"), value)
        XCTAssertTrue(value.hasSuffix("3 packets."), value)
        XCTAssertFalse(
            value.contains("10:15 3 packets."),
            "la fecha y lo que se dice de ella no se pegan sin más: \(value)"
        )
    }

    /// Un eje sin barras no se dibuja, así que en la práctica no se oye; lo que no puede pasar es que
    /// el valor se quede vacío, que sonaría como si señalase algo.
    func testWithoutACursorTheValueStillSaysSomething() {
        XCTAssertFalse(ScrubAccessibility.noSelectionValue.isEmpty)
        XCTAssertNotEqual(
            ScrubAccessibility.noSelectionValue,
            ScrubAccessibility.reading(for: ScrubCursor(index: 0), on: axis([0]))?.detail,
            "«no hay tramo señalado» y «este tramo no tuvo tráfico» son cosas distintas"
        )
    }
}
