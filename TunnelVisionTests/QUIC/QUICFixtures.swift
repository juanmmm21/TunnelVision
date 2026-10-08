import Foundation
import Shared

/// Constructores de payloads UDP con forma de paquete QUIC para los tests.
enum QUICFixtures {

    /// Una cabecera larga (RFC 8999 § 5.1) seguida de relleno. `firstByte` por defecto es el de un
    /// Initial de la versión 1: cabecera larga y fixed bit a 1.
    static func longHeader(
        version: UInt32,
        firstByte: UInt8 = 0xC0,
        destinationID: [UInt8] = [0x83, 0x94, 0xC8, 0xF0, 0x3E, 0x51, 0x57, 0x08],
        sourceID: [UInt8] = [],
        trailing: Int = 32
    ) -> [UInt8] {
        var bytes: [UInt8] = [firstByte]
        bytes += [UInt8(version >> 24), UInt8(version >> 16 & 0xff), UInt8(version >> 8 & 0xff), UInt8(version & 0xff)]
        bytes.append(UInt8(destinationID.count))
        bytes += destinationID
        bytes.append(UInt8(sourceID.count))
        bytes += sourceID
        bytes += [UInt8](repeating: 0x5A, count: trailing)
        return bytes
    }

    /// Un paquete de cabecera corta: primer bit a 0, fixed bit a 1, y lo demás cifrado.
    static func shortHeader(length: Int = 40) -> [UInt8] {
        [0x40] + [UInt8](repeating: 0x5A, count: length - 1)
    }
}
