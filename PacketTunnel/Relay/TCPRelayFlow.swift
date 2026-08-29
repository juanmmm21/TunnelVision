import Foundation
import Shared

/// Máquina de estados TCP en userspace para el passthrough de un flujo, en el papel de **servidor**
/// hacia el dispositivo.
///
/// El dispositivo cree que abre un TCP directo contra el servidor real, pero sus datagramas los
/// intercepta la extensión. A diferencia de UDP —que es sin estado y se reenvía tal cual— TCP hay que
/// **terminarlo** aquí: respondemos al SYN del dispositivo, le mandamos SYN-ACK con nuestro propio ISN,
/// le vamos ACKeando lo que envía, y extraemos su stream de aplicación para reenviarlo por una
/// `NWConnection` que hace su propio TCP contra el servidor. En sentido inverso, los bytes de
/// aplicación que llegan del servidor se **re-segmentan** con nuestros números de secuencia y se
/// emiten hacia el dispositivo. Los dos sentidos son dos espacios de secuencia de 32 bits
/// independientes que **dan la vuelta**: toda comparación usa aritmética serial (RFC 1982).
///
/// Este tipo es **puro y síncrono**: no conoce `NWConnection`, ni el `PacketEmitter`, ni el reinjector.
/// Recibe eventos (`receiveFromDevice`, `receiveFromServer`, `serverDidConnect/Close/Fail`) y devuelve
/// una lista de `TCPRelayAction` que el `Relay` (actor) ejecuta: abrir/escribir/cerrar la conexión
/// saliente, y serializar+reinyectar segmentos hacia el dispositivo. Esa separación es la misma que el
/// pipeline (M7) y el relay UDP hacen con sus sumideros inyectados: la lógica corre en Simulator contra
/// aserciones directas, y lo device-only (la `NWConnection` TCP y el emisor) queda como cáscara fina.
///
/// **Alcance (passthrough, no inspección):** reensambla el stream saliente del dispositivo con
/// `TCPReassembler` (M4) para entregarlo en orden al servidor, y respeta la **ventana anunciada por el
/// dispositivo** para no desbordar su buffer de recepción. No implementa control de congestión ni
/// retransmisión hacia el dispositivo (el camino dispositivo↔extensión es local y sin pérdidas; una
/// retransmisión del dispositivo se absorbe idempotentemente vía el reensamblador). Las degradaciones
/// están acotadas: si el reensamblador se desborda (hueco enorme) o el buffer hacia el dispositivo
/// supera su techo, se aborta el flujo con RST en vez de crecer sin límite.
public struct TCPRelayFlow: Sendable {

    public struct Config: Sendable {
        /// Payload máximo por segmento emitido hacia el dispositivo. Por debajo de la MTU típica del
        /// túnel; el emisor no fragmenta, así que segmentar es cosa de este tipo.
        public var mss: Int
        /// Ventana de recepción que anunciamos al dispositivo. Constante: consumimos su stream de
        /// inmediato (lo pasamos al reensamblador y de ahí al servidor), así que no necesitamos cerrar
        /// la ventana; el techo real del reensamblador acota la memoria.
        public var advertisedWindow: UInt16
        /// Techo duro de bytes del servidor pendientes de emitir al dispositivo (ventana cerrada). Si se
        /// supera, se aborta el flujo. Red de seguridad: en la práctica el `Relay` pacea las lecturas de
        /// la `NWConnection`, así que rara vez se toca.
        public var maxPendingToDeviceBytes: Int
        /// Configuración del reensamblador del stream saliente (dispositivo → servidor).
        public var reassembly: TCPReassembler.Config

        public init(
            mss: Int = 1400,
            advertisedWindow: UInt16 = 65535,
            maxPendingToDeviceBytes: Int = 4 * 1024 * 1024,
            reassembly: TCPReassembler.Config = TCPReassembler.Config()
        ) {
            self.mss = mss
            self.advertisedWindow = advertisedWindow
            self.maxPendingToDeviceBytes = maxPendingToDeviceBytes
            self.reassembly = reassembly
        }
    }

    /// Fase del flujo. El cierre a medias (una dirección FIN, la otra abierta) se modela con banderas
    /// internas (`deviceFinConsumed`, `weSentFin`) en vez de enumerar todos los estados de RFC 9293:
    /// para un relay de passthrough basta con "al menos una dirección cerrando" (`.closing`).
    public enum State: Sendable, Equatable {
        case listen         // esperando el SYN del dispositivo
        case connecting     // SYN recibido; abriendo la conexión saliente, aún sin SYN-ACK
        case synReceived    // SYN-ACK enviado; esperando el ACK del handshake
        case established
        case closing        // al menos una dirección mandó FIN; la otra puede seguir
        case closed
    }

    private let config: Config
    private let serverISN: UInt32

    private(set) public var state: State

    // Sentido dispositivo → servidor.
    private var reassembler: TCPReassembler?
    private var clientISN: UInt32
    private var deviceFinConsumed: Bool
    private var deviceFinSeq: UInt32

    // Sentido servidor → dispositivo.
    private var sendNext: UInt32        // próximo número de secuencia a asignar
    private var sendUnacked: UInt32     // secuencia sin ACKear más antigua (base de la ventana)
    private var deviceWindow: UInt16    // ventana anunciada por el dispositivo (última vista)
    private var pendingToDevice: Data   // bytes del servidor aún no emitidos (ventana cerrada)
    private var weSentSynAck: Bool
    private var weSentFin: Bool
    private var weSentFinSeq: UInt32
    private var ourFinAcked: Bool
    private var serverClosed: Bool      // EOF del servidor recibido

    /// - Parameter serverISN: ISN del lado servidor (nuestro), en el SYN-ACK. Lo aporta quien crea el
    ///   flujo, no se genera aquí: en producción debe ser **impredecible** (lo genera el `Relay` con el
    ///   RNG del sistema, requisito de seguridad de TCP); en tests se pasa un valor conocido para que el
    ///   round-trip de secuencias sea determinista.
    public init(config: Config = Config(), serverISN: UInt32) {
        self.config = config
        self.serverISN = serverISN
        self.state = .listen
        self.reassembler = nil
        self.clientISN = 0
        self.deviceFinConsumed = false
        self.deviceFinSeq = 0
        self.sendNext = 0
        self.sendUnacked = 0
        self.deviceWindow = 0
        self.pendingToDevice = Data()
        self.weSentSynAck = false
        self.weSentFin = false
        self.weSentFinSeq = 0
        self.ourFinAcked = false
        self.serverClosed = false
    }

    // MARK: - Entradas del dispositivo

    /// El dispositivo envió un segmento TCP. Devuelve las acciones a ejecutar (bytes al servidor,
    /// segmentos a reinyectar, apertura/cierre de la conexión saliente).
    public mutating func receiveFromDevice(_ segment: InboundSegment) -> [TCPRelayAction] {
        guard state != .closed else { return [] }
        deviceWindow = segment.window

        // Un RST del dispositivo aborta el flujo sin respuesta: no se contesta a un RST.
        if segment.flags.contains(.rst) {
            state = .closed
            return [.teardown]
        }

        // El campo ACK abre nuestra ventana de envío (y confirma nuestro SYN/FIN si procede).
        if segment.flags.contains(.ack) {
            if seqGT(segment.acknowledgment, sendUnacked) && seqLEQ(segment.acknowledgment, sendNext) {
                sendUnacked = segment.acknowledgment
            }
            if weSentFin && seqGEQ(segment.acknowledgment, weSentFinSeq &+ 1) {
                ourFinAcked = true
            }
        }

        var actions: [TCPRelayAction] = []
        switch state {
        case .listen:
            if segment.flags.contains(.syn) {
                beginConnecting(segment, into: &actions)
            }
            // Cualquier otra cosa en `.listen` es un segmento perdido: se ignora.
        case .connecting:
            // Aún abriendo la conexión saliente: un SYN retransmitido se traga, el dispositivo no debería
            // mandar datos antes de nuestro SYN-ACK.
            break
        case .synReceived:
            if segment.flags.contains(.syn) {
                // SYN retransmitido (perdimos el SYN-ACK, o el dispositivo insiste): reenviamos SYN-ACK.
                actions.append(.segmentToDevice(synAckSegment()))
            } else if segment.flags.contains(.ack) {
                state = .established
                processPayloadAndFin(segment, into: &actions)
                flushToDevice(into: &actions)
            }
        case .established, .closing:
            processPayloadAndFin(segment, into: &actions)
            flushToDevice(into: &actions)
        case .closed:
            break
        }
        return actions
    }

    // MARK: - Entradas del servidor (vía la NWConnection)

    /// La conexión saliente hacia el servidor real quedó lista. Recién ahora mandamos el SYN-ACK al
    /// dispositivo: así el handshake refleja fielmente si el servidor aceptó (no spoofeamos un SYN-ACK
    /// que luego habría que desmentir con un RST si el servidor rechazaba).
    public mutating func serverDidConnect() -> [TCPRelayAction] {
        guard state == .connecting else { return [] }
        sendNext = serverISN &+ 1       // el SYN consume el número `serverISN`
        sendUnacked = serverISN
        weSentSynAck = true
        state = .synReceived
        return [.segmentToDevice(synAckSegment())]
    }

    /// Llegaron bytes de aplicación del servidor. Se segmentan según la ventana del dispositivo y la MSS
    /// y se emiten hacia él; lo que no cabe en la ventana se bufferiza (con techo).
    public mutating func receiveFromServer(_ bytes: Data) -> [TCPRelayAction] {
        guard state != .closed, !bytes.isEmpty else { return [] }
        pendingToDevice.append(bytes)

        var actions: [TCPRelayAction] = []
        flushToDevice(into: &actions)
        // El techo se comprueba sobre lo que quedó sin emitir: si la ventana estaba abierta, ya se drenó.
        if pendingToDevice.count > config.maxPendingToDeviceBytes {
            abortToDevice(into: &actions)
        }
        return actions
    }

    /// El servidor cerró limpiamente (EOF). Tras drenar lo pendiente, emitimos FIN al dispositivo.
    public mutating func serverDidClose() -> [TCPRelayAction] {
        guard state != .closed else { return [] }
        serverClosed = true
        var actions: [TCPRelayAction] = []
        flushToDevice(into: &actions)
        return actions
    }

    /// La conexión saliente falló (o el servidor mandó RST): abortamos el flujo con un RST hacia el
    /// dispositivo. Si aún no habíamos hecho el SYN-ACK, es una conexión rechazada y el RST responde al
    /// SYN (seq 0, ack = clientISN+1), como haría el servidor real.
    public mutating func serverDidFail() -> [TCPRelayAction] {
        guard state != .closed else { return [] }
        var actions: [TCPRelayAction] = []
        if weSentSynAck {
            actions.append(.segmentToDevice(rstSegment()))
        } else {
            actions.append(.segmentToDevice(OutboundSegment(
                sequence: 0,
                acknowledgment: clientISN &+ 1,
                flags: [.rst, .ack],
                window: 0,
                payload: Data()
            )))
        }
        state = .closed
        actions.append(.teardown)
        return actions
    }

    // MARK: - Lógica interna

    private mutating func beginConnecting(_ segment: InboundSegment, into actions: inout [TCPRelayAction]) {
        clientISN = segment.sequence
        reassembler = TCPReassembler(config: config.reassembly, isn: clientISN, direction: .outbound)
        state = .connecting
        actions.append(.connectToServer)
    }

    /// Procesa el payload (vía el reensamblador) y el FIN de un segmento del dispositivo. Emite a lo
    /// sumo un ACK (con el ack acumulado ya actualizado, incluido el FIN si se consumió en esta llamada).
    private mutating func processPayloadAndFin(_ segment: InboundSegment, into actions: inout [TCPRelayAction]) {
        var shouldAck = false

        if !segment.payload.isEmpty, var reasm = reassembler {
            let outcome = reasm.accept(sequence: segment.sequence, payload: segment.payload, flags: segment.flags)
            reassembler = reasm
            switch outcome {
            case .delivered(let data):
                actions.append(.sendToServer(data))
                shouldAck = true
            case .buffered, .duplicate:
                // Fuera de orden o retransmisión: no hay bytes nuevos para el servidor, pero re-ACKeamos
                // (un dup-ACK le dice al dispositivo qué esperamos todavía).
                shouldAck = true
            case .downgraded:
                // El reensamblado se desbordó: no podemos entregar el stream en orden, así que para un
                // passthrough fiel no queda más que abortar. No se retoma (misma política que M4/M7).
                abortToDevice(into: &actions)
                return
            }
        }

        if segment.flags.contains(.fin) {
            if !deviceFinConsumed {
                let finSeq = segment.sequence &+ UInt32(segment.payload.count)
                // Solo se consume el FIN si llega en orden (todo el stream previo ya entregado); si hay un
                // hueco, se difiere y el dispositivo lo retransmitirá.
                if finSeq == (reassembler?.expectedSequence ?? finSeq) {
                    deviceFinConsumed = true
                    deviceFinSeq = finSeq
                    if state == .established { state = .closing }
                    actions.append(.closeServerSend)
                    shouldAck = true
                }
            } else {
                // FIN retransmitido: se re-ACKea, no se vuelve a cerrar el envío al servidor.
                shouldAck = true
            }
        }

        if shouldAck {
            actions.append(.segmentToDevice(ackSegment()))
        }
    }

    /// Emite hacia el dispositivo todo lo que la ventana permita, segmentando por MSS; luego, si el
    /// servidor cerró y no queda nada pendiente, emite el FIN. Cierra el flujo si ambos sentidos
    /// terminaron.
    private mutating func flushToDevice(into actions: inout [TCPRelayAction]) {
        guard state == .established || state == .closing else { return }

        while !pendingToDevice.isEmpty {
            let inFlight = Int(sendNext &- sendUnacked)
            let windowAvailable = Int(deviceWindow) - inFlight
            guard windowAvailable > 0 else { break }

            let chunkLength = min(config.mss, windowAvailable, pendingToDevice.count)
            guard chunkLength > 0 else { break }

            let start = pendingToDevice.startIndex
            let chunk = pendingToDevice.subdata(in: start..<(start + chunkLength))
            actions.append(.segmentToDevice(OutboundSegment(
                sequence: sendNext,
                acknowledgment: ackToDevice(),
                flags: [.ack, .psh],
                window: config.advertisedWindow,
                payload: chunk
            )))
            sendNext = sendNext &+ UInt32(chunkLength)
            pendingToDevice.removeSubrange(start..<(start + chunkLength))
        }

        if pendingToDevice.isEmpty && serverClosed && !weSentFin {
            weSentFinSeq = sendNext
            actions.append(.segmentToDevice(OutboundSegment(
                sequence: sendNext,
                acknowledgment: ackToDevice(),
                flags: [.fin, .ack],
                window: config.advertisedWindow,
                payload: Data()
            )))
            sendNext = sendNext &+ 1
            weSentFin = true
            if state == .established { state = .closing }
        }

        maybeTeardown(into: &actions)
    }

    /// Cierra el flujo cuando ambos sentidos terminaron: mandamos y nos ACKearon el FIN, y consumimos el
    /// FIN del dispositivo (que ACKeamos en el acto).
    private mutating func maybeTeardown(into actions: inout [TCPRelayAction]) {
        guard state != .closed else { return }
        if weSentFin && ourFinAcked && deviceFinConsumed {
            state = .closed
            actions.append(.teardown)
        }
    }

    /// Aborta el flujo con un RST hacia el dispositivo y lo marca cerrado.
    private mutating func abortToDevice(into actions: inout [TCPRelayAction]) {
        guard state != .closed else { return }
        actions.append(.segmentToDevice(rstSegment()))
        state = .closed
        actions.append(.teardown)
    }

    // MARK: - Constructores de segmentos

    private func synAckSegment() -> OutboundSegment {
        OutboundSegment(
            sequence: serverISN,
            acknowledgment: clientISN &+ 1,
            flags: [.syn, .ack],
            window: config.advertisedWindow,
            payload: Data()
        )
    }

    private func ackSegment() -> OutboundSegment {
        OutboundSegment(
            sequence: sendNext,
            acknowledgment: ackToDevice(),
            flags: [.ack],
            window: config.advertisedWindow,
            payload: Data()
        )
    }

    private func rstSegment() -> OutboundSegment {
        OutboundSegment(
            sequence: sendNext,
            acknowledgment: ackToDevice(),
            flags: [.rst, .ack],
            window: 0,
            payload: Data()
        )
    }

    /// ACK acumulado hacia el dispositivo: lo que ha entregado el reensamblador, o —si ya consumimos su
    /// FIN— un número más allá (el FIN consume una secuencia).
    private func ackToDevice() -> UInt32 {
        if deviceFinConsumed { return deviceFinSeq &+ 1 }
        return reassembler?.expectedSequence ?? (clientISN &+ 1)
    }

    // MARK: - Aritmética serial (RFC 1982)

    private func seqLEQ(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) <= 0 }
    private func seqGT(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) > 0 }
    private func seqGEQ(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) >= 0 }
}

/// Segmento TCP entrante (del dispositivo) ya extraído de su datagrama. Desacopla la máquina de estados
/// de los rangos sobre el buffer crudo: el `Relay` lo construye desde el `TCPHeader` parseado y el
/// payload.
public struct InboundSegment: Sendable, Equatable {
    public let sequence: UInt32
    public let acknowledgment: UInt32
    public let flags: TCPFlags
    public let window: UInt16
    public let payload: Data

    public init(sequence: UInt32, acknowledgment: UInt32, flags: TCPFlags, window: UInt16, payload: Data = Data()) {
        self.sequence = sequence
        self.acknowledgment = acknowledgment
        self.flags = flags
        self.window = window
        self.payload = payload
    }

    /// Construye el segmento desde una cabecera TCP parseada y su payload (los bytes de
    /// `TCPHeader.payloadRange` sobre el datagrama).
    public init(header: TCPHeader, payload: Data) {
        self.init(
            sequence: header.sequence,
            acknowledgment: header.acknowledgment,
            flags: header.flags,
            window: header.windowSize,
            payload: payload
        )
    }
}

/// Segmento TCP a emitir hacia el dispositivo. El `Relay` lo serializa con `PacketEmitter.tcp`,
/// añadiendo los endpoints (origen = servidor, destino = dispositivo, en sentido invertido) igual que
/// hace hoy con las respuestas UDP.
public struct OutboundSegment: Sendable, Equatable {
    public let sequence: UInt32
    public let acknowledgment: UInt32
    public let flags: TCPFlags
    public let window: UInt16
    public let payload: Data

    public init(sequence: UInt32, acknowledgment: UInt32, flags: TCPFlags, window: UInt16, payload: Data) {
        self.sequence = sequence
        self.acknowledgment = acknowledgment
        self.flags = flags
        self.window = window
        self.payload = payload
    }
}

/// Acción que la máquina de estados le pide al `Relay`. Mantiene el tipo puro fuera de `NWConnection` y
/// del emisor: la lógica decide *qué* hacer, el actor lo ejecuta.
public enum TCPRelayAction: Sendable, Equatable {
    /// Abrir la conexión saliente TCP hacia el servidor real (una vez por flujo, al recibir el SYN).
    case connectToServer
    /// Escribir bytes de aplicación (ya en orden) en la conexión saliente.
    case sendToServer(Data)
    /// Cerrar el lado de envío de la conexión saliente: el dispositivo terminó de enviar (FIN), así que
    /// el servidor debe ver EOF.
    case closeServerSend
    /// Serializar este segmento (`PacketEmitter.tcp`) y reinyectarlo hacia el dispositivo.
    case segmentToDevice(OutboundSegment)
    /// El flujo terminó: cerrar del todo la conexión saliente y olvidar el flujo.
    case teardown
}
