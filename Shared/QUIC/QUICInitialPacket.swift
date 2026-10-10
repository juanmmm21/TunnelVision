import CryptoKit
import Foundation

/// Por qué de un datagrama no salió un Initial abierto.
public enum QUICInitialError: Error, Equatable, Sendable {
    /// No empieza por una cabecera larga con el fixed bit a 1.
    case notALongHeader
    /// La versión no es una de las que se sabe cómo protegen sus paquetes (las dos del IETF). Un
    /// Version Negotiation, cuya versión es 0, cae aquí.
    case unsupportedVersion(QUICVersion)
    /// Es una cabecera larga de otro tipo: 0-RTT, Handshake o Retry. Van con claves que el túnel
    /// no tiene ni debe tener, o no llevan nada cifrado.
    case notAnInitial
    /// Un Connection ID de más de 20 bytes, que el destinatario tiene que descartar.
    case connectionIDTooLong
    /// La cabecera o la longitud que declara no caben en el datagrama.
    case truncated
    /// No hay sitio para el número de paquete, la muestra de la protección de cabecera y la
    /// etiqueta del AEAD (RFC 9001 § 5.4.2: un paquete así se descarta).
    case tooShortToSample
    /// Las claves son de otra versión que la del paquete.
    case keysOfAnotherVersion
    /// No se pudo calcular la máscara de la cabecera.
    case headerProtectionFailed
    /// El AEAD no autentica: las claves no son las de este paquete (otro Connection ID de
    /// partida, un Initial posterior a un Retry) o el paquete llegó alterado.
    case authenticationFailed
}

/// Lo que un paquete Initial lleva **en claro** (RFC 9000 § 17.2.2), leído sin clave ninguna:
/// lo bastante para saber de qué Connection ID salen sus claves y dónde acaba.
///
/// ```
/// 1 byte    1 1 T T x x x x     T = tipo; los cuatro bits bajos van protegidos
/// 4 bytes   versión
/// 1 + n     Destination Connection ID
/// 1 + n     Source Connection ID
/// varint    longitud del token, y el token
/// varint    longitud de lo que sigue: número de paquete + payload cifrado
/// ```
public struct QUICInitialHeader: Sendable, Equatable {

    public let version: QUICVersion
    public let destinationConnectionID: Data
    public let sourceConnectionID: Data
    /// Bytes del token. Distinto de cero en el Initial que sigue a un Retry y en el de un cliente
    /// que guardaba un token de una conexión anterior.
    public let tokenLength: Int
    /// Desde el principio del datagrama hasta el número de paquete, que es donde acaba lo que se
    /// lee sin clave.
    public let packetNumberOffset: Int
    /// Bytes del datagrama que ocupa el paquete entero. Si es menor que el datagrama, detrás va
    /// otro paquete de la misma conexión (§ 12.2).
    public let packetLength: Int

    private static let longHeaderBit: UInt8 = 0x80
    private static let fixedBit: UInt8 = 0x40
    private static let typeMask: UInt8 = 0x30
    private static let maxConnectionIDLength = 20
    /// Lo que se muestrea empieza cuatro bytes detrás del número de paquete, mida éste lo que
    /// mida (RFC 9001 § 5.4.2).
    fileprivate static let sampleOffset = 4
    fileprivate static let tagLength = 16

    /// Lee la cabecera con la que empieza `datagram`.
    public init(datagram: Data) throws {
        let start = datagram.startIndex
        guard let first = datagram.first, first & Self.longHeaderBit != 0, first & Self.fixedBit != 0 else {
            throw QUICInitialError.notALongHeader
        }
        guard datagram.count >= 5 else { throw QUICInitialError.truncated }

        let version = QUICVersion(
            rawValue: UInt32(datagram[start + 1]) << 24
                | UInt32(datagram[start + 2]) << 16
                | UInt32(datagram[start + 3]) << 8
                | UInt32(datagram[start + 4])
        )
        guard let initialType = Self.initialType(of: version) else {
            throw QUICInitialError.unsupportedVersion(version)
        }
        guard first & Self.typeMask == initialType else { throw QUICInitialError.notAnInitial }

        var index = start + 5
        let destinationID = try Self.readConnectionID(from: datagram, at: &index)
        let sourceID = try Self.readConnectionID(from: datagram, at: &index)

        guard let tokenLength = QUICVarint.read(from: datagram, at: &index) else {
            throw QUICInitialError.truncated
        }
        guard tokenLength <= UInt64(datagram.endIndex - index) else { throw QUICInitialError.truncated }
        index += Int(tokenLength)

        guard let length = QUICVarint.read(from: datagram, at: &index) else {
            throw QUICInitialError.truncated
        }
        guard length <= UInt64(datagram.endIndex - index) else { throw QUICInitialError.truncated }
        guard length >= UInt64(Self.sampleOffset + QUICHeaderProtection.sampleLength) else {
            throw QUICInitialError.tooShortToSample
        }

        self.version = version
        self.destinationConnectionID = destinationID
        self.sourceConnectionID = sourceID
        self.tokenLength = Int(tokenLength)
        self.packetNumberOffset = index - start
        self.packetLength = index - start + Int(length)
    }

    /// Los dos bits de tipo de un Initial, ya en su sitio dentro del primer byte: `00` en la
    /// versión 1 (RFC 9000 § 17.2.2) y `01` en la 2, que los cambió todos (RFC 9369 § 3.2).
    private static func initialType(of version: QUICVersion) -> UInt8? {
        switch version {
        case .v1: return 0x00
        case .v2: return 0x10
        default: return nil
        }
    }

    private static func readConnectionID(from datagram: Data, at index: inout Data.Index) throws -> Data {
        guard index < datagram.endIndex else { throw QUICInitialError.truncated }
        let length = Int(datagram[index])
        guard length <= maxConnectionIDLength else { throw QUICInitialError.connectionIDTooLong }
        index += 1
        guard datagram.endIndex - index >= length else { throw QUICInitialError.truncated }
        defer { index += length }
        return Data(datagram[index..<index + length])
    }
}

/// Un Initial del cliente ya abierto: su número de paquete y los frames que llevaba.
///
/// Abrirlo es deshacer las dos capas de la RFC 9001: la protección de cabecera (§ 5.4), que tapa
/// cuánto mide el número de paquete y el número mismo, y el AEAD (§ 5.3), que cifra los frames y
/// autentica la cabecera. Lo que hay dentro —frames CRYPTO con el ClientHello, PADDING, a veces
/// PING o ACK— no se interpreta aquí.
public struct QUICInitialPacket: Sendable, Equatable {

    public let header: QUICInitialHeader
    public let packetNumber: UInt64
    /// El payload descifrado: la secuencia de frames, relleno incluido.
    public let frames: Data

    /// Abre el Initial con el que empieza `datagram`.
    ///
    /// - Parameters:
    ///   - header: la cabecera leída de ese mismo datagrama.
    ///   - keys: las del cliente para esta conexión, derivadas del Destination Connection ID de
    ///     su **primer** Initial — que no tiene por qué ser el de este paquete.
    ///   - largestPacketNumber: el mayor número de paquete Initial ya abierto de este cliente, o
    ///     `nil` si es el primero; con él se completa el número truncado.
    /// - Throws: `QUICInitialError.authenticationFailed` si las claves no abren el paquete; lo
    ///   demás, si el datagrama no da para intentarlo.
    public init(
        datagram: Data,
        header: QUICInitialHeader,
        keys: QUICInitialKeys,
        largestPacketNumber: UInt64?
    ) throws {
        guard keys.version == header.version else { throw QUICInitialError.keysOfAnotherVersion }
        // La cabecera pudo leerse de otro datagrama; de uno más corto no hay nada que abrir.
        guard datagram.count >= header.packetLength else { throw QUICInitialError.truncated }

        let start = datagram.startIndex
        let numberStart = start + header.packetNumberOffset
        let packetEnd = start + header.packetLength
        let sampleStart = numberStart + QUICInitialHeader.sampleOffset
        let mask = try QUICHeaderProtection.mask(
            key: keys.headerProtectionKey,
            sample: Data(datagram[sampleStart..<sampleStart + QUICHeaderProtection.sampleLength])
        )

        // En una cabecera larga la máscara solo tapa los cuatro bits bajos del primer byte.
        let firstByte = datagram[start] ^ (mask[mask.startIndex] & 0x0f)
        let numberLength = Int(firstByte & 0x03) + 1
        var truncatedNumber: UInt64 = 0
        var numberBytes = [UInt8]()
        numberBytes.reserveCapacity(numberLength)
        for offset in 0..<numberLength {
            let byte = datagram[numberStart + offset] ^ mask[mask.startIndex + 1 + offset]
            numberBytes.append(byte)
            truncatedNumber = truncatedNumber << 8 | UInt64(byte)
        }
        guard let packetNumber = QUICPacketNumber.decode(
            truncated: truncatedNumber, byteCount: numberLength, largestProcessed: largestPacketNumber
        ) else {
            // Solo pasa si se dice haber abierto ya el último número que existe: sin número no
            // hay nonce, y sin nonce el paquete no se abre.
            throw QUICInitialError.authenticationFailed
        }

        // La cabecera ya garantizó veinte bytes tras el número de paquete: caben la etiqueta y,
        // con el número más largo, cero bytes de frames.
        let cipherStart = numberStart + numberLength
        let tagStart = packetEnd - QUICInitialHeader.tagLength

        // Lo que el AEAD autentica es la cabecera tal como era antes de protegerla.
        var associatedData = Data([firstByte])
        associatedData.append(datagram[(start + 1)..<numberStart])
        associatedData.append(contentsOf: numberBytes)

        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: Self.nonce(iv: keys.iv, packetNumber: packetNumber)),
                ciphertext: datagram[cipherStart..<tagStart],
                tag: datagram[tagStart..<packetEnd]
            )
            self.frames = try AES.GCM.open(
                box, using: SymmetricKey(data: keys.key), authenticating: associatedData
            )
        } catch {
            // CryptoKit no distingue más: una etiqueta que no cuadra es todo lo que hay que saber.
            throw QUICInitialError.authenticationFailed
        }
        self.header = header
        self.packetNumber = packetNumber
    }

    /// El nonce de un paquete (RFC 9001 § 5.3): el IV con el número de paquete, en orden de red,
    /// combinado por XOR sobre sus últimos bytes.
    private static func nonce(iv: Data, packetNumber: UInt64) -> Data {
        var nonce = [UInt8](iv)
        for offset in 0..<min(8, nonce.count) {
            nonce[nonce.count - 1 - offset] ^= UInt8(truncatingIfNeeded: packetNumber >> UInt64(offset * 8))
        }
        return Data(nonce)
    }
}
