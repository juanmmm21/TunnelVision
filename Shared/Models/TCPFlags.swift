import Foundation

/// Flags de control TCP (byte 13 de la cabecera). Se transporta y persiste dentro de
/// `PacketMeta`, de ahí que sea `Codable` y `Hashable` además de `OptionSet`.
public struct TCPFlags: OptionSet, Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let fin = TCPFlags(rawValue: 1 << 0)
    public static let syn = TCPFlags(rawValue: 1 << 1)
    public static let rst = TCPFlags(rawValue: 1 << 2)
    public static let psh = TCPFlags(rawValue: 1 << 3)
    public static let ack = TCPFlags(rawValue: 1 << 4)
    public static let urg = TCPFlags(rawValue: 1 << 5)

    // OptionSet no sintetiza Codable; se codifica el rawValue como valor único para que el
    // layout on-wire sea el byte crudo, igual que en la cabecera TCP.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(UInt8.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String {
        let named: [(TCPFlags, String)] = [
            (.syn, "SYN"), (.ack, "ACK"), (.fin, "FIN"),
            (.rst, "RST"), (.psh, "PSH"), (.urg, "URG"),
        ]
        let present = named.filter { contains($0.0) }.map(\.1)
        return present.isEmpty ? "-" : present.joined(separator: "|")
    }
}
