import Foundation
import Shared

/// Reconoce con qué empieza el stream saliente de un flujo TCP: un handshake de TLS, una petición
/// de HTTP en claro, o ninguna de las dos (`StreamOpening`).
///
/// Es lo que permite decir de un flujo fuera del 443 algo que no sea su número de puerto, y lee
/// solo lo que el dispositivo de su dueño mandó en claro: no descifra nada ni roza el ADR 0003.
///
/// **No guarda bytes.** Es una máquina de estados que avanza byte a byte y solo lleva la cuenta de
/// dónde está: se crea uno por flujo TCP dentro de una extensión con presupuesto de memoria, y la
/// mayoría de los streams se deciden en los seis primeros bytes.
///
/// **Termina y se queda quieto**, como `ClientHelloScanner`: en cuanto decide, todas las llamadas
/// siguientes devuelven lo mismo sin mirar un byte más.
///
/// **Es estricto a propósito con HTTP.** De aquí sale la única afirmación de «esto iba sin cifrar»
/// que hace la herramienta, así que no basta con que el stream empiece por `GET `: tiene que
/// pasar la línea de petición entera de RFC 9112 § 3 —método, destino, `HTTP/x.y` y fin de línea—.
/// Lo que no llega a tanto es `unrecognised`, que no afirma nada.
public struct StreamOpeningScanner: Sendable {

    public struct Config: Sendable {
        /// Techo de bytes de una línea de petición antes de rendirse. RFC 9112 § 3 recomienda
        /// aceptar líneas de al menos 8000 octetos; una más larga que esto se deja sin reconocer
        /// en vez de seguir mirando un stream que quizá no sea HTTP.
        public var maxRequestLineBytes: Int

        public init(maxRequestLineBytes: Int = 8192) {
            self.maxRequestLineBytes = maxRequestLineBytes
        }
    }

    public enum Outcome: Sendable, Equatable {
        /// Aún no hay bytes suficientes para decidir. El único desenlace no definitivo.
        case needMoreBytes
        case decided(StreamOpening)
    }

    private enum State {
        case start
        /// Verificando la cabecera de un record de TLS; `index` es el byte que toca mirar.
        case tlsRecord(index: Int, length: Int)
        case httpMethod
        case httpTarget(length: Int)
        /// Cuántos caracteres de `HTTP/d.d` llevan casados.
        case httpVersion(matched: Int)
        /// Visto el CR tras la versión: falta el LF.
        case httpLineFeed
        case decided(StreamOpening)
    }

    private let config: Config
    private var state: State = .start
    private var consumed = 0

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Alimenta el siguiente trozo del stream saliente, en orden.
    public mutating func scan(_ data: Data) -> Outcome {
        for byte in data {
            if case .decided(let opening) = state { return .decided(opening) }
            consumed += 1
            state = Self.advance(state, with: byte)
            if consumed >= config.maxRequestLineBytes, !isDecided {
                state = .decided(.unrecognised)
            }
        }
        if case .decided(let opening) = state { return .decided(opening) }
        return .needMoreBytes
    }

    private var isDecided: Bool {
        if case .decided = state { return true }
        return false
    }

    private static let handshakeContentType: UInt8 = 22
    private static let clientHelloMessageType: UInt8 = 1
    /// El byte mayor de `legacy_record_version`: 3 en todo lo que existe, de SSL 3.0 a TLS 1.3.
    private static let tlsMajorVersion: UInt8 = 3
    private static let highestTLSMinorVersion: UInt8 = 4
    /// Un record de TLS en claro no lleva más de 2^14 bytes de fragmento (RFC 8446 § 5.1).
    private static let maxRecordLength = 1 << 14
    /// Cabecera de un mensaje de handshake: lo mínimo que tiene que caber en el record.
    private static let handshakeHeaderLength = 4
    private static let versionPattern = Array("HTTP/".utf8)

    private static func advance(_ state: State, with byte: UInt8) -> State {
        switch state {
        case .start:
            if byte == handshakeContentType { return .tlsRecord(index: 1, length: 0) }
            return isTokenCharacter(byte) ? .httpMethod : .decided(.unrecognised)

        case .tlsRecord(let index, let length):
            switch index {
            case 1:
                return byte == tlsMajorVersion ? .tlsRecord(index: 2, length: 0) : .decided(.unrecognised)
            case 2:
                return byte <= highestTLSMinorVersion ? .tlsRecord(index: 3, length: 0) : .decided(.unrecognised)
            case 3:
                return .tlsRecord(index: 4, length: Int(byte) << 8)
            case 4:
                let total = length | Int(byte)
                guard (handshakeHeaderLength...maxRecordLength).contains(total) else {
                    return .decided(.unrecognised)
                }
                return .tlsRecord(index: 5, length: total)
            default:
                return .decided(byte == clientHelloMessageType ? .tlsHandshake : .unrecognised)
            }

        case .httpMethod:
            if byte == space { return .httpTarget(length: 0) }
            return isTokenCharacter(byte) ? .httpMethod : .decided(.unrecognised)

        case .httpTarget(let length):
            if byte == space {
                return length > 0 ? .httpVersion(matched: 0) : .decided(.unrecognised)
            }
            return isVisibleASCII(byte) ? .httpTarget(length: length + 1) : .decided(.unrecognised)

        case .httpVersion(let matched):
            // `HTTP/` + dígito + `.` + dígito: ocho caracteres, y detrás el fin de línea.
            let expected: Bool
            switch matched {
            case 0..<versionPattern.count: expected = byte == versionPattern[matched]
            case 5, 7: expected = isDigit(byte)
            case 6: expected = byte == UInt8(ascii: ".")
            case 8:
                if byte == carriageReturn { return .httpLineFeed }
                // RFC 9112 § 2.2 deja al receptor aceptar un LF suelto como fin de línea.
                return .decided(byte == lineFeed ? .httpRequest : .unrecognised)
            default: expected = false
            }
            return expected ? .httpVersion(matched: matched + 1) : .decided(.unrecognised)

        case .httpLineFeed:
            return .decided(byte == lineFeed ? .httpRequest : .unrecognised)

        case .decided:
            return state
        }
    }

    private static let space = UInt8(ascii: " ")
    private static let carriageReturn = UInt8(ascii: "\r")
    private static let lineFeed = UInt8(ascii: "\n")

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    private static func isVisibleASCII(_ byte: UInt8) -> Bool {
        (0x21...0x7E).contains(byte)
    }

    /// `tchar` de RFC 9110 § 5.6.2: de lo que está hecho un método.
    private static func isTokenCharacter(_ byte: UInt8) -> Bool {
        if isDigit(byte) { return true }
        if (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) { return true }
        if (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) { return true }
        return tokenPunctuation.contains(byte)
    }

    private static let tokenPunctuation = Set("!#$%&'*+-.^_`|~".utf8)
}
