import Foundation
import Observation
import Shared

/// El sitio donde se construyen los servicios de la app y se reparten hacia abajo (M9).
///
/// Existe para que la propiedad de los objetos de larga vida esté en **un** sitio y no repartida en
/// `@State` por las vistas: el controlador del túnel y el lector del feed viven lo que vive la app,
/// mientras que las vistas se crean y se destruyen con la navegación. También es la frontera con lo
/// device-only: es el único punto de la app que nombra `NETunnelProviderManagerAdapter`, así que
/// sustituirlo por un doble en un preview o en un test es cambiar una línea.
///
/// Es `@MainActor` porque todo lo que retiene lo es (`TunnelController`, los view models); el
/// `LiveFeedReader` es un actor y se le habla con `await` desde el view model, nunca desde la vista.
@MainActor
@Observable
public final class AppEnvironment {

    public let tunnelController: TunnelController

    /// El lector del feed en vivo. La app entera comparte uno: el ring es de un solo consumidor
    /// (contrato SPSC de `docs/spec/ipc.md`), así que abrir un segundo lector se llevaría registros
    /// que el primero ya no vería.
    public let liveFeed: LiveFeedReader

    public let dashboard: DashboardViewModel

    public let timeline: TimelineViewModel

    public let captures: CapturesViewModel

    public let settings: SettingsViewModel

    /// El diagnóstico de la sesión. Vive aquí, y no en `@State` de la pantalla que lo abre, por lo
    /// mismo que el resto: lo que sabe es de la sesión del túnel —no de la navegación—, así que entrar
    /// y salir de Ajustes no puede vaciarlo.
    public let diagnostics: DiagnosticsViewModel

    /// El intro de la primera ejecución (M10). Vive aquí y no dentro de una pantalla porque no es de
    /// ninguna: lo decide el arranque, lo cierra el usuario y lo puede volver a pedir Ajustes, así que
    /// el único sitio donde las tres cosas ven el mismo objeto es el entorno.
    public let intro: IntroViewModel

    /// El flujo guiado de la CA (M10). Vive aquí por lo mismo que el intro: se abre desde Ajustes pero
    /// no es de Ajustes —lo que cambia (la CA del llavero, el ajuste de inspección) lo miran también
    /// otras pantallas—, y el estado del recorrido tiene que sobrevivir a que el usuario se vaya a los
    /// Ajustes de iOS y vuelva.
    public let certificateSetup: CertificateSetupViewModel

    /// El directorio de capturas. Se expone además de dárselo a `CapturesViewModel` porque la pantalla
    /// de un paquete también lee de ahí (sus bytes), y como el servicio no tiene estado, compartir la
    /// misma instancia no comparte nada: es solo no construir dos veces lo mismo.
    public let captureLibrary: CaptureLibrary

    /// El directorio de contenido descifrado. Se expone por lo mismo que el de capturas: no tiene
    /// estado —resuelve el contenedor en cada operación, porque quien escribe ahí es otro proceso— y
    /// quien lee de él es una pantalla que se crea y se destruye con la navegación.
    public let plaintextLibrary: PlaintextLibrary

    /// El historial se pasa como **fábrica y no como lector ya construido** a propósito: abrirlo toca
    /// disco (SQLite en el contenedor del App Group, con sus migraciones) y puede fallar. Construirlo
    /// aquí obligaría a este `init` a lanzar o a tragarse el error, y un historial ilegible dejaría sin
    /// app también a la Dashboard, que no lo necesita para nada. Con la fábrica, el fallo es un estado
    /// de la pantalla que lo usa y su botón de reintentar vuelve a intentar la apertura de verdad.
    ///
    /// El directorio de capturas, en cambio, entra como servicio ya construido: `CaptureLibrary` no
    /// abre nada al crearse — resuelve el contenedor en cada operación —, así que no hay fallo que
    /// diferir.
    /// El almacén de ajustes y el gestor de almacenamiento entran ya construidos, como
    /// `CaptureLibrary` y al revés que el historial: ninguno de los dos abre nada al crearse —el
    /// almacén resuelve su `UserDefaults` y el gestor su directorio en cada operación—, así que no
    /// hay fallo que diferir.
    public init(
        tunnelController: TunnelController,
        liveFeed: LiveFeedReader,
        captureLibrary: CaptureLibrary,
        plaintextLibrary: PlaintextLibrary,
        flowExporter: FlowExporter,
        settingsStore: SettingsStore,
        storage: StorageManager,
        certificates: CertificateStatusReader,
        makeHistoryReader: @escaping @Sendable () async throws -> HistoryReader
    ) {
        self.tunnelController = tunnelController
        self.liveFeed = liveFeed
        self.captureLibrary = captureLibrary
        self.plaintextLibrary = plaintextLibrary
        self.dashboard = DashboardViewModel(liveFeed: liveFeed)
        self.timeline = TimelineViewModel(makeReader: makeHistoryReader)
        self.captures = CapturesViewModel(
            library: captureLibrary,
            exporter: flowExporter,
            controller: tunnelController,
            // El mismo almacén que Ajustes: la pantalla de capturas compara su inventario con los
            // topes que el usuario eligió allí, y leerlos de otro sitio sería comparar contra unos
            // topes que pueden no ser los suyos.
            settingsStore: settingsStore,
            makeHistoryReader: makeHistoryReader
        )
        self.settings = SettingsViewModel(
            store: settingsStore,
            storage: storage,
            library: captureLibrary,
            controller: tunnelController,
            // La disponibilidad de la inspección entra como closure y se relee en cada refresco: el
            // usuario puede retirar la confianza del certificado desde los Ajustes de iOS entre dos
            // visitas a la pantalla, así que es lo contrario de un valor que se pueda guardar.
            availability: { await certificates.availability() }
        )
        self.diagnostics = AppEnvironment.makeDiagnostics(controller: tunnelController)
        // El mismo lector que alimenta esa closure, y el mismo almacén que edita Ajustes: el flujo
        // guiado escribe el interruptor de inspección al terminar y al deshacerlo, y las dos mitades
        // tienen que estar mirando el mismo blob.
        self.certificateSetup = CertificateSetupViewModel(
            reader: certificates,
            controller: tunnelController,
            store: settingsStore
        )
        // El mismo almacén que la pantalla de Ajustes, porque es el mismo blob: si el intro guardara
        // en otro sitio, "ya lo he visto" y "estas son mis preferencias" serían dos verdades que
        // pueden desaparecer por separado.
        self.intro = IntroViewModel(store: settingsStore)
    }

    /// Los servicios de producción: la cáscara real de NetworkExtension, el ring del App Group, el
    /// directorio de capturas compartido y la base de datos que escribe la extensión.
    public convenience init() {
        // El directorio de capturas se construye una vez y se comparte con el gestor de
        // almacenamiento: el servicio no tiene estado, así que compartirlo no comparte nada — es
        // solo no construir dos veces lo mismo, y garantiza que ambos miren al mismo sitio.
        let captureLibrary = CaptureLibrary()
        self.init(
            tunnelController: TunnelController(manager: NETunnelProviderManagerAdapter()),
            liveFeed: LiveFeedReader(),
            captureLibrary: captureLibrary,
            plaintextLibrary: PlaintextLibrary(),
            // El export escribe en el temporal de la app y no en el contenedor compartido: no es una
            // captura, y dejarlo entre ellas lo metería en el listado y en los planes de retención.
            flowExporter: FlowExporter(),
            settingsStore: SettingsStore(),
            storage: StorageManager(
                library: captureLibrary,
                openingStore: { try FlowStore(appGroupID: AppGroup.identifier) },
                plaintextDirectory: PlaintextDirectory.url(inAppGroup: AppGroup.identifier)
            ),
            // La CA del llavero compartido: los mismos items que usa la extensión para firmar leaves,
            // no una copia publicada de su estado (`CertificateStatusReader`).
            certificates: CertificateStatusReader(),
            makeHistoryReader: {
                HistoryReader(store: try FlowStore(appGroupID: AppGroup.identifier))
            }
        )
    }

    /// El diagnóstico de la sesión, sembrado si el sembrador de Simulator está pedido.
    ///
    /// Se decide aquí y no dentro del view model porque es la misma decisión que ya toma este
    /// arranque para el historial, y porque el sembrador de verdad no puede alcanzar esta pantalla:
    /// escribe en el contenedor compartido y estos contadores viajan por el canal de control, así que
    /// una app sembrada seguía enseñando *Session diagnostics* vacía — la única pantalla que no se
    /// podía mirar entera desde una sesión de Simulator.
    private static func makeDiagnostics(controller: TunnelController) -> DiagnosticsViewModel {
        #if DEBUG
        if FixtureSeeding.request() == .seed {
            return DiagnosticsViewModel(seeded: TunnelStatsFixture.make())
        }
        #endif
        return DiagnosticsViewModel(controller: controller)
    }
}
