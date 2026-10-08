import Foundation
@testable import Shared

/// Constructor de certificados y de mensajes `Certificate` para los tests de su lectura.
///
/// Los certificados salen del **escritor** de la CA local (`X509`), con una firma de relleno: el
/// lector no la mira, y así lo que se lee es DER de verdad y no un vector que repita los supuestos
/// del parser. Los nombres que el escritor no sabe hacer —otros tipos de cadena, RDN múltiples,
/// bytes rotos— se componen aquí con `DER`.
enum CertificateFixtures {

    static let certificateMessageType: UInt8 = 11
    static let changeCipherSpecContentType: UInt8 = 20

    /// 2030-01-01T00:00:00Z.
    static let expiry = Date(timeIntervalSince1970: 1_893_456_000)

    static let leafSubject = "CN=www.example.com,O=Example Ltd"
    static let intermediateSubject = "CN=Example Issuing CA,O=Example Trust"
    static let rootSubject = "CN=Example Root,O=Example Trust"

    // MARK: - Nombres

    static func name(commonName: String, organization: String? = nil) -> [UInt8] {
        X509.name(commonName: commonName, organization: organization)
    }

    /// Un AttributeTypeAndValue con el valor ya codificado como TLV.
    static func attribute(oid: String, value: [UInt8]) -> [UInt8] {
        DER.sequence([DER.objectIdentifier(oid), value])
    }

    /// Un Name con un RDN por cada lista de atributos, en el orden dado.
    static func name(rdns: [[[UInt8]]]) -> [UInt8] {
        DER.sequence(rdns.map { DER.set($0) })
    }

    /// Un Name de un solo atributo `CN` con el valor que se pase, ya como TLV.
    static func name(commonNameValue value: [UInt8]) -> [UInt8] {
        name(rdns: [[attribute(oid: "2.5.4.3", value: value)]])
    }

    // MARK: - Certificados

    static func certificate(
        subject: [UInt8],
        issuer: [UInt8],
        notAfter: Date = expiry
    ) -> [UInt8] {
        let template = X509.Template(
            serialNumber: [0x01, 0x02, 0x03],
            issuerName: issuer,
            subjectName: subject,
            notBefore: Date(timeIntervalSince1970: 1_700_000_000),
            notAfter: notAfter,
            subjectPublicKeyInfo: X509.ecPublicKeyInfo(uncompressedPoint: [0x04] + [UInt8](repeating: 0x11, count: 64)),
            extensions: [X509.basicConstraints(isCA: false)]
        )
        return Array(X509.makeCertificate(template) { _ in Data([0x30, 0x00]) })
    }

    static let leaf = certificate(
        subject: name(commonName: "www.example.com", organization: "Example Ltd"),
        issuer: name(commonName: "Example Issuing CA", organization: "Example Trust")
    )

    static let intermediate = certificate(
        subject: name(commonName: "Example Issuing CA", organization: "Example Trust"),
        issuer: name(commonName: "Example Root", organization: "Example Trust")
    )

    static func read(_ subject: String, issuedBy issuer: String, notAfter: Date = expiry) -> ServerCertificate {
        ServerCertificate(
            subject: CertificateName(text: subject, isTruncated: false),
            issuer: CertificateName(text: issuer, isTruncated: false),
            notAfter: notAfter
        )
    }

    static let readLeaf = read(leafSubject, issuedBy: intermediateSubject)
    static let readIntermediate = read(intermediateSubject, issuedBy: rootSubject)

    // MARK: - El mensaje Certificate

    static func uint24(_ value: Int) -> [UInt8] {
        [UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    /// El cuerpo del mensaje: la lista con su longitud delante, y cada certificado con la suya.
    static func certificateBody(_ certificates: [[UInt8]]) -> [UInt8] {
        let list = certificates.flatMap { uint24($0.count) + $0 }
        return uint24(list.count) + list
    }

    static func certificateMessage(_ certificates: [[UInt8]]) -> [UInt8] {
        ClientHelloFixtures.handshakeMessage(type: certificateMessageType, body: certificateBody(certificates))
    }

    /// Bytes de handshake envueltos en un record.
    static func record(_ payload: [UInt8]) -> [UInt8] {
        ClientHelloFixtures.record(version: [0x03, 0x03], payload: payload)
    }

    static let changeCipherSpec = ClientHelloFixtures.record(
        type: changeCipherSpecContentType, version: [0x03, 0x03], payload: [0x01]
    )

    /// Un ServerHello de TLS 1.2 como mensaje, para componerlo en el mismo record que lo que siga.
    static func serverHelloMessage(legacyVersion: UInt16 = 0x0303) -> [UInt8] {
        ServerHelloFixtures.message(body: ServerHelloFixtures.serverHelloBody(
            legacyVersion: legacyVersion, cipherSuite: 0xC02F, extensions: [ServerHelloFixtures.renegotiationInfo]
        ))
    }
}
