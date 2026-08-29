import Foundation
import Observation
import Shared

/// El view model de la Dashboard (M9): la capa que hay entre el `LiveFeedReader` —un **actor**, que
/// la vista no puede tocar— y SwiftUI.
///
/// Hace tres cosas y ninguna más: consume el stream de instantáneas del lector y las publica en el
/// `MainActor`, deriva de cada instantánea lo que el gráfico y la lista de hosts necesitan, y traduce
/// los cambios de estado del túnel en el ciclo de vida del feed. Todo lo demás (cuándo se abre el
/// ring, cómo se drena, cómo se rellenan los huecos del gráfico) ya está resuelto y probado en el
/// servicio; duplicarlo aquí sería tener dos sitios donde equivocarse.
///
/// Es `@MainActor` y `@Observable` como `TunnelController`, y por el mismo motivo: existe para
/// alimentar vistas.
@MainActor
@Observable
public final class DashboardViewModel {

    /// La última instantánea publicada por el lector. Es el origen de todo lo que pinta la pantalla.
    public private(set) var snapshot: LiveFeedSnapshot = LiveFeedSnapshot()

    /// Los hosts que más mueven ahora mismo, recalculados con cada instantánea.
    ///
    /// Se guarda en vez de calcularse en un `var` derivado porque SwiftUI evalúa el cuerpo de la vista
    /// muchas más veces de las que llegan instantáneas: agregando aquí, el coste va por instantánea y
    /// no por repintado.
    public private(set) var topTalkers: [TopTalker] = []

    private let liveFeed: LiveFeedReader
    private let topTalkerLimit: Int

    /// La tarea que consume `snapshots()`. Se cancela en `stopObserving()`; captura `self` débilmente
    /// para que un view model que ya nadie retiene no la mantenga viva.
    @ObservationIgnored private var feedTask: Task<Void, Never>?

    /// Si el lector está en marcha para la sesión de túnel actual. Distingue un arranque de verdad de
    /// un `live` que solo reconfirma lo que ya estaba en marcha (ver `tunnelStateDidChange`).
    @ObservationIgnored private var isFeedLive = false

    public init(liveFeed: LiveFeedReader, topTalkerLimit: Int = 5) {
        precondition(topTalkerLimit > 0, "topTalkerLimit debe ser positivo")
        self.liveFeed = liveFeed
        self.topTalkerLimit = topTalkerLimit
    }

    deinit {
        feedTask?.cancel()
    }

    // MARK: - Suscripción

    /// Empieza a recibir instantáneas. Idempotente: la vista la llama en cada `onAppear` y no por eso
    /// se abren dos suscripciones.
    public func startObserving() {
        guard feedTask == nil else { return }
        let feed = liveFeed
        feedTask = Task { [weak self] in
            for await snapshot in await feed.snapshots() {
                guard let self else { return }
                self.apply(snapshot)
            }
        }
    }

    /// Deja de recibirlas y libera la tarea. La vista la llama al desaparecer.
    ///
    /// **No** para el lector: el feed sigue drenando el ring mientras el túnel esté vivo, porque los
    /// contadores y el gráfico son de la sesión de monitorización, no de si la pantalla está a la
    /// vista. Quien decide el ciclo de vida del lector es el estado del túnel.
    public func stopObserving() {
        feedTask?.cancel()
        feedTask = nil
    }

    // MARK: - Ciclo de vida del feed

    /// Ajusta el lector al estado del túnel.
    ///
    /// Tres reglas, y las tres vienen de cómo funciona la extensión, no de la UI:
    ///
    /// 1. **Una sesión nueva arranca el lector**, que es quien re-ancla el reloj, vacía los contadores
    ///    y abre el ring que la extensión acaba de crear. Se distingue de una reconfirmación con
    ///    `isFeedLive` porque `start()` es idempotente pero `reattach()` no: si al volver a activo se
    ///    re-enganchase primero, ese drenaje metería el primer lote de la sesión nueva en los
    ///    contadores de la vieja y el `start()` siguiente lo borraría al vaciarlos.
    /// 2. **Un `live` sobre una sesión ya viva solo re-engancha**, sin vaciar nada: la extensión puede
    ///    haber recreado el fichero del ring, y un mapeo del anterior seguiría vivo y mudo, sin dar un
    ///    solo error (`LiveFeedReader.reattach()`).
    /// 3. **`starting`/`stopping` no tocan el lector.** Son transiciones, y `reasserting` —que el
    ///    controlador mapea a `starting`— ocurre *dentro* de una sesión ya viva al cambiar de red:
    ///    parar ahí vaciaría los contadores y el gráfico de una sesión que nunca terminó, y el usuario
    ///    vería su tráfico acumulado desaparecer al pasar de Wi-Fi a datos.
    public func tunnelStateDidChange(to state: TunnelState) async {
        switch state {
        case .live:
            if isFeedLive {
                await liveFeed.reattach()
            } else {
                isFeedLive = true
                await liveFeed.start()
            }
        case .off, .notInstalled, .failed:
            guard isFeedLive else { return }
            isFeedLive = false
            await liveFeed.stop()
        case .starting, .stopping:
            break
        }
    }

    /// La escena de la app vuelve a estar en primer plano.
    ///
    /// Re-engancha el ring, y solo si el feed ya estaba vivo. El re-enganche por cambio de estado del
    /// túnel no basta: el sistema puede matar y volver a levantar la extensión **sin** que `NEVPNStatus`
    /// deje de ser `connected`, y el productor recrea el fichero del ring al arrancar cada sesión
    /// (`createFile` lo trunca). El mapeo que la app tenía se queda entonces mirando un inodo huérfano y
    /// el feed se congela **sin dar un solo error** — que es lo peor que puede pasarle a esta pantalla,
    /// porque un cero honesto y un cero por avería se pintan igual.
    ///
    /// Volver del segundo plano es justo cuando esa muerte ha podido ocurrir sin nadie delante, y cuando
    /// el usuario vuelve a mirar. Cuesta un `mmap` por vuelta a primer plano, no por fotograma.
    public func sceneDidBecomeActive() async {
        guard isFeedLive else { return }
        await liveFeed.reattach()
    }

    // MARK: - Derivados

    /// Velocidad de la barra más reciente del gráfico, que es lo que la ficha de "ahora mismo" enseña.
    /// La última barra siempre existe: `ThroughputWindow` rellena los huecos a cero justo para eso.
    public var currentRateIn: Double { snapshot.throughput.last?.bytesInPerSecond ?? 0 }
    public var currentRateOut: Double { snapshot.throughput.last?.bytesOutPerSecond ?? 0 }

    /// Si la extensión ha tenido que descartar registros por back-pressure. La Dashboard lo enseña
    /// "honesto y discreto": es la única señal de que el feed no lo está viendo todo.
    public var isDroppingRecords: Bool { snapshot.droppedRecords > 0 }

    /// Si el lector tiene el ring abierto. En falso la pantalla dice que espera al túnel, **no** que
    /// haya un error: en una app recién instalada el fichero no existe hasta que la extensión arranca.
    public var isAttached: Bool { snapshot.isAttached }

    // MARK: - Peticiones de fuera de la pantalla

    /// Que alguien de fuera haya pedido encender. Hoy solo lo pide la última tarjeta del intro, que se
    /// despide con *Start monitoring* (M10) y aterriza en esta pantalla.
    ///
    /// Es una **petición** y no una orden, y ahí está la decisión: quién la traduce en un gesto es la
    /// Dashboard, con la misma `MonitoringPresentation` que ya gobierna su botón, así que un perfil sin
    /// instalar pasa por la hoja de explicación y uno ya instalado arranca directo. Resolverlo aquí
    /// sería una segunda copia de esa regla, y la primera vez que las dos discrepasen el intro traería
    /// el diálogo del sistema en frío, que es justo lo que la spec prohíbe.
    public private(set) var hasPendingStartRequest = false

    public func requestStart() {
        hasPendingStartRequest = true
    }

    /// La consume la pantalla al atenderla. Sin esto, volver a esta pestaña la atendería otra vez, y
    /// un usuario que paró la monitorización a mano se la vería arrancar sola al pasar por aquí.
    public func startRequestHandled() {
        hasPendingStartRequest = false
    }

    // MARK: - Interno

    private func apply(_ snapshot: LiveFeedSnapshot) {
        self.snapshot = snapshot
        topTalkers = TopTalkers.compute(from: snapshot.recent, limit: topTalkerLimit)
    }
}
