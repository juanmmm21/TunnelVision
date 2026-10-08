import Foundation
import Shared

/// Flujos guardados a medida para los tests del clasificador: cada test dice solo lo que le
/// importa del flujo, y lo demás es un TCP contra el 443 sin ninguna lectura.
enum FindingFixtures {

    static let start = Date(timeIntervalSince1970: 1_790_000_000)

    static func flow(
        id: Int64,
        proto: IPProtocolNumber = .tcp,
        remotePort: UInt16 = 443,
        tlsStatus: TLSInspectionStatus = .encrypted,
        serverTLS: ServerTLSAnswer? = nil,
        clientTLS: ClientTLSOffer? = nil,
        quic: QUICVersionReading? = nil
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
            sni: nil,
            resolvedName: nil,
            serverTLS: serverTLS,
            serverCertificates: nil,
            clientTLS: clientTLS,
            quic: quic
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

    static func offer(_ versions: OfferedTLSVersions, encryptedClientHello: Bool = false) -> ClientTLSOffer {
        ClientTLSOffer(
            versions: versions,
            applicationProtocols: ["h2"],
            omittedApplicationProtocols: 0,
            hasEncryptedClientHello: encryptedClientHello
        )
    }
}
