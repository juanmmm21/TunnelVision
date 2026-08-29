import Foundation
import Observation
import Shared

/// El view model del Flow Inspector (M9): todo sobre **una** conexión.
///
/// La pantalla se abre desde una fila de la Timeline, así que el flujo llega ya resuelto y no se
/// vuelve a consultar: lo que hay que traer son sus paquetes, y eso es una sola carga
/// (`HistoryReader.packets(forFlow:)`, acotada por `HistoryPolicy.packetsPerFlow`). No hay
/// paginación ni suscripción — el historial no cambia bajo esta pantalla, y si cambiara, quien lo
/// escribe es otro proceso que SQLite no anuncia.
///
/// La diferencia con `TimelineViewModel` está en el fallo: allí las acciones de carga no lanzan
/// nunca, aquí la consulta **sí** lanza, porque esta pantalla se abrió justo para enseñar eso. Por
/// eso `failed` es un estado de primera clase con su reintento.
///
/// La consulta entra como closure y no como `HistoryReader` para poder probar el camino del fallo:
/// el lector real no tiene forma de fallar a voluntad sobre una BD sana. La construcción normal es la
/// que recibe el lector.
@MainActor
@Observable
public final class FlowInspectorViewModel {

    // MARK: - Lo que pinta la vista

    /// La conexión. Llega resuelta desde la Timeline y **se relee en cada carga**: era una foto tomada
    /// al abrir la pantalla, y una conexión todavía viva sigue sumando bytes y duración mientras se la
    /// mira, así que la cabecera se quedaba parada sin decir que lo estaba.
    ///
    /// Si la relectura no la encuentra —la retención se la llevó mientras estaba abierta— se conserva
    /// la que había: enseñar los paquetes de una conexión y no poder decir de cuál es peor que enseñar
    /// una cabecera de hace un minuto.
    public private(set) var flow: HistoryFlow

    public private(set) var state: FlowInspectorState = .idle

    /// Los paquetes con su copia ya compuesta, que es lo que la vista pinta.
    ///
    /// Se componen aquí y no en la fila porque componer el titular, las dos cifras y la frase que oye
    /// VoiceOver —cuatro búsquedas en el catálogo— dentro de un `body` es trabajo por fotograma de
    /// scroll sobre una lista de hasta `HistoryPolicy.packetsPerFlow` filas. Este es el único sitio que
    /// sabe **cuándo** cambian, y aquí la respuesta es más simple que en la Timeline: una vez por
    /// carga, porque esta lista no pagina ni se refresca sola.
    public private(set) var rows: [PacketListRow] = []

    /// Los trozos de contenido descifrado de la conexión, tal y como los indexó la extensión.
    ///
    /// Son **metadatos y no bytes**: bastan para decir si hay algo y cuánto, que es lo único que la
    /// sección de esta pantalla contesta, y evitan abrir un fichero para dibujar una fila. Quien los
    /// convierte en lo que se dijo es la pantalla que abren (`ConversationViewModel`), y van con ella
    /// en el valor de navegación para no volver a consultarlos.
    public private(set) var chunks: [StoredPlaintextChunk] = []

    // MARK: - Dependencias

    private let loadPackets: @Sendable (Int64) async throws -> [StoredPacket]

    /// Cómo traer el índice del contenido descifrado. Opcional por lo mismo que `loadFlow`: los tests
    /// que ejercitan el fallo de los paquetes no tienen nada que decir de esta consulta, y obligarles a
    /// darla añadiría ruido sin afirmar nada.
    private let loadPlaintext: (@Sendable (Int64) async throws -> [StoredPlaintextChunk])?

    /// Cómo volver a leer la conexión. Opcional porque no todos los llamantes pueden: los tests que
    /// ejercitan el fallo de los paquetes construyen el view model con una sola costura, y obligarles a
    /// dar la segunda solo para no usarla añadiría ruido sin afirmar nada.
    private let loadFlow: (@Sendable (Int64) async throws -> HistoryFlow?)?

    /// `loadPackets` va **al final** aunque sea la costura principal: es la que los llamantes pasan
    /// como closure suelta, y en Swift una closure sin etiqueta se engancha al último parámetro de tipo
    /// función. Con el orden natural se habría enganchado sola a `loadFlow`.
    public init(
        flow: HistoryFlow,
        loadFlow: (@Sendable (Int64) async throws -> HistoryFlow?)? = nil,
        loadPlaintext: (@Sendable (Int64) async throws -> [StoredPlaintextChunk])? = nil,
        loadPackets: @escaping @Sendable (Int64) async throws -> [StoredPacket]
    ) {
        self.flow = flow
        self.loadPackets = loadPackets
        self.loadFlow = loadFlow
        self.loadPlaintext = loadPlaintext
    }

    public convenience init(flow: HistoryFlow, reader: HistoryReader) {
        self.init(
            flow: flow,
            loadFlow: { id in try await reader.flow(id: id) },
            loadPlaintext: { id in try await reader.plaintext(forFlow: id) },
            loadPackets: { id in try await reader.packets(forFlow: id) }
        )
    }

    // MARK: - Carga

    /// Trae los paquetes si aún no están. La dispara la aparición de la pantalla, que en SwiftUI
    /// ocurre también al volver de una vista apilada encima: recargar entonces gastaría una consulta
    /// para enseñar exactamente lo mismo.
    public func load() async {
        switch state {
        case .loaded, .loading:
            return
        case .idle, .failed:
            await reload()
        }
    }

    /// Vuelve a pedirlos, pase lo que pase. Es la salida del error.
    public func reload() async {
        state = .loading
        await refreshHeader()
        do {
            // El índice de lo descifrado va **antes** que los paquetes y dentro del mismo `do`: son
            // dos lecturas de la misma conexión en la misma base de datos, hechas para la misma
            // pantalla, así que si una no se puede hacer la pantalla no está cargada. Delante porque
            // la lista de paquetes, una vez pintada, tapa el error de un refresco posterior — y un
            // índice que falló en silencio haría decir a la sección «no se guardó nada», que es lo
            // único que no se puede decir sin haberlo leído.
            if let loadPlaintext {
                chunks = try await loadPlaintext(flow.id)
            }
            let stored = try await loadPackets(flow.id)
            rows = FlowInspectorPresentation.rows(
                for: FlowInspectorPresentation.summaries(stored, flow: flow)
            )
            state = .loaded
        } catch {
            // La lista ya cargada **no** se descarta: si un reintento falla, el usuario se queda con
            // lo que estaba leyendo (`FlowInspectorPresentation.content` decide que eso manda).
            state = .failed(HistoryError.classifying(error))
        }
    }

    public func perform(_ action: FlowInspectorAction) async {
        switch action {
        case .retry:
            await reload()
        }
    }

    /// Relee la cabecera. **No lanza y no toca `state`**: el estado de esta pantalla es el de su lista
    /// de paquetes, que es a lo que se abrió, y un fallo al refrescar unas cifras que ya están en
    /// pantalla no puede taparla con una tarjeta de error. Lo que se pierde es una actualización, y lo
    /// que queda es la cabecera anterior, que sigue siendo cierta de cuando se leyó.
    private func refreshHeader() async {
        guard let loadFlow else { return }
        guard let refreshed = try? await loadFlow(flow.id) else { return }
        flow = refreshed
    }

    // MARK: - Derivados

    public var host: String { FlowDisplay.host(flow) }

    public var tlsStatus: TLSStatusPresentation { .forStatus(flow.tlsStatus) }

    public var facts: [FlowFact] { FlowInspectorPresentation.facts(for: flow) }

    public var content: FlowInspectorContent {
        FlowInspectorPresentation.content(state: state, rows: rows)
    }

    /// Lo que la sección del contenido descifrado enseña, o `nil` mientras no se haya leído su índice.
    ///
    /// Es `nil` y no una de las cuatro ausencias a propósito: las cuatro afirman algo —que no se
    /// cifró, que no se miró, que la otra app pinnea, que no se guardó— y ninguna es cierta hasta
    /// haber preguntado. Una sección que desaparece dice menos, que es exactamente lo que se sabe.
    public var contentSection: FlowContentSection? {
        guard state == .loaded else { return nil }
        return FlowInspectorPresentation.contentSection(for: flow, chunks: chunks)
    }

    /// El valor que apila el `NavigationLink` hacia la conversación descifrada.
    public var conversationRoute: ConversationRoute {
        ConversationRoute(flow: flow, chunks: chunks)
    }

    /// El aviso de lista recortada, o `nil` si se enseñan todos los paquetes de la conexión.
    public var truncationNote: String? {
        guard state == .loaded else { return nil }
        return FlowInspectorPresentation.truncationNote(
            shown: rows.count, recorded: flow.stored.packetCount
        )
    }
}
