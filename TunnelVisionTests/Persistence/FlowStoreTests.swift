import XCTest
import GRDB
@testable import Shared

final class FlowStoreTests: XCTestCase {
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

    /// Store con el ancla de referencia: las fechas de salida son deterministas y comprobables.
    private func makeStore(anchor: MonotonicAnchor = PersistenceFixtures.anchor) throws -> FlowStore {
        try FlowStore(databaseURL: dbURL, anchor: anchor)
    }

    // MARK: - Migraciones

    func testMigrationsApplyOnFreshDatabase() async throws {
        let store = try makeStore()
        // Una BD recién migrada no tiene flujos; la consulta funciona (esquema presente).
        let flows = try await store.recentFlows(limit: 10)
        XCTAssertTrue(flows.isEmpty)
    }

    func testReopeningIsIdempotent() async throws {
        let remote = ModelFixtures.v4(93, 184, 216, 34)
        do {
            let store = try makeStore()
            _ = try await store.upsertFlow(
                PersistenceFixtures.flow(remote: remote, firstSeen: 1, lastSeen: 2)
            )
        }
        // Reabrir la misma ruta debe re-aplicar migraciones sin error y conservar los datos.
        let reopened = try makeStore()
        let flows = try await reopened.recentFlows(limit: 10)
        XCTAssertEqual(flows.count, 1)
        XCTAssertEqual(flows.first?.lastSeen, PersistenceFixtures.date(2))
    }

    /// La migración v2 descarta las filas de v1 en vez de reinterpretar sus sellos monotónicos como
    /// epoch, que las situaría en 1970. Se construye una BD detenida en v1 para poder comprobarlo.
    func testMigrationV2DiscardsRowsWrittenUnderV1() async throws {
        let legacy = try DatabaseQueue(path: dbURL.path)
        try Schema.migrator().migrate(legacy, upTo: "v1")
        try await legacy.write { db in
            try db.execute(
                sql: """
                INSERT INTO flows
                    (proto, addr_a, port_a, addr_b, port_b,
                     first_seen, last_seen, bytes_out, bytes_in, packet_count, tls_status, sni)
                VALUES (6, ?, 51000, ?, 443, 100, 200, 0, 0, 1, 1, NULL)
                """,
                arguments: [
                    Data(PersistenceFixtures.deviceIP.bytes),
                    Data(ModelFixtures.v4(1, 1, 1, 1).bytes),
                ]
            )
        }
        try legacy.close()

        let store = try makeStore()
        let flows = try await store.recentFlows(limit: 10)
        XCTAssertTrue(flows.isEmpty, "las filas de v1 no son fechables: v2 las descarta")

        // Y la BD sigue siendo utilizable: el esquema v2 quedó aplicado.
        _ = try await store.upsertFlow(
            PersistenceFixtures.flow(remote: ModelFixtures.v4(2, 2, 2, 2), firstSeen: 1, lastSeen: 2)
        )
        let after = try await store.recentFlows(limit: 10)
        XCTAssertEqual(after.count, 1)
    }

    /// La migración v3 anula los offsets escritos antes de que se guardara el fichero: un offset sin
    /// fichero no señala unos bytes, y dejarlo apuntando al fichero 0 sería inventárselos. Se
    /// construye una BD detenida en v2 para poder comprobarlo.
    func testMigrationV3ClearsOffsetsWrittenBeforeTheFileWasKnown() async throws {
        let legacy = try DatabaseQueue(path: dbURL.path)
        try Schema.migrator().migrate(legacy, upTo: "v2")
        try await legacy.write { db in
            try db.execute(
                sql: """
                INSERT INTO flows
                    (session, proto, addr_a, port_a, addr_b, port_b,
                     first_seen, last_seen, bytes_out, bytes_in, packet_count, tls_status, sni)
                VALUES (0, 6, ?, 51000, ?, 443, 100, 200, 0, 0, 1, 1, NULL)
                """,
                arguments: [
                    Data(PersistenceFixtures.deviceIP.bytes),
                    Data(ModelFixtures.v4(1, 1, 1, 1).bytes),
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO packets (flow_id, ts, direction, length, tcp_flags, pcap_offset)
                VALUES (1, 150, 0, 1500, 16, 4096)
                """
            )
        }
        try legacy.close()

        let store = try makeStore()
        // El flujo y su paquete se conservan (los metadatos siguen siendo ciertos); lo único que se
        // pierde es el enlace a la captura, que nunca fue resoluble.
        let flows = try await store.recentFlows(limit: 10)
        XCTAssertEqual(flows.count, 1)
        let packets = try await store.packets(forFlow: try XCTUnwrap(flows.first).id, limit: 10)
        XCTAssertEqual(packets.count, 1)
        XCTAssertNil(packets.first?.capture)
        let highest = try await store.highestCaptureFileSequence()
        XCTAssertNil(highest, "un offset huérfano no puede reservar la secuencia de ningún fichero")
    }

    // MARK: - Fechado

    func testStampsAreStoredAsWallClockTime() async throws {
        let store = try makeStore()
        _ = try await store.upsertFlow(
            PersistenceFixtures.flow(
                remote: ModelFixtures.v4(93, 184, 216, 34), firstSeen: 3, lastSeen: 63
            )
        )
        let firstPage = try await store.recentFlows(limit: 1)
        let flow = try XCTUnwrap(firstPage.first)
        XCTAssertEqual(flow.firstSeen, PersistenceFixtures.date(3))
        XCTAssertEqual(flow.lastSeen, PersistenceFixtures.date(63))
        XCTAssertEqual(flow.duration, 60, accuracy: 0.000_001)
    }

    /// Lo guardado es absoluto: un store abierto con **otra** ancla (lo que ocurre en la sesión
    /// siguiente, y siempre en la app, que no comparte el uptime de la extensión) lee las mismas
    /// fechas. Si el disco guardase el sello monotónico crudo, este test daría fechas distintas.
    func testStoredDatesDoNotDependOnTheReadersAnchor() async throws {
        let remote = ModelFixtures.v4(93, 184, 216, 34)
        do {
            let writer = try makeStore()
            _ = try await writer.upsertFlow(
                PersistenceFixtures.flow(remote: remote, firstSeen: 3, lastSeen: 63)
            )
        }
        // Otra sesión: el uptime volvió a empezar y la hora de pared avanzó un día.
        let otherAnchor = MonotonicAnchor(
            uptimeNanoseconds: 5_000_000_000,
            wallClock: PersistenceFixtures.anchorWallClock.addingTimeInterval(86_400)
        )
        let reader = try makeStore(anchor: otherAnchor)
        let page = try await reader.recentFlows(limit: 1)
        let flow = try XCTUnwrap(page.first)
        XCTAssertEqual(flow.firstSeen, PersistenceFixtures.date(3))
        XCTAssertEqual(flow.lastSeen, PersistenceFixtures.date(63))
    }

    // MARK: - Upsert de flujos

    func testUpsertInsertsThenUpdatesSameRow() async throws {
        let store = try makeStore()
        let remote = ModelFixtures.v4(93, 184, 216, 34)

        let id1 = try await store.upsertFlow(
            PersistenceFixtures.flow(
                remote: remote, firstSeen: 10, lastSeen: 20,
                bytesOut: 500, bytesIn: 1_000, packetCount: 3
            )
        )
        // Segundo upsert del MISMO flujo (misma 5-tupla) con totales agregados mayores.
        let id2 = try await store.upsertFlow(
            PersistenceFixtures.flow(
                remote: remote, firstSeen: 8, lastSeen: 40,
                bytesOut: 900, bytesIn: 2_500, packetCount: 7,
                tlsStatus: .inspected, sni: "example.com"
            )
        )

        XCTAssertEqual(id1, id2, "el upsert de la misma 5-tupla debe reutilizar el rowid")

        let flows = try await store.recentFlows(limit: 10)
        XCTAssertEqual(flows.count, 1, "no debe duplicar el flujo")
        let flow = try XCTUnwrap(flows.first)
        XCTAssertEqual(flow.bytesOut, 900)
        XCTAssertEqual(flow.bytesIn, 2_500)
        XCTAssertEqual(flow.totalBytes, 3_400)
        XCTAssertEqual(flow.packetCount, 7)
        XCTAssertEqual(flow.lastSeen, PersistenceFixtures.date(40))
        XCTAssertEqual(flow.firstSeen, PersistenceFixtures.date(8), "first_seen conserva el mínimo visto")
        XCTAssertEqual(flow.tlsStatus, .inspected)
        XCTAssertEqual(flow.sni, "example.com")
    }

    func testUpsertAccumulatesCountersAcrossManyFlushes() async throws {
        let store = try makeStore()
        let remote = ModelFixtures.v4(1, 1, 1, 1)

        // Simula la tabla de flujos en memoria acumulando y volcando el estado agregado completo.
        var bytesOut: UInt64 = 0
        var packetCount: UInt64 = 0
        for i in 1...50 {
            bytesOut += 100
            packetCount += 1
            _ = try await store.upsertFlow(
                PersistenceFixtures.flow(
                    remote: remote, firstSeen: 1_000, lastSeen: 1_000 + UInt64(i),
                    bytesOut: bytesOut, packetCount: packetCount
                )
            )
        }

        let matched = try await store.flow(matching: PersistenceFixtures.key(remote: remote))
        let flow = try XCTUnwrap(matched)
        XCTAssertEqual(flow.bytesOut, 5_000)
        XCTAssertEqual(flow.packetCount, 50)
        XCTAssertEqual(flow.lastSeen, PersistenceFixtures.date(1_050))
    }

    func testDifferentTupleProducesDistinctFlows() async throws {
        let store = try makeStore()
        _ = try await store.upsertFlow(
            PersistenceFixtures.flow(remote: ModelFixtures.v4(1, 1, 1, 1), firstSeen: 1, lastSeen: 2)
        )
        _ = try await store.upsertFlow(
            PersistenceFixtures.flow(remote: ModelFixtures.v4(2, 2, 2, 2), firstSeen: 1, lastSeen: 2)
        )
        // Mismo par de IPs pero UDP en lugar de TCP: otra 5-tupla.
        _ = try await store.upsertFlow(
            PersistenceFixtures.flow(
                remote: ModelFixtures.v4(1, 1, 1, 1), proto: .udp, firstSeen: 1, lastSeen: 2
            )
        )
        let flows = try await store.recentFlows(limit: 10)
        XCTAssertEqual(flows.count, 3)
    }

    /// Los puertos efímeros se reciclan: la misma 5-tupla en dos sesiones de captura son dos
    /// conexiones distintas, y fusionarlas inventaría una duración que abarca ambas.
    func testSameTupleInAnotherSessionIsADistinctFlow() async throws {
        let remote = ModelFixtures.v4(93, 184, 216, 34)
        let firstID: Int64
        do {
            let first = try makeStore()
            firstID = try await first.upsertFlow(
                PersistenceFixtures.flow(remote: remote, firstSeen: 1, lastSeen: 2)
            )
        }
        // Sesión siguiente: otra ancla ⇒ otro discriminador de sesión.
        let second = try makeStore(
            anchor: MonotonicAnchor(
                uptimeNanoseconds: 1_000_000_000,
                wallClock: PersistenceFixtures.anchorWallClock.addingTimeInterval(3_600)
            )
        )
        let secondID = try await second.upsertFlow(
            PersistenceFixtures.flow(remote: remote, firstSeen: 1, lastSeen: 2)
        )

        XCTAssertNotEqual(firstID, secondID)
        let flows = try await second.recentFlows(limit: 10)
        XCTAssertEqual(flows.count, 2)
        // `flow(matching:)` devuelve el más reciente de los dos.
        let matched = try await second.flow(matching: PersistenceFixtures.key(remote: remote))
        XCTAssertEqual(matched?.id, secondID)
    }

    /// Releer por id y releer por tupla **no** son lo mismo, y esa diferencia es la razón de que el
    /// segundo exista: con los puertos efímeros reciclados, la misma 5-tupla tiene varias filas y por
    /// clave sale la última. Una pantalla abierta sobre una conexión concreta que preguntase por clave
    /// se encontraría enseñando otra.
    func testReadingAFlowByIdReturnsThatOneAndNotTheMostRecentOfItsTuple() async throws {
        let remote = ModelFixtures.v4(9, 9, 9, 9)
        let key = PersistenceFixtures.key(remote: remote)

        let firstID: Int64
        do {
            let first = try makeStore()
            firstID = try await first.upsertFlow(
                PersistenceFixtures.flow(remote: remote, firstSeen: 1, lastSeen: 2, bytesOut: 100)
            )
        }
        // Sesión siguiente: la misma 5-tupla vuelve a salir, y es otra conexión.
        let second = try makeStore(
            anchor: MonotonicAnchor(
                uptimeNanoseconds: 1_000_000_000,
                wallClock: PersistenceFixtures.anchorWallClock.addingTimeInterval(3_600)
            )
        )
        let secondID = try await second.upsertFlow(
            PersistenceFixtures.flow(remote: remote, firstSeen: 1, lastSeen: 2, bytesOut: 900)
        )
        XCTAssertNotEqual(firstID, secondID)

        let byKey = try await second.flow(matching: key)
        XCTAssertEqual(byKey?.id, secondID, "por clave sale la más reciente de la tupla")

        let reread = try await second.flow(id: firstID)
        let byID = try XCTUnwrap(reread)
        XCTAssertEqual(byID.id, firstID, "por id sale la que se pidió, que es la que la pantalla mira")
        XCTAssertEqual(byID.bytesOut, 100)
    }

    func testReadingAFlowThatRetentionTookIsNotAFailure() async throws {
        let store = try makeStore()
        let id = try await store.upsertFlow(
            PersistenceFixtures.flow(remote: ModelFixtures.v4(1, 2, 3, 4), firstSeen: 1, lastSeen: 2)
        )
        try await store.clearAll()

        // `nil` y no un error: una conexión que ya no está es lo normal en cuanto la retención corta,
        // y la pantalla que la miraba tiene que poder distinguirlo de una consulta que falló.
        let gone = try await store.flow(id: id)
        XCTAssertNil(gone)
    }

    // MARK: - Paquetes

    func testAppendAndReadPacketsOrderedByTimestamp() async throws {
        let store = try makeStore()
        let remote = ModelFixtures.v4(93, 184, 216, 34)
        let key = PersistenceFixtures.key(remote: remote)
        let flowID = try await store.upsertFlow(
            PersistenceFixtures.flow(remote: remote, firstSeen: 1, lastSeen: 3)
        )

        // Se insertan desordenados; la lectura debe devolverlos por `ts` ascendente.
        let metas = [3, 1, 2].map { ts in
            PersistenceFixtures.packet(timestamp: UInt64(ts), key: key, length: UInt32(ts))
        }
        try await store.appendPackets(metas, flowID: flowID)

        let read = try await store.packets(forFlow: flowID, limit: 10)
        XCTAssertEqual(read.map(\.date), [1, 2, 3].map(PersistenceFixtures.date))
        XCTAssertEqual(read.map(\.length), [1, 2, 3])
        // La FlowKey se reconstruye por join con `flows`.
        XCTAssertEqual(read.first?.flowKey, key)
        // Cada paquete trae su rowid, que es la identidad estable para la lista de la UI.
        XCTAssertEqual(Set(read.map(\.id)).count, 3)
    }

    func testAppendPacketsRoundTripsMetadata() async throws {
        let store = try makeStore()
        let remote = ModelFixtures.v4(93, 184, 216, 34)
        let key = PersistenceFixtures.key(remote: remote)
        let flowID = try await store.upsertFlow(
            PersistenceFixtures.flow(remote: remote, firstSeen: 1, lastSeen: 3)
        )
        let meta = PersistenceFixtures.packet(
            timestamp: 12, key: key, direction: .inbound,
            length: 1_420, tcpFlags: [.syn, .ack],
            capture: CaptureLocation(fileSequence: 5, recordOffset: 987_654)
        )
        try await store.appendPackets([meta], flowID: flowID)

        let readPackets = try await store.packets(forFlow: flowID, limit: 10)
        let read = try XCTUnwrap(readPackets.first)
        XCTAssertEqual(read.date, PersistenceFixtures.date(12))
        XCTAssertEqual(read.direction, .inbound)
        XCTAssertEqual(read.length, 1_420)
        XCTAssertEqual(read.tcpFlags, [.syn, .ack])
        XCTAssertEqual(read.capture, CaptureLocation(fileSequence: 5, recordOffset: 987_654))
    }

    /// Un paquete sin captura vuelve sin localización, no con una que apunte al fichero 0: el
    /// centinela es el offset, y el store lo respeta en los dos sentidos.
    func testPacketWithoutCaptureReadsBackWithoutLocation() async throws {
        let store = try makeStore()
        let remote = ModelFixtures.v4(93, 184, 216, 34)
        let key = PersistenceFixtures.key(remote: remote)
        let flowID = try await store.upsertFlow(
            PersistenceFixtures.flow(remote: remote, firstSeen: 1, lastSeen: 3)
        )
        try await store.appendPackets(
            [PersistenceFixtures.packet(timestamp: 12, key: key, capture: nil)],
            flowID: flowID
        )

        let read = try await store.packets(forFlow: flowID, limit: 10)
        XCTAssertNil(try XCTUnwrap(read.first).capture)
    }

    /// Lo que el escritor de capturas consulta al arrancar para no reutilizar la secuencia de un
    /// fichero que ya no está en disco pero que el historial sigue apuntando.
    func testHighestCaptureFileSequenceIgnoresPacketsWithoutCapture() async throws {
        let store = try makeStore()
        let remote = ModelFixtures.v4(93, 184, 216, 34)
        let key = PersistenceFixtures.key(remote: remote)
        let flowID = try await store.upsertFlow(
            PersistenceFixtures.flow(remote: remote, firstSeen: 1, lastSeen: 3)
        )

        var highest = try await store.highestCaptureFileSequence()
        XCTAssertNil(highest, "sin paquetes guardados no hay ningún fichero referenciado")

        try await store.appendPackets(
            [
                PersistenceFixtures.packet(
                    timestamp: 12, key: key,
                    capture: CaptureLocation(fileSequence: 4, recordOffset: 24)
                ),
                PersistenceFixtures.packet(
                    timestamp: 13, key: key,
                    capture: CaptureLocation(fileSequence: 2, recordOffset: 24)
                ),
                // Sin captura: su columna de fichero vale 0 sin significar nada, así que no puede
                // arrastrar el máximo hacia abajo ni contar como referencia.
                PersistenceFixtures.packet(timestamp: 14, key: key, capture: nil),
            ],
            flowID: flowID
        )

        highest = try await store.highestCaptureFileSequence()
        XCTAssertEqual(highest, 4)
    }

    func testAppendEmptyBatchIsNoOp() async throws {
        let store = try makeStore()
        let remote = ModelFixtures.v4(93, 184, 216, 34)
        let flowID = try await store.upsertFlow(
            PersistenceFixtures.flow(remote: remote, firstSeen: 1, lastSeen: 2)
        )
        try await store.appendPackets([], flowID: flowID)
        let packets = try await store.packets(forFlow: flowID, limit: 10)
        XCTAssertTrue(packets.isEmpty)
    }

    // MARK: - Actividad por intervalo (eje de la Timeline)

    /// Escribe un flujo y sus paquetes en los segundos indicados. Devuelve la clave del flujo.
    @discardableResult
    private func writePackets(
        to store: FlowStore, remote: IPAddress, at seconds: [UInt64]
    ) async throws -> FlowKey {
        let key = PersistenceFixtures.key(remote: remote)
        let flowID = try await store.upsertFlow(
            PersistenceFixtures.flow(
                remote: remote, firstSeen: seconds.min() ?? 0, lastSeen: seconds.max() ?? 0
            )
        )
        try await store.appendPackets(
            seconds.map { PersistenceFixtures.packet(timestamp: $0, key: key) },
            flowID: flowID
        )
        return key
    }

    func testPacketTimeBoundsIsNilWithoutPackets() async throws {
        let store = try makeStore()
        // Un flujo sin paquetes tampoco da extensión: lo que el eje mide son paquetes.
        _ = try await store.upsertFlow(
            PersistenceFixtures.flow(remote: ModelFixtures.v4(1, 1, 1, 1), firstSeen: 1, lastSeen: 2)
        )
        let bounds = try await store.packetTimeBounds()
        XCTAssertNil(bounds)
    }

    func testPacketTimeBoundsSpansEveryFlow() async throws {
        let store = try makeStore()
        try await writePackets(to: store, remote: ModelFixtures.v4(1, 1, 1, 1), at: [30, 90])
        try await writePackets(to: store, remote: ModelFixtures.v4(2, 2, 2, 2), at: [10, 50])

        let measured = try await store.packetTimeBounds()
        let bounds = try XCTUnwrap(measured)
        XCTAssertEqual(bounds.lowerBound, PersistenceFixtures.date(10))
        XCTAssertEqual(bounds.upperBound, PersistenceFixtures.date(90))
    }

    /// Las cuentas son de **paquetes**, agrupados por intervalo, y atraviesan los flujos: dos
    /// conexiones distintas dentro del mismo intervalo suman en la misma barra.
    func testPacketCountsGroupsAcrossFlows() async throws {
        let store = try makeStore()
        try await writePackets(to: store, remote: ModelFixtures.v4(1, 1, 1, 1), at: [0, 1, 2])
        try await writePackets(to: store, remote: ModelFixtures.v4(2, 2, 2, 2), at: [3, 20])

        let counts = try await store.packetCounts(
            in: PersistenceFixtures.date(0)...PersistenceFixtures.date(30),
            bucketDuration: 10
        )
        XCTAssertEqual(
            counts,
            [
                PacketBucket(start: PersistenceFixtures.date(0), packetCount: 4),
                PacketBucket(start: PersistenceFixtures.date(20), packetCount: 1),
            ]
        )
    }

    /// Solo vuelven los intervalos con paquetes: el hueco entre el segundo 0 y el 20 no aparece, y
    /// rellenarlo a cero es de quien dibuja, que es el único que sabe cuántas barras caben.
    func testPacketCountsOmitsEmptyIntervals() async throws {
        let store = try makeStore()
        try await writePackets(to: store, remote: ModelFixtures.v4(1, 1, 1, 1), at: [0, 25])

        let counts = try await store.packetCounts(
            in: PersistenceFixtures.date(0)...PersistenceFixtures.date(30),
            bucketDuration: 5
        )
        XCTAssertEqual(counts.map(\.packetCount), [1, 1])
        XCTAssertEqual(
            counts.map(\.start),
            [PersistenceFixtures.date(0), PersistenceFixtures.date(25)]
        )
    }

    /// Los intervalos se alinean con el principio del rango, no con el epoch: pedir desde el
    /// segundo 3 hace que la primera barra empiece ahí.
    func testPacketCountsAlignsBucketsToTheRangeStart() async throws {
        let store = try makeStore()
        try await writePackets(to: store, remote: ModelFixtures.v4(1, 1, 1, 1), at: [3, 4, 13])

        let counts = try await store.packetCounts(
            in: PersistenceFixtures.date(3)...PersistenceFixtures.date(20),
            bucketDuration: 10
        )
        XCTAssertEqual(
            counts,
            [
                PacketBucket(start: PersistenceFixtures.date(3), packetCount: 2),
                PacketBucket(start: PersistenceFixtures.date(13), packetCount: 1),
            ]
        )
    }

    /// Lo que cae fuera del rango no se cuenta, y los extremos entran (el rango es cerrado).
    func testPacketCountsHonoursTheRangeBounds() async throws {
        let store = try makeStore()
        try await writePackets(to: store, remote: ModelFixtures.v4(1, 1, 1, 1), at: [0, 10, 20, 30])

        let counts = try await store.packetCounts(
            in: PersistenceFixtures.date(10)...PersistenceFixtures.date(20),
            bucketDuration: 100
        )
        XCTAssertEqual(counts.map(\.packetCount), [2])
    }

    func testPacketCountsIsEmptyWithoutPackets() async throws {
        let store = try makeStore()
        let counts = try await store.packetCounts(
            in: PersistenceFixtures.date(0)...PersistenceFixtures.date(60),
            bucketDuration: 10
        )
        XCTAssertTrue(counts.isEmpty)
    }

    /// El eje no honra ningún filtro: cuenta también los paquetes de conexiones que la lista
    /// esconde. Es la contrapartida de que el filtro de host se aplique en memoria, y por eso la
    /// pantalla lo dice.
    func testPacketCountsIgnoresProtocolAndStatus() async throws {
        let store = try makeStore()
        let udp = ModelFixtures.v4(2, 2, 2, 2)
        let udpKey = PersistenceFixtures.key(remote: udp, proto: .udp)
        let udpID = try await store.upsertFlow(
            PersistenceFixtures.flow(
                remote: udp, proto: .udp, firstSeen: 0, lastSeen: 1, tlsStatus: .plaintext
            )
        )
        try await store.appendPackets(
            [PersistenceFixtures.packet(timestamp: 1, key: udpKey)], flowID: udpID
        )
        try await writePackets(to: store, remote: ModelFixtures.v4(1, 1, 1, 1), at: [2])

        let counts = try await store.packetCounts(
            in: PersistenceFixtures.date(0)...PersistenceFixtures.date(10),
            bucketDuration: 10
        )
        XCTAssertEqual(counts.map(\.packetCount), [2])
    }

    /// `prune` se lleva los paquetes por cascade, así que el eje encoge con la retención en vez de
    /// seguir dibujando un pasado que ya no está guardado.
    func testPacketCountsFollowsPrune() async throws {
        let store = try makeStore()
        try await writePackets(to: store, remote: ModelFixtures.v4(1, 1, 1, 1), at: [0, 1])
        try await writePackets(to: store, remote: ModelFixtures.v4(2, 2, 2, 2), at: [100, 101])

        _ = try await store.prune(before: PersistenceFixtures.date(50))

        let remaining = try await store.packetTimeBounds()
        let bounds = try XCTUnwrap(remaining)
        XCTAssertEqual(bounds.lowerBound, PersistenceFixtures.date(100))
        let counts = try await store.packetCounts(in: bounds, bucketDuration: 10)
        XCTAssertEqual(counts.map(\.packetCount), [2])
    }

    // MARK: - Paginación y orden de flujos

    func testRecentFlowsPaginationWithCursor() async throws {
        let store = try makeStore()
        // Cinco flujos con last_seen crecientes.
        for i in 1...5 {
            _ = try await store.upsertFlow(
                PersistenceFixtures.flow(
                    remote: ModelFixtures.v4(10, 0, 0, UInt8(100 + i)),
                    firstSeen: 0, lastSeen: UInt64(i * 10)
                )
            )
        }
        let firstPage = try await store.recentFlows(limit: 2)
        XCTAssertEqual(
            firstPage.map(\.lastSeen), [50, 40].map(PersistenceFixtures.date), "más recientes primero"
        )

        let cursor = FlowCursor(after: try XCTUnwrap(firstPage.last))
        let secondPage = try await store.recentFlows(limit: 2, before: cursor)
        XCTAssertEqual(secondPage.map(\.lastSeen), [30, 20].map(PersistenceFixtures.date))

        let thirdPage = try await store.recentFlows(
            limit: 2, before: FlowCursor(after: try XCTUnwrap(secondPage.last))
        )
        XCTAssertEqual(thirdPage.map(\.lastSeen), [10].map(PersistenceFixtures.date))
    }

    /// Varios flujos pueden compartir `last_seen`. Sin el desempate por `id`, la página siguiente
    /// repetiría o se saltaría filas justo en el corte.
    func testCursorBreaksTiesByRowID() async throws {
        let store = try makeStore()
        var ids: [Int64] = []
        for i in 1...4 {
            ids.append(
                try await store.upsertFlow(
                    PersistenceFixtures.flow(
                        remote: ModelFixtures.v4(10, 0, 0, UInt8(i)), firstSeen: 0, lastSeen: 7
                    )
                )
            )
        }
        let expected = ids.sorted(by: >)   // mismo last_seen ⇒ orden por id descendente

        let firstPage = try await store.recentFlows(limit: 2)
        XCTAssertEqual(firstPage.map(\.id), Array(expected[0..<2]))

        let secondPage = try await store.recentFlows(
            limit: 2, before: FlowCursor(after: try XCTUnwrap(firstPage.last))
        )
        XCTAssertEqual(secondPage.map(\.id), Array(expected[2..<4]))
    }

    func testFlowMatchingReturnsNilWhenAbsent() async throws {
        let store = try makeStore()
        let missing = PersistenceFixtures.key(remote: ModelFixtures.v4(8, 8, 8, 8))
        let match = try await store.flow(matching: missing)
        XCTAssertNil(match)
    }

    // MARK: - Prune y tamaño

    func testPruneDeletesOldFlowsAndCascadesPackets() async throws {
        let store = try makeStore()
        let oldRemote = ModelFixtures.v4(1, 1, 1, 1)
        let newRemote = ModelFixtures.v4(2, 2, 2, 2)
        let oldKey = PersistenceFixtures.key(remote: oldRemote)

        let oldID = try await store.upsertFlow(
            PersistenceFixtures.flow(remote: oldRemote, firstSeen: 1, lastSeen: 10)
        )
        let newID = try await store.upsertFlow(
            PersistenceFixtures.flow(remote: newRemote, firstSeen: 1, lastSeen: 50)
        )
        try await store.appendPackets(
            [PersistenceFixtures.packet(timestamp: 5, key: oldKey)], flowID: oldID
        )

        let deleted = try await store.prune(before: PersistenceFixtures.date(20))
        XCTAssertEqual(deleted, 1, "solo el flujo cuyo last_seen es anterior al corte")

        let remaining = try await store.recentFlows(limit: 10)
        XCTAssertEqual(remaining.map(\.id), [newID])
        // El cascade borró los paquetes del flujo eliminado.
        let oldPackets = try await store.packets(forFlow: oldID, limit: 10)
        XCTAssertTrue(oldPackets.isEmpty)
    }

    func testTotalBytesOnDiskGrowsWithData() async throws {
        let store = try makeStore()
        let empty = try await store.totalBytesOnDisk()
        XCTAssertGreaterThan(empty, 0, "la BD migrada ocupa espacio en disco")

        let remote = ModelFixtures.v4(93, 184, 216, 34)
        let key = PersistenceFixtures.key(remote: remote)
        let flowID = try await store.upsertFlow(
            PersistenceFixtures.flow(remote: remote, firstSeen: 1, lastSeen: 2)
        )
        let metas = (0..<500).map {
            PersistenceFixtures.packet(timestamp: UInt64($0), key: key)
        }
        try await store.appendPackets(metas, flowID: flowID)

        let after = try await store.totalBytesOnDisk()
        XCTAssertGreaterThanOrEqual(after, empty)
    }

    func testFlowCountCountsWhatIsStoredAndFollowsWhatIsDeleted() async throws {
        let store = try makeStore()
        let empty = try await store.flowCount()
        XCTAssertEqual(empty, 0, "una BD recién migrada no tiene conexiones")

        try await store.upsertFlow(
            PersistenceFixtures.flow(remote: ModelFixtures.v4(1, 1, 1, 1), firstSeen: 1, lastSeen: 10)
        )
        try await store.upsertFlow(
            PersistenceFixtures.flow(remote: ModelFixtures.v4(2, 2, 2, 2), firstSeen: 1, lastSeen: 50)
        )
        let both = try await store.flowCount()
        XCTAssertEqual(both, 2)

        // El upsert agrega sobre la fila que ya existe: no es una conexión nueva.
        try await store.upsertFlow(
            PersistenceFixtures.flow(remote: ModelFixtures.v4(1, 1, 1, 1), firstSeen: 1, lastSeen: 20)
        )
        let afterUpsert = try await store.flowCount()
        XCTAssertEqual(afterUpsert, 2)

        try await store.prune(before: PersistenceFixtures.date(30))
        let afterPrune = try await store.flowCount()
        XCTAssertEqual(afterPrune, 1, "es la cifra que Ajustes enseña tras una limpieza")

        try await store.clearAll()
        let afterClear = try await store.flowCount()
        XCTAssertEqual(afterClear, 0)
    }

    func testClearAllRemovesEverything() async throws {
        let store = try makeStore()
        let remote = ModelFixtures.v4(93, 184, 216, 34)
        let key = PersistenceFixtures.key(remote: remote)
        let flowID = try await store.upsertFlow(
            PersistenceFixtures.flow(remote: remote, firstSeen: 1, lastSeen: 2)
        )
        try await store.appendPackets(
            [PersistenceFixtures.packet(timestamp: 1, key: key)], flowID: flowID
        )

        try await store.clearAll()
        let flows = try await store.recentFlows(limit: 10)
        let packets = try await store.packets(forFlow: flowID, limit: 10)
        XCTAssertTrue(flows.isEmpty)
        XCTAssertTrue(packets.isEmpty)
    }

    // MARK: - Concurrencia (WAL)

    func testConcurrentWritesAndReadsDoNotError() async throws {
        let store = try makeStore()

        // Un "productor" (extensión) escribe flujos y paquetes mientras un "consumidor" (app)
        // lee en paralelo. Con WAL, lecturas y escritura conviven sin error.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for i in 0..<100 {
                    let remote = ModelFixtures.v4(10, 0, UInt8(i / 256), UInt8(i % 256))
                    let id = try await store.upsertFlow(
                        PersistenceFixtures.flow(
                            remote: remote, firstSeen: UInt64(i), lastSeen: UInt64(i),
                            bytesOut: UInt64(i * 10), packetCount: UInt64(i)
                        )
                    )
                    try await store.appendPackets(
                        [
                            PersistenceFixtures.packet(
                                timestamp: UInt64(i), key: PersistenceFixtures.key(remote: remote)
                            )
                        ],
                        flowID: id
                    )
                }
            }
            group.addTask {
                for _ in 0..<100 {
                    _ = try await store.recentFlows(limit: 20)
                }
            }
            try await group.waitForAll()
        }

        let all = try await store.recentFlows(limit: 1_000)
        XCTAssertEqual(all.count, 100)
    }
}
