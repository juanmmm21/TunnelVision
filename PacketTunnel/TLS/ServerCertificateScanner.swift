import Foundation
import Shared

/// Lee la cadena de certificados que un servidor presenta en un handshake de **TLS ≤ 1.2**,
/// siguiendo el stream entrante justo donde lo dejó `ServerHelloScanner`.
///
/// Hasta TLS 1.2 el mensaje `Certificate` viaja **en claro**, detrás del ServerHello y antes de
/// que exista ninguna clave: leerlo no descifra nada, no usa la CA local y no roza el ADR 0003.
/// En TLS 1.3 va cifrado, y por eso este escáner no se crea para un flujo 1.3 —lo decide quien lo
/// conduce, con `TLSProtocolVersion.sendsCertificateInClear`—.
///
/// **Es un relevo y no un estado más de `ServerHelloScanner`** porque contestan cosas distintas en
/// momentos distintos: la versión se cuenta en cuanto se lee, y la cadena llega varios segmentos
/// después o no llega (una sesión reanudada no vuelve a mandar certificado). Un solo escáner
/// obligaría a retener la primera hasta saber de la segunda. Lo que los une es el stream, y eso es
/// lo que se pasan (`ServerHelloScanner.Remainder`).
///
/// **Termina y se queda quieto**, como sus hermanos: en cuanto decide, suelta sus buffers.
public struct ServerCertificateScanner: Sendable {

    public struct Config: Sendable {
        /// Techo de bytes del mensaje `Certificate` que se acumulan. Una cadena normal ocupa de 3
        /// a 6 KiB; lo que pase de aquí **se lee hasta donde quepa** y la cadena sale marcada
        /// incompleta, en vez de perderse entera: el certificado del servidor va el primero.
        public var maxChainBytes: Int
        /// Cuántos certificados se guardan como mucho. Los que haya detrás dejan la cadena
        /// incompleta.
        public var maxCertificates: Int
        /// Tope, en caracteres, del texto de un sujeto o un emisor.
        public var maxNameLength: Int

        public init(maxChainBytes: Int = 32768, maxCertificates: Int = 8, maxNameLength: Int = 256) {
            self.maxChainBytes = maxChainBytes
            self.maxCertificates = maxCertificates
            self.maxNameLength = maxNameLength
        }
    }

    public enum Outcome: Sendable, Equatable {
        /// Aún no hay bytes suficientes para decidir. El único desenlace no definitivo.
        case needMoreBytes
        /// Se sabe qué presentó el servidor, o que no presentó nada y por qué.
        case found(ServerCertificateReading)
        /// No habrá lectura para este flujo, y por qué.
        case unavailable(Reason)
    }

    public enum Reason: Sendable, Equatable {
        /// Lo que sigue al ServerHello no es un record de un handshake de TLS.
        case notTLSHandshake
        /// El servidor cortó con una alerta después de su ServerHello.
        case alert(description: UInt8)
        /// El handshake siguió con un mensaje que no es ninguno de los que pueden ir ahí.
        case unexpectedMessage(type: UInt8)
        /// Un record o el mensaje `Certificate` declaran algo que no cuadra con lo que llevan.
        case malformed
    }

    /// Tipos de mensaje de handshake (registro *TLS HandshakeType* de IANA).
    private enum MessageType {
        static let newSessionTicket: UInt8 = 4
        static let certificate: UInt8 = 11
        static let serverKeyExchange: UInt8 = 12
        static let serverHelloDone: UInt8 = 14
    }

    /// Cabecera de un mensaje de handshake: tipo (1) + longitud (3).
    private static let messageHeaderLength = 4
    /// El prefijo de longitud de la lista de certificados.
    private static let listPrefixLength = 3

    private let config: Config
    /// Bytes del stream aún sin trocear en records.
    private var stream: [UInt8]
    /// Bytes de handshake ya sacados de sus records: el mensaje que sigue al ServerHello.
    private var handshake: [UInt8]
    private var settled: Outcome?

    /// - Parameter remainder: lo que `ServerHelloScanner` tenía ya detrás del ServerHello. La
    ///   primera llamada a `scan` puede decidir sin un byte nuevo, si la cadena venía entera ahí.
    public init(resuming remainder: ServerHelloScanner.Remainder, config: Config = Config()) {
        self.config = config
        self.stream = remainder.stream
        self.handshake = Array(remainder.handshake.prefix(Self.messageHeaderLength + config.maxChainBytes))
        self.settled = nil
    }

    /// Alimenta el escáner con el siguiente trozo del stream entrante y devuelve qué se sabe ya.
    public mutating func scan(_ bytes: Data) -> Outcome {
        if let settled { return settled }

        stream.append(contentsOf: bytes)
        let outcome = advance()
        guard outcome != .needMoreBytes else { return outcome }

        stream = []
        handshake = []
        settled = outcome
        return outcome
    }

    // MARK: - Records

    private mutating func advance() -> Outcome {
        while true {
            if let outcome = decide() { return outcome }

            let contentType: UInt8
            let length: Int
            switch TLSRecordHeader.read(stream, accepting: [
                TLSRecordHeader.ContentType.handshake,
                TLSRecordHeader.ContentType.alert,
                TLSRecordHeader.ContentType.changeCipherSpec,
            ]) {
            case .needMoreBytes:
                return .needMoreBytes
            case .notTLS:
                return .unavailable(.notTLSHandshake)
            case .record(let type, let declared):
                contentType = type
                length = declared
            }
            // Se juzga la longitud declarada antes de esperar a que llegue, como en el ServerHello.
            if contentType == TLSRecordHeader.ContentType.alert {
                guard length == TLSRecordHeader.alertLength else { return .unavailable(.malformed) }
            } else {
                guard length <= TLSRecordHeader.maxFragmentLength else { return .unavailable(.malformed) }
            }
            guard stream.count >= TLSRecordHeader.length + length else { return .needMoreBytes }

            switch contentType {
            case TLSRecordHeader.ContentType.alert:
                return .unavailable(.alert(description: stream[TLSRecordHeader.length + 1]))
            case TLSRecordHeader.ContentType.changeCipherSpec:
                // Un ChangeCipherSpec justo detrás del ServerHello es el handshake abreviado: el
                // servidor pasa a cifrar sin presentarse. En mitad de un mensaje a medio llegar
                // no es nada que exista.
                return handshake.isEmpty ? .found(.notSent(.resumedSession)) : .unavailable(.malformed)
            default:
                // Solo se guarda lo que `decide` puede llegar a mirar: el resto del record se
                // suelta, y con ello el buffer no pasa del tope venga lo que venga.
                let room = Self.messageHeaderLength + config.maxChainBytes - handshake.count
                let fragment = stream[TLSRecordHeader.length..<(TLSRecordHeader.length + length)]
                handshake.append(contentsOf: fragment.prefix(max(0, room)))
                stream.removeFirst(TLSRecordHeader.length + length)
            }
        }
    }

    // MARK: - El mensaje que sigue al ServerHello

    /// Qué dice lo acumulado, o `nil` si todavía no alcanza.
    private func decide() -> Outcome? {
        guard let type = handshake.first else { return nil }
        switch type {
        case MessageType.certificate:
            break
        case MessageType.newSessionTicket:
            // Solo va ahí en un handshake abreviado que además renueva el ticket (RFC 5077 § 3.1).
            return .found(.notSent(.resumedSession))
        case MessageType.serverKeyExchange, MessageType.serverHelloDone:
            // Handshake completo que se salta el certificado: suite anónima o de clave
            // precompartida.
            return .found(.notSent(.noCertificateMessage))
        default:
            return .unavailable(.unexpectedMessage(type: type))
        }

        guard handshake.count >= Self.messageHeaderLength else { return nil }
        let declared = Int(handshake[1]) << 16 | Int(handshake[2]) << 8 | Int(handshake[3])
        let isWhole = declared <= config.maxChainBytes
        let wanted = Self.messageHeaderLength + (isWhole ? declared : config.maxChainBytes)
        guard handshake.count >= wanted else { return nil }

        return parseCertificate(handshake[Self.messageHeaderLength..<wanted], isWhole: isWhole)
    }

    /// Recorre la lista de certificados del mensaje.
    ///
    /// - Parameter isWhole: `body` es el mensaje entero. Si no lo es —no cabía en el tope— lo
    ///   que no se pueda recorrer es simplemente donde se acabó lo guardado, no un mensaje roto.
    private func parseCertificate(_ body: ArraySlice<UInt8>, isWhole: Bool) -> Outcome {
        var reader = TLSByteReader(body)
        guard let listLength = reader.uint24() else {
            return isWhole ? .unavailable(.malformed) : Self.chain([], isComplete: false)
        }
        if isWhole {
            guard listLength == body.count - Self.listPrefixLength else { return .unavailable(.malformed) }
        }

        var certificates: [ServerCertificate] = []
        while !reader.isAtEnd {
            guard certificates.count < config.maxCertificates else {
                return Self.chain(certificates, isComplete: false)
            }
            guard let der = reader.vector(prefix: .threeBytes) else {
                return isWhole ? .unavailable(.malformed) : Self.chain(certificates, isComplete: false)
            }
            // Uno que no se deja leer para la lectura en vez de saltarse: así lo guardado es
            // siempre el principio de la cadena y su primer elemento es el del servidor.
            guard let certificate = ServerCertificateReader.certificate(
                fromDER: der, maxNameLength: config.maxNameLength
            ) else {
                return Self.chain(certificates, isComplete: false)
            }
            certificates.append(certificate)
        }
        return Self.chain(certificates, isComplete: isWhole)
    }

    private static func chain(_ certificates: [ServerCertificate], isComplete: Bool) -> Outcome {
        .found(.chain(ServerCertificateChain(certificates: certificates, isComplete: isComplete)))
    }
}
