import Foundation
import Shared

/// El servicio que lee lo que la extensión publica en vivo (M9).
///
/// Es la contraparte de app del `RingBufferProducer`: drena el ring mmap del App Group, convierte
/// cada registro en un `LivePacket` con hora de pared y host remoto, lo acumula en la ventana de
/// throughput y publica una `LiveFeedSnapshot` para la UI.
///
/// Es un `actor` —y no `@MainActor` como `TunnelController`— por dos razones. Una: el contrato SPSC
/// del ring exige que el consumidor lo use desde un único contexto, y el aislamiento del actor es
/// justo esa garantía. Dos: `docs/spec/ipc.md` pide que el drenaje no ocurra en el hilo principal;
/// aquí el `@MainActor` es el view model que consume `snapshots()`, no el lector.
///
/// El ring **se abre en diferido y se reintenta**: el fichero no existe hasta que la extensión haya
/// arrancado una vez, y en la app recién instalada eso es lo normal, no un error. Mientras no
/// exista, el lector publica `isAttached == false` y la UI enseña que espera al túnel.
public actor LiveFeedReader {

    // MARK: - Dependencias inmutables

    /// Abre el consumidor. Es una closure y no un consumidor ya construido porque el ring puede no
    /// existir todavía, y porque tras una sesión nueva hay que volver a abrirlo (`reattach()`).
    private let openConsumer: @Sendable () throws -> RingBufferConsumer
    private let policy: LiveFeedPolicy
    private let wakeup: any LiveFeedWakeup
    private let localAddresses: Set<IPAddress>
    private let anchorProvider: @Sendable () -> MonotonicAnchor
    private let now: @Sendable () -> Date

    // MARK: - Estado de la sesión

    private var consumer: RingBufferConsumer?
    private var anchor: MonotonicAnchor
    private var window: ThroughputWindow
    private var recent: [LivePacket] = []
    private var sequence: UInt64 = 0
    private var bytesIn: UInt64 = 0
    private var bytesOut: UInt64 = 0
    private var packetCount: UInt64 = 0
    private var droppedRecords: UInt64 = 0
    private var isAttached = false
    private var lastAttachError: IPCError?

    private var running = false
    private var pollTask: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<LiveFeedSnapshot>.Continuation] = [:]
    private var lastPublished: LiveFeedSnapshot?

    // MARK: - Construcción

    /// Lector sobre el ring del App Group. Es el sitio de llamada de producción.
    public init(
        appGroupID: String = AppGroup.identifier,
        policy: LiveFeedPolicy = .default,
        wakeup: any LiveFeedWakeup = DarwinNotificationWakeup(),
        localAddresses: Set<IPAddress> = TunnelAddressing.localAddresses,
        anchorProvider: @escaping @Sendable () -> MonotonicAnchor = MonotonicAnchor.now,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.init(
            openConsumer: { try RingBufferConsumer(appGroupID: appGroupID) },
            policy: policy,
            wakeup: wakeup,
            localAddresses: localAddresses,
            anchorProvider: anchorProvider,
            now: now
        )
    }

    /// Lector sobre un ring respaldado por fichero. Expuesto para los tests, igual que
    /// `RingBufferConsumer(fileURL:)` y `FlowStore(databaseURL:)`: no hay App Group en Simulator.
    public init(
        fileURL: URL,
        policy: LiveFeedPolicy = .default,
        wakeup: any LiveFeedWakeup,
        localAddresses: Set<IPAddress> = TunnelAddressing.localAddresses,
        anchorProvider: @escaping @Sendable () -> MonotonicAnchor = MonotonicAnchor.now,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.init(
            openConsumer: { try RingBufferConsumer(fileURL: fileURL) },
            policy: policy,
            wakeup: wakeup,
            localAddresses: localAddresses,
            anchorProvider: anchorProvider,
            now: now
        )
    }

    private init(
        openConsumer: @escaping @Sendable () throws -> RingBufferConsumer,
        policy: LiveFeedPolicy,
        wakeup: any LiveFeedWakeup,
        localAddresses: Set<IPAddress>,
        anchorProvider: @escaping @Sendable () -> MonotonicAnchor,
        now: @escaping @Sendable () -> Date
    ) {
        self.openConsumer = openConsumer
        self.policy = policy
        self.wakeup = wakeup
        self.localAddresses = localAddresses
        self.anchorProvider = anchorProvider
        self.now = now
        self.anchor = anchorProvider()
        self.window = ThroughputWindow(
            bucketDuration: policy.bucketDuration,
            windowDuration: policy.windowDuration
        )
    }

    deinit {
        // El mapeo y el observador Darwin son recursos del sistema: se sueltan pase lo que pase, sin
        // depender de que alguien haya llamado a `stop()`.
        pollTask?.cancel()
        wakeup.stop()
        consumer?.close()
        for continuation in observers.values { continuation.finish() }
    }

    // MARK: - Ciclo de vida

    /// Arranca una sesión de lectura: re-ancla el reloj, vacía los contadores, engancha el despertador,
    /// hace una primera pasada y lanza el latido. Idempotente.
    ///
    /// Vaciar aquí es deliberado: los contadores y el gráfico son **de la sesión de túnel** que
    /// empieza, y el propio ring reinicia sus índices cuando la extensión lo recrea.
    public func start() {
        guard !running else { return }
        running = true
        anchor = anchorProvider()
        resetSession()

        wakeup.start { [weak self] in
            Task { await self?.drainIfRunning() }
        }
        drain()
        startPolling()
    }

    /// Para la lectura, suelta el despertador y cierra el ring. No termina los streams: la vista sigue
    /// suscrita y verá la sesión siguiente sin volver a suscribirse.
    public func stop() {
        guard running else { return }
        running = false
        pollTask?.cancel()
        pollTask = nil
        wakeup.stop()
        detach()
        publish()
    }

    /// Cierra el ring y fuerza a reabrirlo en el siguiente drenaje.
    ///
    /// Hace falta porque la extensión **recrea** el fichero del ring al arrancar cada sesión: un
    /// mapeo abierto contra el fichero anterior seguiría vivo y en silencio, sin ver un solo registro
    /// nuevo. La UI la llama cuando ve el túnel pasar a activo.
    public func reattach() {
        detach()
        drain()
    }

    // MARK: - Lectura

    /// Una pasada de drenaje: incorpora lo que haya en el ring y publica si algo cambió. Devuelve
    /// cuántos registros incorporó.
    ///
    /// Es pública porque la conducen tanto el latido como los tests. Drena en bucle hasta vaciar (con
    /// el tope de `maxDrainsPerBurst`) porque la señal viene coalescida: un despertar puede
    /// corresponder a miles de registros.
    @discardableResult
    public func drain() -> Int {
        guard let consumer = attachedConsumer() else {
            publish()
            return 0
        }

        var ingested = 0
        for _ in 0..<policy.maxDrainsPerBurst {
            let batch = consumer.drain(max: policy.recordsPerDrain)
            if batch.isEmpty { break }
            ingest(batch)
            ingested += batch.count
            if batch.count < policy.recordsPerDrain { break }
        }
        droppedRecords = consumer.droppedCount()
        publish()
        return ingested
    }

    /// Instantánea actual. La UI normalmente consume `snapshots()`; esto es para el primer pintado.
    public var snapshot: LiveFeedSnapshot { currentSnapshot() }

    /// Stream de instantáneas para el view model.
    ///
    /// `bufferingNewest(1)`: si la vista va más lenta que el feed, lo correcto es que se salte
    /// instantáneas intermedias y pinte la última, no que se acumule una cola que ya nadie va a
    /// mirar. La primera instantánea se entrega en el acto para que la vista no arranque en blanco.
    public func snapshots() -> AsyncStream<LiveFeedSnapshot> {
        let (stream, continuation) = AsyncStream<LiveFeedSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        continuation.yield(currentSnapshot())
        return stream
    }

    // MARK: - Interno

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    /// Drena solo si la sesión sigue viva. La usan el despertador y el latido, no el llamante: un
    /// despertar ya encolado cuando llega `stop()` volvería a abrir el ring que se acaba de cerrar.
    private func drainIfRunning() {
        guard running else { return }
        drain()
    }

    /// Devuelve el consumidor, abriéndolo si aún no lo estaba. Un fallo no se traga ni se propaga: se
    /// registra en el snapshot y se reintenta en el siguiente drenaje, porque la causa normal es que
    /// la extensión todavía no ha creado el fichero.
    private func attachedConsumer() -> RingBufferConsumer? {
        if let consumer { return consumer }
        do {
            let opened = try openConsumer()
            consumer = opened
            isAttached = true
            lastAttachError = nil
            return opened
        } catch let error as IPCError {
            isAttached = false
            lastAttachError = error
            return nil
        } catch {
            isAttached = false
            lastAttachError = .mapFailed
            return nil
        }
    }

    private func detach() {
        consumer?.close()
        consumer = nil
        isAttached = false
    }

    private func resetSession() {
        window.reset()
        recent.removeAll(keepingCapacity: true)
        sequence = 0
        bytesIn = 0
        bytesOut = 0
        packetCount = 0
        droppedRecords = 0
        lastPublished = nil
    }

    private func ingest(_ batch: [PackedPacketMeta]) {
        for packed in batch {
            sequence &+= 1
            let packet = LivePacket(
                packed,
                sequence: sequence,
                anchor: anchor,
                localAddresses: localAddresses
            )
            window.add(date: packet.date, direction: packet.direction, length: packet.length)
            recent.append(packet)
            switch packet.direction {
            case .inbound: bytesIn &+= UInt64(packet.length)
            case .outbound: bytesOut &+= UInt64(packet.length)
            }
        }
        packetCount &+= UInt64(batch.count)
        if recent.count > policy.recentPacketCapacity {
            recent.removeFirst(recent.count - policy.recentPacketCapacity)
        }
    }

    private func currentSnapshot() -> LiveFeedSnapshot {
        LiveFeedSnapshot(
            recent: recent,
            throughput: window.samples(asOf: now()),
            droppedRecords: droppedRecords,
            bytesIn: bytesIn,
            bytesOut: bytesOut,
            packetCount: packetCount,
            lateRecords: window.lateRecords,
            isAttached: isAttached,
            lastAttachError: lastAttachError
        )
    }

    /// Publica solo si algo cambió, para no despertar a la UI 60 veces por segundo con lo mismo.
    private func publish() {
        let snapshot = currentSnapshot()
        guard snapshot != lastPublished else { return }
        lastPublished = snapshot
        for continuation in observers.values {
            continuation.yield(snapshot)
        }
    }

    private func startPolling() {
        guard let interval = policy.idlePollInterval else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return   // cancelada: es la salida normal de `stop()`
                }
                guard let self else { return }
                await self.drainIfRunning()
            }
        }
    }
}
