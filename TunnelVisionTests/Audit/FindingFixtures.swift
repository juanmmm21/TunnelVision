import Foundation
import Shared

/// Flujos guardados a medida para los tests del clasificador: cada test dice solo lo que le
/// importa del flujo, y lo demás es un TCP contra el 443 sin ninguna lectura, con un nombre
/// anunciado para que los tests que no van de nombres no levanten `unnamedFlow`.
enum FindingFixtures {

    static let start = Date(timeIntervalSince1970: 1_790_000_000)

    static func flow(
        id: Int64,
        proto: IPProtocolNumber = .tcp,
        remotePort: UInt16 = 443,
        tlsStatus: TLSInspectionStatus = .encrypted,
        sni: String? = "api.example.com",
        resolvedName: ResolvedFlowName? = nil,
        serverTLS: ServerTLSAnswer? = nil,
        clientTLS: ClientTLSOffer? = nil,
        quic: QUICVersionReading? = nil,
        streamOpening: StreamOpening? = nil
    ) -> StoredFlow {
        let local = IPEndpoint(address: IPAddress(version: .v4, bytes: [10, 7, 0, 2]), port: 50_000)
        let remote = IPEndpoint(address: IPAddress(version: .v4, bytes: [203, 0, 113, 9]), port: remotePort)
        let firstSeen = start.addingTimeInterval(TimeInterval(id))
        return StoredFlow(
            id: id,
            key: FlowKey(proto: proto, source: local, destination: remote),
            firstSeen: firstSeen,
            lastSeen: firstSeen.addingTimeInterval(1),
            bytesOut: 900,
            bytesIn: 4_200,
            packetCount: 12,
            tlsStatus: tlsStatus,
            sni: sni,
            resolvedName: resolvedName,
            serverTLS: serverTLS,
            serverCertificates: nil,
            clientTLS: clientTLS,
            quic: quic,
            streamOpening: streamOpening
        )
    }

    static func negotiated(
        _ version: TLSProtocolVersion,
        source: TLSAnswerSource = .serverHello,
        fromHelloRetryRequest: Bool = false
    ) -> ServerTLSAnswer {
        .negotiated(NegotiatedTLS(
            version: version,
            cipherSuite: TLSCipherSuite(rawValue: 0xC02F),
            fromHelloRetryRequest: fromHelloRetryRequest,
            source: source
        ))
    }

    /// Un proyecto con la allowlist que se le escriba, en ese orden.
    static func project(allowlist patterns: [String] = []) throws -> AuditProject {
        AuditProject(
            id: 1,
            name: "Example",
            bundleIdentifier: nil,
            catalogueVersion: nil,
            allowlist: try patterns.map { AllowlistEntry(pattern: try DomainPattern(parsing: $0), note: nil) },
            createdAt: start
        )
    }

    static func offer(_ versions: OfferedTLSVersions, encryptedClientHello: Bool = false) -> ClientTLSOffer {
        ClientTLSOffer(
            versions: versions,
            applicationProtocols: ["h2"],
            omittedApplicationProtocols: 0,
            hasEncryptedClientHello: encryptedClientHello
        )
    }
}
