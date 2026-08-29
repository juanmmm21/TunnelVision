import Foundation
import XCTest
@testable import Shared

/// La copia del badge de cifrado. Es la que le dice al usuario si lo que acaba de hacer viajó
/// protegido, así que se afirma aquí: confundir dos de los cuatro estados es exactamente el error que
/// nadie detectaría mirando la pantalla.
final class TLSStatusPresentationTests: XCTestCase {

    private var all: [TLSStatusPresentation] {
        TLSStatusPresentation.allStatuses.map(TLSStatusPresentation.forStatus)
    }

    func testTheFourStatusesAreOfferedInOrderAndNoneIsMissing() {
        XCTAssertEqual(
            TLSStatusPresentation.allStatuses,
            [.plaintext, .encrypted, .inspected, .notInspectable]
        )
    }

    /// Ninguno de los tres canales del badge puede repetirse: si dos estados comparten etiqueta,
    /// símbolo o papel, el usuario no los distingue aunque el dato sea correcto.
    func testEveryStatusIsDistinguishableByLabelSymbolAndRole() {
        XCTAssertEqual(Set(all.map(\.label)).count, 4)
        XCTAssertEqual(Set(all.map(\.systemImage)).count, 4)
        XCTAssertEqual(Set(all.map(\.role)).count, 4)
    }

    func testEachStatusCarriesItsOwnRole() {
        XCTAssertEqual(TLSStatusPresentation.forStatus(.plaintext).role, .plaintext)
        XCTAssertEqual(TLSStatusPresentation.forStatus(.encrypted).role, .encrypted)
        XCTAssertEqual(TLSStatusPresentation.forStatus(.inspected).role, .inspected)
        XCTAssertEqual(TLSStatusPresentation.forStatus(.notInspectable).role, .notInspectable)
    }

    /// El estado que hay que mirar es el que **no** va cifrado, y se enseña con el candado abierto.
    func testPlaintextIsTheOneThatLooksLikeAWarning() {
        let presentation = TLSStatusPresentation.forStatus(.plaintext)
        XCTAssertEqual(presentation.systemImage, "lock.open")
        XCTAssertTrue(presentation.detail.contains("in the clear"))
    }

    /// El caso de ADR 0003: una app que pinnea no es un fallo nuestro ni algo por reintentar, y la
    /// copia tiene que leerse como lo que es —una garantía—, no como una limitación.
    func testPinnedTrafficReadsAsATrustSignalAndNotAsAFailure() {
        let presentation = TLSStatusPresentation.forStatus(.notInspectable)
        XCTAssertEqual(presentation.role, .notInspectable)
        XCTAssertNotEqual(presentation.role, .warning, "no es una avería de la app")
        XCTAssertTrue(presentation.detail.contains("stays private"))
        for word in ["fail", "error", "couldn't", "unsupported"] {
            XCTAssertFalse(
                presentation.detail.lowercased().contains(word),
                "la explicación no puede sonar a avería: \(presentation.detail)"
            )
        }
    }

    /// Lo que el usuario mira mientras el tráfico se descifra: que es **suyo** y que no sale de ahí.
    func testInspectedSaysWhoseCertificateAndWhereItStays() {
        let detail = TLSStatusPresentation.forStatus(.inspected).detail
        XCTAssertTrue(detail.contains("you installed"))
        XCTAssertTrue(detail.contains("this device"))
    }

    /// VoiceOver no ve el color ni el icono: si leyera solo la etiqueta, "Kept private" y "Encrypted"
    /// serían indistinguibles en intención (principio 6).
    func testVoiceOverReadsTheLabelAndTheReason() {
        for presentation in all {
            XCTAssertTrue(presentation.accessibilityDescription.hasPrefix(presentation.label))
            XCTAssertTrue(presentation.accessibilityDescription.contains(presentation.detail))
        }
    }

    /// Ninguna etiqueta puede colar jerga de las specs de desarrollo (principio 3).
    func testNoLabelLeaksDeveloperJargon() {
        for presentation in all {
            let text = (presentation.label + " " + presentation.detail).lowercased()
            for word in ["tls", "mitm", "sni", "handshake", "pinning", "certificate authority"] {
                XCTAssertFalse(text.contains(word), "jerga en la copia: \(text)")
            }
        }
    }
    // MARK: - Cuánto pesa el estado en una fila

    /// La decisión de la segunda pasada estética: en una fila de la Timeline, `encrypted` es la
    /// lectura por defecto de la lista y no gasta palabra; los otros tres son desviaciones de esa
    /// promesa y se escriben.
    func testOnlyEncryptedGoesUnspokenInARow() {
        XCTAssertEqual(
            TLSStatusPresentation.emphasis(for: .encrypted, isAccessibilitySize: false),
            .mark
        )
        for status in [TLSInspectionStatus.plaintext, .inspected, .notInspectable] {
            XCTAssertEqual(
                TLSStatusPresentation.emphasis(for: status, isAccessibilitySize: false),
                .named,
                "una desviación de lo que la lista da por supuesto se dice con palabras: \(status)"
            )
        }
    }

    /// A tamaños de accesibilidad no hay carril donde poner la marca, así que los cuatro se nombran.
    /// Sin esto, la fila que menos texto lleva sería justamente la que menos dice.
    func testEveryStatusIsSpelledAtAccessibilitySizes() {
        for status in TLSStatusPresentation.allStatuses {
            XCTAssertEqual(
                TLSStatusPresentation.emphasis(for: status, isAccessibilitySize: true),
                .named,
                "sin carril, la palabra es lo único que queda: \(status)"
            )
        }
    }

    /// El porqué de que un estado pueda ir sin palabra, afirmado aquí para que la regla no sobreviva a
    /// su causa: solo se sostiene mientras su símbolo lo distinga él solo de los otros tres. Si dos
    /// estados compartieran símbolo, la fila muda dejaría de decir cuál es.
    func testAStatusMayGoUnspokenOnlyWhileItsSymbolTellsItApart() {
        let unspoken = TLSStatusPresentation.allStatuses.filter {
            TLSStatusPresentation.emphasis(for: $0, isAccessibilitySize: false) == .mark
        }
        for status in unspoken {
            let symbol = TLSStatusPresentation.forStatus(status).systemImage
            let others = TLSStatusPresentation.allStatuses
                .filter { $0 != status }
                .map { TLSStatusPresentation.forStatus($0).systemImage }
            XCTAssertFalse(
                others.contains(symbol),
                "\(status) se dibuja sin palabra y su símbolo no es suyo solo: \(symbol)"
            )
        }
    }
}
