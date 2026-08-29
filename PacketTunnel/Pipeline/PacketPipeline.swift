import Foundation
import Shared

/// El hot path completo, sin `NEPacketTunnelProvider`: parsea un datagrama, lo agrega a su flujo,
/// decide su ruta, lo escribe a la captura, lo publica en el feed en vivo y lo acumula para un
/// volcado por lotes al store.
///
/// Existe separado del provider a propósito (`docs/spec/tunnel-provider.md`): el provider solo
/// corre en dispositivo, así que se queda con el ciclo de vida y el `packetFlow`, y delega aquí
/// todo lo demás. Así el 100% de la lógica de M7 se prueba en Simulator reproduciendo capturas.
///
/// Es un `actor` porque su estado (lote pendiente, contadores, config viva) lo tocan tanto el read
/// loop como el timer periódico y el canal de control de la app.
public actor PacketPipeline {

    public struct Config: Sendable {
        /// IP del túnel para IPv4 (de `NEPacketTunnelNetworkSettings`). Fija el sentido del
        /// paquete: `FlowKey` es canónico y por sí solo no sabe cuál de los dos extremos somos.
        public var localIPv4: IPAddress
        /// IP del túnel para IPv6, si el túnel la tiene. Con `nil`, el tráfico IPv6 se descarta
        /// con `.noLocalAddress` en vez de adivinar mal el sentido.
        public var localIPv6: IPAddress?
        /// Inspección TLS opt-in. Con `false` (el valor por defecto y el estado sin consentimiento
        /// explícito) todo el tráfico es `.passthrough`.
        public var tlsInspectionEnabled: Bool
        /// Escritura del `.pcap`. Con `false`, `PacketMeta.capture` queda a `nil`.
        public var captureEnabled: Bool
        /// Paquetes acumulados que fuerzan un volcado al store.
        public var batchSize: Int
        /// Nanosegundos desde el último volcado que lo fuerzan aunque no se llene el lote (si no,
        /// un flujo lento no aparecería en el historial hasta acumular `batchSize`).
        public var flushInterval: UInt64
        /// Ancla de la sesión. Es la conversión de sello monotónico a instante absoluto que necesita
        /// el contenido descifrado, porque **su fichero fecha en absoluto** y su fila también: tiene
        /// que ser **la misma ancla** que la del store o el registro y la fila que lo indexa dirían
        /// dos instantes distintos del mismo trozo (`docs/spec/plaintext.md`).
        public var anchor: MonotonicAnchor
        /// Bytes de contenido descifrado que se guardan por flujo **y sentido**. El tope por registro
        /// lo pone el escritor; este acota antes, que es lo que impide que una descarga por HTTPS se
        /// escriba entera en claro (ADR 0007). Nunca por encima del tope por registro del escritor:
        /// pasarse dejaría el recorte en manos de quien no lo sabe contar.
        public var plaintextBytesPerDirection: Int

        public init(
            localIPv4: IPAddress,
            localIPv6: IPAddress? = nil,
            tlsInspectionEnabled: Bool = false,
            captureEnabled: Bool = true,
            batchSize: Int = 256,
            flushInterval: UInt64 = 500_000_000,
            anchor: MonotonicAnchor = .now(),
            plaintextBytesPerDirection: Int = PlaintextBudget.defaultMaxBytesPerDirection
        ) {
            self.localIPv4 = localIPv4
            self.localIPv6 = localIPv6
            self.tlsInspectionEnabled = tlsInspectionEnabled
            self.captureEnabled = captureEnabled
            self.batchSize = batchSize
            self.flushInterval = flushInterval
            self.anchor = anchor
            self.plaintextBytesPerDirection = plaintextBytesPerDirection
        }
    }

    private let flowTable: FlowTable
    private let liveFeed: any LiveFeedSink
    private let capture: (any CaptureSink)?
    /// Escritor del contenido descifrado. `nil` = no hay dónde guardarlo, y entonces observarlo es un
    /// no-op: el interruptor del usuario lo aplica el relay, que es quien decide si le pasa el
    /// sumidero a una terminación (ADR 0007).
    private let plaintext: (any PlaintextSink)?
    private let store: any FlowPersisting
    private let clock: any MonotonicClock

    private var config: Config
    /// Lote pendiente de volcado, agrupado por flujo: el store enlaza los paquetes al id que
    /// devuelve el upsert, así que agrupar aquí evita un upsert por paquete.
    private var pending: [FlowKey: PendingFlow]
    private var pendingPackets: Int
    private var lastFlush: UInt64
    /// Se activa al primer fallo de escritura de la captura y no se reintenta solo: repetir un
    /// disco lleno por cada paquete solo gasta batería. La app puede rearmarla con `setCaptureEnabled`.
    private var captureFailed: Bool
    /// Se activa al primer fallo de escritura del contenido descifrado, por lo mismo que el de la
    /// captura: un disco lleno no se reintenta trozo a trozo. A diferencia de aquel **no se rearma
    /// desde la app**, porque no hay un interruptor que lo rearme: el de persistir lo gobierna el
    /// relay y encenderlo de nuevo abre flujos nuevos, que es cuando esto vuelve a intentarse.
    private var plaintextFailed: Bool
    /// Lo que cada flujo inspeccionado tiene abierto en los ficheros de contenido descifrado. Muere
    /// por el mismo embudo que cierra los flujos (`merge(closed:)`).
    private var plaintextFlows: [FlowKey: PlaintextFlow]
    /// Flujos que la tabla ha dado por terminados y cuyos recursos de reenvío siguen vivos, a la
    /// espera de que el provider los suelte (`drainClosedFlowKeys`).
    private var closedFlowKeys: [FlowKey]

    public private(set) var stats: PipelineStats

    public init(
        flowTable: FlowTable,
        liveFeed: any LiveFeedSink,
        capture: (any CaptureSink)?,
        plaintext: (any PlaintextSink)? = nil,
        store: any FlowPersisting,
        clock: any MonotonicClock,
        config: Config
    ) {
        self.flowTable = flowTable
        self.liveFeed = liveFeed
        self.capture = capture
        self.plaintext = plaintext
        self.store = store
        self.clock = clock
        self.config = config
        self.pending = [:]
        self.pendingPackets = 0
        self.lastFlush = clock.now()
        self.captureFailed = false
        self.plaintextFailed = false
        self.plaintextFlows = [:]
        self.closedFlowKeys = []
        self.stats = PipelineStats()
    }

    // MARK: - Hot path

    /// Procesa un datagrama IP crudo tal como lo entrega `packetFlow.readPackets` y devuelve qué
    /// hacer con él. No relaya ni reinyecta: eso es del provider.
    @discardableResult
    public func handle(packet: Data, protocolFamily: Int32) async -> PacketDisposition {
        switch await observe(packet: packet, protocolFamily: protocolFamily) {
        case .dropped(let reason):
            return .dropped(reason)
        case .recorded(let parsed, let flow):
            return route(parsed: parsed, flow: flow)
        }
    }

    /// Registra una respuesta que el relay **acaba de reinyectar** hacia el dispositivo.
    ///
    /// Hace exactamente lo mismo que `handle` menos decidir una ruta: este datagrama ya está
    /// entregado y no hay nada que decidir sobre él. Existe porque lo que entra al dispositivo **no
    /// vuelve a pasar por el bucle de lectura** —`readPackets` solo entrega lo que el dispositivo
    /// envía—, así que sin esto la mitad de cada conversación es invisible: `bytesIn` se queda a
    /// cero, la Dashboard no puede dibujar la bajada y el `.pcap` exportado lleva las preguntas sin
    /// las respuestas.
    ///
    /// El sentido no se le pasa: se **deduce** igual que el de cualquier otro paquete, comparando el
    /// origen con la IP del túnel, así que un datagrama reinyectado se clasifica `inbound` por lo que
    /// es y no porque lo diga quien lo registra. Como su `FlowKey` es canónica, cae en el mismo flujo
    /// que la ida y suma en el mismo `FlowRecord`.
    public func record(reinjected packet: Data, protocolFamily: Int32) async {
        // El desenlace no interesa al llamante: un descarte ya queda contado en `stats`, y la
        // respuesta al dispositivo se entregó pase lo que pase aquí.
        _ = await observe(packet: packet, protocolFamily: protocolFamily)
    }

    /// Lo que comparten los dos sentidos: parsear, fijar el sentido, agregar al flujo, escribir la
    /// captura, publicar en el feed en vivo y encolar para el store.
    private func observe(packet: Data, protocolFamily: Int32) async -> Observation {
        let parsed: ParsedPacket
        do {
            parsed = try PacketParser.parse(packet, protocolFamily: protocolFamily)
        } catch let error as PacketParseError {
            stats.packetsDropped &+= 1
            return .dropped(.parseFailed(error))
        } catch {
            stats.packetsDropped &+= 1
            return .dropped(.unparseable)
        }

        guard let localAddress = localAddress(for: parsed.ip.version) else {
            stats.packetsDropped &+= 1
            return .dropped(.noLocalAddress(parsed.ip.version))
        }

        let now = clock.now()
        let length = UInt32(clamping: packet.count)
        let direction = parsed.flowKey.direction(ofPacketFrom: parsed.source, localAddress: localAddress)
        let flow = await flowTable.observe(parsed, direction: direction, length: length)

        // La captura va antes de publicar el metadato porque este transporta dónde quedó el registro.
        let capture = await writeCapture(packet: packet, timestamp: now)

        let meta = PacketMeta(
            timestamp: now,
            flowKey: parsed.flowKey,
            direction: direction,
            length: length,
            tcpFlags: parsed.tcp?.flags ?? [],
            capture: capture
        )
        liveFeed.push(PackedPacketMeta(meta))
        await enqueue(meta: meta, record: flow.record, now: now)

        stats.packetsHandled &+= 1
        stats.bytesHandled &+= UInt64(length)
        return .recorded(parsed, flow)
    }

    /// Resultado de registrar un datagrama, antes de decidir qué hacer con él.
    private enum Observation {
        case recorded(ParsedPacket, LiveFlow)
        case dropped(DropReason)
    }

    /// Decisión de routing (`docs/spec/tunnel-provider.md`). Solo el TCP contra el 443, con
    /// inspección activada y sobre un flujo que no haya rechazado ya la CA, se termina en userspace.
    private func route(parsed: ParsedPacket, flow: LiveFlow) -> PacketDisposition {
        guard config.tlsInspectionEnabled else { return .passthrough(parsed) }
        guard parsed.tcp != nil else { return .passthrough(parsed) }
        guard parsed.source.port == 443 || parsed.destination.port == 443 else { return .passthrough(parsed) }
        // Un flujo que ya rechazó nuestra CA queda pinneado para siempre: se relaya intacto y no se
        // reintenta la terminación (docs/decisions/0003-no-third-party-pinning-bypass.md).
        guard flow.record.tlsStatus != .notInspectable else { return .passthrough(parsed) }
        return .inspect(parsed)
    }

    private func localAddress(for version: IPVersion) -> IPAddress? {
        switch version {
        case .v4: return config.localIPv4
        case .v6: return config.localIPv6
        }
    }

    /// Escribe el paquete en la captura y devuelve dónde quedó, o `nil` si no hay captura
    /// (desactivada, sin writer, o rota tras un fallo).
    ///
    /// El sello llega monotónico —es el del hot path— y se convierte aquí con el ancla de la sesión,
    /// porque el `.pcap` fecha en **absoluto**: sus `ts_sec`/`ts_usec` son hora de pared para
    /// Wireshark, y pasarle el uptime crudo situaba toda captura exportada en 1970. Es la misma
    /// conversión que ya hacía el contenido descifrado, y con la misma ancla.
    private func writeCapture(packet: Data, timestamp: UInt64) async -> CaptureLocation? {
        guard config.captureEnabled, !captureFailed, let capture else { return nil }
        do {
            return try await capture.write(
                packet: packet,
                originalLength: packet.count,
                timestamp: config.anchor.nanosecondsSince1970(forUptime: timestamp)
            )
        } catch {
            // Un disco lleno no puede tumbar el túnel: el tráfico del usuario sigue fluyendo y el
            // feed en vivo también. Se cuenta, se apaga la captura y la app lo ve en `stats`.
            captureFailed = true
            stats.captureFailures &+= 1
            stats.lastCaptureError = String(describing: error)
            return nil
        }
    }

    // MARK: - Volcado por lotes al store

    private func enqueue(meta: PacketMeta, record: FlowRecord, now: UInt64) async {
        // El último record gana: la tabla de flujos mantiene los acumulados, así que el más
        // reciente ya incluye a todos los anteriores.
        var entry = pending[record.key] ?? PendingFlow(record: record)
        entry.record = record
        entry.metas.append(meta)
        pending[record.key] = entry
        pendingPackets += 1

        if pendingPackets >= config.batchSize || now &- lastFlush >= config.flushInterval {
            await flush(now: now)
        }
    }

    /// Vuelca el lote pendiente al store. Lo llama el propio hot path al llenar el lote, el timer
    /// periódico (`tick`) y el cierre del túnel (`shutdown`).
    public func flush() async {
        await flush(now: clock.now())
    }

    private func flush(now: UInt64) async {
        // Última oportunidad de los flujos cerrados (FIN/RST o evicción LRU): la tabla ya los soltó.
        for record in await flowTable.drainClosed() {
            merge(closed: record)
        }
        await writePending(now: now)
    }

    /// Mantenimiento periódico: cierra los flujos inactivos para liberar su memoria y vuelca.
    /// Lo llama un timer del provider, no el hot path.
    public func tick() async {
        let now = clock.now()
        for record in await flowTable.expireIdle(now: now) {
            merge(closed: record)
        }
        await flush(now: now)
    }

    /// Vuelca lo pendiente y sincroniza la captura a disco. La llama `stopTunnel` antes de cerrar
    /// los recursos: el pipeline no cierra lo que no ha creado (ring, writer y store son del
    /// provider), solo se asegura de que nada quede sin escribir.
    public func shutdown() async {
        await flush()
        if let plaintext, !plaintextFailed {
            do {
                try await plaintext.flush()
            } catch {
                plaintextFailed = true
                stats.plaintextFailures &+= 1
                stats.lastPlaintextError = String(describing: error)
            }
        }
        guard let capture, !captureFailed else { return }
        do {
            try await capture.flush()
        } catch {
            captureFailed = true
            stats.captureFailures &+= 1
            stats.lastCaptureError = String(describing: error)
        }
    }

    /// Un flujo cerrado puede no tener paquetes pendientes (ya se volcaron en un lote anterior) y
    /// aun así su record final —con los totales y el estado TLS definitivos— debe llegar al store.
    ///
    /// Es además el **único embudo** por el que pasa un flujo al terminar —lo cierre un FIN/RST, la
    /// evicción LRU o la inactividad—, así que es aquí donde se anota su clave para que el provider
    /// cierre la conexión saliente que el relay mantenga por él.
    private func merge(closed record: FlowRecord) {
        var entry = pending[record.key] ?? PendingFlow(record: record)
        entry.record = record
        pending[record.key] = entry
        closedFlowKeys.append(record.key)
        // Y es también donde muere lo que el flujo tenía abierto en los ficheros de contenido
        // descifrado: su presupuesto no puede sobrevivirle, o un puerto efímero reciclado heredaría
        // el sitio ya gastado por una conexión que no es la suya.
        plaintextFlows.removeValue(forKey: record.key)
    }

    /// Claves de los flujos terminados desde la última llamada, para que el provider cierre lo que
    /// el relay tenga abierto por ellos. Vacía el buffer interno.
    ///
    /// El pipeline **no** cierra nada él mismo: el relay es del provider, igual que el ring, la
    /// captura y el store, y este actor solo observa y decide (`docs/spec/tunnel-provider.md`). Lo
    /// que sí es suyo es *saber* que un flujo terminó: la tabla de flujos vive aquí dentro y sus dos
    /// canales de cierre (`drainClosed` y `expireIdle`) los consume el volcado, así que sin esto el
    /// provider no tendría cómo enterarse — y una conexión UDP, que solo se cierra por inactividad o
    /// por evicción, se quedaría viva para siempre.
    ///
    /// Se drena en el `tick` y no en el acto: cerrar una conexión saliente hasta un tick tarde no
    /// tiene coste (es liberar memoria, no una decisión de conectividad) y a cambio el hot path no
    /// gana un salto de actor por paquete.
    public func drainClosedFlowKeys() -> [FlowKey] {
        defer { closedFlowKeys.removeAll(keepingCapacity: true) }
        return closedFlowKeys
    }

    private func writePending(now: UInt64) async {
        lastFlush = now
        guard !pending.isEmpty else { return }

        // Se saca la foto y se vacía **antes** de los `await`: el actor es reentrante, así que
        // durante la escritura pueden entrar paquetes nuevos, y deben ir al lote siguiente.
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        pendingPackets = 0

        for entry in batch.values {
            do {
                let flowID = try await store.upsertFlow(entry.record)
                stats.flowsPersisted &+= 1
                if !entry.metas.isEmpty {
                    try await store.appendPackets(entry.metas, flowID: flowID)
                    stats.packetsPersisted &+= UInt64(entry.metas.count)
                }
                // El índice del contenido descifrado va en el mismo lote y con el mismo id: los
                // bytes ya están en su fichero, y esta es la fila que permite volver a ellos.
                if !entry.plaintext.isEmpty {
                    try await store.appendPlaintext(entry.plaintext, flowID: flowID)
                }
            } catch {
                // El lote se pierde y se cuenta; no se reencola. Reintentar contra un store que
                // falla haría crecer la memoria de la extensión sin tope hasta que el OS la mate,
                // y el historial es sacrificable: el feed en vivo y el relay no dependen de él.
                stats.storeFailures &+= 1
                stats.lastStoreError = String(describing: error)
            }
        }
    }

    // MARK: - Nombre de un flujo (SNI)

    /// Anota el host que un flujo TLS anunció en su ClientHello. Lo lee el relay del stream saliente
    /// —el ClientHello viaja en claro— y llega aquí porque la tabla de flujos es de este actor.
    ///
    /// Es lo que hace que la app pueda decir **con quién** habló el dispositivo en vez de con qué
    /// dirección, y no depende de la inspección TLS: un flujo con nombre sigue siendo `encrypted`.
    ///
    /// No hay que escribir nada al store desde aquí: la tabla es la dueña del agregado, así que el
    /// siguiente paquete del flujo ya trae el `FlowRecord` con el nombre puesto, y el record de
    /// cierre —que pasa por el mismo embudo que todos— lo lleva también aunque el flujo muera justo
    /// después del handshake.
    public func observe(sni: String, for key: FlowKey) async {
        await flowTable.setSNI(sni, for: key)
    }

    // MARK: - Desenlace de la inspección de un flujo

    /// Anota cómo acabó el intento de inspeccionar un flujo: `inspected` si se descifró de punta a
    /// punta, `notInspectable` si el cliente rechazó nuestro leaf. Lo decide la terminación TLS y
    /// llega aquí por la misma razón que el nombre: la tabla de flujos es de este actor.
    ///
    /// Marcar `notInspectable` tiene un efecto que va más allá de la etiqueta de la pantalla: `route`
    /// lo lee, así que a partir del siguiente paquete ese flujo vuelve a `.passthrough` y no se
    /// vuelve a intentar. Es la mitad del invariante del ADR 0003 que vive en el pipeline.
    ///
    /// Igual que con el nombre, no hay que escribir nada al store desde aquí: la tabla es la dueña
    /// del agregado y el record de cierre pasa por el mismo embudo que todos.
    public func observe(tlsStatus: TLSInspectionStatus, for key: FlowKey) async {
        await flowTable.setTLSStatus(tlsStatus, for: key, sni: nil)
    }

    // MARK: - Contenido descifrado de un flujo

    /// Guarda un trozo de contenido en claro que salió de una terminación TLS: lo escribe en su
    /// fichero y acumula la fila del índice para el volcado por lotes.
    ///
    /// Es la mitad de la persistencia que solo el pipeline puede hacer, y por dos razones que van
    /// juntas: la fila cuelga del **id del flujo**, que solo existe cuando `upsertFlow` lo devuelve
    /// en el volcado, y el presupuesto de un flujo tiene que morir cuando muere el flujo, que es un
    /// hecho de la tabla. El relay, que es quien tiene los bytes, no sabe ninguna de las dos cosas.
    ///
    /// Se escribe **el principio**: el presupuesto por sentido corta y lo que no cupo se cuenta
    /// (`PlaintextBudget`, ADR 0007). Un trozo que llega con el presupuesto agotado no toca el disco.
    public func observe(plaintext data: Data, direction: Direction, for key: FlowKey) async {
        guard let sink = self.plaintext, !plaintextFailed, !data.isEmpty else { return }

        // Antes de escribir un byte: sin flujo al que colgar la fila no se guarda nada. Bytes
        // descifrados en un fichero que ninguna fila nombra son lo peor de los dos mundos —nadie
        // puede llegar a ellos y la retención no sabe que existen—, así que se pierden aquí.
        guard let record = await flowTable.record(for: key) ?? pending[key]?.record else {
            stats.plaintextBytesDropped &+= UInt64(data.count)
            return
        }

        guard var state = await plaintextFlow(for: key, sink: sink) else { return }
        let allowed = state.budget.allowance(for: data.count, direction: direction)
        let dropped = data.count - allowed
        if dropped > 0 {
            stats.plaintextBytesDropped &+= UInt64(dropped)
        }
        plaintextFlows[key] = state
        guard allowed > 0 else { return }

        let now = clock.now()
        do {
            // El instante va absoluto al fichero y monotónico a la fila, convertidos los dos con el
            // ancla de la sesión: el fichero sobrevive a la sesión y la fila la convierte el store.
            guard let location = try await sink.write(
                data.prefix(allowed),
                stream: state.stream,
                direction: direction,
                timestamp: config.anchor.nanosecondsSince1970(forUptime: now)
            ) else {
                return
            }
            enqueue(
                plaintext: PlaintextChunkMeta(
                    timestamp: now,
                    direction: direction,
                    stream: state.stream,
                    location: location,
                    storedLength: UInt32(allowed),
                    originalLength: UInt32(clamping: data.count)
                ),
                record: record
            )
            stats.plaintextChunksStored &+= 1
            stats.plaintextBytesStored &+= UInt64(allowed)
        } catch {
            // Mismo trato que un fallo de la captura: el tráfico del usuario sigue fluyendo y lo que
            // se apaga es lo que no cabe en el disco. Se cuenta, porque un flujo inspeccionado que
            // deja de guardar contenido sin explicación se lee como si no hubiera dicho nada.
            plaintextFailed = true
            stats.plaintextFailures &+= 1
            stats.lastPlaintextError = String(describing: error)
        }
    }

    /// La conversación de un flujo en los ficheros, abriéndola en su primer trozo.
    private func plaintextFlow(for key: FlowKey, sink: any PlaintextSink) async -> PlaintextFlow? {
        if let existing = plaintextFlows[key] { return existing }

        let stream = await sink.openStream()
        // El `await` de arriba es reentrante, así que otro trozo del mismo flujo ha podido abrir la
        // conversación entretanto. Gana la suya y el identificador recién repartido se queda sin
        // usar: un hueco en la numeración no le hace daño a nadie, y dos conversaciones para un
        // mismo flujo partirían en dos lo que el Flow Inspector tiene que enseñar junto.
        if let existing = plaintextFlows[key] { return existing }

        let state = PlaintextFlow(
            stream: stream,
            budget: PlaintextBudget(maxBytesPerDirection: config.plaintextBytesPerDirection)
        )
        plaintextFlows[key] = state
        return state
    }

    /// Acumula la fila del índice en el lote del flujo, junto a sus paquetes.
    ///
    /// **No cuenta para el tamaño del lote ni fuerza un volcado**: un trozo descifrado no es un
    /// paquete, y un flujo que descifra está mandando paquetes por definición, así que el lote lo
    /// siguen disparando ellos y el tick. Contarlo aquí volcaría a mitad de una ráfaga de bytes.
    private func enqueue(plaintext chunk: PlaintextChunkMeta, record: FlowRecord) {
        var entry = pending[record.key] ?? PendingFlow(record: record)
        entry.record = record
        entry.plaintext.append(chunk)
        pending[record.key] = entry
    }

    // MARK: - Canal de control (handleAppMessage)

    /// Activa o desactiva la inspección TLS en caliente. Al desactivarla, los flujos en curso
    /// vuelven a `.passthrough` en su siguiente paquete.
    public func setTLSInspectionEnabled(_ enabled: Bool) {
        config.tlsInspectionEnabled = enabled
    }

    /// Activa o desactiva la captura a `.pcap`. Reactivarla rearma también el corte por fallo de
    /// escritura, para que el usuario pueda reintentar tras liberar espacio.
    public func setCaptureEnabled(_ enabled: Bool) {
        config.captureEnabled = enabled
        if enabled { captureFailed = false }
    }

    /// Paquetes acumulados sin volcar. Expuesto para verificar el lote en tests.
    public var pendingPacketCount: Int { pendingPackets }

    /// Metadatos de un flujo pendientes de volcado, agrupados para escribirlos con un solo upsert.
    private struct PendingFlow {
        var record: FlowRecord
        var metas: [PacketMeta] = []
        /// Filas del índice de contenido descifrado, que cuelgan del mismo id que los paquetes.
        var plaintext: [PlaintextChunkMeta] = []
    }

    /// Lo que un flujo tiene abierto en los ficheros de contenido descifrado: su conversación y lo
    /// que le queda por guardar en cada sentido.
    private struct PlaintextFlow {
        let stream: UInt64
        var budget: PlaintextBudget
    }
}

/// El pipeline es quien recoge los nombres que el relay lee del handshake: es el dueño de la tabla
/// de flujos, que es donde un nombre significa algo.
extension PacketPipeline: SNIObserving {}

/// Y por lo mismo recoge el desenlace de las terminaciones TLS. Son dos costuras y no una porque son
/// dos hechos distintos: tener nombre no es haber sido inspeccionado.
extension PacketPipeline: TLSStatusObserving {}

/// Y la tercera: el contenido en claro que produce una terminación. Aquí la razón para recogerlo es
/// más fuerte que en las otras dos —la fila del índice cuelga del id que devuelve el volcado, y ese
/// volcado es de este actor—, así que no había otro sitio donde pudiera aterrizar.
extension PacketPipeline: PlaintextObserving {}
