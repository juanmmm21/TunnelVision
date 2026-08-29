import CryptoKit
import Foundation
import Security
import Shared
import XCTest

/// Tests del núcleo de la CA local. La corrección de los certificados no se comprueba contra la
/// propia implementación sino contra `Security`: `SecCertificateCreateWithData` solo acepta DER X.509
/// bien formado, y `SecTrustEvaluateWithError` valida la cadena entera (firma, anclaje, vigencia,
/// coincidencia de host por SAN y ExtendedKeyUsage). Así estos tests no pueden confirmarse a sí mismos.
final class CertificateAuthorityTests: XCTestCase {

    // MARK: - Raíz

    func testRootIsWellFormedSelfSignedCA() async throws {
        let ca = try CertificateAuthority.generate()
        let rootDER = await ca.exportRootCertificateDER()

        let root = try XCTUnwrap(SecCertificateCreateWithData(nil, rootDER as CFData))
        XCTAssertEqual(SecCertificateCopySubjectSummary(root) as String?, "TunnelVision Local CA")
        // Anclada en sí misma valida bajo la política básica: es una CA autofirmada coherente.
        XCTAssertTrue(evaluate([rootDER], anchors: [rootDER], sslHost: nil))
    }

    func testCustomRootNameIsHonored() async throws {
        let config = CertificateAuthority.Configuration(rootCommonName: "Acme Root", rootOrganization: "Acme")
        let ca = try CertificateAuthority.generate(configuration: config)
        let rootDER = await ca.exportRootCertificateDER()
        let root = try XCTUnwrap(SecCertificateCreateWithData(nil, rootDER as CFData))
        XCTAssertEqual(SecCertificateCopySubjectSummary(root) as String?, "Acme Root")
    }

    // MARK: - Cadena leaf → raíz

    func testLeafChainsToRootForItsHost() async throws {
        let ca = try CertificateAuthority.generate()
        let rootDER = await ca.exportRootCertificateDER()
        let leaf = try await ca.mintLeaf(forHost: "example.com")

        XCTAssertNotNil(SecCertificateCreateWithData(nil, leaf.certificateDER as CFData))
        XCTAssertTrue(evaluate([leaf.certificateDER, rootDER], anchors: [rootDER], sslHost: "example.com"))
    }

    func testLeafDoesNotValidateForAnotherHost() async throws {
        let ca = try CertificateAuthority.generate()
        let rootDER = await ca.exportRootCertificateDER()
        let leaf = try await ca.mintLeaf(forHost: "example.com")

        // El SAN cubre example.com, no otra.com: la política SSL debe rechazar el host equivocado.
        XCTAssertFalse(evaluate([leaf.certificateDER, rootDER], anchors: [rootDER], sslHost: "other.com"))
    }

    func testLeafDoesNotValidateUnderADifferentRoot() async throws {
        let ca = try CertificateAuthority.generate()
        let other = try CertificateAuthority.generate()
        let leaf = try await ca.mintLeaf(forHost: "example.com")
        let foreignRoot = await other.exportRootCertificateDER()

        // Anclado a una raíz distinta de la que firmó el leaf: no hay cadena de confianza.
        XCTAssertFalse(evaluate([leaf.certificateDER], anchors: [foreignRoot], sslHost: "example.com"))
    }

    func testExtraDNSSANValidatesForThatName() async throws {
        let ca = try CertificateAuthority.generate()
        let rootDER = await ca.exportRootCertificateDER()
        let leaf = try await ca.mintLeaf(forHost: "example.com", sans: ["www.example.com"])

        XCTAssertTrue(evaluate([leaf.certificateDER, rootDER], anchors: [rootDER], sslHost: "www.example.com"))
        // Y sigue valiendo para el host principal.
        XCTAssertTrue(evaluate([leaf.certificateDER, rootDER], anchors: [rootDER], sslHost: "example.com"))
    }

    func testIPLiteralSANValidatesForThatAddress() async throws {
        let ca = try CertificateAuthority.generate()
        let rootDER = await ca.exportRootCertificateDER()
        // Un host que es una IP literal se codifica como iPAddress, no dNSName; la política SSL contra
        // esa misma IP debe validar.
        let leaf = try await ca.mintLeaf(forHost: "10.0.0.5")

        XCTAssertTrue(evaluate([leaf.certificateDER, rootDER], anchors: [rootDER], sslHost: "10.0.0.5"))
    }

    // MARK: - Vigencia

    func testExpiredLeafFailsValidation() async throws {
        // Reloj fijo: el leaf vive 90 días; verificar 120 días después debe caducar la cadena.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let ca = try CertificateAuthority.generate(now: { base })
        let rootDER = await ca.exportRootCertificateDER()
        let leaf = try await ca.mintLeaf(forHost: "example.com")

        let withinValidity = base.addingTimeInterval(1 * 24 * 3600)
        let afterExpiry = base.addingTimeInterval(120 * 24 * 3600)
        XCTAssertTrue(evaluate([leaf.certificateDER, rootDER], anchors: [rootDER], sslHost: "example.com", verifyDate: withinValidity))
        XCTAssertFalse(evaluate([leaf.certificateDER, rootDER], anchors: [rootDER], sslHost: "example.com", verifyDate: afterExpiry))
    }

    // MARK: - Cache y unicidad

    func testMintingIsCachedPerHost() async throws {
        let ca = try CertificateAuthority.generate()
        let first = try await ca.mintLeaf(forHost: "example.com")
        let second = try await ca.mintLeaf(forHost: "EXAMPLE.com")   // mismo host, distinta caja

        XCTAssertEqual(first, second)   // idéntico: no se re-emite

        await ca.clearLeafCache()
        let afterClear = try await ca.mintLeaf(forHost: "example.com")
        XCTAssertNotEqual(first.certificateDER, afterClear.certificateDER)   // tras limpiar, nuevo leaf
    }

    func testDistinctHostsHaveDistinctKeysAndSerials() async throws {
        let ca = try CertificateAuthority.generate()
        let a = try await ca.mintLeaf(forHost: "a.example.com")
        let b = try await ca.mintLeaf(forHost: "b.example.com")

        XCTAssertNotEqual(a.certificateDER, b.certificateDER)
        XCTAssertNotEqual(a.privateKeyDER, b.privateKeyDER)   // cada leaf tiene su propia clave
    }

    func testEmptyHostIsRejected() async throws {
        let ca = try CertificateAuthority.generate()
        do {
            _ = try await ca.mintLeaf(forHost: "   ")
            XCTFail("un host vacío debería lanzar")
        } catch CertificateAuthorityError.invalidHost {
            // esperado
        }
    }

    // MARK: - Reconstrucción desde una clave persistida (costura de `LocalCA`)

    func testMakeFromExistingKeyReproducesAWorkingCA() async throws {
        // La cáscara de Keychain persiste solo la clave raíz y reconstruye la CA con `make(rootKey:)`.
        let rootKey = P256.Signing.PrivateKey()
        let ca = try CertificateAuthority.make(rootKey: rootKey)
        let rootDER = await ca.exportRootCertificateDER()
        let leaf = try await ca.mintLeaf(forHost: "example.com")

        XCTAssertNotNil(SecCertificateCreateWithData(nil, rootDER as CFData))
        XCTAssertTrue(evaluate([leaf.certificateDER, rootDER], anchors: [rootDER], sslHost: "example.com"))
    }

    func testLeafFromReloadedCAValidatesAgainstOriginallyInstalledRoot() async throws {
        // Invariante que sostiene la persistencia solo-clave: el usuario instala el certificado raíz de
        // una CA (`ca1`); al relanzar, la extensión reconstruye la CA desde la misma clave (`ca2`, con un
        // certificado raíz de serie distinta). Un leaf emitido por la CA recargada debe seguir anclando
        // al certificado que el usuario instaló, porque la confianza empareja por sujeto + clave pública,
        // no por serie.
        let rootKey = P256.Signing.PrivateKey()
        let ca1 = try CertificateAuthority.make(rootKey: rootKey)
        let installedRoot = await ca1.exportRootCertificateDER()

        let ca2 = try CertificateAuthority.make(rootKey: rootKey)
        let reloadedRoot = await ca2.exportRootCertificateDER()
        let leaf = try await ca2.mintLeaf(forHost: "example.com")

        // Misma identidad de CA, distinto certificado (serie aleatoria).
        XCTAssertEqual(
            SecCertificateCopySubjectSummary(SecCertificateCreateWithData(nil, installedRoot as CFData)!) as String?,
            SecCertificateCopySubjectSummary(SecCertificateCreateWithData(nil, reloadedRoot as CFData)!) as String?
        )
        XCTAssertNotEqual(installedRoot, reloadedRoot)

        // El leaf de la CA recargada valida contra el certificado raíz originalmente instalado.
        XCTAssertTrue(evaluate([leaf.certificateDER], anchors: [installedRoot], sslHost: "example.com"))
    }

    // MARK: - Verificación con Security

    /// Evalúa una cadena de certificados DER contra un conjunto de anclas. Con `sslHost` usa la
    /// política TLS de servidor (valida host por SAN, vigencia y EKU); sin él, la política básica.
    private func evaluate(
        _ chain: [Data],
        anchors: [Data],
        sslHost: String?,
        verifyDate: Date? = nil
    ) -> Bool {
        let certs = chain.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard certs.count == chain.count else { return false }

        let policy: SecPolicy = sslHost.map { SecPolicyCreateSSL(true, $0 as CFString) }
            ?? SecPolicyCreateBasicX509()

        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certs as CFArray, policy, &trust) == errSecSuccess,
              let trust else { return false }

        let anchorCerts = anchors.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard anchorCerts.count == anchors.count else { return false }
        guard SecTrustSetAnchorCertificates(trust, anchorCerts as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else { return false }
        if let verifyDate {
            guard SecTrustSetVerifyDate(trust, verifyDate as CFDate) == errSecSuccess else { return false }
        }

        return SecTrustEvaluateWithError(trust, nil)
    }
}
