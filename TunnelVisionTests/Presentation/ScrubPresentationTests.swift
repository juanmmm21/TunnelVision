import Foundation
import XCTest
@testable import Shared

/// Tests de lo que la barra de scrub decide antes de dibujarse: cuándo no se dibuja, qué resalta y
/// con cuánto detalle se fecha lo seleccionado.
final class ScrubPresentationTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

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

    // MARK: - Cuándo se dibuja

    /// Un eje vacío no se pinta plano: "no hay historial todavía" y "en todo este rato no hubo
    /// tráfico" son dos cosas distintas, y la segunda es lo que un eje a cero afirmaría.
    func testWithoutHistoryTheBarIsNotDrawn() {
        XCTAssertEqual(ScrubPresentation.content(for: .empty), .hidden)
    }

    func testWithHistoryTheAxisIsDrawn() {
        let drawn = axis([1, 0, 4])
        XCTAssertEqual(ScrubPresentation.content(for: drawn), .axis(drawn))
    }

    /// Un eje ya dibujado gana al último fallo, igual que una lista pintada gana a la tarjeta de
    /// error: que una recarga no trajese cuentas nuevas no invalida las que se enseñan.
    func testADrawnAxisSurvivesAFailure() {
        let drawn = axis([2, 3])
        XCTAssertEqual(
            ScrubPresentation.content(for: drawn, error: .queryFailed("db locked")),
            .axis(drawn)
        )
    }

    func testAFailureWithoutAnAxisIsSaidInOneLine() {
        guard case .unavailable(let message) = ScrubPresentation.content(
            for: .empty, error: .queryFailed("db locked")
        ) else {
            return XCTFail("un fallo sin eje dibujado tiene que decirse")
        }
        XCTAssertFalse(message.isEmpty)
    }

    // MARK: - La selección

    func testABarOverlappingTheSelectionIsHighlighted() {
        let bars = axis([1, 1, 1]).bars
        let selection = bars[1].range

        XCTAssertTrue(ScrubPresentation.isSelected(bars[1], selection: selection))
        // Por solape: las vecinas comparten el instante del borde con la seleccionada.
        XCTAssertTrue(ScrubPresentation.isSelected(bars[0], selection: selection))
        XCTAssertFalse(
            ScrubPresentation.isSelected(
                bars[0], selection: bars[2].start...bars[2].end
            )
        )
    }

    func testWithoutSelectionNothingIsHighlighted() {
        let bars = axis([1, 1]).bars
        XCTAssertFalse(ScrubPresentation.isSelected(bars[0], selection: nil))
    }

    /// Lo seleccionado se resalta solo si es una *parte* de lo que el eje enseña. Después de bajar a
    /// un tramo, lo seleccionado y lo dibujado son lo mismo, y resaltarlo pintaría el eje entero de
    /// color: quien dice dónde se está es el pie de la barra.
    func testWhatTheAxisIsShowingIsNotHighlightedAsASelection() {
        let stretch = epoch...epoch.addingTimeInterval(300)
        XCTAssertNil(ScrubPresentation.highlight(stretch, viewing: stretch))
    }

    /// Un tramo elegido dentro del que se está enseñando sí se resalta: es el caso del tramo en el que
    /// no se pudo entrar (vacío, o ya en el escalón más fino).
    func testASelectionInsideTheViewedStretchIsHighlighted() {
        let stretch = epoch...epoch.addingTimeInterval(300)
        let inside = epoch...epoch.addingTimeInterval(15)

        XCTAssertEqual(ScrubPresentation.highlight(inside, viewing: stretch), inside)
        XCTAssertEqual(ScrubPresentation.highlight(inside, viewing: nil), inside)
        XCTAssertNil(ScrubPresentation.highlight(nil, viewing: stretch))
    }

    /// El criterio es el día natural, no la duración: media hora a caballo de la medianoche necesita
    /// la fecha igual que una semana entera.
    func testTheScaleFollowsTheCalendarDayAndNotTheDuration() {
        let noon = utcCalendar.startOfDay(for: epoch).addingTimeInterval(43_200)
        XCTAssertEqual(
            ScrubPresentation.scale(for: noon...noon.addingTimeInterval(3_600), calendar: utcCalendar),
            .timeOfDay
        )

        let lateNight = utcCalendar.startOfDay(for: epoch).addingTimeInterval(85_500)  // 23:45
        XCTAssertEqual(
            ScrubPresentation.scale(
                for: lateNight...lateNight.addingTimeInterval(1_800), calendar: utcCalendar
            ),
            .dateAndTime,
            "media hora que cruza la medianoche no se puede fechar solo con la hora"
        )
    }

    // MARK: - Lo que se dice de la barra

    /// El aviso no es opcional: el eje cuenta todo lo guardado, y sin decirlo alguien con un filtro
    /// puesto leería los picos como suyos. Sigue diciéndolo acercado, que es cuando además hay que
    /// avisar de que ya no se está viendo el historial entero.
    func testTheNoteSaysTheAxisIsNotFiltered() {
        XCTAssertTrue(ScrubPresentation.note(zoomed: false).lowercased().contains("filters"))
        XCTAssertTrue(ScrubPresentation.note(zoomed: true).lowercased().contains("filters"))
    }

    /// Acercarse cambia de cuánto habla el eje. Dejar la frase de siempre afirmaría que las barras
    /// cubren todo lo guardado, que desde el primer acercamiento es falso.
    func testTheNoteStopsClaimingTheWholeHistoryOnceZoomedIn() {
        XCTAssertTrue(
            ScrubPresentation.note(zoomed: false).lowercased().contains("everything recorded")
        )
        XCTAssertFalse(
            ScrubPresentation.note(zoomed: true).lowercased().contains("everything recorded")
        )
        XCTAssertNotEqual(
            ScrubPresentation.axisLabel(for: axis([1, 2]), zoomed: true),
            ScrubPresentation.axisLabel(for: axis([1, 2]), zoomed: false)
        )
    }

    /// El total va en el **nombre** del eje y no en su valor: el valor es lo que cambia al recorrerlo
    /// tramo a tramo, y repetir ahí el total escondería lo único que se está moviendo.
    func testTheLabelCountsWhatTheAxisRepresents() {
        let label = ScrubPresentation.axisLabel(for: axis([1_000, 200, 4]), zoomed: false)
        XCTAssertTrue(label.contains("1,204"), "el nombre dice cuántos paquetes hay: \(label)")
        XCTAssertTrue(label.contains("3 intervals"))
    }

    func testTheLabelOfAnEmptyAxisSaysThereIsNothingYet() {
        XCTAssertTrue(
            ScrubPresentation.axisLabel(for: .empty, zoomed: false)
                .contains("No recorded activity yet.")
        )
    }

    /// En un eje que ya no se puede subdividir, elegir un tramo filtra y nada más: prometer un
    /// acercamiento que no va a pasar es ofrecer un gesto muerto.
    func testTheHintOnlyPromisesAZoomWhereThereIsOne() {
        XCTAssertTrue(ScrubPresentation.axisHint(zoomable: true).contains("zooms"))
        XCTAssertFalse(ScrubPresentation.axisHint(zoomable: false).contains("zoom"))
    }

    /// Volver solo a todo el historial tiene que explicarse: un eje que salta de sitio sin decir por
    /// qué se lee como un fallo, no como una salida.
    func testTheExpiredZoomNoticeSaysWhyTheAxisWentBack() {
        let notice = ScrubPresentation.expiredZoomNotice.lowercased()
        XCTAssertTrue(notice.contains("no longer stored"))
        XCTAssertTrue(notice.contains("whole history"))
    }

    // MARK: - Los recuentos, que se dicen en dos sitios

    /// Un paquete no se dice en plural. Es un plural a mano —dos claves hermanas— porque el marcado de
    /// concordancia automática no se resuelve sin catálogo y saldría crudo en estas afirmaciones.
    func testACountOfOneIsNotSaidInPlural() {
        XCTAssertEqual(ScrubPresentation.packetCount(1), "1 packet")
        XCTAssertEqual(ScrubPresentation.intervalCount(1), "1 interval")
        XCTAssertEqual(ScrubPresentation.packetCount(2), "2 packets")
        XCTAssertEqual(ScrubPresentation.intervalCount(3), "3 intervals")
    }

    /// Un cero se cuenta como cualquier otra cantidad **aquí**: el eje entero puede no tener nada
    /// guardado. Lo que no se lee como un número es el cero de **un tramo**, que es una afirmación y
    /// tiene su propia forma de decirse (`ScrubAccessibility`).
    func testAZeroIsCountedHereAndNamedInATramo() {
        XCTAssertEqual(ScrubPresentation.packetCount(0), "0 packets")
        let quiet = ScrubAccessibility.reading(for: ScrubCursor(index: 0), on: axis([0, 5]))?.detail
        XCTAssertEqual(quiet, "No packets. Interval 1 of 2.")
    }

    /// El nombre del eje y la lectura del cursor cuentan lo mismo, así que lo cuentan con **la misma
    /// propiedad**: compartir por coincidencia de literales es cómo una traducción mueve uno y deja
    /// el otro, y entonces el eje y su cursor dirían los paquetes de dos maneras distintas.
    func testTheAxisAndItsCursorCountPacketsWithTheSameWords() {
        let drawn = axis([7, 1])
        let label = ScrubPresentation.axisLabel(for: drawn, zoomed: false)
        let reading = ScrubAccessibility.reading(for: ScrubCursor(index: 0), on: drawn)

        XCTAssertTrue(label.contains(ScrubPresentation.packetCount(8)), label)
        XCTAssertTrue(label.contains(ScrubPresentation.intervalCount(2)), label)
        XCTAssertTrue(reading?.detail.contains(ScrubPresentation.packetCount(7)) == true)
    }

    /// El tramo se compone **entero** en el núcleo puro: la vista formatea cada extremo (es quien sabe
    /// del huso) y aquí se dicen juntos, porque el separador y el orden son propiedades de un idioma.
    func testAnIntervalIsSaidWithBothEndsAndOneSeparator() {
        let interval = ScrubPresentation.interval(from: "10:00", to: "10:15")

        XCTAssertTrue(interval.hasPrefix("10:00"), interval)
        XCTAssertTrue(interval.hasSuffix("10:15"), interval)
        XCTAssertFalse(interval.contains("10:00 10:15"), "los extremos van separados: \(interval)")
    }

    // MARK: - Lo que la barra dice de sí misma, de una vez

    /// Las tres cadenas que la vista pedía una por evaluación de su `body` se piden ahora juntas y
    /// una vez por eje (M11). Lo que hay que afirmar del traslado es que dicen **lo mismo** que las
    /// funciones que ya estaban probadas: si alguna se compusiera de otra manera, la barra diría dos
    /// cosas distintas según quién la mirase.
    func testTheAxisSaysTheSameThingsComposedTogether() {
        let drawn = axis([1_000, 200, 4])

        for zoomed in [false, true] {
            for zoomable in [false, true] {
                let presentation = ScrubPresentation.forAxis(
                    drawn, zoomed: zoomed, zoomable: zoomable
                )
                XCTAssertEqual(presentation.note, ScrubPresentation.note(zoomed: zoomed))
                XCTAssertEqual(
                    presentation.accessibilityLabel,
                    ScrubPresentation.axisLabel(for: drawn, zoomed: zoomed)
                )
                XCTAssertEqual(
                    presentation.accessibilityHint,
                    ScrubPresentation.axisHint(zoomable: zoomable)
                )
            }
        }
    }

    /// Acercarse cambia dos de las tres a la vez, y esa es la razón de que viajen juntas: el aviso
    /// deja de prometer todo el historial y el nombre deja de decir que el eje lo abarca.
    func testZoomingChangesTheNoteAndTheNameTogether() {
        let drawn = axis([1_000, 200, 4])
        let whole = ScrubPresentation.forAxis(drawn, zoomed: false, zoomable: true)
        let stretch = ScrubPresentation.forAxis(drawn, zoomed: true, zoomable: true)

        XCTAssertNotEqual(whole.note, stretch.note)
        XCTAssertNotEqual(whole.accessibilityLabel, stretch.accessibilityLabel)
        XCTAssertEqual(whole.accessibilityHint, stretch.accessibilityHint, "la promesa no la mueve")
    }

    // MARK: - La copia por el catálogo (M11)

    /// Toda la copia de la barra —la suya y la de su recorrido accesible—, con el sitio del que sale.
    /// Las fechas no entran: las formatea la vista con el huso del dispositivo y no son copia.
    private var everyPieceOfCopy: [(where: String, text: String)] {
        let drawn = axis([1_000, 200, 4])
        var copy: [(where: String, text: String)] = [
            ("note.wholeHistory", ScrubPresentation.note(zoomed: false)),
            ("note.zoomed", ScrubPresentation.note(zoomed: true)),
            ("axis.label", ScrubPresentation.axisLabel(for: drawn, zoomed: false)),
            ("axis.label.zoomed", ScrubPresentation.axisLabel(for: drawn, zoomed: true)),
            ("axis.label.empty", ScrubPresentation.axisLabel(for: .empty, zoomed: false)),
            ("axis.hint.zoomable", ScrubPresentation.axisHint(zoomable: true)),
            ("axis.hint.filterOnly", ScrubPresentation.axisHint(zoomable: false)),
            ("notice.expiredZoom", ScrubPresentation.expiredZoomNotice),
            ("action.zoomOut", ScrubPresentation.zoomOutActionTitle),
            ("action.showWholeHistory", ScrubPresentation.showWholeHistoryActionTitle),
            ("action.clearSelection", ScrubPresentation.clearSelectionActionTitle),
            ("viewing.label", ScrubPresentation.viewingStretchLabel),
            ("packets.one", ScrubPresentation.packetCount(1)),
            ("packets.other", ScrubPresentation.packetCount(12)),
            ("intervals.one", ScrubPresentation.intervalCount(1)),
            ("intervals.other", ScrubPresentation.intervalCount(12)),
            ("interval", ScrubPresentation.interval(from: "10:00", to: "10:15")),
            ("cursor.none", ScrubAccessibility.noSelectionValue),
        ]

        if case .unavailable(let message) = ScrubPresentation.content(
            for: .empty, error: .queryFailed("db locked")
        ) {
            copy.append(("unavailable", message))
        }

        for action in ScrubCursorAction.allCases {
            copy.append(("cursorAction.\(action.id)", action.label))
        }

        for (name, cursor) in [
            ("cursor.detail", ScrubCursor(index: 1)),
            ("cursor.detail.selecting", ScrubCursor(index: 2, anchor: 0)),
            ("cursor.detail.quiet", ScrubCursor(index: 0)),
        ] {
            guard let reading = ScrubAccessibility.reading(for: cursor, on: axis([0, 3, 5])) else {
                continue
            }
            copy.append((name, reading.detail))
            copy.append(("\(name).value", ScrubAccessibility.cursorValue(
                interval: ScrubPresentation.interval(from: "10:00", to: "10:15"),
                detail: reading.detail
            )))
        }

        return copy
    }

    /// El fallo característico de una migración al catálogo: una llamada sin `defaultValue` devuelve
    /// **la clave**, y una clave estructural se lee perfectamente en un diff sin llamar la atención.
    func testNoCopyIsARawCatalogKey() {
        for piece in everyPieceOfCopy {
            for prefix in ["timeline.", "scrub.", "common."] {
                XCTAssertFalse(piece.text.hasPrefix(prefix), "\(piece.where): \(piece.text)")
            }
            XCTAssertFalse(piece.text.isEmpty, "\(piece.where) se quedó sin copia")
        }
    }

    /// El otro fallo característico, y el que ningún test de contenido ve: al mudar un literal
    /// multilínea cambia dónde caen las continuaciones (`\`), y una mal puesta mete un espacio doble
    /// o deja un sobrante en un extremo. El texto sigue diciendo lo mismo y se ve mal.
    func testNoCopyCarriesStrayWhitespace() {
        for piece in everyPieceOfCopy {
            XCTAssertFalse(piece.text.contains("  "), "\(piece.where): espacio doble en «\(piece.text)»")
            XCTAssertEqual(
                piece.text.trimmingCharacters(in: .whitespacesAndNewlines),
                piece.text,
                "\(piece.where): sobra espacio en un extremo"
            )
            for line in piece.text.split(separator: "\n") {
                XCTAssertFalse(line.hasSuffix(" "), "\(piece.where): una línea acaba en espacio")
            }
        }
    }
}
