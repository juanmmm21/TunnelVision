import CoreGraphics
import Foundation
import Shared

/// El informe del paquete de evidencia **compuesto en páginas**, antes de dibujarlo
/// (`docs/spec/audit.md` § *Drawing the report*).
///
/// `EvidenceReport` dice qué se imprime; esto decide dónde: qué cabe en cada página, por dónde se
/// parte lo que no cabe y qué no se puede separar. Es puro —no dibuja ni mide: quien mide el texto
/// entra por `EvidenceReportTextMeasuring`— para que lo que un salto de página puede estropear se
/// afirme en un test y no mirando un PDF. Quien lo dibuja recorre marcas ya colocadas.

/// Los papeles tipográficos del informe. Qué fuente lleva cada uno lo dice quien dibuja.
public enum EvidenceReportTextStyle: Sendable, Hashable, CaseIterable {
    case title
    case subtitle
    case sectionTitle
    case heading
    case paragraph
    case note
    case factLabel
    case factValue
    case columnHeader
    case cell
    case footer
}

/// Quien sabe cuánto ocupa un texto en un papel tipográfico.
public protocol EvidenceReportTextMeasuring {

    func lineHeight(of style: EvidenceReportTextStyle) -> CGFloat

    /// Lo que mide el texto en una sola línea.
    func width(of text: String, style: EvidenceReportTextStyle) -> CGFloat

    /// El texto partido en líneas que caben en `width`. No pierde nada que no sea el espacio en
    /// blanco por donde parte: una palabra más ancha que la línea se corta, no se recorta.
    func lines(of text: String, style: EvidenceReportTextStyle, width: CGFloat) -> [String]
}

/// El papel y los espacios del informe, en puntos tipográficos.
public struct EvidenceReportPageGeometry: Sendable, Hashable {

    public let pageSize: CGSize

    /// El mismo en los cuatro lados.
    public let margin: CGFloat

    /// Lo que separa una sección de lo que hay encima.
    public let sectionSpacing: CGFloat

    /// Lo que separa dos piezas de una sección.
    public let blockSpacing: CGFloat

    /// Lo que separa dos datos de una lista.
    public let factSpacing: CGFloat

    /// El aire entre dos columnas. Va dentro del ancho de cada una.
    public let columnGap: CGFloat

    /// El aire encima y debajo del texto de una fila de tabla.
    public let cellPadding: CGFloat

    /// Lo que entra el texto de una nota citada respecto a su barra.
    public let noteIndent: CGFloat

    /// Lo que separa el pie del cuerpo, y su filete de su texto.
    public let footerSpacing: CGFloat

    public init(
        pageSize: CGSize,
        margin: CGFloat,
        sectionSpacing: CGFloat,
        blockSpacing: CGFloat,
        factSpacing: CGFloat,
        columnGap: CGFloat,
        cellPadding: CGFloat,
        noteIndent: CGFloat,
        footerSpacing: CGFloat
    ) {
        self.pageSize = pageSize
        self.margin = margin
        self.sectionSpacing = sectionSpacing
        self.blockSpacing = blockSpacing
        self.factSpacing = factSpacing
        self.columnGap = columnGap
        self.cellPadding = cellPadding
        self.noteIndent = noteIndent
        self.footerSpacing = footerSpacing
    }

    /// A4 con 20 mm de margen. A4 y no Letter porque el informe va a un expediente técnico alemán,
    /// y no el papel de la región del dispositivo porque la misma sesión tiene que dar el mismo
    /// informe en cualquiera.
    public static let a4 = EvidenceReportPageGeometry(
        pageSize: CGSize(width: 210 / 25.4 * 72, height: 297 / 25.4 * 72),
        margin: 20 / 25.4 * 72,
        sectionSpacing: 22,
        blockSpacing: 9,
        factSpacing: 3,
        columnGap: 10,
        cellPadding: 3,
        noteIndent: 9,
        footerSpacing: 8
    )

    public var contentWidth: CGFloat { pageSize.width - 2 * margin }
}

/// Cómo se reparte un ancho entre columnas.
///
/// Es un valor aparte porque es la decisión que más cambia cómo se lee una tabla y la que menos
/// se ve en el código que la dibuja: una columna de identificadores que se lleva un quinto de la
/// página deja la frase de al lado en ocho líneas.
public enum EvidenceReportColumnWidths {

    /// A cada columna, lo que pide si cabe; a las que no, lo que queda a partes iguales.
    ///
    /// Una columna estrecha (un recuento, un identificador) nunca se parte para dejarle sitio a
    /// una ancha, y ninguna de las anchas se queda con menos que un reparto a partes iguales. La
    /// suma no pasa de `available`, y es menor cuando todas caben.
    ///
    /// - Parameter natural: lo que mide cada columna sin partir ninguna celda.
    public static func shares(natural: [CGFloat], into available: CGFloat) -> [CGFloat] {
        var widths = [CGFloat](repeating: 0, count: natural.count)
        guard available > 0 else { return widths }

        var open = Array(natural.indices)
        var remaining = available
        while !open.isEmpty {
            let share = remaining / CGFloat(open.count)
            let fitting = open.filter { natural[$0] <= share }
            guard !fitting.isEmpty else {
                for index in open { widths[index] = share }
                break
            }
            for index in fitting {
                widths[index] = max(0, natural[index])
                remaining -= widths[index]
            }
            open.removeAll { fitting.contains($0) }
        }
        return widths
    }

    /// Lo mismo, ocupando todo el ancho, para que todas las tablas del informe midan lo que el
    /// texto que las rodea. Lo que sobra se lo lleva la columna que más pedía (la primera, si
    /// empatan): las demás miden lo mismo sobre o no sobre sitio, y dos tablas seguidas con las
    /// mismas columnas —una por clase de hallazgo— no cambian de forma de una a otra.
    public static func filling(natural: [CGFloat], into available: CGFloat) -> [CGFloat] {
        var widths = shares(natural: natural, into: available)
        guard available > 0,
              let widest = natural.indices.max(by: { natural[$0] < natural[$1] || (natural[$0] == natural[$1] && $0 > $1) })
        else { return widths }
        widths[widest] += max(0, available - widths.reduce(0, +))
        return widths
    }
}

/// Lo que se rellena en una página sin ser texto.
public enum EvidenceReportFill: Sendable, Hashable {
    /// Un filete: bajo una fila de tabla y sobre el pie.
    case rule
    /// La barra que marca una nota como citada de otro documento del paquete.
    case quoteBar
    /// El fondo de la cabecera de una tabla.
    case headerBand
}

/// Una cosa que se dibuja en una página, ya colocada. El origen es la esquina superior izquierda.
public enum EvidenceReportMark: Sendable, Hashable {
    /// Una línea de texto: quien dibuja no vuelve a partirla.
    case text(String, style: EvidenceReportTextStyle, origin: CGPoint)
    case fill(CGRect, EvidenceReportFill)
}

public struct EvidenceReportPage: Sendable, Hashable {

    /// Desde 1.
    public let number: Int

    /// El cuerpo: todo lo que cae dentro de `EvidenceReportLayout.bodyFrame`.
    public let body: [EvidenceReportMark]

    /// El pie: su filete, la sesión y el número de página.
    public let footer: [EvidenceReportMark]
}

public struct EvidenceReportLayout: Sendable, Hashable {

    public let geometry: EvidenceReportPageGeometry

    /// Donde va el cuerpo en todas las páginas: dentro de los márgenes y por encima del pie.
    public let bodyFrame: CGRect

    /// Al menos una.
    public let pages: [EvidenceReportPage]

    public init(
        report: EvidenceReport,
        geometry: EvidenceReportPageGeometry,
        measuring measurer: some EvidenceReportTextMeasuring
    ) {
        var composer = EvidenceReportComposer(geometry: geometry, measurer: measurer)
        composer.compose(report)
        self.geometry = geometry
        self.bodyFrame = composer.bodyFrame
        self.pages = composer.pages(footer: report.subtitle)
    }
}

// MARK: - Composición

/// Reparte las piezas del informe en páginas. Todo lo que coloca es una **fila**: una o varias
/// columnas de líneas ya partidas, que se puede partir entre dos páginas por cualquier línea.
private struct EvidenceReportComposer<Measurer: EvidenceReportTextMeasuring> {

    struct Column {
        let x: CGFloat
        let style: EvidenceReportTextStyle
        let lines: [String]
    }

    struct Row {
        let columns: [Column]
        let lineHeight: CGFloat

        /// El aire encima y debajo, que se repite en cada trozo si la fila se parte.
        let padding: CGFloat

        var lineCount: Int { columns.map(\.lines.count).max() ?? 0 }
        var height: CGFloat { CGFloat(lineCount) * lineHeight + 2 * padding }

        /// Lo mínimo que tiene que caber de ella para que lo de encima no se quede solo: las
        /// líneas con las que puede empezar al pie de una página.
        var lead: CGFloat {
            CGFloat(min(lineCount, EvidenceReportComposer.linesKeptTogether)) * lineHeight + 2 * padding
        }
    }

    struct FactRow {
        let row: Row
        let staysWithNext: Bool
    }

    enum Piece {
        case heading(Row)
        case text(Row, quoted: Bool)
        case facts([FactRow])
        case table(header: Row, rows: [Row], width: CGFloat)
    }

    // Lo que una división entre coma flotante puede comerse al contar líneas que caben justas.
    private static var tolerance: CGFloat { 0.01 }
    private static var ruleThickness: CGFloat { 0.5 }
    private static var quoteBarWidth: CGFloat { 2 }

    /// Las líneas de un texto que un salto de página no deja solas, a un lado o al otro.
    static var linesKeptTogether: Int { 2 }

    let geometry: EvidenceReportPageGeometry
    let measurer: Measurer
    let bodyFrame: CGRect

    private var finished: [[EvidenceReportMark]] = []
    private var marks: [EvidenceReportMark] = []
    private var y: CGFloat

    /// Donde empieza en esta página lo que no es una cabecera de tabla repetida. Con el cursor
    /// aquí, saltar de página no gana sitio.
    private var pageTop: CGFloat

    /// La cabecera de la tabla que se está colocando: se repite al principio de cada página.
    private var runningHeader: (row: Row, width: CGFloat)?

    init(geometry: EvidenceReportPageGeometry, measurer: Measurer) {
        self.geometry = geometry
        self.measurer = measurer
        let footerHeight = measurer.lineHeight(of: .footer) + 2 * geometry.footerSpacing
        self.bodyFrame = CGRect(
            x: geometry.margin,
            y: geometry.margin,
            width: geometry.contentWidth,
            height: max(0, geometry.pageSize.height - 2 * geometry.margin - footerHeight)
        )
        self.y = bodyFrame.minY
        self.pageTop = bodyFrame.minY
    }

    // MARK: El informe

    mutating func compose(_ report: EvidenceReport) {
        place(textRow(report.title, style: .title))
        place(textRow(report.subtitle, style: .subtitle))

        for section in report.sections {
            let labelWidth = factLabelWidth(in: section.blocks)
            let pieces = section.blocks.map { piece($0, factLabelWidth: labelWidth) }
            let company = companies(of: pieces)
            space(geometry.sectionSpacing)
            place(
                textRow(section.title, style: .sectionTitle),
                keepingWith: pieces.first.map { geometry.blockSpacing + lead(of: $0) + company[0] } ?? 0
            )
            for (index, piece) in pieces.enumerated() {
                space(geometry.blockSpacing)
                switch piece {
                case .heading(let row):
                    place(row, keepingWith: company[index])
                case .text(let row, let quoted):
                    place(row, quoted: quoted)
                case .facts(let facts):
                    place(facts)
                case .table(let header, let rows, let width):
                    place(header: header, rows: rows, width: width)
                }
            }
        }
    }

    /// Lo que tiene que caber debajo de cada pieza para que no se quede al pie de una página
    /// encabezando nada: cero salvo en un encabezado, que arrastra el principio de lo que sigue —
    /// y, si lo que sigue es otro encabezado, también lo que ése arrastra.
    private func companies(of pieces: [Piece]) -> [CGFloat] {
        var companies = [CGFloat](repeating: 0, count: pieces.count)
        for index in pieces.indices.reversed().dropFirst() {
            guard case .heading = pieces[index] else { continue }
            companies[index] = geometry.blockSpacing + lead(of: pieces[index + 1]) + companies[index + 1]
        }
        return companies
    }

    /// Lo que tiene que caber de una pieza bajo un encabezado para que éste no se quede al pie.
    private func lead(of piece: Piece) -> CGFloat {
        switch piece {
        case .heading(let row):
            return row.height
        case .text(let row, _):
            return row.lead
        case .facts(let facts):
            return facts.first.map { wholeLead(of: $0.row, in: bodyFrame.height) } ?? 0
        case .table(let header, let rows, _):
            return header.height
                + (rows.first.map { wholeLead(of: $0, in: bodyFrame.height - header.height) } ?? 0)
        }
    }

    /// Lo que tiene que caber de una fila que no se parte mientras quepa en una página: ella
    /// entera, o su primera línea si es más alta que el sitio que una página le puede dar.
    private func wholeLead(of row: Row, in room: CGFloat) -> CGFloat {
        row.height <= room + Self.tolerance ? row.height : row.lead
    }

    /// Las páginas terminadas, cada una con su pie: el pie necesita saber cuántas son.
    func pages(footer subtitle: String) -> [EvidenceReportPage] {
        let bodies = finished + [marks]
        let ruleY = bodyFrame.maxY + geometry.footerSpacing
        let textY = ruleY + geometry.footerSpacing
        let widestLabel = measurer.width(
            of: EvidenceWording.reportPageLabel(bodies.count, of: bodies.count), style: .footer
        )
        let session = clipped(
            subtitle, style: .footer, to: bodyFrame.width - widestLabel - geometry.columnGap
        )

        return bodies.enumerated().map { index, body in
            let label = EvidenceWording.reportPageLabel(index + 1, of: bodies.count)
            let labelX = bodyFrame.maxX - measurer.width(of: label, style: .footer)
            return EvidenceReportPage(
                number: index + 1,
                body: body,
                footer: [
                    .fill(
                        CGRect(x: bodyFrame.minX, y: ruleY, width: bodyFrame.width, height: Self.ruleThickness),
                        .rule
                    ),
                    .text(session, style: .footer, origin: CGPoint(x: bodyFrame.minX, y: textY)),
                    .text(label, style: .footer, origin: CGPoint(x: labelX, y: textY)),
                ]
            )
        }
    }

    /// El texto en una sola línea, con puntos suspensivos si no cabe. Solo para el pie, que repite
    /// en cada página lo que la primera dice entero.
    private func clipped(_ text: String, style: EvidenceReportTextStyle, to width: CGFloat) -> String {
        guard measurer.width(of: text, style: style) > width else { return text }
        let ellipsis = "…"
        let room = width - measurer.width(of: ellipsis, style: style)
        let first = measurer.lines(of: text, style: style, width: room).first ?? ""
        return first + ellipsis
    }

    // MARK: De bloque a filas

    private func textRow(
        _ text: String,
        style: EvidenceReportTextStyle,
        indent: CGFloat = 0
    ) -> Row {
        Row(
            columns: [Column(
                x: bodyFrame.minX + indent,
                style: style,
                lines: measurer.lines(of: text, style: style, width: bodyFrame.width - indent)
            )],
            lineHeight: measurer.lineHeight(of: style),
            padding: 0
        )
    }

    private func piece(_ block: EvidenceReportBlock, factLabelWidth: CGFloat) -> Piece {
        switch block {
        case .heading(let text):
            return .heading(textRow(text, style: .heading))
        case .paragraph(let text):
            return .text(textRow(text, style: .paragraph), quoted: false)
        case .note(let text):
            return .text(textRow(text, style: .note, indent: geometry.noteIndent), quoted: true)
        case .facts(let facts):
            return .facts(factRows(facts, labelWidth: factLabelWidth))
        case .table(let table):
            return tablePiece(table)
        }
    }

    /// El ancho de la columna de rótulos de **todas** las listas de datos de una sección.
    ///
    /// Es uno por sección y no uno por lista porque una sección encadena varias —una por
    /// requisito, una por comprobación— y con un ancho cada una los valores bailan de una a otra.
    /// El rótulo se lleva lo que pide mientras no pase de la mitad; el valor, todo lo demás.
    private func factLabelWidth(in blocks: [EvidenceReportBlock]) -> CGFloat {
        let facts = blocks.flatMap { block -> [EvidenceReportFact] in
            if case .facts(let facts) = block { return facts }
            return []
        }
        let widestLabel = facts.map { measurer.width(of: $0.label, style: .factLabel) }.max() ?? 0
        let widestValue = facts.map { measurer.width(of: $0.value, style: .factValue) }.max() ?? 0
        return EvidenceReportColumnWidths.shares(
            natural: [widestLabel + geometry.columnGap, widestValue],
            into: bodyFrame.width
        )[0]
    }

    private func factRows(_ facts: [EvidenceReportFact], labelWidth: CGFloat) -> [FactRow] {
        let lineHeight = max(measurer.lineHeight(of: .factLabel), measurer.lineHeight(of: .factValue))

        return facts.map { fact in
            FactRow(
                row: Row(
                    columns: [
                        Column(
                            x: bodyFrame.minX,
                            style: .factLabel,
                            lines: measurer.lines(
                                of: fact.label, style: .factLabel, width: labelWidth - geometry.columnGap
                            )
                        ),
                        Column(
                            x: bodyFrame.minX + labelWidth,
                            style: .factValue,
                            lines: measurer.lines(
                                of: fact.value, style: .factValue, width: bodyFrame.width - labelWidth
                            )
                        ),
                    ],
                    lineHeight: lineHeight,
                    padding: 0
                ),
                staysWithNext: fact.staysWithNext
            )
        }
    }

    private func tablePiece(_ table: EvidenceReportTable) -> Piece {
        let natural = table.columns.indices.map { column -> CGFloat in
            let cells = table.rows.compactMap { $0.indices.contains(column) ? $0[column] : nil }
            let widest = cells.map { measurer.width(of: $0, style: .cell) }.max() ?? 0
            return max(widest, measurer.width(of: table.columns[column], style: .columnHeader))
                + geometry.columnGap
        }
        let widths = EvidenceReportColumnWidths.filling(natural: natural, into: bodyFrame.width)
        var origins: [CGFloat] = []
        var x = bodyFrame.minX
        for width in widths {
            origins.append(x + geometry.columnGap / 2)
            x += width
        }

        func row(_ cells: [String], style: EvidenceReportTextStyle) -> Row {
            Row(
                columns: zip(cells.indices, cells).compactMap { index, cell in
                    guard widths.indices.contains(index) else { return nil }
                    return Column(
                        x: origins[index],
                        style: style,
                        lines: measurer.lines(of: cell, style: style, width: widths[index] - geometry.columnGap)
                    )
                },
                lineHeight: measurer.lineHeight(of: style),
                padding: geometry.cellPadding
            )
        }
        return .table(
            header: row(table.columns, style: .columnHeader),
            rows: table.rows.map { row($0, style: .cell) },
            width: widths.reduce(0, +)
        )
    }

    // MARK: Colocar

    private var isAtPageTop: Bool { y <= pageTop + Self.tolerance }

    /// Aire antes de lo siguiente. Al principio de una página no se deja: ya lo es el margen.
    private mutating func space(_ amount: CGFloat) {
        guard !isAtPageTop else { return }
        y += amount
    }

    private mutating func breakPage() {
        finished.append(marks)
        marks = []
        y = bodyFrame.minY
        if let runningHeader {
            draw(header: runningHeader.row, width: runningHeader.width)
        }
        pageTop = y
    }

    /// Coloca una fila, partiéndola entre páginas por donde haga falta.
    ///
    /// - Parameter following: lo que tiene que caber además debajo de su última línea. Si no
    ///   cabe, la fila —o su último trozo— empieza en la página siguiente.
    /// - Parameter whole: no se parte mientras quepa entera en una página.
    private mutating func place(
        _ row: Row,
        keepingWith following: CGFloat = 0,
        whole: Bool = false,
        quoted: Bool = false
    ) {
        let total = row.lineCount
        var index = 0
        while index < total {
            let remaining = total - index
            let room = bodyFrame.maxY - y - 2 * row.padding
            let fitting = max(0, Int(((room + Self.tolerance) / row.lineHeight).rounded(.down)))
            var take = min(remaining, fitting)
            // Ninguna línea sola: ni la última de un texto en cabeza de la página siguiente…
            if remaining - take == 1, take >= Self.linesKeptTogether + 1 { take -= 1 }

            if !isAtPageTop {
                let ends = take == remaining
                // …ni la primera al pie de ésta.
                let startsAlone = index == 0 && !ends && take < Self.linesKeptTogether
                let endsWithoutItsCompany = ends
                    && y + 2 * row.padding + CGFloat(take) * row.lineHeight + following
                        > bodyFrame.maxY + Self.tolerance
                let wouldSplitNeedlessly = whole && index == 0 && !ends
                    && row.height <= bodyFrame.maxY - pageTop + Self.tolerance
                if take == 0 || endsWithoutItsCompany || wouldSplitNeedlessly || startsAlone {
                    breakPage()
                    continue
                }
            }
            // Con la página entera por delante no hay salto que gane sitio: se coloca lo que
            // quepa, y una línea más alta que la página se coloca igualmente antes que perderla.
            take = max(1, take)

            let top = y
            for column in row.columns {
                for (offset, line) in column.lines.dropFirst(index).prefix(take).enumerated()
                where !line.isEmpty {
                    marks.append(.text(
                        line,
                        style: column.style,
                        origin: CGPoint(x: column.x, y: top + row.padding + CGFloat(offset) * row.lineHeight)
                    ))
                }
            }
            y = top + 2 * row.padding + CGFloat(take) * row.lineHeight
            if quoted {
                marks.append(.fill(
                    CGRect(x: bodyFrame.minX, y: top, width: Self.quoteBarWidth, height: y - top),
                    .quoteBar
                ))
            }
            index += take
            if index < total { breakPage() }
        }
    }

    private mutating func place(_ facts: [FactRow]) {
        // Si el dato anterior no puede separarse de éste y los dos no caben enteros en una
        // página, éste se parte: ir juntos manda sobre ir entero.
        var sharesPageWithPrevious = false
        for (index, fact) in facts.enumerated() {
            if index > 0 { space(geometry.factSpacing) }
            var company: CGFloat = 0
            var nextSharesPage = false
            if fact.staysWithNext, let next = facts.dropFirst(index + 1).first {
                let together = fact.row.height + geometry.factSpacing + next.row.height
                nextSharesPage = together > bodyFrame.height + Self.tolerance
                company = geometry.factSpacing + (nextSharesPage ? next.row.lead : next.row.height)
            }
            place(fact.row, keepingWith: company, whole: !sharesPageWithPrevious)
            sharesPageWithPrevious = nextSharesPage
        }
    }

    private mutating func place(header: Row, rows: [Row], width: CGFloat) {
        // Una cabecera sin ninguna fila debajo, al pie de una página, no encabeza nada.
        let lead = lead(of: .table(header: header, rows: rows, width: width))
        if !isAtPageTop, y + lead > bodyFrame.maxY + Self.tolerance {
            breakPage()
        }
        draw(header: header, width: width)
        runningHeader = (header, width)
        for row in rows {
            place(row, whole: true)
            // Dentro del aire de la fila, para que el filete de la última de una página no
            // caiga fuera del cuerpo.
            marks.append(.fill(
                CGRect(
                    x: bodyFrame.minX, y: y - Self.ruleThickness,
                    width: width, height: Self.ruleThickness
                ),
                .rule
            ))
        }
        runningHeader = nil
    }

    /// La cabecera de una tabla, que no se parte: son rótulos de una o dos líneas.
    private mutating func draw(header: Row, width: CGFloat) {
        marks.append(.fill(
            CGRect(x: bodyFrame.minX, y: y, width: width, height: header.height),
            .headerBand
        ))
        for column in header.columns {
            for (offset, line) in column.lines.enumerated() where !line.isEmpty {
                marks.append(.text(
                    line,
                    style: column.style,
                    origin: CGPoint(
                        x: column.x,
                        y: y + header.padding + CGFloat(offset) * header.lineHeight
                    )
                ))
            }
        }
        y += header.height
    }
}
