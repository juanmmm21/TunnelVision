import Foundation
import XCTest
import Shared

/// Tests del disector de DNS (paso 10 del roadmap): qué lee de un mensaje y, sobre todo, **qué hace
/// con uno hostil**.
///
/// La mitad interesante es la segunda. Un mensaje de DNS llega de la red, así que sus longitudes y
/// sus punteros de compresión son datos de un tercero: un puntero a sí mismo es un bucle infinito
/// escrito en dos bytes, y un byte de control dentro de un nombre es una línea de pantalla que se
/// reescribe sola. Los casos normales se escriben con `DNSMessageFixture`, que es código
/// independiente del parser; los hostiles van a mano, byte a byte, porque el fixture no sabe —ni debe
/// saber— escribir un mensaje ilegal.
final class DNSMessageParserTests: XCTestCase {

    // MARK: - Utilidades

    private func header(
        id: UInt16 = 0x1234,
        flags: UInt16 = 0x0100,
        questions: UInt16 = 1,
        answers: UInt16 = 0
    ) -> [UInt8] {
        var bytes: [UInt8] = []
        for value in [id, flags, questions, answers, 0, 0] {
            bytes.append(UInt8(truncatingIfNeeded: value >> 8))
            bytes.append(UInt8(truncatingIfNeeded: value))
        }
        return bytes
    }

    /// Una pregunta cualquiera ya codificada: `a.test` de tipo A y clase IN.
    private let encodedQuestion: [UInt8] = [
        1, UInt8(ascii: "a"),
        4, UInt8(ascii: "t"), UInt8(ascii: "e"), UInt8(ascii: "s"), UInt8(ascii: "t"),
        0,
        0, 1,   // type A
        0, 1,   // class IN
    ]

    private func address(_ text: String) throws -> IPAddress {
        try XCTUnwrap(IPAddress(parsing: text))
    }

    // MARK: - Lo que lee

    func testReadsAQuery() throws {
        let message = try DNSMessageParser.parse(
            DNSMessageFixture.query(id: 0x4a21, name: "api.example.com", type: .a)
        )

        XCTAssertEqual(message.id, 0x4a21)
        XCTAssertFalse(message.isResponse)
        XCTAssertEqual(message.opcode, 0, "una consulta estándar")
        XCTAssertTrue(message.recursionDesired)
        XCTAssertEqual(message.questions.count, 1)
        XCTAssertEqual(message.questions.first?.name, "api.example.com")
        XCTAssertEqual(message.questions.first?.type, .a)
        XCTAssertEqual(message.questions.first?.recordClass, 1)
        XCTAssertTrue(message.answers.isEmpty, "una consulta no contesta nada")
    }

    func testReadsAReplyWhoseNamesAreCompressed() throws {
        // El fixture comprime el nombre de cada respuesta con un puntero a la pregunta, que es lo que
        // hace todo resolutor de verdad: sin seguir el puntero, estos registros no tendrían nombre.
        let message = try DNSMessageParser.parse(
            DNSMessageFixture.reply(
                id: 0x4a21, name: "api.example.com", type: .a,
                answers: [.address(try address("203.0.113.10")), .address(try address("203.0.113.11"))]
            )
        )

        XCTAssertTrue(message.isResponse)
        XCTAssertTrue(message.recursionAvailable)
        XCTAssertEqual(message.responseCode, .noError)
        XCTAssertEqual(message.answers.map(\.name), ["api.example.com", "api.example.com"])
        XCTAssertEqual(
            message.answers.map(\.data),
            [.address(try address("203.0.113.10")), .address(try address("203.0.113.11"))]
        )
        XCTAssertEqual(message.answers.first?.timeToLive, 300)
    }

    func testReadsAnIPv6Answer() throws {
        let message = try DNSMessageParser.parse(
            DNSMessageFixture.reply(
                id: 1, name: "v6.example.com", type: .aaaa,
                answers: [.address(try address("2001:db8::7"))]
            )
        )

        XCTAssertEqual(message.answers.first?.type, .aaaa)
        XCTAssertEqual(message.answers.first?.data, .address(try address("2001:db8::7")))
    }

    func testReadsANameInsideARecord() throws {
        let message = try DNSMessageParser.parse(
            DNSMessageFixture.reply(
                id: 2, name: "10.113.0.203.in-addr.arpa", type: .ptr,
                answers: [.name("api.example.com", type: .ptr)]
            )
        )

        XCTAssertEqual(message.answers.first?.data, .name("api.example.com"))
    }

    func testAnEmptyReplyKeepsTheServersCode() throws {
        let message = try DNSMessageParser.parse(
            DNSMessageFixture.reply(
                id: 3, name: "missing.example.com", type: .a,
                answers: [], responseCode: .nonExistentDomain
            )
        )

        XCTAssertTrue(message.answers.isEmpty)
        XCTAssertEqual(message.responseCode, .nonExistentDomain)
    }

    // MARK: - Lo que no sabe desmenuzar, que no es un fallo

    func testARecordTypeItDoesNotBreakDownKeepsItsSize() throws {
        let message = try DNSMessageParser.parse(
            DNSMessageFixture.reply(
                id: 4, name: "example.com", type: .txt,
                answers: [.opaque(type: .txt, byteCount: 40)]
            )
        )

        XCTAssertEqual(message.answers.first?.data, .opaque(byteCount: 40))
        XCTAssertEqual(message.answers.first?.type, .txt)
    }

    func testAnUnknownRecordTypeIsNamedByItsNumber() throws {
        let message = try DNSMessageParser.parse(
            DNSMessageFixture.reply(
                id: 5, name: "example.com", type: DNSRecordType(rawValue: 64),
                answers: [.opaque(type: DNSRecordType(rawValue: 64), byteCount: 6)]
            )
        )

        // RFC 3597 § 5: así los nombra el propio DNS, y por eso el tipo guarda el número en vez de
        // colapsarlo en un caso "otro".
        XCTAssertEqual(message.answers.first?.type.displayName, "TYPE64")
    }

    func testAnAddressRecordWithTheWrongLengthIsNotAnAddress() throws {
        // Un A que no mide cuatro bytes no es una dirección por mucho que lo diga su tipo: inventarle
        // una sería enseñar un dato que nadie mandó.
        var bytes = header(flags: 0x8180, answers: 1)
        bytes += encodedQuestion
        bytes += [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 3, 1, 2, 3]

        let message = try DNSMessageParser.parse(Data(bytes))

        XCTAssertEqual(message.answers.first?.type, .a)
        XCTAssertEqual(message.answers.first?.data, .opaque(byteCount: 3))
    }

    // MARK: - Nombres hostiles

    func testAPointerThatPointsAtItselfIsRefused() throws {
        // El bucle infinito escrito en dos bytes. La regla que lo hace imposible no es un contador:
        // un puntero solo puede ir hacia atrás, y éste no va a ninguna parte.
        var bytes = header()
        bytes += [0xc0, 0x0c]

        XCTAssertThrowsError(try DNSMessageParser.parse(Data(bytes))) { error in
            XCTAssertEqual(error as? DNSParseError, .malformedName)
        }
    }

    func testAPointerThatPointsForwardIsRefused() throws {
        var bytes = header()
        bytes += [0xc0, 0x20]   // hacia adelante, fuera de lo ya leído

        XCTAssertThrowsError(try DNSMessageParser.parse(Data(bytes))) { error in
            XCTAssertEqual(error as? DNSParseError, .malformedName)
        }
    }

    func testTheReservedLabelBitsAreRefused() throws {
        var bytes = header()
        bytes += [0x40, 0x00]   // 0x40 y 0x80 llevan reservados desde 1987

        XCTAssertThrowsError(try DNSMessageParser.parse(Data(bytes))) { error in
            XCTAssertEqual(error as? DNSParseError, .malformedName)
        }
    }

    func testANameLongerThanTheFormatAllowsIsRefused() throws {
        var bytes = header()
        // Cinco etiquetas de 63 bytes: 320 con sus longitudes, contra los 255 del formato.
        for _ in 0..<5 {
            bytes.append(63)
            bytes += [UInt8](repeating: UInt8(ascii: "a"), count: 63)
        }
        bytes.append(0)

        XCTAssertThrowsError(try DNSMessageParser.parse(Data(bytes))) { error in
            XCTAssertEqual(error as? DNSParseError, .malformedName)
        }
    }

    func testBytesThatAreNotPrintableAreEscapedAndNotDrawn() throws {
        // Un nombre viene de un tercero. Sin escapar, un byte de control se dibuja en la pantalla del
        // paquete y puede reescribir la línea en la que sale; el punto y la barra se confundirían con
        // el separador de etiquetas y con el propio escape.
        var bytes = header()
        bytes += [4, UInt8(ascii: "a"), 0x00, UInt8(ascii: "."), UInt8(ascii: "\\")]
        bytes += [2, UInt8(ascii: "t"), UInt8(ascii: "v"), 0]
        bytes += [0, 1, 0, 1]

        let message = try DNSMessageParser.parse(Data(bytes))

        XCTAssertEqual(message.questions.first?.name, #"a\000\046\092.tv"#)
    }

    func testTheRootNameIsSaidWithItsDot() throws {
        var bytes = header()
        bytes += [0, 0, 2, 0, 1]   // nombre vacío, tipo NS, clase IN

        let message = try DNSMessageParser.parse(Data(bytes))

        // Un hueco donde va un nombre se leería como un dato que falta, y la raíz no falta.
        XCTAssertEqual(message.questions.first?.name, ".")
    }

    // MARK: - Mensajes cortados

    func testAMessageWithoutEvenAHeaderIsTooShort() throws {
        XCTAssertThrowsError(try DNSMessageParser.parse(Data([0x12, 0x34]))) { error in
            XCTAssertEqual(error as? DNSParseError, .tooShort(expected: 12, got: 2))
        }
    }

    func testANameThatRunsOffTheEndIsTruncated() throws {
        var bytes = header()
        bytes += [8, UInt8(ascii: "a"), UInt8(ascii: "b")]   // dice ocho y trae dos

        XCTAssertThrowsError(try DNSMessageParser.parse(Data(bytes))) { error in
            XCTAssertEqual(error as? DNSParseError, .truncated)
        }
    }

    func testARecordWhoseDataRunsOffTheEndIsTruncated() throws {
        var bytes = header(flags: 0x8180, answers: 1)
        bytes += encodedQuestion
        bytes += [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 203, 0]   // dice cuatro y trae dos

        XCTAssertThrowsError(try DNSMessageParser.parse(Data(bytes))) { error in
            XCTAssertEqual(error as? DNSParseError, .truncated)
        }
    }

    func testAHeaderThatPromisesMoreRecordsThanItCarriesIsTruncated() throws {
        // Es lo que produce el `snaplen` al recortar una respuesta larga: la cabecera sigue diciendo
        // cuántas respuestas venían y ya no están.
        var bytes = header(flags: 0x8180, answers: 3)
        bytes += encodedQuestion
        bytes += [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 203, 0, 113, 10]

        XCTAssertThrowsError(try DNSMessageParser.parse(Data(bytes))) { error in
            XCTAssertEqual(error as? DNSParseError, .truncated)
        }
    }

    func testAMessageReadFromASliceReadsTheSameAsFromItsOwnBytes() throws {
        // El payload llega como slice de los bytes del datagrama, y los punteros de compresión son
        // offsets desde el principio **del mensaje**: si el parser indexara con el `startIndex` del
        // slice, seguiría el puntero al sitio equivocado.
        let whole = DNSMessageFixture.reply(
            id: 6, name: "api.example.com", type: .a,
            answers: [.address(try address("203.0.113.10"))]
        )
        let padded = Data([0xff, 0xff, 0xff]) + whole
        let slice = padded.dropFirst(3)

        XCTAssertEqual(try DNSMessageParser.parse(slice), try DNSMessageParser.parse(whole))
    }
}
