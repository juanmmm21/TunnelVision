import CryptoKit
import Foundation
import Security
import Shared
import XCTest

extension XCTestCase {

    /// Emite un leaf para `host` bajo una CA recién generada y lo convierte en `SecIdentity`
    /// importándolo al llavero, que es la única forma que tiene iOS de formar el par
    /// clave+certificado. Es lo mismo que hace `LocalCA.mintLeaf`, replicado aquí porque aquello es
    /// privado y porque un test no debe tocar los items de producción: la etiqueta lleva un UUID por
    /// llamada y se borra al acabar el test.
    ///
    /// Vive aparte porque lo necesitan los dos lados de una inspección: la sesión que presenta el
    /// leaf al cliente y el servidor de loopback contra el que se prueba la pata saliente.
    func makeTestTLSIdentity(forHost host: String) async throws -> (identity: SecIdentity, rootDER: Data) {
        let ca = try CertificateAuthority.generate()
        let rootDER = await ca.exportRootCertificateDER()
        let minted = try await ca.mintLeaf(forHost: host, sans: [])

        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, minted.certificateDER as CFData))
        let leafKey = try P256.Signing.PrivateKey(derRepresentation: minted.privateKeyDER)
        var error: Unmanaged<CFError>?
        let secKey = try XCTUnwrap(SecKeyCreateWithData(
            Data(leafKey.x963Representation) as CFData,
            [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                kSecAttrKeySizeInBits as String: 256,
            ] as CFDictionary,
            &error
        ))

        let label = "tests.tunnelvision.leaf.\(UUID().uuidString)"
        let keyStatus = SecItemAdd([
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrLabel as String: label,
            kSecValueRef as String: secKey,
        ] as CFDictionary, nil)
        XCTAssertEqual(keyStatus, errSecSuccess, "importar la clave del leaf")
        let certStatus = SecItemAdd([
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: label,
            kSecValueRef as String: certificate,
        ] as CFDictionary, nil)
        XCTAssertEqual(certStatus, errSecSuccess, "importar el certificado del leaf")
        addTeardownBlock {
            SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrLabel as String: label] as CFDictionary)
            SecItemDelete([kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: label] as CFDictionary)
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
        ] as CFDictionary, &item)
        XCTAssertEqual(status, errSecSuccess, "formar el SecIdentity")
        return (try XCTUnwrap(item as! SecIdentity?), rootDER)
    }
}
