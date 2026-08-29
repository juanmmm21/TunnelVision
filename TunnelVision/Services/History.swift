import Foundation
import Shared

/// El núcleo puro del lector de historial: lo que la Timeline pinta, cómo se filtra y cómo se
/// encadenan las páginas. Ninguna decisión de aquí toca el disco, así que todas se prueban en
/// Simulator contra aserciones directas, igual que `TunnelStatePolicy` o `ThroughputWindow`.

/// Un flujo del historial tal y como lo consume la UI.
///
/// Compone lo que guarda el store (`StoredFlow`, que ya viene fechado) con lo único que el store no
/// puede saber: cuál de los dos extremos de la 5-tupla canónica es el dispositivo. Ese reparto lo
/// resuelve `LiveFeedAddressing`, la **misma** función que usa el feed en vivo: si la Timeline y la
/// Dashboard lo decidieran cada una por su cuenta, el mismo flujo podría salir con el host invertido
/// en una de las dos pantallas.
public struct HistoryFlow: Sendable, Hashable, Identifiable {

    /// La fila tal y como está guardada.
    public let stored: StoredFlow

    /// Extremos repartidos, o `nil` si no se pudo decidir cuál era el dispositivo.
    public let endpoints: FlowEndpoints?

    public init(_ stored: StoredFlow, localAddresses: Set<IPAddress>) {
        self.stored = stored
        self.endpoints = LiveFeedAddressing.endpoints(of: stored.key, localAddresses: localAddresses)
    }

    public var id: Int64 { stored.id }

    public var remoteEndpoint: IPEndpoint? { endpoints?.remote }

    /// Lo que encabeza la fila: el SNI si se vio en el ClientHello y, si no, la IP del host remoto.
    ///
    /// Es `nil` —y no una IP cualquiera— cuando no se pudo repartir los extremos: enseñar como host
    /// la dirección del propio dispositivo invertiría lo que el usuario lee. La copia para ese caso
    /// es de la vista, no de este servicio.
    public var displayHost: String? {
        if let sni = stored.sni, !sni.isEmpty { return sni }
        return endpoints?.remote.address.description
    }

    /// Puerto del host remoto: lo que distingue "web" (443) de cualquier otro servicio.
    public var remotePort: UInt16? { endpoints?.remote.port }

    public var tlsStatus: TLSInspectionStatus { stored.tlsStatus }
    public var proto: IPProtocolNumber { stored.key.proto }
    public var firstSeen: Date { stored.firstSeen }
    public var lastSeen: Date { stored.lastSeen }
    public var duration: TimeInterval { stored.duration }
    public var totalBytes: UInt64 { stored.totalBytes }
}

/// Los filtros de la Timeline (`docs/ux/screens.md`): host, protocolo, estado TLS y rango temporal.
///
/// Se aplican **en memoria**, sobre las filas que el store ya devolvió ordenadas y paginadas. Es una
/// decisión deliberada: el texto se busca contra el host que se enseña, y ese host puede ser un SNI
/// (columna) o la IP formateada del extremo remoto (que en disco es un blob canónico, sin saber cuál
/// de los dos extremos es), así que empujar la búsqueda a SQL solo podría filtrar la mitad de los
/// casos y mentiría sobre lo que encuentra. El coste —leer filas que se descartan— lo acota el
/// lector con un tope de páginas por carga.
public struct HistoryFilter: Sendable, Equatable {

    /// Texto libre contra el host visible (SNI o IP remota). Vacío = sin filtro.
    public var searchText: String

    /// Protocolos admitidos. Vacío = todos.
    public var protocols: Set<IPProtocolNumber>

    /// Estados de inspección TLS admitidos. Vacío = todos.
    public var tlsStatuses: Set<TLSInspectionStatus>

    /// Intervalo temporal. Un flujo entra si **se solapa** con él: una conexión viva durante la
    /// ventana pertenece a esa ventana aunque empezara antes.
    public var dateRange: ClosedRange<Date>?

    public init(
        searchText: String = "",
        protocols: Set<IPProtocolNumber> = [],
        tlsStatuses: Set<TLSInspectionStatus> = [],
        dateRange: ClosedRange<Date>? = nil
    ) {
        self.searchText = searchText
        self.protocols = protocols
        self.tlsStatuses = tlsStatuses
        self.dateRange = dateRange
    }

    /// Sin ningún filtro puesto: lo que ve la Timeline al abrirse.
    public static let none = HistoryFilter()

    /// Si hay algún criterio activo. La vista lo usa para distinguir "todavía no hay tráfico" de
    /// "no hay nada que coincida", que son dos vacíos con mensajes distintos.
    public var isActive: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
            || !protocols.isEmpty
            || !tlsStatuses.isEmpty
            || dateRange != nil
    }

    public func matches(_ flow: HistoryFlow) -> Bool {
        if !protocols.isEmpty, !protocols.contains(flow.proto) { return false }
        if !tlsStatuses.isEmpty, !tlsStatuses.contains(flow.tlsStatus) { return false }
        if let dateRange {
            // Solape de intervalos: [firstSeen, lastSeen] ∩ dateRange ≠ ∅.
            if flow.lastSeen < dateRange.lowerBound || flow.firstSeen > dateRange.upperBound {
                return false
            }
        }
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            guard let host = flow.displayHost,
                  host.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            else {
                return false
            }
        }
        return true
    }
}

/// Los topes del lector. Como en el feed en vivo, existen todos por el mismo motivo: el historial lo
/// escribe la extensión y puede tener decenas de miles de filas, así que la lectura tiene que estar
/// acotada por construcción y no crecer con el tráfico acumulado.
public struct HistoryPolicy: Sendable, Equatable {

    /// Filas por consulta al store, y también cuántas coincidencias intenta reunir una carga.
    public var pageSize: Int

    /// Consultas seguidas como máximo en una misma carga. Con un filtro muy selectivo la mayoría de
    /// filas leídas se descartan; sin este tope, un "cargar más" podría recorrer la BD entera de una
    /// sentada. Al alcanzarlo se devuelve lo que haya y `hasMore` sigue en `true`.
    public var maxPagesPerLoad: Int

    /// Paquetes que se traen al abrir el Flow Inspector.
    public var packetsPerFlow: Int

    /// Trozos de contenido descifrado que se traen al abrir el Flow Inspector.
    ///
    /// Va aparte de `packetsPerFlow` aunque hoy valgan lo mismo: son dos listas distintas de la misma
    /// pantalla y atarlas a un número compartido las haría moverse juntas sin motivo. Y es un tope de
    /// **cortesía**, no la defensa: lo que acota de verdad una conversación es el presupuesto del
    /// escritor (64 KiB por sentido, `PlaintextBudget`), así que llegar aquí exige miles de trozos
    /// diminutos. Solo son metadatos — los bytes se leen después, y solo los de lo que se mire.
    public var plaintextChunksPerFlow: Int

    /// **Techo** de barras del eje temporal de la Timeline. No es un tope de coste como los otros
    /// —la consulta ya agrega en el motor y devuelve como mucho esto—, y tampoco es el número que se
    /// dibuja: cuántos tramos ofrece el eje de verdad lo decide su **anchura**, porque un tramo se
    /// toca con el dedo y le debe los 44 puntos de la HIG (`ScrubCapacity`, y el lector lo recibe por
    /// `HistoryReader.setAxisCapacity`). Esto es solo el límite que esa medida nunca puede superar.
    public var axisBars: Int

    public init(
        pageSize: Int = 100,
        maxPagesPerLoad: Int = 8,
        packetsPerFlow: Int = 500,
        plaintextChunksPerFlow: Int = 500,
        axisBars: Int = 48
    ) {
        precondition(pageSize > 0, "pageSize debe ser positivo")
        precondition(maxPagesPerLoad > 0, "maxPagesPerLoad debe ser positivo")
        precondition(packetsPerFlow > 0, "packetsPerFlow debe ser positivo")
        precondition(plaintextChunksPerFlow > 0, "plaintextChunksPerFlow debe ser positivo")
        precondition(axisBars > 0, "axisBars debe ser positivo")
        self.pageSize = pageSize
        self.maxPagesPerLoad = maxPagesPerLoad
        self.packetsPerFlow = packetsPerFlow
        self.plaintextChunksPerFlow = plaintextChunksPerFlow
        self.axisBars = axisBars
    }

    public static let `default` = HistoryPolicy()
}

/// Por qué falló una consulta al historial.
public enum HistoryError: Error, Sendable, Equatable {
    /// Una fila guardada no reconstruye a un tipo de dominio: corrupción o esquema mal migrado.
    case corruptData(String)
    /// El store no pudo responder (BD bloqueada, fichero ilegible...).
    case queryFailed(String)

    /// Traduce lo que lanza el `FlowStore` para que por encima de aquí no viaje un error sin tipar.
    public static func classifying(_ error: any Error) -> HistoryError {
        // Lo que ya viene clasificado se deja pasar: el lector lanza `HistoryError`, así que sin esto
        // el view model que lo recoge convertiría un `corruptData` en un `queryFailed` con el caso
        // anterior escrito dentro, y la pantalla enseñaría el mensaje equivocado.
        if let historyError = error as? HistoryError { return historyError }
        if let storeError = error as? FlowStore.StoreError,
           case .corruptRow(let detail) = storeError {
            return .corruptData(detail)
        }
        return .queryFailed(String(describing: error))
    }
}

/// En qué punto está la carga. `empty` y `populated` de `docs/ux/screens.md` se derivan de esto más
/// `flows.isEmpty`, así que no se duplican como casos.
public enum HistoryState: Sendable, Equatable {
    /// Todavía no se ha pedido nada.
    case idle
    /// Primera carga (o recarga tras cambiar el filtro): la lista aún no es de fiar.
    case loading
    /// Trayendo la página siguiente: la lista ya vale y se le añadirá por debajo.
    case loadingOlder
    case loaded
    case failed(HistoryError)
}

/// Lo que el lector publica y la Timeline pinta. Es un valor: la vista no consulta al lector, lo
/// recibe (igual que con `LiveFeedSnapshot`).
public struct HistorySnapshot: Sendable, Equatable {

    /// Flujos del más reciente al más antiguo, ya filtrados.
    public var flows: [HistoryFlow]

    public var filter: HistoryFilter
    public var state: HistoryState

    /// Si queda historial por detrás del último flujo cargado.
    public var hasMore: Bool

    /// Filas que el store devolvió en la última carga, coincidieran o no con el filtro. Se expone en
    /// vez de tragarse: si es mucho mayor que las que se ven, el filtro obligó a recorrer media BD y
    /// la carga probablemente tocó `maxPagesPerLoad`.
    public var scannedInLastLoad: Int

    public init(
        flows: [HistoryFlow] = [],
        filter: HistoryFilter = .none,
        state: HistoryState = .idle,
        hasMore: Bool = true,
        scannedInLastLoad: Int = 0
    ) {
        self.flows = flows
        self.filter = filter
        self.state = state
        self.hasMore = hasMore
        self.scannedInLastLoad = scannedInLastLoad
    }

    /// Cargado y sin nada que enseñar. Con `filter.isActive` la vista distingue "aún no hay tráfico"
    /// (enseñar y explicar) de "no hay coincidencias" (ofrecer limpiar el filtro).
    public var isEmpty: Bool { flows.isEmpty && state == .loaded }
}

/// El encadenado de páginas, separado del lector porque es pura aritmética de listas.
public enum HistoryPaging {

    /// Añade una página al final conservando el orden y **sin duplicar** filas ya presentes.
    ///
    /// Hace falta porque el historial no está congelado mientras se pagina: la extensión sigue
    /// escribiendo, y un flujo que ya estaba en la lista puede actualizar su `last_seen` y volver a
    /// aparecer en una página posterior. Duplicarlo rompería la identidad de las filas de SwiftUI.
    public static func appending(
        _ page: [HistoryFlow], to existing: [HistoryFlow]
    ) -> [HistoryFlow] {
        guard !page.isEmpty else { return existing }
        var seen = Set(existing.map(\.id))
        var result = existing
        result.reserveCapacity(existing.count + page.count)
        for flow in page where seen.insert(flow.id).inserted {
            result.append(flow)
        }
        return result
    }
}
