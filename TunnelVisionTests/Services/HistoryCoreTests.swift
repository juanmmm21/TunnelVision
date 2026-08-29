import XCTest
@testable import Shared

/// El núcleo puro del historial: el reparto de extremos, el host que se enseña, los filtros y el
/// encadenado de páginas. Todo síncrono y sin disco.
final class HistoryCoreTests: XCTestCase {

    // MARK: - HistoryFlow

    func testTheRemoteEndpointIsTheOneThatIsNotTheDevice() {
        let flow = HistoryFixtures.historyFlow(remote: HistoryFixtures.remote(34), remotePort: 443)
        XCTAssertEqual(flow.remoteEndpoint?.address, HistoryFixtures.remote(34))
        XCTAssertEqual(flow.remotePort, 443)
        XCTAssertEqual(flow.endpoints?.local.address, HistoryFixtures.deviceIPv4)
    }

    func testTheIPv6TunnelAddressIsRecognisedToo() {
        let flow = HistoryFixtures.historyFlow(
            remote: ModelFixtures.v6(0x2606, 0x2800, 0x220, 1, 0x248, 0x1893, 0x25c8, 0x1946),
            local: HistoryFixtures.deviceIPv6
        )
        XCTAssertEqual(flow.endpoints?.local.address, HistoryFixtures.deviceIPv6)
    }

    /// Si ninguno de los dos extremos es del túnel no se adivina: la vista dirá que el host es
    /// desconocido antes que enseñar como host al propio dispositivo.
    func testWithoutALocalAddressThereIsNoHost() {
        let flow = HistoryFixtures.historyFlow(localAddresses: [])
        XCTAssertNil(flow.endpoints)
        XCTAssertNil(flow.displayHost)
        XCTAssertNil(flow.remotePort)
    }

    func testTheSNIWinsOverTheAddressAsDisplayHost() {
        let named = HistoryFixtures.historyFlow(sni: "example.com")
        XCTAssertEqual(named.displayHost, "example.com")

        let anonymous = HistoryFixtures.historyFlow(remote: HistoryFixtures.remote(34))
        XCTAssertEqual(anonymous.displayHost, "93.184.216.34")
    }

    /// Un SNI vacío es lo mismo que no tenerlo: encabezar la fila con una cadena en blanco sería
    /// peor que enseñar la IP.
    func testAnEmptySNIFallsBackToTheAddress() {
        let flow = HistoryFixtures.historyFlow(sni: "")
        XCTAssertEqual(flow.displayHost, "93.184.216.34")
    }

    func testDurationAndTotalsComeFromTheStoredRow() {
        let flow = HistoryFixtures.historyFlow(firstSeen: 10, lastSeen: 70)
        XCTAssertEqual(flow.duration, 60, accuracy: 0.000_001)
        XCTAssertEqual(flow.totalBytes, 3_000)
        XCTAssertEqual(flow.firstSeen, HistoryFixtures.date(10))
        XCTAssertEqual(flow.lastSeen, HistoryFixtures.date(70))
    }

    // MARK: - HistoryFilter

    func testAnEmptyFilterIsInactiveAndMatchesEverything() {
        let filter = HistoryFilter.none
        XCTAssertFalse(filter.isActive)
        XCTAssertTrue(filter.matches(HistoryFixtures.historyFlow()))
        XCTAssertTrue(filter.matches(HistoryFixtures.historyFlow(proto: .udp, tlsStatus: .plaintext)))
    }

    func testWhitespaceOnlySearchTextDoesNotActivateTheFilter() {
        let filter = HistoryFilter(searchText: "   ")
        XCTAssertFalse(filter.isActive)
        XCTAssertTrue(filter.matches(HistoryFixtures.historyFlow(localAddresses: [])))
    }

    func testTheProtocolFilterAdmitsOnlyItsProtocols() {
        let filter = HistoryFilter(protocols: [.udp])
        XCTAssertTrue(filter.isActive)
        XCTAssertTrue(filter.matches(HistoryFixtures.historyFlow(proto: .udp)))
        XCTAssertFalse(filter.matches(HistoryFixtures.historyFlow(proto: .tcp)))
    }

    func testTheTLSStatusFilterAdmitsOnlyItsStatuses() {
        let filter = HistoryFilter(tlsStatuses: [.inspected, .notInspectable])
        XCTAssertTrue(filter.matches(HistoryFixtures.historyFlow(tlsStatus: .inspected)))
        XCTAssertTrue(filter.matches(HistoryFixtures.historyFlow(tlsStatus: .notInspectable)))
        XCTAssertFalse(filter.matches(HistoryFixtures.historyFlow(tlsStatus: .encrypted)))
    }

    func testTheSearchTextMatchesTheSNICaseInsensitively() {
        let filter = HistoryFilter(searchText: "EXAMPLE")
        XCTAssertTrue(filter.matches(HistoryFixtures.historyFlow(sni: "cdn.example.com")))
        XCTAssertFalse(filter.matches(HistoryFixtures.historyFlow(sni: "apple.com")))
    }

    func testTheSearchTextAlsoMatchesTheRemoteAddress() {
        let filter = HistoryFilter(searchText: "93.184")
        XCTAssertTrue(filter.matches(HistoryFixtures.historyFlow(remote: HistoryFixtures.remote(34))))
        XCTAssertFalse(
            filter.matches(HistoryFixtures.historyFlow(remote: ModelFixtures.v4(1, 1, 1, 1)))
        )
    }

    /// Un flujo sin host no coincide con ninguna búsqueda de texto: no hay nada contra lo que buscar,
    /// y darlo por bueno metería filas mudas entre los resultados.
    func testAFlowWithoutAHostNeverMatchesASearch() {
        let filter = HistoryFilter(searchText: "example")
        XCTAssertFalse(filter.matches(HistoryFixtures.historyFlow(sni: nil, localAddresses: [])))
    }

    /// Un flujo pertenece a la ventana si **se solapa** con ella: una conexión viva durante ese rato
    /// cuenta aunque empezara antes o siguiera después.
    func testTheDateRangeMatchesOverlappingFlowsNotOnlyContainedOnes() {
        let filter = HistoryFilter(
            dateRange: HistoryFixtures.date(100)...HistoryFixtures.date(200)
        )
        XCTAssertTrue(
            filter.matches(HistoryFixtures.historyFlow(firstSeen: 120, lastSeen: 180)), "contenido"
        )
        XCTAssertTrue(
            filter.matches(HistoryFixtures.historyFlow(firstSeen: 50, lastSeen: 150)), "entra por la izquierda"
        )
        XCTAssertTrue(
            filter.matches(HistoryFixtures.historyFlow(firstSeen: 150, lastSeen: 400)), "sale por la derecha"
        )
        XCTAssertTrue(
            filter.matches(HistoryFixtures.historyFlow(firstSeen: 0, lastSeen: 900)), "lo abarca entero"
        )
        XCTAssertFalse(
            filter.matches(HistoryFixtures.historyFlow(firstSeen: 0, lastSeen: 99)), "termina antes"
        )
        XCTAssertFalse(
            filter.matches(HistoryFixtures.historyFlow(firstSeen: 201, lastSeen: 300)), "empieza después"
        )
    }

    func testCriteriaCombineWithAND() {
        let filter = HistoryFilter(
            searchText: "example", protocols: [.tcp], tlsStatuses: [.inspected]
        )
        XCTAssertTrue(
            filter.matches(
                HistoryFixtures.historyFlow(proto: .tcp, tlsStatus: .inspected, sni: "example.com")
            )
        )
        // Cada uno de los tres, fallando por su cuenta.
        XCTAssertFalse(
            filter.matches(
                HistoryFixtures.historyFlow(proto: .udp, tlsStatus: .inspected, sni: "example.com")
            )
        )
        XCTAssertFalse(
            filter.matches(
                HistoryFixtures.historyFlow(proto: .tcp, tlsStatus: .encrypted, sni: "example.com")
            )
        )
        XCTAssertFalse(
            filter.matches(
                HistoryFixtures.historyFlow(proto: .tcp, tlsStatus: .inspected, sni: "apple.com")
            )
        )
    }

    // MARK: - Paginación

    func testAppendingAPageKeepsOrderAndDropsRepeats() {
        let existing = [1, 2, 3].map { HistoryFixtures.historyFlow(id: Int64($0)) }
        // El 3 vuelve a aparecer porque la extensión actualizó su last_seen entre páginas.
        let page = [3, 4, 5].map { HistoryFixtures.historyFlow(id: Int64($0)) }

        let merged = HistoryPaging.appending(page, to: existing)
        XCTAssertEqual(merged.map(\.id), [1, 2, 3, 4, 5])
    }

    func testAppendingAnEmptyPageChangesNothing() {
        let existing = [1, 2].map { HistoryFixtures.historyFlow(id: Int64($0)) }
        XCTAssertEqual(HistoryPaging.appending([], to: existing).map(\.id), [1, 2])
    }

    func testAppendingToAnEmptyListDeduplicatesWithinThePage() {
        let page = [7, 7, 8].map { HistoryFixtures.historyFlow(id: Int64($0)) }
        XCTAssertEqual(HistoryPaging.appending(page, to: []).map(\.id), [7, 8])
    }

    // MARK: - Snapshot

    func testEmptyOnlyMeansEmptyOnceLoaded() {
        XCTAssertFalse(HistorySnapshot(state: .loading).isEmpty, "cargando no es vacío")
        XCTAssertTrue(HistorySnapshot(state: .loaded).isEmpty)
        XCTAssertFalse(
            HistorySnapshot(flows: [HistoryFixtures.historyFlow()], state: .loaded).isEmpty
        )
    }

    // MARK: - Errores

    func testACorruptRowKeepsItsDetailAndAnythingElseIsAQueryFailure() {
        XCTAssertEqual(
            HistoryError.classifying(FlowStore.StoreError.corruptRow("puerto fuera de rango: 99999")),
            .corruptData("puerto fuera de rango: 99999")
        )
        // Cualquier otro error del store, o de GRDB, cae en el genérico sin perder su descripción.
        guard case .queryFailed(let message) =
            HistoryError.classifying(FlowStore.StoreError.openFailed)
        else {
            return XCTFail("un fallo de apertura debería clasificarse como queryFailed")
        }
        XCTAssertTrue(message.contains("openFailed"))
    }

    /// Lo que ya viene clasificado se deja pasar. Importa porque el lector lanza `HistoryError`: sin
    /// esto, el Flow Inspector —que clasifica lo que le llega del lector— convertiría un
    /// `corruptData` en un `queryFailed` con el caso anterior escrito dentro, y enseñaría el mensaje
    /// de "no se pudo leer" sobre unos datos que sí se leyeron y estaban dañados.
    func testAnAlreadyTypedErrorIsNotWrappedAgain() {
        XCTAssertEqual(
            HistoryError.classifying(HistoryError.corruptData("fila 12")),
            .corruptData("fila 12")
        )
        XCTAssertEqual(
            HistoryError.classifying(HistoryError.queryFailed("database is locked")),
            .queryFailed("database is locked")
        )
    }
}
