import Foundation
import XCTest
import Shared

/// Tests del lector del feed en vivo (M9) contra un ring **real** respaldado por fichero temporal —
/// el mismo `RingBufferProducer`/`RingBufferConsumer` de M5, no un doble—, con el despertador y los
/// dos relojes inyectados.
///
/// Que el ring sea real importa: lo que se ejercita es el acoplamiento entre el productor de la
/// extensión y el consumidor de la app, que es justo donde un fallo no lo vería ningún test de
/// unidades aisladas.
final class LiveFeedReaderTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private var files: [URL] = []

    override func tearDown() {
        for url in files { try? FileManager.default.removeItem(at: url) }
        files.removeAll()
        super.tearDown()
    }

    // MARK: - Utilidades

    private func tempFile() -> URL {
        let url = LiveFeedFixtures.tempFile()
        files.append(url)
        return url
    }

    /// Ancla trivial (uptime 0 ⇒ el sello en ns es el desplazamiento sobre `epoch`) y reloj fijo, para
    /// que ni las fechas ni el eje del gráfico dependan de cuándo corra el test.
    private func makeReader(
        fileURL: URL,
        wakeup: FakeLiveFeedWakeup,
        policy: LiveFeedPolicy = LiveFeedPolicy(idlePollInterval: nil)
    ) -> LiveFeedReader {
        let epoch = self.epoch
        return LiveFeedReader(
            fileURL: fileURL,
            policy: policy,
            wakeup: wakeup,
            anchorProvider: { MonotonicAnchor(uptimeNanoseconds: 0, wallClock: epoch) },
            now: { epoch }
        )
    }

    private func makeProducer(_ url: URL, slotCount: Int = 1_024) throws -> RingBufferProducer {
        try RingBufferProducer(fileURL: url, slotCount: slotCount)
    }

    /// Espera acotada a que el snapshot cumpla una condición. Solo la usan los tests del despertador y
    /// del latido, donde el drenaje ocurre en una tarea que el test no controla.
    private func waitForSnapshot(
        _ reader: LiveFeedReader,
        timeout: Duration = .seconds(5),
        where predicate: (LiveFeedSnapshot) -> Bool
    ) async -> LiveFeedSnapshot? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let snapshot = await reader.snapshot
            if predicate(snapshot) { return snapshot }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    // MARK: - Enganche al ring

    /// Antes del primer arranque del túnel el fichero del ring no existe. Eso es el estado normal de
    /// una app recién instalada, no una avería: el lector lo dice y lo reintenta.
    func testWithoutARingTheReaderReportsItIsDetachedInsteadOfFailing() async {
        let reader = makeReader(fileURL: tempFile(), wakeup: FakeLiveFeedWakeup())

        let ingested = await reader.drain()
        let snapshot = await reader.snapshot

        XCTAssertEqual(ingested, 0)
        XCTAssertFalse(snapshot.isAttached)
        XCTAssertEqual(snapshot.lastAttachError, .mapFailed)
        XCTAssertTrue(snapshot.recent.isEmpty)
    }

    /// Y cuando la extensión por fin lo crea, el siguiente drenaje se engancha sin que nadie tenga que
    /// reconstruir el lector.
    func testTheReaderAttachesWhenTheExtensionCreatesTheRing() async throws {
        let url = tempFile()
        let reader = makeReader(fileURL: url, wakeup: FakeLiveFeedWakeup())
        let firstAttempt = await reader.drain()
        XCTAssertEqual(firstAttempt, 0)

        let producer = try makeProducer(url)
        defer { producer.close() }
        producer.push(LiveFeedFixtures.packed(timestamp: 1_000_000, direction: .outbound, length: 60))

        let ingested = await reader.drain()
        let snapshot = await reader.snapshot

        XCTAssertEqual(ingested, 1)
        XCTAssertTrue(snapshot.isAttached)
        XCTAssertNil(snapshot.lastAttachError)
        XCTAssertEqual(snapshot.recent.count, 1)
    }

    /// La extensión **recrea** el fichero en cada sesión, así que un mapeo viejo se quedaría mirando
    /// un ring muerto sin dar un solo error. `reattach()` es la salida, y la UI la dispara al ver el
    /// túnel arrancar.
    func testReattachPicksUpARingRecreatedByANewSession() async throws {
        let url = tempFile()
        let reader = makeReader(fileURL: url, wakeup: FakeLiveFeedWakeup())

        let first = try makeProducer(url)
        first.push(LiveFeedFixtures.packed(timestamp: 1_000, direction: .outbound, length: 100))
        await reader.drain()
        first.close()

        // Sesión nueva: el productor recrea el fichero desde cero.
        let second = try makeProducer(url)
        defer { second.close() }
        second.push(LiveFeedFixtures.packed(timestamp: 2_000, direction: .inbound, length: 200))

        await reader.reattach()
        let snapshot = await reader.snapshot

        XCTAssertTrue(snapshot.isAttached)
        XCTAssertEqual(snapshot.packetCount, 2)
        XCTAssertEqual(snapshot.bytesIn, 200)
    }

    // MARK: - Drenaje

    /// El camino normal: la extensión empuja un lote y postea la señal; el lector se despierta y lo
    /// recoge sin que nadie le diga cuántos registros hay (la notificación Darwin no lleva datos).
    func testAWakeupDrainsWhatTheProducerPushed() async throws {
        let url = tempFile()
        let producer = try makeProducer(url)
        defer { producer.close() }
        let wakeup = FakeLiveFeedWakeup()
        let reader = makeReader(fileURL: url, wakeup: wakeup)
        await reader.start()

        for i in 0..<5 {
            producer.push(LiveFeedFixtures.packed(timestamp: UInt64(i) * 1_000, direction: .outbound, length: 100))
        }
        wakeup.fire()

        let snapshot = await waitForSnapshot(reader) { $0.packetCount == 5 }
        XCTAssertEqual(snapshot?.bytesOut, 500)
        XCTAssertTrue(wakeup.isListening)
    }

    /// Un despertar puede corresponder a muchos más registros que un lote, porque la señal viene
    /// coalescida. El lector drena en bucle hasta vaciar en vez de asumir un registro por aviso.
    func testABurstBiggerThanOneBatchIsDrainedInASinglePass() async throws {
        let url = tempFile()
        let producer = try makeProducer(url)
        defer { producer.close() }
        let policy = LiveFeedPolicy(recordsPerDrain: 4, maxDrainsPerBurst: 8, idlePollInterval: nil)
        let reader = makeReader(fileURL: url, wakeup: FakeLiveFeedWakeup(), policy: policy)

        for i in 0..<20 {
            producer.push(LiveFeedFixtures.packed(timestamp: UInt64(i), direction: .outbound, length: 10))
        }

        let ingested = await reader.drain()

        XCTAssertEqual(ingested, 20)
    }

    /// Pero el bucle está acotado: con el ring a tope, el lector coge su ración y cede en vez de
    /// monopolizar el actor mientras la extensión sigue empujando. Lo que queda espera al siguiente
    /// aviso o al latido.
    func testTheBurstCapLeavesTheRestForTheNextPass() async throws {
        let url = tempFile()
        let producer = try makeProducer(url)
        defer { producer.close() }
        let policy = LiveFeedPolicy(recordsPerDrain: 4, maxDrainsPerBurst: 2, idlePollInterval: nil)
        let reader = makeReader(fileURL: url, wakeup: FakeLiveFeedWakeup(), policy: policy)

        for i in 0..<20 {
            producer.push(LiveFeedFixtures.packed(timestamp: UInt64(i), direction: .outbound, length: 10))
        }

        let first = await reader.drain()
        let second = await reader.drain()
        let third = await reader.drain()
        let fourth = await reader.drain()

        XCTAssertEqual([first, second, third, fourth], [8, 8, 4, 0])
        let snapshot = await reader.snapshot
        XCTAssertEqual(snapshot.packetCount, 20)
    }

    /// El latido existe para cubrir una señal perdida: sin ningún despertar, el lector acaba viendo lo
    /// que hay en el ring.
    func testTheHeartbeatDrainsWithoutAnyWakeup() async throws {
        let url = tempFile()
        let producer = try makeProducer(url)
        defer { producer.close() }
        let policy = LiveFeedPolicy(idlePollInterval: .milliseconds(20))
        let reader = makeReader(fileURL: url, wakeup: FakeLiveFeedWakeup(), policy: policy)
        await reader.start()

        producer.push(LiveFeedFixtures.packed(timestamp: 1_000, direction: .inbound, length: 1_500))

        let snapshot = await waitForSnapshot(reader) { $0.packetCount == 1 }
        XCTAssertEqual(snapshot?.bytesIn, 1_500)
        await reader.stop()
    }

    // MARK: - Contenido del snapshot

    /// Los dos sentidos se contabilizan por separado: es lo que dibuja las dos series del gráfico y lo
    /// que la Dashboard enseña como "datos usados".
    func testTheSnapshotKeepsBothSensesApart() async throws {
        let url = tempFile()
        let producer = try makeProducer(url)
        defer { producer.close() }
        let reader = makeReader(fileURL: url, wakeup: FakeLiveFeedWakeup())

        producer.push(LiveFeedFixtures.packed(timestamp: 0, direction: .outbound, length: 100))
        producer.push(LiveFeedFixtures.packed(timestamp: 500_000_000, direction: .inbound, length: 1_400))
        producer.push(LiveFeedFixtures.packed(timestamp: 900_000_000, direction: .outbound, length: 60))
        await reader.drain()

        let snapshot = await reader.snapshot

        XCTAssertEqual(snapshot.packetCount, 3)
        XCTAssertEqual(snapshot.bytesOut, 160)
        XCTAssertEqual(snapshot.bytesIn, 1_400)
        // Los tres caen en la misma barra de 1 s (sellos 0, 0,5 y 0,9 s sobre el ancla).
        let bar = snapshot.throughput.last
        XCTAssertEqual(bar?.bytesOut, 160)
        XCTAssertEqual(bar?.bytesIn, 1_400)
    }

    /// Cada registro sale ya con el host remoto resuelto y con hora de pared: es lo que `PackedPacketMeta`
    /// no sabe y sin lo cual una fila de la UI no se puede pintar.
    func testEachRecordArrivesAsAPacketTheUICanRender() async throws {
        let url = tempFile()
        let producer = try makeProducer(url)
        defer { producer.close() }
        let reader = makeReader(fileURL: url, wakeup: FakeLiveFeedWakeup())

        producer.push(
            LiveFeedFixtures.packed(timestamp: 2_500_000_000, direction: .outbound, length: 74, capture: CaptureLocation(fileSequence: 4, recordOffset: 24))
        )
        await reader.drain()

        let recent = await reader.snapshot.recent
        let packet = try XCTUnwrap(recent.first)

        XCTAssertEqual(packet.id, 1)
        XCTAssertEqual(packet.remoteEndpoint, LiveFeedFixtures.remote)
        XCTAssertEqual(packet.endpoints?.local.address, TunnelAddressing.localIPv4)
        XCTAssertEqual(packet.length, 74)
        XCTAssertEqual(packet.capture, CaptureLocation(fileSequence: 4, recordOffset: 24))
        XCTAssertEqual(packet.date.timeIntervalSince(epoch), 2.5, accuracy: 1e-9)
    }

    /// La lista de recientes está acotada por la política: el histórico completo es del store, no de
    /// la memoria de la app. Se conservan los **últimos**, que es lo que la Dashboard enseña.
    func testRecentPacketsAreCappedAndKeepTheNewest() async throws {
        let url = tempFile()
        let producer = try makeProducer(url)
        defer { producer.close() }
        let policy = LiveFeedPolicy(recentPacketCapacity: 10, idlePollInterval: nil)
        let reader = makeReader(fileURL: url, wakeup: FakeLiveFeedWakeup(), policy: policy)

        for i in 1...50 {
            producer.push(LiveFeedFixtures.packed(timestamp: UInt64(i), direction: .outbound, length: 10))
        }
        await reader.drain()

        let snapshot = await reader.snapshot

        XCTAssertEqual(snapshot.recent.count, 10)
        XCTAssertEqual(snapshot.recent.map(\.id), Array(41...50).map(UInt64.init))
        XCTAssertEqual(snapshot.packetCount, 50)   // el contador sí cuenta los 50
    }

    /// Los descartes por back-pressure de la extensión se propagan tal cual: es la única señal de que
    /// el feed no lo está viendo todo, y `docs/ux/screens.md` pide enseñarla, no esconderla.
    func testTheDropsOfTheProducerAreReported() async throws {
        let url = tempFile()
        let producer = try makeProducer(url, slotCount: 4)
        defer { producer.close() }
        let reader = makeReader(fileURL: url, wakeup: FakeLiveFeedWakeup())

        for i in 0..<10 {
            producer.push(LiveFeedFixtures.packed(timestamp: UInt64(i), direction: .outbound, length: 10))
        }
        await reader.drain()

        let snapshot = await reader.snapshot

        XCTAssertEqual(snapshot.packetCount, 4)
        XCTAssertEqual(snapshot.droppedRecords, 6)
    }

    // MARK: - Sesión

    /// `start()` empieza una sesión: re-ancla y vacía los contadores, porque el gráfico y los totales
    /// son de la sesión de túnel que arranca, y el propio ring reinicia sus índices al recrearse.
    func testStartResetsTheSessionCounters() async throws {
        let url = tempFile()
        let producer = try makeProducer(url)
        defer { producer.close() }
        let wakeup = FakeLiveFeedWakeup()
        let reader = makeReader(fileURL: url, wakeup: wakeup)

        producer.push(LiveFeedFixtures.packed(timestamp: 0, direction: .outbound, length: 100))
        await reader.drain()
        let before = await reader.snapshot
        XCTAssertEqual(before.packetCount, 1)

        await reader.stop()
        await reader.start()

        let after = await reader.snapshot
        XCTAssertEqual(after.packetCount, 0)
        XCTAssertEqual(after.bytesOut, 0)
        XCTAssertTrue(after.recent.isEmpty)
        XCTAssertTrue(after.throughput.allSatisfy { $0.bytesOut == 0 })
    }

    /// `stop()` suelta el despertador y cierra el ring; un despertar rezagado que llegue después no
    /// puede reabrirlo a espaldas de nadie.
    func testStopReleasesTheWakeupAndALateSignalDoesNotReopenTheRing() async throws {
        let url = tempFile()
        let producer = try makeProducer(url)
        defer { producer.close() }
        let wakeup = FakeLiveFeedWakeup()
        let reader = makeReader(fileURL: url, wakeup: wakeup)
        await reader.start()

        await reader.stop()
        producer.push(LiveFeedFixtures.packed(timestamp: 0, direction: .outbound, length: 100))
        wakeup.fire()
        try await Task.sleep(for: .milliseconds(50))

        let snapshot = await reader.snapshot
        XCTAssertEqual(wakeup.stopCount, 1)
        XCTAssertFalse(wakeup.isListening)
        XCTAssertFalse(snapshot.isAttached)
        XCTAssertEqual(snapshot.packetCount, 0)
    }

    /// `start()` dos veces no abre dos observadores ni reinicia una sesión ya en curso.
    func testStartIsIdempotent() async throws {
        let wakeup = FakeLiveFeedWakeup()
        let reader = makeReader(fileURL: tempFile(), wakeup: wakeup)

        await reader.start()
        await reader.start()

        XCTAssertEqual(wakeup.startCount, 1)
    }

    // MARK: - Publicación

    /// La UI no consulta al lector: lo escucha. La primera instantánea llega en el acto para que la
    /// vista no arranque en blanco, y cada cambio produce otra.
    func testTheStreamDeliversTheCurrentSnapshotAndThenEachChange() async throws {
        let url = tempFile()
        let producer = try makeProducer(url)
        defer { producer.close() }
        let reader = makeReader(fileURL: url, wakeup: FakeLiveFeedWakeup())

        let stream = await reader.snapshots()
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.packetCount, 0)

        producer.push(LiveFeedFixtures.packed(timestamp: 0, direction: .inbound, length: 1_200))
        await reader.drain()

        let updated = await iterator.next()
        XCTAssertEqual(updated?.packetCount, 1)
        XCTAssertEqual(updated?.bytesIn, 1_200)
    }

    /// Un drenaje que no encuentra nada no republica: con el reloj parado el snapshot es idéntico, y
    /// despertar a la UI con lo mismo la haría redibujar el gráfico varias veces por segundo para nada.
    func testAnEmptyDrainDoesNotRepublishTheSameSnapshot() async throws {
        let url = tempFile()
        let producer = try makeProducer(url)
        defer { producer.close() }
        let reader = makeReader(fileURL: url, wakeup: FakeLiveFeedWakeup())
        await reader.drain()   // engancha el ring antes de suscribirse

        let stream = await reader.snapshots()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()

        await reader.drain()
        await reader.drain()
        producer.push(LiveFeedFixtures.packed(timestamp: 0, direction: .outbound, length: 42))
        await reader.drain()

        // Si los drenajes vacíos hubieran publicado, este `next()` devolvería uno de ellos.
        let next = await iterator.next()
        XCTAssertEqual(next?.packetCount, 1)
        XCTAssertEqual(next?.bytesOut, 42)
    }

    // MARK: - Carga

    /// Carga sostenida: 5 000 registros por un ring que los admite, drenados en pasadas acotadas. No
    /// se pierde ni se duplica ninguno, y la lista de recientes sigue siendo la de la política.
    func testASustainedLoadIsDrainedWithoutLossOrDuplication() async throws {
        let url = tempFile()
        let producer = try makeProducer(url, slotCount: 8_192)
        defer { producer.close() }
        let policy = LiveFeedPolicy(recordsPerDrain: 128, maxDrainsPerBurst: 4, recentPacketCapacity: 100, idlePollInterval: nil)
        let reader = makeReader(fileURL: url, wakeup: FakeLiveFeedWakeup(), policy: policy)

        for i in 1...5_000 {
            producer.push(
                LiveFeedFixtures.packed(
                    timestamp: UInt64(i) * 1_000_000,
                    direction: i.isMultiple(of: 2) ? .inbound : .outbound,
                    length: 100
                )
            )
        }

        var total = 0
        while true {
            let ingested = await reader.drain()
            if ingested == 0 { break }
            total += ingested
        }

        let snapshot = await reader.snapshot
        XCTAssertEqual(total, 5_000)
        XCTAssertEqual(snapshot.packetCount, 5_000)
        XCTAssertEqual(snapshot.droppedRecords, 0)
        XCTAssertEqual(snapshot.bytesIn, 250_000)
        XCTAssertEqual(snapshot.bytesOut, 250_000)
        XCTAssertEqual(snapshot.recent.count, 100)
        XCTAssertEqual(snapshot.recent.last?.id, 5_000)
    }
}
