import Foundation

/// Un frame CRYPTO (RFC 9000 § 19.6): un trozo del stream de handshake de su nivel de cifrado, con
/// el desplazamiento que ocupa en él.
public struct QUICCryptoFrame: Sendable, Equatable {

    /// Dónde empieza `data` dentro del stream, que arranca en 0 en cada nivel de cifrado.
    public let offset: UInt64
    public let data: Data

    public init(offset: UInt64, data: Data) {
        self.offset = offset
        self.data = data
    }
}

/// Los frames de un paquete Initial ya abierto (`QUICInitialPacket.frames`), recorridos: de ellos
/// se quedan los CRYPTO, que son los que llevan el ClientHello, y el resto se salta.
///
/// En un Initial solo caben cinco clases de frame (RFC 9000 § 12.4, tabla 3):
///
/// ```
/// 0x00        PADDING             un byte y nada más
/// 0x01        PING                un byte y nada más
/// 0x02 0x03   ACK                 cuatro varints, sus rangos y, en el 0x03, tres contadores de ECN
/// 0x06        CRYPTO              offset, longitud y los datos
/// 0x1c        CONNECTION_CLOSE    código, tipo de frame, longitud de la frase y la frase
/// ```
///
/// Hay que saber saltar las otras cuatro porque un CRYPTO puede ir detrás de cualquiera de ellas:
/// los clientes ponen relleno delante, y el Initial que retransmite un ClientHello suele llevar
/// antes el ACK del Initial del servidor.
public struct QUICInitialFrames: Sendable, Equatable {

    /// Por qué el recorrido se paró antes de acabar el payload.
    public enum Stop: Error, Sendable, Equatable {
        /// Un tipo de frame que un Initial no puede llevar, o que no se conoce: sin saber cuánto
        /// mide no se sabe dónde empieza el siguiente.
        case unexpectedFrameType(UInt64)
        /// Un frame declara más de lo que queda de payload.
        case truncated
        /// Un CRYPTO que acaba más allá de 2^62 − 1, el mayor desplazamiento que existe (§ 19.6).
        case cryptoBeyondStreamLimit
    }

    /// Los CRYPTO leídos, en el orden en que viajan — que no es el de sus desplazamientos.
    public let crypto: [QUICCryptoFrame]
    /// `nil` si se recorrió el payload entero.
    ///
    /// **Lo leído antes de pararse se conserva**, y pararse corta este paquete, no la conexión: es
    /// su destinatario quien la cierra por un frame que no toca, y lo que el cliente ya había
    /// dicho en los frames de delante lo dijo igual.
    public let stop: Stop?

    private static let paddingType: UInt64 = 0x00
    private static let pingType: UInt64 = 0x01
    private static let ackType: UInt64 = 0x02
    private static let ackWithECNType: UInt64 = 0x03
    private static let cryptoType: UInt64 = 0x06
    /// El CONNECTION_CLOSE de la capa de QUIC. El 0x1d, el de la aplicación, no cabe en un Initial.
    private static let connectionCloseType: UInt64 = 0x1c
    private static let padding: UInt8 = 0x00

    /// Recorre `payload`, el contenido descifrado de un Initial.
    public init(payload: Data) {
        var crypto: [QUICCryptoFrame] = []
        var stop: Stop?
        var index = payload.startIndex

        walk: while index < payload.endIndex {
            // El relleno son cientos de bytes a cero seguidos (un Initial del cliente se infla
            // hasta 1200): se saltan sin pasar cada uno por el lector de varints.
            if payload[index] == Self.padding {
                index += 1
                continue
            }
            // El tipo se lee como el varint que es y se acepta aunque no venga en su codificación
            // más corta: rechazarlo es un MAY de su destinatario (§ 12.4), no cosa de quien mira.
            guard let type = QUICVarint.read(from: payload, at: &index) else {
                stop = .truncated
                break
            }
            switch type {
            case Self.paddingType, Self.pingType:
                continue
            case Self.ackType, Self.ackWithECNType:
                guard Self.skipACK(in: payload, at: &index, hasECNCounts: type == Self.ackWithECNType) else {
                    stop = .truncated
                    break walk
                }
            case Self.cryptoType:
                switch Self.readCrypto(from: payload, at: &index) {
                case .success(let frame):
                    crypto.append(frame)
                case .failure(let reason):
                    stop = reason
                    break walk
                }
            case Self.connectionCloseType:
                guard Self.skipConnectionClose(in: payload, at: &index) else {
                    stop = .truncated
                    break walk
                }
            default:
                stop = .unexpectedFrameType(type)
                break walk
            }
        }

        self.crypto = crypto
        self.stop = stop
    }

    /// Salta un ACK (§ 19.3) cuyo tipo ya se leyó. Lo que reconoce no se comprueba: que sus rangos
    /// den un número de paquete negativo es asunto de quien lo recibe.
    private static func skipACK(in payload: Data, at index: inout Data.Index, hasECNCounts: Bool) -> Bool {
        guard skipVarints(2, in: payload, at: &index),                  // Largest Acknowledged, ACK Delay
              let rangeCount = QUICVarint.read(from: payload, at: &index),
              skipVarints(1, in: payload, at: &index)                   // First ACK Range
        else { return false }

        // Cada rango son dos varints (Gap y ACK Range Length) y por tanto dos bytes como poco: una
        // cuenta que no cabe en lo que queda se rechaza sin recorrerla, que la elige el otro extremo.
        guard rangeCount <= UInt64(payload.endIndex - index) / 2,
              skipVarints(Int(rangeCount) * 2, in: payload, at: &index)
        else { return false }

        return hasECNCounts ? skipVarints(3, in: payload, at: &index) : true
    }

    /// Lee un CRYPTO (§ 19.6) cuyo tipo ya se leyó.
    private static func readCrypto(from payload: Data, at index: inout Data.Index) -> Result<QUICCryptoFrame, Stop> {
        guard let offset = QUICVarint.read(from: payload, at: &index),
              let length = QUICVarint.read(from: payload, at: &index),
              length <= UInt64(payload.endIndex - index)
        else { return .failure(.truncated) }

        // Los dos son varints, así que ninguno pasa de 2^62 − 1 y la suma no desborda.
        guard offset + length <= QUICPacketNumber.maximum else { return .failure(.cryptoBeyondStreamLimit) }

        let end = index + Int(length)
        defer { index = end }
        return .success(QUICCryptoFrame(offset: offset, data: Data(payload[index..<end])))
    }

    /// Salta un CONNECTION_CLOSE de tipo 0x1c (§ 19.19) cuyo tipo ya se leyó.
    private static func skipConnectionClose(in payload: Data, at index: inout Data.Index) -> Bool {
        guard skipVarints(2, in: payload, at: &index),                  // Error Code, Frame Type
              let reasonLength = QUICVarint.read(from: payload, at: &index),
              reasonLength <= UInt64(payload.endIndex - index)
        else { return false }
        index += Int(reasonLength)
        return true
    }

    private static func skipVarints(_ count: Int, in payload: Data, at index: inout Data.Index) -> Bool {
        for _ in 0..<count {
            guard QUICVarint.read(from: payload, at: &index) != nil else { return false }
        }
        return true
    }
}
