import Foundation
import Observation
import Shared

/// El view model de la mitad descifrada del Flow Inspector (M8, pieza 4): lo que se dijo por dentro de
/// **una** conexión inspeccionada.
///
/// Recibe los trozos ya resueltos —los trajo el Flow Inspector para poder contar su sección, y volver
/// a pedirlos aquí gastaría una consulta para obtener lo mismo— y lo único que hace es **leer sus
/// bytes**, que es el reparto que `HistoryReader.plaintext(forFlow:)` y `PlaintextLibrary` tienen
/// escrito: el índice dice qué hay, los ficheros dicen qué decía.
///
/// **Se lee todo de una vez y eso está acotado por construcción**, no por un tope de pantalla: el
/// presupuesto del escritor guarda como mucho 64 KiB por sentido y flujo (`PlaintextBudget`), así que
/// una conversación entera cabe en 128 KiB. Y se lee **entero** y no solo la vista previa a
/// propósito: lo que la pantalla dibuja está acotado, pero lo que el botón de compartir entrega es
/// todo lo que se guardó, y dejar eso sin leer lo pondría fuera del alcance de su dueño.
///
/// No tiene estado de fallo global, al contrario que el Flow Inspector: aquí no hay **una** lectura
/// que falle sino una por turno, y cada desenlace viaja dentro de su fila. Que la pantalla entera
/// acabe siendo un hueco lo decide `ConversationPresentation.content` cuando resulta que ninguno se
/// pudo leer.
///
/// La lectura entra como closure y no como `PlaintextLibrary` por lo mismo que en las otras dos
/// pantallas de ficheros: una biblioteca sana sobre un directorio temporal no sabe fallar a voluntad,
/// y los caminos de fallo son justo los que hay que afirmar.
@MainActor
@Observable
public final class ConversationViewModel {

    // MARK: - Lo que pinta la vista

    public private(set) var state: ConversationState = .idle

    // MARK: - Lo que se sabe sin leer nada

    /// Los turnos, agrupados una sola vez: son un derivado puro de los trozos, que no cambian bajo
    /// esta pantalla.
    private let turns: [ConversationTurn]

    /// Cuántos trozos trajo la consulta y cuántos como mucho podía traer. Juntos son lo único que se
    /// sabe del recorte: si coinciden, había más.
    private let chunkCount: Int
    private let chunkLimit: Int

    // MARK: - Dependencias

    private let loadRecord: @Sendable (StoredPlaintextChunk) async throws -> PlaintextRecord

    public init(
        flow: HistoryFlow,
        chunks: [StoredPlaintextChunk],
        chunkLimit: Int = HistoryPolicy.default.plaintextChunksPerFlow,
        loadRecord: @escaping @Sendable (StoredPlaintextChunk) async throws -> PlaintextRecord
    ) {
        self.turns = ConversationPresentation.turns(chunks, flow: flow)
        self.chunkCount = chunks.count
        self.chunkLimit = chunkLimit
        self.loadRecord = loadRecord
    }

    public convenience init(
        flow: HistoryFlow,
        chunks: [StoredPlaintextChunk],
        chunkLimit: Int = HistoryPolicy.default.plaintextChunksPerFlow,
        library: PlaintextLibrary
    ) {
        self.init(flow: flow, chunks: chunks, chunkLimit: chunkLimit) { chunk in
            try await library.record(for: chunk)
        }
    }

    // MARK: - Carga

    /// Lee los ficheros si aún no se han leído. La dispara la aparición de la pantalla, que en SwiftUI
    /// ocurre también al volver de una vista apilada encima.
    public func load() async {
        switch state {
        case .loaded, .loading:
            return
        case .idle:
            await reload()
        }
    }

    /// Vuelve a leerlos, pase lo que pase. Es la salida del único hueco que ofrece reintento.
    public func reload() async {
        state = .loading

        var rows: [ConversationTurnRow] = []
        rows.reserveCapacity(turns.count)
        for turn in turns {
            rows.append(ConversationPresentation.row(turn, bytes: await bytes(of: turn)))
        }
        state = .loaded(rows)
    }

    public func perform(_ action: ConversationAction) async {
        switch action {
        case .retry:
            await reload()
        }
    }

    /// Lo que se leyó de un turno, o por qué no se pudo.
    ///
    /// Un trozo que falla se lleva el turno entero y **no se rellena con lo que sí se leyó**: los
    /// trozos de un turno son partes consecutivas de la misma cosa dicha, así que pegar lo de antes
    /// del fallo con lo de después empalmaría dos posiciones del stream y enseñaría una frase que
    /// nadie escribió. Es la misma regla por la que `readable` se para en el primer trozo recortado.
    private func bytes(of turn: ConversationTurn) async -> ConversationTurnBytes {
        var read = Data()
        for chunk in ConversationPresentation.readable(turn) {
            do {
                read.append(try await loadRecord(chunk).bytes)
            } catch let error as PlaintextLibraryError {
                return .unavailable(ConversationPresentation.unavailable(for: error))
            } catch {
                return .unavailable(.unreadable(error.localizedDescription))
            }
        }
        return .read(read)
    }

    // MARK: - Derivados

    public var content: ConversationContent {
        ConversationPresentation.content(state: state)
    }

    /// El aviso de que la consulta llenó su tope, o `nil` si trajo la conversación entera. Solo cuando
    /// hay algo que enseñar: sobre un hueco no significaría nada.
    public var chunkLimitNote: String? {
        guard case .turns = content else { return nil }
        return ConversationPresentation.chunkLimitNote(shown: chunkCount, limit: chunkLimit)
    }
}
