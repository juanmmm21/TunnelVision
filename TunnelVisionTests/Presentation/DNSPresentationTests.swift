import Foundation
import XCTest
import Shared

/// Tests de lo que la pantalla de un paquete dice de un mensaje de DNS (paso 10 del roadmap).
///
/// Lo que se afirma aquí **no es el parseo** —eso está en `DNSMessageParserTests`— sino las decisiones
/// que se toman encima: que una consulta no enseñe una respuesta que no tiene, que una respuesta con
/// alias y dirección enseñe la dirección, y que "no hay registros de ese tipo" y "no existe ese
/// nombre" no se digan igual.
final class DNSPresentationTests: XCTestCase {

    // MARK: - Utilidades

    private func address(_ text: String) throws -> IPAddress {
        try XCTUnwrap(IPAddress(parsing: text))
    }

    private func message(
        isResponse: Bool,
        question: String = "api.example.com",
        type: DNSRecordType = .a,
        answers: [DNSResourceRecord] = [],
        responseCode: DNSResponseCode = .noError
    ) -> DNSMessage {
        DNSMessage(
            id: 0x4a21,
            isResponse: isResponse,
            opcode: 0,
            isAuthoritative: false,
            isTruncated: false,
            recursionDesired: true,
            recursionAvailable: isResponse,
            responseCode: responseCode,
            questions: [DNSQuestion(name: question, type: type, recordClass: 1)],
            answers: answers
        )
    }

    private func record(_ data: DNSRecordData, type: DNSRecordType) -> DNSResourceRecord {
        DNSResourceRecord(
            name: "api.example.com", type: type, recordClass: 1, timeToLive: 300, data: data
        )
    }

    private func value(_ facts: [FlowFact], _ id: String) -> String? {
        guard case .text(let text)? = facts.first(where: { $0.id == id })?.value else { return nil }
        return text
    }

    private func captureRecord(bytes: Data, originalLength: UInt32) -> CaptureRecord {
        CaptureRecord(
            location: CaptureLocation(fileSequence: 1, recordOffset: 24),
            bytes: bytes,
            originalLength: originalLength,
            timestampMicroseconds: 1_000
        )
    }

    // MARK: - Qué se lee de una respuesta

    func testAQueryHasNoAnswerToRead() {
        // Una pregunta no tiene respuesta, igual que un segmento sin ACK no tiene acuse: enseñar un
        // hueco donde va la respuesta invitaría a leer un silencio del servidor que no ha habido.
        XCTAssertNil(DNSPresentation.reading(of: message(isResponse: false)))
    }

    func testTheAddressWinsOverTheAliasThatLedToIt() throws {
        let reading = DNSPresentation.reading(
            of: message(
                isResponse: true,
                answers: [
                    record(.name("cdn.example.net"), type: .cname),
                    record(.address(try address("203.0.113.10")), type: .a),
                ]
            )
        )

        // El alias es el camino y la dirección es el destino: es a lo que el dispositivo va a llamar.
        XCTAssertEqual(reading, .addresses([try address("203.0.113.10")]))
    }

    func testAnAnswerThatIsOnlyANameIsReadAsThatName() throws {
        let reading = DNSPresentation.reading(
            of: message(
                isResponse: true, question: "10.113.0.203.in-addr.arpa", type: .ptr,
                answers: [record(.name("api.example.com"), type: .ptr)]
            )
        )

        XCTAssertEqual(reading, .name("api.example.com"))
    }

    func testRecordsThatAreNotBrokenDownAreCountedAndNamed() {
        let reading = DNSPresentation.reading(
            of: message(
                isResponse: true, type: .txt,
                answers: [record(.opaque(byteCount: 40), type: .txt), record(.opaque(byteCount: 12), type: .txt)]
            )
        )

        XCTAssertEqual(reading, .records(.txt, count: 2))
    }

    func testAReplyWithNothingInItKeepsTheServersCode() {
        XCTAssertEqual(
            DNSPresentation.reading(of: message(isResponse: true, responseCode: .nonExistentDomain)),
            .nothing(.nonExistentDomain)
        )
        // Sin error **y** sin registros no es lo mismo: el nombre existe y no tiene registros de ese
        // tipo, que es un desenlace distinto de que no exista.
        XCTAssertEqual(
            DNSPresentation.reading(of: message(isResponse: true)),
            .nothing(.noError)
        )
    }

    // MARK: - Qué se enseña

    func testAQueryShowsWhatWasLookedUpAndNothingElse() {
        let facts = DNSPresentation.facts(for: message(isResponse: false))

        XCTAssertEqual(value(facts, "dnsKind"), "Question")
        XCTAssertEqual(value(facts, "dnsName"), "api.example.com")
        XCTAssertEqual(value(facts, "dnsRecordType"), "A")
        XCTAssertNil(value(facts, "dnsAnswer"))
    }

    func testAReplyShowsItsAddressesSeparatedByCommas() throws {
        let facts = DNSPresentation.facts(
            for: message(
                isResponse: true,
                answers: [
                    record(.address(try address("203.0.113.10")), type: .a),
                    record(.address(try address("203.0.113.11")), type: .a),
                ]
            )
        )

        XCTAssertEqual(value(facts, "dnsKind"), "Reply")
        XCTAssertEqual(value(facts, "dnsAnswer"), "203.0.113.10, 203.0.113.11")
    }

    func testTheTwoKindsOfEmptyReplyDoNotReadTheSame() {
        let noSuchName = DNSPresentation.facts(
            for: message(isResponse: true, responseCode: .nonExistentDomain)
        )
        let noRecords = DNSPresentation.facts(for: message(isResponse: true))

        XCTAssertEqual(value(noSuchName, "dnsAnswer"), "No such name")
        XCTAssertEqual(value(noRecords, "dnsAnswer"), "No records of that type")
    }

    func testAnErrorCodeWithoutANameIsSaidByItsNumber() {
        let facts = DNSPresentation.facts(
            for: message(isResponse: true, responseCode: DNSResponseCode(rawValue: 9))
        )

        // Inventarle una frase a un código que no se conoce sería afirmar algo que nadie ha leído.
        XCTAssertEqual(value(facts, "dnsAnswer"), "Answered with code 9")
    }

    func testTheCountOfUnbrokenRecordsUsesItsOwnPluralKey() {
        let one = DNSPresentation.facts(
            for: message(isResponse: true, type: .txt, answers: [record(.opaque(byteCount: 40), type: .txt)])
        )
        let two = DNSPresentation.facts(
            for: message(
                isResponse: true, type: .txt,
                answers: [record(.opaque(byteCount: 40), type: .txt), record(.opaque(byteCount: 4), type: .txt)]
            )
        )

        XCTAssertEqual(value(one, "dnsAnswer"), "1 TXT record")
        XCTAssertEqual(value(two, "dnsAnswer"), "2 TXT records")
    }

    func testTheGridNamesTheProtocolItIsShowing() {
        // Sin esta celda nada en la rejilla diría que estos campos son de DNS: *Looked up* solo no lo
        // dice, y la rejilla no tiene encabezado propio.
        let labels = DNSPresentation.facts(for: message(isResponse: false)).map(\.label)

        XCTAssertTrue(labels.contains("DNS message"))
    }

    // MARK: - El puerto

    func testOnlyPort53IsReadAsDNS() {
        func udp(source: UInt16, destination: UInt16) -> UDPHeader {
            UDPHeader(sourcePort: source, destinationPort: destination, length: 40, payloadRange: 28..<60)
        }

        XCTAssertTrue(DNSPresentation.carriesDNS(udp(source: 53_535, destination: 53)))
        XCTAssertTrue(DNSPresentation.carriesDNS(udp(source: 53, destination: 53_535)))
        // mDNS usa el mismo formato y es el siguiente candidato, pero un disector por incremento: el
        // roadmap lo dice con esas palabras.
        XCTAssertFalse(DNSPresentation.carriesDNS(udp(source: 5_353, destination: 5_353)))
        XCTAssertFalse(DNSPresentation.carriesDNS(udp(source: 53_535, destination: 443)))
    }

    // MARK: - Cuando no se puede leer

    func testTheTwoReasonsAMessageWentUnreadDoNotReadTheSame() {
        let truncated = DNSPresentation.unreadNote(
            for: captureRecord(bytes: Data(repeating: 0, count: 128), originalLength: 300)
        )
        let unreadable = DNSPresentation.unreadNote(
            for: captureRecord(bytes: Data(repeating: 0, count: 60), originalLength: 60)
        )

        // El primero lo arregla el usuario en Ajustes y el segundo no lo arregla nadie, así que no se
        // colapsan en un "no se pudo leer".
        XCTAssertTrue(truncated.contains("Settings"), truncated)
        XCTAssertTrue(unreadable.contains("port 53"), unreadable)
        XCTAssertNotEqual(truncated, unreadable)
    }
}
