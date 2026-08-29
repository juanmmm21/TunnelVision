import Foundation
import XCTest

/// Tests del escáner de ClientHello: el parser que le da nombre a un flujo TLS sin descifrar nada.
///
/// Lo que se afirma, por orden de importancia: que lee el SNI de un ClientHello bien formado, que
/// **lo lee igual venga como venga partido** (que es su razón de ser: un ClientHello moderno no cabe
/// en un segmento), que distingue los motivos por los que un flujo se queda sin nombre, y que ningún
/// byte malformado le hace leer fuera de sus vectores.
final class ClientHelloScannerTests: XCTestCase {

    private static let host = "www.example.com"

    // MARK: - El caso normal

    func testReadsSNIFromASingleChunk() {
        var scanner = ClientHelloScanner()
        XCTAssertEqual(scanner.scan(ClientHelloFixtures.clientHello(host: Self.host)), .found(Self.host))
    }

    func testReadsSNIWhenItIsNotTheFirstExtension() {
        // El fixture pone `supported_versions` delante del SNI, como los clientes reales.
        var scanner = ClientHelloScanner()
        XCTAssertEqual(scanner.scan(ClientHelloFixtures.clientHello(host: "api.example.org")), .found("api.example.org"))
    }

    func testReadsSNIWhenOtherExtensionsFollowIt() {
        var scanner = ClientHelloScanner()
        let hello = ClientHelloFixtures.clientHello(host: Self.host, extraExtensions: [.padding(64)])
        XCTAssertEqual(scanner.scan(hello), .found(Self.host))
    }

    // MARK: - Llegada a trozos (la razón de que sea incremental)

    /// El caso que motiva todo: un ClientHello de los de hoy no cabe en un segmento del túnel, así
    /// que llega partido. Se parte justo donde lo partiría la MTU.
    func testReadsSNIFromAHelloSplitAcrossTwoSegments() {
        let hello = ClientHelloFixtures.oversizedClientHello(host: Self.host)
        XCTAssertGreaterThan(hello.count, 1_460, "el fixture debe pasar de un segmento para que el test signifique algo")

        var scanner = ClientHelloScanner()
        let first = hello.prefix(1_460)
        let second = hello.dropFirst(1_460)

        XCTAssertEqual(scanner.scan(first), .needMoreBytes)
        XCTAssertEqual(scanner.scan(second), .found(Self.host))
    }

    /// La prueba dura de la incrementalidad: partido en **todos** los puntos posibles, el desenlace
    /// es el mismo y nunca se adelanta a tener los bytes.
    func testReadsSNIWhateverTheChunkBoundaries() {
        let hello = ClientHelloFixtures.clientHello(host: Self.host)
        for split in 1..<hello.count {
            var scanner = ClientHelloScanner()
            XCTAssertEqual(scanner.scan(hello.prefix(split)), .needMoreBytes, "corte en \(split)")
            XCTAssertEqual(scanner.scan(hello.dropFirst(split)), .found(Self.host), "corte en \(split)")
        }
    }

    func testReadsSNIByteByByte() {
        let hello = ClientHelloFixtures.clientHello(host: Self.host)
        var scanner = ClientHelloScanner()
        var outcomes: [ClientHelloScanner.Outcome] = []
        for byte in hello {
            outcomes.append(scanner.scan(Data([byte])))
        }
        XCTAssertEqual(outcomes.last, .found(Self.host))
        XCTAssertEqual(outcomes.dropLast().filter { $0 != .needMoreBytes }, [])
    }

    /// Fragmentación de handshake: el mismo mensaje repartido en varios records TLS.
    func testReadsSNIFromAHelloSplitAcrossRecords() {
        var scanner = ClientHelloScanner()
        let hello = ClientHelloFixtures.clientHelloInRecords(host: Self.host, chunk: 40)
        XCTAssertEqual(scanner.scan(hello), .found(Self.host))
    }

    // MARK: - Sin nombre, y por qué

    func testHelloWithoutServerNameExtension() {
        var scanner = ClientHelloScanner()
        let body = ClientHelloFixtures.clientHelloBody(extensions: [.supportedVersions])
        let hello = Data(ClientHelloFixtures.record(payload: ClientHelloFixtures.handshakeMessage(body: body)))
        XCTAssertEqual(scanner.scan(hello), .unavailable(.noServerName))
    }

    /// Un ClientHello TLS 1.0–1.2 puede no traer bloque de extensiones: es legal, no es basura.
    func testHelloWithoutExtensionsBlock() {
        var scanner = ClientHelloScanner()
        let body = ClientHelloFixtures.clientHelloBody(extensions: nil)
        let hello = Data(ClientHelloFixtures.record(payload: ClientHelloFixtures.handshakeMessage(body: body)))
        XCTAssertEqual(scanner.scan(hello), .unavailable(.noServerName))
    }

    func testHelloWithEmptyServerNameList() {
        var scanner = ClientHelloScanner()
        let body = ClientHelloFixtures.clientHelloBody(extensions: [.emptyServerNameList])
        let hello = Data(ClientHelloFixtures.record(payload: ClientHelloFixtures.handshakeMessage(body: body)))
        XCTAssertEqual(scanner.scan(hello), .unavailable(.noServerName))
    }

    /// La lista puede llevar entradas de un tipo que no conocemos: se saltan, no rompen.
    func testUnknownServerNameTypeIsSkipped() {
        var scanner = ClientHelloScanner()
        let body = ClientHelloFixtures.clientHelloBody(extensions: [.serverName(Self.host, nameType: 9)])
        let hello = Data(ClientHelloFixtures.record(payload: ClientHelloFixtures.handshakeMessage(body: body)))
        XCTAssertEqual(scanner.scan(hello), .unavailable(.noServerName))
    }

    // MARK: - No es un ClientHello

    func testPlainTextStreamIsNotTLS() {
        var scanner = ClientHelloScanner()
        XCTAssertEqual(scanner.scan(Data("GET / HTTP/1.1\r\n".utf8)), .unavailable(.notTLSHandshake))
    }

    /// Con un solo byte ya se sabe: no hay que esperar a la cabecera entera del record.
    func testNonHandshakeIsDecidedOnTheFirstByte() {
        var scanner = ClientHelloScanner()
        XCTAssertEqual(scanner.scan(Data([0x17])), .unavailable(.notTLSHandshake))
    }

    func testRecordWithUnknownVersionIsNotTLS() {
        var scanner = ClientHelloScanner()
        let hello = ClientHelloFixtures.record(version: [0x09, 0x01], payload: [0x01, 0x00, 0x00, 0x00])
        XCTAssertEqual(scanner.scan(Data(hello)), .unavailable(.notTLSHandshake))
    }

    func testHandshakeThatIsNotAClientHello() {
        var scanner = ClientHelloScanner()
        let message = ClientHelloFixtures.handshakeMessage(
            type: ClientHelloFixtures.serverHelloMessageType,
            body: ClientHelloFixtures.clientHelloBody(extensions: [.serverName(Self.host)])
        )
        XCTAssertEqual(scanner.scan(Data(ClientHelloFixtures.record(payload: message))), .unavailable(.notClientHello))
    }

    // MARK: - Bytes que mienten

    func testTruncatedBodyIsMalformed() {
        var scanner = ClientHelloScanner()
        // Un ClientHello que declara su longitud y se queda a mitad de la cabecera fija.
        let body: [UInt8] = [0x03, 0x03] + [UInt8](repeating: 0xAB, count: 10)
        let hello = ClientHelloFixtures.record(payload: ClientHelloFixtures.handshakeMessage(body: body))
        XCTAssertEqual(scanner.scan(Data(hello)), .unavailable(.malformed))
    }

    func testVectorLongerThanTheMessageIsMalformed() {
        var scanner = ClientHelloScanner()
        // Cabecera fija correcta, pero el vector de cipher_suites declara 200 bytes y no los hay.
        var body: [UInt8] = [0x03, 0x03]
        body += [UInt8](repeating: 0xAB, count: 32)
        body += [0]                                    // legacy_session_id vacío
        body += ClientHelloFixtures.uint16(200) + [0x13, 0x01]
        let hello = ClientHelloFixtures.record(payload: ClientHelloFixtures.handshakeMessage(body: body))
        XCTAssertEqual(scanner.scan(Data(hello)), .unavailable(.malformed))
    }

    func testHandshakeBeyondTheCeilingIsTooLarge() {
        var scanner = ClientHelloScanner(config: .init(maxHandshakeBytes: 256))
        XCTAssertEqual(scanner.scan(ClientHelloFixtures.oversizedClientHello(host: Self.host)), .unavailable(.tooLarge))
    }

    // MARK: - Nombres que no se pueden enseñar

    func testHostIsNormalisedToLowercase() {
        var scanner = ClientHelloScanner()
        XCTAssertEqual(scanner.scan(ClientHelloFixtures.clientHello(host: "WWW.Example.COM")), .found("www.example.com"))
    }

    func testHostWithTrailingDotIsRejected() {
        XCTAssertNil(ClientHelloScanner.hostName(from: bytes("example.com.")))
    }

    func testHostWithLeadingDotIsRejected() {
        XCTAssertNil(ClientHelloScanner.hostName(from: bytes(".example.com")))
    }

    func testEmptyHostIsRejected() {
        XCTAssertNil(ClientHelloScanner.hostName(from: bytes("")))
    }

    func testHostWithNonASCIIBytesIsRejected() {
        XCTAssertNil(ClientHelloScanner.hostName(from: [0x77, 0xC3, 0xA9, 0x2E][...]))
    }

    func testHostWithControlBytesIsRejected() {
        XCTAssertNil(ClientHelloScanner.hostName(from: [0x61, 0x00, 0x62][...]))
    }

    func testOverlongHostIsRejected() {
        let long = String(repeating: "a", count: 254)
        XCTAssertNil(ClientHelloScanner.hostName(from: bytes(long)))
    }

    func testHostAtTheLengthLimitIsAccepted() {
        let limit = String(repeating: "a", count: 253)
        XCTAssertEqual(ClientHelloScanner.hostName(from: bytes(limit)), limit)
    }

    /// Un nombre inutilizable deja al flujo sin nombre, no malformado: el ClientHello estaba bien,
    /// lo que no vale es lo que dice.
    func testUnusableNameLeavesTheFlowWithoutServerName() {
        var scanner = ClientHelloScanner()
        let body = ClientHelloFixtures.clientHelloBody(extensions: [.serverName(rawName: [0x61, 0x20, 0x62])])
        let hello = Data(ClientHelloFixtures.record(payload: ClientHelloFixtures.handshakeMessage(body: body)))
        XCTAssertEqual(scanner.scan(hello), .unavailable(.noServerName))
    }

    // MARK: - Se para cuando ya sabe

    func testOutcomeIsStickyOnceFound() {
        var scanner = ClientHelloScanner()
        XCTAssertEqual(scanner.scan(ClientHelloFixtures.clientHello(host: Self.host)), .found(Self.host))
        // Lo que sigue en un flujo TLS ya va cifrado: no puede cambiar la respuesta ni hacerla dudar.
        XCTAssertEqual(scanner.scan(Data([0x17, 0x03, 0x03, 0x00, 0x05, 1, 2, 3, 4, 5])), .found(Self.host))
        XCTAssertEqual(scanner.scan(ClientHelloFixtures.clientHello(host: "otro.example.net")), .found(Self.host))
    }

    func testOutcomeIsStickyOnceUnavailable() {
        var scanner = ClientHelloScanner()
        XCTAssertEqual(scanner.scan(Data("GET / HTTP/1.1\r\n".utf8)), .unavailable(.notTLSHandshake))
        XCTAssertEqual(scanner.scan(ClientHelloFixtures.clientHello(host: Self.host)), .unavailable(.notTLSHandshake))
    }

    private func bytes(_ string: String) -> ArraySlice<UInt8> {
        [UInt8](string.utf8)[...]
    }
}
