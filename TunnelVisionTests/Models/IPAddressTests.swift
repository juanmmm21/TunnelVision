import XCTest
@testable import Shared

final class IPAddressTests: XCTestCase {
    func testIPv4Description() {
        XCTAssertEqual(ModelFixtures.v4(192, 168, 1, 1).description, "192.168.1.1")
        XCTAssertEqual(ModelFixtures.v4(0, 0, 0, 0).description, "0.0.0.0")
        XCTAssertEqual(ModelFixtures.v4(255, 255, 255, 255).description, "255.255.255.255")
        XCTAssertEqual(ModelFixtures.v4(8, 8, 8, 8).description, "8.8.8.8")
    }

    func testIPv6DescriptionUncompressed() {
        let addr = ModelFixtures.v6(0x2001, 0x0db8, 0x0001, 0x0002, 0x0003, 0x0004, 0x0005, 0x0006)
        XCTAssertEqual(addr.description, "2001:db8:1:2:3:4:5:6")
    }

    func testIPv6DescriptionCompressesLongestZeroRun() {
        XCTAssertEqual(
            ModelFixtures.v6(0x2001, 0x0db8, 0, 0, 0, 0, 0, 0x0001).description,
            "2001:db8::1"
        )
    }

    func testIPv6DescriptionLoopback() {
        XCTAssertEqual(ModelFixtures.v6(0, 0, 0, 0, 0, 0, 0, 1).description, "::1")
    }

    func testIPv6DescriptionUnspecifiedAllZeros() {
        XCTAssertEqual(ModelFixtures.v6(0, 0, 0, 0, 0, 0, 0, 0).description, "::")
    }

    func testIPv6DescriptionTrailingZeroRun() {
        XCTAssertEqual(
            ModelFixtures.v6(0x2001, 0x0db8, 0, 0, 0, 0, 0, 0).description,
            "2001:db8::"
        )
    }

    func testIPv6DescriptionLeadingZeroRun() {
        // Run inicial (grupos 0-2 en cero) → prefijo "::".
        XCTAssertEqual(
            ModelFixtures.v6(0, 0, 0, 0x0001, 0x0002, 0x0003, 0x0004, 0x0005).description,
            "::1:2:3:4:5"
        )
    }

    func testIPv6DescriptionSingleZeroGroupNotCompressed() {
        // RFC 5952: un único grupo a cero NO se comprime.
        XCTAssertEqual(
            ModelFixtures.v6(0x2001, 0x0db8, 0, 0x0001, 0x0001, 0x0001, 0x0001, 0x0001).description,
            "2001:db8:0:1:1:1:1:1"
        )
    }

    func testIPv6DescriptionLeftmostLongestRunWins() {
        // Dos runs de ceros: gana el más largo (grupos 4-6, longitud 3), no el primero (longitud 2).
        XCTAssertEqual(
            ModelFixtures.v6(0x2001, 0, 0, 0x0001, 0, 0, 0, 0x0001).description,
            "2001:0:0:1::1"
        )
    }

    func testOrderingByVersionThenBytes() {
        XCTAssertTrue(ModelFixtures.v4(1, 0, 0, 0) < ModelFixtures.v4(2, 0, 0, 0))
        XCTAssertTrue(ModelFixtures.v4(1, 2, 3, 4) < ModelFixtures.v4(1, 2, 3, 5))
        // v4 (rawValue 4) precede a v6 (rawValue 6).
        XCTAssertTrue(ModelFixtures.v4(255, 255, 255, 255) < ModelFixtures.v6(0, 0, 0, 0, 0, 0, 0, 0))
        XCTAssertFalse(ModelFixtures.v4(1, 2, 3, 4) < ModelFixtures.v4(1, 2, 3, 4))
    }

    func testEqualityAndHashing() {
        let a = ModelFixtures.v4(10, 0, 0, 1)
        let b = ModelFixtures.v4(10, 0, 0, 1)
        let c = ModelFixtures.v4(10, 0, 0, 2)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - Desde su forma de presentación

    func testParsingReadsBothFamilies() {
        XCTAssertEqual(IPAddress(parsing: "192.0.2.21"), ModelFixtures.v4(192, 0, 2, 21))
        XCTAssertEqual(
            IPAddress(parsing: "2001:db8::1"),
            ModelFixtures.v6(0x2001, 0x0db8, 0, 0, 0, 0, 0, 1)
        )
    }

    /// Parsear y volver a formatear devuelve la forma canónica, no el texto de entrada: es lo que
    /// hace que dos escrituras de la misma dirección se reconozcan como una sola.
    func testParsingCanonicalisesTheText() {
        XCTAssertEqual(IPAddress(parsing: "2001:0db8:0000:0000:0000:0000:0000:0001")?.description, "2001:db8::1")
        XCTAssertEqual(IPAddress(parsing: "2001:DB8::1"), IPAddress(parsing: "2001:db8::1"))
    }

    func testParsingRejectsWhatIsNotAnAddress() {
        XCTAssertNil(IPAddress(parsing: ""))
        XCTAssertNil(IPAddress(parsing: "dns.example.com"))
        XCTAssertNil(IPAddress(parsing: "1.1.1"))
        XCTAssertNil(IPAddress(parsing: "999.1.1.1"))
        XCTAssertNil(IPAddress(parsing: "2001:db8::/32"))
    }

    /// La zona se rechaza en vez de recortarse, y el filtro es **nuestro**: `inet_pton` no rechaza
    /// `fe80::1%en0` en Darwin — devuelve `fe80:e::1`, una dirección distinta y silenciosamente
    /// equivocada. Este test existe por eso: se escribió creyendo lo contrario y falló.
    func testParsingRejectsAScopedAddressInsteadOfSilentlyMisreadingIt() {
        XCTAssertNil(IPAddress(parsing: "fe80::1%en0"))
        XCTAssertNil(IPAddress(parsing: "192.0.2.1%en0"))
    }
}
