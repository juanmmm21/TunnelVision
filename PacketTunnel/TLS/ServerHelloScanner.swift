import Foundation
import Shared

/// Lee la versión de TLS y la suite de cifrado que un **servidor** eligió en su ServerHello,
/// alimentándose del stream entrante del flujo tal y como va llegando.
///
/// Es el gemelo de `ClientHelloScanner` para el otro sentido, y vale por lo mismo: el ServerHello
/// viaja **en claro**, antes de que exista ninguna clave, así que esto no descifra nada, no
/// necesita la CA local y no roza el ADR 0003. Es lo que permite decir con qué versión de TLS habló
/// una conexión que **no** se inspecciona —que son casi todas, y todas las que hacen pinning—.
///
/// **Es incremental por la misma razón que su gemelo**, aunque el caso sea otro: un ServerHello
/// cabe de sobra en un segmento, pero en TLS 1.2 el servidor suele meter en el mismo record el
/// certificado que viene detrás, y ese record sí llega partido. Contesta `.needMoreBytes` hasta
/// poder decidir.
///
/// **Termina y se queda quieto.** En cuanto devuelve algo que no es `.needMoreBytes`, suelta sus
/// buffers y todas las llamadas siguientes devuelven ese mismo desenlace sin mirar un byte más.
public struct ServerHelloScanner: Sendable {

    public struct Config: Sendable {
        /// Techo de bytes de handshake acumulados antes de rendirse, y también del tamaño que se le
        /// admite declarar a un record: un record TLS no puede llevar más de 2^14 bytes de
        /// fragmento, así que lo que no quepa aquí no es un ServerHello que vayamos a entender. El
        /// tope existe para que un stream que empieza como un handshake y sigue como cualquier otra
        /// cosa no pueda hacer crecer la memoria de la extensión.
        public var maxHandshakeBytes: Int

        public init(maxHandshakeBytes: Int = 16384) {
            self.maxHandshakeBytes = maxHandshakeBytes
        }
    }

    /// Qué se sabe del flujo tras alimentar el último trozo del stream.
    public enum Outcome: Sendable, Equatable {
        /// Aún no hay bytes suficientes para decidir. El único desenlace no definitivo.
        case needMoreBytes
        /// El servidor eligió esto.
        case found(NegotiatedTLS)
        /// No habrá lectura para este flujo, y por qué.
        case unavailable(Reason)
    }

    /// Por qué un flujo se queda sin versión negociada. Se distinguen porque significan cosas
    /// distintas en un informe: «esto no era TLS» no es un hallazgo sobre TLS, y «el servidor se
    /// negó» sí lo es.
    public enum Reason: Sendable, Equatable {
        /// El stream no empieza por un record de TLS que este escáner conozca.
        case notTLSHandshake
        /// El servidor contestó con una alerta en vez de con un ServerHello: no hubo negociación.
        /// `description` es el código de la alerta tal cual (RFC 8446 § 6), p. ej. 70 =
        /// `protocol_version` cuando no acepta ninguna de las versiones que el cliente ofreció.
        case alert(description: UInt8)
        /// Es un handshake, pero su primer mensaje no es un ServerHello.
        case notServerHello
        /// El ServerHello no se puede recorrer entero: algún vector declara más de lo que hay.
        case malformed
        /// Un record o el mensaje declaran más de `maxHandshakeBytes`.
        case tooLarge
    }

    private static let alertContentType: UInt8 = 21
    private static let handshakeContentType: UInt8 = 22
    private static let serverHelloMessageType: UInt8 = 2
    private static let supportedVersionsExtension: UInt16 = 43
    /// `legacy_version` de un record: el byte mayor es 3 en todo lo que existe.
    private static let recordVersionMajor: UInt8 = 3
    /// Una alerta son exactamente dos bytes: nivel y descripción.
    private static let alertLength = 2
    private static let randomLength = 32
    /// El `random` que convierte un ServerHello en un HelloRetryRequest: SHA-256 de la cadena
    /// "HelloRetryRequest", fijado por RFC 8446 § 4.1.3.
    private static let helloRetryRequestRandom: [UInt8] = [
        0xCF, 0x21, 0xAD, 0x74, 0xE5, 0x9A, 0x61, 0x11, 0xBE, 0x1D, 0x8C, 0x02, 0x1E, 0x65, 0xB8, 0x91,
        0xC2, 0xA2, 0x11, 0x16, 0x7A, 0xBB, 0x8C, 0x5E, 0x07, 0x9E, 0x09, 0xE2, 0xC8, 0xA8, 0x33, 0x9C,
    ]

    private let config: Config
    /// Bytes del stream aún sin trocear en records.
    private var stream: [UInt8]
    /// Payload de handshake ya extraído de los records, a la espera de completar el mensaje.
    private var handshake: [UInt8]
    /// Desenlace definitivo, si ya se alcanzó.
    private var settled: Outcome?

    public init(config: Config = Config()) {
        self.config = config
        self.stream = []
        self.handshake = []
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

    /// Trocea el stream en records y va completando el primer mensaje de handshake.
    private mutating func advance() -> Outcome {
        while true {
            // Lo primero que manda un servidor TLS es un handshake o una alerta. Cualquier otra
            // cosa se delata en el primer byte, sin esperar a la cabecera entera.
            if let contentType = stream.first,
               contentType != Self.handshakeContentType, contentType != Self.alertContentType {
                return .unavailable(.notTLSHandshake)
            }
            if stream.count >= 2, stream[1] != Self.recordVersionMajor {
                return .unavailable(.notTLSHandshake)
            }
            // Cabecera de record: tipo (1) + versión (2) + longitud (2).
            guard stream.count >= 5 else { return .needMoreBytes }

            let isAlert = stream[0] == Self.alertContentType
            let length = Int(stream[3]) << 8 | Int(stream[4])
            // Se juzga la longitud **declarada**, antes de esperar a que llegue: si no, un record
            // que dice medir 64 KiB obligaría a guardarlos enteros para acabar descartándolos.
            if isAlert {
                guard length == Self.alertLength else { return .unavailable(.malformed) }
            } else {
                guard length <= config.maxHandshakeBytes else { return .unavailable(.tooLarge) }
            }
            guard stream.count >= 5 + length else { return .needMoreBytes }

            if isAlert {
                // Una alerta en mitad de un mensaje de handshake a medio llegar también es el
                // servidor negándose: lo acumulado ya no se va a completar.
                return .unavailable(.alert(description: stream[6]))
            }

            handshake.append(contentsOf: stream[5..<(5 + length)])
            stream.removeFirst(5 + length)
            guard handshake.count <= config.maxHandshakeBytes else { return .unavailable(.tooLarge) }

            // Un mensaje incompleto no es un fallo: puede venir repartido en varios records.
            if let outcome = parseHandshakeMessage() { return outcome }
        }
    }

    /// Intenta leer el primer mensaje de handshake acumulado. `nil` = aún incompleto.
    private func parseHandshakeMessage() -> Outcome? {
        // Cabecera de mensaje: tipo (1) + longitud (3).
        guard handshake.count >= 4 else { return nil }
        guard handshake[0] == Self.serverHelloMessageType else { return .unavailable(.notServerHello) }

        let length = Int(handshake[1]) << 16 | Int(handshake[2]) << 8 | Int(handshake[3])
        guard length <= config.maxHandshakeBytes else { return .unavailable(.tooLarge) }
        guard handshake.count >= 4 + length else { return nil }

        // Lo que venga detrás en el mismo record (en TLS 1.2, el certificado) no se mira.
        return parseServerHello(handshake[4..<(4 + length)])
    }

    // MARK: - ServerHello

    /// Recorre el cuerpo del ServerHello: versión, `random`, suite elegida y, si las hay, las
    /// extensiones en busca de `supported_versions`.
    private func parseServerHello(_ body: ArraySlice<UInt8>) -> Outcome {
        var reader = TLSByteReader(body)

        guard let legacyVersion = reader.uint16(),
              let random = reader.take(Self.randomLength),
              reader.skipVector(prefix: .oneByte),    // legacy_session_id_echo
              let cipherSuite = reader.uint16(),
              reader.skip(1)                          // legacy_compression_method
        else { return .unavailable(.malformed) }

        var version = TLSProtocolVersion(rawValue: legacyVersion)

        // Un ServerHello sin bloque de extensiones es legal hasta TLS 1.2, y entonces la versión
        // es la de `legacy_version` sin más.
        if !reader.isAtEnd {
            guard let extensions = reader.vector(prefix: .twoBytes) else { return .unavailable(.malformed) }

            var list = TLSByteReader(extensions)
            while !list.isAtEnd {
                guard let type = list.uint16(), let payload = list.vector(prefix: .twoBytes) else {
                    return .unavailable(.malformed)
                }
                guard type == Self.supportedVersionsExtension else { continue }
                // En un ServerHello la extensión lleva **una** versión, la elegida, no una lista.
                var selected = TLSByteReader(payload)
                guard let selectedVersion = selected.uint16(), selected.isAtEnd else {
                    return .unavailable(.malformed)
                }
                // Manda sobre `legacy_version`: TLS 1.3 se anuncia aquí y deja el campo antiguo
                // diciendo 1.2 para que los middleboxes no corten la conexión.
                version = TLSProtocolVersion(rawValue: selectedVersion)
                break
            }
        }

        return .found(NegotiatedTLS(
            version: version,
            cipherSuite: TLSCipherSuite(rawValue: cipherSuite),
            fromHelloRetryRequest: random.elementsEqual(Self.helloRetryRequestRandom),
            source: .serverHello
        ))
    }
}
