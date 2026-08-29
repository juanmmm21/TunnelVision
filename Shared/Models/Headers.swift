import Foundation

// Cabeceras parseadas y transitorias: las produce el parser y se consumen de inmediato en el
// hot path (no se persisten tal cual). `payloadRange` referencia el buffer original sin copiar.

/// Cabecera IP (v4 o v6) ya normalizada a host-order.
public struct IPHeader: Sendable, Hashable {
    public let version: IPVersion
    public let source: IPAddress
    public let destination: IPAddress
    public let proto: IPProtocolNumber
    public let rawProtocol: UInt8       // valor real del campo, incluso si `proto == .other`
    public let payloadRange: Range<Int> // rango del payload L4 dentro del buffer original
    public let totalLength: Int

    public init(
        version: IPVersion,
        source: IPAddress,
        destination: IPAddress,
        proto: IPProtocolNumber,
        rawProtocol: UInt8,
        payloadRange: Range<Int>,
        totalLength: Int
    ) {
        self.version = version
        self.source = source
        self.destination = destination
        self.proto = proto
        self.rawProtocol = rawProtocol
        self.payloadRange = payloadRange
        self.totalLength = totalLength
    }
}

/// Cabecera TCP (RFC 9293) ya normalizada a host-order.
public struct TCPHeader: Sendable, Hashable {
    public let sourcePort: UInt16
    public let destinationPort: UInt16
    public let sequence: UInt32
    public let acknowledgment: UInt32
    public let flags: TCPFlags
    public let windowSize: UInt16
    public let dataOffsetBytes: Int     // longitud de cabecera TCP (incluye opciones)
    public let payloadRange: Range<Int>

    public init(
        sourcePort: UInt16,
        destinationPort: UInt16,
        sequence: UInt32,
        acknowledgment: UInt32,
        flags: TCPFlags,
        windowSize: UInt16,
        dataOffsetBytes: Int,
        payloadRange: Range<Int>
    ) {
        self.sourcePort = sourcePort
        self.destinationPort = destinationPort
        self.sequence = sequence
        self.acknowledgment = acknowledgment
        self.flags = flags
        self.windowSize = windowSize
        self.dataOffsetBytes = dataOffsetBytes
        self.payloadRange = payloadRange
    }
}

/// Cabecera UDP (RFC 768) ya normalizada a host-order.
public struct UDPHeader: Sendable, Hashable {
    public let sourcePort: UInt16
    public let destinationPort: UInt16
    public let length: UInt16
    public let payloadRange: Range<Int>

    public init(
        sourcePort: UInt16,
        destinationPort: UInt16,
        length: UInt16,
        payloadRange: Range<Int>
    ) {
        self.sourcePort = sourcePort
        self.destinationPort = destinationPort
        self.length = length
        self.payloadRange = payloadRange
    }
}
