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

    /// El nombre que el DNS había dado a la dirección remota cuando el flujo se creó, si había
    /// alguno vivo. Campo aparte del `sni` a propósito: aquél lo anuncia la conexión, éste se deduce.
    /// Se fija al crear el flujo y no cambia aunque después pase otra respuesta.
    public var resolvedName: ResolvedFlowName?

    /// Lo que el servidor contestó al ClientHello —versión y suite, o una alerta—, leído del
    /// ServerHello en claro. `nil` si no hubo lectura: el flujo no era TLS sobre TCP/443, el stream
    /// no se dejó leer, o la respuesta aún no ha llegado.
    public var serverTLS: ServerTLSAnswer?

    /// Lo que el cliente ofreció en su ClientHello —versiones de TLS y ALPN—. `nil` si no hubo
    /// lectura: el flujo no era TLS sobre TCP/443, o su ClientHello no se dejó recorrer entero.
    /// Es de la app también en un flujo inspeccionado, al revés que `serverTLS`.
    public var clientTLS: ClientTLSOffer?

    /// La versión de QUIC leída de una cabecera larga del flujo, y de qué extremo. `nil` si no
    /// hubo lectura: el flujo no era UDP contra el 443, no hablaba QUIC, o su arranque —lo único
    /// que lleva cabecera larga— pasó antes de que el túnel mirase.
    public var quic: QUICVersionReading?

    public init(
        id: Int64,
        key: FlowKey,
        firstSeen: UInt64,
        lastSeen: UInt64,
        bytesOut: UInt64,
        bytesIn: UInt64,
        packetCount: UInt64,
        tlsStatus: TLSInspectionStatus,
        sni: String?,
        resolvedName: ResolvedFlowName?,
        serverTLS: ServerTLSAnswer?,
        clientTLS: ClientTLSOffer?,
        quic: QUICVersionReading?
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
        self.resolvedName = resolvedName
        self.serverTLS = serverTLS
        self.clientTLS = clientTLS
        self.quic = quic
    }

    /// El nombre del flujo con su origen: el SNI si lo anunció, y si no el que se dedujo del DNS.
    public var name: FlowName? { FlowName(sni: sni, resolved: resolvedName) }
}
