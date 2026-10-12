import Foundation
import Shared

/// Lo que un flujo QUIC necesita recordar para que de sus primeros datagramas salga el nombre que
/// el cliente anuncia: las claves con las que se abren sus paquetes Initial, el mayor número de
/// paquete abierto y el `QUICClientHelloScanner` que va recomponiendo el mensaje.
///
/// Se le dan los payloads UDP **que manda el cliente**, enteros y en el orden en que lleguen, y
/// contesta con el nombre en cuanto lo tiene. Es la pieza que faltaba entre abrir un paquete y
/// leer un mensaje: sabe qué claves tocan y cuándo dejar de mirar.
///
/// **Termina y se queda quieto**, como los escáneres que lleva dentro: tras un desenlace
/// definitivo no abre un paquete más. Quien lo usa lo suelta entonces, que es lo que devuelve su
/// memoria.
///
/// Las claves de un Initial salen de constantes públicas y de un identificador que viaja en
/// claro: las deriva cualquiera que vea pasar el paquete, y así está diseñado (RFC 9001 § 5.2).
/// De ahí en adelante —Handshake, 1-RTT— las claves son de los dos extremos y aquí no se tocan.
public struct QUICClientHelloReader: Sendable {

    /// Cuánto se mira de un flujo y cuánta memoria puede ocupar mientras se mira. Sin valores
    /// por defecto: los bytes los escribe el otro extremo y esto corre en la extensión.
    public struct Limits: Sendable, Equatable {
        /// Paquetes Initial del cliente que se intentan abrir por flujo, se abran o no.
        public let maxInitialPackets: Int
        /// Lo que puede ocupar el stream CRYPTO mientras tiene huecos.
        public let stream: QUICCryptoStream.Limits
        /// El tope del ClientHello ya en orden.
        public let maxHandshakeBytes: Int

        public init(maxInitialPackets: Int, stream: QUICCryptoStream.Limits, maxHandshakeBytes: Int) {
            self.maxInitialPackets = maxInitialPackets
            self.stream = stream
            self.maxHandshakeBytes = maxHandshakeBytes
        }

        /// Los del túnel, puestos sobre lo medido en clientes de verdad (`QUICClientCaptures`):
        /// el ClientHello de la pila de Apple son 1 506 bytes y el de Chrome 1 951, los dos en
        /// dos Initial, y Chrome llega a meter once frames CRYPTO barajados en un paquete.
        ///
        /// - Ocho Initial: cuatro veces los dos que hacen falta, para que un Retry (que obliga a
        ///   mandarlo todo otra vez) y un par de retransmisiones no dejen el flujo sin leer.
        /// - 8 192 bytes de stream y de mensaje: cuatro veces el mayor medido. Un flujo a medio
        ///   leer no puede retener más que eso dos veces.
        /// - 32 trozos esperando: casi tres veces los once frames del paquete más troceado que
        ///   se ha visto, que es lo que quedaría esperando si ninguno se tocara con otro.
        public static let tunnel = Limits(
            maxInitialPackets: 8,
            stream: QUICCryptoStream.Limits(maxStreamBytes: 8_192, maxPendingFragments: 32),
            maxHandshakeBytes: 8_192
        )
    }

    /// Qué se sabe del flujo tras el último datagrama.
    enum Outcome: Sendable, Equatable {
        /// Falta ClientHello por llegar. El único desenlace no definitivo.
        case needMoreInitials
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
        /// Se miraron todos los Initial que se miran de un flujo y el mensaje no estaba entero.
        case initialsExhausted
    }

    /// Lo que pasó al darle un datagrama.
    struct Reading: Sendable, Equatable {
        var outcome: Outcome
        /// Lo que el cliente ofreció en su ClientHello. Solo en la lectura que decide el
        /// desenlace, y no con todos: hace falta haber leído el mensaje entero.
        var offer: ClientTLSOffer?
        /// Paquetes Initial de este datagrama que se abrieron.
        var opened: Int
        /// Paquetes Initial de este datagrama que se intentaron abrir y no se dejaron.
        var notOpened: Int
        /// La lectura volvió a empezar con las claves de otro Connection ID.
        var restarted: Bool

        /// El datagrama llevaba al menos un Initial que se intentó abrir.
        var attemptedAnInitial: Bool { opened + notOpened > 0 }
    }

    /// De qué salieron las claves que se están usando.
    private struct KeySource: Sendable, Equatable {
        let version: QUICVersion
        let connectionID: Data
    }

    private let limits: Limits
    private var keys: QUICInitialKeys?
    private var keySource: KeySource?
    private var largestPacketNumber: UInt64?
    private var scanner: QUICClientHelloScanner
    private var attempts: Int
    private var settled: Outcome?

    init(limits: Limits) {
        self.limits = limits
        self.keys = nil
        self.keySource = nil
        self.largestPacketNumber = nil
        self.scanner = Self.makeScanner(limits)
        self.attempts = 0
        self.settled = nil
    }

    private static func makeScanner(_ limits: Limits) -> QUICClientHelloScanner {
        QUICClientHelloScanner(streamLimits: limits.stream, maxHandshakeBytes: limits.maxHandshakeBytes)
    }

    /// Lee los Initial con los que empieza el payload de un datagrama UDP del cliente.
    ///
    /// Un datagrama puede llevar varios paquetes seguidos (RFC 9000 § 12.2): se recorren mientras
    /// sean Initial y se para en el primero que no lo sea, porque lo de detrás —0-RTT, Handshake,
    /// relleno— no es de esta lectura.
    mutating func read(datagram: Data) -> Reading {
        var reading = Reading(
            outcome: settled ?? .needMoreInitials, offer: nil, opened: 0, notOpened: 0, restarted: false
        )
        var rest = datagram
        while settled == nil, !rest.isEmpty {
            let header: QUICInitialHeader
            do {
                header = try QUICInitialHeader(datagram: rest)
            } catch {
                // No es un Initial de una versión conocida, o no cabe en lo que queda: no hay
                // paquete que abrir ni longitud con la que saltar al siguiente.
                break
            }

            attempts += 1
            if let packet = open(rest, header: header, restarted: &reading.restarted) {
                reading.opened += 1
                largestPacketNumber = max(largestPacketNumber ?? 0, packet.packetNumber)
                switch scanner.scan(initialPayload: packet.frames) {
                case .needMoreFrames:
                    break
                case .found(let host):
                    settle(.found(host), in: &reading)
                case .unavailable(.clientHello(let reason)):
                    settle(.unavailable(.clientHello(reason)), in: &reading)
                case .unavailable(.cryptoStream(let limit)):
                    settle(.unavailable(.cryptoStream(limit)), in: &reading)
                }
            } else {
                reading.notOpened += 1
            }
            // Agotado en el acto y no al llegar el siguiente, que puede no llegar nunca: es lo
            // que le deja a quien llama soltar esto ya.
            if settled == nil, attempts >= limits.maxInitialPackets {
                settle(.unavailable(.initialsExhausted), in: &reading)
            }
            rest = rest.dropFirst(header.packetLength)
        }
        return reading
    }

    private mutating func settle(_ outcome: Outcome, in reading: inout Reading) {
        settled = outcome
        reading.outcome = outcome
        reading.offer = scanner.offer
        // Ya no hace falta nada de lo que se guardaba: las claves no van a abrir otro paquete, y
        // un escáner nuevo suelta lo que el anterior tuviera a medio recomponer.
        keys = nil
        scanner = Self.makeScanner(limits)
    }

    /// Abre el Initial con el que empieza `datagram`, con las claves de la conexión o, si no
    /// sirven, con las de su propio Connection ID.
    private mutating func open(
        _ datagram: Data, header: QUICInitialHeader, restarted: inout Bool
    ) -> QUICInitialPacket? {
        let own = KeySource(version: header.version, connectionID: header.destinationConnectionID)

        if let keys {
            do {
                return try QUICInitialPacket(
                    datagram: datagram, header: header, keys: keys, largestPacketNumber: largestPacketNumber
                )
            } catch QUICInitialError.authenticationFailed, QUICInitialError.keysOfAnotherVersion {
                // Las claves son las del primer Connection ID del cliente, y sirven aunque el de
                // destino cambie por el camino. Dejan de servir tras un Retry —el cliente vuelve
                // a empezar con el identificador que le dio el servidor— o si por el mismo par de
                // puertos empieza otra conexión: en los dos casos las buenas son las de este
                // paquete. Con las mismas de antes no hay nada nuevo que probar.
                guard own != keySource else { return nil }
            } catch {
                return nil
            }
        }

        guard let fresh = QUICInitialKeys(version: own.version, clientDestinationConnectionID: own.connectionID) else {
            return nil
        }
        do {
            let packet = try QUICInitialPacket(
                datagram: datagram, header: header, keys: fresh, largestPacketNumber: nil
            )
            if keySource != nil {
                // Empieza de cero: tras un Retry el ClientHello se manda otra vez desde el
                // principio, y si es otra conexión lo que había recompuesto no era suyo.
                scanner = Self.makeScanner(limits)
                largestPacketNumber = nil
                restarted = true
            }
            keys = fresh
            keySource = own
            return packet
        } catch {
            return nil
        }
    }
}
