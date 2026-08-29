import Foundation
import Shared

/// Tabla de flujos vivos con tope duro de tamaño. Agrega el estado por flujo (bytes, paquetes,
/// primer/último visto, estado TLS) y decide cuándo cerrar un flujo (FIN en ambos sentidos, RST,
/// inactividad o evicción por presión de memoria).
///
/// La memoria está acotada siempre: nunca hay más de `maxFlows` flujos vivos. Al desbordar se
/// evicta el menos usado recientemente (LRU) y su `FlowRecord` se cola para volcarlo al store.
/// El LRU es intrusivo (diccionario + lista doblemente enlazada) para que `observe` sea O(1)
/// incluso bajo una tormenta de flujos.
///
/// Nota de diseño: `observe` recibe la longitud del paquete pero **no** sus bytes de payload —
/// `ParsedPacket` es zero-copy (solo rangos sobre el buffer). El reensamblado TCP se alimenta por
/// una ruta aparte (la de inspección, M8) con los bytes reales; por eso `LiveFlow.reassembler`
/// lo puebla ese pipeline, no `observe`.
public actor FlowTable {

    public struct Config: Sendable {
        /// Tope duro de flujos vivos simultáneos.
        public var maxFlows: Int
        /// Nanosegundos sin tráfico tras los que un flujo es candidato a cierre por inactividad.
        public var idleTimeout: UInt64

        public init(maxFlows: Int = 4096, idleTimeout: UInt64 = 120_000_000_000) {
            self.maxFlows = maxFlows
            self.idleTimeout = idleTimeout
        }
    }

    private let config: Config
    private let clock: any MonotonicClock

    private var nodes: [FlowKey: Node]
    private var head: Node?   // más reciente
    private var tail: Node?   // menos reciente (primer candidato a evicción)
    private var closed: [FlowRecord]

    public init(config: Config, clock: any MonotonicClock) {
        self.config = config
        self.clock = clock
        self.nodes = [:]
        self.head = nil
        self.tail = nil
        self.closed = []
    }

    /// Registra un paquete en su flujo (creándolo si es nuevo) y devuelve el estado vivo. Si la
    /// tabla está llena, evicta el flujo LRU antes de crear el nuevo.
    @discardableResult
    public func observe(_ packet: ParsedPacket, direction: Direction, length: UInt32) -> LiveFlow {
        let now = clock.now()
        let key = packet.flowKey

        let node: Node
        if let existing = nodes[key] {
            node = existing
            apply(direction: direction, length: length, now: now, to: node)
            moveToFront(node)
        } else {
            if nodes.count >= config.maxFlows {
                evictLRU()
            }
            node = Node(key: key, direction: direction, length: length, now: now, tlsStatus: initialTLSStatus(for: packet))
            nodes[key] = node
            insertFront(node)
        }

        // Se toma la foto antes de un posible cierre inmediato (un RST o el FIN de cierre): el
        // llamante todavía necesita el estado de este último paquete.
        let snapshot = liveFlow(from: node)
        maybeClose(node: node, packet: packet, direction: direction)
        return snapshot
    }

    /// Fija el estado de inspección TLS de un flujo (lo determina el pipeline TLS). No-op si el
    /// flujo ya no está en la tabla.
    public func setTLSStatus(_ status: TLSInspectionStatus, for key: FlowKey, sni: String?) {
        guard let node = nodes[key] else { return }
        node.tlsStatus = status
        if let sni { node.sni = sni }
    }

    /// Anota el nombre de host que el flujo anunció en su ClientHello, que el relay lee del stream
    /// saliente (`Relay.readHandshake`). No-op si el flujo ya no está en la tabla.
    ///
    /// Va aparte de `setTLSStatus` y **no toca el estado de inspección**: saber a quién llama un
    /// flujo no es haberlo inspeccionado, así que un flujo con nombre sigue siendo `encrypted` hasta
    /// que la terminación TLS diga otra cosa. Confundirlos pintaría de "inspeccionado" tráfico que
    /// nadie ha descifrado.
    public func setSNI(_ sni: String, for key: FlowKey) {
        nodes[key]?.sni = sni
    }

    /// El agregado actual de un flujo vivo, o `nil` si la tabla ya no lo tiene.
    ///
    /// Existe para el contenido descifrado: un trozo llega del relay con la `FlowKey` y sin paquete
    /// detrás —sale de un stream ya reensamblado—, así que quien lo va a indexar necesita el record
    /// al que colgarlo sin que haya pasado un datagrama por `observe`.
    ///
    /// **No cuenta como actividad**: no toca el orden LRU ni el `lastSeen`. Leer un flujo no es
    /// usarlo, y contarlo lo mantendría vivo por el mero hecho de estar mirándolo.
    public func record(for key: FlowKey) -> FlowRecord? {
        nodes[key]?.makeRecord()
    }

    /// Flujos cerrados (por FIN/RST o evicción LRU) desde la última llamada, para volcarlos al
    /// store y liberar. Vacía el buffer interno.
    public func drainClosed() -> [FlowRecord] {
        defer { closed.removeAll(keepingCapacity: true) }
        return closed
    }

    /// Cierra los flujos inactivos desde hace más de `idleTimeout` y devuelve sus records. Lo
    /// llama periódicamente un timer del provider. Los devueltos NO pasan por `drainClosed`: son
    /// un canal aparte para el volcado por inactividad.
    public func expireIdle(now: UInt64) -> [FlowRecord] {
        var expired: [FlowRecord] = []
        // Barrido O(n) desde el LRU (tail) hacia el MRU. Es un timer periódico de baja frecuencia,
        // así que recorrer toda la tabla es aceptable y evita depender del orden exacto de la lista.
        var current = tail
        while let node = current {
            let previous = node.prev
            if now >= node.lastSeen, now - node.lastSeen >= config.idleTimeout {
                expired.append(node.makeRecord())
                remove(node)
            }
            current = previous
        }
        return expired
    }

    /// Número de flujos vivos (para verificar el tope en tests).
    public var count: Int { nodes.count }

    // MARK: - Agregación

    private func apply(direction: Direction, length: UInt32, now: UInt64, to node: Node) {
        let bytes = UInt64(length)
        switch direction {
        case .outbound: node.bytesOut &+= bytes
        case .inbound: node.bytesIn &+= bytes
        }
        node.packetCount &+= 1
        node.lastSeen = now
    }

    /// Estado TLS inicial: TCP hacia el 443 se marca `encrypted` (candidato a inspección opt-in);
    /// el resto del TCP como `plaintext`. UDP y no-TCP no tienen semántica TLS: `plaintext`.
    private func initialTLSStatus(for packet: ParsedPacket) -> TLSInspectionStatus {
        guard packet.tcp != nil else { return .plaintext }
        let isHTTPS = packet.source.port == 443 || packet.destination.port == 443
        return isHTTPS ? .encrypted : .plaintext
    }

    private func maybeClose(node: Node, packet: ParsedPacket, direction: Direction) {
        guard let flags = packet.tcp?.flags else { return }
        if flags.contains(.rst) {
            close(node)
            return
        }
        if flags.contains(.fin) {
            switch direction {
            case .outbound: node.finOutbound = true
            case .inbound: node.finInbound = true
            }
            // Un cierre TCP limpio necesita el FIN de ambos sentidos.
            if node.finOutbound, node.finInbound {
                close(node)
            }
        }
    }

    private func close(_ node: Node) {
        closed.append(node.makeRecord())
        remove(node)
    }

    private func evictLRU() {
        guard let victim = tail else { return }
        closed.append(victim.makeRecord())
        remove(victim)
    }

    private func liveFlow(from node: Node) -> LiveFlow {
        LiveFlow(key: node.key, record: node.makeRecord(), reassembler: node.reassembler, lastActivity: node.lastSeen)
    }

    // MARK: - LRU intrusivo (lista doblemente enlazada)

    private func insertFront(_ node: Node) {
        node.prev = nil
        node.next = head
        head?.prev = node
        head = node
        if tail == nil { tail = node }
    }

    private func moveToFront(_ node: Node) {
        guard head !== node else { return }
        unlink(node)
        insertFront(node)
    }

    private func remove(_ node: Node) {
        unlink(node)
        node.reassembler = nil   // libera el buffer de reensamblado al cerrar
        nodes[node.key] = nil
    }

    /// Desengancha el nodo de la lista sin tocar el diccionario. Deja `prev`/`next` limpios.
    private func unlink(_ node: Node) {
        let previous = node.prev
        let following = node.next
        previous?.next = following
        following?.prev = previous
        if head === node { head = following }
        if tail === node { tail = previous }
        node.prev = nil
        node.next = nil
    }

    /// Nodo de la tabla: tipo referencia porque la lista LRU lo enlaza por identidad, y porque
    /// mantiene el agregado mutable del flujo. Vive siempre aislado dentro del actor, así que no
    /// necesita ser `Sendable`. Proyecta un `FlowRecord` (value type) bajo demanda al emitir.
    private final class Node {
        let key: FlowKey
        let firstSeen: UInt64
        var lastSeen: UInt64
        var bytesOut: UInt64
        var bytesIn: UInt64
        var packetCount: UInt64
        var tlsStatus: TLSInspectionStatus
        var sni: String?
        var reassembler: TCPReassembler?
        var finOutbound: Bool
        var finInbound: Bool
        // `prev` es débil para no formar ciclos de retención con `next`; el diccionario y la
        // cadena `next` desde `head` mantienen vivos los nodos.
        weak var prev: Node?
        var next: Node?

        init(key: FlowKey, direction: Direction, length: UInt32, now: UInt64, tlsStatus: TLSInspectionStatus) {
            let bytes = UInt64(length)
            self.key = key
            self.firstSeen = now
            self.lastSeen = now
            self.bytesOut = direction == .outbound ? bytes : 0
            self.bytesIn = direction == .inbound ? bytes : 0
            self.packetCount = 1
            self.tlsStatus = tlsStatus
            self.sni = nil
            self.reassembler = nil
            self.finOutbound = false
            self.finInbound = false
            self.prev = nil
            self.next = nil
        }

        /// `id = 0`: aún sin persistir. El store asigna el rowid en el UPSERT por 5-tupla.
        func makeRecord() -> FlowRecord {
            FlowRecord(
                id: 0,
                key: key,
                firstSeen: firstSeen,
                lastSeen: lastSeen,
                bytesOut: bytesOut,
                bytesIn: bytesIn,
                packetCount: packetCount,
                tlsStatus: tlsStatus,
                sni: sni
            )
        }
    }
}

/// Estado vivo de un flujo mientras está en la tabla. Foto inmutable (`Sendable`) que `observe`
/// devuelve al llamante; la tabla conserva el estado autoritativo por dentro.
public struct LiveFlow: Sendable {
    public let key: FlowKey
    public var record: FlowRecord
    /// Presente solo si el flujo es TCP y está bajo inspección; lo puebla el pipeline TLS (M8).
    public var reassembler: TCPReassembler?
    public var lastActivity: UInt64

    public init(key: FlowKey, record: FlowRecord, reassembler: TCPReassembler?, lastActivity: UInt64) {
        self.key = key
        self.record = record
        self.reassembler = reassembler
        self.lastActivity = lastActivity
    }
}
