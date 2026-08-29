import Foundation

/// Construcción y firma de certificados X.509 v3 (RFC 5280) sobre el codificador `DER`.
///
/// Es puro y no conoce ninguna clave: recibe la información del certificado más una **closure de
/// firma** (`sign`) que produce la firma DER del TBS, y devuelve el certificado DER completo. Así el
/// material de clave y el algoritmo concreto (aquí ECDSA P-256 + SHA-256) viven en quien firma
/// (`CertificateAuthority`), y esta capa solo serializa y ensambla — el mismo reparto núcleo-puro /
/// cáscara-inyectada del resto del proyecto.
///
/// Solo emite lo que la inspección TLS de este proyecto necesita: firma ECDSA-SHA256, clave pública
/// EC P-256, y el conjunto mínimo de extensiones (BasicConstraints, KeyUsage, ExtendedKeyUsage,
/// SubjectAltName, Subject/Authority Key Identifier). No hay opciones ni algoritmos alternativos.
enum X509 {

    // MARK: - OIDs (RFC 5280, RFC 5480, RFC 5758)

    private enum OID {
        static let commonName = "2.5.4.3"
        static let organizationName = "2.5.4.10"

        static let ecPublicKey = "1.2.840.10045.2.1"
        static let prime256v1 = "1.2.840.10045.3.1.7"
        static let ecdsaWithSHA256 = "1.2.840.10045.4.3.2"

        static let basicConstraints = "2.5.29.19"
        static let keyUsage = "2.5.29.15"
        static let subjectKeyIdentifier = "2.5.29.14"
        static let authorityKeyIdentifier = "2.5.29.35"
        static let subjectAltName = "2.5.29.17"
        static let extKeyUsage = "2.5.29.37"
        static let serverAuth = "1.3.6.1.5.5.7.3.1"
    }

    /// Posición de cada bandera dentro del BIT STRING de KeyUsage (RFC 5280 §4.2.1.3).
    enum KeyUsageBit {
        static let digitalSignature = 0
        static let keyEncipherment = 2
        static let keyCertSign = 5
        static let cRLSign = 6
    }

    /// Un `GeneralName` de un SubjectAltName. Solo se modelan los dos que sirven a un servidor TLS:
    /// nombre DNS y dirección IP literal.
    enum GeneralName: Sendable, Equatable {
        case dnsName(String)
        case ipAddress([UInt8])   // 4 bytes (IPv4) o 16 (IPv6), en orden de red
    }

    // MARK: - Datos del certificado

    /// Todo lo necesario para emitir un certificado. `issuerName`/`subjectName` son Names DER ya
    /// codificados (con `name(commonName:organization:)`); las `extensions` son TLVs `Extension`
    /// completos (con `makeExtension` y sus ayudantes).
    struct Template {
        var serialNumber: [UInt8]
        var issuerName: [UInt8]
        var subjectName: [UInt8]
        var notBefore: Date
        var notAfter: Date
        var subjectPublicKeyInfo: [UInt8]
        var extensions: [[UInt8]]
    }

    // MARK: - Ensamblado del certificado

    /// Serializa el TBSCertificate, lo firma con `sign` y devuelve el `Certificate` DER completo.
    ///
    /// `sign` recibe el TBS ya serializado y devuelve la firma en su codificación DER (para ECDSA, un
    /// `SEQUENCE { r, s }`), que se envuelve en el BIT STRING de firma sin ninguna transformación
    /// extra. Los `signatureAlgorithm` de dentro del TBS y de fuera coinciden, como exige RFC 5280.
    static func makeCertificate(_ template: Template, sign: (Data) throws -> Data) rethrows -> Data {
        let tbs = tbsCertificate(template)
        let signature = try sign(Data(tbs))
        return Data(DER.sequence([
            tbs,
            signatureAlgorithm(),
            DER.bitString(Array(signature)),
        ]))
    }

    private static func tbsCertificate(_ template: Template) -> [UInt8] {
        DER.sequence([
            DER.explicit(0, DER.integer(2)),   // versión v3 (valor 2), etiquetado [0] explícito
            DER.integer(magnitude: template.serialNumber),
            signatureAlgorithm(),
            template.issuerName,
            DER.sequence([DER.time(template.notBefore), DER.time(template.notAfter)]),
            template.subjectName,
            template.subjectPublicKeyInfo,
            DER.explicit(3, DER.sequence(template.extensions)),
        ])
    }

    /// AlgorithmIdentifier de ECDSA con SHA-256. ECDSA no lleva parámetros (a diferencia de RSA, que
    /// pone NULL): el SEQUENCE contiene solo el OID.
    private static func signatureAlgorithm() -> [UInt8] {
        DER.sequence([DER.objectIdentifier(OID.ecdsaWithSHA256)])
    }

    // MARK: - Name (RFC 5280 §4.1.2.4)

    /// Distinguished Name con Common Name y, opcionalmente, Organization. Cada atributo es su propio
    /// RDN (un SET de un solo AttributeTypeAndValue), en el orden dado.
    static func name(commonName: String, organization: String?) -> [UInt8] {
        var rdns: [[UInt8]] = []
        if let organization {
            rdns.append(relativeDistinguishedName(oid: OID.organizationName, value: organization))
        }
        rdns.append(relativeDistinguishedName(oid: OID.commonName, value: commonName))
        return DER.sequence(rdns)
    }

    private static func relativeDistinguishedName(oid: String, value: String) -> [UInt8] {
        DER.set([
            DER.sequence([DER.objectIdentifier(oid), DER.utf8String(value)]),
        ])
    }

    // MARK: - SubjectPublicKeyInfo (RFC 5480, clave EC)

    /// SPKI de una clave pública EC P-256 a partir de su punto sin comprimir (`0x04 || X || Y`, 65 B).
    static func ecPublicKeyInfo(uncompressedPoint: [UInt8]) -> [UInt8] {
        DER.sequence([
            DER.sequence([
                DER.objectIdentifier(OID.ecPublicKey),
                DER.objectIdentifier(OID.prime256v1),
            ]),
            DER.bitString(uncompressedPoint),
        ])
    }

    // MARK: - Extensiones

    /// Envuelve un valor de extensión ya codificado en su `Extension` SEQUENCE. El valor va dentro de
    /// un OCTET STRING (RFC 5280); `critical` se omite cuando es falso (es el DEFAULT).
    static func makeExtension(oid: String, critical: Bool, value: [UInt8]) -> [UInt8] {
        var items: [[UInt8]] = [DER.objectIdentifier(oid)]
        if critical {
            items.append(DER.boolean(true))
        }
        items.append(DER.octetString(value))
        return DER.sequence(items)
    }

    /// BasicConstraints. Para una CA se emite `cA TRUE`; para un leaf se deja el SEQUENCE vacío
    /// (`cA` toma su DEFAULT FALSE). Siempre crítica, como recomienda RFC 5280.
    static func basicConstraints(isCA: Bool) -> [UInt8] {
        let value = isCA ? DER.sequence([DER.boolean(true)]) : DER.sequence([])
        return makeExtension(oid: OID.basicConstraints, critical: true, value: value)
    }

    static func keyUsage(bits: [Int]) -> [UInt8] {
        makeExtension(oid: OID.keyUsage, critical: true, value: DER.namedBitString(setBits: bits))
    }

    /// ExtendedKeyUsage con solo `serverAuth`: presentamos el leaf como certificado de servidor TLS
    /// hacia el cliente (el dispositivo). No crítica (RFC 5280 la recomienda no crítica).
    static func extendedKeyUsageServerAuth() -> [UInt8] {
        let value = DER.sequence([DER.objectIdentifier(OID.serverAuth)])
        return makeExtension(oid: OID.extKeyUsage, critical: false, value: value)
    }

    /// SubjectAltName. Es donde iOS busca el host (ignora el CN), así que un leaf sin SAN no valida.
    static func subjectAltName(_ names: [GeneralName]) -> [UInt8] {
        let encoded = names.map { generalName -> [UInt8] in
            switch generalName {
            case .dnsName(let host):
                // dNSName [2]: IA5String sin tag interno (valor primitivo etiquetado por contexto).
                return DER.implicit(2, Array(host.utf8))
            case .ipAddress(let bytes):
                // iPAddress [7]: los bytes crudos de la dirección.
                return DER.implicit(7, bytes)
            }
        }
        return makeExtension(oid: OID.subjectAltName, critical: false, value: DER.sequence(encoded))
    }

    static func subjectKeyIdentifier(_ keyID: [UInt8]) -> [UInt8] {
        makeExtension(oid: OID.subjectKeyIdentifier, critical: false, value: DER.octetString(keyID))
    }

    /// AuthorityKeyIdentifier con solo el `keyIdentifier [0]` del emisor: enlaza el leaf con la CA
    /// que lo firmó. No crítica.
    static func authorityKeyIdentifier(_ keyID: [UInt8]) -> [UInt8] {
        let value = DER.sequence([DER.implicit(0, keyID)])
        return makeExtension(oid: OID.authorityKeyIdentifier, critical: false, value: value)
    }
}
