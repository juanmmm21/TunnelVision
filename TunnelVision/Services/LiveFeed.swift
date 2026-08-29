import Foundation
import Shared

/// Los dos extremos de un flujo ya repartidos en dispositivo y host remoto.
public struct FlowEndpoints: Sendable, Hashable {
    /// El extremo que es el propio dispositivo (la IP del túnel).
    public let local: IPEndpoint
    /// El extremo del otro lado: lo que la UI llama "host".
    public let remote: IPEndpoint

    public init(local: IPEndpoint, remote: IPEndpoint) {
        self.local = local
        self.remote = remote
    }
}

/// El reparto de los endpoints canónicos de un `FlowKey`, que por diseño no sabe cuál es cuál.
public enum LiveFeedAddressing {

    /// Reparte (A, B) en (local, remoto) comparando contra las IPs del túnel.
    ///
    /// Devuelve `nil` si ninguno de los dos es local, y **no se adivina**: etiquetar como "host" al
    /// propio dispositivo invertiría lo que el usuario lee en pantalla, y es preferible que la UI
    /// muestre un flujo sin host a que muestre uno con el host equivocado. En la práctica solo pasa
    /// si el feed trae registros de una sesión levantada con otro direccionamiento.
    /// Si ambos fuesen locales (el dispositivo hablándose a sí mismo por el túnel), gana A.
    public static func endpoints(of key: FlowKey, localAddresses: Set<IPAddress>) -> FlowEndpoints? {
        if localAddresses.contains(key.endpointA.address) {
            return FlowEndpoints(local: key.endpointA, remote: key.endpointB)
        }
        if localAddresses.contains(key.endpointB.address) {
            return FlowEndpoints(local: key.endpointB, remote: key.endpointA)
        }
        return nil
    }
}

/// Un paquete del feed en vivo tal y como lo consume la UI: con hora de pared y con el host remoto
/// ya identificado, que es lo que a `PackedPacketMeta` le falta para poder pintarse.
public struct LivePacket: Sendable, Hashable, Identifiable {

    /// Secuencia estable asignada por el lector al ingerirlo. Es el `id` de las listas de SwiftUI:
    /// el sello de tiempo no sirve, porque dos paquetes pueden compartirlo.
    public let id: UInt64

    /// Hora de pared del paquete, derivada del ancla.
    public let date: Date

    public let flowKey: FlowKey
    public let direction: Direction
    public let length: UInt32
    public let tcpFlags: TCPFlags

    /// Fichero y offset donde quedaron sus bytes, o `nil` si no se capturó.
    public let capture: CaptureLocation?

    /// Extremos repartidos, o `nil` si no se pudo decidir cuál era el dispositivo.
    public let endpoints: FlowEndpoints?

    public init(
        id: UInt64,
        date: Date,
        flowKey: FlowKey,
        direction: Direction,
        length: UInt32,
        tcpFlags: TCPFlags,
        capture: CaptureLocation?,
        endpoints: FlowEndpoints?
    ) {
        self.id = id
        self.date = date
        self.flowKey = flowKey
        self.direction = direction
        self.length = length
        self.tcpFlags = tcpFlags
        self.capture = capture
        self.endpoints = endpoints
    }

    /// Convierte un registro del ring en un paquete pintable.
    public init(
        _ packed: PackedPacketMeta,
        sequence: UInt64,
        anchor: MonotonicAnchor,
        localAddresses: Set<IPAddress>
    ) {
        let meta = packed.toPacketMeta()
        self.init(
            id: sequence,
            date: anchor.date(forUptime: meta.timestamp),
            flowKey: meta.flowKey,
            direction: meta.direction,
            length: meta.length,
            tcpFlags: meta.tcpFlags,
            capture: meta.capture,
            endpoints: LiveFeedAddressing.endpoints(of: meta.flowKey, localAddresses: localAddresses)
        )
    }

    /// El host del otro lado, si se pudo identificar. Es lo que encabeza la fila en la UI.
    public var remoteEndpoint: IPEndpoint? { endpoints?.remote }
}

/// La política de drenaje: cuánto se lee de golpe, cuánto se recuerda y cada cuánto se comprueba el
/// ring por si se perdió una señal.
///
/// Todos los topes existen por la misma razón: el ring es de la extensión y puede llenarse a miles de
/// registros por segundo, así que el lector tiene que ser **acotado por construcción** y no crecer
/// con el tráfico.
public struct LiveFeedPolicy: Sendable, Equatable {

    /// Registros por llamada a `RingBufferConsumer.drain(max:)`. Acota la copia de una pasada.
    public var recordsPerDrain: Int

    /// Pasadas seguidas como máximo en un mismo drenaje. Con el ring a tope, el lector coge
    /// `recordsPerDrain * maxDrainsPerBurst` y cede; lo que quede lo recoge el siguiente despertar o
    /// el latido, en vez de monopolizar el actor mientras la extensión sigue empujando.
    public var maxDrainsPerBurst: Int

    /// Paquetes recientes que se conservan en memoria para la UI. El histórico completo es del store.
    public var recentPacketCapacity: Int

    /// Cada cuánto se drena aunque no llegue señal. Es un latido, no el mecanismo principal: cubre una
    /// señal Darwin perdida (se pierden si el proceso no estaba escuchando) y refresca el eje temporal
    /// del gráfico cuando no hay tráfico. `nil` lo desactiva (los tests conducen `drain()` a mano).
    public var idlePollInterval: Duration?

    /// Anchura de cada barra del gráfico de throughput.
    public var bucketDuration: TimeInterval

    /// Anchura total de la ventana rodante del gráfico.
    public var windowDuration: TimeInterval

    public init(
        recordsPerDrain: Int = 512,
        maxDrainsPerBurst: Int = 8,
        recentPacketCapacity: Int = 500,
        idlePollInterval: Duration? = .seconds(1),
        bucketDuration: TimeInterval = 1,
        windowDuration: TimeInterval = 60
    ) {
        precondition(recordsPerDrain > 0, "recordsPerDrain debe ser positivo")
        precondition(maxDrainsPerBurst > 0, "maxDrainsPerBurst debe ser positivo")
        precondition(recentPacketCapacity > 0, "recentPacketCapacity debe ser positivo")
        self.recordsPerDrain = recordsPerDrain
        self.maxDrainsPerBurst = maxDrainsPerBurst
        self.recentPacketCapacity = recentPacketCapacity
        self.idlePollInterval = idlePollInterval
        self.bucketDuration = bucketDuration
        self.windowDuration = windowDuration
    }

    /// 512 registros por pasada (≈30 KB de copia), hasta 8 pasadas seguidas, 500 paquetes recientes,
    /// latido de 1 s y una ventana de 60 barras de 1 s — la que pide el gráfico de la Dashboard.
    public static let `default` = LiveFeedPolicy()
}

/// Lo que el lector publica y la UI pinta. Es un valor: la vista no consulta al lector, lo recibe.
public struct LiveFeedSnapshot: Sendable, Equatable {

    /// Paquetes recientes en orden de llegada (el más nuevo, el último). La lista de la Dashboard los
    /// enseña al revés; invertir es de la vista, no del lector.
    public var recent: [LivePacket]

    /// Barras del gráfico de throughput, con los huecos rellenos a cero.
    public var throughput: [ThroughputSample]

    /// Registros que la extensión descartó por back-pressure desde que arrancó el ring. La Dashboard
    /// lo enseña "honesto y discreto" (`docs/ux/screens.md`): es la única señal de que el feed en vivo
    /// no lo está viendo todo.
    public var droppedRecords: UInt64

    /// Totales de la sesión (desde el último `start()`).
    public var bytesIn: UInt64
    public var bytesOut: UInt64
    public var packetCount: UInt64

    /// Paquetes que llegaron demasiado tarde para su barra del gráfico y no se contabilizaron en él
    /// (sí en los totales). Se expone en vez de tragarse: si crece, la ventana está mal dimensionada.
    public var lateRecords: UInt64

    /// Si el lector tiene el ring abierto. Falso mientras la extensión no lo haya creado nunca: la UI
    /// enseña "esperando al túnel", no un error.
    public var isAttached: Bool

    /// Por qué no se pudo abrir el ring en el último intento, si falló.
    public var lastAttachError: IPCError?

    public init(
        recent: [LivePacket] = [],
        throughput: [ThroughputSample] = [],
        droppedRecords: UInt64 = 0,
        bytesIn: UInt64 = 0,
        bytesOut: UInt64 = 0,
        packetCount: UInt64 = 0,
        lateRecords: UInt64 = 0,
        isAttached: Bool = false,
        lastAttachError: IPCError? = nil
    ) {
        self.recent = recent
        self.throughput = throughput
        self.droppedRecords = droppedRecords
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.packetCount = packetCount
        self.lateRecords = lateRecords
        self.isAttached = isAttached
        self.lastAttachError = lastAttachError
    }
}
