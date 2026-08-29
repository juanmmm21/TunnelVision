import Foundation

/// Representación empaquetada de ancho fijo de `PacketMeta`, tal como viaja por el ring buffer.
///
/// Ancho fijo (`packedByteCount` = 64 bytes) y serialización **little-endian explícita** (byte a
/// byte, independiente del endianness del host, igual que el escritor `pcap`): así el consumidor
/// calcula el offset de cada slot sin parsear y las lecturas nunca quedan a medias.
///
/// El proto se guarda como un **código de 4 bits** (no el valor de cable, que para UDP=17 o
/// ICMPv6=58 no cabe en un nibble). No se pierde información respecto a `PacketMeta`, porque este
/// ya porta `IPProtocolNumber` colapsado (el valor crudo vive en `IPHeader.rawProtocol`, fuera de
/// `PacketMeta`). El estado TLS es por-flujo y vive en el store, no en el feed por-paquete.
public struct PackedPacketMeta: Sendable, Hashable {
    public var timestamp: UInt64          // nanosegundos monotónicos (convención de `PacketMeta`)
    public var protoAndDirection: UInt8   // proto (código 0-4) en nibble alto, dirección en el bajo
    public var ipVersion: UInt8           // 4 o 6; ambos endpoints comparten familia
    public var tcpFlags: UInt8            // 0 si no es TCP
    public var portA: UInt16              // puerto del endpoint canónico A (menor)
    public var portB: UInt16              // puerto del endpoint canónico B (mayor)
    public var addrA: [UInt8]             // 16 bytes; v4 usa los primeros 4, resto a 0
    public var addrB: [UInt8]             // 16 bytes
    public var length: UInt32             // bytes del datagrama IP

    /// Fichero y offset donde quedaron sus bytes, o `nil` si no se capturó. Sobre el cable se
    /// codifica con `recordOffset == 0` como centinela de "sin captura": el offset 0 nunca es un
    /// registro válido, porque todo `.pcap` empieza por su cabecera global.
    public var capture: CaptureLocation?

    /// Bytes de un registro serializado. Fijo: el ring reserva `slotSize >= packedByteCount`.
    public static let packedByteCount = 64

    public init(
        timestamp: UInt64,
        protoAndDirection: UInt8,
        ipVersion: UInt8,
        tcpFlags: UInt8,
        portA: UInt16,
        portB: UInt16,
        addrA: [UInt8],
        addrB: [UInt8],
        length: UInt32,
        capture: CaptureLocation?
    ) {
        precondition(addrA.count == 16 && addrB.count == 16, "addrA/addrB deben ser de 16 bytes")
        self.timestamp = timestamp
        self.protoAndDirection = protoAndDirection
        self.ipVersion = ipVersion
        self.tcpFlags = tcpFlags
        self.portA = portA
        self.portB = portB
        self.addrA = addrA
        self.addrB = addrB
        self.length = length
        self.capture = capture
    }

    // MARK: - Conversión desde/hacia PacketMeta

    /// Empaqueta un `PacketMeta`. `addrA/addrB` toman los endpoints canónicos de `flowKey`
    /// (rellenando a 16 bytes); la dirección real dispositivo↔internet va aparte en el nibble bajo.
    public init(_ meta: PacketMeta) {
        let a = meta.flowKey.endpointA
        let b = meta.flowKey.endpointB
        self.init(
            timestamp: meta.timestamp,
            protoAndDirection: Self.packProto(meta.flowKey.proto, direction: meta.direction),
            ipVersion: a.address.version.rawValue,
            tcpFlags: meta.tcpFlags.rawValue,
            portA: a.port,
            portB: b.port,
            addrA: Self.padded(a.address.bytes),
            addrB: Self.padded(b.address.bytes),
            length: meta.length,
            capture: meta.capture
        )
    }

    /// Reconstruye el `PacketMeta` equivalente. La clave canónica se regenera con
    /// `FlowKey(proto:source:destination:)` a partir de (A, B) — como A ≤ B, sale idéntica.
    public func toPacketMeta() -> PacketMeta {
        let version: IPVersion = ipVersion == 6 ? .v6 : .v4
        let byteCount = version.addressByteCount
        let endpointA = IPEndpoint(
            address: IPAddress(version: version, bytes: Array(addrA.prefix(byteCount))),
            port: portA
        )
        let endpointB = IPEndpoint(
            address: IPAddress(version: version, bytes: Array(addrB.prefix(byteCount))),
            port: portB
        )
        let key = FlowKey(proto: Self.proto(fromCode: protoAndDirection >> 4), source: endpointA, destination: endpointB)
        return PacketMeta(
            timestamp: timestamp,
            flowKey: key,
            direction: Self.direction(from: protoAndDirection),
            length: length,
            tcpFlags: TCPFlags(rawValue: tcpFlags),
            capture: capture
        )
    }

    // MARK: - Serialización de ancho fijo (little-endian)

    /// Escribe los `packedByteCount` bytes del registro en `raw` (offset 0). No asume alineación:
    /// cada campo se emite byte a byte en little-endian.
    public func encode(into raw: UnsafeMutableRawPointer) {
        let p = raw.assumingMemoryBound(to: UInt8.self)
        Self.putU64(p, 0, timestamp)
        p[8] = protoAndDirection
        p[9] = ipVersion
        p[10] = tcpFlags
        p[11] = 0                       // reservado (padding): alinea los puertos y deja el layout fijo
        Self.putU16(p, 12, portA)
        Self.putU16(p, 14, portB)
        for i in 0..<16 { p[16 + i] = addrA[i] }
        for i in 0..<16 { p[32 + i] = addrB[i] }
        Self.putU32(p, 48, length)
        Self.putU64(p, 52, capture?.recordOffset ?? 0)
        Self.putU32(p, 60, capture?.fileSequence ?? 0)
    }

    /// Decodifica un registro desde `raw` (offset 0). Simétrico a `encode`.
    public init(from raw: UnsafeRawPointer) {
        let p = raw.assumingMemoryBound(to: UInt8.self)
        self.timestamp = Self.getU64(p, 0)
        self.protoAndDirection = p[8]
        self.ipVersion = p[9]
        self.tcpFlags = p[10]
        // p[11] reservado, ignorado.
        self.portA = Self.getU16(p, 12)
        self.portB = Self.getU16(p, 14)
        self.addrA = (0..<16).map { p[16 + $0] }
        self.addrB = (0..<16).map { p[32 + $0] }
        self.length = Self.getU32(p, 48)
        // Sin offset no hay captura, y entonces la secuencia del fichero no significa nada: se
        // ignora en vez de fabricar una localización que apuntaría al fichero 0.
        let recordOffset = Self.getU64(p, 52)
        let fileSequence = Self.getU32(p, 60)
        self.capture = recordOffset == 0
            ? nil
            : CaptureLocation(fileSequence: fileSequence, recordOffset: recordOffset)
    }

    // MARK: - Interno: proto/dirección en un byte

    private static func packProto(_ proto: IPProtocolNumber, direction: Direction) -> UInt8 {
        (protoCode(proto) << 4) | (direction.rawValue & 0x0f)
    }

    private static func direction(from byte: UInt8) -> Direction {
        Direction(rawValue: byte & 0x0f) ?? .outbound
    }

    /// Código de 4 bits del protocolo. Mapeo explícito (no derivado de `CaseIterable`) para que el
    /// layout on-wire sea estable aunque cambie el orden del enum.
    private static func protoCode(_ proto: IPProtocolNumber) -> UInt8 {
        switch proto {
        case .tcp: return 0
        case .udp: return 1
        case .icmp: return 2
        case .icmpv6: return 3
        case .other: return 4
        }
    }

    private static func proto(fromCode code: UInt8) -> IPProtocolNumber {
        switch code {
        case 0: return .tcp
        case 1: return .udp
        case 2: return .icmp
        case 3: return .icmpv6
        default: return .other
        }
    }

    private static func padded(_ bytes: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        for i in 0..<min(bytes.count, 16) { out[i] = bytes[i] }
        return out
    }

    // MARK: - Interno: enteros little-endian byte a byte

    private static func putU16(_ p: UnsafeMutablePointer<UInt8>, _ o: Int, _ v: UInt16) {
        p[o] = UInt8(truncatingIfNeeded: v)
        p[o + 1] = UInt8(truncatingIfNeeded: v >> 8)
    }

    private static func putU32(_ p: UnsafeMutablePointer<UInt8>, _ o: Int, _ v: UInt32) {
        for i in 0..<4 { p[o + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) }
    }

    private static func putU64(_ p: UnsafeMutablePointer<UInt8>, _ o: Int, _ v: UInt64) {
        for i in 0..<8 { p[o + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) }
    }

    private static func getU16(_ p: UnsafePointer<UInt8>, _ o: Int) -> UInt16 {
        UInt16(p[o]) | (UInt16(p[o + 1]) << 8)
    }

    private static func getU32(_ p: UnsafePointer<UInt8>, _ o: Int) -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(p[o + i]) << (8 * i) }
        return v
    }

    private static func getU64(_ p: UnsafePointer<UInt8>, _ o: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(p[o + i]) << (8 * i) }
        return v
    }
}
