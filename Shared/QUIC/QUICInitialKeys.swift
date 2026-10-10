import CommonCrypto
import CryptoKit
import Foundation

/// Las claves con las que **el cliente** protege sus paquetes Initial (RFC 9001 § 5.2).
///
/// No son un secreto: salen de una sal publicada en la RFC de cada versión y del Destination
/// Connection ID del primer Initial del cliente, que viaja en claro. La propia RFC 9000 (§ 17.2.2)
/// dice que esta protección no da confidencialidad frente a quien ve los paquetes — existe para
/// que un intermediario que no conoce la versión no los altere. Por eso leerlas no toca el ADR
/// 0003: es lo que puede hacer cualquier observador de la red.
///
/// Solo las del cliente, a propósito: lo que se busca es el ClientHello. Las del servidor saldrían
/// de la misma derivación con otra etiqueta y nadie las pide.
public struct QUICInitialKeys: Sendable, Equatable {

    /// La versión de cuya sal y etiquetas salen.
    public let version: QUICVersion
    /// Clave de AEAD_AES_128_GCM, 16 bytes.
    public let key: Data
    /// IV del AEAD, 12 bytes; el nonce de cada paquete es este IV con su número de paquete.
    public let iv: Data
    /// Clave de la protección de cabecera (AES-128-ECB), 16 bytes.
    public let headerProtectionKey: Data

    /// Deriva las claves, o devuelve `nil` si de `version` no se conocen sal ni etiquetas.
    ///
    /// - Parameter clientDestinationConnectionID: el del **primer** Initial del cliente. Los
    ///   Initial siguientes siguen protegidos con las claves de aquél aunque el cliente pase a
    ///   usar el identificador que eligió el servidor; solo un Retry las cambia (§ 5.2).
    public init?(version: QUICVersion, clientDestinationConnectionID: Data) {
        guard let parameters = Parameters(version: version) else { return nil }

        let initialSecret = HKDF<SHA256>.extract(
            inputKeyMaterial: SymmetricKey(data: clientDestinationConnectionID),
            salt: parameters.salt
        )
        let clientSecret = Self.expandLabel(
            SymmetricKey(data: initialSecret), label: "client in", length: SHA256.byteCount
        )
        self.version = version
        self.key = Self.bytes(Self.expandLabel(clientSecret, label: parameters.keyLabel, length: 16))
        self.iv = Self.bytes(Self.expandLabel(clientSecret, label: parameters.ivLabel, length: 12))
        self.headerProtectionKey = Self.bytes(
            Self.expandLabel(clientSecret, label: parameters.headerProtectionLabel, length: 16)
        )
    }

    /// Lo que cambia de una versión a otra. Los valores están copiados de la RFC 9001 § 5.2 y de
    /// la RFC 9369 § 3.3.1 y § 3.3.2 con el documento delante, y los sujetan los vectores de sus
    /// apéndices A en `QUICInitialKeysTests`.
    private struct Parameters {
        let salt: Data
        let keyLabel: String
        let ivLabel: String
        let headerProtectionLabel: String

        init?(version: QUICVersion) {
            switch version {
            case .v1:
                salt = Data([
                    0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3, 0x4d, 0x17,
                    0x9a, 0xe6, 0xa4, 0xc8, 0x0c, 0xad, 0xcc, 0xbb, 0x7f, 0x0a,
                ])
                keyLabel = "quic key"
                ivLabel = "quic iv"
                headerProtectionLabel = "quic hp"
            case .v2:
                salt = Data([
                    0x0d, 0xed, 0xe3, 0xde, 0xf7, 0x00, 0xa6, 0xdb, 0x81, 0x93,
                    0x81, 0xbe, 0x6e, 0x26, 0x9d, 0xcb, 0xf9, 0xbd, 0x2e, 0xd9,
                ])
                keyLabel = "quicv2 key"
                ivLabel = "quicv2 iv"
                headerProtectionLabel = "quicv2 hp"
            default:
                return nil
            }
        }
    }

    /// HKDF-Expand-Label de TLS 1.3 (RFC 8446 § 7.1) con contexto vacío, que es como lo usa QUIC:
    /// la longitud pedida en dos bytes, la etiqueta con el prefijo `tls13 ` precedida de su
    /// longitud, y un byte a cero por el contexto.
    private static func expandLabel(_ secret: SymmetricKey, label: String, length: Int) -> SymmetricKey {
        let fullLabel = Array("tls13 \(label)".utf8)
        var info = Data([UInt8(length >> 8), UInt8(length & 0xff), UInt8(fullLabel.count)])
        info.append(contentsOf: fullLabel)
        info.append(0)
        return HKDF<SHA256>.expand(pseudoRandomKey: secret, info: info, outputByteCount: length)
    }

    private static func bytes(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }
}

/// La protección de cabecera de QUIC con AES (RFC 9001 § 5.4.3), que es la de los Initial: una
/// máscara de cinco bytes que tapa los bits bajos del primer byte y el número de paquete.
public enum QUICHeaderProtection {

    /// Bytes de texto cifrado que se muestrean, y a la vez el bloque de AES.
    public static let sampleLength = 16
    /// Bytes de la máscara que se usan: uno para el primer byte y hasta cuatro para el número.
    public static let maskLength = 5

    /// La máscara: los cinco primeros bytes de cifrar `sample` con AES-128 en modo ECB.
    ///
    /// CryptoKit no ofrece AES sin modo de operación, así que el bloque lo cifra CommonCrypto.
    public static func mask(key: Data, sample: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128, sample.count == sampleLength else {
            throw QUICInitialError.headerProtectionFailed
        }
        var block = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        var written = 0
        let status = key.withUnsafeBytes { keyBytes in
            sample.withUnsafeBytes { sampleBytes in
                CCCrypt(
                    CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                    keyBytes.baseAddress, keyBytes.count,
                    nil,
                    sampleBytes.baseAddress, sampleBytes.count,
                    &block, block.count,
                    &written
                )
            }
        }
        guard status == kCCSuccess, written == block.count else {
            throw QUICInitialError.headerProtectionFailed
        }
        return Data(block[..<maskLength])
    }
}
