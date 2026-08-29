import Foundation
import Observation
import Shared

/// El view model de la pantalla de **un paquete** (M9): sus bytes tal y como quedaron en el `.pcap`.
///
/// Es la última pieza del salto paquete→bytes que `docs/ux/screens.md` pide para el Flow Inspector, y
/// la más pequeña de las pantallas: una sola lectura, sin paginación y sin suscripción. Lo que la hace
/// distinta de las otras es que su fuente **puede haber desaparecido a propósito** — el usuario borra
/// capturas desde la pantalla de Captures —, así que "no hay bytes" es un desenlace normal y no un
/// fallo, y la pantalla tiene que distinguir los dos.
///
/// La lectura entra como closure y no como `CaptureLibrary` por lo mismo que en el Flow Inspector: una
/// biblioteca sana sobre un directorio temporal no sabe fallar a voluntad, y los caminos de fallo son
/// justo los que hay que afirmar. La construcción normal es la que recibe la biblioteca.
@MainActor
@Observable
public final class PacketDetailViewModel {

    // MARK: - Lo que pinta la vista

    /// El paquete, tal y como el Flow Inspector lo tenía en su lista. No se vuelve a consultar: lo que
    /// falta traer son sus bytes.
    public let packet: PacketSummary

    public private(set) var state: PacketBytesState = .idle

    // MARK: - Dependencias

    private let loadRecord: @Sendable (CaptureLocation) async throws -> CaptureRecord

    public init(
        packet: PacketSummary,
        loadRecord: @escaping @Sendable (CaptureLocation) async throws -> CaptureRecord
    ) {
        self.packet = packet
        self.loadRecord = loadRecord
    }

    public convenience init(packet: PacketSummary, library: CaptureLibrary) {
        self.init(packet: packet) { location in try await library.record(at: location) }
    }

    // MARK: - Carga

    /// Trae los bytes si aún no están. La dispara la aparición de la pantalla, que en SwiftUI ocurre
    /// también al volver de una vista apilada encima.
    public func load() async {
        switch state {
        case .loaded, .loading:
            return
        case .idle, .unavailable:
            await reload()
        }
    }

    /// Vuelve a leerlos, pase lo que pase. Es la salida del único hueco que ofrece reintento.
    public func reload() async {
        // Las cabeceras se rehacen en **todas** las salidas, incluida la temprana: si no, un reintento
        // que acabase sin bytes dejaría en pantalla la lectura del intento anterior.
        defer { headers = Self.headers(for: state) }

        // Sin localización no hay nada que abrir, y decirlo aquí evita una lectura de disco que solo
        // podría acabar en el mismo sitio.
        guard let location = packet.capture else {
            state = .unavailable(.notCaptured)
            return
        }

        state = .loading
        do {
            let record = try await loadRecord(location)
            // Los bytes no se pintan por haber llegado: se pintan si son los de **este** paquete.
            state = PacketBytesPresentation.verify(record, expectedLength: packet.length)
        } catch let error as CaptureLibraryError {
            state = .unavailable(PacketBytesPresentation.unavailable(for: error))
        } catch {
            state = .unavailable(.failed(.recordUnreadable(error.localizedDescription)))
        }
    }

    public func perform(_ action: PacketBytesAction) async {
        switch action {
        case .retry:
            await reload()
        }
    }

    // MARK: - Derivados

    public var content: PacketBytesContent {
        PacketBytesPresentation.content(state: state)
    }

    /// Lo que se sabe del paquete sin abrir nada. Está siempre: es lo que hace que abrir un paquete
    /// que no se capturó siga teniendo sentido.
    public var packetFacts: [FlowFact] {
        PacketBytesPresentation.packetFacts(packet)
    }

    /// Los datos del registro, o vacío mientras no haya registro válido: una cabecera con los huecos
    /// puestos a cero diría cosas que nadie ha leído todavía.
    public var recordFacts: [FlowFact] {
        guard case .loaded(let record) = state else { return [] }
        return PacketBytesPresentation.recordFacts(record)
    }

    /// Las cabeceras leídas, o `nil` mientras no haya bytes que leer.
    ///
    /// Se compone **una vez por carga** y no en el `body`: son once búsquedas en el catálogo y otras
    /// tantas cadenas, y la pantalla se repinta cada vez que se desplaza el volcado. Es la misma regla
    /// que ya cumplen la fila de la Timeline y el eje de la barra de scrub.
    public private(set) var headers: PacketHeaderContent?

    /// El aviso de recorte —el del `snaplen` al capturar y el de la pantalla al pintar—, o `nil` si se
    /// enseña el paquete entero.
    public var truncationNote: String? {
        guard case .loaded(let record) = state else { return nil }
        return PacketBytesPresentation.truncationNote(for: record)
    }

    /// El volcado como texto para sacarlo de la app, o `nil` cuando no hay bytes que sacar.
    ///
    /// Se compone del **mismo** `content` que se está pintando y no del registro: así lo que se comparte
    /// es exactamente lo que se ve, recorte de pantalla incluido.
    public var shareableDump: String? {
        guard case .bytes(let lines) = content, !lines.isEmpty else { return nil }
        return HexDump.text(lines)
    }

    private static func headers(for state: PacketBytesState) -> PacketHeaderContent? {
        guard case .loaded(let record) = state else { return nil }
        return PacketHeaderPresentation.content(for: record)
    }
}
