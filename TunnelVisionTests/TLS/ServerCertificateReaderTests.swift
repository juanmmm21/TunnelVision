import Foundation
import XCTest
@testable import Shared

/// Tests de la lectura de un certificado: sujeto, emisor y caducidad.
///
/// Lo que se afirma, por orden de importancia: que un valor que elige el servidor **no puede
/// fingir estructura ni mover el texto** de un informe, que la fecha se lee bien en sus dos formas
/// y en los dos siglos de la corta, y que nada que no sea un certificado se lee como si lo fuera.
final class ServerCertificateReaderTests: XCTestCase {

    private func read(_ der: [UInt8], maxNameLength: Int = 256) -> ServerCertificate? {
        ServerCertificateReader.certificate(fromDER: der[...], maxNameLength: maxNameLength)
    }

    private func subject(_ name: [UInt8], maxNameLength: Int = 256) -> CertificateName? {
        read(
            CertificateFixtures.certificate(subject: name, issuer: CertificateFixtures.name(commonName: "CA")),
            maxNameLength: maxNameLength
        )?.subject
    }

    // MARK: - El caso normal

    func testReadsSubjectIssuerAndExpiry() {
        XCTAssertEqual(read(CertificateFixtures.leaf), CertificateFixtures.readLeaf)
    }

    /// Lo que emite la CA local de verdad —con su clave, sus extensiones y su firma— se lee igual:
    /// la raíz se firma a sí misma y el leaf lleva a la raíz de emisor.
    func testReadsTheCertificatesTheLocalAuthorityIssues() async throws {
        let authority = try CertificateAuthority.generate()
        let rootDER = await authority.exportRootCertificateDER()
        let leafDER = try await authority.mintLeaf(forHost: "www.example.com").certificateDER
        let root = try XCTUnwrap(read(Array(rootDER)))
        let leaf = try XCTUnwrap(read(Array(leafDER)))

        XCTAssertEqual(root.subject, root.issuer)
        XCTAssertFalse(root.subject.text.isEmpty)
        XCTAssertEqual(leaf.issuer, root.subject)
        XCTAssertEqual(leaf.subject.text, "CN=www.example.com")
        XCTAssertGreaterThan(leaf.notAfter, Date())
    }

    func testAVersion1CertificateHasNoVersionFieldAndIsStillRead() {
        let name = CertificateFixtures.name(commonName: "old.example.com")
        let tbs = DER.sequence([
            DER.integer(7),
            DER.sequence([DER.objectIdentifier("1.2.840.10045.4.3.2")]),
            name,
            DER.sequence([DER.time(Date(timeIntervalSince1970: 0)), DER.time(CertificateFixtures.expiry)]),
            name,
        ])
        let certificate = DER.sequence([tbs])
        XCTAssertEqual(
            read(certificate),
            CertificateFixtures.read("CN=old.example.com", issuedBy: "CN=old.example.com")
        )
    }

    // MARK: - Nombres

    func testTheMostSpecificAttributeComesFirst() {
        let name = CertificateFixtures.name(rdns: [
            [CertificateFixtures.attribute(oid: "2.5.4.6", value: DER.printableString("DE"))],
            [CertificateFixtures.attribute(oid: "2.5.4.8", value: DER.utf8String("Hessen"))],
            [CertificateFixtures.attribute(oid: "2.5.4.7", value: DER.utf8String("Frankfurt"))],
            [CertificateFixtures.attribute(oid: "2.5.4.10", value: DER.utf8String("Beispiel AG"))],
            [CertificateFixtures.attribute(oid: "2.5.4.11", value: DER.utf8String("IT"))],
            [CertificateFixtures.attribute(oid: "2.5.4.3", value: DER.utf8String("app.beispiel.de"))],
        ])
        XCTAssertEqual(subject(name)?.text, "CN=app.beispiel.de,OU=IT,O=Beispiel AG,L=Frankfurt,ST=Hessen,C=DE")
    }

    func testAnAttributeWithoutAShortNameIsWrittenByItsOID() {
        // 2.5.4.5 es serialNumber: no está en la tabla de RFC 4514.
        let name = CertificateFixtures.name(rdns: [
            [CertificateFixtures.attribute(oid: "2.5.4.5", value: DER.printableString("HRB 1234"))],
            [CertificateFixtures.attribute(oid: "0.9.2342.19200300.100.1.25", value: DER.ia5String("example"))],
        ])
        XCTAssertEqual(subject(name)?.text, "DC=example,2.5.4.5=HRB 1234")
    }

    func testAMultiValuedRDNJoinsItsAttributesWithAPlus() {
        let name = CertificateFixtures.name(rdns: [[
            CertificateFixtures.attribute(oid: "2.5.4.3", value: DER.utf8String("host")),
            CertificateFixtures.attribute(oid: "2.5.4.11", value: DER.utf8String("unit")),
        ]])
        XCTAssertEqual(subject(name)?.text, "CN=host+OU=unit")
    }

    func testAnEmptyNameIsAnEmptyText() {
        XCTAssertEqual(subject(DER.sequence([])), CertificateName(text: "", isTruncated: false))
    }

    func testNonASCIITextIsKept() {
        XCTAssertEqual(subject(CertificateFixtures.name(commonName: "Müller GmbH"))?.text, "CN=Müller GmbH")
    }

    func testOtherStringTypesAreDecoded() {
        let teletex = DER.tlv(DERReader.Tag.teletexString, [0x4D, 0xFC, 0x6C])                 // "Mül" en Latin-1
        let bmp = DER.tlv(DERReader.Tag.bmpString, [0x00, 0x41, 0x00, 0xE9])                   // "Aé" en UTF-16BE
        let universal = DER.tlv(DERReader.Tag.universalString, [0x00, 0x00, 0x00, 0x5A])       // "Z" en UTF-32BE
        XCTAssertEqual(subject(CertificateFixtures.name(commonNameValue: teletex))?.text, "CN=Mül")
        XCTAssertEqual(subject(CertificateFixtures.name(commonNameValue: bmp))?.text, "CN=Aé")
        XCTAssertEqual(subject(CertificateFixtures.name(commonNameValue: universal))?.text, "CN=Z")
    }

    // MARK: - Lo que el servidor no puede colar

    /// El caso que justifica el escapado: un valor con una coma no puede pasar por dos atributos.
    func testAValueCannotForgeASecondAttribute() {
        let name = CertificateFixtures.name(commonName: "evil.example,O=Trusted Bank")
        XCTAssertEqual(subject(name)?.text, "CN=evil.example\\,O=Trusted Bank")
    }

    func testSpecialCharactersAreEscaped() {
        XCTAssertEqual(ServerCertificateReader.escaped("a+b;c<d>e\"f\\g"), "a\\+b\\;c\\<d\\>e\\\"f\\\\g")
        XCTAssertEqual(ServerCertificateReader.escaped(" padded "), "\\ padded\\ ")
        XCTAssertEqual(ServerCertificateReader.escaped("#hash"), "\\#hash")
        XCTAssertEqual(ServerCertificateReader.escaped("in # side"), "in # side")
        XCTAssertEqual(ServerCertificateReader.escaped(" "), "\\ ")
    }

    /// Un salto de línea partiría una fila de un informe; un cambio de dirección de escritura
    /// (U+202E) haría que un nombre se leyera al revés de como está escrito.
    func testControlAndFormatCharactersAreWrittenAsHex() {
        XCTAssertEqual(ServerCertificateReader.escaped("a\nb"), "a\\0Ab")
        XCTAssertEqual(ServerCertificateReader.escaped("a\u{0}b"), "a\\00b")
        XCTAssertEqual(ServerCertificateReader.escaped("a\u{7F}b"), "a\\7Fb")
        XCTAssertEqual(ServerCertificateReader.escaped("a\u{202E}b"), "a\\E2\\80\\AEb")
        XCTAssertEqual(ServerCertificateReader.escaped("a\u{2028}b"), "a\\E2\\80\\A8b")
    }

    func testAValueThatIsNotValidTextIsWrittenAsItsBytes() {
        let broken = DER.tlv(DERReader.Tag.utf8String, [0xC3, 0x28])
        XCTAssertEqual(subject(CertificateFixtures.name(commonNameValue: broken))?.text, "CN=#0C02C328")
        let oddBMP = DER.tlv(DERReader.Tag.bmpString, [0x00, 0x41, 0x00])
        XCTAssertEqual(subject(CertificateFixtures.name(commonNameValue: oddBMP))?.text, "CN=#1E03004100")
    }

    func testAValueThatIsNotAStringIsWrittenAsItsBytes() {
        XCTAssertEqual(subject(CertificateFixtures.name(commonNameValue: DER.integer(5)))?.text, "CN=#020105")
    }

    func testANameOverTheLimitIsCutAndMarked() {
        let name = CertificateFixtures.name(commonName: String(repeating: "a", count: 300))
        let cut = subject(name, maxNameLength: 10)
        XCTAssertEqual(cut, CertificateName(text: "CN=aaaaaaa", isTruncated: true))
    }

    func testANameExactlyAtTheLimitIsNotMarked() {
        let cut = subject(CertificateFixtures.name(commonName: "abcdefg"), maxNameLength: 10)
        XCTAssertEqual(cut, CertificateName(text: "CN=abcdefg", isTruncated: false))
    }

    // MARK: - OID

    func testObjectIdentifiers() {
        func dotted(_ text: String) -> String? {
            var reader = DERReader(DER.objectIdentifier(text)[...])
            return reader.content(tag: DERReader.Tag.objectIdentifier).flatMap(ServerCertificateReader.objectIdentifier)
        }
        for oid in ["2.5.4.3", "1.2.840.113549.1.9.1", "0.9.2342.19200300.100.1.25"] {
            XCTAssertEqual(dotted(oid), oid)
        }
        // El ejemplo de X.690 § 8.19: bajo el arco 2 el segundo no tiene tope, y el primer
        // subidentificador ocupa entonces más de un byte (80 + 999 = 1079).
        XCTAssertEqual(ServerCertificateReader.objectIdentifier([0x88, 0x37, 0x03]), "2.999.3")
    }

    func testABrokenObjectIdentifierIsRefused() {
        XCTAssertNil(ServerCertificateReader.objectIdentifier([]))
        // Último byte con el bit de continuación: el arco no termina.
        XCTAssertNil(ServerCertificateReader.objectIdentifier([0x55, 0x84]))
        // Diez bytes de continuación no caben en un arco.
        XCTAssertNil(ServerCertificateReader.objectIdentifier([0x55] + [UInt8](repeating: 0xFF, count: 10) + [0x01]))
    }

    func testANameWithABrokenAttributeMakesTheCertificateUnreadable() {
        let brokenOID = DER.sequence([DER.set([DER.sequence([DER.tlv(DERReader.Tag.objectIdentifier, [0x55, 0x84]), DER.utf8String("x")])])])
        XCTAssertNil(subject(brokenOID))
        let emptySet = DER.sequence([DER.set([])])
        XCTAssertNil(subject(emptySet))
        let notASet = DER.sequence([DER.sequence([])])
        XCTAssertNil(subject(notASet))
    }

    // MARK: - Fechas

    private func time(_ tag: UInt8, _ text: String) -> Date? {
        var reader = DERReader(DER.tlv(tag, Array(text.utf8))[...])
        return reader.element().flatMap(ServerCertificateReader.time)
    }

    func testUTCTimeIsReadInBothCenturies() {
        XCTAssertEqual(time(DERReader.Tag.utcTime, "300101000000Z"), Date(timeIntervalSince1970: 1_893_456_000))
        XCTAssertEqual(time(DERReader.Tag.utcTime, "700101000000Z"), Date(timeIntervalSince1970: 0))
        XCTAssertEqual(time(DERReader.Tag.utcTime, "491231235959Z"), Date(timeIntervalSince1970: 2_524_607_999))
        XCTAssertEqual(time(DERReader.Tag.utcTime, "500101000000Z"), Date(timeIntervalSince1970: -631_152_000))
    }

    func testGeneralizedTimeIsRead() {
        XCTAssertEqual(time(DERReader.Tag.generalizedTime, "20500101000000Z"), Date(timeIntervalSince1970: 2_524_608_000))
        // El «sin caducidad» de RFC 5280 § 4.1.2.5.
        XCTAssertEqual(time(DERReader.Tag.generalizedTime, "99991231235959Z"), Date(timeIntervalSince1970: 253_402_300_799))
    }

    func testLeapDaysAreCounted() {
        XCTAssertEqual(time(DERReader.Tag.utcTime, "240229120000Z"), Date(timeIntervalSince1970: 1_709_208_000))
        XCTAssertEqual(time(DERReader.Tag.utcTime, "240301000000Z"), Date(timeIntervalSince1970: 1_709_251_200))
    }

    /// Lo que escribe `DER.time` —que usa `Calendar`— se lee con la aritmética propia igual.
    func testReadsBackWhatTheWriterWrites() {
        for seconds in [0.0, 951_782_400, 1_700_000_000, 2_524_607_999, 2_524_608_000, 4_102_444_800] {
            let date = Date(timeIntervalSince1970: seconds)
            var reader = DERReader(DER.time(date)[...])
            XCTAssertEqual(reader.element().flatMap(ServerCertificateReader.time), date)
        }
    }

    func testTimesInAnyOtherShapeAreRefused() {
        XCTAssertNil(time(DERReader.Tag.utcTime, "3001010000Z"))             // sin segundos
        XCTAssertNil(time(DERReader.Tag.utcTime, "300101000000+0100"))       // con desfase
        XCTAssertNil(time(DERReader.Tag.utcTime, "30010100000AZ"))
        XCTAssertNil(time(DERReader.Tag.utcTime, "301301000000Z"))           // mes 13
        XCTAssertNil(time(DERReader.Tag.utcTime, "300100000000Z"))           // día 0
        XCTAssertNil(time(DERReader.Tag.utcTime, "300101240000Z"))           // hora 24
        XCTAssertNil(time(DERReader.Tag.generalizedTime, "20500101000000.5Z"))
        XCTAssertNil(time(DERReader.Tag.generalizedTime, "300101000000Z"))   // forma corta con la etiqueta larga
        XCTAssertNil(time(DERReader.Tag.utf8String, "300101000000Z"))
    }

    // MARK: - Lo que no es un certificado

    func testBytesThatAreNotACertificateAreRefused() {
        XCTAssertNil(read([]))
        XCTAssertNil(read([UInt8](repeating: 0x5A, count: 64)))
        XCTAssertNil(read(DER.sequence([])))
        XCTAssertNil(read(DER.sequence([DER.sequence([])])))
        XCTAssertNil(read(DER.octetString(CertificateFixtures.leaf)))
    }

    func testEveryTruncationOfACertificateIsRefusedWithoutReadingOutside() {
        let leaf = CertificateFixtures.leaf
        for length in 0..<leaf.count {
            XCTAssertNil(read(Array(leaf.prefix(length))), "cortado a \(length) bytes")
        }
    }

    /// El lector trabaja sobre una rebanada de un buffer mayor: sus índices no empiezan en cero.
    func testReadsACertificateInsideALargerBuffer() {
        let buffer = [0xFF, 0xFF, 0xFF] + CertificateFixtures.leaf + [0xFF]
        let slice = buffer[3..<(3 + CertificateFixtures.leaf.count)]
        XCTAssertEqual(
            ServerCertificateReader.certificate(fromDER: slice, maxNameLength: 256),
            CertificateFixtures.readLeaf
        )
    }
}
