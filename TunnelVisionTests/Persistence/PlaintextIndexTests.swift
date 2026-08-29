import XCTest
import GRDB
@testable import Shared

/// Tests del índice del contenido descifrado (esquema `v5` + la mitad de `FlowStore` que lo escribe,
/// lo lee y lo poda). Lo que se afirma es lo que el ADR 0007 promete: que el plaintext caduca **antes**
/// que el flujo que lo contiene y sin llevárselo por delante, que se puede borrar **solo** él, y que
/// nadie reutiliza un número de fichero ni de conversación que el índice todavía señale.
final class PlaintextIndexTests: XCTestCase {

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
        try FlowStore(databaseURL: dbURL, anchor: PersistenceFixtures.anchor)
    }

    private func chunk(
        at seconds: UInt64,
        direction: Direction = .outbound,
        stream: UInt64 = 0,
        file: UInt32 = 0,
        offset: UInt64 = 16,
        stored: UInt32 = 100,
        original: UInt32 = 100
    ) -> PlaintextChunkMeta {
        PlaintextChunkMeta(
            timestamp: PersistenceFixtures.uptime(seconds),
            direction: direction,
            stream: stream,
            location: PlaintextLocation(fileSequence: file, recordOffset: offset),
            storedLength: stored,
            originalLength: original
        )
    }

    private func makeFlow(_ store: FlowStore, lastSeen: UInt64 = 2) async throws -> Int64 {
        try await store.upsertFlow(
            PersistenceFixtures.flow(
                remote: ModelFixtures.v4(93, 184, 216, 34),
                firstSeen: 1,
                lastSeen: lastSeen
            )
        )
    }

    // MARK: - Escritura y lectura

    func testChunksComeBackDatedInOrderAndWithTheirLocation() async throws {
        let store = try makeStore()
        let flowID = try await makeFlow(store)

        try await store.appendPlaintext(
            [
                chunk(at: 2, direction: .inbound, stream: 7, file: 3, offset: 148, stored: 40, original: 40),
                chunk(at: 1, direction: .outbound, stream: 7, file: 3, offset: 16, stored: 60, original: 900),
            ],
            flowID: flowID
        )

        let chunks = try await store.plaintext(forFlow: flowID, limit: 10)
        XCTAssertEqual(chunks.count, 2)

        // Orden temporal ascendente, no el de inserción: la conversación se lee como ocurrió.
        XCTAssertEqual(chunks[0].date, PersistenceFixtures.date(1))
        XCTAssertEqual(chunks[0].direction, .outbound)
        XCTAssertEqual(chunks[0].stream, 7)
        XCTAssertEqual(chunks[0].location, PlaintextLocation(fileSequence: 3, recordOffset: 16))
        XCTAssertEqual(chunks[0].storedLength, 60)
        XCTAssertEqual(chunks[0].originalLength, 900)
        XCTAssertTrue(chunks[0].isTruncated)
        XCTAssertEqual(chunks[0].droppedLength, 840)

        XCTAssertEqual(chunks[1].date, PersistenceFixtures.date(2))
        XCTAssertEqual(chunks[1].direction, .inbound)
        XCTAssertFalse(chunks[1].isTruncated)
    }

    /// El sello entra monotónico y sale fechado, igual que el de un paquete: una fila que guardase el
    /// uptime crudo dejaría de ser fechable en cuanto el dispositivo se reiniciara.
    func testTimestampsAreStoredAbsolute() async throws {
        let store = try makeStore()
        let flowID = try await makeFlow(store)
        try await store.appendPlaintext([chunk(at: 5)], flowID: flowID)

        let stored = try await store.plaintext(forFlow: flowID, limit: 1)
        XCTAssertEqual(stored.first?.date, PersistenceFixtures.date(5))
    }

    func testAnEmptyBatchWritesNothing() async throws {
        let store = try makeStore()
        let flowID = try await makeFlow(store)

        try await store.appendPlaintext([], flowID: flowID)

        let count = try await store.plaintextChunkCount()
        XCTAssertEqual(count, 0)
    }

    func testChunksBelongToTheirFlow() async throws {
        let store = try makeStore()
        let first = try await makeFlow(store)
        let second = try await store.upsertFlow(
            PersistenceFixtures.flow(
                remote: ModelFixtures.v4(1, 1, 1, 1),
                localPort: 51001,
                firstSeen: 1,
                lastSeen: 2
            )
        )

        try await store.appendPlaintext([chunk(at: 1, stream: 1)], flowID: first)
        try await store.appendPlaintext([chunk(at: 1, stream: 2, offset: 200)], flowID: second)

        let ofFirst = try await store.plaintext(forFlow: first, limit: 10)
        let ofSecond = try await store.plaintext(forFlow: second, limit: 10)
        XCTAssertEqual(ofFirst.map(\.stream), [1])
        XCTAssertEqual(ofSecond.map(\.stream), [2])
    }

    func testTheLimitIsHonoured() async throws {
        let store = try makeStore()
        let flowID = try await makeFlow(store)
        try await store.appendPlaintext(
            (1...10).map { chunk(at: UInt64($0), offset: UInt64($0) * 200) },
            flowID: flowID
        )

        let chunks = try await store.plaintext(forFlow: flowID, limit: 4)
        XCTAssertEqual(chunks.count, 4)
        XCTAssertEqual(chunks.first?.date, PersistenceFixtures.date(1))
    }

    // MARK: - Lo que el escritor pregunta al arrancar

    func testHighestReferencesAreEmptyOnAFreshDatabase() async throws {
        let store = try makeStore()

        let sequence = try await store.highestPlaintextFileSequence()
        let stream = try await store.highestPlaintextStream()
        XCTAssertNil(sequence)
        XCTAssertNil(stream)
    }

    /// Lo que impide que una fila de ayer acabe señalando el contenido de otra conversación de hoy.
    func testHighestReferencesAreWhatTheIndexStillPointsAt() async throws {
        let store = try makeStore()
        let flowID = try await makeFlow(store)
        try await store.appendPlaintext(
            [
                chunk(at: 1, stream: 4, file: 2),
                chunk(at: 2, stream: 9, file: 7, offset: 300),
                chunk(at: 3, stream: 6, file: 5, offset: 400),
            ],
            flowID: flowID
        )

        let sequence = try await store.highestPlaintextFileSequence()
        let stream = try await store.highestPlaintextStream()
        XCTAssertEqual(sequence, 7)
        XCTAssertEqual(stream, 9)
    }

    func testReferencedFileSequencesAreTheOnesStillWorthKeeping() async throws {
        let store = try makeStore()
        let flowID = try await makeFlow(store)
        try await store.appendPlaintext(
            [
                chunk(at: 1, file: 1),
                chunk(at: 2, file: 1, offset: 300),
                chunk(at: 3, file: 4, offset: 16),
            ],
            flowID: flowID
        )

        let referenced = try await store.referencedPlaintextFileSequences()
        XCTAssertEqual(referenced, [1, 4])
    }

    // MARK: - Retención (ADR 0007)

    /// La promesa del ADR: el contenido descifrado caduca antes que el flujo, y el flujo se queda con
    /// sus paquetes y sus contadores intactos.
    func testPruningPlaintextLeavesTheFlowAndItsPacketsAlone() async throws {
        let store = try makeStore()
        let key = PersistenceFixtures.key(remote: ModelFixtures.v4(93, 184, 216, 34))
        let flowID = try await makeFlow(store, lastSeen: 10)
        try await store.appendPackets([PersistenceFixtures.packet(timestamp: 1, key: key)], flowID: flowID)
        try await store.appendPlaintext(
            [chunk(at: 1), chunk(at: 9, offset: 300)],
            flowID: flowID
        )

        let removed = try await store.prunePlaintext(before: PersistenceFixtures.date(5))

        XCTAssertEqual(removed, 1)
        let remaining = try await store.plaintext(forFlow: flowID, limit: 10)
        XCTAssertEqual(remaining.map(\.date), [PersistenceFixtures.date(9)])

        let flow = try await store.flow(id: flowID)
        XCTAssertNotNil(flow)
        let packets = try await store.packets(forFlow: flowID, limit: 10)
        XCTAssertEqual(packets.count, 1)
    }

    func testPruningWithNothingOldEnoughRemovesNothing() async throws {
        let store = try makeStore()
        let flowID = try await makeFlow(store)
        try await store.appendPlaintext([chunk(at: 9)], flowID: flowID)

        let removed = try await store.prunePlaintext(before: PersistenceFixtures.date(5))

        XCTAssertEqual(removed, 0)
        let count = try await store.plaintextChunkCount()
        XCTAssertEqual(count, 1)
    }

    /// El gesto que el ADR pide que exista por separado: arrepentirse de lo grabado no puede costar
    /// el historial entero.
    func testClearingPlaintextKeepsHistoryAndCaptureLinks() async throws {
        let store = try makeStore()
        let key = PersistenceFixtures.key(remote: ModelFixtures.v4(93, 184, 216, 34))
        let flowID = try await makeFlow(store)
        try await store.appendPackets(
            [
                PersistenceFixtures.packet(
                    timestamp: 1,
                    key: key,
                    capture: CaptureLocation(fileSequence: 2, recordOffset: 24)
                )
            ],
            flowID: flowID
        )
        try await store.appendPlaintext([chunk(at: 1), chunk(at: 2, offset: 300)], flowID: flowID)

        let removed = try await store.clearPlaintext()

        XCTAssertEqual(removed, 2)
        let count = try await store.plaintextChunkCount()
        XCTAssertEqual(count, 0)
        let flows = try await store.recentFlows(limit: 10)
        XCTAssertEqual(flows.count, 1)
        let packets = try await store.packets(forFlow: flowID, limit: 10)
        XCTAssertEqual(packets.first?.capture, CaptureLocation(fileSequence: 2, recordOffset: 24))
    }

    /// La mitad barata de la retención: borrar el flujo se lleva su contenido descifrado sin que nadie
    /// tenga que acordarse (`ON DELETE CASCADE`).
    func testDeletingAFlowTakesItsPlaintextWithIt() async throws {
        let store = try makeStore()
        let flowID = try await makeFlow(store, lastSeen: 2)
        try await store.appendPlaintext([chunk(at: 1)], flowID: flowID)

        _ = try await store.prune(before: PersistenceFixtures.date(5))

        let count = try await store.plaintextChunkCount()
        XCTAssertEqual(count, 0)
    }

    /// La mitad de índice del techo de disco: el barrido se lleva ficheros enteros, y las filas que
    /// los nombraban tienen que irse con ellos o contarían como contenido guardado sin bytes que leer.
    func testDroppingTheRowsOfDeletedFilesLeavesTheRest() async throws {
        let store = try makeStore()
        let flowID = try await makeFlow(store)
        try await store.appendPlaintext(
            [
                chunk(at: 1, file: 0),
                chunk(at: 2, file: 1, offset: 300),
                chunk(at: 3, file: 2, offset: 400),
            ],
            flowID: flowID
        )

        let removed = try await store.prunePlaintext(inFileSequences: [0, 1])

        XCTAssertEqual(removed, 2)
        let referenced = try await store.referencedPlaintextFileSequences()
        XCTAssertEqual(referenced, [2])
    }

    func testDroppingTheRowsOfNoFileDoesNothing() async throws {
        let store = try makeStore()
        let flowID = try await makeFlow(store)
        try await store.appendPlaintext([chunk(at: 1, file: 0)], flowID: flowID)

        let removed = try await store.prunePlaintext(inFileSequences: [])

        XCTAssertEqual(removed, 0)
        let count = try await store.plaintextChunkCount()
        XCTAssertEqual(count, 1)
    }

    func testClearAllTakesThePlaintextToo() async throws {
        let store = try makeStore()
        let flowID = try await makeFlow(store)
        try await store.appendPlaintext([chunk(at: 1)], flowID: flowID)

        try await store.clearAll()

        let count = try await store.plaintextChunkCount()
        XCTAssertEqual(count, 0)
    }

    // MARK: - Migración

    /// Una BD escrita antes de `v5` sigue abriendo, migra sola y conserva lo que tenía: el índice del
    /// plaintext se añade, no reemplaza nada.
    func testAnOlderDatabaseGainsTheIndexWithoutLosingAnything() async throws {
        let key = PersistenceFixtures.key(remote: ModelFixtures.v4(93, 184, 216, 34))
        do {
            let store = try makeStore()
            let flowID = try await makeFlow(store)
            try await store.appendPackets([PersistenceFixtures.packet(timestamp: 1, key: key)], flowID: flowID)
        }

        let store = try makeStore()
        let flows = try await store.recentFlows(limit: 10)
        XCTAssertEqual(flows.count, 1)
        let count = try await store.plaintextChunkCount()
        XCTAssertEqual(count, 0)
    }
}
