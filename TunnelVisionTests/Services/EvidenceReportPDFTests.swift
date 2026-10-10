import PDFKit
import XCTest
@testable import Shared

/// Tests de la mitad del informe que sí toca UIKit: la tipografía con la que se mide y el PDF que
/// sale. Lo que decide la paginación está en `EvidenceReportLayoutTests`; aquí se afirma que la
/// medida de verdad cumple lo que aquélla da por hecho, y que el fichero es un PDF que otro
/// lector —PDFKit, que no comparte nada con quien lo escribe— abre y lee.
final class EvidenceReportPDFTests: XCTestCase {

    private typealias Fixtures = FindingFixtures

    private let typography = EvidenceReportTypography()

    private func report() throws -> EvidenceReport {
        let bundle = try EvidenceBundle(
            project: try Fixtures.project(allowlist: ["api.example.com"]),
            session: Fixtures.session(inspection: InspectionConditions(inspectionEnabled: true, caTrusted: true)),
            markers: [Fixtures.marker(id: 1, at: 4.5)],
            flows: [
                Fixtures.flow(id: 1, tlsStatus: .notInspectable, sni: "bank.example.com", serverTLS: Fixtures.negotiated(.tls13), streamOpening: .tlsHandshake),
                Fixtures.flow(id: 2, remotePort: 80, tlsStatus: .plaintext, sni: nil, streamOpening: .httpRequest),
                Fixtures.flow(id: 3, sni: "tracker.example.net", serverTLS: Fixtures.negotiated(.tls10)),
                Fixtures.flow(id: 4, proto: .udp, sni: nil, quic: QUICVersionReading(version: .v1, source: .client)),
            ],
            catalogue: try RequirementCatalogueLibrary.catalogue(
                identifier: RequirementCatalogueLibrary.defaultIdentifier
            ),
            exportedWith: "1.1 (4)",
            exportedAt: Fixtures.start.addingTimeInterval(7_200.5)
        )
        return try EvidenceReport(
            bundle: bundle,
            capture: EvidenceCaptureDocument(
                sessionID: Fixtures.sessionID,
                snaplen: 262_144,
                flows: [.init(id: 1, packets: EvidencePacketTally(written: 10, lost: [.notCaptured: 2]))],
                sourceFiles: [],
                writtenOutsideSession: .init(beforeStart: 1, afterEnd: 0)
            ),
            limits: .bundled
        )
    }

    private func squeezed(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }

    /// Como `squeezed`, y sin guiones bajos: PDFKit devuelve `tr-03161-1_3.0` como
    /// `tr-03161-13.0_` (coloca el guion bajo por su altura en la línea, no por su sitio). Es del
    /// lector: otros extractores lo leen en orden.
    private func readable(_ text: String) -> String {
        squeezed(text).replacingOccurrences(of: "_", with: "")
    }

    // MARK: - La tipografía

    func testBreakingATextIntoLinesLosesNothingButWhiteSpace() {
        let texts = [
            EvidenceWording.captureContentsNote,
            "f8837fbee1710ad3555bbe333f4a50e83c0c66b24724ab3be5cc634a80beb001",
            "a-host-name-that-goes-on.and-on.and-on.and-on.and-on.and-on.and-on.example.com, with a tail",
            "Two  spaces,\ta tab and\na line break typed by the assessor.\n\nAnd a blank line.",
            "Größe · naïve · 日本語のテキスト · emoji 🩺 in a note",
            "x",
        ]
        for style in EvidenceReportTextStyle.allCases {
            for width in [20, 60, 140, 482] as [CGFloat] {
                for text in texts {
                    let lines = typography.lines(of: text, style: style, width: width)
                    XCTAssertEqual(squeezed(lines.joined()), squeezed(text), "\(style) a \(width) pt")
                }
            }
        }
    }

    func testEveryLineFitsTheWidthItWasBrokenFor() {
        let text = EvidenceWording.captureContentsNote
            + " f8837fbee1710ad3555bbe333f4a50e83c0c66b24724ab3be5cc634a80beb001"
        for style in EvidenceReportTextStyle.allCases {
            for width in [60, 140, 482] as [CGFloat] {
                for line in typography.lines(of: text, style: style, width: width) {
                    XCTAssertLessThanOrEqual(
                        typography.width(of: line, style: style), width + 1,
                        "«\(line)» en \(style) a \(width) pt"
                    )
                }
            }
        }
    }

    func testATextWithNothingInItIsNoLines() {
        XCTAssertEqual(typography.lines(of: "", style: .paragraph, width: 200), [])
    }

    func testALineIsTallerThanItsFontAndAWiderTextMeasuresMore() {
        for style in EvidenceReportTextStyle.allCases {
            XCTAssertGreaterThan(typography.lineHeight(of: style), typography.font(for: style).lineHeight)
            XCTAssertGreaterThan(
                typography.width(of: "wider text", style: style), typography.width(of: "wider", style: style)
            )
        }
    }

    /// Un rótulo y su valor van en la misma fila, y una fila tiene una sola altura de línea.
    func testALabelAndItsValueShareALineHeight() {
        XCTAssertEqual(typography.lineHeight(of: .factLabel), typography.lineHeight(of: .factValue))
    }

    /// Ni blanco sobre blanco ni un color que dependa de la apariencia del dispositivo.
    func testEveryInkIsAFixedGreyThatShowsOnPaper() {
        let appearances = [UITraitCollection(userInterfaceStyle: .light), UITraitCollection(userInterfaceStyle: .dark)]
        var inks = EvidenceReportTextStyle.allCases.map { typography.ink(for: $0) }
        inks += [EvidenceReportFill.rule, .quoteBar, .headerBand].map { typography.ink(for: $0) }

        for ink in inks {
            XCTAssertEqual(ink.resolvedColor(with: appearances[0]), ink.resolvedColor(with: appearances[1]))
            var white: CGFloat = 1
            XCTAssertTrue(ink.getWhite(&white, alpha: nil))
            XCTAssertLessThan(white, 0.95)
        }
        for style in EvidenceReportTextStyle.allCases {
            var white: CGFloat = 1
            XCTAssertTrue(typography.ink(for: style).getWhite(&white, alpha: nil))
            XCTAssertLessThan(white, 0.5, "\(style): texto demasiado claro para imprimirse")
        }
    }

    // MARK: - El PDF

    func testThePDFHasThePagesOfTheLayoutEachOnA4() throws {
        let report = try report()
        let layout = EvidenceReportLayout(report: report, geometry: .a4, measuring: typography)

        let document = try XCTUnwrap(PDFDocument(
            data: EvidenceReportPDF.data(of: layout, typography: typography, title: report.title, creator: "TunnelVision 1.1 (4)")
        ))

        XCTAssertGreaterThan(layout.pages.count, 1)
        XCTAssertEqual(document.pageCount, layout.pages.count)
        for index in 0..<document.pageCount {
            let box = try XCTUnwrap(document.page(at: index)).bounds(for: .mediaBox)
            XCTAssertEqual(box.width, 595.28, accuracy: 0.01)
            XCTAssertEqual(box.height, 841.89, accuracy: 0.01)
        }
    }

    func testEveryLineOfTheLayoutCanBeReadBackFromItsPageOfThePDF() throws {
        let report = try report()
        let layout = EvidenceReportLayout(report: report, geometry: .a4, measuring: typography)
        let document = try XCTUnwrap(PDFDocument(
            data: EvidenceReportPDF.data(of: layout, typography: typography, title: report.title, creator: "TunnelVision 1.1 (4)")
        ))

        var lines = 0
        for page in layout.pages {
            let read = readable(try XCTUnwrap(document.page(at: page.number - 1)?.string))
            for mark in page.body + page.footer {
                guard case .text(let text, _, _) = mark else { continue }
                lines += 1
                XCTAssertTrue(read.contains(readable(text)), "«\(text)» no se lee en la página \(page.number)")
            }
        }
        XCTAssertGreaterThan(lines, 100)
    }

    func testThePDFNamesTheReportAndTheToolThatWroteIt() throws {
        let report = try report()
        let layout = EvidenceReportLayout(report: report, geometry: .a4, measuring: typography)

        let attributes = try XCTUnwrap(PDFDocument(
            data: EvidenceReportPDF.data(of: layout, typography: typography, title: report.title, creator: "TunnelVision 1.1 (4)")
        )?.documentAttributes)

        XCTAssertEqual(attributes[PDFDocumentAttribute.titleAttribute] as? String, "Network evidence report")
        XCTAssertEqual(attributes[PDFDocumentAttribute.creatorAttribute] as? String, "TunnelVision 1.1 (4)")
    }

    /// El informe de verdad, con la tipografía de verdad: lo que `EvidenceReportLayoutTests`
    /// afirma con un informe hecho a mano se cumple también aquí.
    func testOnA4TheRealReportKeepsEveryVerdictWithItsCoverageAndEveryLineInsideTheMargins() throws {
        let report = try report()
        let layout = EvidenceReportLayout(report: report, geometry: .a4, measuring: typography)
        let frame = layout.bodyFrame.insetBy(dx: -1, dy: -0.01)

        var verdicts = 0
        for page in layout.pages {
            var lines: [(text: String, style: EvidenceReportTextStyle, origin: CGPoint)] = []
            for mark in page.body {
                guard case .text(let text, let style, let origin) = mark else { continue }
                lines.append((text, style, origin))
                XCTAssertTrue(
                    frame.contains(CGRect(
                        x: origin.x, y: origin.y,
                        width: typography.width(of: text, style: style),
                        height: typography.lineHeight(of: style)
                    )),
                    "«\(text)» se sale del cuerpo en la página \(page.number)"
                )
            }
            for verdict in lines where verdict.style == .factLabel && verdict.text == "Verdict" {
                verdicts += 1
                let value = try XCTUnwrap(lines.first { $0.style == .factValue && $0.origin.y == verdict.origin.y })
                // El único veredicto sin `toolCoverage` es el de lo que queda fuera del alcance.
                guard value.text != "Not assessed by this tool." else { continue }
                XCTAssertTrue(
                    lines.contains { $0.text == "Tool coverage (toolCoverage)" && $0.origin.y > verdict.origin.y },
                    "un veredicto cierra la página \(page.number) sin su toolCoverage"
                )
            }
        }
        XCTAssertEqual(verdicts, 10)
    }
}
