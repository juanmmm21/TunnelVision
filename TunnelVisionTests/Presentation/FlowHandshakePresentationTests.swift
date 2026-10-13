import Foundation
import XCTest
@testable import Shared

/// Lo que la ficha de una conexión dice de su handshake.
///
/// Cada dato de esa sección es una lectura con dueño —del servidor, del túnel, de la app— y lo
/// que aquí se afirma es que la pantalla no le cambia el dueño a ninguna: una versión negociada
/// por el túnel no se enseña como la de la app, un techo no se redacta como lista, y un
/// certificado se enseña diciendo que nadie lo validó.
final class FlowHandshakePresentationTests: XCTestCase {

    private func flow(
        proto: IPProtocolNumber = .tcp,
        tlsStatus: TLSInspectionStatus = .encrypted,
        serverTLS: ServerTLSAnswer? = nil,
        serverCertificates: ServerCertificateReading? = nil,
        clientTLS: ClientTLSOffer? = nil,
        quic: QUICVersionReading? = nil
    ) -> HistoryFlow {
        let local = IPEndpoint(address: HistoryFixtures.deviceIPv4, port: 50_000)
        let remote = IPEndpoint(address: HistoryFixtures.remote(34), port: 443)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        return HistoryFlow(
            StoredFlow(
                id: 1,
                key: FlowKey(proto: proto, source: local, destination: remote),
                firstSeen: start,
                lastSeen: start.addingTimeInterval(1),
                bytesOut: 900,
                bytesIn: 4_200,
                packetCount: 12,
                tlsStatus: tlsStatus,
                sni: "api.example.com",
                resolvedName: nil,
                serverTLS: serverTLS,
                serverCertificates: serverCertificates,
                clientTLS: clientTLS,
                quic: quic,
                streamOpening: proto == .tcp ? .tlsHandshake : nil
            ),
            localAddresses: HistoryFixtures.localAddresses
        )
    }

    private func negotiated(
        _ version: TLSProtocolVersion, source: TLSAnswerSource = .serverHello
    ) -> ServerTLSAnswer {
        .negotiated(NegotiatedTLS(
            version: version,
            cipherSuite: TLSCipherSuite(rawValue: 0x1301),
            fromHelloRetryRequest: false,
            source: source
        ))
    }

    private func offer(
        _ versions: OfferedTLSVersions,
        protocols: [String] = ["h2", "http/1.1"],
        encryptedClientHello: Bool = false
    ) -> ClientTLSOffer {
        ClientTLSOffer(
            versions: versions,
            applicationProtocols: protocols,
            omittedApplicationProtocols: 0,
            hasEncryptedClientHello: encryptedClientHello
        )
    }

    private func values(_ section: FlowHandshakeSection?) -> [String: String] {
        var result: [String: String] = [:]
        for fact in section?.facts ?? [] {
            if case .text(let text) = fact.value { result[fact.id] = text }
        }
        return result
    }

    // MARK: - Cuándo hay sección

    /// Un flujo del que no se leyó nada de esto no tiene sección: una rejilla de «no leído» en
    /// cada ping sería ruido en la mayoría de las fichas.
    func testAConnectionWithNothingReadHasNoSection() {
        XCTAssertNil(FlowHandshakePresentation.section(for: flow()))
        XCTAssertNil(FlowHandshakePresentation.section(for: flow(proto: .icmp)))
    }

    /// La rejilla es de dos columnas: salga lo que salga, los datos entran de dos en dos.
    func testFactsAlwaysComeInPairs() {
        let chain = ServerCertificateReading.chain(ServerCertificateChain(
            certificates: [certificate("CN=api.example.com", issuer: "CN=Example CA")], isComplete: true
        ))
        let cases = [
            flow(serverTLS: negotiated(.tls13)),
            flow(clientTLS: offer(.listed([.tls13]))),
            flow(serverTLS: negotiated(.tls12), serverCertificates: chain, clientTLS: offer(.upTo(.tls12))),
            flow(serverTLS: .refused(alert: 70)),
            flow(proto: .udp, clientTLS: offer(.listed([.tls13]), protocols: ["h3"]),
                 quic: QUICVersionReading(version: .v1, source: .server)),
        ]
        for flow in cases {
            let section = FlowHandshakePresentation.section(for: flow)
            XCTAssertNotNil(section)
            XCTAssertTrue(section?.facts.count.isMultiple(of: 2) ?? false)
            XCTAssertEqual(Set(section?.facts.map(\.id) ?? []).count, section?.facts.count, "ids repetidos")
        }
    }

    // MARK: - La respuesta del servidor

    func testTheNegotiatedVersionIsNamedAndSaysWhereItWasRead() {
        let section = FlowHandshakePresentation.section(for: flow(serverTLS: negotiated(.tls13)))
        XCTAssertEqual(values(section)["tlsVersion"], "TLS 1.3")
        XCTAssertEqual(values(section)["tlsSource"], "Server's answer")
    }

    /// Lo que el túnel negoció con el servidor no es lo que negoció la app, y la ficha lo dice en
    /// los dos sitios: en el origen de la lectura y en una frase debajo.
    func testAnUpstreamReadingIsNeverShownAsTheApps() throws {
        for status in [TLSInspectionStatus.inspected, .notInspectable] {
            let section = try XCTUnwrap(FlowHandshakePresentation.section(
                for: flow(tlsStatus: status, serverTLS: negotiated(.tls13, source: .upstreamConnection))
            ))
            XCTAssertEqual(values(section)["tlsSource"], "Tunnel's connection")
            XCTAssertTrue(section.notes.contains { $0.contains("not with the app") })
        }
        let own = try XCTUnwrap(FlowHandshakePresentation.section(for: flow(serverTLS: negotiated(.tls13))))
        XCTAssertFalse(own.notes.contains { $0.contains("not with the app") })
    }

    func testARefusalIsShownWithItsAlert() {
        let section = FlowHandshakePresentation.section(for: flow(serverTLS: .refused(alert: 70)))
        XCTAssertEqual(values(section)["tlsVersion"], "Refused (alert 70)")
    }

    /// Un valor que no es una versión publicada se enseña como viajó: es evidencia, y colapsarlo
    /// en «desconocida» perdería el número.
    func testAnUnpublishedVersionIsShownByItsNumber() {
        XCTAssertEqual(FlowHandshakePresentation.name(of: TLSProtocolVersion(rawValue: 0x7F1C)), "0x7F1C")
        XCTAssertEqual(FlowHandshakePresentation.name(of: .ssl30), "SSL 3.0")
        XCTAssertEqual(FlowHandshakePresentation.name(of: .tls10), "TLS 1.0")
        XCTAssertEqual(FlowHandshakePresentation.name(of: .tls11), "TLS 1.1")
        XCTAssertEqual(FlowHandshakePresentation.name(of: .tls12), "TLS 1.2")
    }

    // MARK: - La oferta de la app

    func testAListedOfferIsAListInTheAppsOrder() {
        let section = FlowHandshakePresentation.section(
            for: flow(serverTLS: negotiated(.tls13), clientTLS: offer(.listed([.tls13, .tls12])))
        )
        XCTAssertEqual(values(section)["offeredVersions"], "TLS 1.3, TLS 1.2")
        XCTAssertEqual(values(section)["offeredProtocols"], "h2, http/1.1")
    }

    /// Un `legacy_version` es un techo: dice hasta dónde llega el cliente y no qué acepta por
    /// debajo. Redactado como lista de uno afirmaría que la app no habría aceptado menos.
    func testACeilingIsNeverWrittenAsAList() {
        let section = FlowHandshakePresentation.section(
            for: flow(serverTLS: negotiated(.tls10), clientTLS: offer(.upTo(.tls12), protocols: []))
        )
        XCTAssertEqual(values(section)["offeredVersions"], "Up to TLS 1.2")
        XCTAssertEqual(values(section)["offeredProtocols"], "None")
    }

    func testAnEmptyListSaysNothingWasOffered() {
        let section = FlowHandshakePresentation.section(for: flow(clientTLS: offer(.listed([]))))
        XCTAssertEqual(values(section)["offeredVersions"], "None")
    }

    /// Con solo la oferta delante, lo ofrecido se leería como lo acordado.
    func testAnOfferWithoutAnAnswerSaysTheAnswerIsMissing() throws {
        let alone = try XCTUnwrap(FlowHandshakePresentation.section(for: flow(clientTLS: offer(.listed([.tls13])))))
        XCTAssertNil(values(alone)["tlsVersion"])
        XCTAssertTrue(alone.notes.contains { $0.contains("answer was not read") })

        let answered = try XCTUnwrap(FlowHandshakePresentation.section(
            for: flow(serverTLS: negotiated(.tls13), clientTLS: offer(.listed([.tls13])))
        ))
        XCTAssertFalse(answered.notes.contains { $0.contains("answer was not read") })
    }

    func testAnEncryptedClientHelloIsFlagged() throws {
        let section = try XCTUnwrap(FlowHandshakePresentation.section(
            for: flow(
                serverTLS: negotiated(.tls13),
                clientTLS: offer(.listed([.tls13]), encryptedClientHello: true)
            )
        ))
        XCTAssertTrue(section.notes.contains { $0.contains("outer offer") })
    }

    // MARK: - QUIC

    /// En QUIC la lectura es la versión de QUIC, no una de TLS: no hay ServerHello que leer.
    func testAQUICConnectionShowsItsQUICVersionAndWhoSaidIt() throws {
        let confirmed = try XCTUnwrap(FlowHandshakePresentation.section(
            for: flow(proto: .udp, clientTLS: offer(.listed([.tls13]), protocols: ["h3"]),
                      quic: QUICVersionReading(version: .v1, source: .server))
        ))
        XCTAssertEqual(values(confirmed)["quicVersion"], "Version 1")
        XCTAssertEqual(values(confirmed)["quicSource"], "Server's packets")
        XCTAssertEqual(values(confirmed)["offeredProtocols"], "h3")
        XCTAssertNil(values(confirmed)["tlsVersion"])
        XCTAssertTrue(confirmed.notes.contains { $0.contains("TLS 1.3") })
        // La frase de QUIC ya dice que la respuesta va cifrada: la de «no se leyó» sobraría.
        XCTAssertFalse(confirmed.notes.contains { $0.contains("answer was not read") })
    }

    /// Lo que solo dijo el cliente es una propuesta, y no se afirma que sea la versión en uso.
    func testAQUICVersionOnlyTheAppSentIsAProposal() throws {
        let section = try XCTUnwrap(FlowHandshakePresentation.section(
            for: flow(proto: .udp, quic: QUICVersionReading(version: .v2, source: .client))
        ))
        XCTAssertEqual(values(section)["quicVersion"], "Version 2")
        XCTAssertEqual(values(section)["quicSource"], "App's packets")
        XCTAssertTrue(section.notes.contains { $0.contains("proposed") })
        XCTAssertFalse(section.notes.contains { $0.contains("encrypts every packet") })
    }

    /// De una versión que no se conoce no se dice que cifre: es justo lo que una auditoría busca.
    func testAnUnknownQUICVersionClaimsNothingAboutEncryption() throws {
        let section = try XCTUnwrap(FlowHandshakePresentation.section(
            for: flow(proto: .udp, quic: QUICVersionReading(version: QUICVersion(rawValue: 0xFACE_B00C), source: .server))
        ))
        XCTAssertEqual(values(section)["quicVersion"], "0xFACEB00C")
        XCTAssertFalse(section.notes.contains { $0.contains("TLS 1.3") })
        XCTAssertTrue(section.notes.contains { $0.contains("states nothing") })
    }

    // MARK: - El certificado

    private func certificate(_ subject: String, issuer: String) -> ServerCertificate {
        ServerCertificate(
            subject: CertificateName(text: subject, isTruncated: false),
            issuer: CertificateName(text: issuer, isTruncated: false),
            notAfter: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    /// Se enseña el primero de la cadena —el del servidor—, con su emisor y dicho sin rodeos que
    /// no se validó: un sujeto y una fecha en pantalla se leen como «el certificado es bueno».
    func testAPresentedCertificateShowsItsLeafAndSaysNothingWasValidated() throws {
        let chain = ServerCertificateChain(
            certificates: [
                certificate("CN=api.example.com", issuer: "CN=Example Issuing CA"),
                certificate("CN=Example Issuing CA", issuer: "CN=Example Root CA"),
            ],
            isComplete: true
        )
        let section = try XCTUnwrap(FlowHandshakePresentation.section(
            for: flow(serverTLS: negotiated(.tls12), serverCertificates: .chain(chain))
        ))
        XCTAssertEqual(values(section)["certificateSubject"], "CN=api.example.com")
        XCTAssertNotNil(values(section)["certificateExpiry"])
        let note = try XCTUnwrap(section.notes.first { $0.contains("Issued by") })
        XCTAssertTrue(note.contains("CN=Example Issuing CA"))
        XCTAssertTrue(note.contains("nothing about it was validated"))
    }

    /// Por qué no hay certificado, cuando el motivo es un hecho de la conexión y no una laguna.
    func testEachReasonACertificateIsNotShownHasItsOwnSentence() throws {
        func notes(_ flow: HistoryFlow) throws -> [String] {
            try XCTUnwrap(FlowHandshakePresentation.section(for: flow)).notes
        }
        let encrypted = try notes(flow(serverTLS: negotiated(.tls13)))
        let replaced = try notes(flow(tlsStatus: .inspected, serverTLS: negotiated(.tls13, source: .upstreamConnection)))
        let resumed = try notes(flow(serverTLS: negotiated(.tls12), serverCertificates: .notSent(.resumedSession)))
        let absent = try notes(flow(serverTLS: negotiated(.tls12), serverCertificates: .notSent(.noCertificateMessage)))

        XCTAssertTrue(encrypted.contains { $0.contains("sends the server's certificate encrypted") })
        XCTAssertTrue(replaced.contains { $0.contains("TunnelVision's own") })
        XCTAssertTrue(resumed.contains { $0.contains("resumed") })
        XCTAssertTrue(absent.contains { $0.contains("carried no certificate") })
        XCTAssertEqual(Set([encrypted, replaced, resumed, absent].map { $0.last ?? "" }).count, 4)
    }

    /// Una negativa y una lectura que no se hizo no añaden frase: la primera ya está en la fila
    /// de la versión, y la segunda no es un hecho sobre la conexión.
    func testARefusalAndAMissingReadingAddNoCertificateSentence() throws {
        let refused = try XCTUnwrap(FlowHandshakePresentation.section(for: flow(serverTLS: .refused(alert: 70))))
        XCTAssertTrue(refused.notes.isEmpty)
        let unread = try XCTUnwrap(FlowHandshakePresentation.section(for: flow(serverTLS: negotiated(.tls12))))
        XCTAssertTrue(unread.notes.isEmpty)
    }

    /// Ninguna frase de esta sección dice que algo esté bien: enseña lecturas, no veredictos.
    func testNoSentenceStatesAVerdict() {
        let flows = [
            flow(serverTLS: negotiated(.tls13), clientTLS: offer(.listed([.tls13]))),
            flow(tlsStatus: .inspected, serverTLS: negotiated(.tls13, source: .upstreamConnection)),
            flow(proto: .udp, quic: QUICVersionReading(version: .v1, source: .server)),
        ]
        for flow in flows {
            for note in FlowHandshakePresentation.section(for: flow)?.notes ?? [] {
                for word in ["secure", "safe", "passed", "valid ", "trusted"] {
                    XCTAssertFalse(note.lowercased().contains(word), "«\(word)» en: \(note)")
                }
            }
        }
    }
}
