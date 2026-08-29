import Foundation
@testable import Shared

/// Constructores compactos reutilizados por los tests de modelos.
enum ModelFixtures {
    static func v4(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> IPAddress {
        IPAddress(version: .v4, bytes: [a, b, c, d])
    }

    static func v6(_ groups: UInt16...) -> IPAddress {
        precondition(groups.count == 8, "una IPv6 tiene 8 grupos de 16 bits")
        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        for g in groups {
            bytes.append(UInt8(g >> 8))
            bytes.append(UInt8(g & 0xff))
        }
        return IPAddress(version: .v6, bytes: bytes)
    }

    static func endpoint(_ address: IPAddress, _ port: UInt16) -> IPEndpoint {
        IPEndpoint(address: address, port: port)
    }
}
