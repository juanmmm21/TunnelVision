import Foundation
import XCTest

/// Tests del perfil de configuración con el que se le entrega a iOS el certificado raíz (M10).
///
/// Lo que se afirma es lo que iOS va a leer: que el payload sea el de un **ancla de confianza** y no
/// el de un certificado cualquiera, que el DER llegue byte a byte, que el perfil se pueda quitar y que
/// dos perfiles de dos raíces distintas sigan siendo **el mismo perfil** para el sistema — que es lo
/// que hace que rehacer la CA reemplace el ancla anterior en vez de dejar dos instaladas.
final class CertificateProfileTests: XCTestCase {

    /// Un DER de mentira: aquí no se está probando criptografía, se está probando el sobre. Que dentro
    /// vaya un certificado de verdad lo prueban los tests de `CertificateAuthority`.
    private let der = Data([0x30, 0x82, 0x01, 0x0A, 0x02, 0x01, 0x07, 0xFF, 0x00, 0x10])

    private func plist(_ profile: ConfigurationProfile) throws -> [String: Any] {
        let object = try PropertyListSerialization.propertyList(from: profile.data, options: [], format: nil)
        return try XCTUnwrap(object as? [String: Any])
    }

    private func certificatePayload(_ profile: ConfigurationProfile) throws -> [String: Any] {
        let content = try XCTUnwrap(plist(profile)["PayloadContent"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1, "el perfil lleva un único payload: el ancla")
        return try XCTUnwrap(content.first)
    }

    // MARK: - El perfil

    func testTheProfileIsAnXMLPropertyListNamedAsAProfile() throws {
        let profile = try CertificateProfile.make(rootCertificateDER: der)

        XCTAssertEqual(profile.fileName, "TunnelVision.mobileconfig")
        XCTAssertTrue(profile.fileName.hasSuffix(".mobileconfig"), "la extensión es lo que hace que iOS lo trate como perfil")
        XCTAssertTrue(String(decoding: profile.data.prefix(5), as: UTF8.self).hasPrefix("<?xml"))
        XCTAssertEqual(try plist(profile)["PayloadType"] as? String, "Configuration")
        XCTAssertEqual(try plist(profile)["PayloadVersion"] as? Int, 1)
    }

    /// El payload es el de una **raíz de confianza**. Un `com.apple.security.pkcs1` cualquiera
    /// instalaría el certificado sin ofrecerlo como ancla, y el paso 3 (confianza plena) no tendría
    /// nada que activar.
    func testThePayloadIsATrustAnchorAndCarriesTheCertificateVerbatim() throws {
        let profile = try CertificateProfile.make(rootCertificateDER: der)
        let payload = try certificatePayload(profile)

        XCTAssertEqual(payload["PayloadType"] as? String, "com.apple.security.root")
        XCTAssertEqual(payload["PayloadContent"] as? Data, der, "el DER viaja intacto")
        XCTAssertEqual(payload["PayloadCertificateFileName"] as? String, "TunnelVision.cer")
    }

    /// Que el usuario pueda quitar el perfil se declara **explícitamente**, no por omisión: es la
    /// mitad de la reversibilidad que no vive en el llavero.
    func testTheProfileDeclaresItselfRemovable() throws {
        let profile = try CertificateProfile.make(rootCertificateDER: der)
        let removalDisallowed = try XCTUnwrap(
            plist(profile)["PayloadRemovalDisallowed"] as? Bool,
            "la clave tiene que estar puesta, no ausente"
        )

        XCTAssertFalse(removalDisallowed)
    }

    /// Lo que el usuario lee **fuera** de la app, en la hoja de instalación de iOS, donde ya no hay
    /// nada nuestro que se lo explique: tiene que decir de quién es y qué hace.
    func testTheProfileExplainsItselfWhereTheAppCannot() throws {
        let profile = try CertificateProfile.make(rootCertificateDER: der)
        let root = try plist(profile)
        let name = try XCTUnwrap(root["PayloadDisplayName"] as? String)
        let description = try XCTUnwrap(root["PayloadDescription"] as? String)

        XCTAssertTrue(name.contains("TunnelVision"))
        XCTAssertTrue(description.lowercased().contains("never leaves"), description)
        XCTAssertTrue(description.lowercased().contains("pin"), "los pinneados siguen privados, y se dice aquí también")
        XCTAssertTrue(description.lowercased().contains("remove"), "la salida se nombra en el propio perfil")
        XCTAssertEqual(try certificatePayload(profile)["PayloadDisplayName"] as? String, name)
    }

    // MARK: - La identidad del perfil

    /// El mismo certificado da el mismo fichero: no hay UUIDs aleatorios ni fechas dentro. Sin esto,
    /// preparar el perfil dos veces daría dos ficheros distintos para la misma raíz.
    func testTheProfileIsDeterministic() throws {
        let first = try CertificateProfile.make(rootCertificateDER: der)
        let second = try CertificateProfile.make(rootCertificateDER: der)

        XCTAssertEqual(first.data, second.data)
    }

    /// Y **dos raíces distintas siguen siendo el mismo perfil** para iOS. Es lo que hace que rehacer la
    /// CA reemplace el ancla instalada en vez de añadir una segunda al lado, que el usuario no tendría
    /// forma de distinguir ni motivo para sospechar.
    func testTwoDifferentRootsShareTheProfileIdentity() throws {
        let first = try CertificateProfile.make(rootCertificateDER: der)
        let second = try CertificateProfile.make(rootCertificateDER: Data([0x30, 0x03, 0x02, 0x01, 0x01]))

        XCTAssertNotEqual(first.data, second.data, "el certificado sí cambia")
        XCTAssertEqual(try plist(first)["PayloadIdentifier"] as? String, try plist(second)["PayloadIdentifier"] as? String)
        XCTAssertEqual(try plist(first)["PayloadUUID"] as? String, try plist(second)["PayloadUUID"] as? String)
        XCTAssertEqual(
            try certificatePayload(first)["PayloadUUID"] as? String,
            try certificatePayload(second)["PayloadUUID"] as? String
        )
    }

    /// Un perfil con un ancla vacía se instalaría igual y no anclaría nada: el usuario haría los tres
    /// pasos y seguiría sin poder encender la inspección, sin nada que se lo explicase.
    func testAnEmptyCertificateIsRefusedInsteadOfWrapped() {
        XCTAssertThrowsError(try CertificateProfile.make(rootCertificateDER: Data())) { error in
            XCTAssertEqual(error as? CertificateProfileError, .emptyCertificate)
        }
    }

    // MARK: - El escritor

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CertificateProfileTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testWritingLeavesExactlyTheProfileOnDisk() async throws {
        let directory = try temporaryDirectory()
        let exporter = CertificateProfileExporter(directory: directory)
        let profile = try CertificateProfile.make(rootCertificateDER: der)

        let url = try await exporter.write(profile)

        XCTAssertEqual(url.lastPathComponent, profile.fileName)
        XCTAssertEqual(try Data(contentsOf: url), profile.data)
    }

    /// Escribir dos veces deja **un** fichero, no dos: el nombre es fijo a propósito, así que la
    /// segunda escritura sustituye a la primera y no acumula copias de un ancla en el temporal.
    func testWritingTwiceKeepsOneFile() async throws {
        let directory = try temporaryDirectory()
        let exporter = CertificateProfileExporter(directory: directory)

        _ = try await exporter.write(try CertificateProfile.make(rootCertificateDER: der))
        let second = try await exporter.write(try CertificateProfile.make(rootCertificateDER: Data([0x30, 0x01, 0x02])))

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(try Data(contentsOf: second), try CertificateProfile.make(rootCertificateDER: Data([0x30, 0x01, 0x02])).data)
    }

    /// Tirar el perfil es lo que hace el flujo cuando la CA cambia: compartir el de una raíz que ya no
    /// existe instalaría un ancla que no firma nada.
    func testDiscardRemovesTheProfile() async throws {
        let directory = try temporaryDirectory()
        let exporter = CertificateProfileExporter(directory: directory)
        let url = try await exporter.write(try CertificateProfile.make(rootCertificateDER: der))

        await exporter.discard()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// Y tirarlo cuando no hay nada que tirar no es un fallo: es el caso normal la primera vez.
    func testDiscardWithoutAProfileIsSilent() async throws {
        let exporter = CertificateProfileExporter(directory: try temporaryDirectory())

        await exporter.discard()
    }

    /// El único fallo que este actor puede tener por sí solo. Se resuelve el directorio **en cada
    /// escritura**, así que llega tipado y no como un `nil` que la pantalla tendría que interpretar.
    func testAnUnresolvableDirectoryFailsAsAWriteFailure() async throws {
        let exporter = CertificateProfileExporter(resolvingDirectory: {
            throw CertificateProfileError.writeFailed("no container")
        })

        do {
            _ = try await exporter.write(try CertificateProfile.make(rootCertificateDER: der))
            XCTFail("un directorio irresoluble no puede pasar por una escritura correcta")
        } catch let error as CertificateProfileError {
            guard case .writeFailed = error else {
                return XCTFail("se esperaba writeFailed, llegó \(error)")
            }
        }
    }
}
