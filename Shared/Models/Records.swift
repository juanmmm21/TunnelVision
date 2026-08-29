import Foundation

/// Metadato compacto de un paquete: lo que viaja por el ring buffer y a la tabla `packets`.
/// Layout de ancho fijo — ver `docs/spec/ipc.md` para la representación empaquetada.
public struct PacketMeta: Sendable, Hashable, Codable {
    public let timestamp: UInt64        // nanosegundos monotónicos desde un origen inyectado
    public let flowKey: FlowKey
    public let direction: Direction
    public let length: UInt32           // bytes del paquete IP
    public let tcpFlags: TCPFlags       // 0 si no es TCP

    /// Fichero y posición donde quedaron sus bytes, o `nil` si no se capturó (captura desactivada,
    /// sin writer, o rota tras un fallo de escritura). Es la pareja completa a propósito: el offset
    /// suelto no identifica unos bytes, porque el writer rota de fichero.
    public let capture: CaptureLocation?

    public init(
        timestamp: UInt64,
        flowKey: FlowKey,
        direction: Direction,
        length: UInt32,
        tcpFlags: TCPFlags,
        capture: CaptureLocation?
    ) {
        self.timestamp = timestamp
        self.flowKey = flowKey
        self.direction = direction
        self.length = length
        self.tcpFlags = tcpFlags
        self.capture = capture
    }
}

/// Estado agregado de un flujo: fila de la tabla `flows`.
public struct FlowRecord: Sendable, Hashable, Codable, Identifiable {
    public let id: Int64                 // rowid asignado por el store
    public let key: FlowKey
    public let firstSeen: UInt64
    public let lastSeen: UInt64
    public var bytesOut: UInt64
    public var bytesIn: UInt64
    public var packetCount: UInt64
    public var tlsStatus: TLSInspectionStatus
    public var sni: String?             // hostname del ClientHello, si se vio

    public init(
        id: Int64,
        key: FlowKey,
        firstSeen: UInt64,
        lastSeen: UInt64,
        bytesOut: UInt64,
        bytesIn: UInt64,
        packetCount: UInt64,
        tlsStatus: TLSInspectionStatus,
        sni: String?
    ) {
        self.id = id
        self.key = key
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.bytesOut = bytesOut
        self.bytesIn = bytesIn
        self.packetCount = packetCount
        self.tlsStatus = tlsStatus
        self.sni = sni
    }
}
