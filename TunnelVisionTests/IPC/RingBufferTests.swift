import Foundation
import XCTest
import Shared

/// Tests del ring buffer SPSC (M5). Cubren: round-trip productor→consumidor en orden, límite `max`
/// del `drain`, desbordamiento que descarta y cuenta sin pisar slots no leídos, lectura de geometría
/// desde una cabecera existente, validación de cabecera (fichero ausente / magic inválido), reinicio
/// de índices al recrear el productor, y un bucle de estrés concurrente sin torn reads.
final class RingBufferTests: XCTestCase {

    private var url: URL!

    override func setUpWithError() throws {
        url = IPCFixtures.tempFile()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Round-trip

    func testRoundTripPreservesOrderAndData() throws {
        let producer = try RingBufferProducer(fileURL: url, slotCount: 1024)
        let consumer = try RingBufferConsumer(fileURL: url)
        defer { producer.close(); consumer.close() }

        let count = 500
        for i in 0..<count { producer.push(IPCFixtures.packed(UInt64(i))) }

        var drained: [PackedPacketMeta] = []
        while drained.count < count {
            let batch = consumer.drain(max: 64)
            if batch.isEmpty { break }
            drained.append(contentsOf: batch)
        }

        XCTAssertEqual(drained.count, count)
        XCTAssertEqual(drained.map(\.timestamp), (0..<UInt64(count)).map { $0 })
        XCTAssertEqual(drained[42], IPCFixtures.packed(42))   // registro completo intacto
        XCTAssertEqual(consumer.droppedCount(), 0)
    }

    func testDrainRespectsMaxBatch() throws {
        let producer = try RingBufferProducer(fileURL: url, slotCount: 16)
        let consumer = try RingBufferConsumer(fileURL: url)
        defer { producer.close(); consumer.close() }

        for i in 0..<10 { producer.push(IPCFixtures.packed(UInt64(i))) }

        let first = consumer.drain(max: 3)
        let second = consumer.drain(max: 3)
        let rest = consumer.drain(max: 100)

        XCTAssertEqual(first.map(\.timestamp), [0, 1, 2])
        XCTAssertEqual(second.map(\.timestamp), [3, 4, 5])
        XCTAssertEqual(rest.map(\.timestamp), [6, 7, 8, 9])
        XCTAssertTrue(consumer.drain(max: 10).isEmpty)
    }

    // MARK: - Desbordamiento

    func testOverflowDropsAndPreservesUnreadSlots() throws {
        let producer = try RingBufferProducer(fileURL: url, slotCount: 4)
        let consumer = try RingBufferConsumer(fileURL: url)
        defer { producer.close(); consumer.close() }

        for i in 0..<4 { producer.push(IPCFixtures.packed(UInt64(i))) }   // llena el ring
        producer.push(IPCFixtures.packed(100))                            // descartado
        producer.push(IPCFixtures.packed(101))                            // descartado

        XCTAssertEqual(consumer.droppedCount(), 2)
        // Los 4 primeros siguen intactos y en orden: el desbordamiento no pisa slots no leídos.
        XCTAssertEqual(consumer.drain(max: 10).map(\.timestamp), [0, 1, 2, 3])

        // Con espacio libre, los siguientes push vuelven a entrar; el contador de descartes no baja.
        producer.push(IPCFixtures.packed(200))
        producer.push(IPCFixtures.packed(201))
        XCTAssertEqual(consumer.droppedCount(), 2)
        XCTAssertEqual(consumer.drain(max: 10).map(\.timestamp), [200, 201])
    }

    // MARK: - Geometría y validación de cabecera

    func testConsumerReadsGeometryFromExistingRing() throws {
        // slotSize distinto del por defecto: el consumidor debe leer stride y capacidad de la cabecera.
        let producer = try RingBufferProducer(fileURL: url, slotCount: 16, slotSize: 64)
        defer { producer.close() }
        producer.push(IPCFixtures.packed(7))

        let consumer = try RingBufferConsumer(fileURL: url)
        defer { consumer.close() }
        XCTAssertEqual(consumer.drain(max: 10).map(\.timestamp), [7])
    }

    func testConsumerOnMissingFileThrowsMapFailed() {
        XCTAssertThrowsError(try RingBufferConsumer(fileURL: url)) { error in
            XCTAssertEqual(error as? IPCError, .mapFailed)
        }
    }

    func testConsumerOnBadMagicThrowsBadHeader() throws {
        // Fichero del tamaño de la cabecera pero con magic 0: cabecera incompatible.
        try Data(repeating: 0, count: 128).write(to: url)
        XCTAssertThrowsError(try RingBufferConsumer(fileURL: url)) { error in
            XCTAssertEqual(error as? IPCError, .badHeader)
        }
    }

    func testProducerReinitializesIndices() throws {
        let first = try RingBufferProducer(fileURL: url, slotCount: 8)
        for i in 0..<5 { first.push(IPCFixtures.packed(UInt64(i))) }
        first.close()

        // Un productor nuevo sobre el mismo fichero arranca una sesión limpia: head/tail vuelven a 0.
        let second = try RingBufferProducer(fileURL: url, slotCount: 8)
        let consumer = try RingBufferConsumer(fileURL: url)
        defer { second.close(); consumer.close() }

        XCTAssertTrue(consumer.drain(max: 10).isEmpty)
        second.push(IPCFixtures.packed(99))
        XCTAssertEqual(consumer.drain(max: 10).map(\.timestamp), [99])
    }

    // MARK: - Estrés concurrente

    func testConcurrentPushDrainHasNoTornReads() async throws {
        let total: UInt64 = 100_000
        let producer = try RingBufferProducer(fileURL: url, slotCount: 1024)
        let consumer = try RingBufferConsumer(fileURL: url)
        defer { producer.close(); consumer.close() }

        let producerTask = Task.detached(priority: .userInitiated) {
            for i in 0..<total { producer.push(IPCFixtures.packed(i)) }
        }

        let consumerTask = Task.detached(priority: .userInitiated) {
            () -> (received: UInt64, ordered: Bool, intact: Bool, maxValue: UInt64) in
            var received: UInt64 = 0
            var previous: Int64 = -1
            var ordered = true
            var intact = true
            var maxValue: UInt64 = 0
            // Termina cuando lo drenado más lo descartado cubre todo lo empujado.
            while received + consumer.droppedCount() < total {
                for record in consumer.drain(max: 512) {
                    if !IPCFixtures.isIntact(record) { intact = false }
                    if Int64(record.timestamp) <= previous { ordered = false }
                    previous = Int64(record.timestamp)
                    maxValue = Swift.max(maxValue, record.timestamp)
                    received &+= 1
                }
            }
            return (received, ordered, intact, maxValue)
        }

        await producerTask.value
        let result = await consumerTask.value

        XCTAssertTrue(result.intact, "se detectó una lectura a medias (torn read)")
        XCTAssertTrue(result.ordered, "los registros deben entregarse en orden estricto")
        XCTAssertEqual(result.received + consumer.droppedCount(), total)
        XCTAssertLessThan(result.maxValue, total)
    }
}
