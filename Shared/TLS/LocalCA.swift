import CryptoKit
import Foundation
import Security

/// Errores de la cáscara de Keychain de la CA local.
public enum LocalCAError: Error, Sendable, Equatable {
    /// Un `SecItem*`/`SecKey*` devolvió un estado distinto de `errSecSuccess`.
    case keychain(OSStatus)
    /// El material recuperado del llavero no reconstruye una clave P-256 válida.
    case invalidStoredKey
    /// No se pudo formar el `SecIdentity` del leaf recién importado.
    case identityUnavailable
}

/// Cáscara de llavero de la CA local: `LocalCA` de la spec `relay-and-tls.md`.
///
/// Envuelve el núcleo puro `CertificateAuthority` (toda la criptografía y la construcción de
/// certificados) y le añade lo único que no se puede ejercitar fuera de un dispositivo con
/// entitlements: la **persistencia de la clave raíz P-256 en el llavero** y la conversión de un
/// `MintedCertificate` (cert DER + clave PKCS#8) en un `SecIdentity` presentable en el handshake TLS.
/// Es el mismo reparto núcleo-puro/cáscara-inyectada que `PacketPipeline`→`PacketTunnelProvider` o
/// `TCPRelayFlow`→`Relay`: el núcleo se prueba en Simulator contra `Security` (SecTrust); esta cáscara
/// se valida **solo por compilación** bajo concurrencia estricta, porque el Keychain necesita
/// entitlements de dispositivo y su corrección viva es un smoke test de dispositivo.
///
/// **Vive en `Shared` desde M10 y no en `PacketTunnel`** (mismo movimiento que `TunnelAddressing` y
/// que el formato `.pcap`, y por el mismo motivo): la CA no es de la extensión, es **del usuario**, y
/// las dos mitades del producto la necesitan — la extensión para firmar leaves durante el handshake, y
/// la app para generarla, ofrecer su certificado raíz al flujo guiado de instalación y comprobar si el
/// sistema confía en ella (`docs/ux/onboarding-and-consent.md`). No hay IPC de por medio: los items van
/// al **grupo de acceso de llavero compartido** que ya declaran los dos entitlements, así que app y
/// extensión miran literalmente los mismos items y no hay copia que se pueda quedar desfasada.
///
/// Es un `struct Sendable` (como pide la spec): solo guarda el actor `CertificateAuthority` (Sendable)
/// y la configuración del llavero (valores Sendable). Ningún `SecKey`/`SecIdentity` se retiene: se
/// leen y construyen bajo demanda dentro de cada método, así que no cruzan fronteras de aislamiento.
///
/// **Desviación consciente sobre "Secure Enclave si hay":** la clave raíz se persiste como una clave
/// EC P-256 de software, en un item **device-only y no sincronizable**
/// (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). Respaldarla en el Secure Enclave la volvería
/// **no exportable** por diseño (su material nunca sale del SE), y entonces `CertificateAuthority` no
/// podría reconstruirse desde ella con `make(rootKey:)`: haría falta que el núcleo firmara a través de
/// un firmante inyectado en vez de tener la clave. Ese refinamiento (firmante abstracto para soportar
/// SE) queda para un incremento posterior; hoy la clave raíz nunca abandona el dispositivo igualmente.
public struct LocalCA: Sendable {

    /// Dónde y cómo vive el material de la CA en el llavero. Los defaults usan identificadores propios
    /// del proyecto; `accessGroup` permite compartir la CA entre la app y la extensión (mismo grupo de
    /// acceso de Keychain declarado en los entitlements).
    public struct KeychainConfiguration: Sendable {
        /// Grupo de acceso de Keychain compartido app↔extensión. `nil` usa el grupo por defecto del
        /// proceso, que es **el primer grupo de `keychain-access-groups`** en sus entitlements — y app
        /// y extensión declaran ahí el mismo, así que el default ya comparte. Se deja configurable
        /// porque el default depende del **orden** de una lista en un plist: si algún día se añade otro
        /// grupo por delante, la CA se partiría en dos silenciosamente, y nombrarlo aquí es la salida.
        public var accessGroup: String?
        /// `kSecAttrApplicationTag` de la clave raíz.
        public var rootKeyTag: Data
        /// Prefijo de la etiqueta (`kSecAttrLabel`) de los leaves importados; se le concatena el host.
        public var leafLabelPrefix: String

        public init(
            accessGroup: String? = nil,
            rootKeyTag: Data = Data("com.juanmmm21.tunnelvision.ca.root-key".utf8),
            leafLabelPrefix: String = "com.juanmmm21.tunnelvision.ca.leaf."
        ) {
            self.accessGroup = accessGroup
            self.rootKeyTag = rootKeyTag
            self.leafLabelPrefix = leafLabelPrefix
        }
    }

    private let authority: CertificateAuthority
    private let keychain: KeychainConfiguration

    private init(authority: CertificateAuthority, keychain: KeychainConfiguration) {
        self.authority = authority
        self.keychain = keychain
    }

    // MARK: - Ciclo de vida de la CA

    /// Genera una CA raíz nueva y **persiste su clave privada** en el llavero antes de construir el
    /// núcleo. Si ya existía una clave con el mismo tag, se reemplaza (una CA nueva invalida la
    /// anterior).
    ///
    /// Solo se persiste la clave, no el certificado raíz: `load()` lo recompone desde la clave. El
    /// certificado recompuesto **no** es byte-idéntico al que el usuario instaló (la serie es aleatoria
    /// y el `notBefore`/`notAfter` depende del reloj), pero eso es inocuo: los leaves los firma la misma
    /// clave, y el cliente ancla la cadena en el certificado raíz **de confianza que instaló** —
    /// emparejado por sujeto + clave pública, no por serie— así que un leaf de una CA recargada sigue
    /// validando contra la raíz instalada (probado en `CertificateAuthorityTests`). Persistir el cert
    /// solo importaría para volver a ofrecerlo idéntico en la UI, que no lo necesita.
    public static func generate(
        keychain: KeychainConfiguration = KeychainConfiguration(),
        configuration: CertificateAuthority.Configuration = CertificateAuthority.Configuration()
    ) throws -> LocalCA {
        let rootKey = P256.Signing.PrivateKey()
        try storeRootKey(rootKey, keychain: keychain)
        let authority = try CertificateAuthority.make(rootKey: rootKey, configuration: configuration)
        return LocalCA(authority: authority, keychain: keychain)
    }

    /// Restaura la CA desde la clave raíz persistida por una `generate()` previa, o `nil` si no hay
    /// ninguna (primer arranque, o el usuario la eliminó). La extensión se relanza a menudo, así que
    /// este es el camino normal tras el primer arranque.
    public static func load(
        keychain: KeychainConfiguration = KeychainConfiguration(),
        configuration: CertificateAuthority.Configuration = CertificateAuthority.Configuration()
    ) throws -> LocalCA? {
        guard let rootKey = try loadRootKey(keychain: keychain) else { return nil }
        let authority = try CertificateAuthority.make(rootKey: rootKey, configuration: configuration)
        return LocalCA(authority: authority, keychain: keychain)
    }

    /// Certificado raíz (DER) para que el usuario lo instale y confíe en Ajustes.
    public func exportRootCertificateDER() async -> Data {
        await authority.exportRootCertificateDER()
    }

    /// Emite la sonda con la que preguntarle al sistema si aceptaría un certificado de esta CA en un
    /// handshake TLS (`TrustProbe`, con el porqué entero).
    ///
    /// **No toca el llavero**, a diferencia de `mintLeaf`: la sonda no se presenta en ningún
    /// handshake de verdad, así que no necesita un `SecIdentity` y no debe dejar rastro. Sale de la
    /// cache de leaves del núcleo a partir de la segunda llamada, que es lo correcto: lo que caduca
    /// es la respuesta del sistema —el usuario retira la confianza cuando quiere—, no el leaf.
    public func trustProbe() async throws -> TrustProbe {
        let minted = try await authority.mintLeaf(forHost: TrustProbe.host)
        return TrustProbe(
            leafDER: minted.certificateDER,
            rootDER: await authority.exportRootCertificateDER()
        )
    }

    /// Emite (o recupera de cache) el leaf de `host`, lo importa al llavero y devuelve el `SecIdentity`
    /// resultante — clave + certificado emparejados — que el servidor TLS userspace presentará al
    /// dispositivo durante el handshake.
    public func mintLeaf(forHost host: String, sans: [String] = []) async throws -> SecIdentity {
        let minted = try await authority.mintLeaf(forHost: host, sans: sans)
        return try Self.makeIdentity(from: minted, keychain: keychain)
    }

    /// Vacía la cache de leaves del núcleo (p. ej. al apagar la inspección). No toca la clave raíz ni
    /// el llavero; solo evita reutilizar leaves ya emitidos.
    public func clearLeafCache() async {
        await authority.clearLeafCache()
    }

    /// Elimina la clave raíz del llavero: hace la inspección **reversible** desde el lado de la
    /// extensión (sin clave raíz no se puede firmar ni emitir ningún leaf, así que la CA deja de
    /// existir). Los leaves son efímeros y caducan solos; el usuario completa la reversibilidad
    /// retirando además el certificado raíz de confianza en Ajustes de iOS.
    public func removeFromKeychain() throws {
        let status = SecItemDelete(Self.rootKeyBaseQuery(keychain: keychain) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LocalCAError.keychain(status)
        }
    }

    // MARK: - Keychain: clave raíz

    /// Consulta base que identifica la clave raíz (clase + tag + tipo + grupo). Se comparte entre
    /// almacenar, cargar y borrar para que las tres operen sobre exactamente el mismo item.
    private static func rootKeyBaseQuery(keychain: KeychainConfiguration) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keychain.rootKeyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        ]
        if let accessGroup = keychain.accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private static func storeRootKey(_ key: P256.Signing.PrivateKey, keychain: KeychainConfiguration) throws {
        let secKey = try makeSecKey(fromP256Private: key)
        // Idempotencia: una CA nueva reemplaza la anterior con el mismo tag.
        SecItemDelete(rootKeyBaseQuery(keychain: keychain) as CFDictionary)

        var attributes = rootKeyBaseQuery(keychain: keychain)
        attributes[kSecAttrKeyClass as String] = kSecAttrKeyClassPrivate
        attributes[kSecValueRef as String] = secKey
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw LocalCAError.keychain(status) }
    }

    private static func loadRootKey(keychain: KeychainConfiguration) throws -> P256.Signing.PrivateKey? {
        var query = rootKeyBaseQuery(keychain: keychain)
        query[kSecReturnRef as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let item else { throw LocalCAError.keychain(status) }

        let secKey = item as! SecKey
        var error: Unmanaged<CFError>?
        guard let external = SecKeyCopyExternalRepresentation(secKey, &error) as Data? else {
            throw LocalCAError.invalidStoredKey
        }
        do {
            return try P256.Signing.PrivateKey(x963Representation: external)
        } catch {
            throw LocalCAError.invalidStoredKey
        }
    }

    // MARK: - Keychain: identidad del leaf

    /// Importa el leaf (clave + certificado) al llavero y recupera el `SecIdentity` que forma el par.
    /// En iOS no hay constructor público de `SecIdentity`: solo existe una vez su clave y su certificado
    /// están en el llavero, y el llavero los empareja por la clave pública.
    private static func makeIdentity(from minted: MintedCertificate, keychain: KeychainConfiguration) throws -> SecIdentity {
        guard let certificate = SecCertificateCreateWithData(nil, minted.certificateDER as CFData) else {
            throw LocalCAError.identityUnavailable
        }
        let leafKey: P256.Signing.PrivateKey
        do {
            leafKey = try P256.Signing.PrivateKey(derRepresentation: minted.privateKeyDER)
        } catch {
            throw LocalCAError.invalidStoredKey
        }
        let secKey = try makeSecKey(fromP256Private: leafKey)
        let label = keychain.leafLabelPrefix + minted.host

        try importLeafKey(secKey, label: label, keychain: keychain)
        try importLeafCertificate(certificate, label: label, keychain: keychain)

        var query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
        ]
        if let accessGroup = keychain.accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let item else { throw LocalCAError.identityUnavailable }
        return item as! SecIdentity
    }

    private static func importLeafKey(_ key: SecKey, label: String, keychain: KeychainConfiguration) throws {
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrLabel as String: label,
            kSecValueRef as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if let accessGroup = keychain.accessGroup {
            attributes[kSecAttrAccessGroup as String] = accessGroup
        }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        // Un leaf ya importado (misma clave) reaparece en cada conexión: tratar el duplicado como éxito.
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw LocalCAError.keychain(status)
        }
    }

    private static func importLeafCertificate(_ certificate: SecCertificate, label: String, keychain: KeychainConfiguration) throws {
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: label,
            kSecValueRef as String: certificate,
        ]
        if let accessGroup = keychain.accessGroup {
            attributes[kSecAttrAccessGroup as String] = accessGroup
        }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw LocalCAError.keychain(status)
        }
    }

    // MARK: - Puente CryptoKit → Security

    /// Construye un `SecKey` EC privado a partir de una clave P-256 de CryptoKit, vía su representación
    /// ANSI X9.63 (`0x04 || X || Y || K`), que es justo lo que `SecKeyCreateWithData` espera para una
    /// clave EC privada.
    private static func makeSecKey(fromP256Private key: P256.Signing.PrivateKey) throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(
            Data(key.x963Representation) as CFData,
            attributes as CFDictionary,
            &error
        ) else {
            throw LocalCAError.invalidStoredKey
        }
        return secKey
    }
}
