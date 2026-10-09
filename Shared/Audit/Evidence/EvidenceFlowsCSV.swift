import Foundation

/// `flows.csv`: los mismos flujos de `flows.json`, una fila por flujo, para quien los quiera en
/// una hoja de cálculo. Es una vista **aplanada**: lo que no cabe en una celda (la cadena de
/// certificados entera, los detalles de una oferta) se queda en el JSON, que es el que manda.
public enum EvidenceFlowsCSV {

    /// Una columna: su cabecera y lo que saca de un flujo. Van juntas para que la cabecera y las
    /// filas no puedan desordenarse entre sí.
    private struct Column: Sendable {
        let header: String
        let value: @Sendable (EvidenceFlow) -> String
    }

    private static let columns: [Column] = [
        Column(header: "id") { String($0.id) },
        Column(header: "protocol") { $0.proto },
        Column(header: "peer_a_address") { $0.peers.first?.address ?? "" },
        Column(header: "peer_a_port") { $0.peers.first.map { String($0.port) } ?? "" },
        Column(header: "peer_b_address") { $0.peers.last?.address ?? "" },
        Column(header: "peer_b_port") { $0.peers.last.map { String($0.port) } ?? "" },
        Column(header: "first_seen") { EvidenceBundleFormat.timestamp($0.firstSeen) },
        Column(header: "last_seen") { EvidenceBundleFormat.timestamp($0.lastSeen) },
        Column(header: "bytes_out") { String($0.bytesOut) },
        Column(header: "bytes_in") { String($0.bytesIn) },
        Column(header: "packet_count") { String($0.packetCount) },
        Column(header: "tls_status") { $0.tlsStatus },
        Column(header: "name") { $0.name?.text ?? "" },
        Column(header: "name_origin") { $0.name?.origin ?? "" },
        Column(header: "sni") { $0.sni ?? "" },
        Column(header: "dns_name") { $0.dnsName ?? "" },
        Column(header: "dns_other_names") { list($0.dnsOtherNames) },
        Column(header: "stream_opening") { $0.streamOpening ?? "" },
        Column(header: "offered_versions_form") { $0.clientTLS?.versionsForm ?? "" },
        Column(header: "offered_versions") { list($0.clientTLS?.versions.map(text) ?? []) },
        Column(header: "offered_alpn") { list($0.clientTLS?.applicationProtocols ?? []) },
        Column(header: "encrypted_client_hello") { $0.clientTLS.map { text($0.hasEncryptedClientHello) } ?? "" },
        Column(header: "server_answer") { $0.serverTLS?.answer ?? "" },
        Column(header: "tls_version") { $0.serverTLS?.version.map(text) ?? "" },
        Column(header: "tls_version_source") { $0.serverTLS?.source ?? "" },
        Column(header: "tls_cipher_suite") { $0.serverTLS?.cipherSuite?.hex ?? "" },
        Column(header: "tls_alert") { $0.serverTLS?.alert.map { String($0) } ?? "" },
        Column(header: "quic_version") { $0.quic?.version.hex ?? "" },
        Column(header: "quic_version_source") { $0.quic?.source ?? "" },
        Column(header: "certificate_visibility") { $0.serverCertificate.visibility },
        Column(header: "certificate_subject") { $0.serverCertificate.chain?.first?.subject ?? "" },
        Column(header: "certificate_issuer") { $0.serverCertificate.chain?.first?.issuer ?? "" },
        Column(header: "certificate_not_after") {
            $0.serverCertificate.chain?.first.map { EvidenceBundleFormat.timestamp($0.notAfter) } ?? ""
        },
        Column(header: "finding_ids") { list($0.findingIDs) },
    ]

    public static var headers: [String] { columns.map(\.header) }

    /// El fichero entero: la cabecera y una fila por flujo, en UTF-8 y con CRLF (RFC 4180).
    public static func document(_ flows: [EvidenceFlow]) -> Data {
        var text = row(headers)
        for flow in flows {
            text += row(columns.map { $0.value(flow) })
        }
        return Data(text.utf8)
    }

    private static func row(_ cells: [String]) -> String {
        cells.map(cell).joined(separator: ",") + "\r\n"
    }

    /// Una celda tal como se escribe.
    ///
    /// Casi todo lo que hay aquí lo eligió **el otro extremo** —un SNI, un ALPN, el sujeto de un
    /// certificado— y este fichero se abre en una hoja de cálculo, que ejecuta como fórmula una
    /// celda que empieza por `=`, `+`, `-` o `@`. A una celda así se le antepone un apóstrofo, que
    /// es lo que la hoja entiende como «esto es texto». El valor sin tocar está en `flows.json`.
    static func cell(_ value: String) -> String {
        var text = value
        if let first = text.first, "=+-@\t\r".contains(first) {
            text = "'" + text
        }
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // Varios valores en una celda van separados por un espacio: ninguno de los que entran aquí
    // (nombres de DNS, identificadores de ALPN acotados a ASCII imprimible, ids de hallazgo)
    // lleva espacios dentro, salvo un nombre de versión, y por eso las versiones van por su número.
    private static func list(_ values: [String]) -> String {
        values.joined(separator: " ")
    }

    /// Una versión de TLS en una celda: su nombre sin espacios (`TLS1.2`) o, si no es una versión
    /// publicada, su valor en hexadecimal.
    private static func text(_ version: EvidenceTLSVersion) -> String {
        version.name?.replacingOccurrences(of: " ", with: "")
            ?? "0x" + String(version.wireValue, radix: 16, uppercase: true)
    }

    private static func text(_ flag: Bool) -> String {
        flag ? "true" : "false"
    }
}
