import Foundation
import XCTest
import Shared

/// Tests del view model de la mitad descifrada del Flow Inspector (M8, pieza 4).
///
/// Lo que se afirma aquí y en ningún otro sitio es el **reparto de la lectura**: que los turnos se
/// leen de sus trozos y enteros —lo que se dibuja está acotado, lo que se comparte no—, que un fallo
/// se queda dentro de su turno en vez de tumbar la pantalla, y que un turno que falla a medias **no se
/// rellena** con lo que sí se leyó.
@MainActor
final class ConversationViewModelTests: XCTestCase {

    // MARK: - Utilidades

    private let flow = HistoryFixtures.historyFlow(tlsStatus: .inspected)

    /// Una biblioteca de mentira: devuelve los bytes que se le digan por localización, o el fallo.
    private struct FakeLibrary: Sendable {
        var bytes: [UInt64: Data] = [:]
        var failures: [UInt64: PlaintextLibraryError] = [:]

        func record(for chunk: StoredPlaintextChunk) throws -> PlaintextRecord {
            if let failure = failures[chunk.location.recordOffset] { throw failure }
            let data = bytes[chunk.location.recordOffset] ?? Data()
            return PlaintextRecord(
                location: chunk.location,
                stream: chunk.stream,
                direction: chunk.direction,
                date: chunk.date,
                bytes: data,
                originalLength: chunk.originalLength
            )
        }
    }

    private func viewModel(
        chunks: [StoredPlaintextChunk],
        library: FakeLibrary,
        chunkLimit: Int = 500,
        reads: (@Sendable (UInt64) -> Void)? = nil
    ) -> ConversationViewModel {
        ConversationViewModel(flow: flow, chunks: chunks, chunkLimit: chunkLimit) { chunk in
            reads?(chunk.location.recordOffset)
            return try library.record(for: chunk)
        }
    }

    private func rows(of viewModel: ConversationViewModel) -> [ConversationTurnRow] {
        guard case .turns(let rows) = viewModel.content else { return [] }
        return rows
    }

    // MARK: - La lectura

    func testATurnIsTheChunksOfItsSideReadInOrder() async {
        let chunks = [
            HistoryFixtures.storedChunk(id: 1, at: 0.1, recordOffset: 100, storedLength: 5),
            HistoryFixtures.storedChunk(id: 2, at: 0.2, recordOffset: 200, storedLength: 6),
        ]
        let library = FakeLibrary(bytes: [100: Data("GET /".utf8), 200: Data(" HTTP\n".utf8)])

        let viewModel = viewModel(chunks: chunks, library: library)
        await viewModel.load()

        XCTAssertEqual(rows(of: viewModel).count, 1)
        XCTAssertEqual(rows(of: viewModel).first?.body, .text("GET / HTTP"))
    }

    func testTheTwoSidesStayApartAndInOrder() async {
        let chunks = [
            HistoryFixtures.storedChunk(id: 1, at: 0.1, direction: .outbound, recordOffset: 100, storedLength: 5),
            HistoryFixtures.storedChunk(id: 2, at: 0.2, direction: .inbound, recordOffset: 200, storedLength: 4),
        ]
        let library = FakeLibrary(bytes: [100: Data("ping\n".utf8), 200: Data("pong".utf8)])

        let viewModel = viewModel(chunks: chunks, library: library)
        await viewModel.load()

        XCTAssertEqual(rows(of: viewModel).map(\.turn.direction), [.outbound, .inbound])
        XCTAssertEqual(rows(of: viewModel).map(\.body), [.text("ping"), .text("pong")])
    }

    func testReadingStopsAtATruncatedPieceAndNotBefore() async {
        // Se lee el turno **entero** —el botón de compartir lo entrega entero— y solo se corta donde
        // los bytes dejan de ser contiguos: después de un trozo recortado.
        let chunks = [
            HistoryFixtures.storedChunk(id: 1, at: 0.1, recordOffset: 100, storedLength: 4_000),
            HistoryFixtures.storedChunk(
                id: 2, at: 0.2, recordOffset: 200, storedLength: 10, originalLength: 900
            ),
            HistoryFixtures.storedChunk(id: 3, at: 0.3, recordOffset: 300, storedLength: 10),
        ]
        let library = FakeLibrary(bytes: [
            100: Data(String(repeating: "a", count: 4_000).utf8),
            200: Data("cut".utf8),
            300: Data("never read".utf8),
        ])

        let read = Reads()
        let viewModel = viewModel(chunks: chunks, library: library) { read.append($0) }
        await viewModel.load()

        XCTAssertEqual(read.offsets, [100, 200])
    }

    func testLoadingTwiceDoesNotReadTwice() async {
        let chunks = [HistoryFixtures.storedChunk(recordOffset: 100, storedLength: 2)]
        let library = FakeLibrary(bytes: [100: Data("hi".utf8)])

        let read = Reads()
        let viewModel = viewModel(chunks: chunks, library: library) { read.append($0) }
        await viewModel.load()
        await viewModel.load()

        XCTAssertEqual(read.offsets, [100])
    }

    func testRetryingReadsAgain() async {
        let chunks = [HistoryFixtures.storedChunk(recordOffset: 100, storedLength: 2)]
        let library = FakeLibrary(bytes: [100: Data("hi".utf8)])

        let read = Reads()
        let viewModel = viewModel(chunks: chunks, library: library) { read.append($0) }
        await viewModel.load()
        await viewModel.perform(.retry)

        XCTAssertEqual(read.offsets, [100, 100])
    }

    // MARK: - Los fallos

    func testAFailedChunkStaysInsideItsTurn() async {
        let chunks = [
            HistoryFixtures.storedChunk(id: 1, at: 0.1, direction: .outbound, recordOffset: 100, storedLength: 5),
            HistoryFixtures.storedChunk(id: 2, at: 0.2, direction: .inbound, recordOffset: 200, storedLength: 4),
        ]
        let library = FakeLibrary(
            bytes: [100: Data("ping\n".utf8)], failures: [200: .notFound(9)]
        )

        let viewModel = viewModel(chunks: chunks, library: library)
        await viewModel.load()

        XCTAssertEqual(rows(of: viewModel).map(\.body), [.text("ping"), .unavailable(.swept(9))])
    }

    func testATurnThatFailsHalfwayIsNotFilledWithWhatDidRead() async {
        // Los trozos de un turno son partes consecutivas de la misma cosa dicha: pegar lo de antes del
        // fallo con lo de después enseñaría una frase que nadie escribió.
        let chunks = [
            HistoryFixtures.storedChunk(id: 1, at: 0.1, recordOffset: 100, storedLength: 5),
            HistoryFixtures.storedChunk(id: 2, at: 0.2, recordOffset: 200, storedLength: 5),
        ]
        let library = FakeLibrary(
            bytes: [100: Data("first".utf8)], failures: [200: .recordUnreadable("cut short")]
        )

        let viewModel = viewModel(chunks: chunks, library: library)
        await viewModel.load()

        guard case .placeholder(let placeholder) = viewModel.content else {
            return XCTFail("Con el único turno ilegible la pantalla es un hueco.")
        }
        XCTAssertEqual(placeholder.action, .retry)
    }

    func testAForeignRecordIsNeverShownUnderThisConnection() async {
        let chunks = [HistoryFixtures.storedChunk(recordOffset: 100, storedLength: 5)]
        let library = FakeLibrary(failures: [100: .recordMismatch("belongs to 7, not 3")])

        let viewModel = viewModel(chunks: chunks, library: library)
        await viewModel.load()

        guard case .placeholder(let placeholder) = viewModel.content else {
            return XCTFail("Un registro ajeno se dice, no se enseña.")
        }
        XCTAssertNil(placeholder.action)
        XCTAssertEqual(placeholder.diagnostic, "belongs to 7, not 3")
    }

    func testAnUnexpectedErrorIsStillAReadFailureAndNotACrash() async {
        struct Odd: Error {}
        let chunks = [HistoryFixtures.storedChunk(recordOffset: 100, storedLength: 5)]

        let viewModel = ConversationViewModel(flow: flow, chunks: chunks) { _ in throw Odd() }
        await viewModel.load()

        guard case .placeholder(let placeholder) = viewModel.content else {
            return XCTFail("Un error de otro dominio sigue siendo un fallo de lectura.")
        }
        XCTAssertEqual(placeholder.action, .retry)
    }

    // MARK: - Los vacíos

    func testAConversationWithNoChunksIsAnEmptyAndNotAnError() async {
        let viewModel = viewModel(chunks: [], library: FakeLibrary())
        await viewModel.load()

        guard case .placeholder(let placeholder) = viewModel.content else {
            return XCTFail("Sin trozos hay que explicar por qué.")
        }
        XCTAssertNil(placeholder.action)
    }

    func testNothingIsDrawnBeforeTheFirstRead() {
        let viewModel = viewModel(chunks: [HistoryFixtures.storedChunk()], library: FakeLibrary())

        XCTAssertEqual(viewModel.content, .loading)
    }

    // MARK: - El recorte de la consulta

    func testAQueryThatFilledItsLimitSaysSo() async {
        let chunks = (1...4).map {
            HistoryFixtures.storedChunk(
                id: Int64($0), at: Double($0) / 10, recordOffset: UInt64($0) * 100, storedLength: 2
            )
        }
        let library = FakeLibrary(bytes: Dictionary(
            uniqueKeysWithValues: (1...4).map { (UInt64($0) * 100, Data("hi".utf8)) }
        ))

        let viewModel = viewModel(chunks: chunks, library: library, chunkLimit: 4)
        await viewModel.load()

        XCTAssertNotNil(viewModel.chunkLimitNote)
    }

    func testTheLimitNoteIsNotSaidOverAnEmptyScreen() async {
        let viewModel = viewModel(chunks: [], library: FakeLibrary(), chunkLimit: 0)
        await viewModel.load()

        XCTAssertNil(viewModel.chunkLimitNote)
    }

    // MARK: - Compartir

    func testAReadTurnCarriesWhatCanBeSharedOfIt() async {
        let chunks = [HistoryFixtures.storedChunk(recordOffset: 100, storedLength: 5)]
        let library = FakeLibrary(bytes: [100: Data("GET /".utf8)])

        let viewModel = viewModel(chunks: chunks, library: library)
        await viewModel.load()

        XCTAssertEqual(rows(of: viewModel).first?.shareable, "GET /")
    }

    func testATurnThatCouldNotBeReadHasNothingToShare() async {
        let chunks = [HistoryFixtures.storedChunk(recordOffset: 100, storedLength: 5)]
        let library = FakeLibrary(failures: [100: .notFound(9)])

        let viewModel = viewModel(chunks: chunks, library: library)
        await viewModel.load()

        // Con el único turno ilegible la pantalla es un hueco, así que no hay fila que compartir.
        guard case .placeholder = viewModel.content else {
            return XCTFail("Ningún turno legible es un hueco.")
        }
    }
}

/// Cuenta las lecturas de fichero que hace el view model. Es una clase porque la closure de lectura es
/// `@Sendable` y lo que hace falta es que las anotaciones sobrevivan a la llamada.
private final class Reads: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [UInt64] = []

    func append(_ offset: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        seen.append(offset)
    }

    var offsets: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }
}
