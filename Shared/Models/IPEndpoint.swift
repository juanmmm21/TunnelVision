import Foundation

/// Dirección IP + puerto. La IP se guarda en su forma binaria (ver `IPAddress`).
public struct IPEndpoint: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    public let address: IPAddress
    public let port: UInt16

    public init(address: IPAddress, port: UInt16) {
        self.address = address
        self.port = port
    }

    /// Orden total y estable: primero por dirección, luego por puerto. Es la base de la
    /// canonicalización de `FlowKey`, así que debe ser determinista.
    public static func < (lhs: IPEndpoint, rhs: IPEndpoint) -> Bool {
        if lhs.address != rhs.address {
            return lhs.address < rhs.address
        }
        return lhs.port < rhs.port
    }

    public var description: String {
        switch address.version {
        case .v4:
            return "\(address):\(port)"
        case .v6:
            // Corchetes en IPv6 para separar la dirección (que lleva ":") del puerto.
            return "[\(address)]:\(port)"
        }
    }
}
