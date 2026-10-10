import CoreGraphics
import Foundation
import XCTest
@testable import Shared

/// Tests de la composición en páginas del informe del paquete de evidencia: lo que un salto de
/// página puede estropear. Se afirma sobre un informe hecho a mano y un medidor de texto en el que
/// cada carácter mide lo mismo, y casi siempre **para muchas alturas de página**: un salto que
/// cae mal lo hace en una altura concreta, y un test con una sola no la encuentra.
final class EvidenceReportLayoutTests: XCTestCase {

    // MARK: - Utilidades

    /// Cada carácter mide 5 pt y cada línea 10, en todos los papeles. Parte por espacios y, si una
    /// palabra no cabe, por dentro.
    private struct GridMeasurer: EvidenceReportTextMeasuring {
        static let characterWidth: CGFloat = 5
        static let lineHeight: CGFloat = 10

        func lineHeight(of style: EvidenceReportTextStyle) -> CGFloat { Self.lineHeight }

        func width(of text: String, style: EvidenceReportTextStyle) -> CGFloat {
            CGFloat(text.count) * Self.characterWidth
        }

        func lines(of text: String, style: EvidenceReportTextStyle, width: CGFloat) -> [String] {
            let capacity = max(1, Int(width / Self.characterWidth))
            var lines: [String] = []
            var current = ""
            for word in text.split(separator: " ") {
                var word = String(word)
                if !current.isEmpty, current.count + 1 + word.count <= capacity {
                    current += " " + word
                    continue
                }
                if !current.isEmpty { lines.append(current) }
                while word.count > capacity {
                    lines.append(String(word.prefix(capacity)))
                    word = String(word.dropFirst(capacity))
                }
                current = word
            }
            if !current.isEmpty { lines.append(current) }
            return lines
        }
    }

    private static let pageWidth: CGFloat = 340

    /// 300 pt de ancho útil: sesenta caracteres por línea.
    private func geometry(height: CGFloat) -> EvidenceReportPageGeometry {
        EvidenceReportPageGeometry(
            pageSize: CGSize(width: Self.pageWidth, height: height),
            margin: 20,
            sectionSpacing: 16,
            blockSpacing: 8,
            factSpacing: 2,
            columnGap: 10,
            cellPadding: 3,
            noteIndent: 10,
            footerSpacing: 6
        )
    }

    /// De una página que apenas da para cinco líneas a una en la que cabe todo.
    private static let heights = Array(stride(from: CGFloat(112), through: 460, by: 7)) + [2_000]

    private func layout(
        _ report: EvidenceReport,
        height: CGFloat
    ) -> EvidenceReportLayout {
        EvidenceReportLayout(report: report, geometry: geometry(height: height), measuring: GridMeasurer())
    }

    private func words(_ count: Int, _ word: String) -> String {
        (1...count).map { "\(word)\($0)" }.joined(separator: " ")
    }

    private func section(
        _ kind: EvidenceReportSectionKind,
        _ title: String,
        _ blocks: [EvidenceReportBlock]
    ) -> EvidenceReportSection {
        EvidenceReportSection(kind: kind, title: title, blocks: blocks)
    }

    /// Un informe con cada tipo de pieza, textos largos y una tabla de muchas filas.
    private func sample() -> EvidenceReport {
        EvidenceReport(
            title: "Sample report",
            subtitle: "Project · 1.0 (1) · session 7",
            sections: [
                section(.session, "First section", [
                    .facts([
                        EvidenceReportFact(label: "Project", value: "Example"),
                        EvidenceReportFact(label: "Verdict", value: "Observed", staysWithNext: true),
                        EvidenceReportFact(label: "Coverage", value: words(40, "cover")),
                        EvidenceReportFact(label: "A label that is long enough to wrap by itself", value: "7"),
                    ]),
                    .paragraph(words(60, "para")),
                    .heading("Markers"),
                    .table(EvidenceReportTable(
                        columns: ["Key", "Sentence"],
                        rows: (1...30).map { ["K\($0)", words(14, "row\($0)x")] }
                    )),
                ]),
                section(.method, "Second section", [
                    .note(words(70, "note")),
                    .heading("Chained heading"),
                    .heading("Its subheading"),
                    .facts([EvidenceReportFact(label: "Count", value: "3")]),
                    .paragraph("A-token-with-no-space-in-it-" + String(repeating: "x", count: 150)),
                ]),
                section(.findings, "Third section", [
                    .heading("Opens with a heading"),
                    .note("Quoted."),
                ]),
            ]
        )
    }

    private func texts(_ marks: [EvidenceReportMark]) -> [(text: String, style: EvidenceReportTextStyle, origin: CGPoint)] {
        marks.compactMap { mark in
            if case .text(let text, let style, let origin) = mark { return (text, style, origin) }
            return nil
        }
    }

    private func fills(_ marks: [EvidenceReportMark], _ kind: EvidenceReportFill) -> [CGRect] {
        marks.compactMap { mark in
            if case .fill(let rect, kind) = mark { return rect }
            return nil
        }
    }

    /// Los caracteres de unos textos, sin espacios y ordenados: lo que no depende de por dónde
    /// se partió cada uno.
    private func characters(_ texts: [String]) -> [Character] {
        texts.joined().filter { !$0.isWhitespace }.sorted()
    }

    /// Todo lo que un informe imprime una sola vez, por papel.
    private func printed(_ report: EvidenceReport) -> [EvidenceReportTextStyle: [String]] {
        var printed: [EvidenceReportTextStyle: [String]] = [
            .title: [report.title], .subtitle: [report.subtitle],
        ]
        for section in report.sections {
            printed[.sectionTitle, default: []].append(section.title)
            for block in section.blocks {
                switch block {
                case .heading(let text): printed[.heading, default: []].append(text)
                case .paragraph(let text): printed[.paragraph, default: []].append(text)
                case .note(let text): printed[.note, default: []].append(text)
                case .facts(let facts):
                    printed[.factLabel, default: []] += facts.map(\.label)
                    printed[.factValue, default: []] += facts.map(\.value)
                case .table(let table):
                    printed[.cell, default: []] += table.rows.flatMap { $0 }
                }
            }
        }
        return printed
    }

    // MARK: - Anchos de columna

    func testColumnsThatFitGetWhatTheyAskFor() {
        XCTAssertEqual(EvidenceReportColumnWidths.shares(natural: [40, 60, 100], into: 300), [40, 60, 100])
    }

    func testAWideColumnGetsWhatTheNarrowOnesLeave() {
        XCTAssertEqual(EvidenceReportColumnWidths.shares(natural: [40, 900, 60], into: 300), [40, 200, 60])
    }

    func testWideColumnsSplitWhatIsLeftEvenlyAndNeverGetLessThanAnEvenShare() {
        let widths = EvidenceReportColumnWidths.shares(natural: [30, 900, 400, 110], into: 400)

        // 30 cabe; de los 370 que quedan, a 123,3 cada una, 110 cabe; las dos anchas, 130.
        XCTAssertEqual(widths, [30, 130, 130, 110])
        XCTAssertGreaterThanOrEqual(widths[1], 400 / 4)
    }

    func testANarrowColumnIsNotSqueezedToMakeRoomForAWideOne() {
        let widths = EvidenceReportColumnWidths.shares(natural: [50, 5_000], into: 200)

        XCTAssertEqual(widths[0], 50)
        XCTAssertEqual(widths.reduce(0, +), 200)
    }

    func testSharesNeverAddUpToMoreThanThereIs() {
        for natural in [[10.0, 20, 30], [500, 500], [1, 999, 1, 999, 1], [0, 0], [300]] as [[CGFloat]] {
            let widths = EvidenceReportColumnWidths.shares(natural: natural, into: 300)
            XCTAssertEqual(widths.count, natural.count)
            XCTAssertLessThanOrEqual(widths.reduce(0, +), 300 + 0.001, "\(natural)")
            XCTAssertTrue(widths.allSatisfy { $0 >= 0 }, "\(natural)")
        }
    }

    func testWithNoRoomEveryColumnIsZero() {
        XCTAssertEqual(EvidenceReportColumnWidths.shares(natural: [10, 20], into: 0), [0, 0])
        XCTAssertEqual(EvidenceReportColumnWidths.shares(natural: [], into: 300), [])
        XCTAssertEqual(EvidenceReportColumnWidths.filling(natural: [], into: 300), [])
    }

    func testFillingGivesWhatIsLeftOverToTheColumnThatAskedForMost() {
        XCTAssertEqual(EvidenceReportColumnWidths.filling(natural: [40, 80, 60], into: 300), [40, 200, 60])
        XCTAssertEqual(EvidenceReportColumnWidths.filling(natural: [50, 50], into: 300), [250, 50])
    }

    /// Dos tablas con las mismas columnas, una con sitio de sobra y otra sin él: las columnas
    /// estrechas miden lo mismo en las dos.
    func testNarrowColumnsMeasureTheSameWhetherOrNotThereIsRoomToSpare() {
        let roomy = EvidenceReportColumnWidths.filling(natural: [30, 120, 70, 60], into: 400)
        let tight = EvidenceReportColumnWidths.filling(natural: [30, 900, 70, 60], into: 400)

        XCTAssertEqual(roomy, tight)
        XCTAssertEqual(roomy, [30, 240, 70, 60])
    }

    func testFillingAlwaysTakesTheWholeWidth() {
        for natural in [[10.0, 20, 30], [500, 500], [1, 999, 1, 999, 1], [300]] as [[CGFloat]] {
            let widths = EvidenceReportColumnWidths.filling(natural: natural, into: 300)
            XCTAssertEqual(widths.reduce(0, +), 300, accuracy: 0.001, "\(natural)")
        }
    }

    // MARK: - El papel

    func testTheReportIsComposedOnA4() {
        let a4 = EvidenceReportPageGeometry.a4

        XCTAssertEqual(a4.pageSize.width, 595.28, accuracy: 0.01)
        XCTAssertEqual(a4.pageSize.height, 841.89, accuracy: 0.01)
        XCTAssertEqual(a4.margin, 56.69, accuracy: 0.01)
        XCTAssertEqual(a4.contentWidth, a4.pageSize.width - 2 * a4.margin)
    }

    func testAReportWithNothingInItIsStillOnePage() {
        let layout = layout(EvidenceReport(title: "Empty", subtitle: "Nothing", sections: []), height: 300)

        XCTAssertEqual(layout.pages.count, 1)
        XCTAssertEqual(texts(layout.pages[0].body).map(\.text), ["Empty", "Nothing"])
    }

    func testTheBodyFrameLeavesTheMarginsAndTheFooter() {
        let layout = layout(sample(), height: 300)

        // 300 de alto, 20 de margen arriba y abajo, y un pie de una línea de 10 con 6 a cada lado.
        XCTAssertEqual(layout.bodyFrame, CGRect(x: 20, y: 20, width: 300, height: 238))
    }

    // MARK: - Nada se pierde

    func testEveryCharacterOfTheReportIsOnSomePageWhateverThePageHeight() {
        let report = sample()
        let expected = printed(report).mapValues(characters)

        for height in Self.heights {
            let body = texts(layout(report, height: height).pages.flatMap(\.body))
            for (style, characters) in expected {
                XCTAssertEqual(
                    self.characters(body.filter { $0.style == style }.map(\.text)), characters,
                    "\(style) con páginas de \(height) pt"
                )
            }
        }
    }

    func testEveryLineStaysInsideTheBodyFrameWhateverThePageHeight() {
        let report = sample()
        for height in Self.heights {
            let layout = layout(report, height: height)
            let frame = layout.bodyFrame.insetBy(dx: -0.01, dy: -0.01)
            for page in layout.pages {
                for line in texts(page.body) {
                    let box = CGRect(
                        x: line.origin.x, y: line.origin.y,
                        width: CGFloat(line.text.count) * GridMeasurer.characterWidth,
                        height: GridMeasurer.lineHeight
                    )
                    XCTAssertTrue(frame.contains(box), "«\(line.text)» en la página \(page.number) de \(height) pt")
                }
                for kind in [EvidenceReportFill.rule, .quoteBar, .headerBand] {
                    for rect in fills(page.body, kind) {
                        XCTAssertTrue(frame.contains(rect), "\(kind) en la página \(page.number) de \(height) pt")
                    }
                }
            }
        }
    }

    func testNoTwoLinesOfAPageAreDrawnOnTheSameSpot() {
        let report = sample()
        for height in Self.heights {
            for page in layout(report, height: height).pages {
                let origins = texts(page.body).map { "\($0.origin.x),\($0.origin.y)" }
                XCTAssertEqual(Set(origins).count, origins.count, "página \(page.number) de \(height) pt")
            }
        }
    }

    func testAPageDoesNotOpenWithTheSpaceThatSeparatedWhatCameBefore() {
        let report = sample()
        for height in Self.heights {
            let layout = layout(report, height: height)
            for page in layout.pages {
                let top = (texts(page.body).map(\.origin.y) + fills(page.body, .headerBand).map(\.minY)).min()
                XCTAssertEqual(
                    try XCTUnwrap(top), layout.bodyFrame.minY, accuracy: 0.01,
                    "página \(page.number) de \(height) pt"
                )
            }
        }
    }

    // MARK: - Lo que no se separa

    func testATextBrokenBetweenTwoPagesLeavesNoLineAlone() throws {
        let report = EvidenceReport(title: "t", subtitle: "s", sections: [
            section(.method, "Method", [.paragraph(words(25, "lead")), .note(words(100, "note"))]),
        ])
        var broken = 0
        for height in Self.heights {
            let pages = layout(report, height: height).pages
            let counts = pages.map { page in texts(page.body).filter { $0.style == .note }.count }
                .filter { $0 > 0 }
            if counts.count > 1 { broken += 1 }
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(counts.first), 2, "páginas de \(height) pt")
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(counts.last), 2, "páginas de \(height) pt")
        }
        XCTAssertGreaterThan(broken, 20, "casi ninguna altura parte la nota: el test no prueba nada")
    }

    func testAHeadingIsNeverTheLastThingOnAPage() {
        let report = sample()
        // Desde que una página puede con lo más alto que un encabezado arrastra aquí: él, la
        // cabecera de su tabla y la primera fila entera. Por debajo no hay dónde ponerlos juntos.
        for height in Self.heights where height >= 140 {
            for page in layout(report, height: height).pages {
                let lines = texts(page.body)
                let lowestHeading = lines
                    .filter { $0.style == .heading || $0.style == .sectionTitle }
                    .map(\.origin.y).max()
                guard let lowestHeading else { continue }
                XCTAssertTrue(
                    lines.contains { line in
                        line.style != .heading && line.style != .sectionTitle && line.origin.y > lowestHeading
                    },
                    "un encabezado cierra la página \(page.number) de \(height) pt"
                )
            }
        }
    }

    func testAFactThatStaysWithTheNextIsOnThePageWhereTheNextBegins() throws {
        let report = sample()
        for height in Self.heights {
            let pages = layout(report, height: height).pages
            let verdict = try XCTUnwrap(pages.first { page in texts(page.body).contains { $0.text == "Verdict" } })
            let coverage = try XCTUnwrap(pages.first { page in texts(page.body).contains { $0.text == "Coverage" } })
            XCTAssertEqual(verdict.number, coverage.number, "páginas de \(height) pt")
        }
    }

    func testWithoutTheMarkAFactCanCloseAPageAlone() throws {
        // La misma lista sin la marca: si ninguna altura los separase, el test de arriba no
        // estaría probando la marca sino la casualidad.
        let facts = [
            EvidenceReportFact(label: "Project", value: "Example"),
            EvidenceReportFact(label: "Verdict", value: "Observed"),
            EvidenceReportFact(label: "Coverage", value: words(40, "cover")),
        ]
        let report = EvidenceReport(
            title: "Sample report", subtitle: "s", sections: [section(.session, "First section", [.facts(facts)])]
        )

        let separated = try Self.heights.filter { height in
            let pages = layout(report, height: height).pages
            let verdict = try XCTUnwrap(pages.first { page in texts(page.body).contains { $0.text == "Verdict" } })
            let coverage = try XCTUnwrap(pages.first { page in texts(page.body).contains { $0.text == "Coverage" } })
            return verdict.number != coverage.number
        }
        XCTAssertFalse(separated.isEmpty)
    }

    func testARowThatFitsInAPageIsNotSplitBetweenTwo() {
        let report = sample()
        // Cada fila de la tabla son tres líneas: desde que caben de sobra la cabecera y una entera.
        for height in Self.heights where height >= 140 {
            let pages = layout(report, height: height).pages
            for row in 1...30 {
                let holding = pages.filter { page in
                    texts(page.body).contains { $0.style == .cell && $0.text.contains("row\(row)x") }
                }
                XCTAssertEqual(holding.count, 1, "fila \(row) con páginas de \(height) pt")
                XCTAssertTrue(
                    texts(holding[0].body).contains { $0.style == .cell && $0.text == "K\(row)" },
                    "la clave de la fila \(row) no va con su frase, con páginas de \(height) pt"
                )
            }
        }
    }

    // MARK: - Tablas

    func testATableThatGoesOnToAnotherPageRepeatsItsHeaderThere() {
        let report = sample()
        var continued = 0
        for height in Self.heights {
            let pages = layout(report, height: height).pages
            let withCells = pages.filter { page in texts(page.body).contains { $0.style == .cell } }
            if withCells.count > 1 { continued += 1 }
            for page in withCells {
                let lines = texts(page.body)
                let firstCell = lines.filter { $0.style == .cell }.map(\.origin.y).min() ?? 0
                let headers = lines.filter { $0.style == .columnHeader && $0.origin.y < firstCell }
                XCTAssertEqual(
                    Set(headers.map(\.text)), ["Key", "Sentence"],
                    "página \(page.number) de \(height) pt"
                )
                XCTAssertTrue(
                    fills(page.body, .headerBand).contains { $0.minY < firstCell },
                    "página \(page.number) de \(height) pt"
                )
            }
        }
        XCTAssertGreaterThan(continued, 10, "casi ninguna altura parte la tabla: el test no prueba nada")
    }

    func testAHeaderIsNeverLeftWithNoRowUnderIt() {
        let report = sample()
        for height in Self.heights {
            for page in layout(report, height: height).pages {
                let cells = texts(page.body).filter { $0.style == .cell }
                for band in fills(page.body, .headerBand) {
                    XCTAssertTrue(
                        cells.contains { $0.origin.y >= band.maxY },
                        "cabecera sin filas en la página \(page.number) de \(height) pt"
                    )
                }
            }
        }
    }

    func testEveryRowOfATableIsClosedByARule() {
        let pages = layout(sample(), height: 2_000).pages

        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(fills(pages[0].body, .rule).count, 30)
    }

    func testATableIsAsWideAsTheTextAroundIt() throws {
        let layout = layout(sample(), height: 2_000)
        let band = try XCTUnwrap(fills(layout.pages[0].body, .headerBand).first)

        XCTAssertEqual(band.minX, layout.bodyFrame.minX)
        XCTAssertEqual(band.width, layout.bodyFrame.width, accuracy: 0.001)
    }

    func testACellStartsInsideItsColumnAndNotAgainstTheOneBefore() throws {
        let layout = layout(sample(), height: 2_000)
        let lines = texts(layout.pages[0].body)
        let key = try XCTUnwrap(lines.first { $0.text == "K1" })
        let sentence = try XCTUnwrap(lines.first { $0.style == .cell && $0.text.hasPrefix("row1x1 ") })

        // «Sentence» pide más de lo que hay y «Key» lo suyo: 8 caracteres de cabecera más el aire.
        XCTAssertEqual(key.origin.x, layout.bodyFrame.minX + 5)
        XCTAssertEqual(sentence.origin.x, layout.bodyFrame.minX + 25 + 5)
        XCTAssertEqual(key.origin.y, sentence.origin.y)
    }

    // MARK: - Datos y notas

    func testEveryFactListOfASectionSharesOneLabelColumn() {
        let report = EvidenceReport(title: "t", subtitle: "s", sections: [
            section(.requirements, "Requirements", [
                .facts([EvidenceReportFact(label: "Short", value: "one")]),
                .heading("Another"),
                .facts([EvidenceReportFact(label: "A considerably longer label", value: "two")]),
            ]),
            section(.checks, "Checks", [.facts([EvidenceReportFact(label: "Tiny", value: "three")])]),
        ])

        let values = texts(layout(report, height: 2_000).pages[0].body).filter { $0.style == .factValue }

        XCTAssertEqual(values.map(\.text), ["one", "two", "three"])
        XCTAssertEqual(values[0].origin.x, values[1].origin.x)
        // Otra sección, otra columna: la suya no tiene ningún rótulo largo.
        XCTAssertLessThan(values[2].origin.x, values[0].origin.x)
    }

    func testALabelNeverTakesMoreThanHalfTheLine() throws {
        let report = EvidenceReport(title: "t", subtitle: "s", sections: [
            section(.session, "Session", [.facts([
                EvidenceReportFact(label: words(30, "label"), value: words(30, "value")),
            ])]),
        ])
        let layout = layout(report, height: 2_000)

        let value = try XCTUnwrap(texts(layout.pages[0].body).first { $0.style == .factValue })

        XCTAssertEqual(value.origin.x, layout.bodyFrame.midX)
    }

    func testAQuotedNoteCarriesItsBarOnEveryPageItIsOnAndAParagraphNone() {
        let report = EvidenceReport(title: "t", subtitle: "s", sections: [
            section(.method, "Method", [.paragraph(words(30, "para")), .note(words(90, "note"))]),
        ])
        for height in Self.heights {
            let layout = layout(report, height: height)
            for page in layout.pages {
                let lines = texts(page.body)
                let bars = fills(page.body, .quoteBar)
                for line in lines where line.style == .note {
                    XCTAssertTrue(
                        bars.contains { $0.minY <= line.origin.y && $0.maxY >= line.origin.y + GridMeasurer.lineHeight },
                        "línea de nota sin barra en la página \(page.number) de \(height) pt"
                    )
                    XCTAssertEqual(line.origin.x, layout.bodyFrame.minX + 10)
                }
                for line in lines where line.style == .paragraph {
                    XCTAssertFalse(
                        bars.contains { $0.minY <= line.origin.y && $0.maxY > line.origin.y },
                        "párrafo marcado como cita en la página \(page.number) de \(height) pt"
                    )
                }
            }
        }
    }

    // MARK: - El pie

    func testEveryPageSaysWhichSessionItIsAndWhichPageOfHowMany() {
        let layout = layout(sample(), height: 300)
        let count = layout.pages.count

        XCTAssertGreaterThan(count, 3)
        for (index, page) in layout.pages.enumerated() {
            XCTAssertEqual(page.number, index + 1)
            let footer = texts(page.footer)
            XCTAssertEqual(footer.map(\.text), ["Project · 1.0 (1) · session 7", "Page \(index + 1) of \(count)"])
            XCTAssertTrue(footer.allSatisfy { $0.style == .footer })
            XCTAssertEqual(footer[0].origin.x, layout.bodyFrame.minX)
            // El número acaba donde acaba el cuerpo.
            XCTAssertEqual(
                footer[1].origin.x + CGFloat(footer[1].text.count) * GridMeasurer.characterWidth,
                layout.bodyFrame.maxX
            )
            XCTAssertEqual(fills(page.footer, .rule).count, 1)
            XCTAssertTrue(footer.allSatisfy { $0.origin.y > layout.bodyFrame.maxY })
            XCTAssertTrue(footer.allSatisfy {
                $0.origin.y + GridMeasurer.lineHeight <= layout.geometry.pageSize.height - layout.geometry.margin
            })
        }
    }

    func testASessionLineTooLongForTheFooterIsCutShortAndSaysSo() throws {
        let report = EvidenceReport(title: "t", subtitle: words(40, "project"), sections: [])
        let layout = layout(report, height: 300)
        let footer = texts(layout.pages[0].footer)

        XCTAssertTrue(footer[0].text.hasSuffix("…"))
        XCTAssertTrue(footer[0].text.hasPrefix("project1 project2"))
        XCTAssertLessThan(
            footer[0].origin.x + CGFloat(footer[0].text.count) * GridMeasurer.characterWidth,
            footer[1].origin.x
        )
        // Entera está donde el informe la dice una vez: bajo el título.
        XCTAssertEqual(
            characters(texts(layout.pages.flatMap(\.body)).filter { $0.style == .subtitle }.map(\.text)),
            characters([report.subtitle])
        )
    }

    // MARK: - Determinismo

    func testTheSameReportIsComposedTheSameWay() {
        XCTAssertEqual(layout(sample(), height: 300), layout(sample(), height: 300))
    }
}
