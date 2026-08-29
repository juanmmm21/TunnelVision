import Foundation
import Observation
import Shared

/// El view model de la pantalla de capturas (M9): la capa entre `CaptureLibrary` —un **actor**— y
/// SwiftUI, más el único gesto de esta pantalla que no va a disco sino a la extensión, rotar.
///
/// Rotar entra como closure y no como `TunnelController` por lo mismo que la consulta del Flow
/// Inspector: es lo único que puede fallar de varias maneras distintas (el túnel parado, el disco
/// lleno, el canal caído) y ninguna de ellas se puede provocar sobre un controlador sano. La
/// construcción normal es la que recibe el controlador.
///
/// Es `@MainActor` y `@Observable` como los demás view models de la app.
@MainActor
@Observable
public final class CapturesViewModel {

    // MARK: - Lo que pinta la vista

    public private(set) var state: CapturesState = .idle

    public private(set) var files: [CaptureFileInfo] = []

    public private(set) var activity: CapturesActivity = .idle

    /// El resultado de la última acción, si hay algo que contar. Lo descarta el usuario.
    public private(set) var notice: CapturesNotice?

    /// El export ya escrito y esperando a que el usuario decida compartirlo. Es estado del view model
    /// y no de la vista porque hay un fichero de por medio: mientras esto no sea `nil`, hay un JSON en
    /// el temporal que alguien preparó a propósito.
    public private(set) var pendingExport: FlowExportSummary?

    /// Si el túnel está vivo, que es lo que decide si hay un fichero abierto ahora mismo y si tiene
    /// sentido pedir una rotación. Lo empuja la vista desde el estado del controlador, igual que en
    /// la Dashboard.
    public private(set) var isMonitoring: Bool = false

    /// Los topes que el usuario tiene guardados, o `nil` si no se pudieron leer.
    ///
    /// Sin ellos la pantalla **no compara nada**: enseñar el inventario contra los topes de fábrica
    /// afirmaría un tope que el usuario puede haber cambiado, y de esa afirmación cuelga la respuesta
    /// a si el dispositivo se va a llenar. Que no se hayan podido leer se dice en un aviso, que es
    /// como esta pantalla cuenta lo que no salió sin tapar lo que el usuario está mirando.
    public private(set) var retention: RetentionSettings?

    /// El instante de la última lectura, que es contra el que se mide la antigüedad.
    ///
    /// Se guarda en vez de preguntarle la hora al reloj en cada repintado por dos razones que van
    /// juntas: la comparación es una **foto** del momento en que se leyó el directorio —igual que los
    /// tamaños de los ficheros— y un derivado que consulta el reloj no se puede afirmar en un test.
    private var measuredAt: Date = .distantPast

    // MARK: - Dependencias

    private let library: CaptureLibrary
    private let rotateCapture: @Sendable () async throws -> ControlResponse
    private let exportConnections: @Sendable () async throws -> FlowExportResult

    /// Los topes guardados, que escribe la pantalla de Ajustes y lee la extensión al arrancar.
    ///
    /// Entra como closure y no como `SettingsStore` por lo mismo que rotar: es lo que puede fallar de
    /// una manera que no se puede provocar sobre un almacén sano (un blob que no es JSON), y esta
    /// pantalla tiene que saber pintarse igual cuando eso pasa.
    private let loadRetention: @Sendable () throws -> RetentionSettings

    /// El reloj. Inyectable porque de él cuelga la única cifra de esta pantalla que cambia sola: la
    /// fecha en que caduca la captura más antigua.
    private let now: @Sendable () -> Date

    public init(
        library: CaptureLibrary,
        rotateCapture: @escaping @Sendable () async throws -> ControlResponse,
        exportConnections: @escaping @Sendable () async throws -> FlowExportResult,
        loadRetention: @escaping @Sendable () throws -> RetentionSettings,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.library = library
        self.rotateCapture = rotateCapture
        self.exportConnections = exportConnections
        self.loadRetention = loadRetention
        self.now = now
    }

    /// La construcción normal: rotar va al túnel y el export recorre el historial.
    ///
    /// El historial entra como **fábrica** y se abre en cada export, por lo mismo que en la Timeline:
    /// abrir el `FlowStore` toca disco y puede fallar, y esta pantalla funciona entera sin él — no
    /// tiene sentido que un historial ilegible impida listar o borrar capturas. Un lector propio
    /// además no comparte paginación con la Timeline, que es lo que garantiza que exportar no mueva
    /// la lista que el usuario tenía cargada allí.
    public convenience init(
        library: CaptureLibrary,
        exporter: FlowExporter,
        controller: TunnelController,
        settingsStore: SettingsStore,
        makeHistoryReader: @escaping @Sendable () async throws -> HistoryReader
    ) {
        self.init(
            library: library,
            rotateCapture: { try await controller.send(.rotateCapture) },
            exportConnections: {
                let reader: HistoryReader
                do {
                    reader = try await makeHistoryReader()
                } catch {
                    // Abrir el historial es parte de leerlo: sin esto, un `FlowStore` que no se deja
                    // abrir llegaría a la pantalla sin tipar y se contaría como un fallo de escritura.
                    throw FlowExportError.historyUnreadable(HistoryError.classifying(error))
                }
                return try await exporter.export { limit, cursor in
                    try await reader.flowPage(limit: limit, after: cursor)
                }
            },
            // El mismo almacén que edita Ajustes, porque es el mismo blob: si esta pantalla leyera
            // los topes de otro sitio, la comparación que enseña y los topes que el usuario eligió
            // podrían ser dos verdades distintas.
            loadRetention: { try settingsStore.load().retention }
        )
    }

    // MARK: - Carga

    /// Vuelve a leer el directorio. La dispara la aparición de la pantalla y el tirar para refrescar.
    ///
    /// No hay observación viva del directorio: quien escribe es la extensión, en otro proceso, y el
    /// fichero solo cambia de tamaño mientras se captura. Vigilarlo con un `DispatchSource` costaría
    /// un evento por escritura para repintar un tamaño que el usuario no está midiendo al byte.
    public func refresh() async {
        if files.isEmpty { state = .loading }
        measuredAt = now()
        readRetention()
        do {
            files = try await library.files()
            state = .loaded
        } catch let error as CaptureLibraryError {
            fail(with: error)
        } catch {
            fail(with: .containerUnavailable(error.localizedDescription))
        }
    }

    /// Sincroniza con el estado del túnel. Solo `live` cuenta como "hay alguien escribiendo": en
    /// `starting`/`stopping` el writer aún no existe o ya se cerró, y marcar entonces un fichero como
    /// abierto se lo quitaría al usuario justo cuando ya puede exportarlo.
    public func tunnelStateDidChange(to state: TunnelState) {
        isMonitoring = (state == .live)
    }

    // MARK: - Acciones

    /// Cierra el fichero actual y abre uno nuevo, para poder exportar lo capturado hasta ahora sin
    /// parar el túnel — que es justo lo que `ControlCommand.rotateCapture` existe para hacer.
    public func rotate() async {
        guard activity == .idle else { return }
        activity = .rotating
        defer { activity = .idle }

        do {
            switch try await rotateCapture() {
            case .ok:
                notice = CapturesPresentation.rotated
                await refresh()
            case .notRunning:
                notice = CapturesPresentation.rotateUnavailable
            case .failed(let detail):
                notice = CapturesPresentation.rotateFailed(detail)
            case .stats:
                // La extensión contestó a otra pregunta. No se puede afirmar que haya rotado, así que
                // se cuenta como fallo en vez de enseñar una confirmación que quizá no ocurrió.
                notice = CapturesPresentation.rotateFailed("Unexpected reply from the tunnel.")
            }
        } catch TunnelControlError.notRunning {
            notice = CapturesPresentation.rotateUnavailable
        } catch {
            notice = CapturesPresentation.rotateFailed(String(describing: error))
        }
    }

    /// Borra un fichero. Se niega con el que está abierto: la vista ya no ofrece el gesto, pero la
    /// regla vive aquí porque la consecuencia (la extensión escribiendo en un fichero sin nombre) es
    /// del dominio y no del dibujo.
    public func delete(sequence: UInt32) async {
        guard activity == .idle else { return }
        guard rows.first(where: { $0.sequence == sequence })?.isActionable ?? false else {
            notice = CapturesPresentation.cannotDeleteRecording
            return
        }

        activity = .deleting(sequence)
        defer { activity = .idle }

        do {
            try await library.delete(sequence: sequence)
        } catch CaptureLibraryError.notFound {
            // Ya no estaba: es exactamente el resultado que el usuario pidió, no un fallo que
            // contarle. El refresco de abajo hace desaparecer la fila igual.
            notice = nil
        } catch let error as CaptureLibraryError {
            notice = CapturesPresentation.deletionFailed(CapturesPresentation.diagnostic(for: error))
        } catch {
            notice = CapturesPresentation.deletionFailed(error.localizedDescription)
        }

        await refresh()
    }

    /// Escribe el listado de conexiones en JSON y lo deja preparado para compartir.
    ///
    /// No comparte nada por su cuenta: deja el resumen en `pendingExport` para que la pantalla enseñe
    /// **qué** hay dentro antes de que el usuario decida sacarlo del dispositivo. Un export vacío no
    /// llega a ofrecerse — con el historial vacío no hay nada que compartir, y una hoja del sistema
    /// con un fichero de cero conexiones sería un gesto que no lleva a ninguna parte.
    public func exportFlows() async {
        guard activity == .idle else { return }
        activity = .exporting
        defer { activity = .idle }

        do {
            let result = try await exportConnections()
            guard result.connectionCount > 0 else {
                notice = CapturesPresentation.nothingToExport
                return
            }
            notice = nil
            pendingExport = CapturesPresentation.exportPrepared(result)
        } catch let error as FlowExportError {
            notice = CapturesPresentation.exportFailed(error)
        } catch {
            notice = CapturesPresentation.exportFailed(.writeFailed(String(describing: error)))
        }
    }

    /// El usuario cierra la hoja del export. El fichero se queda en el temporal hasta el siguiente
    /// export, que limpia el anterior: borrarlo aquí correría con la hoja del sistema, que puede
    /// seguir leyéndolo mientras se comparte.
    public func dismissExport() {
        pendingExport = nil
    }

    public func dismissNotice() {
        notice = nil
    }

    public func perform(_ action: CapturesAction) async {
        switch action {
        case .retry:
            await refresh()
        }
    }

    // MARK: - Derivados

    /// Las filas, recalculadas en cada repintado a propósito: aquí la lista cambia solo cuando el
    /// usuario actúa (un puñado de ficheros), al revés que los hosts de la Dashboard, que se agregan
    /// una vez por instantánea porque llegan mucho más rápido de lo que se repinta.
    public var rows: [CaptureFileDisplay] {
        CapturesPresentation.rows(files, recordingSequence: recordingSequence)
    }

    public var recordingSequence: UInt32? {
        CapturesPresentation.recordingSequence(files: files, isMonitoring: isMonitoring)
    }

    public var content: CapturesContent {
        CapturesPresentation.content(state: state, files: rows)
    }

    public var summary: CapturesSummary {
        CapturesPresentation.summary(files)
    }

    /// Cómo va el inventario contra los topes, o `nil` mientras no haya topes que comparar.
    ///
    /// Es un derivado y no un valor guardado a propósito: depende también de **cuál es el fichero
    /// abierto**, que cambia cuando el túnel arranca o para sin que nadie vuelva a tocar el disco.
    /// La única entrada que sí se congela es el instante (`measuredAt`), porque medir la antigüedad
    /// contra un reloj que corre haría que un repintado cualquiera cambiara la respuesta.
    public var headroom: CaptureHeadroom? {
        guard let retention else { return nil }
        return CaptureHeadroom.reading(
            files: files,
            settings: retention,
            now: measuredAt,
            recordingSequence: recordingSequence
        )
    }

    /// Rotar solo tiene sentido con el túnel vivo. Con él parado el botón se queda visible pero
    /// apagado: esconderlo dejaría al usuario sin saber que esa salida existe.
    public var canRotate: Bool {
        isMonitoring && activity == .idle
    }

    /// Exportar no depende del túnel: lo que se lee es el historial, que está guardado con la
    /// monitorización parada. Solo espera a que no haya otra acción en curso.
    public var canExport: Bool {
        activity == .idle
    }

    // MARK: - Interno

    /// Relee los topes. Que no se puedan leer **no tapa la pantalla**: lo que se pierde es la
    /// comparación, no el inventario, así que la sección desaparece y se dice por qué — callarse
    /// dejaría un bloque que aparece y desaparece sin explicación, que es como se lee una avería
    /// intermitente.
    private func readRetention() {
        do {
            retention = try loadRetention()
        } catch let error as SettingsStoreError {
            retention = nil
            notice = CapturesPresentation.retentionUnreadable(error)
        } catch {
            retention = nil
            notice = CapturesPresentation.retentionUnreadable(.corruptData(String(describing: error)))
        }
    }

    /// Un fallo de lectura con la lista ya pintada no la tapa: se cuenta como aviso y la lista se
    /// queda, aunque pueda estar desfasada. Sin filas, el fallo sí es el cuerpo de la pantalla.
    private func fail(with error: CaptureLibraryError) {
        if files.isEmpty {
            state = .failed(error)
        } else {
            state = .loaded
            notice = CapturesPresentation.refreshFailed(error)
        }
    }
}
