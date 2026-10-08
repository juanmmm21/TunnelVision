import Foundation
import Shared
import XCTest

/// Tests del escáner del arranque de un stream. Lo que se afirma, por orden de importancia: que
/// **solo una línea de petición entera** se da por HTTP en claro —de ahí sale la única afirmación
/// de «sin cifrar» de la herramienta—, que un ClientHello se reconoce en cualquier puerto, que
/// todo lo demás queda sin reconocer, y que decide igual venga como venga partido el stream.
final class StreamOpeningScannerTests: XCTestCase {

    private func scan(_ bytes: [UInt8], config: StreamOpeningScanner.Config = .init()) -> StreamOpeningScanner.Outcome {
        var scanner = StreamOpeningScanner(config: config)
        return scanner.scan(Data(bytes))
    }

    private func scan(_ text: String) -> StreamOpeningScanner.Outcome {
        scan(Array(text.utf8))
    }

    /// Cabecera de record de handshake + primer byte del mensaje.
    private func tlsOpening(
        contentType: UInt8 = 22, major: UInt8 = 3, minor: UInt8 = 1, length: UInt16 = 512, message: UInt8 = 1
    ) -> [UInt8] {
        [contentType, major, minor, UInt8(length >> 8), UInt8(length & 0xff), message]
    }

    // MARK: - TLS

    func testAClientHelloRecordIsATLSHandshake() {
        for minor in UInt8(0)...4 {
            XCTAssertEqual(scan(tlsOpening(minor: minor)), .decided(.tlsHandshake))
        }
    }

    func testATLSHandshakeIsDecidedOnItsSixthByte() {
        let opening = tlsOpening()
        XCTAssertEqual(scan(Array(opening.prefix(5))), .needMoreBytes)
        XCTAssertEqual(scan(opening), .decided(.tlsHandshake))
    }

    func testARecordThatIsNotAClientHelloIsUnrecognised() {
        XCTAssertEqual(scan(tlsOpening(major: 2)), .decided(.unrecognised))
        XCTAssertEqual(scan(tlsOpening(minor: 5)), .decided(.unrecognised))
        XCTAssertEqual(scan(tlsOpening(message: 2)), .decided(.unrecognised))
        XCTAssertEqual(scan(tlsOpening(length: 3)), .decided(.unrecognised))
        XCTAssertEqual(scan(tlsOpening(length: 16385)), .decided(.unrecognised))
        // Datos de aplicación (23) o una alerta (21) no abren una conexión.
        XCTAssertEqual(scan(tlsOpening(contentType: 23)), .decided(.unrecognised))
        XCTAssertEqual(scan(tlsOpening(contentType: 21)), .decided(.unrecognised))
    }

    func testTheRecordLengthLimitsAreInclusive() {
        XCTAssertEqual(scan(tlsOpening(length: 4)), .decided(.tlsHandshake))
        XCTAssertEqual(scan(tlsOpening(length: 16384)), .decided(.tlsHandshake))
    }

    // MARK: - HTTP

    func testAFullRequestLineIsAnHTTPRequest() {
        XCTAssertEqual(scan("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"), .decided(.httpRequest))
        XCTAssertEqual(scan("POST /api/v1/login?x=1 HTTP/1.0\r\n"), .decided(.httpRequest))
        XCTAssertEqual(scan("OPTIONS * HTTP/1.1\r\n"), .decided(.httpRequest))
        XCTAssertEqual(scan("CONNECT example.com:443 HTTP/1.1\r\n"), .decided(.httpRequest))
        XCTAssertEqual(scan("GET http://example.com/a HTTP/1.1\r\n"), .decided(.httpRequest))
        // El prefacio de HTTP/2 sin TLS (RFC 9113 § 3.4) es también una línea de petición.
        XCTAssertEqual(scan("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"), .decided(.httpRequest))
    }

    func testABareLineFeedEndsTheRequestLine() {
        XCTAssertEqual(scan("GET / HTTP/1.1\n"), .decided(.httpRequest))
    }

    /// Empezar por `GET ` no basta: hasta el fin de línea no se afirma nada.
    func testARequestLineIsNotDecidedBeforeItsEnd() {
        XCTAssertEqual(scan("GET"), .needMoreBytes)
        XCTAssertEqual(scan("GET /index.html"), .needMoreBytes)
        XCTAssertEqual(scan("GET / HTTP/1.1"), .needMoreBytes)
        XCTAssertEqual(scan("GET / HTTP/1.1\r"), .needMoreBytes)
    }

    func testWhatOnlyLooksLikeARequestLineIsUnrecognised() {
        XCTAssertEqual(scan("GET / HTTP/1.1 \r\n"), .decided(.unrecognised))
        XCTAssertEqual(scan("GET / HTTP/11\r\n"), .decided(.unrecognised))
        XCTAssertEqual(scan("GET / HTTPS/1.1\r\n"), .decided(.unrecognised))
        XCTAssertEqual(scan("GET / http/1.1\r\n"), .decided(.unrecognised))
        XCTAssertEqual(scan("GET / HTTP/1.1\rX"), .decided(.unrecognised))
        XCTAssertEqual(scan("GET  / HTTP/1.1\r\n"), .decided(.unrecognised))
        XCTAssertEqual(scan("GET /\r\n"), .decided(.unrecognised))
        XCTAssertEqual(scan(" GET / HTTP/1.1\r\n"), .decided(.unrecognised))
        XCTAssertEqual(scan("GET /caf\u{e9} HTTP/1.1\r\n"), .decided(.unrecognised))
    }

    func testOtherProtocolsAreUnrecognised() {
        // Un protocolo de texto cuyo arranque no es una línea de petición.
        XCTAssertEqual(scan("EHLO mail.example.com\r\n"), .decided(.unrecognised))
        XCTAssertEqual(scan("SSH-2.0-OpenSSH_9.6\r\n"), .decided(.unrecognised))
        // Binario: el primer byte no es de un método ni de un record de handshake.
        XCTAssertEqual(scan([0x00, 0x01, 0x02]), .decided(.unrecognised))
        XCTAssertEqual(scan([0xFF]), .decided(.unrecognised))
    }

    func testNoBytesIsNoDecision() {
        XCTAssertEqual(scan([UInt8]()), .needMoreBytes)
    }

    func testARequestLineLongerThanTheCeilingIsUnrecognised() {
        let config = StreamOpeningScanner.Config(maxRequestLineBytes: 32)
        let fits = "GET /" + String(repeating: "a", count: 10) + " HTTP/1.1\r\n"
        XCTAssertEqual(fits.utf8.count, 26)
        XCTAssertEqual(scan(Array(fits.utf8), config: config), .decided(.httpRequest))

        let tooLong = "GET /" + String(repeating: "a", count: 40) + " HTTP/1.1\r\n"
        XCTAssertEqual(scan(Array(tooLong.utf8), config: config), .decided(.unrecognised))
        // Y se rinde al llegar al techo, sin esperar al resto.
        XCTAssertEqual(scan(Array(tooLong.utf8.prefix(32)), config: config), .decided(.unrecognised))
        XCTAssertEqual(scan(Array(tooLong.utf8.prefix(31)), config: config), .needMoreBytes)
    }

    // MARK: - Incremental

    func testTheDecisionDoesNotDependOnHowTheStreamIsSplit() {
        let streams: [([UInt8], StreamOpening)] = [
            (tlsOpening() + [0, 1, 2, 3], .tlsHandshake),
            (Array("GET /a/b?c=d HTTP/1.1\r\nHost: x\r\n".utf8), .httpRequest),
            (Array("HELO there\r\n".utf8), .unrecognised),
        ]
        for (bytes, expected) in streams {
            for chunk in 1...bytes.count {
                var scanner = StreamOpeningScanner()
                var outcome = StreamOpeningScanner.Outcome.needMoreBytes
                var offset = 0
                while offset < bytes.count {
                    outcome = scanner.scan(Data(bytes[offset..<min(offset + chunk, bytes.count)]))
                    offset += chunk
                }
                XCTAssertEqual(outcome, .decided(expected), "troceado de \(chunk) en \(bytes.count) bytes")
            }
        }
    }

    func testOnceDecidedItStaysDecided() {
        var scanner = StreamOpeningScanner()
        XCTAssertEqual(scanner.scan(Data("GET / HTTP/1.1\r\n".utf8)), .decided(.httpRequest))
        XCTAssertEqual(scanner.scan(Data(tlsOpening())), .decided(.httpRequest))
        XCTAssertEqual(scanner.scan(Data()), .decided(.httpRequest))
    }
}
