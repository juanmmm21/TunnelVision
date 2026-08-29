import Foundation
import XCTest

// `DER` es un detalle interno de `Shared` (nadie fuera del framework serializa ASN.1 a mano), así que
// se importa con `@testable` en vez de hacerlo público: la alternativa sería ampliar la API del
// framework solo para poder probarlo, que es dejar que el test decida el diseño.
@testable import Shared

/// Tests del codificador ASN.1 DER. Los vectores son golden calculados a mano (o tomados de OIDs
/// públicos conocidos), no capturados de esta implementación: un golden capturado solo probaría que
/// no ha cambiado, no que es correcto.
final class DERWriterTests: XCTestCase {

    // MARK: - Longitud

    func testShortFormLength() {
        XCTAssertEqual(DER.length(0), [0x00])
        XCTAssertEqual(DER.length(1), [0x01])
        XCTAssertEqual(DER.length(127), [0x7f])
    }

    func testLongFormLength() {
        XCTAssertEqual(DER.length(128), [0x81, 0x80])
        XCTAssertEqual(DER.length(255), [0x81, 0xff])
        XCTAssertEqual(DER.length(256), [0x82, 0x01, 0x00])
        XCTAssertEqual(DER.length(65535), [0x82, 0xff, 0xff])
        XCTAssertEqual(DER.length(65536), [0x83, 0x01, 0x00, 0x00])
    }

    // MARK: - INTEGER

    func testIntegerStripsRedundantLeadingZeros() {
        XCTAssertEqual(DER.integer(magnitude: [0x00, 0x00, 0x01]), [0x02, 0x01, 0x01])
    }

    func testIntegerKeepsOneZeroForValueZero() {
        XCTAssertEqual(DER.integer(magnitude: [0x00, 0x00]), [0x02, 0x01, 0x00])
        XCTAssertEqual(DER.integer(0), [0x02, 0x01, 0x00])
    }

    func testIntegerPrependsZeroWhenHighBitSet() {
        // 0x80 se leería como negativo en complemento a dos: DER antepone 0x00 para forzar positivo.
        XCTAssertEqual(DER.integer(magnitude: [0x80]), [0x02, 0x02, 0x00, 0x80])
        XCTAssertEqual(DER.integer(magnitude: [0xff, 0x01]), [0x02, 0x03, 0x00, 0xff, 0x01])
    }

    func testIntegerFromValue() {
        XCTAssertEqual(DER.integer(2), [0x02, 0x01, 0x02])
        XCTAssertEqual(DER.integer(255), [0x02, 0x02, 0x00, 0xff])
        XCTAssertEqual(DER.integer(256), [0x02, 0x02, 0x01, 0x00])
    }

    // MARK: - BOOLEAN / NULL

    func testBoolean() {
        XCTAssertEqual(DER.boolean(true), [0x01, 0x01, 0xff])
        XCTAssertEqual(DER.boolean(false), [0x01, 0x01, 0x00])
    }

    func testNull() {
        XCTAssertEqual(DER.null(), [0x05, 0x00])
    }

    // MARK: - OBJECT IDENTIFIER

    /// sha256WithRSAEncryption (1.2.840.113549.1.1.11) es un OID público de codificación conocida:
    /// ejercita el primer arco combinado (42) y la base 128 multibyte (840, 113549).
    func testObjectIdentifierKnownVector() {
        XCTAssertEqual(
            DER.objectIdentifier("1.2.840.113549.1.1.11"),
            [0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b]
        )
    }

    func testObjectIdentifierShortVector() {
        // basicConstraints (2.5.29.19): primer byte 2*40+5 = 85 = 0x55.
        XCTAssertEqual(DER.objectIdentifier("2.5.29.19"), [0x06, 0x03, 0x55, 0x1d, 0x13])
    }

    // MARK: - BIT STRING de banderas (KeyUsage)

    func testNamedBitStringForCAUsage() {
        // digitalSignature(0) + keyCertSign(5) + cRLSign(6): primer byte 0x86, 1 bit sin usar.
        XCTAssertEqual(
            DER.namedBitString(setBits: [0, 5, 6]),
            [0x03, 0x02, 0x01, 0x86]
        )
    }

    func testNamedBitStringForLeafUsage() {
        // digitalSignature(0) + keyEncipherment(2): primer byte 0xA0, 5 bits sin usar.
        XCTAssertEqual(
            DER.namedBitString(setBits: [0, 2]),
            [0x03, 0x02, 0x05, 0xa0]
        )
    }

    func testNamedBitStringEmpty() {
        XCTAssertEqual(DER.namedBitString(setBits: []), [0x03, 0x01, 0x00])
    }

    // MARK: - Tiempo

    func testUTCTimeForYearInRange() {
        let date = Self.utcDate(year: 2025, month: 1, day: 2, hour: 3, minute: 4, second: 5)
        XCTAssertEqual(DER.time(date), [0x17, 0x0d] + Array("250102030405Z".utf8))
    }

    func testGeneralizedTimeForYearBeyond2049() {
        let date = Self.utcDate(year: 2050, month: 6, day: 7, hour: 8, minute: 9, second: 10)
        XCTAssertEqual(DER.time(date), [0x18, 0x0f] + Array("20500607080910Z".utf8))
    }

    // MARK: - Contenedores y etiquetas

    func testSequenceWrapsConcatenatedItems() {
        let seq = DER.sequence([DER.integer(1), DER.integer(2)])
        XCTAssertEqual(seq, [0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x02])
    }

    func testExplicitContextTag() {
        // [0] EXPLICIT sobre INTEGER 2 (la versión v3 de un certificado): A0 03 02 01 02.
        XCTAssertEqual(DER.explicit(0, DER.integer(2)), [0xa0, 0x03, 0x02, 0x01, 0x02])
    }

    func testImplicitContextTag() {
        // [2] primitivo con bytes crudos (un dNSName): 82 03 61 62 63.
        XCTAssertEqual(DER.implicit(2, Array("abc".utf8)), [0x82, 0x03, 0x61, 0x62, 0x63])
    }

    // MARK: - Utilidades

    private static func utcDate(
        year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }
}
