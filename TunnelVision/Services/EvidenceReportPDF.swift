import CoreText
import Shared
import UIKit

/// La tipografía del informe en papel: qué fuente y qué tinta lleva cada papel, y cuánto ocupa un
/// texto con ella.
///
/// Los tamaños son fijos y las tintas son grises literales, a propósito: ni el tamaño de letra del
/// dispositivo ni su apariencia pueden cambiar un documento que va a un expediente, y la misma
/// sesión tiene que dar el mismo informe en cualquiera (`docs/spec/audit.md` § *Drawing the
/// report*). Por eso no pasa por los tokens del sistema visual, que existen para lo contrario.
public struct EvidenceReportTypography: EvidenceReportTextMeasuring, Sendable {

    public init() {}

    func font(for style: EvidenceReportTextStyle) -> UIFont {
        switch style {
        case .title: return .systemFont(ofSize: 20, weight: .bold)
        case .subtitle: return .systemFont(ofSize: 10, weight: .regular)
        case .sectionTitle: return .systemFont(ofSize: 14, weight: .bold)
        case .heading: return .systemFont(ofSize: 10.5, weight: .semibold)
        case .paragraph, .note: return .systemFont(ofSize: 9.5, weight: .regular)
        case .factLabel, .factValue: return .systemFont(ofSize: 9, weight: .regular)
        case .columnHeader: return .systemFont(ofSize: 8.5, weight: .semibold)
        case .cell: return .systemFont(ofSize: 8.5, weight: .regular)
        case .footer: return .systemFont(ofSize: 8, weight: .regular)
        }
    }

    func ink(for style: EvidenceReportTextStyle) -> UIColor {
        switch style {
        case .title, .sectionTitle, .heading, .paragraph, .note, .factValue, .columnHeader, .cell:
            return UIColor(white: 0, alpha: 1)
        case .subtitle, .factLabel, .footer:
            return UIColor(white: 0.35, alpha: 1)
        }
    }

    func ink(for fill: EvidenceReportFill) -> UIColor {
        switch fill {
        case .rule: return UIColor(white: 0.75, alpha: 1)
        case .quoteBar: return UIColor(white: 0.6, alpha: 1)
        case .headerBand: return UIColor(white: 0.92, alpha: 1)
        }
    }

    func attributes(for style: EvidenceReportTextStyle) -> [NSAttributedString.Key: Any] {
        [.font: font(for: style), .foregroundColor: ink(for: style)]
    }

    // MARK: - EvidenceReportTextMeasuring

    public func lineHeight(of style: EvidenceReportTextStyle) -> CGFloat {
        // Algo más que la de la fuente: a 9 pt, las seis líneas pegadas de un `toolCoverage`
        // se leen como una mancha.
        (font(for: style).lineHeight * 1.15).rounded(.up)
    }

    public func width(of text: String, style: EvidenceReportTextStyle) -> CGFloat {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes(for: style))
        )
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)).rounded(.up)
    }

    public func lines(of text: String, style: EvidenceReportTextStyle, width: CGFloat) -> [String] {
        let source = text as NSString
        guard source.length > 0 else { return [] }
        let typesetter = CTTypesetterCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes(for: style))
        )

        var lines: [String] = []
        var start = 0
        while start < source.length {
            // Si ni un carácter cabe, el compositor devuelve cero: se avanza uno para no perderlo
            // ni quedarse dando vueltas.
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(max(1, width))))
            let line = source.substring(with: NSRange(location: start, length: min(count, source.length - start)))
            lines.append(line.trimmingCharacters(in: .whitespacesAndNewlines))
            start += count
        }
        return lines
    }
}

/// Dibuja el informe ya compuesto como `report.pdf`.
///
/// No decide nada: recorre las marcas de `EvidenceReportLayout` y las pone donde dicen.
public enum EvidenceReportPDF {

    /// - Parameter title: el título del documento en sus metadatos.
    /// - Parameter creator: la herramienta que lo escribe, con su versión.
    public static func data(
        of layout: EvidenceReportLayout,
        typography: EvidenceReportTypography,
        title: String,
        creator: String
    ) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: title,
            kCGPDFContextCreator as String: creator,
        ]
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: layout.geometry.pageSize),
            format: format
        )
        return renderer.pdfData { context in
            for page in layout.pages {
                context.beginPage()
                for mark in page.body + page.footer {
                    switch mark {
                    case .text(let text, let style, let origin):
                        (text as NSString).draw(at: origin, withAttributes: typography.attributes(for: style))
                    case .fill(let rect, let fill):
                        typography.ink(for: fill).setFill()
                        context.cgContext.fill(rect)
                    }
                }
            }
        }
    }
}
