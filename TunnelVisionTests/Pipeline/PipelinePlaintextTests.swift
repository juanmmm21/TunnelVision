import Foundation
import XCTest
import Shared

/// Tests del **cableado del contenido descifrado en el pipeline**: la mitad que convierte un trozo
/// suelto que llega del relay en bytes en un fichero y una fila que sabe volver a ellos.
///
/// Lo que aquí se afirma es lo que solo el pipeline puede contestar: que el trozo se escribe con la
/// conversación de **su** flujo, que su localización llega intacta a la fila, que el presupuesto por
/// sentido corta y cuenta lo que no cupo, que un flujo cerrado se lleva su presupuesto, y que un
/// disco lleno apaga esto sin tocar nada más. El formato y el presupuesto tienen sus propios tests
/// (`PlaintextWriterTests`, `PlaintextBudgetTests`), así que aquí no se vuelven a probar.
final class PipelinePlaintextTests: XCTestCase {

    private struct Harness {
        let pipeline: PacketPipeline
        let table: FlowTable
        let store: RecordingStore
        let plaintext: RecordingPlaintext
        let clock: ManualClock
        let anchor: MonotonicAnchor
    }

    /// Ancla de la sesión con una hora de pared fija: es lo que hace afirmable el instante absoluto
    /// que va al fichero, que si no dependería de cuándo se ejecuta el test.
    private static let wallClock = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeHarness(
        bytesPerDirection: Int = PlaintextBudget.defaultMaxBytesPerDirection,
        writesPlaintext: Bool = true
    ) -> Harness {
        let clock = ManualClock(1_000)
        let anchor = MonotonicAnchor(uptimeNanoseconds: 1_000, wallClock: Self.wallClock)
        let table = FlowTable(config: .init(), clock: clock)
        let store = RecordingStore()
        let plaintext = RecordingPlaintext()
        let pipeline = PacketPipeline(
            flowTable: table,
            liveFeed: RecordingLiveFeed(),
            capture: nil,
            plaintext: writesPlaintext ? plaintext : nil,
            store: store,
            clock: clock,
            config: .init(
                localIPv4: PipelineFixtures.localV4,
                tlsInspectionEnabled: true,
                captureEnabled: false,
                anchor: anchor,
                plaintextBytesPerDirection: bytesPerDirection
            )
        )
        return Harness(
            pipeline: pipeline, table: table, store: store,
            plaintext: plaintext, clock: clock, anchor: anchor
        )
    }

    /// Un flujo vivo en la tabla, que es el requisito para que un trozo tenga dónde colgarse.
    @discardableResult
    private func openFlow(_ h: Harness, localPort: UInt16 = 51000) async -> FlowKey {
        await h.pipeline.handle(
            packet: PipelineFixtures.tcpV4(localPort: localPort),
            protocolFamily: Int32(AF_INET)
        )
        return PipelineFixtures.tcpV4Key(localPort: localPort)
    }

    // MARK: - El camino completo de un trozo

    func testChunkIsWrittenAndIndexedAgainstItsFlow() async {
        let h = makeHarness()
        let key = await openFlow(h)

        await h.pipeline.observe(plaintext: Data("GET / HTTP/1.1".utf8), direction: .outbound, for: key)
        await h.pipeline.flush()

        let written = await h.plaintext.written
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(written[0].bytes, Data("GET / HTTP/1.1".utf8))
        XCTAssertEqual(written[0].direction, .outbound)

        // La fila del índice cuelga del mismo flujo que los paquetes y apunta a donde quedaron los
        // bytes: es toda la razón de ser de esta pieza.
        let chunks = await h.store.plaintext(for: key)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].location, written[0].location)
        XCTAssertEqual(chunks[0].stream, written[0].stream)
        XCTAssertEqual(chunks[0].storedLength, 14)
        XCTAssertEqual(chunks[0].originalLength, 14)
        XCTAssertFalse(chunks[0].isTruncated)
    }

    /// El fichero fecha en absoluto y la fila en monotónico, y las dos conversiones salen del **mismo
    /// ancla**: si no, el mismo trozo diría dos instantes distintos.
    func testChunkIsDatedAbsoluteOnDiskAndMonotonicInTheRow() async {
        let h = makeHarness()
        let key = await openFlow(h)
        h.clock.set(5_000)

        await h.pipeline.observe(plaintext: Data([0x01]), direction: .inbound, for: key)
        await h.pipeline.flush()

        let written = await h.plaintext.written
        let chunks = await h.store.plaintext(for: key)
        XCTAssertEqual(chunks[0].timestamp, 5_000)
        XCTAssertEqual(written[0].timestamp, h.anchor.nanosecondsSince1970(forUptime: 5_000))
    }

    /// Un flujo tiene **una** conversación, aunque hable muchas veces y en los dos sentidos: es lo
    /// que empareja sus registros dispersos dentro de un fichero que intercala flujos.
    func testOneStreamPerFlowAndOnePerFlow() async {
        let h = makeHarness()
        let first = await openFlow(h, localPort: 51000)
        let second = await openFlow(h, localPort: 51001)

        await h.pipeline.observe(plaintext: Data([0x01]), direction: .outbound, for: first)
        await h.pipeline.observe(plaintext: Data([0x02]), direction: .inbound, for: first)
        await h.pipeline.observe(plaintext: Data([0x03]), direction: .outbound, for: second)

        let opened = await h.plaintext.streamsOpened
        XCTAssertEqual(opened, 2)
        let written = await h.plaintext.written
        XCTAssertEqual(written[0].stream, written[1].stream)
        XCTAssertNotEqual(written[0].stream, written[2].stream)
    }

    // MARK: - El presupuesto

    /// Se guarda el principio y se cuenta lo que no cupo: el trozo que cabe a medias se recorta y su
    /// fila lo dice con las dos longitudes.
    func testBudgetKeepsTheBeginningAndTellsTheTruncation() async {
        let h = makeHarness(bytesPerDirection: 4)
        let key = await openFlow(h)

        await h.pipeline.observe(plaintext: Data([1, 2, 3, 4, 5, 6]), direction: .outbound, for: key)
        await h.pipeline.flush()

        let written = await h.plaintext.written
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(written[0].bytes, Data([1, 2, 3, 4]))

        let chunks = await h.store.plaintext(for: key)
        XCTAssertEqual(chunks[0].storedLength, 4)
        XCTAssertEqual(chunks[0].originalLength, 6)
        XCTAssertTrue(chunks[0].isTruncated)

        let stats = await h.pipeline.stats
        XCTAssertEqual(stats.plaintextBytesStored, 4)
        XCTAssertEqual(stats.plaintextBytesDropped, 2)
    }

    /// Agotado el presupuesto de un sentido, lo siguiente **no toca el disco**: ni fichero ni fila.
    func testExhaustedBudgetStopsWritingAltogether() async {
        let h = makeHarness(bytesPerDirection: 4)
        let key = await openFlow(h)

        await h.pipeline.observe(plaintext: Data([1, 2, 3, 4]), direction: .outbound, for: key)
        await h.pipeline.observe(plaintext: Data([5, 6]), direction: .outbound, for: key)
        await h.pipeline.flush()

        let written = await h.plaintext.written
        XCTAssertEqual(written.count, 1)
        let indexedChunks = await h.store.plaintext(for: key).count
        XCTAssertEqual(indexedChunks, 1)
        let droppedBytes = await h.pipeline.stats.plaintextBytesDropped
        XCTAssertEqual(droppedBytes, 2)
    }

    /// Cada sentido tiene el suyo: la respuesta de megabytes no puede dejar sin sitio a las
    /// peticiones que explican la conexión.
    func testEachDirectionHasItsOwnBudget() async {
        let h = makeHarness(bytesPerDirection: 4)
        let key = await openFlow(h)

        await h.pipeline.observe(plaintext: Data([1, 2, 3, 4]), direction: .inbound, for: key)
        await h.pipeline.observe(plaintext: Data([5, 6]), direction: .outbound, for: key)

        let outboundStream = await h.plaintext.stream(.outbound)
        XCTAssertEqual(outboundStream, Data([5, 6]))
        let inboundStream = await h.plaintext.stream(.inbound)
        XCTAssertEqual(inboundStream, Data([1, 2, 3, 4]))
    }

    /// El presupuesto muere con el flujo, por el mismo embudo que lo cierra. Sin esto, un puerto
    /// efímero reciclado heredaría el sitio ya gastado por una conexión que no es la suya.
    func testClosingAFlowReleasesItsBudget() async {
        let h = makeHarness(bytesPerDirection: 4)
        let key = await openFlow(h)
        await h.pipeline.observe(plaintext: Data([1, 2, 3, 4]), direction: .outbound, for: key)

        // Un RST cierra el flujo y el volcado lo pasa por `merge(closed:)`.
        await h.pipeline.handle(
            packet: PipelineFixtures.tcpV4(flagsByte: 0x04),
            protocolFamily: Int32(AF_INET)
        )
        await h.pipeline.flush()

        // La misma 5-tupla otra vez: es un flujo nuevo, y vuelve a tener su presupuesto entero.
        await openFlow(h)
        await h.pipeline.observe(plaintext: Data([9, 9, 9, 9]), direction: .outbound, for: key)

        let recordsWritten = await h.plaintext.written.count
        XCTAssertEqual(recordsWritten, 2)
        let opened = await h.plaintext.streamsOpened
        XCTAssertEqual(opened, 2, "un flujo nuevo abre su propia conversación")
    }

    // MARK: - Degradación

    /// Sin flujo al que colgar la fila no se escribe: bytes descifrados que ninguna fila nombra son
    /// lo peor de los dos mundos —nadie llega a ellos y la retención no sabe que existen—.
    func testChunkWithoutAFlowIsNotWritten() async {
        let h = makeHarness()

        await h.pipeline.observe(
            plaintext: Data([1, 2, 3]),
            direction: .outbound,
            for: PipelineFixtures.tcpV4Key()
        )

        let recordsWritten = await h.plaintext.written.count
        XCTAssertEqual(recordsWritten, 0)
        let droppedBytes = await h.pipeline.stats.plaintextBytesDropped
        XCTAssertEqual(droppedBytes, 3)
    }

    /// Un disco lleno apaga el contenido descifrado y **no** toca el resto: los paquetes siguen
    /// llegando al historial, que es lo que el túnel promete pase lo que pase.
    func testWriteFailureStopsPlaintextOnlyAndIsCounted() async {
        let h = makeHarness()
        let key = await openFlow(h)
        await h.plaintext.failNextWrites(true)

        await h.pipeline.observe(plaintext: Data([1, 2, 3]), direction: .outbound, for: key)
        await h.plaintext.failNextWrites(false)
        await h.pipeline.observe(plaintext: Data([4, 5, 6]), direction: .outbound, for: key)
        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(), protocolFamily: Int32(AF_INET))
        await h.pipeline.flush()

        let stats = await h.pipeline.stats
        XCTAssertEqual(stats.plaintextFailures, 1)
        XCTAssertNotNil(stats.lastPlaintextError)
        XCTAssertEqual(stats.plaintextChunksStored, 0, "el corte no se rearma solo dentro de la sesión")
        let indexedChunks = await h.store.plaintext(for: key).count
        XCTAssertEqual(indexedChunks, 0)
        let indexedPackets = await h.store.packets(for: key).count
        XCTAssertEqual(indexedPackets, 2, "el historial sigue escribiéndose")
    }

    /// Sin escritor, observar es un no-op: es el estado en el que el túnel corre sin nada donde
    /// guardar lo descifrado, y no puede costar ni un error.
    func testWithoutASinkNothingIsWritten() async {
        let h = makeHarness(writesPlaintext: false)
        let key = await openFlow(h)

        await h.pipeline.observe(plaintext: Data([1, 2, 3]), direction: .outbound, for: key)
        await h.pipeline.flush()

        let recordsWritten = await h.plaintext.written.count
        XCTAssertEqual(recordsWritten, 0)
        let indexedChunks = await h.store.plaintext(for: key).count
        XCTAssertEqual(indexedChunks, 0)
        let chunksStored = await h.pipeline.stats.plaintextChunksStored
        XCTAssertEqual(chunksStored, 0)
    }

    /// El volcado escribe el índice **por lotes** y con el id del flujo, igual que los paquetes: un
    /// insert por trozo está prohibido aquí por lo mismo que allí.
    func testIndexRowsAreWrittenBatchedWithTheFlowID() async {
        let h = makeHarness()
        let key = await openFlow(h)

        await h.pipeline.observe(plaintext: Data([1]), direction: .outbound, for: key)
        await h.pipeline.observe(plaintext: Data([2]), direction: .inbound, for: key)
        let indexedChunks = await h.store.plaintext(for: key).count
        XCTAssertEqual(indexedChunks, 0, "nada llega al índice antes del volcado")

        await h.pipeline.flush()

        let chunks = await h.store.plaintext(for: key)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks.map(\.direction), [.outbound, .inbound])
    }

    /// Cerrar el túnel vacía a disco lo descifrado, por lo mismo que la captura: un crash después de
    /// parar no puede llevarse lo último que se escribió.
    func testShutdownFlushesThePlaintextWriter() async {
        let h = makeHarness()
        let key = await openFlow(h)
        await h.pipeline.observe(plaintext: Data([1]), direction: .outbound, for: key)

        await h.pipeline.shutdown()

        let flushes = await h.plaintext.flushCount
        XCTAssertEqual(flushes, 1)
        let indexedChunks = await h.store.plaintext(for: key).count
        XCTAssertEqual(indexedChunks, 1)
    }
}
