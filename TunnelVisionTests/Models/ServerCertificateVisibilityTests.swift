import Foundation
import Shared
import XCTest

/// Tests de lo que se puede decir del certificado del servidor de un flujo: que cada flujo sin
/// cadena lleva **su motivo**, y que el motivo sale de lo observado y no de una suposición.
final class ServerCertificateVisibilityTests: XCTestCase {

    private func negotiated(_ version: TLSProtocolVersion, source: TLSAnswerSource = .serverHello) -> ServerTLSAnswer {
        .negotiated(NegotiatedTLS(
            version: version, cipherSuite: TLSCipherSuite(rawValue: 0xC02F), fromHelloRetryRequest: false, source: source
        ))
    }

    private static let chain = ServerCertificateChain(certificates: [], isComplete: false)

    func testAReadChainIsPresented() {
        XCTAssertEqual(
            ServerCertificateVisibility(answer: negotiated(.tls12), reading: .chain(Self.chain)),
            .presented(Self.chain)
        )
    }

    func testAHandshakeWithoutCertificateSaysWhy() {
        XCTAssertEqual(
            ServerCertificateVisibility(answer: negotiated(.tls12), reading: .notSent(.resumedSession)),
            .notSent(.resumedSession)
        )
        XCTAssertEqual(
            ServerCertificateVisibility(answer: negotiated(.tls10), reading: .notSent(.noCertificateMessage)),
            .notSent(.noCertificateMessage)
        )
    }

    func testTLS13SaysTheCertificateIsEncrypted() {
        XCTAssertEqual(ServerCertificateVisibility(answer: negotiated(.tls13), reading: nil), .encryptedInHandshake)
    }

    /// Aunque la conexión de subida negociara 1.2: lo que la app recibió es nuestro leaf.
    func testAnInspectedFlowSaysTheCertificateWasReplaced() {
        for version in [TLSProtocolVersion.tls12, .tls13] {
            XCTAssertEqual(
                ServerCertificateVisibility(answer: negotiated(version, source: .upstreamConnection), reading: nil),
                .replacedByInspection
            )
        }
    }

    func testARefusalSaysThereWasNoNegotiation() {
        XCTAssertEqual(ServerCertificateVisibility(answer: .refused(alert: 70), reading: nil), .noNegotiation)
    }

    /// TLS ≤ 1.2 sin lectura no es «cifrado» ni «no enviado»: es que no se llegó a leer.
    func testAClearTextVersionWithoutAReadingIsNotRead() {
        for version in [TLSProtocolVersion.ssl30, .tls10, .tls11, .tls12] {
            XCTAssertEqual(ServerCertificateVisibility(answer: negotiated(version), reading: nil), .notRead)
        }
    }

    func testAnUnknownVersionIsNotAssumedToEncrypt() {
        let draft = TLSProtocolVersion(rawValue: 0x7F1C)
        XCTAssertEqual(ServerCertificateVisibility(answer: negotiated(draft), reading: nil), .notRead)
    }

    func testNoAnswerAndNoReadingIsNotRead() {
        XCTAssertEqual(ServerCertificateVisibility(answer: nil, reading: nil), .notRead)
    }

    /// Una lectura es una observación: manda sobre lo que se deduciría de la respuesta, aunque la
    /// respuesta apuntada sea otra (o aún no haya llegado a la tabla).
    func testAReadingWinsOverWhatTheAnswerWouldImply() {
        for answer in [nil, negotiated(.tls13), negotiated(.tls12, source: .upstreamConnection), .refused(alert: 40)] {
            XCTAssertEqual(
                ServerCertificateVisibility(answer: answer, reading: .chain(Self.chain)),
                .presented(Self.chain)
            )
        }
    }

    // MARK: - Qué versiones mandan el certificado en claro

    func testOnlyVersionsUpToTLS12SendTheCertificateInClear() {
        for version in [TLSProtocolVersion.ssl30, .tls10, .tls11, .tls12] {
            XCTAssertTrue(version.sendsCertificateInClear)
        }
        XCTAssertFalse(TLSProtocolVersion.tls13.sendsCertificateInClear)
        XCTAssertFalse(TLSProtocolVersion(rawValue: 0x0200).sendsCertificateInClear)
        XCTAssertFalse(TLSProtocolVersion(rawValue: 0x0305).sendsCertificateInClear)
        XCTAssertFalse(TLSProtocolVersion(rawValue: 0x7F1C).sendsCertificateInClear)
    }

    // MARK: - Los flujos lo llevan puesto

    func testAFlowAnswersForItsOwnCertificate() {
        let record = HistoryFixtures.record(
            remote: HistoryFixtures.remote(34), firstSeen: 1, lastSeen: 2, serverTLS: negotiated(.tls13)
        )
        XCTAssertEqual(record.certificateVisibility, .encryptedInHandshake)
        let stored = HistoryFixtures.storedFlow(
            serverTLS: negotiated(.tls12), serverCertificates: .notSent(.resumedSession)
        )
        XCTAssertEqual(stored.certificateVisibility, .notSent(.resumedSession))
    }
}
