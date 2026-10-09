import Foundation
import Shared
import XCTest

/// Tests de `flows.csv`: que cada fila tiene las columnas de la cabecera, que lo que eligió el
/// otro extremo no rompe el fichero ni se ejecuta en una hoja de cálculo, y qué se aplana.
final class EvidenceFlowsCSVTests: XCTestCase {

    private typealias Fixtures = FindingFixtures

    /// Las filas de un documento, sin la cabecera, ya partidas en celdas. Parte por comas sin
    /// mirar comillas: solo vale para filas que no llevan ninguna celda entrecomillada.
    private func plainRows(_ flows: [EvidenceFlow]) throws -> [[String: String]] {
        let text = try XCTUnwrap(String(data: EvidenceFlowsCSV.document(flows), encoding: .utf8))
        let lines = text.components(separatedBy: "\r\n")
        XCTAssertEqual(lines.last, "")
        XCTAssertEqual(lines.first, EvidenceFlowsCSV.headers.joined(separator: ","))
        return lines.dropFirst().dropLast().map { line in
            let cells = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(cells.count, EvidenceFlowsCSV.headers.count, line)
            return Dictionary(uniqueKeysWithValues: zip(EvidenceFlowsCSV.headers, cells))
        }
    }

    private func csvLine(of flow: StoredFlow, findingIDs: [String] = []) throws -> String {
        let data = EvidenceFlowsCSV.document([EvidenceFlow(flow, findingIDs: findingIDs)])
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        return try XCTUnwrap(text.components(separatedBy: "\r\n").dropFirst().first)
    }

    func testTheHeadersAreUniqueAndADocumentWithNoFlowsIsOnlyTheHeader() throws {
        XCTAssertEqual(Set(EvidenceFlowsCSV.headers).count, EvidenceFlowsCSV.headers.count)
        XCTAssertEqual(EvidenceFlowsCSV.headers.first, "id")
        XCTAssertEqual(EvidenceFlowsCSV.headers.last, "finding_ids")

        let text = String(data: EvidenceFlowsCSV.document([]), encoding: .utf8)
        XCTAssertEqual(text, EvidenceFlowsCSV.headers.joined(separator: ",") + "\r\n")
    }

    func testAFlowIsOneRowWithItsReadingsFlattened() throws {
        let flow = Fixtures.flow(
            id: 12,
            sni: "api.example.com",
            serverTLS: Fixtures.negotiated(.tls12),
            clientTLS: ClientTLSOffer(
                versions: .listed([.tls13, .tls12, TLSProtocolVersion(rawValue: 0x7F1C)]),
                applicationProtocols: ["h2", "http/1.1"],
                omittedApplicationProtocols: 0,
                hasEncryptedClientHello: false
            ),
            streamOpening: .tlsHandshake
        )
        let row = try XCTUnwrap(try plainRows([EvidenceFlow(flow, findingIDs: ["F1", "F3"])]).first)

        XCTAssertEqual(row["id"], "12")
        XCTAssertEqual(row["protocol"], "tcp")
        XCTAssertEqual(row["peer_a_address"], "10.7.0.2")
        XCTAssertEqual(row["peer_a_port"], "50000")
        XCTAssertEqual(row["peer_b_address"], "203.0.113.9")
        XCTAssertEqual(row["peer_b_port"], "443")
        XCTAssertEqual(row["first_seen"], "2026-09-21T14:13:32.000Z")
        XCTAssertEqual(row["bytes_out"], "900")
        XCTAssertEqual(row["bytes_in"], "4200")
        XCTAssertEqual(row["packet_count"], "12")
        XCTAssertEqual(row["tls_status"], "encrypted")
        XCTAssertEqual(row["name"], "api.example.com")
        XCTAssertEqual(row["name_origin"], "sni")
        XCTAssertEqual(row["dns_name"], "")
        XCTAssertEqual(row["stream_opening"], "tlsHandshake")
        XCTAssertEqual(row["offered_versions_form"], "listed")
        XCTAssertEqual(row["offered_versions"], "TLS1.3 TLS1.2 0x7F1C")
        XCTAssertEqual(row["offered_alpn"], "h2 http/1.1")
        XCTAssertEqual(row["encrypted_client_hello"], "false")
        XCTAssertEqual(row["server_answer"], "negotiated")
        XCTAssertEqual(row["tls_version"], "TLS1.2")
        XCTAssertEqual(row["tls_version_source"], "serverHello")
        XCTAssertEqual(row["tls_cipher_suite"], "0xC02F")
        XCTAssertEqual(row["tls_alert"], "")
        XCTAssertEqual(row["quic_version"], "")
        XCTAssertEqual(row["certificate_visibility"], "notRead")
        XCTAssertEqual(row["finding_ids"], "F1 F3")
    }

    func testAReadingThatWasNotMadeIsAnEmptyCell() throws {
        let flow = Fixtures.flow(
            id: 1,
            proto: .udp,
            sni: nil,
            resolvedName: ResolvedFlowName(name: "cdn.example.net", otherNames: ["a.example.net", "b.example.net"]),
            quic: QUICVersionReading(version: .v1, source: .client)
        )
        let row = try XCTUnwrap(try plainRows([EvidenceFlow(flow, findingIDs: [])]).first)

        XCTAssertEqual(row["sni"], "")
        XCTAssertEqual(row["name_origin"], "dns")
        XCTAssertEqual(row["dns_other_names"], "a.example.net b.example.net")
        XCTAssertEqual(row["stream_opening"], "")
        XCTAssertEqual(row["offered_versions_form"], "")
        XCTAssertEqual(row["encrypted_client_hello"], "")
        XCTAssertEqual(row["server_answer"], "")
        XCTAssertEqual(row["quic_version"], "0x00000001")
        XCTAssertEqual(row["quic_version_source"], "client")
        XCTAssertEqual(row["finding_ids"], "")
    }

    func testOneRowPerFlowInTheOrderGiven() throws {
        let rows = try plainRows([3, 1, 2].map { EvidenceFlow(Fixtures.flow(id: $0), findingIDs: []) })
        XCTAssertEqual(rows.map { $0["id"] }, ["3", "1", "2"])
    }

    func testACellWithACommaAQuoteOrANewlineIsQuoted() throws {
        let base = Fixtures.flow(id: 1, serverTLS: Fixtures.negotiated(.tls12))
        let flow = StoredFlow(
            id: 1, key: base.key, firstSeen: base.firstSeen, lastSeen: base.lastSeen,
            bytesOut: 1, bytesIn: 1, packetCount: 2, tlsStatus: .encrypted, sni: "api.example.com",
            resolvedName: nil, serverTLS: base.serverTLS,
            serverCertificates: .chain(ServerCertificateChain(
                certificates: [ServerCertificate(
                    subject: CertificateName(text: "CN=api.example.com,O=Example \"Health\" GmbH", isTruncated: false),
                    issuer: CertificateName(text: "CN=Line\nBreak", isTruncated: false),
                    notAfter: base.firstSeen
                )],
                isComplete: true
            )),
            clientTLS: nil, quic: nil, streamOpening: nil
        )
        let line = try csvLine(of: flow)

        XCTAssertTrue(line.contains(",presented,\"CN=api.example.com,O=Example \"\"Health\"\" GmbH\",\"CN=Line\nBreak\","))
    }

    func testACellThatASpreadsheetWouldRunAsAFormulaIsNeutralised() throws {
        for dangerous in ["=HYPERLINK(1)", "+1", "-1", "@SUM(A1)"] {
            let line = try csvLine(of: Fixtures.flow(id: 1, sni: dangerous))
            // Dos veces: en `name` y en `sni`.
            XCTAssertTrue(line.contains(",'\(dangerous),sni,'\(dangerous),"), dangerous)
        }
        // Un nombre corriente no se toca.
        XCTAssertTrue(try csvLine(of: Fixtures.flow(id: 1, sni: "a-b.example.com")).contains(",a-b.example.com,sni,"))
    }
}
