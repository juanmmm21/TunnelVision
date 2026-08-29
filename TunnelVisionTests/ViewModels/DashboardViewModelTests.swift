import Foundation
import XCTest
import Shared

/// Tests del view model de la Dashboard contra un `LiveFeedReader` **real** sobre un ring de fichero
/// temporal —el mismo montaje que usan los tests del lector—, porque lo que se ejercita aquí es justo
/// el acoplamiento entre los dos: quién arranca el feed, cuándo se re-engancha y qué llega a la vista.
@MainActor
final class DashboardViewModelTests: XCTestCase {

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

    /// Ancla trivial y reloj fijo: ni las fechas ni el eje del gráfico dependen de cuándo corra el test.
    private func makeReader(fileURL: URL, wakeup: FakeLiveFeedWakeup) -> LiveFeedReader {
        let epoch = self.epoch
        return LiveFeedReader(
            fileURL: fileURL,
            policy: LiveFeedPolicy(idlePollInterval: nil),
            wakeup: wakeup,
            anchorProvider: { MonotonicAnchor(uptimeNanoseconds: 0, wallClock: epoch) },
            now: { epoch }
        )
    }

    private func makeProducer(_ url: URL) throws -> RingBufferProducer {
        try RingBufferProducer(fileURL: url, slotCount: 1_024)
    }

    private func push(
        _ producer: RingBufferProducer,
        sequence: UInt64,
        direction: Direction,
        length: UInt32,
        peer: IPEndpoint = LiveFeedFixtures.remote
    ) {
        producer.push(
            LiveFeedFixtures.packed(
                timestamp: sequence * 1_000,
                direction: direction,
                length: length,
                peer: peer
            )
        )
    }

    /// Espera acotada a que el view model refleje algo, y falla si no llega. El drenaje ocurre en
    /// tareas que el test no conduce, así que se sondea en vez de dormir a ciegas.
    private func expect(
        _ viewModel: DashboardViewModel,
        timeout: Duration = .seconds(5),
        _ message: String = "el view model no llegó al estado esperado",
        file: StaticString = #filePath,
        line: UInt = #line,
        until predicate: @MainActor (DashboardViewModel) -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline, !predicate(viewModel) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(predicate(viewModel), message, file: file, line: line)
    }

    /// La misma espera contra el lector, para afirmar sobre el feed cuando la vista ya no escucha.
    private func expectReader(
        _ reader: LiveFeedReader,
        timeout: Duration = .seconds(5),
        _ message: String = "el lector no llegó al estado esperado",
        file: StaticString = #filePath,
        line: UInt = #line,
        until predicate: @Sendable (LiveFeedSnapshot) -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline, !predicate(await reader.snapshot) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let reached = predicate(await reader.snapshot)
        XCTAssertTrue(reached, message, file: file, line: line)
    }

    // MARK: - Publicación

    func testTheViewModelPublishesWhatTheReaderDrains() async throws {
        let url = tempFile()
        let producer = try makeProducer(url)
        defer { producer.close() }
        let wakeup = FakeLiveFeedWakeup()
        let reader = makeReader(fileURL: url, wakeup: wakeup)
        let viewModel = DashboardViewModel(liveFeed: reader)

        viewModel.startObserving()
        await viewModel.tunnelStateDidChange(to: .live)

        push(producer, sequence: 1, direction: .outbound, length: 100)
        push(producer, sequence: 2, direction: .inbound, length: 400)
        wakeup.fire()

        await expect(viewModel) { $0.snapshot.packetCount == 2 }
        XCTAssertEqual(viewModel.snapshot.bytesOut, 100)
        XCTAssertEqual(viewModel.snapshot.bytesIn, 400)
        XCTAssertTrue(viewModel.isAttached)
        XCTAssertFalse(viewModel.isDroppingRecords)
    }

    /// Los hosts se derivan **por instantánea**, no por repintado: SwiftUI evalúa el cuerpo de la
    /// vista muchas más veces de las que llega tráfico.
    func testTopTalkersAreDerivedFromEachSnapshotAndCapped() async throws {
        let url = tempFile()
        let producer = try makeProducer(url)
        defer { producer.close() }
        let wakeup = FakeLiveFeedWakeup()
        let reader = makeReader(fileURL: url, wakeup: wakeup)
        let viewModel = DashboardViewModel(liveFeed: reader, topTalkerLimit: 2)

        viewModel.startObserving()
        await viewModel.tunnelStateDidChange(to: .live)

        push(producer, sequence: 1, direction: .inbound, length: 900, peer: LiveFeedFixtures.remote)
        push(producer, sequence: 2, direction: .inbound, length: 500, peer: LiveFeedFixtures.lowRemote)
        push(
            producer,
            sequence: 3,
            direction: .inbound,
            length: 100,
            peer: IPEndpoint(address: IPAddress(version: .v4, bytes: [8, 8, 8, 8]), port: 53)
        )
        wakeup.fire()

        await expect(viewModel) { $0.snapshot.packetCount == 3 }
        XCTAssertEqual(viewModel.topTalkers.count, 2)
        XCTAssertEqual(
            viewModel.topTalkers.map(\.displayHost),
            [LiveFeedFixtures.remote.address.description, LiveFeedFixtures.lowRemote.address.description]
        )
    }

    // MARK: - Ciclo de vida del feed

    /// En una app recién instalada el fichero del ring **no existe** hasta que la extensión arranca:
    /// abrir el feed al ver el túnel activo es lo que hace que se enganche sin reinstalar nada.
    func testGoingLiveAttachesToARingCreatedAfterTheAppStarted() async throws {
        let url = tempFile()
        let wakeup = FakeLiveFeedWakeup()
        let reader = makeReader(fileURL: url, wakeup: wakeup)
        let viewModel = DashboardViewModel(liveFeed: reader)

        viewModel.startObserving()
        XCTAssertFalse(viewModel.isAttached)

        await viewModel.tunnelStateDidChange(to: .live)
        let producer = try makeProducer(url)
        defer { producer.close() }
        push(producer, sequence: 1, direction: .outbound, length: 250)
        wakeup.fire()

        await expect(viewModel) { $0.isAttached && $0.snapshot.packetCount == 1 }
    }

    /// La extensión recrea el fichero del ring en cada sesión: sin re-enganchar, el mapeo de la sesión
    /// anterior seguiría vivo y mudo, sin dar un solo error y sin ver un solo registro nuevo.
    func testGoingLiveAgainReattachesToARecreatedRing() async throws {
        let url = tempFile()
        let wakeup = FakeLiveFeedWakeup()
        let reader = makeReader(fileURL: url, wakeup: wakeup)
        let viewModel = DashboardViewModel(liveFeed: reader)

        viewModel.startObserving()
        await viewModel.tunnelStateDidChange(to: .live)

        let first = try makeProducer(url)
        push(first, sequence: 1, direction: .outbound, length: 100)
        wakeup.fire()
        await expect(viewModel) { $0.snapshot.packetCount == 1 }

        await viewModel.tunnelStateDidChange(to: .off)
        first.close()

        // Sesión nueva de la extensión: el productor recrea el fichero desde cero.
        let second = try makeProducer(url)
        defer { second.close() }
        push(second, sequence: 2, direction: .inbound, length: 700)

        await viewModel.tunnelStateDidChange(to: .live)

        await expect(viewModel) { $0.snapshot.packetCount == 1 && $0.snapshot.bytesIn == 700 }
        // Sesión nueva: los contadores son de esta sesión, no acumulados de la anterior.
        XCTAssertEqual(viewModel.snapshot.bytesOut, 0)
        XCTAssertTrue(viewModel.isAttached)
    }

    /// El sistema puede matar y levantar la extensión **sin** que el estado del túnel deje de ser
    /// `connected`, y entonces nadie dispara el re-enganche por cambio de estado: el mapeo se queda
    /// mirando un fichero muerto y el feed se congela sin dar un solo error. Volver a primer plano es
    /// donde se recupera, y es también cuando el usuario vuelve a mirar la pantalla.
    func testComingBackToTheForegroundReattachesARingRecreatedWhileAway() async throws {
        let url = tempFile()
        let wakeup = FakeLiveFeedWakeup()
        let reader = makeReader(fileURL: url, wakeup: wakeup)
        let viewModel = DashboardViewModel(liveFeed: reader)

        viewModel.startObserving()
        await viewModel.tunnelStateDidChange(to: .live)

        let first = try makeProducer(url)
        push(first, sequence: 1, direction: .outbound, length: 100)
        wakeup.fire()
        await expect(viewModel) { $0.snapshot.packetCount == 1 }

        // La extensión muere y vuelve mientras la app está en segundo plano: el productor recrea el
        // fichero y el túnel nunca deja de estar `live`, así que `tunnelStateDidChange` no llega.
        first.close()
        let second = try makeProducer(url)
        defer { second.close() }
        push(second, sequence: 2, direction: .inbound, length: 700)

        await viewModel.sceneDidBecomeActive()

        await expect(viewModel) { $0.snapshot.bytesIn == 700 }
        XCTAssertTrue(viewModel.isAttached)
    }

    /// Volver a primer plano con el túnel parado no engancha nada. Sin esta guarda, abrir la app sobre
    /// una sesión que no existe mapearía el ring de la anterior y la pantalla enseñaría como "ahora
    /// mismo" el tráfico de la última vez.
    func testComingBackToTheForegroundDoesNothingWhenTheFeedIsNotLive() async throws {
        let url = tempFile()
        let producer = try makeProducer(url)
        defer { producer.close() }
        let wakeup = FakeLiveFeedWakeup()
        let reader = makeReader(fileURL: url, wakeup: wakeup)
        let viewModel = DashboardViewModel(liveFeed: reader)

        viewModel.startObserving()
        push(producer, sequence: 1, direction: .outbound, length: 100)

        await viewModel.sceneDidBecomeActive()

        XCTAssertFalse(viewModel.isAttached)
        XCTAssertEqual(viewModel.snapshot.packetCount, 0)
    }

    /// `reasserting` (que el controlador mapea a `starting`) ocurre **dentro** de una sesión viva al
    /// cambiar de red. Parar ahí vaciaría los contadores y el gráfico de una sesión que nunca terminó,
    /// y el usuario vería su tráfico acumulado desaparecer al pasar de Wi-Fi a datos.
    func testATransitionDoesNotStopALiveFeed() async throws {
        let url = tempFile()
        let producer = try makeProducer(url)
        defer { producer.close() }
        let wakeup = FakeLiveFeedWakeup()
        let reader = makeReader(fileURL: url, wakeup: wakeup)
        let viewModel = DashboardViewModel(liveFeed: reader)

        viewModel.startObserving()
        await viewModel.tunnelStateDidChange(to: .live)
        push(producer, sequence: 1, direction: .outbound, length: 100)
        wakeup.fire()
        await expect(viewModel) { $0.snapshot.packetCount == 1 }

        await viewModel.tunnelStateDidChange(to: .starting)
        push(producer, sequence: 2, direction: .outbound, length: 300)
        wakeup.fire()

        await expect(viewModel) { $0.snapshot.packetCount == 2 }
        XCTAssertEqual(viewModel.snapshot.bytesOut, 400)
        XCTAssertTrue(wakeup.isListening)
    }

    /// Volver a `live` tras un `reasserting` es la **misma** sesión reconfirmada: se re-engancha por si
    /// la extensión recreó el ring, pero no se vacían los contadores ni el gráfico.
    func testComingBackToLiveWithinTheSameSessionKeepsTheCounters() async throws {
        let url = tempFile()
        let producer = try makeProducer(url)
        defer { producer.close() }
        let wakeup = FakeLiveFeedWakeup()
        let reader = makeReader(fileURL: url, wakeup: wakeup)
        let viewModel = DashboardViewModel(liveFeed: reader)

        viewModel.startObserving()
        await viewModel.tunnelStateDidChange(to: .live)
        push(producer, sequence: 1, direction: .outbound, length: 100)
        wakeup.fire()
        await expect(viewModel) { $0.snapshot.packetCount == 1 }

        await viewModel.tunnelStateDidChange(to: .starting)
        await viewModel.tunnelStateDidChange(to: .live)
        push(producer, sequence: 2, direction: .outbound, length: 300)
        wakeup.fire()

        await expect(viewModel) { $0.snapshot.packetCount == 2 }
        XCTAssertEqual(viewModel.snapshot.bytesOut, 400)
    }

    func testTurningMonitoringOffStopsTheFeed() async throws {
        let url = tempFile()
        let producer = try makeProducer(url)
        defer { producer.close() }
        let wakeup = FakeLiveFeedWakeup()
        let reader = makeReader(fileURL: url, wakeup: wakeup)
        let viewModel = DashboardViewModel(liveFeed: reader)

        viewModel.startObserving()
        await viewModel.tunnelStateDidChange(to: .live)
        push(producer, sequence: 1, direction: .outbound, length: 100)
        wakeup.fire()
        await expect(viewModel) { $0.snapshot.packetCount == 1 }

        await viewModel.tunnelStateDidChange(to: .off)

        await expect(viewModel) { !$0.isAttached }
        XCTAssertFalse(wakeup.isListening)
    }

    /// Un fallo deja el túnel parado, así que el feed también: mantenerlo abierto pintaría una
    /// pantalla que parece viva sobre un túnel que no lo está.
    func testAFailedTunnelStopsTheFeed() async throws {
        let url = tempFile()
        let producer = try makeProducer(url)
        defer { producer.close() }
        let wakeup = FakeLiveFeedWakeup()
        let reader = makeReader(fileURL: url, wakeup: wakeup)
        let viewModel = DashboardViewModel(liveFeed: reader)

        viewModel.startObserving()
        await viewModel.tunnelStateDidChange(to: .live)
        XCTAssertTrue(wakeup.isListening)

        await viewModel.tunnelStateDidChange(to: .failed(.permissionDenied))

        XCTAssertFalse(wakeup.isListening)
        await expect(viewModel) { !$0.isAttached }
    }

    // MARK: - Suscripción

    /// Dejar de mirar la pantalla no para la monitorización: el feed sigue drenando el ring mientras
    /// el túnel viva, y lo único que se corta es la publicación hacia esta vista.
    func testStopObservingStopsTheUpdatesButNotTheFeed() async throws {
        let url = tempFile()
        let producer = try makeProducer(url)
        defer { producer.close() }
        let wakeup = FakeLiveFeedWakeup()
        let reader = makeReader(fileURL: url, wakeup: wakeup)
        let viewModel = DashboardViewModel(liveFeed: reader)

        viewModel.startObserving()
        await viewModel.tunnelStateDidChange(to: .live)
        push(producer, sequence: 1, direction: .outbound, length: 100)
        wakeup.fire()
        await expect(viewModel) { $0.snapshot.packetCount == 1 }

        viewModel.stopObserving()
        push(producer, sequence: 2, direction: .outbound, length: 300)
        wakeup.fire()

        await expectReader(reader) { $0.packetCount == 2 }
        XCTAssertEqual(viewModel.snapshot.packetCount, 1, "la vista no debería seguir recibiendo")
        XCTAssertTrue(wakeup.isListening, "el feed sigue vivo")
    }

    /// La vista llama a `startObserving()` en cada aparición: dos llamadas no pueden dejar dos
    /// suscripciones vivas, porque entonces `stopObserving()` solo cerraría una.
    func testObservingTwiceKeepsASingleSubscription() async throws {
        let url = tempFile()
        let producer = try makeProducer(url)
        defer { producer.close() }
        let wakeup = FakeLiveFeedWakeup()
        let reader = makeReader(fileURL: url, wakeup: wakeup)
        let viewModel = DashboardViewModel(liveFeed: reader)

        viewModel.startObserving()
        viewModel.startObserving()
        await viewModel.tunnelStateDidChange(to: .live)
        push(producer, sequence: 1, direction: .outbound, length: 100)
        wakeup.fire()
        await expect(viewModel) { $0.snapshot.packetCount == 1 }

        viewModel.stopObserving()
        push(producer, sequence: 2, direction: .outbound, length: 300)
        wakeup.fire()

        await expectReader(reader) { $0.packetCount == 2 }
        XCTAssertEqual(viewModel.snapshot.packetCount, 1)
    }

    // MARK: - Derivados

    func testTheCurrentRatesComeFromTheNewestBucket() async throws {
        let url = tempFile()
        let producer = try makeProducer(url)
        defer { producer.close() }
        let wakeup = FakeLiveFeedWakeup()
        let reader = makeReader(fileURL: url, wakeup: wakeup)
        let viewModel = DashboardViewModel(liveFeed: reader)

        viewModel.startObserving()
        await viewModel.tunnelStateDidChange(to: .live)
        // El reloj del lector está fijo en `epoch` y el ancla es trivial, así que un sello de 0 ns cae
        // en la barra más nueva de la ventana.
        push(producer, sequence: 0, direction: .inbound, length: 2_000)
        wakeup.fire()

        await expect(viewModel) { $0.snapshot.packetCount == 1 }
        XCTAssertEqual(viewModel.currentRateIn, 2_000, accuracy: 0.001)
        XCTAssertEqual(viewModel.currentRateOut, 0, accuracy: 0.001)
    }

    /// La única señal de que el feed no lo está viendo todo. Se enseña solo si de verdad se perdió
    /// algo, así que el view model la deriva del contador del ring, no de una heurística.
    func testDroppedRecordsSurfaceAsTheBackPressureSignal() async throws {
        let url = tempFile()
        // Ring diminuto: se desborda a propósito para que la extensión tenga que descartar.
        let producer = try RingBufferProducer(fileURL: url, slotCount: 2)
        defer { producer.close() }
        let wakeup = FakeLiveFeedWakeup()
        let reader = makeReader(fileURL: url, wakeup: wakeup)
        let viewModel = DashboardViewModel(liveFeed: reader)

        viewModel.startObserving()
        await viewModel.tunnelStateDidChange(to: .live)
        for sequence in 0..<6 {
            push(producer, sequence: UInt64(sequence), direction: .outbound, length: 100)
        }
        wakeup.fire()

        await expect(viewModel) { $0.isDroppingRecords }
        XCTAssertEqual(viewModel.snapshot.droppedRecords, 4)
    }

    // MARK: - La petición de encender que llega del intro (M10)

    func testThereIsNoPendingStartRequestUntilSomebodyAsks() throws {
        let viewModel = DashboardViewModel(liveFeed: makeReader(fileURL: tempFile(), wakeup: FakeLiveFeedWakeup()))
        XCTAssertFalse(viewModel.hasPendingStartRequest)

        viewModel.requestStart()
        XCTAssertTrue(viewModel.hasPendingStartRequest)
    }

    /// La pantalla la marca atendida al recogerla. Sin esto, volver a esta pestaña la atendería otra
    /// vez, y quien paró la monitorización a mano se la vería arrancar sola al pasar por aquí.
    func testAnAnsweredRequestDoesNotStayPending() throws {
        let viewModel = DashboardViewModel(liveFeed: makeReader(fileURL: tempFile(), wakeup: FakeLiveFeedWakeup()))

        viewModel.requestStart()
        viewModel.startRequestHandled()

        XCTAssertFalse(viewModel.hasPendingStartRequest)
    }
}
