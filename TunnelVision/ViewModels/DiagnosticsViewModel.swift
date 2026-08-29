import Foundation
import Observation
import Shared

/// El view model del diagnóstico de la sesión: pide los contadores por el canal de control y los deja
/// como copia.
///
/// Habla con la extensión por el mismo sitio que Ajustes y Capturas —una closure `send`, no un
/// controlador— porque lo que necesita es exactamente eso: mandar un comando y leer la respuesta. Y
/// **los contadores son estado de esta pantalla**, no del túnel: nadie más los enseña, así que
/// guardarlos en el controlador solo repartía en dos sitios la misma lectura.
///
/// Dos reglas gobiernan lo que se conserva, y las dos salen de lo mismo —los contadores nacen a cero
/// con cada sesión—:
///
/// 1. **Un fallo de consulta no borra lo último cierto.** Los números de hace un momento siguen
///    siendo lo que pasó; lo que se añade es el motivo por el que no hay unos más nuevos.
/// 2. **Parar el túnel sí los borra.** Son de *aquella* sesión, y dejarlos en pantalla bajo un
///    titular que dice que no hay nada que diagnosticar sería enseñar dos cosas que se contradicen.
@MainActor
@Observable
public final class DiagnosticsViewModel {

    // MARK: - Lo que pinta la vista

    /// Lo último que contestó la extensión. `nil` mientras no haya contestado nunca en esta sesión.
    public private(set) var stats: TunnelStats?

    /// Por qué no hay contadores más nuevos, con el texto del sistema. Se enseña aparte de la copia,
    /// como en el resto de la app: un mensaje de framework no puede ser lo único que se lea, pero
    /// tragárselo dejaría sin nada que contar a quien pida ayuda.
    public private(set) var failure: String?

    public private(set) var isRefreshing = false

    /// Si el túnel está vivo. Lo empuja la vista desde el controlador, igual que en Ajustes y en
    /// Capturas, porque es un hecho del túnel y no de esta pantalla.
    public private(set) var isMonitoring = false

    /// El titular: el veredicto sobre la inspección, o el fallo si no hay ni un contador que leer.
    public var headline: DiagnosticsHeadline {
        if stats == nil, let failure {
            return DiagnosticsPresentation.unreachable(failure)
        }
        return DiagnosticsPresentation.headline(
            for: DiagnosticsPresentation.verdict(for: stats, isMonitoring: isMonitoring)
        )
    }

    /// Lo que hay que decir del DNS, o `nil` si no hay nada que decir.
    ///
    /// Va **por encima** del titular en la vista, y esa colocación es la decisión: el titular habla de
    /// la inspección, que es opcional y degrada en silencio, y esto habla de si el dispositivo puede
    /// resolver nombres. Cuando las dos cosas tienen algo que contar, la segunda es la que explica lo
    /// que el usuario está notando.
    public var resolverNotice: DiagnosticsHeadline? {
        DiagnosticsPresentation.resolverNotice(
            for: DiagnosticsPresentation.resolverVerdict(for: stats, isMonitoring: isMonitoring)
        )
    }

    public var sections: [DiagnosticsSection] {
        guard let stats else { return [] }
        return DiagnosticsPresentation.sections(for: stats)
    }

    // MARK: - Dependencias

    private let send: @Sendable (ControlCommand) async throws -> ControlResponse

    public init(send: @escaping @Sendable (ControlCommand) async throws -> ControlResponse) {
        self.send = send
    }

    /// La construcción normal: el controlador del túnel como canal de control.
    public convenience init(controller: TunnelController) {
        self.init(send: { [weak controller] command in
            guard let controller else { throw TunnelControlError.notRunning }
            return try await controller.send(command)
        })
    }

    #if DEBUG
    /// Los contadores vienen del sembrador de Simulator y no de ninguna extensión.
    ///
    /// Es lo único que esta clase necesita saber de ello, y sirve para una sola cosa: que el estado
    /// del túnel —que en Simulator nunca es `.live`— no desmonte la pantalla. El refresco no la
    /// necesita, porque el canal sembrado contesta siempre lo mismo.
    private var isSeeded = false

    /// La pantalla sobre unos contadores sembrados, para poder mirarla sin un túnel
    /// (`Shared/Fixtures/TunnelStatsFixture.swift`).
    public convenience init(seeded stats: TunnelStats) {
        self.init(send: { _ in .stats(stats) })
        self.isSeeded = true
        self.isMonitoring = true
        self.stats = stats
    }
    #endif

    // MARK: - Estado del túnel

    public func tunnelStateDidChange(to state: TunnelState) {
        #if DEBUG
        guard !isSeeded else { return }
        #endif
        let monitoring = (state == .live)
        defer { isMonitoring = monitoring }
        guard isMonitoring, !monitoring else { return }
        // La sesión de la que hablaban estos números ya no existe. Conservarlos enseñaría el resultado
        // de una inspección que terminó junto a un titular que dice que no hay nada que diagnosticar.
        stats = nil
        failure = nil
    }

    // MARK: - Los contadores

    public func refresh() async {
        // Sin túnel no se pregunta, y esto no es una optimización: mandar el comando igualmente hacía
        // que la pantalla enseñara el fallo del canal —"no hay sesión"— en vez de lo único cierto,
        // que es que no hay nada que diagnosticar todavía. Se vio en el Simulator, que es donde nunca
        // hay túnel.
        guard isMonitoring else {
            stats = nil
            failure = nil
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            switch try await send(.stats) {
            case .stats(let received):
                stats = received
                failure = nil
            case .notRunning:
                // No hay sesión al otro lado, así que no hay contadores: es la carrera normal entre
                // la pantalla y `stopTunnel`, y no un fallo que contar.
                stats = nil
                failure = nil
            case .ok, .failed:
                // Una respuesta que no es la que se pidió. No se puede afirmar nada nuevo, pero
                // tampoco se puede llamar cierto lo anterior sin decir que no se pudo confirmar.
                failure = DiagnosticsPresentation.unexpectedReply
            }
        } catch TunnelControlError.notRunning {
            stats = nil
            failure = nil
        } catch let error as TunnelControlError {
            failure = DiagnosticsPresentation.diagnostic(for: error)
        } catch {
            failure = String(describing: error)
        }
    }
}
