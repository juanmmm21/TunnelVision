import Foundation
import XCTest
@testable import Shared

/// Tests del view model de la Timeline contra un `HistoryReader` **real** sobre un `FlowStore` real
/// en BD temporal —el mismo montaje que usan los tests del lector—, porque lo que se ejercita aquí es
/// el acoplamiento entre los dos: cuándo se abre el historial, qué filtro se le pasa y qué acaba
/// viendo la vista.
@MainActor
final class TimelineViewModelTests: XCTestCase {

    /// Ancla del store: fija las fechas de las filas para que los rangos temporales sean afirmables.
    private let epoch = HistoryFixtures.anchorWallClock

    // MARK: - Utilidades

    private func makeDatabaseURL() -> URL {
        let url = PersistenceFixtures.temporaryDatabaseURL()
        addTeardownBlock { PersistenceFixtures.removeDatabase(at: url) }
        return url
    }

    private func makeStore(_ url: URL) throws -> FlowStore {
        try FlowStore(databaseURL: url, anchor: HistoryFixtures.anchor)
    }

    /// El view model sobre un lector ya construido. El calendario va en UTC por lo mismo que en los
    /// tests de presentación: `today` depende del huso del que ejecuta.
    private func makeViewModel(
        reader: HistoryReader,
        now: @escaping @Sendable () -> Date
    ) -> TimelineViewModel {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return TimelineViewModel(makeReader: { reader }, now: now, calendar: calendar)
    }

    private func makeViewModel(
        _ store: FlowStore,
        policy: HistoryPolicy = .default,
        now: Date? = nil
    ) -> TimelineViewModel {
        let instant = now ?? epoch
        return makeViewModel(
            reader: HistoryReader(store: store, policy: policy),
            now: { instant }
        )
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

    /// Espera acotada a que la vista refleje algo: la instantánea llega por un `AsyncStream` que el
    /// test no conduce, así que se sondea en vez de dormir a ciegas.
    private func expect(
        _ viewModel: TimelineViewModel,
        timeout: Duration = .seconds(5),
        _ message: String = "el view model no llegó al estado esperado",
        file: StaticString = #filePath,
        line: UInt = #line,
        until predicate: @MainActor (TimelineViewModel) -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline, !predicate(viewModel) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(predicate(viewModel), message, file: file, line: line)
    }

    private func start(_ viewModel: TimelineViewModel) async {
        await viewModel.startObserving()
        await viewModel.refresh()
    }

    /// Espera a que la carga **termine**: una lista vacía a mitad de una recarga no significa lo mismo
    /// que una lista vacía ya cargada, y afirmar sobre la primera es medir una instantánea de paso.
    private func expectSettled(
        _ viewModel: TimelineViewModel,
        file: StaticString = #filePath,
        line: UInt = #line,
        until predicate: @escaping @MainActor (TimelineViewModel) -> Bool
    ) async {
        await expect(viewModel, file: file, line: line) {
            $0.snapshot.state == .loaded && predicate($0)
        }
    }

    // MARK: - Carga

    func testAppearingLoadsTheHistoryNewestFirst() async throws {
        let store = try makeStore(makeDatabaseURL())
        for index in 0..<3 {
            try await write(to: store, index: index, lastSeen: UInt64(index) * 10)
        }
        let viewModel = makeViewModel(store)

        await start(viewModel)
        await expect(viewModel) { $0.flows.count == 3 }

        XCTAssertEqual(viewModel.content, .list)
        XCTAssertEqual(
            viewModel.flows.map(\.lastSeen),
            viewModel.flows.map(\.lastSeen).sorted(by: >),
            "el historial se lee del más reciente al más antiguo"
        )
    }

    /// Sin esto la pantalla se quedaría en blanco: el lector arranca con el filtro vacío, así que
    /// aplicarle el mismo filtro no recarga nada y hay que pedirle un `refresh` de verdad.
    func testTheFirstLoadHappensEvenThoughTheFilterDidNotChange() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await write(to: store, index: 0, lastSeen: 10)
        let viewModel = makeViewModel(store)

        XCTAssertEqual(viewModel.content, .loading)
        await start(viewModel)
        await expect(viewModel) { $0.flows.count == 1 }
    }

    func testPagesAreAddedWithoutRepeatingRows() async throws {
        let store = try makeStore(makeDatabaseURL())
        for index in 0..<5 {
            try await write(to: store, index: index, lastSeen: UInt64(index) * 10)
        }
        let viewModel = makeViewModel(store, policy: HistoryPolicy(pageSize: 2, maxPagesPerLoad: 1))

        await start(viewModel)
        await expect(viewModel) { $0.flows.count == 2 }
        XCTAssertEqual(viewModel.footer, .loadMore, "quedando historial, el pie es lo que lo pide")

        await viewModel.loadMore()
        await expect(viewModel) { $0.flows.count == 4 }
        await viewModel.loadMore()
        await expect(viewModel) { $0.flows.count == 5 }

        XCTAssertEqual(Set(viewModel.flows.map(\.id)).count, 5, "sin filas repetidas")
        await expect(viewModel) { $0.footer == .endOfHistory }
    }

    func testAnEmptyHistoryTeachesInsteadOfLookingBroken() async throws {
        let viewModel = makeViewModel(try makeStore(makeDatabaseURL()))

        await start(viewModel)
        await expect(viewModel) { $0.content != .loading }

        guard case .placeholder(let placeholder) = viewModel.content else {
            return XCTFail("un historial vacío tiene que explicarse")
        }
        XCTAssertNil(placeholder.action)
        XCTAssertEqual(viewModel.footer, .none)
    }

    // MARK: - Apertura del historial

    /// El fallo al abrir la BD no puede tumbar la app —la Dashboard no necesita el historial—, así
    /// que se convierte en un estado de esta pantalla.
    func testAHistoryThatCannotBeOpenedFailsOnlyThisScreen() async {
        let viewModel = TimelineViewModel(
            makeReader: { throw FlowStore.StoreError.appGroupUnavailable },
            now: { Date() }
        )

        await start(viewModel)

        guard case .placeholder(let placeholder) = viewModel.content else {
            return XCTFail("el fallo de apertura tiene que enseñarse")
        }
        XCTAssertEqual(placeholder.action, .retry)
        XCTAssertNotNil(placeholder.diagnostic)
    }

    /// Y "Try again" tiene que **volver a abrir**, no repetir un error cacheado: si el contenedor
    /// pasa a estar disponible, el usuario sale del error sin reinstalar la app.
    func testTryingAgainReopensTheHistoryForReal() async throws {
        let url = makeDatabaseURL()
        let store = try makeStore(url)
        try await write(to: store, index: 0, lastSeen: 10)

        // Dos fallos, no uno: aparecer la pantalla intenta abrir dos veces —al suscribirse y al
        // cargar—, así que con un solo fallo el "reintento" ya habría ocurrido solo.
        let gate = OpenGate(failuresLeft: 2)
        let viewModel = TimelineViewModel(
            makeReader: {
                try await gate.check()
                return HistoryReader(store: store)
            },
            now: { HistoryFixtures.anchorWallClock }
        )

        await start(viewModel)
        guard case .placeholder = viewModel.content else {
            return XCTFail("el primer intento tenía que fallar")
        }

        // Sin volver a suscribirse a mano: la apertura que funciona tiene que dejar la pantalla
        // escuchando, o el usuario vería el error para siempre sobre un historial ya cargado.
        await viewModel.perform(.retry)
        await expect(viewModel) { $0.flows.count == 1 }

        let attempts = await gate.attempts
        XCTAssertEqual(attempts, 3, "el reintento abrió de verdad y no repitió un error cacheado")
    }

    // MARK: - Búsqueda

    /// Escribir no recarga: cada carga barre páginas del store y las descarta en memoria, así que
    /// hacerlo por tecla gastaría lecturas para enseñar listas que nadie mira.
    func testTypingDoesNotFilterUntilTheSearchIsSubmitted() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await write(to: store, index: 0, lastSeen: 10, sni: "example.com")
        try await write(to: store, index: 1, lastSeen: 20, sni: "cdn.other.net")
        let viewModel = makeViewModel(store)

        await start(viewModel)
        await expect(viewModel) { $0.flows.count == 2 }

        viewModel.searchText = "example"
        XCTAssertEqual(viewModel.flows.count, 2, "todavía no se ha pedido buscar")
        XCTAssertTrue(viewModel.hasActiveFilters, "pero el botón de limpiar ya tiene sentido")

        await viewModel.submitSearch()
        await expect(viewModel) { $0.flows.count == 1 }
        XCTAssertEqual(viewModel.flows.first?.displayHost, "example.com")
    }

    /// El vacío con filtro ofrece limpiarlo, y limpiarlo devuelve la lista entera **y** vacía la
    /// barra: dejar el texto puesto sobre una lista sin filtrar sería enseñar dos cosas distintas.
    func testClearingTheFiltersFromTheEmptyStateBringsTheListBack() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await write(to: store, index: 0, lastSeen: 10, sni: "example.com")
        let viewModel = makeViewModel(store)

        await start(viewModel)
        await expect(viewModel) { $0.flows.count == 1 }

        viewModel.searchText = "nothing-matches-this"
        await viewModel.submitSearch()
        await expectSettled(viewModel) { $0.flows.isEmpty }

        guard case .placeholder(let placeholder) = viewModel.content,
              let action = placeholder.action
        else {
            return XCTFail("un filtro sin resultados tiene que ofrecer salida")
        }
        XCTAssertEqual(action, .clearFilters)

        await viewModel.perform(action)
        await expect(viewModel) { $0.flows.count == 1 }
        XCTAssertTrue(viewModel.searchText.isEmpty)
        XCTAssertFalse(viewModel.hasActiveFilters)
    }

    // MARK: - Filtros del menú

    func testTogglingAProtocolFiltersAndTogglingItBackRestores() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await write(to: store, index: 0, lastSeen: 10, proto: .tcp)
        try await write(to: store, index: 1, lastSeen: 20, proto: .udp)
        let viewModel = makeViewModel(store)

        await start(viewModel)
        await expect(viewModel) { $0.flows.count == 2 }

        await viewModel.toggleProtocol(.udp)
        await expect(viewModel) { $0.flows.count == 1 }
        XCTAssertEqual(viewModel.flows.first?.proto, .udp)

        await viewModel.toggleProtocol(.udp)
        await expect(viewModel) { $0.flows.count == 2 }
        XCTAssertFalse(viewModel.hasActiveFilters)
    }

    /// La casilla "Other" existe para que ningún protocolo se quede sin filtro posible.
    func testTheOtherProtocolOptionReachesIcmp() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await write(to: store, index: 0, lastSeen: 10, proto: .tcp)
        try await write(to: store, index: 1, lastSeen: 20, proto: .icmp)
        let viewModel = makeViewModel(store)

        await start(viewModel)
        await expect(viewModel) { $0.flows.count == 2 }

        await viewModel.toggleProtocol(.other)
        await expect(viewModel) { $0.flows.count == 1 }
        XCTAssertEqual(viewModel.flows.first?.proto, .icmp)
    }

    func testTogglingATLSStatusFiltersTheList() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await write(to: store, index: 0, lastSeen: 10, tlsStatus: .encrypted)
        try await write(to: store, index: 1, lastSeen: 20, tlsStatus: .notInspectable)
        let viewModel = makeViewModel(store)

        await start(viewModel)
        await expect(viewModel) { $0.flows.count == 2 }

        await viewModel.toggleTLSStatus(.notInspectable)
        await expect(viewModel) { $0.flows.count == 1 }
        XCTAssertEqual(viewModel.flows.first?.tlsStatus, .notInspectable)
    }

    // MARK: - Rango temporal

    /// El rango relativo se recalcula en cada recarga: "última hora" tiene que significar la hora
    /// anterior a *ahora*, no la anterior al momento en que se marcó la opción.
    func testARelativeRangeIsRecomputedOnEveryRefresh() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await write(to: store, index: 0, firstSeen: 0, lastSeen: 10)

        // Reloj movible: el primer refresco cae dentro de la hora del flujo y el segundo, muy lejos.
        let clock = MovableClock(instant: epoch.addingTimeInterval(30))
        let viewModel = makeViewModel(reader: HistoryReader(store: store), now: { clock.instant })

        await start(viewModel)
        await expect(viewModel) { $0.flows.count == 1 }

        await viewModel.setTimeRange(.lastHour)
        await expect(viewModel) { $0.flows.count == 1 }

        clock.instant = self.epoch.addingTimeInterval(7_200)
        await viewModel.refresh()
        await expectSettled(viewModel) { $0.flows.isEmpty }
        XCTAssertTrue(viewModel.hasActiveFilters)
    }

    func testAnyTimeDoesNotFilterAnything() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await write(to: store, index: 0, lastSeen: 10)
        let viewModel = makeViewModel(store, now: epoch.addingTimeInterval(100_000))

        await start(viewModel)
        await expect(viewModel) { $0.flows.count == 1 }
        XCTAssertFalse(viewModel.hasActiveFilters, "sin rango puesto no hay filtro que enseñar")
    }

    // MARK: - Barra de scrub

    /// Escribe un flujo con sus paquetes: el eje cuenta paquetes, así que sin ellos no hay barra.
    private func writePackets(
        to store: FlowStore, index: Int, at seconds: [UInt64]
    ) async throws {
        let remote = ModelFixtures.v4(93, 184, UInt8(index / 256), UInt8(index % 256))
        let flowID = try await store.upsertFlow(
            HistoryFixtures.record(
                remote: remote, firstSeen: seconds.min() ?? 0, lastSeen: seconds.max() ?? 0
            )
        )
        try await store.appendPackets(
            seconds.map { HistoryFixtures.packet(timestamp: $0, key: HistoryFixtures.key(remote: remote)) },
            flowID: flowID
        )
    }

    /// Sin historial no hay barra que dibujar: un eje a cero se leería como "en todo este rato no
    /// hubo tráfico", que no es lo mismo que "todavía no hay nada guardado".
    func testWithoutHistoryThereIsNoScrubBar() async throws {
        let store = try makeStore(makeDatabaseURL())
        let viewModel = makeViewModel(store)

        await start(viewModel)
        await expectSettled(viewModel) { $0.flows.isEmpty }
        XCTAssertEqual(viewModel.scrub, .hidden)
    }

    func testRefreshingLoadsTheAxis() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await writePackets(to: store, index: 0, at: [0, 1, 30])
        let viewModel = makeViewModel(store)

        await start(viewModel)
        await expect(viewModel) { !$0.axis.isEmpty }

        XCTAssertEqual(viewModel.axis.totalPackets, 3)
        XCTAssertEqual(viewModel.scrub, .axis(viewModel.axis))
    }

    /// Lo que mide la pantalla llega al eje: menos ancho, menos tramos, porque cada uno se toca con el
    /// dedo. Es lo que impide que la resolución del eje vuelva a ser un número escrito a mano.
    func testANarrowScreenAsksForFewerIntervals() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await writePackets(to: store, index: 0, at: [0, 900, 1_800, 2_700, 3_600])
        let viewModel = makeViewModel(store, policy: HistoryPolicy(axisBars: 48))

        await start(viewModel)
        await expect(viewModel) { !$0.axis.isEmpty }
        let wide = viewModel.axis.bars.count

        await viewModel.setScreenWidth(ScrubCapacity.horizontalBudget + 5 * TouchTarget.minimum)
        await expect(viewModel) { $0.axis.bars.count < wide }

        XCTAssertLessThanOrEqual(viewModel.axis.bars.count, 5)
        XCTAssertEqual(viewModel.axis.totalPackets, 5, "agrupar no pierde paquetes")
    }

    /// Una anchura que no dice nada —una pantalla que todavía no se ha medido— deja el eje como estaba
    /// en vez de rehacerlo con un tramo único.
    func testAnUnmeasuredWidthLeavesTheAxisAlone() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await writePackets(to: store, index: 0, at: [0, 900, 1_800])
        let viewModel = makeViewModel(store, policy: HistoryPolicy(axisBars: 48))

        await start(viewModel)
        await expect(viewModel) { !$0.axis.isEmpty }
        let before = viewModel.axis

        await viewModel.setScreenWidth(0)
        XCTAssertEqual(viewModel.axis, before)
    }

    /// El eje se vuelve a pedir en cada recarga porque el historial crece por debajo; lo que **no**
    /// lo mueve es un filtro, que es lo que el aviso de la barra dice.
    func testTheAxisFollowsNewTrafficAndNotTheFilter() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await writePackets(to: store, index: 0, at: [0, 1])
        let viewModel = makeViewModel(store)

        await start(viewModel)
        await expect(viewModel) { $0.axis.totalPackets == 2 }

        try await writePackets(to: store, index: 1, at: [2, 3])
        await viewModel.toggleProtocol(.udp)          // filtra la lista a cero…
        await expectSettled(viewModel) { $0.flows.isEmpty }
        XCTAssertEqual(viewModel.axis.totalPackets, 2, "un filtro no vuelve a pedir el eje")

        await viewModel.refresh()
        await expect(viewModel) { $0.axis.totalPackets == 4 }
    }

    /// Lo que hace útil la barra: al tocar un tramo, la lista pasa a enseñar solo sus conexiones.
    func testSelectingAnIntervalFiltersTheListToIt() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await writePackets(to: store, index: 0, at: [0])
        try await writePackets(to: store, index: 1, at: [3_600])
        let viewModel = makeViewModel(store)

        await start(viewModel)
        await expectSettled(viewModel) { $0.flows.count == 2 }
        let first = try XCTUnwrap(viewModel.axis.bars.first)

        await viewModel.selectInterval(first)
        await expectSettled(viewModel) { $0.flows.count == 1 }
        XCTAssertEqual(viewModel.selectedInterval, first.range)
        XCTAssertNil(viewModel.timeRange, "con un tramo puesto no hay preset marcado")
        XCTAssertTrue(viewModel.hasActiveFilters)
    }

    /// La razón de ser de `TimelineDateFilter`: el tramo es absoluto, así que una recarga con el
    /// reloj mucho más tarde sigue enseñando el mismo trozo del pasado. Si se recalculase como un
    /// preset, la selección se movería sola bajo el dedo.
    func testASelectedIntervalIsNeverRecomputed() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await writePackets(to: store, index: 0, at: [0, 10])
        let clock = MovableClock(instant: epoch.addingTimeInterval(30))
        let viewModel = makeViewModel(reader: HistoryReader(store: store), now: { clock.instant })

        await start(viewModel)
        await expect(viewModel) { !$0.axis.isEmpty }
        let bar = try XCTUnwrap(viewModel.axis.bars.first)
        await viewModel.selectInterval(bar)
        await expectSettled(viewModel) { $0.flows.count == 1 }

        clock.instant = self.epoch.addingTimeInterval(100_000)
        await viewModel.refresh()
        await expectSettled(viewModel) { $0.flows.count == 1 }
        XCTAssertEqual(viewModel.selectedInterval, bar.range, "el tramo elegido no se recalcula")
    }

    /// Volver a tocar el mismo tramo lo suelta, que es lo que el gesto sugiere; `clearInterval` hace
    /// lo mismo sin tocar el resto de filtros.
    func testTappingTheSameIntervalAgainReleasesIt() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await writePackets(to: store, index: 0, at: [0])
        try await writePackets(to: store, index: 1, at: [3_600])
        let viewModel = makeViewModel(store)

        await start(viewModel)
        await expectSettled(viewModel) { $0.flows.count == 2 }
        let bar = try XCTUnwrap(viewModel.axis.bars.first)

        await viewModel.selectInterval(bar)
        await expectSettled(viewModel) { $0.flows.count == 1 }

        await viewModel.selectInterval(bar)
        await expectSettled(viewModel) { $0.flows.count == 2 }
        XCTAssertNil(viewModel.selectedInterval)
        XCTAssertEqual(viewModel.timeRange, .anyTime)
    }

    func testClearingTheIntervalKeepsTheOtherFilters() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await writePackets(to: store, index: 0, at: [0])
        let viewModel = makeViewModel(store)

        await start(viewModel)
        await expect(viewModel) { !$0.axis.isEmpty }
        viewModel.searchText = "nothing-matches-this"
        await viewModel.submitSearch()

        let bar = try XCTUnwrap(viewModel.axis.bars.first)
        await viewModel.selectInterval(bar)
        await viewModel.clearInterval()
        await expectSettled(viewModel) { $0.flows.isEmpty }

        XCTAssertNil(viewModel.selectedInterval)
        XCTAssertEqual(viewModel.searchText, "nothing-matches-this", "soltar el tramo no borra la búsqueda")
    }

    /// Un preset del menú y un tramo de la barra son el mismo criterio: elegir uno suelta el otro.
    func testAPresetReplacesTheSelectedInterval() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await writePackets(to: store, index: 0, at: [0])
        let viewModel = makeViewModel(store)

        await start(viewModel)
        await expect(viewModel) { !$0.axis.isEmpty }
        await viewModel.selectInterval(try XCTUnwrap(viewModel.axis.bars.first))
        await viewModel.setTimeRange(.lastHour)

        XCTAssertNil(viewModel.selectedInterval)
        XCTAssertEqual(viewModel.timeRange, .lastHour)
    }

    /// Quitar todos los filtros también suelta el tramo: es la salida que ofrece el vacío "no
    /// matches", y dejar la lista acotada por la barra la haría inútil.
    func testClearingEveryFilterAlsoReleasesTheInterval() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await writePackets(to: store, index: 0, at: [0])
        try await writePackets(to: store, index: 1, at: [3_600])
        let viewModel = makeViewModel(store)

        await start(viewModel)
        await expectSettled(viewModel) { $0.flows.count == 2 }
        await viewModel.selectInterval(try XCTUnwrap(viewModel.axis.bars.first))
        await expectSettled(viewModel) { $0.flows.count == 1 }

        await viewModel.clearFilters()
        await expectSettled(viewModel) { $0.flows.count == 2 }
        XCTAssertNil(viewModel.selectedInterval)
        XCTAssertFalse(viewModel.hasActiveFilters)
    }

    // MARK: - Acercarse a un tramo

    /// Lo que hace que la barra sirva con semanas guardadas: tocar un tramo con contenido acota la
    /// lista **y** baja el eje a él, con barras más finas de las que había.
    func testEnteringAStretchRedrawsTheAxisInsideIt() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await writePackets(to: store, index: 0, at: [0, 1])
        try await writePackets(to: store, index: 1, at: [3_600])
        let viewModel = makeViewModel(store)

        await start(viewModel)
        await expectSettled(viewModel) { $0.flows.count == 2 }
        let hour = try XCTUnwrap(viewModel.axis.bars.first)
        XCTAssertEqual(hour.duration, 300, "el eje entero se dibuja en tramos de 5 min")

        await viewModel.selectInterval(hour)
        await expectSettled(viewModel) { $0.flows.count == 1 }

        XCTAssertEqual(viewModel.viewingInterval, hour.range)
        XCTAssertEqual(viewModel.selectedInterval, hour.range, "lo dibujado es lo que acota la lista")
        XCTAssertNil(viewModel.highlightedInterval, "resaltarlo pintaría el eje entero")
        XCTAssertEqual(viewModel.axis.bars.first?.duration, 15, "el eje baja de resolución")
        XCTAssertEqual(viewModel.axis.totalPackets, 2, "y solo cuenta lo del tramo")
        XCTAssertTrue(viewModel.zoom.isZoomed)
        XCTAssertFalse(viewModel.zoom.offersFullReset, "con un nivel, 'atrás' ya sale del todo")
    }

    /// Donde ya no se puede bajar más, el toque hace lo de siempre: acotar la lista y quedarse
    /// señalado dentro del eje, que sigue siendo el mismo.
    func testAStretchThatCannotBeEnteredOnlyFiltersAndStaysHighlighted() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await writePackets(to: store, index: 0, at: [0])
        try await writePackets(to: store, index: 1, at: [10])
        let viewModel = makeViewModel(store)

        await start(viewModel)
        await expectSettled(viewModel) { $0.flows.count == 2 }
        let second = try XCTUnwrap(viewModel.axis.bars.first)
        XCTAssertEqual(second.duration, 1, "10 s se dibujan en el escalón más fino")

        await viewModel.selectInterval(second)
        await expectSettled(viewModel) { $0.flows.count == 1 }

        XCTAssertNil(viewModel.viewingInterval, "no se ha bajado a ningún sitio")
        XCTAssertEqual(viewModel.highlightedInterval, second.range)
        XCTAssertEqual(viewModel.axis.bars.count, 11, "el eje no se ha movido")
    }

    /// La salida es simétrica con la entrada: se sube nivel a nivel y la lista se acota a lo mismo que
    /// el eje pasa a enseñar, que es la respuesta a "¿dónde estoy?".
    func testGoingBackWalksUpOneLevelAndTakesTheListWithIt() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await writePackets(to: store, index: 0, at: [0, 1])
        try await writePackets(to: store, index: 1, at: [3_600])
        let viewModel = makeViewModel(store)

        await start(viewModel)
        await expectSettled(viewModel) { $0.flows.count == 2 }
        let hour = try XCTUnwrap(viewModel.axis.bars.first)
        await viewModel.selectInterval(hour)
        await expectSettled(viewModel) { $0.flows.count == 1 }

        let inside = try XCTUnwrap(viewModel.axis.bars.first)
        await viewModel.selectInterval(inside)
        await expectSettled(viewModel) { !$0.flows.isEmpty }
        XCTAssertEqual(viewModel.zoom.depth, 2)
        XCTAssertTrue(viewModel.zoom.offersFullReset, "desde dos niveles sí hay salida directa")

        await viewModel.zoomOut()
        await expectSettled(viewModel) { $0.flows.count == 1 }
        XCTAssertEqual(viewModel.viewingInterval, hour.range)
        XCTAssertEqual(viewModel.selectedInterval, hour.range)

        await viewModel.zoomOut()
        await expectSettled(viewModel) { $0.flows.count == 2 }
        XCTAssertNil(viewModel.viewingInterval)
        XCTAssertNil(viewModel.selectedInterval)
        XCTAssertEqual(viewModel.axis.totalPackets, 3, "el eje vuelve a cubrirlo todo")
    }

    /// La salida directa deshace el camino entero de una vez, sin pasar por los niveles.
    func testShowingTheWholeHistoryDropsEveryLevelAtOnce() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await writePackets(to: store, index: 0, at: [0, 1])
        try await writePackets(to: store, index: 1, at: [3_600])
        let viewModel = makeViewModel(store)

        await start(viewModel)
        await expectSettled(viewModel) { $0.flows.count == 2 }
        await viewModel.selectInterval(try XCTUnwrap(viewModel.axis.bars.first))
        await expectSettled(viewModel) { $0.flows.count == 1 }
        await viewModel.selectInterval(try XCTUnwrap(viewModel.axis.bars.first))
        await expectSettled(viewModel) { !$0.flows.isEmpty }

        await viewModel.showWholeHistory()
        await expectSettled(viewModel) { $0.flows.count == 2 }
        XCTAssertEqual(viewModel.zoom, .wholeHistory)
        XCTAssertNil(viewModel.selectedInterval)
        XCTAssertEqual(viewModel.axis.totalPackets, 3)
    }

    /// Un preset del menú es una regla sobre *ahora* y el eje acercado, un trozo del pasado: elegir uno
    /// sube el eje, o la barra dejaría de explicar lo que la lista enseña.
    func testAPresetAlsoLeavesTheZoom() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await writePackets(to: store, index: 0, at: [0, 1])
        try await writePackets(to: store, index: 1, at: [3_600])
        let viewModel = makeViewModel(store)

        await start(viewModel)
        await expectSettled(viewModel) { $0.flows.count == 2 }
        await viewModel.selectInterval(try XCTUnwrap(viewModel.axis.bars.first))
        await expectSettled(viewModel) { $0.flows.count == 1 }

        await viewModel.setTimeRange(.last7Days)
        XCTAssertNil(viewModel.viewingInterval)
        XCTAssertEqual(viewModel.axis.totalPackets, 3, "el eje vuelve a todo el historial")

        await viewModel.selectInterval(try XCTUnwrap(viewModel.axis.bars.first))
        await expectSettled(viewModel) { $0.flows.count == 1 }
        await viewModel.clearFilters()
        await expectSettled(viewModel) { $0.flows.count == 2 }
        XCTAssertEqual(viewModel.zoom, .wholeHistory, "limpiar los filtros también sube el eje")
    }

    /// El cabo suelto que abre acercarse: si la retención se lleva el tramo que se estaba mirando, el
    /// eje no puede dibujarse a cero —se leería como "aquí no hubo tráfico"—, así que se vuelve a todo
    /// el historial **diciéndolo**, y el tramo caducado deja de acotar la lista.
    func testWhenRetentionTakesTheViewedStretchTheAxisGoesBackAndSaysSo() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await writePackets(to: store, index: 0, at: [0, 1])
        try await writePackets(to: store, index: 1, at: [3_600])
        let viewModel = makeViewModel(store)

        await start(viewModel)
        await expectSettled(viewModel) { $0.flows.count == 2 }
        await viewModel.selectInterval(try XCTUnwrap(viewModel.axis.bars.first))
        await expectSettled(viewModel) { $0.flows.count == 1 }
        XCTAssertTrue(viewModel.zoom.isZoomed)
        XCTAssertNil(viewModel.scrubNotice)

        _ = try await store.prune(before: HistoryFixtures.date(3_600))
        await viewModel.refresh()
        await expectSettled(viewModel) { $0.flows.count == 1 }

        XCTAssertEqual(viewModel.zoom, .wholeHistory)
        XCTAssertNil(viewModel.selectedInterval, "un tramo que ya no existe no puede acotar la lista")
        XCTAssertEqual(viewModel.scrubNotice, ScrubPresentation.expiredZoomNotice)
        XCTAssertEqual(viewModel.axis.totalPackets, 1, "queda lo que la retención no se llevó")

        await viewModel.refresh()
        await expectSettled(viewModel) { $0.scrubNotice == nil }
    }

    /// Sin bajar a ningún sitio nada de esto se activa: un eje sobre todo el historial que sale a cero
    /// no puede pasar (los extremos salen de los paquetes), y el aviso hablaría de un tramo que nadie
    /// eligió.
    func testTheWholeHistoryAxisNeverTriggersTheExpiredNotice() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await writePackets(to: store, index: 0, at: [0])
        let viewModel = makeViewModel(store)

        await start(viewModel)
        await expect(viewModel) { !$0.axis.isEmpty }
        try await store.clearAll()
        await viewModel.refresh()
        await expectSettled(viewModel) { $0.flows.isEmpty }

        XCTAssertNil(viewModel.scrubNotice)
        XCTAssertEqual(viewModel.scrub, .hidden, "sin historial la barra no se dibuja")
    }

    // MARK: - Barrer varias barras

    /// Lo que el toque no sabe hacer en cuanto la resolución es fina: acotar la lista a un tramo de
    /// varias barras sin tener que tocarlas una a una.
    func testSweepingSeveralBarsFiltersTheListToTheWholeStretch() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await writePackets(to: store, index: 0, at: [0])
        try await writePackets(to: store, index: 1, at: [600])
        try await writePackets(to: store, index: 2, at: [3_600])
        let viewModel = makeViewModel(store)

        await start(viewModel)
        await expectSettled(viewModel) { $0.flows.count == 3 }
        XCTAssertEqual(viewModel.axis.bars.first?.duration, 300, "el eje se dibuja en tramos de 5 min")

        let swept = try XCTUnwrap(
            viewModel.axis.sweep(from: HistoryFixtures.date(0), to: HistoryFixtures.date(700))
        )
        XCTAssertEqual(swept, HistoryFixtures.date(0)...HistoryFixtures.date(900), "barras enteras")

        await viewModel.selectRange(swept)
        await expectSettled(viewModel) { $0.flows.count == 2 }
        XCTAssertEqual(viewModel.selectedInterval, swept)
        XCTAssertNil(viewModel.timeRange, "con un tramo puesto no hay preset marcado")
    }

    /// La diferencia con el toque, y la razón de que exista `selectRange`: un tramo barrido no es una
    /// barra, así que bajar a él apilaría un nivel que no se corresponde con nada de lo dibujado. El
    /// eje se queda donde estaba y el tramo se **resalta** dentro de él, que es lo que dice dónde está.
    func testASweepFiltersWithoutZoomingTheAxis() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await writePackets(to: store, index: 0, at: [0, 1])
        try await writePackets(to: store, index: 1, at: [3_600])
        let viewModel = makeViewModel(store)

        await start(viewModel)
        await expectSettled(viewModel) { $0.flows.count == 2 }
        let bars = viewModel.axis.bars.count

        let swept = try XCTUnwrap(
            viewModel.axis.sweep(from: HistoryFixtures.date(0), to: HistoryFixtures.date(400))
        )
        await viewModel.selectRange(swept)
        await expectSettled(viewModel) { $0.flows.count == 1 }

        XCTAssertNil(viewModel.viewingInterval, "barrer no baja el eje")
        XCTAssertEqual(viewModel.zoom, .wholeHistory)
        XCTAssertEqual(viewModel.axis.bars.count, bars, "el eje no se ha movido")
        XCTAssertEqual(viewModel.highlightedInterval, swept, "lo barrido sí se señala dentro del eje")
    }

    /// Barrer dentro de un eje acercado acota la lista **sin salirse del tramo**: el acercamiento es
    /// dónde se está mirando y el barrido, cuánto de eso se lista. Soltarlo devuelve la lista a lo que
    /// el eje enseña, que es la misma salida que la de un tramo en el que no se pudo entrar.
    func testASweepInsideAZoomedAxisKeepsTheZoom() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await writePackets(to: store, index: 0, at: [0, 1])
        try await writePackets(to: store, index: 1, at: [200])
        try await writePackets(to: store, index: 2, at: [3_600])
        let viewModel = makeViewModel(store)

        await start(viewModel)
        await expectSettled(viewModel) { $0.flows.count == 3 }
        let stretch = try XCTUnwrap(viewModel.axis.bars.first)
        await viewModel.selectInterval(stretch)
        await expectSettled(viewModel) { $0.flows.count == 2 }

        let swept = try XCTUnwrap(
            viewModel.axis.sweep(from: HistoryFixtures.date(0), to: HistoryFixtures.date(20))
        )
        await viewModel.selectRange(swept)
        await expectSettled(viewModel) { $0.flows.count == 1 }

        XCTAssertEqual(viewModel.zoom.depth, 1, "el acercamiento sigue puesto")
        XCTAssertEqual(viewModel.viewingInterval, stretch.range)
        XCTAssertEqual(viewModel.selectedInterval, swept)

        await viewModel.clearInterval()
        await expectSettled(viewModel) { $0.flows.count == 2 }
        XCTAssertEqual(viewModel.selectedInterval, stretch.range, "la lista vuelve a lo que el eje enseña")
        XCTAssertNil(viewModel.highlightedInterval)
    }

    /// Barrer otra vez lo mismo **no** lo suelta, al revés que volver a tocar un tramo: repetir un
    /// rango exacto con el dedo no se hace sin querer, y leerlo como "quitar el filtro" desharía el
    /// gesto que se acaba de hacer.
    func testSweepingTheSameStretchAgainKeepsIt() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await writePackets(to: store, index: 0, at: [0])
        try await writePackets(to: store, index: 1, at: [3_600])
        let viewModel = makeViewModel(store)

        await start(viewModel)
        await expectSettled(viewModel) { $0.flows.count == 2 }
        let swept = try XCTUnwrap(
            viewModel.axis.sweep(from: HistoryFixtures.date(0), to: HistoryFixtures.date(400))
        )

        await viewModel.selectRange(swept)
        await expectSettled(viewModel) { $0.flows.count == 1 }
        await viewModel.selectRange(swept)
        await expectSettled(viewModel) { $0.flows.count == 1 }
        XCTAssertEqual(viewModel.selectedInterval, swept)
    }

    /// Un gesto nuevo sobre la barra se lleva el aviso de la vez anterior: el del tramo caducado habla
    /// de un eje que ya no es el que el usuario está manejando.
    func testASweepClearsTheExpiredZoomNotice() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await writePackets(to: store, index: 0, at: [0, 1])
        try await writePackets(to: store, index: 1, at: [3_600])
        let viewModel = makeViewModel(store)

        await start(viewModel)
        await expectSettled(viewModel) { $0.flows.count == 2 }
        await viewModel.selectInterval(try XCTUnwrap(viewModel.axis.bars.first))
        await expectSettled(viewModel) { $0.flows.count == 1 }

        _ = try await store.prune(before: HistoryFixtures.date(3_600))
        await viewModel.refresh()
        await expect(viewModel) { $0.scrubNotice != nil }

        let swept = try XCTUnwrap(
            viewModel.axis.sweep(from: HistoryFixtures.date(3_600), to: HistoryFixtures.date(3_600))
        )
        await viewModel.selectRange(swept)
        await expectSettled(viewModel) { $0.flows.count == 1 }
        XCTAssertNil(viewModel.scrubNotice)
        XCTAssertEqual(viewModel.selectedInterval, swept)
    }

    // MARK: - Las filas que la vista pinta

    /// La copia de una fila se compone aquí y no en el `body` de la fila (M11). Lo que hay que
    /// afirmar de ese traslado no es la función pura —que no ha cambiado, y ya tiene sus tests— sino
    /// que lo que se publica es exactamente lo que la vista habría compuesto, flujo a flujo y en el
    /// mismo orden.
    func testEveryDrawnRowCarriesTheCopyOfItsFlow() async throws {
        let store = try makeStore(makeDatabaseURL())
        for index in 0..<3 {
            try await write(to: store, index: index, lastSeen: UInt64(index) * 10, sni: "host\(index)")
        }
        let viewModel = makeViewModel(store)

        await start(viewModel)
        await expect(viewModel) { $0.rows.count == 3 }

        XCTAssertEqual(
            viewModel.rows.map(\.flow), viewModel.flows,
            "la lista pintada y la cargada son la misma, en el mismo orden"
        )
        XCTAssertEqual(
            viewModel.rows.map(\.presentation),
            viewModel.flows.map(TimelinePresentation.row),
            "cada fila trae la copia de su flujo, ya compuesta"
        )
        XCTAssertEqual(
            viewModel.rows.map(\.id), viewModel.flows.map(\.id),
            "la fila se identifica por su conexión: la copia es un derivado suyo"
        )
    }

    /// El riesgo de componer una vez y guardarlo: que una fila ya pintada se quede con la copia de
    /// antes cuando su conexión sigue viva y vuelve a leerse con más tráfico. Se conjura recomponiendo
    /// por **igualdad de los flujos** y no por su identidad, que es lo que este test vigila.
    func testAFlowThatGrowsRedrawsItsCopyAndNotTheStaleOne() async throws {
        let store = try makeStore(makeDatabaseURL())
        let remote = HistoryFixtures.remote(9)
        _ = try await store.upsertFlow(
            HistoryFixtures.record(remote: remote, firstSeen: 0, lastSeen: 10, bytesIn: 2_000)
        )
        let viewModel = makeViewModel(store)

        await start(viewModel)
        await expect(viewModel) { $0.rows.count == 1 }
        let before = try XCTUnwrap(viewModel.rows.first)

        // La misma 5-tupla: el store actualiza la fila en su sitio, así que el `id` no cambia y solo
        // una comparación de contenido puede notar que la copia se quedó vieja.
        _ = try await store.upsertFlow(
            HistoryFixtures.record(remote: remote, firstSeen: 0, lastSeen: 20, bytesIn: 9_000_000)
        )
        await viewModel.refresh()
        await expect(viewModel) { $0.rows.first?.presentation != before.presentation }

        let after = try XCTUnwrap(viewModel.rows.first)
        XCTAssertEqual(after.id, before.id, "sigue siendo la misma conexión")
        XCTAssertEqual(
            after.presentation, TimelinePresentation.row(after.flow),
            "y su copia es la del flujo recargado, no la de la carga anterior"
        )
    }

    /// Una página nueva llega con su copia hecha: si la lista creciera sin rehacer las filas, el
    /// scroll acabaría en un final que no se pinta.
    func testANewPageArrivesWithItsRowsComposed() async throws {
        let store = try makeStore(makeDatabaseURL())
        for index in 0..<4 {
            try await write(to: store, index: index, lastSeen: UInt64(index) * 10)
        }
        let viewModel = makeViewModel(store, policy: HistoryPolicy(pageSize: 2, maxPagesPerLoad: 1))

        await start(viewModel)
        await expect(viewModel) { $0.rows.count == 2 }

        await viewModel.loadMore()
        await expect(viewModel) { $0.rows.count == 4 }
        XCTAssertEqual(viewModel.rows.map(\.flow), viewModel.flows)
    }

    /// Un filtro que no deja pasar nada vacía también lo pintado: dejar las filas puestas dibujaría
    /// una lista que el filtro dice que no existe.
    func testAFilterThatEmptiesTheListEmptiesTheRows() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await write(to: store, index: 0, lastSeen: 10, sni: "example.com")
        let viewModel = makeViewModel(store)

        await start(viewModel)
        await expect(viewModel) { $0.rows.count == 1 }

        viewModel.searchText = "nada-de-esto"
        await viewModel.submitSearch()
        await expectSettled(viewModel) { $0.flows.isEmpty }
        XCTAssertTrue(viewModel.rows.isEmpty, "sin flujos no hay filas que pintar")
    }

    /// Un historial que no se puede abrir no deja filas de una carga anterior: la pantalla entera
    /// pasa a ser la tarjeta del fallo.
    func testAHistoryThatCannotBeOpenedDrawsNoRows() async {
        let viewModel = TimelineViewModel(
            makeReader: { throw FlowStore.StoreError.appGroupUnavailable },
            now: { Date() }
        )

        await start(viewModel)

        XCTAssertTrue(viewModel.rows.isEmpty)
        guard case .placeholder = viewModel.content else {
            return XCTFail("un historial que no abre tiene que explicarse")
        }
    }

    // MARK: - Lo que la barra dice de sí misma

    /// La copia de la barra se compone al publicar un eje y no en su `body`, que se reevalúa con cada
    /// fotograma de un arrastre (M11). Lo afirmable es que lo publicado sea siempre lo que
    /// corresponde al eje que se está enseñando.
    func testTheScrubCopyFollowsTheAxisThatIsDrawn() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await writePackets(to: store, index: 0, at: [0, 1])
        let viewModel = makeViewModel(store)

        XCTAssertEqual(
            viewModel.scrubAxis,
            ScrubPresentation.forAxis(.empty, zoomed: false, zoomable: false),
            "antes de cargar, la copia es la del eje vacío y no un relleno"
        )

        await start(viewModel)
        await expectSettled(viewModel) { !$0.axis.isEmpty }

        XCTAssertEqual(
            viewModel.scrubAxis,
            ScrubPresentation.forAxis(
                viewModel.axis, zoomed: false, zoomable: viewModel.canZoomFurther
            )
        )
    }

    /// Bajar a un tramo cambia dos de las tres cadenas a la vez, y la promesa del acercamiento se
    /// apaga en cuanto ya no queda dónde bajar: por eso se componen juntas y donde vive el eje.
    func testZoomingRewritesWhatTheBarSaysOfItself() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await writePackets(to: store, index: 0, at: [0, 1])
        try await writePackets(to: store, index: 1, at: [3_600])
        let viewModel = makeViewModel(store)

        await start(viewModel)
        await expectSettled(viewModel) { $0.flows.count == 2 }
        let whole = viewModel.scrubAxis
        let hour = try XCTUnwrap(viewModel.axis.bars.first)

        await viewModel.selectInterval(hour)
        await expectSettled(viewModel) { $0.zoom.isZoomed }

        XCTAssertNotEqual(viewModel.scrubAxis.note, whole.note, "el aviso deja de hablar de todo")
        XCTAssertEqual(
            viewModel.scrubAxis,
            ScrubPresentation.forAxis(
                viewModel.axis, zoomed: true, zoomable: viewModel.canZoomFurther
            )
        )

        await viewModel.showWholeHistory()
        await expectSettled(viewModel) { !$0.zoom.isZoomed }
        XCTAssertEqual(viewModel.scrubAxis, whole, "y al salir vuelve a decir lo de antes")
    }

    // MARK: - Apertura del Flow Inspector

    /// La pantalla de una conexión lee del **mismo** historial ya abierto, así que solo puede nacer
    /// después de la apertura. Antes de ella no hay lector que pasarle, y devolver `nil` es lo que
    /// evita que la vista fuerce uno que no está.
    func testAConnectionCanOnlyBeOpenedOnceTheHistoryIs() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await write(to: store, index: 0, lastSeen: 10, sni: "example.com")
        let viewModel = makeViewModel(store)
        let flow = HistoryFixtures.historyFlow(sni: "example.com")

        XCTAssertNil(viewModel.makeInspector(for: flow))

        await start(viewModel)
        await expect(viewModel) { $0.flows.count == 1 }

        guard let row = viewModel.flows.first,
              let inspector = viewModel.makeInspector(for: row)
        else { return XCTFail("una fila cargada tiene que poder abrirse") }

        await inspector.load()
        XCTAssertEqual(inspector.state, .loaded)
        XCTAssertEqual(inspector.host, "example.com", "la pantalla habla de la conexión que se pulsó")
    }

    // MARK: - Ciclo de vida

    /// Salir de la pestaña no descarta lo cargado: volver a ella no puede costar una recarga entera
    /// de una lista que sigue siendo válida.
    func testLeavingTheTabKeepsTheListLoaded() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await write(to: store, index: 0, lastSeen: 10)
        let viewModel = makeViewModel(store)

        await start(viewModel)
        await expect(viewModel) { $0.flows.count == 1 }

        viewModel.stopObserving()
        XCTAssertEqual(viewModel.flows.count, 1)

        await viewModel.startObserving()
        await expect(viewModel) { $0.flows.count == 1 }
    }

    /// Volver a la pestaña recarga: quien escribe es la extensión y SQLite no notifica entre
    /// procesos, así que sin recargar el usuario vería un historial congelado sin saberlo.
    func testComingBackPicksUpTrafficWrittenMeanwhile() async throws {
        let store = try makeStore(makeDatabaseURL())
        try await write(to: store, index: 0, lastSeen: 10)
        let viewModel = makeViewModel(store)

        await start(viewModel)
        await expect(viewModel) { $0.flows.count == 1 }

        viewModel.stopObserving()
        try await write(to: store, index: 1, lastSeen: 20)

        await start(viewModel)
        await expect(viewModel) { $0.flows.count == 2 }
    }
}

/// Deja fallar las primeras aperturas y cuenta los intentos, para probar que el reintento abre de
/// verdad. Es un actor porque la fábrica es `@Sendable` y se ejecuta fuera del `MainActor`.
private actor OpenGate {
    private(set) var attempts = 0
    private var failuresLeft: Int

    init(failuresLeft: Int) {
        self.failuresLeft = failuresLeft
    }

    func check() throws {
        attempts += 1
        guard failuresLeft > 0 else { return }
        failuresLeft -= 1
        throw FlowStore.StoreError.openFailed
    }
}

/// Reloj movible para los rangos relativos. El `now` del view model es una closure `@Sendable` que no
/// está aislada a ningún actor, así que el estado se protege con un candado en vez de con aislamiento.
private final class MovableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(instant: Date) {
        self.value = instant
    }

    var instant: Date {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            value = newValue
        }
    }
}
