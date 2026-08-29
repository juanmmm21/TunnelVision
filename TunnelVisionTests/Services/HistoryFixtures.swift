import Foundation
@testable import Shared

/// Ayudas de los tests del lector de historial: tiempo determinista, flujos guardados a mano (para
/// el núcleo puro) y flujos escribibles en un `FlowStore` real (para el lector).
enum HistoryFixtures {

    // MARK: - Tiempo

    static let anchorWallClock = Date(timeIntervalSince1970: 1_700_000_000)

    /// La misma forma de ancla que usan los tests del store: uptime distinto de cero, para que
    /// confundir sello monotónico con instante absoluto se note.
    static let anchor = MonotonicAnchor(
        uptimeNanoseconds: 1_000_000_000,
        wallClock: anchorWallClock
    )

    /// Sello monotónico de `seconds` segundos después del ancla.
    static func uptime(_ seconds: UInt64) -> UInt64 {
        anchor.uptimeNanoseconds + seconds * 1_000_000_000
    }

    /// La hora de pared correspondiente, calculada sin pasar por el ancla.
    static func date(_ seconds: UInt64) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + Double(seconds))
    }

    // MARK: - Direcciones

    /// El dispositivo es la IP del túnel: es lo que hace que `LiveFeedAddressing` sepa repartir.
    static let deviceIPv4 = TunnelAddressing.localIPv4
    static let deviceIPv6 = TunnelAddressing.localIPv6
    static let localAddresses = TunnelAddressing.localAddresses

    static func remote(_ d: UInt8) -> IPAddress { ModelFixtures.v4(93, 184, 216, d) }

    static func key(
        remote: IPAddress,
        remotePort: UInt16 = 443,
        localPort: UInt16 = 51_000,
        proto: IPProtocolNumber = .tcp,
        local: IPAddress = deviceIPv4
    ) -> FlowKey {
        FlowKey(
            proto: proto,
            source: ModelFixtures.endpoint(local, localPort),
            destination: ModelFixtures.endpoint(remote, remotePort)
        )
    }

    // MARK: - Flujos ya guardados (núcleo puro)

    /// `firstSeen`/`lastSeen` en segundos desde el ancla, como en los tests del store.
    static func storedFlow(
        id: Int64 = 1,
        remote: IPAddress = HistoryFixtures.remote(34),
        remotePort: UInt16 = 443,
        localPort: UInt16 = 51_000,
        proto: IPProtocolNumber = .tcp,
        local: IPAddress = deviceIPv4,
        firstSeen: UInt64 = 0,
        lastSeen: UInt64 = 10,
        bytesOut: UInt64 = 1_000,
        bytesIn: UInt64 = 2_000,
        packetCount: UInt64 = 12,
        tlsStatus: TLSInspectionStatus = .encrypted,
        sni: String? = nil
    ) -> StoredFlow {
        StoredFlow(
            id: id,
            key: key(
                remote: remote, remotePort: remotePort, localPort: localPort,
                proto: proto, local: local
            ),
            firstSeen: date(firstSeen),
            lastSeen: date(lastSeen),
            bytesOut: bytesOut,
            bytesIn: bytesIn,
            packetCount: packetCount,
            tlsStatus: tlsStatus,
            sni: sni
        )
    }

    static func historyFlow(
        id: Int64 = 1,
        remote: IPAddress = HistoryFixtures.remote(34),
        remotePort: UInt16 = 443,
        proto: IPProtocolNumber = .tcp,
        local: IPAddress = deviceIPv4,
        firstSeen: UInt64 = 0,
        lastSeen: UInt64 = 10,
        tlsStatus: TLSInspectionStatus = .encrypted,
        sni: String? = nil,
        localAddresses: Set<IPAddress> = HistoryFixtures.localAddresses
    ) -> HistoryFlow {
        HistoryFlow(
            storedFlow(
                id: id, remote: remote, remotePort: remotePort, proto: proto, local: local,
                firstSeen: firstSeen, lastSeen: lastSeen, tlsStatus: tlsStatus, sni: sni
            ),
            localAddresses: localAddresses
        )
    }

    // MARK: - Flujos escribibles (lector contra un store real)

    /// El record que la extensión volcaría al store: sellos monotónicos, que el store convierte.
    static func record(
        remote: IPAddress,
        remotePort: UInt16 = 443,
        localPort: UInt16 = 51_000,
        proto: IPProtocolNumber = .tcp,
        firstSeen: UInt64,
        lastSeen: UInt64,
        bytesOut: UInt64 = 1_000,
        bytesIn: UInt64 = 2_000,
        packetCount: UInt64 = 12,
        tlsStatus: TLSInspectionStatus = .encrypted,
        sni: String? = nil
    ) -> FlowRecord {
        FlowRecord(
            id: 0,
            key: key(remote: remote, remotePort: remotePort, localPort: localPort, proto: proto),
            firstSeen: uptime(firstSeen),
            lastSeen: uptime(lastSeen),
            bytesOut: bytesOut,
            bytesIn: bytesIn,
            packetCount: packetCount,
            tlsStatus: tlsStatus,
            sni: sni
        )
    }

    /// Un paquete ya guardado, como lo devuelve el store: `at` en segundos desde el ancla.
    static func storedPacket(
        id: Int64 = 1,
        at seconds: TimeInterval = 0,
        key: FlowKey = HistoryFixtures.key(remote: HistoryFixtures.remote(34)),
        direction: Direction = .outbound,
        length: UInt32 = 1_500,
        tcpFlags: TCPFlags = [.ack],
        capture: CaptureLocation? = nil
    ) -> StoredPacket {
        StoredPacket(
            id: id,
            date: anchorWallClock.addingTimeInterval(seconds),
            flowKey: key,
            direction: direction,
            length: length,
            tcpFlags: tcpFlags,
            capture: capture
        )
    }

    /// Un trozo de contenido descifrado ya indexado, como lo devuelve el store: `at` en segundos desde
    /// el ancla. La localización es sintética y solo tiene que ser **distinta** entre trozos: quien la
    /// resuelve de verdad es `PlaintextLibrary`, que se prueba contra ficheros escritos por un writer
    /// real.
    static func storedChunk(
        id: Int64 = 1,
        at seconds: TimeInterval = 0,
        direction: Direction = .outbound,
        stream: UInt64 = 1,
        fileSequence: UInt32 = 1,
        recordOffset: UInt64 = 16,
        storedLength: UInt32 = 64,
        originalLength: UInt32? = nil
    ) -> StoredPlaintextChunk {
        StoredPlaintextChunk(
            id: id,
            date: anchorWallClock.addingTimeInterval(seconds),
            direction: direction,
            stream: stream,
            location: PlaintextLocation(fileSequence: fileSequence, recordOffset: recordOffset),
            storedLength: storedLength,
            originalLength: originalLength ?? storedLength
        )
    }

    static func packet(
        timestamp: UInt64,
        key: FlowKey,
        direction: Direction = .outbound,
        length: UInt32 = 1_500,
        tcpFlags: TCPFlags = [.ack],
        capture: CaptureLocation? = nil
    ) -> PacketMeta {
        PacketMeta(
            timestamp: uptime(timestamp),
            flowKey: key,
            direction: direction,
            length: length,
            tcpFlags: tcpFlags,
            capture: capture
        )
    }
}
