import Foundation
import XCTest

/// Tests del núcleo puro del estado de la CA local (M10). Aquí no hay llavero ni `SecTrust`: lo que se
/// afirma son las dos reglas que convierten lo que se sabe en lo que se ofrece, y sobre todo que las
/// dudas se resuelven **cerrando** — ni encender la inspección ni regenerar la CA cuando no se pudo
/// mirar, porque las dos equivocaciones se llevan por delante algo que el usuario ya tenía.
final class CertificatePresentationTests: XCTestCase {

    // MARK: - Encender la inspección

    func testOnlyATrustedGeneratedCAAllowsEnabling() {
        XCTAssertEqual(
            CertificateStatusPolicy.availability(CertificateStatus(authority: .generated(.trusted))),
            .ready
        )
    }

    func testGeneratedButNotTrustedCannotEnable() {
        XCTAssertEqual(
            CertificateStatusPolicy.availability(CertificateStatus(authority: .generated(.notTrusted))),
            .certificateNotReady
        )
    }

    func testNoCertificateCannotEnable() {
        XCTAssertEqual(CertificateStatusPolicy.availability(.notGenerated), .certificateNotReady)
    }

    /// La regla que importa: no poder evaluar la confianza **no** se lee como confianza. Encender la
    /// inspección con una raíz que el dispositivo no ancla rompería todos los handshakes contra
    /// nuestro leaf, así que la duda cierra.
    func testTrustThatCannotBeEvaluatedIsNotReadAsTrusted() {
        XCTAssertEqual(
            CertificateStatusPolicy.availability(CertificateStatus(authority: .generated(.cannotEvaluate("sin Security")))),
            .certificateNotReady
        )
    }

    func testAnUnreadableKeychainCannotEnable() {
        XCTAssertEqual(
            CertificateStatusPolicy.availability(CertificateStatus(authority: .unknown("errSecInteractionNotAllowed"))),
            .certificateNotReady
        )
    }

    // MARK: - Ofrecer generar

    func testGenerationIsOfferedOnlyWhenThereIsNoCA() {
        XCTAssertTrue(CertificateStatusPolicy.canGenerate(.notGenerated))
    }

    /// Generar reemplaza la clave raíz anterior, así que ofrecerlo cuando ya hay CA sería ofrecer
    /// invalidar el certificado que el usuario tiene instalado sin decirlo.
    func testGenerationIsNotOfferedWhenACAAlreadyExists() {
        XCTAssertFalse(CertificateStatusPolicy.canGenerate(CertificateStatus(authority: .generated(.trusted))))
        XCTAssertFalse(CertificateStatusPolicy.canGenerate(CertificateStatus(authority: .generated(.notTrusted))))
    }

    /// Y tampoco a ciegas: "no se pudo mirar el llavero" no es "no hay CA".
    func testGenerationIsNotOfferedWhenTheKeychainCouldNotBeRead() {
        XCTAssertFalse(CertificateStatusPolicy.canGenerate(CertificateStatus(authority: .unknown("errSecMissingEntitlement"))))
    }
}
