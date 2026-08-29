import Foundation
@testable import Shared

/// Ayudas compartidas por los tests del store: rutas de BD temporales, ancla determinista y
/// constructores de records.
enum PersistenceFixtures {

    /// Ruta única en el directorio temporal para una BD SQLite de test. No crea el fichero; lo
    /// abre el `DatabasePool`. El llamante debe borrarla (junto a sus sidecars `-wal`/`-shm`) al
    /// terminar con `removeDatabase(at:)`.
    static func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tunnelvision-tests-\(UUID().uuidString).sqlite")
    }

    /// Borra la BD y sus ficheros auxiliares de WAL, ignorando los que no existan.
    static func removeDatabase(at url: URL) {
        let manager = FileManager.default
        for path in [url.path, url.path + "-wal", url.path + "-shm"] {
            try? manager.removeItem(atPath: path)
        }
    }

    // MARK: - Tiempo determinista

    /// Instante de pared del anclaje. Elegido redondo y actual: `Date` tiene ~256 ns de resolución a
    /// esta magnitud, así que los tests espacian en **segundos**, nunca en nanosegundos sueltos.
    static let anchorWallClock = Date(timeIntervalSince1970: 1_700_000_000)

    /// Ancla de referencia de los tests del store. Uptime de 1 s: distinto de cero a propósito, para
    /// que un test que confunda sello monotónico con instante absoluto falle.
    static let anchor = MonotonicAnchor(
        uptimeNanoseconds: 1_000_000_000,
        wallClock: anchorWallClock
    )

    /// Sello monotónico correspondiente a `seconds` segundos después del ancla.
    static func uptime(_ seconds: UInt64) -> UInt64 {
        anchor.uptimeNanoseconds + seconds * 1_000_000_000
    }

    /// Hora de pared correspondiente a `uptime(seconds)`, calculada sin pasar por el ancla para que
    /// el test no se valide contra la implementación que prueba.
    static func date(_ seconds: UInt64) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + Double(seconds))
    }

    static let deviceIP = ModelFixtures.v4(10, 0, 0, 2)      // dispositivo (local)

    /// Flujo TCP dispositivo↔servidor remoto. `id` es irrelevante en escritura (el store asigna
    /// su propio rowid); se deja en 0. `firstSeen`/`lastSeen` son **segundos después del ancla**,
    /// no sellos crudos: escribirlos así mantiene los tests legibles y por encima de la resolución
    /// de `Date`.
    static func flow(
        remote: IPAddress,
        remotePort: UInt16 = 443,
        localPort: UInt16 = 51000,
        proto: IPProtocolNumber = .tcp,
        firstSeen: UInt64,
        lastSeen: UInt64,
        bytesOut: UInt64 = 0,
        bytesIn: UInt64 = 0,
        packetCount: UInt64 = 0,
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

    /// La 5-tupla canónica del flujo que construye `flow(...)` con los mismos parámetros.
    static func key(
        remote: IPAddress,
        remotePort: UInt16 = 443,
        localPort: UInt16 = 51000,
        proto: IPProtocolNumber = .tcp
    ) -> FlowKey {
        FlowKey(
            proto: proto,
            source: ModelFixtures.endpoint(deviceIP, localPort),
            destination: ModelFixtures.endpoint(remote, remotePort)
        )
    }

    /// `timestamp` en segundos después del ancla, por el mismo motivo que en `flow(...)`.
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
