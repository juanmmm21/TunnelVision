import Foundation
import Shared

/// Lee el ClientHello que un cliente QUIC reparte por sus paquetes Initial: se le da el payload
/// ya abierto de cada uno (`QUICInitialPacket.frames`), en el orden en que lleguen, y contesta con
/// el nombre anunciado en cuanto lo tiene.
///
/// Es la unión de tres piezas que no saben unas de otras: `QUICInitialFrames` saca los CRYPTO de
/// cada payload, `QUICCryptoStream` los pone en orden, y el `ClientHelloScanner` de TCP —en su
/// modo sin capa de registro— lee el mensaje. Por eso el nombre y la oferta salen de aquí con las
/// mismas reglas que los de un flujo TLS sobre TCP: es el mismo lector.
///
/// **No abre paquetes ni guarda claves**: eso es de quien lo llama, que es también quien decide
/// cuántos Initial de un flujo mira. Y, como el escáner que lleva dentro, **termina y se queda
/// quieto**: tras un desenlace definitivo suelta lo que guardaba y no recorre un frame más.
struct QUICClientHelloScanner: Sendable {

    /// Qué se sabe del flujo tras el último Initial.
    enum Outcome: Sendable, Equatable {
        /// Falta ClientHello por llegar. El único desenlace no definitivo.
        case needMoreFrames
        /// El cliente anunció este host.
        case found(String)
        /// No habrá nombre para este flujo, y por qué.
        case unavailable(Reason)
    }

    enum Reason: Sendable, Equatable {
        /// El mensaje se recompuso y el lector no sacó nombre de él, por el motivo que da.
        case clientHello(ClientHelloScanner.Reason)
        /// El stream CRYPTO se saltó un tope antes de completar el mensaje.
        case cryptoStream(QUICCryptoStream.Exceeded)
    }

    private var stream: QUICCryptoStream
    private var scanner: ClientHelloScanner
    private var settled: Outcome?

    /// Lo que el cliente ofreció, con las mismas condiciones que `ClientHelloScanner.offer`.
    var offer: ClientTLSOffer? { scanner.offer }

    /// - Parameters:
    ///   - streamLimits: lo que puede ocupar el stream mientras tiene huecos.
    ///   - maxHandshakeBytes: el tope del mensaje ya en orden, el del `ClientHelloScanner`.
    init(streamLimits: QUICCryptoStream.Limits, maxHandshakeBytes: Int) {
        self.stream = QUICCryptoStream(limits: streamLimits)
        self.scanner = ClientHelloScanner(
            config: ClientHelloScanner.Config(maxHandshakeBytes: maxHandshakeBytes),
            framing: .handshakeMessages
        )
        self.settled = nil
    }

    /// Alimenta el escáner con el payload descifrado de un Initial del cliente.
    mutating func scan(initialPayload: Data) -> Outcome {
        if let settled { return settled }

        // Un payload que no se deja recorrer entero entrega igualmente los CRYPTO que llevaba
        // delante: lo que corta es ese paquete, no el flujo.
        for frame in QUICInitialFrames(payload: initialPayload).crypto {
            let outcome: Outcome
            switch stream.insert(frame) {
            case .exceeded(let limit):
                outcome = .unavailable(.cryptoStream(limit))
            case .delivered(let bytes):
                guard !bytes.isEmpty else { continue }
                switch scanner.scan(bytes) {
                case .needMoreBytes: continue
                case .found(let host): outcome = .found(host)
                case .unavailable(let reason): outcome = .unavailable(.clientHello(reason))
                }
            }
            // Definitivo: el stream suelta lo que tuviera pendiente, que ya no hace falta.
            stream = QUICCryptoStream(limits: stream.limits)
            settled = outcome
            return outcome
        }
        return .needMoreFrames
    }
}
