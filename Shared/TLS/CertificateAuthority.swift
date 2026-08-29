import CryptoKit
import Foundation

/// Errores de la autoridad certificadora local.
public enum CertificateAuthorityError: Error, Sendable, Equatable {
    /// Se pidió emitir un leaf para un host vacío o solo con espacios.
    case invalidHost(String)
}

/// Un certificado leaf recién emitido: el certificado DER más su clave privada (PKCS#8 DER), listos
/// para que la cáscara de Keychain los importe y construya un `SecIdentity` que presentar en el
/// handshake TLS de cara al dispositivo.
public struct MintedCertificate: Sendable, Equatable {
    /// Host para el que se emitió (el SNI del ClientHello).
    public let host: String
    /// Certificado X.509 en DER, firmado por la CA raíz.
    public let certificateDER: Data
    /// Clave privada del leaf, en DER PKCS#8.
    public let privateKeyDER: Data

    public init(host: String, certificateDER: Data, privateKeyDER: Data) {
        self.host = host
        self.certificateDER = certificateDER
        self.privateKeyDER = privateKeyDER
    }
}

/// Núcleo puro de la CA local de inspección TLS: genera una raíz P-256 autofirmada y emite leaves
/// efímeros firmados por ella, cacheados por host.
///
/// Es la mitad **testeable en Simulator** de `LocalCA` (spec `relay-and-tls.md`): toda la
/// criptografía y la construcción de certificados vive aquí, sobre `CryptoKit` (P-256, ECDSA-SHA256)
/// y el codificador `DER`/`X509`, sin tocar el Keychain ni `SecIdentity`. La persistencia de la clave
/// raíz en el llavero (Secure Enclave donde exista) y la conversión de un `MintedCertificate` en un
/// `SecIdentity` son la cáscara device-only, que se apoya en este núcleo — el mismo reparto que
/// `PacketPipeline`→`PacketTunnelProvider` o `TCPRelayFlow`→`Relay`.
///
/// Actor porque cachea leaves (estado mutable) y porque el interceptor TLS (también actor) le pedirá
/// certificados durante el handshake. La clave raíz nunca se expone; solo salen el certificado raíz
/// (para que el usuario lo instale) y los leaves.
public actor CertificateAuthority {

    /// Parámetros de emisión. Los valores por defecto mantienen los leaves bien por debajo del tope de
    /// validez que iOS impone a los certificados de servidor (398 días), y dan a la raíz una vigencia
    /// larga para no forzar reinstalaciones frecuentes del usuario.
    public struct Configuration: Sendable {
        public var rootCommonName: String
        public var rootOrganization: String
        public var rootValidity: TimeInterval
        public var leafValidity: TimeInterval
        /// Margen hacia atrás en `notBefore` para absorber desfases de reloj entre dispositivos.
        public var backdating: TimeInterval

        public init(
            rootCommonName: String = "TunnelVision Local CA",
            rootOrganization: String = "TunnelVision",
            rootValidity: TimeInterval = 3650 * 24 * 3600,   // ~10 años
            leafValidity: TimeInterval = 90 * 24 * 3600,     // 90 días
            backdating: TimeInterval = 300                    // 5 minutos
        ) {
            self.rootCommonName = rootCommonName
            self.rootOrganization = rootOrganization
            self.rootValidity = rootValidity
            self.leafValidity = leafValidity
            self.backdating = backdating
        }
    }

    private let rootKey: P256.Signing.PrivateKey
    private let rootCertificate: Data
    private let rootSubjectName: [UInt8]
    private let rootKeyIdentifier: [UInt8]
    private let configuration: Configuration
    private let now: @Sendable () -> Date

    /// Cache de leaves por host (en minúsculas). Evita re-emitir en cada conexión al mismo servidor.
    private var leafCache: [String: MintedCertificate] = [:]

    private init(
        rootKey: P256.Signing.PrivateKey,
        rootCertificate: Data,
        rootSubjectName: [UInt8],
        rootKeyIdentifier: [UInt8],
        configuration: Configuration,
        now: @escaping @Sendable () -> Date
    ) {
        self.rootKey = rootKey
        self.rootCertificate = rootCertificate
        self.rootSubjectName = rootSubjectName
        self.rootKeyIdentifier = rootKeyIdentifier
        self.configuration = configuration
        self.now = now
    }

    /// Genera una CA raíz nueva: una clave P-256 y su certificado autofirmado (CA:TRUE, keyCertSign).
    ///
    /// `now` es inyectable para tests deterministas de validez; en producción es `Date.init`.
    public static func generate(
        configuration: Configuration = Configuration(),
        now: @escaping @Sendable () -> Date = Date.init
    ) throws -> CertificateAuthority {
        try make(rootKey: P256.Signing.PrivateKey(), configuration: configuration, now: now)
    }

    /// Reconstruye la CA sobre una clave raíz **ya existente** — la que la cáscara de Keychain
    /// (`LocalCA`) persistió al generarla y recupera al relanzar la extensión. Re-emite el certificado
    /// raíz de forma determinista a partir de la misma clave, así que sirve tanto para el arranque en
    /// frío (`generate()` pasa una clave nueva) como para restaurar una CA persistida. `now` fija el
    /// `notBefore`/`notAfter` del certificado raíz recomputado; en producción es `Date.init`.
    public static func make(
        rootKey: P256.Signing.PrivateKey,
        configuration: Configuration = Configuration(),
        now: @escaping @Sendable () -> Date = Date.init
    ) throws -> CertificateAuthority {
        let publicPoint = Array(rootKey.publicKey.x963Representation)
        let keyIdentifier = Self.keyIdentifier(forPublicPoint: publicPoint)
        let subjectName = X509.name(
            commonName: configuration.rootCommonName,
            organization: configuration.rootOrganization
        )
        let start = now()

        let template = X509.Template(
            serialNumber: Self.randomSerialNumber(),
            issuerName: subjectName,          // autofirmado: emisor = sujeto
            subjectName: subjectName,
            notBefore: start.addingTimeInterval(-configuration.backdating),
            notAfter: start.addingTimeInterval(configuration.rootValidity),
            subjectPublicKeyInfo: X509.ecPublicKeyInfo(uncompressedPoint: publicPoint),
            extensions: [
                X509.basicConstraints(isCA: true),
                X509.keyUsage(bits: [
                    X509.KeyUsageBit.digitalSignature,
                    X509.KeyUsageBit.keyCertSign,
                    X509.KeyUsageBit.cRLSign,
                ]),
                X509.subjectKeyIdentifier(keyIdentifier),
            ]
        )
        let certificate = try X509.makeCertificate(template) { tbs in
            try rootKey.signature(for: tbs).derRepresentation
        }

        return CertificateAuthority(
            rootKey: rootKey,
            rootCertificate: certificate,
            rootSubjectName: subjectName,
            rootKeyIdentifier: keyIdentifier,
            configuration: configuration,
            now: now
        )
    }

    /// Certificado raíz (DER) para que el usuario lo instale y confíe en Ajustes.
    public func exportRootCertificateDER() -> Data {
        rootCertificate
    }

    /// Emite (o recupera de cache) un leaf efímero para `host`, firmado por la CA.
    ///
    /// El SubjectAltName incluye siempre `host` y, además, los `sans` extra. Un SAN que sea una IP
    /// literal se codifica como `iPAddress`; cualquier otro, como `dNSName`. La cache es **por host**:
    /// una segunda llamada con `sans` distintos devuelve el leaf ya emitido (el primero gana), que
    /// siempre cubre `host`.
    public func mintLeaf(forHost host: String, sans: [String] = []) throws -> MintedCertificate {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty else {
            throw CertificateAuthorityError.invalidHost(host)
        }
        let cacheKey = normalizedHost.lowercased()
        if let cached = leafCache[cacheKey] {
            return cached
        }

        let leafKey = P256.Signing.PrivateKey()
        let publicPoint = Array(leafKey.publicKey.x963Representation)
        let start = now()

        let template = X509.Template(
            serialNumber: Self.randomSerialNumber(),
            issuerName: rootSubjectName,
            subjectName: X509.name(commonName: normalizedHost, organization: nil),
            notBefore: start.addingTimeInterval(-configuration.backdating),
            notAfter: start.addingTimeInterval(configuration.leafValidity),
            subjectPublicKeyInfo: X509.ecPublicKeyInfo(uncompressedPoint: publicPoint),
            extensions: [
                X509.basicConstraints(isCA: false),
                X509.keyUsage(bits: [
                    X509.KeyUsageBit.digitalSignature,
                    X509.KeyUsageBit.keyEncipherment,
                ]),
                X509.extendedKeyUsageServerAuth(),
                X509.subjectAltName(Self.generalNames(host: normalizedHost, extraSANs: sans)),
                X509.subjectKeyIdentifier(Self.keyIdentifier(forPublicPoint: publicPoint)),
                X509.authorityKeyIdentifier(rootKeyIdentifier),
            ]
        )
        let certificate = try X509.makeCertificate(template) { tbs in
            try rootKey.signature(for: tbs).derRepresentation
        }

        let minted = MintedCertificate(
            host: normalizedHost,
            certificateDER: certificate,
            privateKeyDER: leafKey.derRepresentation
        )
        leafCache[cacheKey] = minted
        return minted
    }

    /// Vacía la cache de leaves (p. ej. al apagar la inspección). No afecta a la raíz.
    public func clearLeafCache() {
        leafCache.removeAll()
    }

    // MARK: - Ayudantes

    /// Convierte host + SANs extra en `GeneralName`s, deduplicando por representación y decidiendo
    /// `iPAddress` vs `dNSName` según parsee o no como IP literal.
    private static func generalNames(host: String, extraSANs: [String]) -> [X509.GeneralName] {
        var seen = Set<String>()
        var names: [X509.GeneralName] = []
        for candidate in [host] + extraSANs {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            if let ipBytes = ipLiteralBytes(trimmed) {
                names.append(.ipAddress(ipBytes))
            } else {
                names.append(.dnsName(trimmed))
            }
        }
        return names
    }

    /// Bytes de red de una IP literal (4 para v4, 16 para v6), o `nil` si no lo es. Lo resuelve
    /// `IPAddress(parsing:)`, que es el mismo `inet_pton` de siempre pero en un solo sitio: dos
    /// parsers de IP dentro del mismo framework podrían discrepar sobre qué es una dirección.
    private static func ipLiteralBytes(_ string: String) -> [UInt8]? {
        IPAddress(parsing: string)?.bytes
    }

    /// SubjectKeyIdentifier según el método (1) de RFC 5280 §4.2.1.2: SHA-1 del contenido del BIT
    /// STRING de la clave pública (el punto EC). SHA-1 aquí es solo un identificador, no una garantía
    /// de seguridad, así que su debilidad criptográfica es irrelevante.
    private static func keyIdentifier(forPublicPoint point: [UInt8]) -> [UInt8] {
        Array(Insecure.SHA1.hash(data: Data(point)))
    }

    /// Número de serie aleatorio de 16 bytes (>0 tras la normalización DER). RFC 5280 exige serie
    /// positiva y única; 16 bytes de entropía hacen la colisión inverosímil.
    private static func randomSerialNumber() -> [UInt8] {
        (0..<16).map { _ in UInt8.random(in: 0...255) }
    }
}
