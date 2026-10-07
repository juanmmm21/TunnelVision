import Foundation
import XCTest
import Shared

/// Tests de la **oferta** que el escáner de ClientHello lee junto al nombre: las versiones de TLS
/// que el cliente acepta y sus protocolos de aplicación.
///
/// Lo que se afirma, por orden de importancia: que las versiones salen de donde de verdad están y
/// con el significado que tienen ahí (una lista exacta no es un techo), que lo que no es una
/// versión ni un protocolo —los GREASE— no se guarda como si lo fuera, que una oferta que no se
/// deja leer se queda en nada en vez de en media oferta, y que **nada de esto le cuesta el nombre**
/// a un flujo que lo tenía.
final class ClientHelloOfferTests: XCTestCase {

    private typealias Extension = ClientHelloFixtures.Extension

    private static let host = "www.example.com"

    /// Alimenta un escáner nuevo con el ClientHello entero y devuelve el desenlace y la oferta.
    private func read(_ hello: Data) -> (outcome: ClientHelloScanner.Outcome, offer: ClientTLSOffer?) {
        var scanner = ClientHelloScanner()
        let outcome = scanner.scan(hello)
        return (outcome, scanner.offer)
    }

    private func bytes(_ string: String) -> ArraySlice<UInt8> {
        ArraySlice([UInt8](string.utf8))
    }

    // MARK: - Las versiones

    func testListedVersionsKeepTheClientsOrder() {
        let hello = ClientHelloFixtures.clientHello(extensions: [
            .serverName(Self.host), .supportedVersions([0x0304, 0x0303]),
        ])
        XCTAssertEqual(read(hello).offer?.versions, .listed([.tls13, .tls12]))
    }

    /// El caso que le da sentido al tipo: sin la extensión, `legacy_version` es un techo y no una
    /// lista de una sola versión.
    func testWithoutTheExtensionTheLegacyVersionIsACeiling() {
        let hello = ClientHelloFixtures.clientHello(extensions: [.serverName(Self.host)], legacyVersion: 0x0303)
        XCTAssertEqual(read(hello).offer?.versions, .upTo(.tls12))
    }

    /// Con la extensión, el campo antiguo no pinta nada: un cliente de TLS 1.3 lo deja en 1.2.
    func testTheExtensionWinsOverTheLegacyVersion() {
        let hello = ClientHelloFixtures.clientHello(
            extensions: [.supportedVersions([0x0304])], legacyVersion: 0x0303
        )
        XCTAssertEqual(read(hello).offer?.versions, .listed([.tls13]))
    }

    func testGREASEValuesAreNotVersions() {
        let hello = ClientHelloFixtures.clientHello(extensions: [
            .supportedVersions([0x0A0A, 0x0304, 0xFAFA, 0x0303]),
        ])
        XCTAssertEqual(read(hello).offer?.versions, .listed([.tls13, .tls12]))
    }

    func testEverySixteenGREASEValuesAreRecognised() {
        for nibble in UInt16(0)...15 {
            let byte = nibble << 4 | 0x0A
            XCTAssertTrue(ClientHelloScanner.isGREASE(byte << 8 | byte), "0x\(String(byte << 8 | byte, radix: 16))")
        }
        // Parecidos que no lo son: los dos bytes distintos, o iguales sin acabar en A.
        XCTAssertFalse(ClientHelloScanner.isGREASE(0x0A1A))
        XCTAssertFalse(ClientHelloScanner.isGREASE(0x0303))
        XCTAssertFalse(ClientHelloScanner.isGREASE(0x0304))
        XCTAssertFalse(ClientHelloScanner.isGREASE(0x7F1C))
    }

    /// Una lista de solo relleno es una extensión mandada sin ofrecer nada: no vuelve al techo.
    func testAListOfOnlyGREASEIsAnEmptyListNotACeiling() {
        let hello = ClientHelloFixtures.clientHello(extensions: [.supportedVersions([0x2A2A])])
        XCTAssertEqual(read(hello).offer?.versions, .listed([]))
    }

    /// Un borrador o un número que no existe es lo que el cliente mandó, y se guarda tal cual.
    func testAnUnpublishedVersionIsKeptRaw() {
        let hello = ClientHelloFixtures.clientHello(extensions: [.supportedVersions([0x7F1C, 0x0304])])
        XCTAssertEqual(
            read(hello).offer?.versions,
            .listed([TLSProtocolVersion(rawValue: 0x7F1C), .tls13])
        )
    }

    func testAHelloWithoutExtensionsBlockOffersItsLegacyVersion() {
        let hello = ClientHelloFixtures.clientHello(extensions: nil, legacyVersion: 0x0301)
        let reading = read(hello)
        XCTAssertEqual(reading.outcome, .unavailable(.noServerName))
        XCTAssertEqual(reading.offer, ClientTLSOffer(
            versions: .upTo(.tls10),
            applicationProtocols: [],
            omittedApplicationProtocols: 0,
            hasEncryptedClientHello: false
        ))
    }

    func testOnlyTheFirstSupportedVersionsExtensionCounts() {
        let hello = ClientHelloFixtures.clientHello(extensions: [
            .supportedVersions([0x0304]), .supportedVersions([0x0301]),
        ])
        XCTAssertEqual(read(hello).offer?.versions, .listed([.tls13]))
    }

    // MARK: - ALPN

    func testApplicationProtocolsKeepTheClientsOrder() {
        let hello = ClientHelloFixtures.clientHello(extensions: [
            .supportedVersions([0x0304]), .applicationProtocols(["h2", "http/1.1"]),
        ])
        let offer = read(hello).offer
        XCTAssertEqual(offer?.applicationProtocols, ["h2", "http/1.1"])
        XCTAssertEqual(offer?.omittedApplicationProtocols, 0)
    }

    func testWithoutALPNThereAreNoProtocols() {
        let hello = ClientHelloFixtures.clientHello(extensions: [.supportedVersions([0x0304])])
        let offer = read(hello).offer
        XCTAssertEqual(offer?.applicationProtocols, [])
        XCTAssertEqual(offer?.omittedApplicationProtocols, 0)
    }

    /// Un GREASE de ALPN no es un protocolo: ni se guarda ni cuenta como omitido. `0x2A2A` es
    /// además ASCII imprimible («**»), así que sin reconocerlo por su dibujo se colaría.
    func testGREASEProtocolsAreNeitherKeptNorCounted() {
        let hello = ClientHelloFixtures.clientHello(extensions: [
            .applicationProtocols(rawNames: [[0x2A, 0x2A], [UInt8]("h2".utf8), [0x0A, 0x0A]]),
        ])
        let offer = read(hello).offer
        XCTAssertEqual(offer?.applicationProtocols, ["h2"])
        XCTAssertEqual(offer?.omittedApplicationProtocols, 0)
    }

    func testProtocolsThatAreNotPrintableASCIIAreCountedNotKept() {
        let hello = ClientHelloFixtures.clientHello(extensions: [
            .applicationProtocols(rawNames: [
                [UInt8]("h2".utf8),
                [0x68, 0x00, 0x32],             // con un byte de control
                [0x68, 0x20, 0x32],             // con un espacio: rompería la columna
                [0xC3, 0xB1],                   // UTF-8 de varios bytes
            ]),
        ])
        let offer = read(hello).offer
        XCTAssertEqual(offer?.applicationProtocols, ["h2"])
        XCTAssertEqual(offer?.omittedApplicationProtocols, 3)
    }

    func testAnOverlongProtocolIsCountedNotKept() {
        let limit = ClientHelloScanner.maxApplicationProtocolLength
        let hello = ClientHelloFixtures.clientHello(extensions: [
            .applicationProtocols([String(repeating: "a", count: limit), String(repeating: "b", count: limit + 1)]),
        ])
        let offer = read(hello).offer
        XCTAssertEqual(offer?.applicationProtocols, [String(repeating: "a", count: limit)])
        XCTAssertEqual(offer?.omittedApplicationProtocols, 1)
    }

    func testProtocolsBeyondTheCapAreCountedNotKept() {
        let cap = ClientHelloScanner.maxApplicationProtocols
        let names = (0..<(cap + 3)).map { "proto-\($0)" }
        let hello = ClientHelloFixtures.clientHello(extensions: [.applicationProtocols(names)])
        let offer = read(hello).offer
        XCTAssertEqual(offer?.applicationProtocols, Array(names.prefix(cap)))
        XCTAssertEqual(offer?.omittedApplicationProtocols, 3)
    }

    func testAnEmptyProtocolNameIsCountedNotKept() {
        let hello = ClientHelloFixtures.clientHello(extensions: [
            .applicationProtocols(rawNames: [[], [UInt8]("h2".utf8)]),
        ])
        let offer = read(hello).offer
        XCTAssertEqual(offer?.applicationProtocols, ["h2"])
        XCTAssertEqual(offer?.omittedApplicationProtocols, 1)
    }

    func testProtocolTextIsNotNormalised() {
        // Un identificador de ALPN distingue mayúsculas (son bytes opacos), al revés que un host.
        XCTAssertEqual(ClientHelloScanner.applicationProtocol(from: bytes("H2")), "H2")
    }

    // MARK: - ECH

    func testEncryptedClientHelloIsFlagged() {
        let hello = ClientHelloFixtures.clientHello(extensions: [
            .supportedVersions([0x0304]), .serverName("public.example.net"), .encryptedClientHello,
        ])
        let reading = read(hello)
        // El nombre exterior se sigue leyendo: es lo que viaja en claro.
        XCTAssertEqual(reading.outcome, .found("public.example.net"))
        XCTAssertEqual(reading.offer?.hasEncryptedClientHello, true)
    }

    func testAHelloWithoutECHIsNotFlagged() {
        XCTAssertEqual(read(ClientHelloFixtures.clientHello(host: Self.host)).offer?.hasEncryptedClientHello, false)
    }

    // MARK: - La oferta y el nombre no dependen el uno del otro

    func testAHelloWithoutServerNameStillHasAnOffer() {
        let hello = ClientHelloFixtures.clientHello(extensions: [
            .supportedVersions([0x0304, 0x0303]), .applicationProtocols(["h2"]),
        ])
        let reading = read(hello)
        XCTAssertEqual(reading.outcome, .unavailable(.noServerName))
        XCTAssertEqual(reading.offer, ClientTLSOffer(
            versions: .listed([.tls13, .tls12]),
            applicationProtocols: ["h2"],
            omittedApplicationProtocols: 0,
            hasEncryptedClientHello: false
        ))
    }

    /// Lo que va **detrás** del nombre también se lee: en un ClientHello de verdad el ALPN y las
    /// versiones suelen ir después del SNI, y el escáner antes se paraba en él.
    func testExtensionsAfterTheServerNameAreRead() {
        let hello = ClientHelloFixtures.clientHello(extensions: [
            .serverName(Self.host), .applicationProtocols(["h2", "http/1.1"]), .supportedVersions([0x0304]),
        ])
        let reading = read(hello)
        XCTAssertEqual(reading.outcome, .found(Self.host))
        XCTAssertEqual(reading.offer?.versions, .listed([.tls13]))
        XCTAssertEqual(reading.offer?.applicationProtocols, ["h2", "http/1.1"])
    }

    func testAMalformedVersionListCostsTheOfferNotTheName() {
        // El vector declara tres bytes: una lista de versiones no puede tener longitud impar.
        let broken = Extension(type: 43, payload: [0x03, 0x03, 0x04, 0x03])
        let reading = read(ClientHelloFixtures.clientHello(extensions: [.serverName(Self.host), broken]))
        XCTAssertEqual(reading.outcome, .found(Self.host))
        XCTAssertNil(reading.offer)
    }

    func testAVersionListThatDeclaresMoreThanItHasCostsTheOffer() {
        let broken = Extension(type: 43, payload: [0x08, 0x03, 0x04])
        let reading = read(ClientHelloFixtures.clientHello(extensions: [.serverName(Self.host), broken]))
        XCTAssertEqual(reading.outcome, .found(Self.host))
        XCTAssertNil(reading.offer)
    }

    func testAVersionListWithTrailingBytesCostsTheOffer() {
        let broken = Extension(type: 43, payload: [0x02, 0x03, 0x04, 0x03, 0x03])
        XCTAssertNil(read(ClientHelloFixtures.clientHello(extensions: [broken])).offer)
    }

    /// Una oferta leída a medias no es una oferta más corta: las versiones buenas no se quedan si
    /// el ALPN miente.
    func testAMalformedProtocolListCostsTheWholeOffer() {
        // La lista declara 6 bytes y su única entrada dice medir 9.
        let broken = Extension(type: 16, payload: [0x00, 0x06, 0x09, 0x68, 0x32, 0x00, 0x00, 0x00])
        let reading = read(ClientHelloFixtures.clientHello(extensions: [
            .serverName(Self.host), .supportedVersions([0x0304]), broken,
        ]))
        XCTAssertEqual(reading.outcome, .found(Self.host))
        XCTAssertNil(reading.offer)
    }

    /// El bloque de extensiones se rompe después del nombre: el nombre se queda —ya estaba leído
    /// entero— y no hay oferta, porque las versiones podían ir en lo que no se pudo leer.
    func testABlockThatBreaksAfterTheNameKeepsTheNameAndGivesNoOffer() {
        var extensions = Extension.serverName(Self.host).bytes
        extensions += [0x00, 0x2B, 0x00, 0x40, 0x02, 0x03, 0x04]      // declara 64 bytes y trae 3
        var body = ClientHelloFixtures.clientHelloBody(extensions: nil)
        body += ClientHelloFixtures.uint16(UInt16(extensions.count)) + extensions
        let hello = ClientHelloFixtures.record(payload: ClientHelloFixtures.handshakeMessage(body: body))

        let reading = read(Data(hello))
        XCTAssertEqual(reading.outcome, .found(Self.host))
        XCTAssertNil(reading.offer)
    }

    func testABlockThatBreaksBeforeAnyNameIsMalformedAndGivesNoOffer() {
        var extensions = Extension.supportedVersions([0x0304]).bytes
        extensions += [0x00, 0x00, 0x00, 0x40, 0x00]                  // un SNI que declara 64 bytes
        var body = ClientHelloFixtures.clientHelloBody(extensions: nil)
        body += ClientHelloFixtures.uint16(UInt16(extensions.count)) + extensions
        let hello = ClientHelloFixtures.record(payload: ClientHelloFixtures.handshakeMessage(body: body))

        let reading = read(Data(hello))
        XCTAssertEqual(reading.outcome, .unavailable(.malformed))
        XCTAssertNil(reading.offer)
    }

    // MARK: - Cuándo hay oferta

    func testThereIsNoOfferWhileBytesAreMissing() {
        let hello = ClientHelloFixtures.clientHello(host: Self.host)
        var scanner = ClientHelloScanner()
        XCTAssertEqual(scanner.scan(hello.prefix(hello.count - 1)), .needMoreBytes)
        XCTAssertNil(scanner.offer)
        XCTAssertEqual(scanner.scan(hello.suffix(1)), .found(Self.host))
        XCTAssertNotNil(scanner.offer)
    }

    func testAStreamThatIsNotAClientHelloHasNoOffer() {
        XCTAssertNil(read(Data("GET / HTTP/1.1\r\n".utf8)).offer)
    }

    /// La oferta es la misma venga el mensaje como venga partido.
    func testTheOfferIsTheSameWhateverTheChunkBoundaries() {
        let hello = ClientHelloFixtures.clientHello(extensions: [
            .supportedVersions([0x0A0A, 0x0304, 0x0303]), .serverName(Self.host),
            .applicationProtocols(["h2", "http/1.1"]), .encryptedClientHello,
        ])
        let expected = ClientTLSOffer(
            versions: .listed([.tls13, .tls12]),
            applicationProtocols: ["h2", "http/1.1"],
            omittedApplicationProtocols: 0,
            hasEncryptedClientHello: true
        )
        for split in 1..<hello.count {
            var scanner = ClientHelloScanner()
            _ = scanner.scan(hello.prefix(split))
            XCTAssertNil(scanner.offer, "corte en \(split)")
            _ = scanner.scan(hello.dropFirst(split))
            XCTAssertEqual(scanner.offer, expected, "corte en \(split)")
        }
    }

    func testTheOfferIsStickyOnceRead() {
        var scanner = ClientHelloScanner()
        _ = scanner.scan(ClientHelloFixtures.clientHello(extensions: [.supportedVersions([0x0304])]))
        let first = scanner.offer
        _ = scanner.scan(ClientHelloFixtures.clientHello(extensions: [.supportedVersions([0x0301])]))
        XCTAssertEqual(scanner.offer, first)
        XCTAssertEqual(first?.versions, .listed([.tls13]))
    }
}
