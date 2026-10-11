import CryptoKit
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

    /// Los bytes de un texto en hexadecimal; espacios y saltos de línea no cuentan, que es como
    /// los imprimen las RFC.
    static func bytes(hex: String) -> [UInt8] {
        let digits = hex.filter { !$0.isWhitespace }
        precondition(digits.count.isMultiple(of: 2), "hexadecimal con un dígito suelto")
        var bytes = [UInt8]()
        bytes.reserveCapacity(digits.count / 2)
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else {
                preconditionFailure("no es hexadecimal: \(digits[index..<next])")
            }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// Un Initial del cliente **protegido de verdad** (RFC 9001 § 5.3 y § 5.4), para los casos que
    /// los vectores de la RFC no traen: otras longitudes del número de paquete, un token, un
    /// paquete detrás en el mismo datagrama.
    ///
    /// Las claves salen de `keysFrom`, que no tiene por qué ser `destinationID`: así se escribe
    /// el Initial que un cliente manda después de que el servidor eligiera su identificador.
    static func clientInitial(
        version: QUICVersion = .v1,
        keysFrom originalDestinationID: [UInt8],
        destinationID: [UInt8],
        sourceID: [UInt8] = [],
        token: [UInt8] = [],
        packetNumber: UInt64,
        packetNumberLength: Int,
        frames: [UInt8]
    ) throws -> [UInt8] {
        precondition((1...4).contains(packetNumberLength))
        guard let keys = QUICInitialKeys(
            version: version, clientDestinationConnectionID: Data(originalDestinationID)
        ) else {
            throw QUICInitialError.unsupportedVersion(version)
        }
        let typeBits: UInt8 = version == .v2 ? 0x10 : 0x00
        let raw = version.rawValue

        var header: [UInt8] = [0xC0 | typeBits | UInt8(packetNumberLength - 1)]
        header += [UInt8(raw >> 24), UInt8(raw >> 16 & 0xff), UInt8(raw >> 8 & 0xff), UInt8(raw & 0xff)]
        header.append(UInt8(destinationID.count))
        header += destinationID
        header.append(UInt8(sourceID.count))
        header += sourceID
        header += varint(token.count)
        header += token
        header += varint(packetNumberLength + frames.count + 16)
        let numberOffset = header.count
        for shift in stride(from: (packetNumberLength - 1) * 8, through: 0, by: -8) {
            header.append(UInt8(truncatingIfNeeded: packetNumber >> UInt64(shift)))
        }

        var nonce = [UInt8](keys.iv)
        for offset in 0..<8 {
            nonce[nonce.count - 1 - offset] ^= UInt8(truncatingIfNeeded: packetNumber >> UInt64(offset * 8))
        }
        let sealed = try AES.GCM.seal(
            Data(frames),
            using: SymmetricKey(data: keys.key),
            nonce: AES.GCM.Nonce(data: Data(nonce)),
            authenticating: Data(header)
        )
        var packet = header + [UInt8](sealed.ciphertext) + [UInt8](sealed.tag)

        let sampleStart = numberOffset + 4
        let mask = [UInt8](try QUICHeaderProtection.mask(
            key: keys.headerProtectionKey, sample: Data(packet[sampleStart..<sampleStart + 16])
        ))
        packet[0] ^= mask[0] & 0x0f
        for offset in 0..<packetNumberLength {
            packet[numberOffset + offset] ^= mask[1 + offset]
        }
        return packet
    }

    /// Un entero de longitud variable (RFC 9000 § 16) en uno o dos bytes, que es lo que dan de sí
    /// las longitudes de un datagrama.
    static func varint(_ value: Int) -> [UInt8] {
        precondition((0..<16384).contains(value))
        return value < 64 ? [UInt8(value)] : [0x40 | UInt8(value >> 8), UInt8(value & 0xff)]
    }

    /// El mismo entero en ocho bytes, la codificación más larga: para los valores que no caben en
    /// dos y para escribir a propósito uno que no va en su forma más corta.
    static func varint8(_ value: UInt64) -> [UInt8] {
        precondition(value < 1 << 62)
        return (0..<8).map { UInt8(truncatingIfNeeded: (value | 0xC000_0000_0000_0000) >> UInt64((7 - $0) * 8)) }
    }

    /// Un frame CRYPTO (RFC 9000 § 19.6): tipo 0x06, desplazamiento, longitud y los datos.
    static func cryptoFrame(offset: Int, data: [UInt8]) -> [UInt8] {
        [0x06] + varint(offset) + varint(data.count) + data
    }

    /// Un ACK (§ 19.3) que reconoce `largest` y, por cada par de `ranges`, un hueco y un rango
    /// más. Con `ecnCounts` es el tipo 0x03, que lleva tres contadores detrás.
    static func ackFrame(
        largest: Int, delay: Int = 0, firstRange: Int = 0, ranges: [(gap: Int, length: Int)] = [], ecnCounts: [Int]? = nil
    ) -> [UInt8] {
        var frame: [UInt8] = [ecnCounts == nil ? 0x02 : 0x03]
        frame += varint(largest) + varint(delay) + varint(ranges.count) + varint(firstRange)
        for range in ranges {
            frame += varint(range.gap) + varint(range.length)
        }
        if let ecnCounts {
            precondition(ecnCounts.count == 3)
            frame += ecnCounts.flatMap(varint)
        }
        return frame
    }

    /// Un CONNECTION_CLOSE de la capa de QUIC (§ 19.19, tipo 0x1c) con su frase.
    static func connectionCloseFrame(errorCode: Int, frameType: Int = 0, reason: String = "") -> [UInt8] {
        let phrase = [UInt8](reason.utf8)
        return [0x1c] + varint(errorCode) + varint(frameType) + varint(phrase.count) + phrase
    }
}
