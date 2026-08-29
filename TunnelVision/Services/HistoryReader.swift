import Foundation
import Shared

/// El servicio que lee lo que la extensión dejó escrito (M9): el tercero y último de
/// `docs/spec/app-services.md`.
///
/// El feed en vivo enseña *lo que está pasando*; esto enseña *lo que pasó*. Alimenta la Timeline y
/// el Flow Inspector de `docs/ux/screens.md` paginando el `FlowStore` hacia atrás en el tiempo,
/// aplicando los filtros de la pantalla y publicando una `HistorySnapshot` para la vista.
///
/// Es un `actor` por lo mismo que `LiveFeedReader`: la paginación es estado mutable (el cursor, la
/// lista acumulada) que varias acciones de la UI pueden tocar a la vez —un "cargar más" mientras
/// llega un cambio de filtro—, y el aislamiento del actor es lo que serializa eso sin candados. El
/// `@MainActor` es el view model que consume `snapshots()`.
///
/// No hay costura nueva: `FlowStore` ya es Simulator-testeable sobre una BD temporal, así que el
/// lector se prueba contra un store **real**, que además es lo interesante (la paginación por cursor
/// solo se puede confirmar contra SQL de verdad).
///
/// **La actualización es explícita.** No hay observación viva de la BD: quien escribe es otro
/// proceso y SQLite no notifica entre procesos. La Timeline recarga al aparecer y cuando el usuario
/// tira para refrescar; lo que sí es continuo es el feed en vivo, que para eso existe.
public actor HistoryReader {

    // MARK: - Dependencias inmutables

    private let store: FlowStore
    private let policy: HistoryPolicy
    private let localAddresses: Set<IPAddress>

    // MARK: - Estado de la paginación

    private var flows: [HistoryFlow] = []
    private var filter: HistoryFilter = .none
    private var state: HistoryState = .idle
    private var hasMore = true
    private var scannedInLastLoad = 0

    /// Punto de lectura en el store: la última fila **leída**, coincidiese o no con el filtro. Va
    /// aparte de la lista visible a propósito — si el cursor avanzara solo con las coincidencias,
    /// una carga filtrada volvería a recorrer desde el principio las filas que ya descartó.
    private var cursor: FlowCursor?

    /// Evita que dos cargas se solapen. Sin él, un `loadMore` disparado por el scroll mientras otro
    /// está esperando al store leería dos veces desde el mismo cursor y duplicaría el trabajo.
    private var isLoading = false

    private var observers: [UUID: AsyncStream<HistorySnapshot>.Continuation] = [:]
    private var lastPublished: HistorySnapshot?

    /// Los tramos que ofrece el eje temporal. Empieza en el techo de la política y lo baja la
    /// pantalla en cuanto sabe lo que mide (`setAxisCapacity`), porque cuántos tramos caben es una
    /// pregunta de anchura: cada uno se toca con el dedo.
    private var axisBars: Int

    // MARK: - Construcción

    public init(
        store: FlowStore,
        policy: HistoryPolicy = .default,
        localAddresses: Set<IPAddress> = TunnelAddressing.localAddresses
    ) {
        self.store = store
        self.policy = policy
        self.localAddresses = localAddresses
        self.axisBars = policy.axisBars
    }

    deinit {
        for continuation in observers.values { continuation.finish() }
    }

    // MARK: - Publicación

    /// Instantánea actual. La UI normalmente consume `snapshots()`; esto es para el primer pintado.
    public var snapshot: HistorySnapshot { currentSnapshot() }

    /// Stream de instantáneas para el view model, con la misma política que el feed en vivo:
    /// `bufferingNewest(1)` porque una instantánea intermedia que la vista no llegó a pintar ya no
    /// le interesa a nadie.
    public func snapshots() -> AsyncStream<HistorySnapshot> {
        let (stream, continuation) = AsyncStream<HistorySnapshot>.makeStream(
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

    // MARK: - Carga

    /// Recarga desde el principio: olvida el cursor y la lista y trae la primera página.
    ///
    /// Reconstruir en vez de fusionar es deliberado: entre dos refrescos la extensión ha podido
    /// actualizar flujos que estaban en mitad de la lista, y esos suben al principio por `last_seen`.
    /// Intentar coserlo dejaría filas repetidas o en un orden que ya no es el del store.
    public func refresh() async {
        guard !isLoading else { return }
        flows = []
        cursor = nil
        hasMore = true
        await load(initial: true)
    }

    /// Trae la página siguiente hacia atrás en el tiempo y la añade al final. No hace nada si ya no
    /// queda historial o si hay otra carga en curso.
    public func loadMore() async {
        guard !isLoading, hasMore else { return }
        await load(initial: flows.isEmpty)
    }

    /// Cambia el filtro y recarga. Cambiar lo que coincide invalida la lista entera, no solo su cola.
    public func apply(_ filter: HistoryFilter) async {
        guard filter != self.filter else { return }
        self.filter = filter
        await refresh()
    }

    /// Paquetes de un flujo para el Flow Inspector, en orden temporal ascendente.
    ///
    /// Este sí lanza, al contrario que las acciones de carga: quien lo llama es una pantalla que se
    /// abre *para* enseñar esos paquetes, así que un fallo es suyo y no del estado de la lista — el
    /// mismo reparto que hay entre `TunnelController.send` y sus acciones de interruptor.
    public func packets(forFlow id: Int64) async throws -> [StoredPacket] {
        do {
            return try await store.packets(forFlow: id, limit: policy.packetsPerFlow)
        } catch {
            throw HistoryError.classifying(error)
        }
    }

    /// Trozos de contenido descifrado de un flujo para el Flow Inspector, en orden temporal ascendente.
    ///
    /// Devuelve **metadatos**, no bytes: cada fila dice dónde están los suyos y quien los lee es
    /// `PlaintextLibrary`. Ese reparto es lo que permite traerse la conversación entera —que son unas
    /// decenas de filas— y abrir el fichero solo para lo que se vaya a enseñar.
    ///
    /// El orden es el de la **conversación** y no el del disco: los trozos de los dos sentidos están
    /// intercalados entre sí y entre los de otros flujos dentro del fichero, así que quien los ordena
    /// es el índice por su sello (`FlowStore.plaintext(forFlow:limit:)`), que es el único sitio donde
    /// los dos sentidos comparten una regla.
    ///
    /// Una lista vacía significa las dos cosas a la vez y desde aquí no se distinguen: que la conexión
    /// nunca se inspeccionó (o se inspeccionó sin permiso para guardar nada) y que su contenido ya
    /// caducó. Quien las separa es la pantalla, que tiene delante el `tlsStatus` del flujo.
    ///
    /// Lanza por lo mismo que `packets(forFlow:)`: quien pregunta lo hace para enseñar justo esto.
    public func plaintext(forFlow id: Int64) async throws -> [StoredPlaintextChunk] {
        do {
            return try await store.plaintext(forFlow: id, limit: policy.plaintextChunksPerFlow)
        } catch {
            throw HistoryError.classifying(error)
        }
    }

    /// Relee **una** conexión, o `nil` si la retención ya se la llevó.
    ///
    /// Existe para el Flow Inspector, cuya cabecera era una foto tomada en la Timeline: una conexión
    /// todavía viva sigue sumando bytes y duración mientras la pantalla está abierta, y sin esto no
    /// había forma de traerlos sin recargar la lista entera de detrás.
    ///
    /// Va por id y no por clave a propósito: los puertos efímeros se reciclan, así que la misma 5-tupla
    /// puede tener varias filas y la más reciente puede ser **otra** conexión. Lanza por lo mismo que
    /// `packets(forFlow:)`: quien pregunta está enseñando justo eso.
    public func flow(id: Int64) async throws -> HistoryFlow? {
        do {
            guard let stored = try await store.flow(id: id) else { return nil }
            return HistoryFlow(stored, localAddresses: localAddresses)
        } catch {
            throw HistoryError.classifying(error)
        }
    }

    /// Una página del historial hacia atrás en el tiempo, **sin tocar el estado de la pantalla**.
    ///
    /// Es lo que consume el export del listado de conexiones (`FlowExporter`), y existe aparte de
    /// `loadMore()` precisamente por eso: aquella avanza el cursor de la Timeline y publica una
    /// instantánea, y un export no puede mover la lista que el usuario está mirando. Aquí el cursor
    /// entra y sale por parámetro, así que quien recorre lleva el suyo.
    ///
    /// **No aplica el filtro.** Lo que se exporta desde la pantalla de capturas es el historial, no lo
    /// que otra pantalla tenga puesto en su buscador; un export que honrase un filtro que no se ve
    /// desde donde se pide sería un fichero incompleto sin manera de saberlo.
    ///
    /// Lanza, como `packets(forFlow:)` y `activity()`: quien la llama lo hace para una acción concreta
    /// del usuario, así que el fallo es suyo y no del estado de la lista.
    public func flowPage(limit: Int, after cursor: FlowCursor?) async throws -> [HistoryFlow] {
        do {
            return try await store.recentFlows(limit: limit, before: cursor)
                .map { HistoryFlow($0, localAddresses: localAddresses) }
        } catch {
            throw HistoryError.classifying(error)
        }
    }

    /// Si acercarse a esta barra enseñaría algo que ahora mismo no se ve.
    ///
    /// La regla es pura (`TimelineActivity.canZoom`) pero necesita el tope de barras, que es de la
    /// política y vive aquí: preguntarlo desde la pantalla obligaría a repetir la política en el view
    /// model, y dos copias del mismo número acabarían discrepando justo cuando alguien la cambiase.
    public func canZoom(into bar: ActivityBar) -> Bool {
        TimelineActivity.canZoom(into: bar, maxBars: axisBars)
    }

    /// Cuántos tramos cabe ofrecer en el eje, que lo decide la **anchura** de la pantalla y no el
    /// coste de la consulta: un tramo se toca con el dedo y le debe los 44 puntos de la HIG
    /// (`ScrubCapacity`). Lo mide la pantalla, que es la única que sabe lo que ocupa.
    ///
    /// Se acota contra `policy.axisBars`, que sigue siendo lo que era —el techo de coste—, y contra
    /// 1 por abajo: un eje sin barras no es un eje. Y se guarda aquí, junto a la política, para que
    /// `canZoom` y `activity` sigan leyendo **el mismo** número; dos copias del tope acabarían
    /// discrepando justo cuando alguien cambiase una.
    public func setAxisCapacity(_ intervals: Int) {
        axisBars = min(max(1, intervals), policy.axisBars)
    }

    /// Si queda algún tramo del eje en el que se pueda entrar. Lo pregunta la pantalla para no
    /// prometer un gesto que no haría nada: en un eje ya en el escalón más fino, tocar un tramo lo
    /// filtra y nada más.
    public func canZoomFurther(in axis: ActivityAxis) -> Bool {
        axis.bars.contains { canZoom(into: $0) }
    }

    /// El eje temporal del historial para la barra de scrub, con los tramos vacíos a cero.
    ///
    /// Con `range` el eje se dibuja **solo** dentro de ese tramo, que es lo que hace que la barra se
    /// pueda acercar: el mismo agregado, acotado, con la anchura de barra que le toca al tramo nuevo.
    /// El rango se pasa tal cual y **no se recorta** contra lo que hay guardado — si la retención se
    /// llevó el tramo, lo que vuelve es un eje a cero, y qué hacer con eso es de la pantalla, que es
    /// la única que sabe que ese tramo lo eligió el usuario y puede decírselo.
    ///
    /// Es una consulta **distinta** de la paginación de la lista y por eso no viaja en la instantánea:
    /// no lee filas hacia atrás desde un cursor, sino que agrega cuentas por intervalo sobre todo lo
    /// guardado. Se pide aparte porque también cambia aparte — la lista se recarga al cambiar un
    /// filtro, y el eje no, precisamente porque no depende de ninguno.
    ///
    /// **El eje no honra el filtro.** Cuenta todos los paquetes guardados, también los de conexiones
    /// que la lista esconde. Podría honrar el protocolo y el estado TLS (son columnas), pero no el
    /// host, que se busca en memoria contra el host visible; honrar la mitad dejaría un eje que parece
    /// filtrado sin serlo, que es peor que uno que declara no estarlo. Decirlo es de la pantalla.
    ///
    /// Lanza, como `packets(forFlow:)` y por lo mismo: quien lo pide lo pide para dibujarlo, así que
    /// el fallo es suyo y no del estado de la lista.
    public func activity(in range: ClosedRange<Date>? = nil) async throws -> ActivityAxis {
        do {
            // Sin nada guardado no hay eje ni siquiera para un tramo pedido: la barra no se dibuja, y
            // eso es distinto de un tramo vacío dentro de un historial que sí existe.
            guard let bounds = try await store.packetTimeBounds() else { return .empty }
            let span = range ?? bounds
            let seconds = span.upperBound.timeIntervalSince(span.lowerBound)
            let bucketDuration = TimelineActivity.bucketDuration(
                forSpan: seconds, maxBars: axisBars
            )
            let counts = try await store.packetCounts(in: span, bucketDuration: bucketDuration)
            return TimelineActivity.axis(
                counts: counts,
                span: span,
                bucketDuration: bucketDuration,
                maxBars: axisBars
            )
        } catch {
            throw HistoryError.classifying(error)
        }
    }

    // MARK: - Interno

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    /// El bucle de carga: pide páginas al store hasta reunir `pageSize` coincidencias, agotar el
    /// historial o alcanzar el tope de páginas. Un filtro muy selectivo hace que una carga lea mucho
    /// y enseñe poco; el tope es lo que impide que eso se convierta en recorrer la BD entera.
    private func load(initial: Bool) async {
        isLoading = true
        state = initial ? .loading : .loadingOlder
        publish()

        var matched: [HistoryFlow] = []
        var scanned = 0

        for _ in 0..<policy.maxPagesPerLoad {
            let page: [StoredFlow]
            do {
                page = try await store.recentFlows(limit: policy.pageSize, before: cursor)
            } catch {
                state = .failed(HistoryError.classifying(error))
                isLoading = false
                publish()
                return
            }

            scanned += page.count
            if let last = page.last {
                cursor = FlowCursor(after: last)
            }
            // Una página incompleta significa que el store se quedó sin filas por detrás.
            if page.count < policy.pageSize {
                hasMore = false
            }
            matched.append(
                contentsOf: page
                    .map { HistoryFlow($0, localAddresses: localAddresses) }
                    .filter(filter.matches)
            )
            if !hasMore || matched.count >= policy.pageSize { break }
        }

        flows = HistoryPaging.appending(matched, to: flows)
        scannedInLastLoad = scanned
        state = .loaded
        isLoading = false
        publish()
    }

    private func currentSnapshot() -> HistorySnapshot {
        HistorySnapshot(
            flows: flows,
            filter: filter,
            state: state,
            hasMore: hasMore,
            scannedInLastLoad: scannedInLastLoad
        )
    }

    /// Publica solo si algo cambió, para no despertar a la vista con la misma lista.
    private func publish() {
        let snapshot = currentSnapshot()
        guard snapshot != lastPublished else { return }
        lastPublished = snapshot
        for continuation in observers.values {
            continuation.yield(snapshot)
        }
    }
}
