import XCTest
@testable import Shared

/// El lector de historial contra un `FlowStore` **real** sobre una BD temporal, no contra un doble:
/// lo que hay que probar es justo el acoplamiento con la paginación por cursor del store, que un
/// doble reproduciría a su gusto.
final class HistoryReaderTests: XCTestCase {
    private var dbURL: URL!

    override func setUp() {
        super.setUp()
        dbURL = PersistenceFixtures.temporaryDatabaseURL()
    }

    override func tearDown() {
        PersistenceFixtures.removeDatabase(at: dbURL)
        dbURL = nil
        super.tearDown()
    }

    private func makeStore() throws -> FlowStore {
        try FlowStore(databaseURL: dbURL, anchor: HistoryFixtures.anchor)
    }

    private func makeReader(
        _ store: FlowStore,
        policy: HistoryPolicy = .default,
        localAddresses: Set<IPAddress> = HistoryFixtures.localAddresses
    ) -> HistoryReader {
        HistoryReader(store: store, policy: policy, localAddresses: localAddresses)
    }

    /// Escribe un flujo con 5-tupla única. `lastSeen` en segundos desde el ancla.
    @discardableResult
    private func write(
        to store: FlowStore,
        index: Int,
        firstSeen: UInt64 = 0,
        lastSeen: UInt64,
        proto: IPProtocolNumber = .tcp,
        tlsStatus: TLSInspectionStatus = .encrypted,
        sni: String? = nil
    ) async throws -> Int64 {
        try await store.upsertFlow(
            HistoryFixtures.record(
                remote: ModelFixtures.v4(93, 184, UInt8(index / 256), UInt8(index % 256)),
                proto: proto,
                firstSeen: firstSeen,
                lastSeen: lastSeen,
                tlsStatus: tlsStatus,
                sni: sni
            )
        )
    }

    // MARK: - Estados vacíos

    func testAFreshStoreLoadsToAnEmptyState() async throws {
        let reader = makeReader(try makeStore())
        let initial = await reader.snapshot
        XCTAssertEqual(initial.state, .idle)
        XCTAssertFalse(initial.isEmpty, "sin cargar todavía, vacío no significa nada")

        await reader.refresh()
        let snapshot = await reader.snapshot
        XCTAssertEqual(snapshot.state, .loaded)
        XCTAssertTrue(snapshot.flows.isEmpty)
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertFalse(snapshot.hasMore, "no hay nada por detrás")
        XCTAssertFalse(snapshot.filter.isActive, "un historial vacío sin filtro es 'aún no hay tráfico'")
    }

    // MARK: - Paginación

    func testTheFirstPageIsTheMostRecentFlows() async throws {
        let store = try makeStore()
        for i in 1...10 {
            try await write(to: store, index: i, lastSeen: UInt64(i * 10))
        }
        let reader = makeReader(store, policy: HistoryPolicy(pageSize: 4))

        await reader.refresh()
        let snapshot = await reader.snapshot
        XCTAssertEqual(snapshot.flows.count, 4)
        XCTAssertEqual(
            snapshot.flows.map(\.lastSeen),
            [100, 90, 80, 70].map { HistoryFixtures.date(UInt64($0)) },
            "del más reciente al más antiguo"
        )
        XCTAssertTrue(snapshot.hasMore)
        XCTAssertEqual(snapshot.scannedInLastLoad, 4, "sin filtro no se lee de más")
    }

    func testLoadMoreAppendsOlderFlowsWithoutRepeating() async throws {
        let store = try makeStore()
        for i in 1...10 {
            try await write(to: store, index: i, lastSeen: UInt64(i * 10))
        }
        let reader = makeReader(store, policy: HistoryPolicy(pageSize: 4))

        await reader.refresh()
        await reader.loadMore()
        let snapshot = await reader.snapshot
        XCTAssertEqual(
            snapshot.flows.map(\.lastSeen),
            [100, 90, 80, 70, 60, 50, 40, 30].map { HistoryFixtures.date(UInt64($0)) }
        )
        XCTAssertEqual(Set(snapshot.flows.map(\.id)).count, 8, "sin filas repetidas")
        XCTAssertTrue(snapshot.hasMore)
    }

    func testHasMoreDropsWhenTheHistoryRunsOutAndLoadMoreBecomesANoOp() async throws {
        let store = try makeStore()
        for i in 1...6 {
            try await write(to: store, index: i, lastSeen: UInt64(i * 10))
        }
        let reader = makeReader(store, policy: HistoryPolicy(pageSize: 4))

        await reader.refresh()
        await reader.loadMore()
        let exhausted = await reader.snapshot
        XCTAssertEqual(exhausted.flows.count, 6)
        XCTAssertFalse(exhausted.hasMore, "la última página vino incompleta")

        await reader.loadMore()
        let after = await reader.snapshot
        XCTAssertEqual(after.flows.count, 6, "sin historial por detrás, cargar más no hace nada")
    }

    /// Varios flujos con el mismo `last_seen` no deben repetirse ni perderse al cruzar el corte de
    /// página: es el desempate por rowid del cursor, visto desde arriba.
    func testFlowsSharingATimestampPaginateWithoutLossOrRepetition() async throws {
        let store = try makeStore()
        for i in 1...9 {
            try await write(to: store, index: i, lastSeen: 42)
        }
        let reader = makeReader(store, policy: HistoryPolicy(pageSize: 4))

        await reader.refresh()
        await reader.loadMore()
        await reader.loadMore()
        let snapshot = await reader.snapshot
        XCTAssertEqual(snapshot.flows.count, 9)
        XCTAssertEqual(Set(snapshot.flows.map(\.id)).count, 9)
    }

    // MARK: - Filtros

    /// Un filtro selectivo obliga a encadenar varias consultas: la carga no se conforma con la
    /// primera página, sigue leyendo hasta reunir una página entera de **coincidencias**.
    func testAFilterKeepsScanningAcrossPagesUntilItFillsThePage() async throws {
        let store = try makeStore()
        // Uno de cada diez es UDP; el resto, TCP. Ordenados por `lastSeen`, las coincidencias caen
        // en las filas 1, 11 y 21, así que hacen falta 7 páginas de 3 para reunir 3.
        for i in 1...100 {
            try await write(
                to: store, index: i, lastSeen: UInt64(i), proto: i % 10 == 0 ? .udp : .tcp
            )
        }
        let reader = makeReader(store, policy: HistoryPolicy(pageSize: 3, maxPagesPerLoad: 8))

        await reader.apply(HistoryFilter(protocols: [.udp]))
        let snapshot = await reader.snapshot
        XCTAssertEqual(snapshot.flows.count, 3, "reúne una página entera de coincidencias")
        XCTAssertTrue(snapshot.flows.allSatisfy { $0.proto == .udp }, "y solo coincidencias")
        XCTAssertEqual(
            snapshot.flows.map(\.lastSeen),
            [100, 90, 80].map { HistoryFixtures.date(UInt64($0)) }
        )
        XCTAssertEqual(snapshot.scannedInLastLoad, 21, "leyó 7 páginas de 3, por debajo del tope")
        XCTAssertTrue(snapshot.hasMore)
    }

    /// Y si el tope de páginas llega antes que la página de coincidencias, se devuelve lo que haya:
    /// vale más una lista corta ya pintada que una carga que recorre media BD.
    func testTheBurstCapWinsOverFillingThePage() async throws {
        let store = try makeStore()
        for i in 1...100 {
            try await write(
                to: store, index: i, lastSeen: UInt64(i), proto: i % 10 == 0 ? .udp : .tcp
            )
        }
        let reader = makeReader(store, policy: HistoryPolicy(pageSize: 5, maxPagesPerLoad: 8))

        await reader.apply(HistoryFilter(protocols: [.udp]))
        let snapshot = await reader.snapshot
        XCTAssertEqual(snapshot.scannedInLastLoad, 40, "8 páginas de 5 y para")
        XCTAssertEqual(snapshot.flows.count, 4, "las 4 coincidencias que había en esas 40 filas")
        XCTAssertTrue(snapshot.hasMore)
    }

    /// Un filtro que no encuentra nada no puede convertirse en recorrer la BD entera: la carga para
    /// en el tope de páginas, devuelve lo que hay y deja `hasMore` en `true` para que el usuario
    /// decida si sigue buscando.
    func testAFruitlessFilterStopsAtTheBurstCap() async throws {
        let store = try makeStore()
        for i in 1...100 {
            try await write(to: store, index: i, lastSeen: UInt64(i))
        }
        let reader = makeReader(store, policy: HistoryPolicy(pageSize: 5, maxPagesPerLoad: 3))

        await reader.apply(HistoryFilter(searchText: "no-existe-este-host"))
        let snapshot = await reader.snapshot
        XCTAssertTrue(snapshot.flows.isEmpty)
        XCTAssertEqual(snapshot.scannedInLastLoad, 15, "3 páginas de 5 y para")
        XCTAssertTrue(snapshot.hasMore, "queda historial sin mirar")
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertTrue(snapshot.filter.isActive, "vacío por filtro, no por falta de tráfico")

        // Y continuar retoma donde lo dejó, sin volver a leer las mismas filas.
        await reader.loadMore()
        let continued = await reader.snapshot
        XCTAssertEqual(continued.scannedInLastLoad, 15)
    }

    func testFilteringBySNIFindsTheFlowsThatCarryIt() async throws {
        let store = try makeStore()
        try await write(to: store, index: 1, lastSeen: 10, sni: "cdn.example.com")
        try await write(to: store, index: 2, lastSeen: 20, sni: "apple.com")
        try await write(to: store, index: 3, lastSeen: 30, sni: "EXAMPLE.org")
        let reader = makeReader(store)

        await reader.apply(HistoryFilter(searchText: "example"))
        let snapshot = await reader.snapshot
        XCTAssertEqual(snapshot.flows.compactMap(\.displayHost), ["EXAMPLE.org", "cdn.example.com"])
    }

    func testApplyingTheSameFilterTwiceDoesNotReload() async throws {
        let store = try makeStore()
        try await write(to: store, index: 1, lastSeen: 10)
        let reader = makeReader(store)

        await reader.apply(HistoryFilter(tlsStatuses: [.encrypted]))
        let first = await reader.snapshot
        await reader.apply(HistoryFilter(tlsStatuses: [.encrypted]))
        let second = await reader.snapshot
        XCTAssertEqual(first, second)
    }

    func testChangingTheFilterRebuildsTheListFromTheTop() async throws {
        let store = try makeStore()
        try await write(to: store, index: 1, lastSeen: 10, proto: .tcp)
        try await write(to: store, index: 2, lastSeen: 20, proto: .udp)
        let reader = makeReader(store, policy: HistoryPolicy(pageSize: 1))

        await reader.refresh()
        let unfiltered = await reader.snapshot
        XCTAssertEqual(unfiltered.flows.count, 1)

        await reader.apply(HistoryFilter(protocols: [.tcp]))
        let filtered = await reader.snapshot
        XCTAssertEqual(filtered.flows.count, 1)
        XCTAssertEqual(filtered.flows.first?.proto, .tcp, "la lista se reconstruye, no se filtra en sitio")
    }

    // MARK: - Refresco

    func testRefreshPicksUpNewTrafficWithoutDuplicatingWhatWasLoaded() async throws {
        let store = try makeStore()
        for i in 1...6 {
            try await write(to: store, index: i, lastSeen: UInt64(i * 10))
        }
        let reader = makeReader(store, policy: HistoryPolicy(pageSize: 3))

        await reader.refresh()
        await reader.loadMore()
        let before = await reader.snapshot
        XCTAssertEqual(before.flows.count, 6)

        // Llega tráfico nuevo mientras la Timeline estaba abierta.
        try await write(to: store, index: 99, lastSeen: 500)
        await reader.refresh()
        let after = await reader.snapshot
        XCTAssertEqual(after.flows.count, 3, "vuelve a empezar por la primera página")
        XCTAssertEqual(after.flows.first?.lastSeen, HistoryFixtures.date(500))
        XCTAssertEqual(Set(after.flows.map(\.id)).count, 3)
    }

    // MARK: - Fechas y extremos

    func testTheDatesAreTheOnesTheStoreWrote() async throws {
        let store = try makeStore()
        try await write(to: store, index: 1, firstSeen: 5, lastSeen: 65)
        let reader = makeReader(store)

        await reader.refresh()
        let flows = await reader.snapshot.flows
        let flow = try XCTUnwrap(flows.first)
        XCTAssertEqual(flow.firstSeen, HistoryFixtures.date(5))
        XCTAssertEqual(flow.lastSeen, HistoryFixtures.date(65))
        XCTAssertEqual(flow.duration, 60, accuracy: 0.000_001)
    }

    /// Sin las IPs del túnel el historial sigue leyéndose: lo que falta es el reparto de extremos, y
    /// una fila sin host hace menos daño que una fila con el host cambiado.
    func testWithoutTunnelAddressesTheRowsStillLoadButHaveNoHost() async throws {
        let store = try makeStore()
        try await write(to: store, index: 1, lastSeen: 10, sni: nil)
        let reader = makeReader(store, localAddresses: [])

        await reader.refresh()
        let flows = await reader.snapshot.flows
        XCTAssertEqual(flows.count, 1)
        XCTAssertNil(flows.first?.displayHost)
    }

    // MARK: - Paquetes de un flujo

    func testPacketsOfAFlowComeBackDatedAndInOrder() async throws {
        let store = try makeStore()
        let key = HistoryFixtures.key(remote: ModelFixtures.v4(93, 184, 0, 1))
        let flowID = try await write(to: store, index: 1, lastSeen: 30)
        try await store.appendPackets(
            [30, 10, 20].map { HistoryFixtures.packet(timestamp: UInt64($0), key: key) },
            flowID: flowID
        )
        let reader = makeReader(store)

        let packets = try await reader.packets(forFlow: flowID)
        XCTAssertEqual(packets.map(\.date), [10, 20, 30].map { HistoryFixtures.date(UInt64($0)) })
        XCTAssertEqual(packets.map(\.flowKey), Array(repeating: key, count: 3))
    }

    func testPacketsAreCappedByThePolicy() async throws {
        let store = try makeStore()
        let key = HistoryFixtures.key(remote: ModelFixtures.v4(93, 184, 0, 1))
        let flowID = try await write(to: store, index: 1, lastSeen: 30)
        try await store.appendPackets(
            (0..<50).map { HistoryFixtures.packet(timestamp: UInt64($0), key: key) },
            flowID: flowID
        )
        let reader = makeReader(store, policy: HistoryPolicy(packetsPerFlow: 10))

        let packets = try await reader.packets(forFlow: flowID)
        XCTAssertEqual(packets.count, 10)
    }

    func testPacketsOfAnUnknownFlowAreJustEmpty() async throws {
        let reader = makeReader(try makeStore())
        let packets = try await reader.packets(forFlow: 12_345)
        XCTAssertTrue(packets.isEmpty)
    }

    // MARK: - Contenido descifrado de un flujo

    /// El orden que sale de aquí es el de la **conversación**, no el del disco: los dos sentidos están
    /// intercalados en el fichero y solo el sello los ordena entre sí.
    func testPlaintextOfAFlowComesBackInConversationOrderWithItsLocations() async throws {
        let store = try makeStore()
        let flowID = try await write(to: store, index: 1, lastSeen: 30)
        try await store.appendPlaintext(
            [
                plaintextChunk(at: 20, direction: .inbound, offset: 148, stored: 40),
                plaintextChunk(at: 10, direction: .outbound, offset: 16, stored: 60, original: 900),
            ],
            flowID: flowID
        )
        let reader = makeReader(store)

        let chunks = try await reader.plaintext(forFlow: flowID)
        XCTAssertEqual(chunks.map(\.date), [10, 20].map { HistoryFixtures.date(UInt64($0)) })
        XCTAssertEqual(chunks.map(\.direction), [.outbound, .inbound])
        XCTAssertEqual(chunks.map(\.location.recordOffset), [16, 148])
        XCTAssertEqual(chunks.first?.isTruncated, true, "las dos longitudes viajan hasta la pantalla")
        XCTAssertEqual(chunks.first?.droppedLength, 840)
    }

    func testPlaintextIsCappedByItsOwnPolicy() async throws {
        let store = try makeStore()
        let flowID = try await write(to: store, index: 1, lastSeen: 60)
        try await store.appendPlaintext(
            (0..<50).map { plaintextChunk(at: UInt64($0), offset: UInt64(16 + $0 * 96)) },
            flowID: flowID
        )
        // El tope de los paquetes se deja alto a propósito: lo que se afirma es que esta lista
        // obedece al **suyo** y no al de la otra lista de la misma pantalla.
        let reader = makeReader(store, policy: HistoryPolicy(packetsPerFlow: 500, plaintextChunksPerFlow: 8))

        let chunks = try await reader.plaintext(forFlow: flowID)
        XCTAssertEqual(chunks.count, 8)
    }

    /// La lista vacía significa dos cosas a la vez —nunca se inspeccionó, o su contenido ya caducó— y
    /// desde aquí no se distinguen: quien las separa es la pantalla, que tiene el `tlsStatus` delante.
    func testPlaintextOfAFlowWithoutAnyIsJustEmpty() async throws {
        let store = try makeStore()
        let flowID = try await write(to: store, index: 1, lastSeen: 30)
        let reader = makeReader(store)

        let chunks = try await reader.plaintext(forFlow: flowID)
        XCTAssertTrue(chunks.isEmpty)
    }

    private func plaintextChunk(
        at seconds: UInt64,
        direction: Direction = .outbound,
        offset: UInt64,
        stored: UInt32 = 60,
        original: UInt32? = nil
    ) -> PlaintextChunkMeta {
        PlaintextChunkMeta(
            timestamp: HistoryFixtures.uptime(seconds),
            direction: direction,
            stream: 7,
            location: PlaintextLocation(fileSequence: 3, recordOffset: offset),
            storedLength: stored,
            originalLength: original ?? stored
        )
    }

    // MARK: - Eje temporal (barra de scrub)

    /// Escribe un flujo con sus paquetes en los segundos indicados desde el ancla.
    private func writePackets(
        to store: FlowStore, index: Int, at seconds: [UInt64],
        proto: IPProtocolNumber = .tcp
    ) async throws {
        let remote = ModelFixtures.v4(93, 184, UInt8(index / 256), UInt8(index % 256))
        let flowID = try await store.upsertFlow(
            HistoryFixtures.record(
                remote: remote, proto: proto,
                firstSeen: seconds.min() ?? 0, lastSeen: seconds.max() ?? 0
            )
        )
        let key = HistoryFixtures.key(remote: remote, proto: proto)
        try await store.appendPackets(
            seconds.map { HistoryFixtures.packet(timestamp: $0, key: key) },
            flowID: flowID
        )
    }

    func testWithoutPacketsThereIsNoAxis() async throws {
        let store = try makeStore()
        // Un flujo sin paquetes tampoco da eje: lo que se cuenta son paquetes.
        try await write(to: store, index: 1, lastSeen: 10)
        let axis = try await makeReader(store).activity()
        XCTAssertTrue(axis.isEmpty)
    }

    /// El eje va de punta a punta del historial, con los tramos vacíos a cero y las cuentas
    /// atravesando los flujos.
    func testTheAxisCoversTheWholeHistoryWithZeroesInBetween() async throws {
        let store = try makeStore()
        try await writePackets(to: store, index: 1, at: [0, 1, 2])
        try await writePackets(to: store, index: 2, at: [3, 40])
        let reader = makeReader(store, policy: HistoryPolicy(axisBars: 5))

        let axis = try await reader.activity()
        XCTAssertEqual(axis.span?.lowerBound, HistoryFixtures.date(0))
        XCTAssertEqual(axis.totalPackets, 5, "ningún paquete se pierde entre los extremos")
        XCTAssertEqual(axis.busiest, 4)
        // 40 s en 5 barras: el escalón redondo que cabe es el de 15 s (0-15, 15-30, 30-45).
        XCTAssertEqual(axis.bars.map(\.duration), Array(repeating: 15, count: 3))
        XCTAssertEqual(axis.bars.map(\.packetCount), [4, 0, 1])
    }

    /// Cuántos tramos ofrece el eje lo dice la **pantalla**, porque es una pregunta de anchura: un
    /// tramo se toca con el dedo. El lector lo aplica y no lo decide.
    func testTheScreenDecidesHowManyIntervalsTheAxisOffers() async throws {
        let store = try makeStore()
        try await writePackets(to: store, index: 1, at: [0, 900, 1_800, 2_700, 3_600])
        let reader = makeReader(store, policy: HistoryPolicy(axisBars: 48))

        let wide = try await reader.activity()
        await reader.setAxisCapacity(5)
        let narrow = try await reader.activity()

        XCTAssertLessThanOrEqual(narrow.bars.count, 5)
        XCTAssertLessThan(narrow.bars.count, wide.bars.count, "una pantalla estrecha pide menos eje")
        XCTAssertEqual(narrow.totalPackets, wide.totalPackets, "no se pierde ni un paquete al agrupar")
    }

    /// El techo de la política sigue mandando, y un eje sin barras no es un eje: la medida de la
    /// pantalla se acota por los dos lados antes de aplicarse.
    func testTheMeasuredCapacityIsClampedBetweenOneAndThePolicysCeiling() async throws {
        let store = try makeStore()
        try await writePackets(to: store, index: 1, at: [0, 3_600, 7_200, 86_400])
        let reader = makeReader(store, policy: HistoryPolicy(axisBars: 8))

        await reader.setAxisCapacity(400)
        let capped = try await reader.activity()
        XCTAssertLessThanOrEqual(capped.bars.count, 8, "la política sigue siendo el techo")

        await reader.setAxisCapacity(0)
        let floored = try await reader.activity()
        XCTAssertEqual(floored.bars.count, 1)
        XCTAssertEqual(floored.totalPackets, 4)
    }

    /// La resolución la fija la política, no el tráfico: es lo que impide que un historial largo
    /// devuelva cientos de tramos que no se pueden tocar con el dedo.
    func testTheAxisNeverExceedsThePolicysBars() async throws {
        let store = try makeStore()
        try await writePackets(to: store, index: 1, at: [0, 3_600, 7_200, 86_400])
        let reader = makeReader(store, policy: HistoryPolicy(axisBars: 8))

        let axis = try await reader.activity()
        XCTAssertLessThanOrEqual(axis.bars.count, 8)
        XCTAssertEqual(axis.totalPackets, 4)
    }

    /// El eje **no** honra el filtro de la lista: cuenta también los paquetes de conexiones que el
    /// filtro esconde, porque el de host se resuelve en memoria y honrar la mitad sería peor.
    func testTheAxisIgnoresTheFilterOnTheList() async throws {
        let store = try makeStore()
        try await writePackets(to: store, index: 1, at: [0, 1], proto: .tcp)
        try await writePackets(to: store, index: 2, at: [2, 3], proto: .udp)
        let reader = makeReader(store)

        await reader.apply(HistoryFilter(protocols: [.tcp]))
        let snapshot = await reader.snapshot
        XCTAssertEqual(snapshot.flows.count, 1, "la lista sí filtra")

        let axis = try await reader.activity()
        XCTAssertEqual(axis.totalPackets, 4, "el eje cuenta todo lo guardado")
    }

    /// Un solo paquete no deja el eje sin nada que enseñar: es un tramo nulo, que es una barra.
    func testASinglePacketIsOneBar() async throws {
        let store = try makeStore()
        try await writePackets(to: store, index: 1, at: [7])
        let axis = try await makeReader(store).activity()

        XCTAssertEqual(axis.bars.count, 1)
        XCTAssertEqual(axis.bars.first?.packetCount, 1)
        XCTAssertEqual(axis.bars.first?.start, HistoryFixtures.date(7))
    }

    // MARK: - Acercarse a un tramo

    /// Lo que hace que la barra se pueda acercar: el mismo agregado acotado al tramo, con la anchura
    /// de barra que le toca al tramo nuevo y sin nada de fuera.
    func testTheAxisCanBeDrawnOverOneStretchOfTheHistory() async throws {
        let store = try makeStore()
        try await writePackets(to: store, index: 1, at: [0, 1, 2])
        try await writePackets(to: store, index: 2, at: [3_600])
        let reader = makeReader(store)

        let whole = try await reader.activity()
        XCTAssertEqual(whole.totalPackets, 4)
        // Una hora en 48 barras: el escalón redondo que cabe es el de 5 min.
        XCTAssertEqual(whole.bars.first?.duration, 300)

        let stretch = try await reader.activity(in: HistoryFixtures.date(0)...HistoryFixtures.date(300))
        XCTAssertEqual(stretch.totalPackets, 3, "el paquete de la hora siguiente queda fuera")
        XCTAssertEqual(stretch.bars.first?.duration, 15, "el tramo nuevo se dibuja más fino")
        XCTAssertEqual(stretch.span?.lowerBound, HistoryFixtures.date(0))
    }

    /// El tramo pedido **no se recorta** contra lo guardado: si la retención se lo llevó, lo que vuelve
    /// es un eje a cero. Distinguir eso de "no hay historial" es de la pantalla, que es la única que
    /// sabe que ese tramo lo eligió el usuario.
    func testAStretchWithNothingLeftComesBackAtZeroAndNotEmpty() async throws {
        let store = try makeStore()
        try await writePackets(to: store, index: 1, at: [0, 1])
        let reader = makeReader(store)

        let gone = try await reader.activity(
            in: HistoryFixtures.date(10_000)...HistoryFixtures.date(10_300)
        )
        XCTAssertFalse(gone.isEmpty, "hay historial, así que hay eje que dibujar")
        XCTAssertEqual(gone.totalPackets, 0)
    }

    /// Sin nada guardado no hay eje ni siquiera para un tramo pedido: la barra no se dibuja, y eso es
    /// otra afirmación distinta de la de un tramo vacío dentro de un historial que sí existe.
    func testWithoutAnyHistoryEvenAStretchGivesNoAxis() async throws {
        let store = try makeStore()
        let axis = try await makeReader(store).activity(
            in: HistoryFixtures.date(0)...HistoryFixtures.date(300)
        )
        XCTAssertTrue(axis.isEmpty)
    }

    /// La regla de si se puede bajar es pura, pero el tope de barras es de la política y vive en el
    /// lector: preguntarlo desde la pantalla obligaría a repetir ese número.
    func testWhetherABarCanBeEnteredIsAnsweredAgainstThePolicy() async throws {
        let store = try makeStore()
        let reader = makeReader(store, policy: HistoryPolicy(axisBars: 6))
        let hour = ActivityBar(start: HistoryFixtures.date(0), duration: 3_600, packetCount: 9)
        let second = ActivityBar(start: HistoryFixtures.date(0), duration: 1, packetCount: 9)
        let quiet = ActivityBar(start: HistoryFixtures.date(0), duration: 3_600, packetCount: 0)

        var canEnterHour = await reader.canZoom(into: hour)
        XCTAssertTrue(canEnterHour)
        canEnterHour = await reader.canZoom(into: second)
        XCTAssertFalse(canEnterHour, "el escalón más fino es el suelo")
        canEnterHour = await reader.canZoom(into: quiet)
        XCTAssertFalse(canEnterHour, "dentro de un tramo vacío no hay nada que mirar")

        let further = await reader.canZoomFurther(in: ActivityAxis(bars: [quiet, hour]))
        XCTAssertTrue(further, "basta con que quede un tramo en el que entrar")
        let none = await reader.canZoomFurther(in: ActivityAxis(bars: [quiet, second]))
        XCTAssertFalse(none)
        let empty = await reader.canZoomFurther(in: .empty)
        XCTAssertFalse(empty)
    }

    // MARK: - Publicación

    func testTheStreamPublishesTheLoadingStateAndThenTheResult() async throws {
        let store = try makeStore()
        for i in 1...3 {
            try await write(to: store, index: i, lastSeen: UInt64(i * 10))
        }
        let reader = makeReader(store)

        let stream = await reader.snapshots()
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.state, .idle, "la primera instantánea llega en el acto")

        await reader.refresh()
        var states: [HistoryState] = []
        var flowCount = 0
        // El stream bufferiza solo la última, así que se consume hasta ver el estado final.
        while let snapshot = await iterator.next() {
            states.append(snapshot.state)
            if snapshot.state == .loaded {
                flowCount = snapshot.flows.count
                break
            }
        }
        XCTAssertEqual(states.last, .loaded)
        XCTAssertEqual(flowCount, 3)
    }

    // MARK: - Páginas sueltas (el export)

    func testAFlowPageWalksBackwardsFromItsOwnCursor() async throws {
        let store = try makeStore()
        for i in 1...5 {
            try await write(to: store, index: i, lastSeen: UInt64(i))
        }
        let reader = makeReader(store)

        let first = try await reader.flowPage(limit: 2, after: nil)
        let second = try await reader.flowPage(limit: 2, after: FlowCursor(after: first[1].stored))

        // Del más reciente al más antiguo y sin solaparse: el cursor entra y sale por parámetro.
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(second.count, 2)
        XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with: Set(second.map(\.id))))
        XCTAssertGreaterThan(first[0].lastSeen, second[0].lastSeen)
    }

    func testAFlowPageDoesNotDisturbTheScreenThatIsPaginating() async throws {
        // Es la razón de que exista: exportar no puede mover la lista que el usuario tiene cargada.
        let store = try makeStore()
        for i in 1...10 {
            try await write(to: store, index: i, lastSeen: UInt64(i))
        }
        let reader = makeReader(store, policy: HistoryPolicy(pageSize: 4))
        await reader.refresh()
        let before = await reader.snapshot

        _ = try await reader.flowPage(limit: 10, after: nil)
        let after = await reader.snapshot

        XCTAssertEqual(before, after)
        XCTAssertEqual(after.flows.count, 4)
    }

    func testAFlowPageIgnoresTheFilterTheScreenHasApplied() async throws {
        // Lo que se exporta desde la pantalla de capturas es el historial, no lo que otra pantalla
        // tenga puesto en su buscador: un export que honrase un filtro invisible desde donde se pide
        // sería un fichero incompleto sin manera de saberlo.
        let store = try makeStore()
        try await write(to: store, index: 1, lastSeen: 1, sni: "keep.example")
        try await write(to: store, index: 2, lastSeen: 2, sni: "drop.example")
        let reader = makeReader(store)
        await reader.apply(HistoryFilter(searchText: "keep"))

        let listed = await reader.snapshot.flows
        let exported = try await reader.flowPage(limit: 10, after: nil)

        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(exported.count, 2)
    }

    func testConcurrentLoadsNeverDuplicateRows() async throws {
        let store = try makeStore()
        for i in 1...20 {
            try await write(to: store, index: i, lastSeen: UInt64(i))
        }
        let reader = makeReader(store, policy: HistoryPolicy(pageSize: 5))

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { await reader.loadMore() }
            }
        }
        let snapshot = await reader.snapshot
        XCTAssertEqual(
            Set(snapshot.flows.map(\.id)).count, snapshot.flows.count, "sin filas repetidas"
        )
        XCTAssertFalse(snapshot.flows.isEmpty)
    }
}
