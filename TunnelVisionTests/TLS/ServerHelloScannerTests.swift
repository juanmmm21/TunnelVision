import Foundation
import Shared
import XCTest

/// Tests del escáner de ServerHello: el parser que dice con qué versión de TLS y con qué suite
/// contestó un servidor, sin descifrar nada.
///
/// Lo que se afirma, por orden de importancia: que lee la versión **de donde toca** (la extensión
/// `supported_versions` si está, `legacy_version` si no — equivocarse ahí es informar TLS 1.2 de una
/// conexión 1.3), que lo lee igual venga como venga partido, que distingue los motivos por los que
/// no hay lectura, y que ningún byte malformado le hace leer fuera de sus vectores.
final class ServerHelloScannerTests: XCTestCase {

    private static func found(
        _ version: TLSProtocolVersion,
        _ cipherSuite: UInt16,
        fromHelloRetryRequest: Bool = false
    ) -> ServerHelloScanner.Outcome {
        .found(NegotiatedTLS(
            version: version,
            cipherSuite: TLSCipherSuite(rawValue: cipherSuite),
            fromHelloRetryRequest: fromHelloRetryRequest,
            source: .serverHello
        ))
    }

    // MARK: - De dónde sale la versión

    func testTLS13IsReadFromSupportedVersionsNotFromLegacyVersion() {
        var scanner = ServerHelloScanner()
        XCTAssertEqual(scanner.scan(ServerHelloFixtures.tls13()), Self.found(.tls13, 0x1301))
    }

    func testTLS12IsReadFromLegacyVersionWhenTheExtensionIsAbsent() {
        var scanner = ServerHelloScanner()
        XCTAssertEqual(scanner.scan(ServerHelloFixtures.tls12()), Self.found(.tls12, 0xC02F))
    }

    func testHelloWithoutExtensionsBlockUsesLegacyVersion() {
        var scanner = ServerHelloScanner()
        let hello = ServerHelloFixtures.record(body: ServerHelloFixtures.serverHelloBody(
            legacyVersion: 0x0301, cipherSuite: 0x002F, extensions: nil
        ))
        XCTAssertEqual(scanner.scan(hello), Self.found(.tls10, 0x002F))
    }

    func testHelloWithAnEmptyExtensionsBlockUsesLegacyVersion() {
        var scanner = ServerHelloScanner()
        let hello = ServerHelloFixtures.record(body: ServerHelloFixtures.serverHelloBody(
            legacyVersion: 0x0302, cipherSuite: 0x0035, extensions: []
        ))
        XCTAssertEqual(scanner.scan(hello), Self.found(.tls11, 0x0035))
    }

    func testSupportedVersionsIsFoundWhenOtherExtensionsFollowIt() {
        var scanner = ServerHelloScanner()
        let hello = ServerHelloFixtures.record(body: ServerHelloFixtures.serverHelloBody(
            cipherSuite: 0x1302,
            extensions: [ServerHelloFixtures.selectedVersion(0x0304), ServerHelloFixtures.keyShare]
        ))
        XCTAssertEqual(scanner.scan(hello), Self.found(.tls13, 0x1302))
    }

    /// Un valor que no es ninguna versión publicada (un borrador de TLS 1.3) se conserva tal cual:
    /// es lo que el servidor dijo, y colapsarlo sería perder la evidencia.
    func testAnUnpublishedVersionKeepsItsRawValue() {
        var scanner = ServerHelloScanner()
        let hello = ServerHelloFixtures.record(body: ServerHelloFixtures.serverHelloBody(
            cipherSuite: 0x1301, extensions: [ServerHelloFixtures.selectedVersion(0x7F1C)]
        ))
        XCTAssertEqual(scanner.scan(hello), Self.found(TLSProtocolVersion(rawValue: 0x7F1C), 0x1301))
    }

    func testAnEmptySessionIDEchoIsLegal() {
        var scanner = ServerHelloScanner()
        let hello = ServerHelloFixtures.record(body: ServerHelloFixtures.serverHelloBody(
            sessionID: [], cipherSuite: 0xC030, extensions: nil
        ))
        XCTAssertEqual(scanner.scan(hello), Self.found(.tls12, 0xC030))
    }

    func testTheNamedVersionsCarryTheirWireValues() {
        XCTAssertEqual(TLSProtocolVersion.ssl30.rawValue, 0x0300)
        XCTAssertEqual(TLSProtocolVersion.tls10.rawValue, 0x0301)
        XCTAssertEqual(TLSProtocolVersion.tls11.rawValue, 0x0302)
        XCTAssertEqual(TLSProtocolVersion.tls12.rawValue, 0x0303)
        XCTAssertEqual(TLSProtocolVersion.tls13.rawValue, 0x0304)
    }

    // MARK: - HelloRetryRequest

    func testAHelloRetryRequestIsReadAndMarkedAsSuch() {
        var scanner = ServerHelloScanner()
        let retry = ServerHelloFixtures.tls13(cipherSuite: 0x1303, random: ServerHelloFixtures.helloRetryRequestRandom)
        XCTAssertEqual(scanner.scan(retry), Self.found(.tls13, 0x1303, fromHelloRetryRequest: true))
    }

    /// Un `random` que se parece al del HelloRetryRequest en todo menos en el último byte es un
    /// ServerHello corriente.
    func testARandomOneByteAwayFromTheRetryValueIsAnOrdinaryHello() {
        var random = ServerHelloFixtures.helloRetryRequestRandom
        random[31] ^= 0x01
        var scanner = ServerHelloScanner()
        XCTAssertEqual(scanner.scan(ServerHelloFixtures.tls13(random: random)), Self.found(.tls13, 0x1301))
    }

    // MARK: - Llegada a trozos

    func testReadsWhateverTheChunkBoundaries() {
        let hello = ServerHelloFixtures.tls13()
        for split in 1..<hello.count {
            var scanner = ServerHelloScanner()
            XCTAssertEqual(scanner.scan(hello.prefix(split)), .needMoreBytes, "corte en \(split)")
            XCTAssertEqual(scanner.scan(hello.dropFirst(split)), Self.found(.tls13, 0x1301), "corte en \(split)")
        }
    }

    func testReadsByteByByte() {
        let hello = ServerHelloFixtures.tls12()
        var scanner = ServerHelloScanner()
        var outcomes: [ServerHelloScanner.Outcome] = []
        for byte in hello {
            outcomes.append(scanner.scan(Data([byte])))
        }
        XCTAssertEqual(outcomes.last, Self.found(.tls12, 0xC02F))
        XCTAssertEqual(outcomes.dropLast().filter { $0 != .needMoreBytes }, [])
    }

    func testReadsAHelloSplitAcrossRecords() {
        let message = ServerHelloFixtures.message(body: ServerHelloFixtures.serverHelloBody(
            cipherSuite: 0x1301, extensions: [ServerHelloFixtures.selectedVersion(0x0304)]
        ))
        var bytes: [UInt8] = []
        var index = 0
        while index < message.count {
            let end = min(index + 20, message.count)
            bytes += ClientHelloFixtures.record(payload: Array(message[index..<end]))
            index = end
        }
        var scanner = ServerHelloScanner()
        XCTAssertEqual(scanner.scan(Data(bytes)), Self.found(.tls13, 0x1301))
    }

    /// El caso que motiva que sea incremental: en TLS 1.2 el certificado va detrás del ServerHello
    /// **en el mismo record**, y ese record no cabe en un segmento.
    func testAHelloSharingItsRecordWithTheCertificateWaitsForTheWholeRecord() {
        let hello = ServerHelloFixtures.message(body: ServerHelloFixtures.serverHelloBody(
            cipherSuite: 0xC02B, extensions: [ServerHelloFixtures.renegotiationInfo]
        ))
        let record = Data(ClientHelloFixtures.record(
            version: [0x03, 0x03], payload: hello + ServerHelloFixtures.certificateMessage(size: 3_000)
        ))
        XCTAssertGreaterThan(record.count, 1_460, "el fixture debe pasar de un segmento para que el test signifique algo")

        var scanner = ServerHelloScanner()
        XCTAssertEqual(scanner.scan(record.prefix(1_460)), .needMoreBytes)
        XCTAssertEqual(scanner.scan(record.dropFirst(1_460)), Self.found(.tls12, 0xC02B))
    }

    // MARK: - Sin lectura, y por qué

    func testAnAlertInsteadOfAHelloIsReportedWithItsDescription() {
        var scanner = ServerHelloScanner()
        XCTAssertEqual(
            scanner.scan(ServerHelloFixtures.alert(description: 70)),
            .unavailable(.alert(description: 70))
        )
    }

    func testAnAlertWaitsForItsTwoBytes() {
        let alert = ServerHelloFixtures.alert(description: 40)
        var scanner = ServerHelloScanner()
        XCTAssertEqual(scanner.scan(alert.prefix(6)), .needMoreBytes)
        XCTAssertEqual(scanner.scan(alert.dropFirst(6)), .unavailable(.alert(description: 40)))
    }

    func testAnAlertOfTheWrongSizeIsMalformed() {
        let alert = Data(ClientHelloFixtures.record(type: ServerHelloFixtures.alertContentType, payload: [2, 40, 0]))
        var scanner = ServerHelloScanner()
        XCTAssertEqual(scanner.scan(alert), .unavailable(.malformed))
    }

    /// Una alerta que corta un ServerHello a medio llegar: lo acumulado ya no se va a completar.
    func testAnAlertAfterAPartialHelloIsTheOutcome() {
        let message = ServerHelloFixtures.message(body: ServerHelloFixtures.serverHelloBody(
            cipherSuite: 0x1301, extensions: nil
        ))
        var bytes = ClientHelloFixtures.record(payload: Array(message.prefix(10)))
        bytes += [UInt8](ServerHelloFixtures.alert(description: 80))
        var scanner = ServerHelloScanner()
        XCTAssertEqual(scanner.scan(Data(bytes)), .unavailable(.alert(description: 80)))
    }

    func testPlainTextStreamIsNotTLS() {
        var scanner = ServerHelloScanner()
        XCTAssertEqual(scanner.scan(Data("HTTP/1.1 400 Bad Request\r\n".utf8)), .unavailable(.notTLSHandshake))
    }

    func testNonHandshakeIsDecidedOnTheFirstByte() {
        var scanner = ServerHelloScanner()
        XCTAssertEqual(scanner.scan(Data([23])), .unavailable(.notTLSHandshake))
    }

    func testRecordWithUnknownVersionIsNotTLS() {
        var scanner = ServerHelloScanner()
        XCTAssertEqual(scanner.scan(Data([22, 0x02])), .unavailable(.notTLSHandshake))
    }

    func testHandshakeThatIsNotAServerHello() {
        var scanner = ServerHelloScanner()
        XCTAssertEqual(
            scanner.scan(ClientHelloFixtures.clientHello(host: "www.example.com")),
            .unavailable(.notServerHello)
        )
    }

    // MARK: - Malformaciones

    func testTruncatedBodyIsMalformed() {
        // Un cuerpo que se acaba dentro del `random`.
        var scanner = ServerHelloScanner()
        let hello = ServerHelloFixtures.record(body: [0x03, 0x03] + [UInt8](repeating: 0xAB, count: 20))
        XCTAssertEqual(scanner.scan(hello), .unavailable(.malformed))
    }

    func testBodyEndingBeforeTheCompressionMethodIsMalformed() {
        var body = ServerHelloFixtures.serverHelloBody(cipherSuite: 0x1301, extensions: nil)
        body.removeLast()
        var scanner = ServerHelloScanner()
        XCTAssertEqual(scanner.scan(ServerHelloFixtures.record(body: body)), .unavailable(.malformed))
    }

    func testSessionIDLongerThanTheMessageIsMalformed() {
        var body: [UInt8] = [0x03, 0x03] + ServerHelloFixtures.ordinaryRandom
        body += [200, 0x01, 0x02]
        var scanner = ServerHelloScanner()
        XCTAssertEqual(scanner.scan(ServerHelloFixtures.record(body: body)), .unavailable(.malformed))
    }

    func testExtensionsBlockLongerThanTheMessageIsMalformed() {
        var body = ServerHelloFixtures.serverHelloBody(cipherSuite: 0x1301, extensions: nil)
        body += [0x00, 0x40, 0x00, 0x2B]
        var scanner = ServerHelloScanner()
        XCTAssertEqual(scanner.scan(ServerHelloFixtures.record(body: body)), .unavailable(.malformed))
    }

    func testExtensionLongerThanItsBlockIsMalformed() {
        var body = ServerHelloFixtures.serverHelloBody(cipherSuite: 0x1301, extensions: nil)
        body += [0x00, 0x06, 0x00, 0x33, 0x00, 0x10, 0xAA, 0xBB]
        var scanner = ServerHelloScanner()
        XCTAssertEqual(scanner.scan(ServerHelloFixtures.record(body: body)), .unavailable(.malformed))
    }

    func testSupportedVersionsWithHalfAVersionIsMalformed() {
        var scanner = ServerHelloScanner()
        let hello = ServerHelloFixtures.record(body: ServerHelloFixtures.serverHelloBody(
            cipherSuite: 0x1301, extensions: [.init(type: 43, payload: [0x03])]
        ))
        XCTAssertEqual(scanner.scan(hello), .unavailable(.malformed))
    }

    /// La forma de lista es la del ClientHello. En un ServerHello es una sola versión, y aceptar
    /// una lista sería elegir nosotros lo que el servidor no eligió.
    func testSupportedVersionsShapedAsAListIsMalformed() {
        var scanner = ServerHelloScanner()
        let hello = ServerHelloFixtures.record(body: ServerHelloFixtures.serverHelloBody(
            cipherSuite: 0x1301, extensions: [ClientHelloFixtures.Extension.supportedVersions]
        ))
        XCTAssertEqual(scanner.scan(hello), .unavailable(.malformed))
    }

    // MARK: - El techo

    /// Con solo la cabecera del record ya se sabe: no se espera a que lleguen los bytes que declara.
    func testARecordDeclaringMoreThanTheCeilingIsTooLargeFromItsHeader() {
        var scanner = ServerHelloScanner()
        XCTAssertEqual(scanner.scan(Data([22, 0x03, 0x03, 0xFF, 0xFF])), .unavailable(.tooLarge))
    }

    func testAMessageDeclaringMoreThanTheCeilingIsTooLarge() {
        var scanner = ServerHelloScanner(config: .init(maxHandshakeBytes: 64))
        let header: [UInt8] = [2, 0x00, 0x01, 0x00]
        XCTAssertEqual(
            scanner.scan(Data(ClientHelloFixtures.record(payload: header))),
            .unavailable(.tooLarge)
        )
    }

    /// Records que caben uno a uno pero cuyo acumulado pasa del techo: lo que se limita es lo que
    /// se guarda, no lo que cada record dice de sí mismo.
    func testRecordsAddingUpBeyondTheCeilingAreTooLarge() {
        var scanner = ServerHelloScanner(config: .init(maxHandshakeBytes: 64))
        let chunk = [UInt8](repeating: 0, count: 40)
        // Un mensaje que dice medir 60 (cabe en el techo) y cuya primera entrega no lo completa.
        let opening = ClientHelloFixtures.record(payload: [2, 0x00, 0x00, 0x3C] + chunk)
        XCTAssertEqual(scanner.scan(Data(opening)), .needMoreBytes)
        XCTAssertEqual(scanner.scan(Data(ClientHelloFixtures.record(payload: chunk))), .unavailable(.tooLarge))
    }

    // MARK: - Desenlaces definitivos

    func testOutcomeIsStickyOnceFound() {
        var scanner = ServerHelloScanner()
        XCTAssertEqual(scanner.scan(ServerHelloFixtures.tls13()), Self.found(.tls13, 0x1301))
        XCTAssertEqual(scanner.scan(ServerHelloFixtures.tls12()), Self.found(.tls13, 0x1301))
        XCTAssertEqual(scanner.scan(Data("cualquier cosa".utf8)), Self.found(.tls13, 0x1301))
    }

    func testOutcomeIsStickyOnceUnavailable() {
        var scanner = ServerHelloScanner()
        XCTAssertEqual(scanner.scan(Data("GET".utf8)), .unavailable(.notTLSHandshake))
        XCTAssertEqual(scanner.scan(ServerHelloFixtures.tls13()), .unavailable(.notTLSHandshake))
    }
}
