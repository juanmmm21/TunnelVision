import Foundation
import XCTest
@testable import Shared

/// El view model del Flow Inspector: contra un `HistoryReader` **real** sobre un `FlowStore` real
/// —como el de la Timeline, porque lo que importa es qué acaba viendo la pantalla de lo que hay en
/// disco— y contra una consulta que falla a voluntad, que es lo que un store sano no sabe hacer.
@MainActor
final class FlowInspectorViewModelTests: XCTestCase {

    // MARK: - Utilidades

    private func makeStore() throws -> FlowStore {
        let url = PersistenceFixtures.temporaryDatabaseURL()
        addTeardownBlock { PersistenceFixtures.removeDatabase(at: url) }
        return try FlowStore(databaseURL: url, anchor: HistoryFixtures.anchor)
    }

    /// Escribe un flujo con sus paquetes y devuelve el `HistoryFlow` que la Timeline le pasaría a la
    /// pantalla. Los sellos son segundos desde el ancla, como en el resto de tests del historial.
    private func write(
        to store: FlowStore,
        proto: IPProtocolNumber = .tcp,
        packets: [(seconds: UInt64, flags: TCPFlags, direction: Direction)],
        packetCount: UInt64? = nil,
        tlsStatus: TLSInspectionStatus = .encrypted
    ) async throws -> HistoryFlow {
        let remote = HistoryFixtures.remote(34)
        let key = HistoryFixtures.key(remote: remote, proto: proto)
        let lastSeen = packets.map(\.seconds).max() ?? 0
        let flowID = try await store.upsertFlow(
            HistoryFixtures.record(
                remote: remote,
                proto: proto,
                firstSeen: 0,
                lastSeen: lastSeen,
                packetCount: packetCount ?? UInt64(packets.count),
                tlsStatus: tlsStatus
            )
        )
        try await store.appendPackets(
            packets.map {
                HistoryFixtures.packet(
                    timestamp: $0.seconds,
                    key: key,
                    direction: $0.direction,
                    tcpFlags: $0.flags
                )
            },
            flowID: flowID
        )
        guard let stored = try await store.recentFlows(limit: 1).first else {
            throw XCTSkip("el flujo recién escrito tiene que poder leerse")
        }
        XCTAssertEqual(stored.id, flowID)
        return HistoryFlow(stored, localAddresses: HistoryFixtures.localAddresses)
    }

    private let handshake: [(seconds: UInt64, flags: TCPFlags, direction: Direction)] = [
        (0, [.syn], .outbound),
        (1, [.syn, .ack], .inbound),
        (2, [.psh, .ack], .outbound),
    ]

    // MARK: - Carga

    func testOpeningAConnectionShowsItsPacketsInOrder() async throws {
        let store = try makeStore()
        let flow = try await write(to: store, packets: handshake)
        let viewModel = FlowInspectorViewModel(flow: flow, reader: HistoryReader(store: store))

        XCTAssertEqual(viewModel.content, .loading, "antes de cargar no se afirma nada de la lista")
        await viewModel.load()

        XCTAssertEqual(viewModel.state, .loaded)
        XCTAssertEqual(viewModel.rows.map(\.packet.event), [.opened, .accepted, .data])
        XCTAssertEqual(viewModel.rows.map(\.packet.direction), [.outbound, .inbound, .outbound])
        XCTAssertEqual(viewModel.content, .packets(viewModel.rows))
        XCTAssertNil(viewModel.truncationNote, "la conexión entera cabe: no hay nada que avisar")
    }

    /// La cabecera sale del flujo que llegó de la Timeline: es la misma conexión que el usuario acaba
    /// de pulsar.
    func testTheHeaderDescribesTheConnectionThatWasTapped() async throws {
        let store = try makeStore()
        let flow = try await write(to: store, packets: handshake)
        let viewModel = FlowInspectorViewModel(flow: flow, reader: HistoryReader(store: store))

        XCTAssertEqual(viewModel.host, FlowDisplay.host(flow))
        XCTAssertEqual(viewModel.tlsStatus, TLSStatusPresentation.forStatus(flow.tlsStatus))
        XCTAssertEqual(viewModel.facts.first?.value, .text("TCP · port 443"))
    }

    /// Era una foto: una conexión todavía viva sigue sumando bytes mientras se la mira, y la cabecera
    /// se quedaba en las cifras de cuando se pulsó la fila, sin decir que estaba parada.
    func testRefreshingRereadsTheConnectionAndNotOnlyItsPackets() async throws {
        let store = try makeStore()
        let flow = try await write(to: store, packets: handshake)
        let viewModel = FlowInspectorViewModel(flow: flow, reader: HistoryReader(store: store))
        await viewModel.load()
        let bytesWhenOpened = viewModel.flow.stored.bytesIn

        // La extensión sigue escribiendo bajo la pantalla: el mismo flujo crece.
        _ = try await store.upsertFlow(
            HistoryFixtures.record(
                remote: HistoryFixtures.remote(34),
                firstSeen: 0,
                lastSeen: 9,
                bytesIn: bytesWhenOpened + 4_096,
                packetCount: 9
            )
        )

        await viewModel.reload()

        XCTAssertEqual(viewModel.flow.id, flow.id, "sigue siendo la conexión que se abrió")
        XCTAssertEqual(viewModel.flow.stored.bytesIn, bytesWhenOpened + 4_096)
    }

    /// Refrescar la cabecera **no puede** tapar la lista: el estado de esta pantalla es el de sus
    /// paquetes, que es a lo que se abrió. Si la relectura del flujo falla, lo que se pierde es una
    /// actualización de unas cifras, no la pantalla.
    func testAFailedHeaderRefreshKeepsThePacketsAndTheOldHeader() async throws {
        struct Unavailable: Error {}
        let flow = HistoryFixtures.historyFlow()
        let viewModel = FlowInspectorViewModel(
            flow: flow,
            loadFlow: { _ in throw Unavailable() },
            loadPackets: { _ in [HistoryFixtures.storedPacket()] }
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.state, .loaded)
        XCTAssertEqual(viewModel.rows.count, 1)
        XCTAssertEqual(viewModel.flow, flow, "se conserva la cabecera anterior, que era cierta")
    }

    /// Que la retención se lleve la conexión con la pantalla abierta tampoco la vacía: enseñar unos
    /// paquetes sin poder decir de quién son sería peor que una cabecera de hace un minuto.
    func testAConnectionRemovedWhileOpenKeepsItsHeader() async throws {
        let flow = HistoryFixtures.historyFlow()
        let viewModel = FlowInspectorViewModel(
            flow: flow,
            loadFlow: { _ in nil },
            loadPackets: { _ in [HistoryFixtures.storedPacket()] }
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.flow, flow)
        XCTAssertEqual(viewModel.state, .loaded)
    }

    /// Volver de una vista apilada encima vuelve a disparar la aparición de la pantalla; recargar ahí
    /// gastaría una consulta para enseñar exactamente lo mismo.
    func testAppearingAgainDoesNotQueryTheHistoryTwice() async throws {
        let counter = QueryCounter()
        let viewModel = FlowInspectorViewModel(flow: HistoryFixtures.historyFlow()) { _ in
            await counter.record()
            return [HistoryFixtures.storedPacket()]
        }

        await viewModel.load()
        await viewModel.load()

        let calls = await counter.calls
        XCTAssertEqual(calls, 1)
    }

    // MARK: - Vacío y fallo

    /// Una conexión puede estar guardada sin sus paquetes (captura en metadatos-solo, o retención).
    /// Eso es un vacío que se explica, no un error que se reintenta.
    func testAConnectionWithoutPacketsIsAnEmptyStateAndNotAFailure() async throws {
        let store = try makeStore()
        let flow = try await write(to: store, packets: [], packetCount: 0)
        let viewModel = FlowInspectorViewModel(flow: flow, reader: HistoryReader(store: store))

        await viewModel.load()

        XCTAssertEqual(viewModel.state, .loaded)
        guard case .placeholder(let placeholder) = viewModel.content else {
            return XCTFail("una conexión sin paquetes tiene que explicarse")
        }
        XCTAssertNil(placeholder.action)
    }

    /// Aquí la consulta **sí** lanza (al revés que las cargas de la Timeline), así que el fallo es un
    /// estado de la pantalla con salida.
    func testAFailedQueryBecomesAnActionableScreenState() async {
        let gate = FailingQuery(failuresLeft: 1)
        let viewModel = FlowInspectorViewModel(flow: HistoryFixtures.historyFlow()) { _ in
            try await gate.check()
            return [HistoryFixtures.storedPacket(id: 7)]
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.state, .failed(.queryFailed("database is locked")))
        guard case .placeholder(let placeholder) = viewModel.content,
              let action = placeholder.action
        else { return XCTFail("el fallo tiene que ofrecer salida") }

        await viewModel.perform(action)
        XCTAssertEqual(viewModel.state, .loaded)
        XCTAssertEqual(viewModel.rows.map(\.id), [7])
    }

    /// Un `corruptData` del lector llega tal cual y no envuelto en un "no se pudo leer": son dos
    /// mensajes distintos y el usuario merece el que corresponde.
    func testATypedErrorFromTheReaderKeepsItsKind() async {
        let viewModel = FlowInspectorViewModel(flow: HistoryFixtures.historyFlow()) { _ in
            throw HistoryError.corruptData("puerto fuera de rango: 99999")
        }

        await viewModel.load()

        XCTAssertEqual(viewModel.state, .failed(.corruptData("puerto fuera de rango: 99999")))
    }

    /// Y un fallo posterior no puede tapar lo que el usuario ya estaba leyendo.
    func testAFailedReloadKeepsTheListThatWasAlreadyDrawn() async {
        let gate = FailingQuery(failuresLeft: 0)
        let viewModel = FlowInspectorViewModel(flow: HistoryFixtures.historyFlow()) { _ in
            try await gate.check()
            return [HistoryFixtures.storedPacket(id: 3)]
        }

        await viewModel.load()
        XCTAssertEqual(viewModel.rows.count, 1)

        await gate.fail(times: 1)
        await viewModel.reload()

        XCTAssertEqual(viewModel.state, .failed(.queryFailed("database is locked")))
        XCTAssertEqual(viewModel.content, .packets(viewModel.rows), "la lista sigue en pie")
    }

    // MARK: - La copia fuera del camino de dibujo (M11)

    /// Lo que la pantalla publica son filas **con su copia ya compuesta**, no paquetes que la vista
    /// tenga que traducir en cada fotograma de scroll. Es el mismo reparto que hicieron la Timeline y
    /// la barra de scrub, y aquí es donde se puede afirmar que la fila recibe la copia en vez de
    /// calcularla.
    func testTheListIsPublishedWithItsCopyAlreadyComposed() async throws {
        let store = try makeStore()
        let flow = try await write(to: store, packets: handshake)
        let viewModel = FlowInspectorViewModel(flow: flow, reader: HistoryReader(store: store))

        await viewModel.load()

        XCTAssertEqual(
            viewModel.rows.map(\.presentation.event),
            ["Connection opened", "Connection accepted", "Data"]
        )
        for row in viewModel.rows {
            XCTAssertEqual(
                row.presentation,
                FlowInspectorPresentation.row(row.packet),
                "la fila \(row.id) se publicó con la copia de otro paquete"
            )
            XCTAssertFalse(row.presentation.accessibilityLabel.isEmpty)
        }
    }

    /// Y una recarga que trae otros paquetes rehace la copia: la lista no puede quedarse con la de la
    /// carga anterior. Aquí no hace falta comparar nada para saberlo —esta pantalla no pagina ni se
    /// refresca sola, así que se compone una vez por carga—, pero que se rehaga es la propiedad que la
    /// fila da por supuesta.
    func testReloadingWithOtherPacketsRecomposesTheCopy() async {
        let source = PacketSource(packets: [HistoryFixtures.storedPacket(id: 1, tcpFlags: [.syn])])
        let viewModel = FlowInspectorViewModel(flow: HistoryFixtures.historyFlow()) { _ in
            await source.packets
        }

        await viewModel.load()
        XCTAssertEqual(viewModel.rows.map(\.presentation.event), ["Connection opened"])

        await source.replace(with: [HistoryFixtures.storedPacket(id: 2, tcpFlags: [.rst])])
        await viewModel.reload()

        XCTAssertEqual(viewModel.rows.map(\.id), [2])
        XCTAssertEqual(viewModel.rows.map(\.presentation.event), ["Connection cut off"])
    }

    // MARK: - Lista recortada

    /// El tope de la política se anuncia: si no, la pantalla afirmaría que una conexión de 50
    /// paquetes tuvo 2.
    func testACappedListSaysHowManyPacketsTheConnectionReallyHad() async throws {
        let store = try makeStore()
        let flow = try await write(
            to: store,
            packets: (0..<5).map { (UInt64($0), TCPFlags([.ack]), Direction.outbound) }
        )
        let viewModel = FlowInspectorViewModel(
            flow: flow,
            reader: HistoryReader(store: store, policy: HistoryPolicy(packetsPerFlow: 2))
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.rows.count, 2)
        XCTAssertEqual(
            viewModel.truncationNote,
            "Showing the first 2 of 5 packets recorded for this connection."
        )
    }

    // MARK: - La sección del contenido descifrado

    func testTheSectionSaysNothingUntilItsIndexHasBeenRead() async throws {
        let store = try makeStore()
        let flow = try await write(to: store, packets: handshake)
        let viewModel = FlowInspectorViewModel(flow: flow, reader: HistoryReader(store: store))

        // Las cuatro ausencias **afirman** algo, y ninguna es cierta antes de haber preguntado.
        XCTAssertNil(viewModel.contentSection)

        await viewModel.load()

        XCTAssertNotNil(viewModel.contentSection)
    }

    func testAnInspectedConnectionWithSavedContentOffersIt() async throws {
        let store = try makeStore()
        let flow = try await write(to: store, packets: handshake, tlsStatus: .inspected)
        try await store.appendPlaintext(
            [
                PlaintextChunkMeta(
                    timestamp: HistoryFixtures.uptime(3),
                    direction: .outbound,
                    stream: 1,
                    location: PlaintextLocation(fileSequence: 1, recordOffset: 16),
                    storedLength: 120,
                    originalLength: 120
                )
            ],
            flowID: flow.id
        )
        let viewModel = FlowInspectorViewModel(flow: flow, reader: HistoryReader(store: store))

        await viewModel.load()

        XCTAssertEqual(viewModel.contentSection, .conversation(storedBytes: 120))
        XCTAssertEqual(viewModel.conversationRoute.chunks.count, 1)
        XCTAssertEqual(viewModel.conversationRoute.flow.id, flow.id)
    }

    func testAnInspectedConnectionWithNothingSavedSaysSo() async throws {
        let store = try makeStore()
        let flow = try await write(to: store, packets: handshake, tlsStatus: .inspected)
        let viewModel = FlowInspectorViewModel(flow: flow, reader: HistoryReader(store: store))

        await viewModel.load()

        XCTAssertEqual(viewModel.contentSection, .absent(.notSaved))
    }

    func testAFailedIndexReadIsNotReadAsNothingSaved() async throws {
        // Es la razón de que la consulta vaya dentro del mismo `do` y **delante** de los paquetes:
        // decir «no se guardó nada» sin haber leído el índice es lo único que no se puede afirmar.
        let store = try makeStore()
        let flow = try await write(to: store, packets: handshake, tlsStatus: .inspected)
        let failing = FailingQuery(failuresLeft: 1)
        let viewModel = FlowInspectorViewModel(
            flow: flow,
            loadPlaintext: { _ in
                try await failing.check()
                return []
            },
            loadPackets: { id in try await HistoryReader(store: store).packets(forFlow: id) }
        )

        await viewModel.load()

        XCTAssertNil(viewModel.contentSection)
        XCTAssertEqual(viewModel.state, .failed(.queryFailed("database is locked")))

        await viewModel.perform(.retry)

        XCTAssertEqual(viewModel.contentSection, .absent(.notSaved))
    }
}

/// Devuelve unos paquetes u otros según le vayan cambiando, para que una recarga traiga algo distinto
/// de lo que trajo la primera carga.
private actor PacketSource {
    private(set) var packets: [StoredPacket]

    init(packets: [StoredPacket]) {
        self.packets = packets
    }

    func replace(with packets: [StoredPacket]) {
        self.packets = packets
    }
}

/// Cuenta las consultas, para probar que la segunda aparición no dispara otra.
private actor QueryCounter {
    private(set) var calls = 0
    func record() { calls += 1 }
}

/// Hace fallar la consulta a voluntad: un `FlowStore` sano sobre una BD temporal no sabe fallar, y el
/// camino del error es justo el que distingue a esta pantalla de la Timeline.
private actor FailingQuery {
    private var failuresLeft: Int

    init(failuresLeft: Int) {
        self.failuresLeft = failuresLeft
    }

    func fail(times: Int) {
        failuresLeft += times
    }

    func check() throws {
        guard failuresLeft > 0 else { return }
        failuresLeft -= 1
        throw HistoryError.queryFailed("database is locked")
    }
}
