import Foundation
import Observation
import Shared

/// El view model del flujo guiado de la CA local (M10, pasos 0–4 de
/// `docs/ux/onboarding-and-consent.md`).
///
/// Orquesta lo único que la app puede hacer de este flujo —crear la CA, preparar el perfil que iOS
/// instala, volver a preguntar si el sistema confía, rehacerla y quitarla— contra las costuras que ya
/// existían (`CertificateStatusReader`, `LocalCA`) más una nueva (`CertificateProfileExporter`). Tres
/// reglas gobiernan todo lo que hay aquí, y ninguna es de dibujo:
///
/// 1. **Dónde está el usuario lo dice el sistema, no un contador.** La etapa se deriva del estado de
///    la CA en cada vuelta (`CertificateSetupPolicy.stage`), así que instalar el certificado con la app
///    en segundo plano y volver deja la pantalla donde toca. Un contador de pasos propio se
///    desincronizaría en cuanto el usuario hiciera algo fuera de la app, que aquí es **lo normal**.
/// 2. **Antes de tocar la CA se apaga la inspección, y si no se puede apagar no se toca la CA.** El
///    ajuste guardado es lo único que gobierna a la extensión: dejarlo encendido con una raíz que
///    acaba de dejar de valer no deja al usuario como estaba, lo deja peor — la extensión terminaría
///    los handshakes con un leaf que el dispositivo ya no ancla y el tráfico que hoy funciona dejaría
///    de funcionar. Que el cambio no alcance a la **sesión viva** sí se tolera: sin clave raíz la
///    extensión no puede firmar nada, así que la inspección se cae sola por falta de CA.
/// 3. **Nada se afirma sin haberlo preguntado.** Con el llavero ilegible no se ofrece crear (crearía
///    encima de la CA que el usuario ya instaló), y comprobar la confianza y que siga sin haberla
///    **no es un fallo**: es el estado normal entre el paso 2 y el paso 3.
///
/// Es `@MainActor` y `@Observable` como los demás; el llavero, el disco y la evaluación de confianza
/// viven detrás de costuras `async` a las que se les habla con `await`.
@MainActor
@Observable
public final class CertificateSetupViewModel {

    // MARK: - Costuras

    /// Lo que se sabe de la CA. En producción, `CertificateStatusReader`.
    public typealias StatusSource = @Sendable () async -> CertificateStatus

    /// El certificado raíz en DER, o `nil` si no hay CA. Es lo que se mete en el perfil.
    public typealias RootCertificateSource = @Sendable () async throws -> Data?

    /// Crear la CA (reemplaza la anterior, si la había) y quitarla del llavero.
    public typealias KeychainOperation = @Sendable () async throws -> Void

    // MARK: - Lo que pinta la vista

    /// Lo que se sabe de la CA, o `nil` mientras no se ha preguntado. Es un opcional a propósito: el
    /// flujo abre por el paso 0, que no necesita saber nada, y un valor inventado de arranque
    /// afirmaría algo del llavero antes de haberlo mirado.
    public private(set) var status: CertificateStatus?

    public private(set) var activity: CertificateSetupActivity = .idle

    public private(set) var notice: CertificateSetupNotice?

    /// La confirmación pendiente de una acción destructiva, o `nil`.
    public private(set) var confirmation: CertificateSetupConfirmation?

    /// El perfil listo para entregarle al sistema. Lo consume el share sheet de la pantalla.
    public private(set) var profileURL: URL?

    /// Si toca enseñar cómo quitar el perfil de los Ajustes de iOS. Se pone al borrar la clave y no
    /// antes: hasta entonces no hay nada que retirar.
    public private(set) var showsRemovalGuidance = false

    /// Si el usuario ha leído el paso 0 en esta visita. Solo gobierna la puerta que hay delante de
    /// **crear** la CA (`CertificateSetupPolicy.stage`).
    public private(set) var tradeOffAcknowledged = false

    /// El ajuste guardado, que es lo que gobierna a la extensión. No es lo mismo que "se puede
    /// encender": eso lo dice la CA.
    public private(set) var inspectionEnabled = false

    /// Que el flujo pide cerrarse. Lo atiende quien lo presenta.
    public private(set) var isFinished = false

    // MARK: - Dependencias

    private let readStatus: StatusSource
    private let rootCertificate: RootCertificateSource
    private let generateCA: KeychainOperation
    private let removeCA: KeychainOperation
    private let exporter: CertificateProfileExporter
    private let store: SettingsStore
    private let send: @Sendable (ControlCommand) async throws -> ControlResponse

    public init(
        readStatus: @escaping StatusSource,
        rootCertificate: @escaping RootCertificateSource,
        generateCA: @escaping KeychainOperation,
        removeCA: @escaping KeychainOperation,
        exporter: CertificateProfileExporter,
        store: SettingsStore,
        send: @escaping @Sendable (ControlCommand) async throws -> ControlResponse
    ) {
        self.readStatus = readStatus
        self.rootCertificate = rootCertificate
        self.generateCA = generateCA
        self.removeCA = removeCA
        self.exporter = exporter
        self.store = store
        self.send = send
    }

    /// La construcción normal: el llavero compartido y el controlador del túnel.
    ///
    /// Las tres operaciones de `LocalCA` necesitan entitlements de dispositivo, así que este `init` se
    /// valida **por compilación** como `NETunnelProviderManagerAdapter` o `PacketTunnelProvider`; lo
    /// que se prueba en Simulator es todo lo de arriba, contra costuras.
    public convenience init(
        reader: CertificateStatusReader,
        controller: TunnelController,
        store: SettingsStore,
        keychain: LocalCA.KeychainConfiguration = LocalCA.KeychainConfiguration(),
        exporter: CertificateProfileExporter = CertificateProfileExporter()
    ) {
        self.init(
            readStatus: { await reader.status() },
            rootCertificate: { try await LocalCA.load(keychain: keychain)?.exportRootCertificateDER() },
            generateCA: { _ = try LocalCA.generate(keychain: keychain) },
            removeCA: { try LocalCA.load(keychain: keychain)?.removeFromKeychain() },
            exporter: exporter,
            store: store,
            send: { command in try await controller.send(command) }
        )
    }

    // MARK: - Derivados

    public var stage: CertificateSetupStage {
        guard let status else { return .explainTradeOff }
        return CertificateSetupPolicy.stage(for: status, tradeOffAcknowledged: tradeOffAcknowledged)
    }

    public var presentation: CertificateSetupPresentation {
        CertificateSetupPresentation.forStage(stage, inspectionEnabled: inspectionEnabled)
    }

    public var canRegenerate: Bool {
        status.map(CertificateSetupPolicy.canRegenerate) ?? false
    }

    public var canRemove: Bool {
        status.map(CertificateSetupPolicy.canRemove) ?? false
    }

    // MARK: - Entrada y salida

    /// Abrir el flujo. Lo llama la pantalla al aparecer.
    ///
    /// **Cada visita vuelve a explicar el paso 0** antes de ofrecer crear nada: la explicación es la
    /// puerta que hay delante de una decisión, no un trámite que se despacha una vez y ya. Lo que sí
    /// se conserva es lo que el sistema dice de la CA, que se vuelve a preguntar acto seguido.
    public func start() async {
        isFinished = false
        tradeOffAcknowledged = false
        notice = nil
        confirmation = nil
        showsRemovalGuidance = false
        await refresh()
    }

    /// Volver a preguntar por la CA y por el ajuste guardado. La dispara volver del segundo plano y el
    /// tirar para refrescar: el usuario se ha ido a los Ajustes de iOS y puede volver con otra
    /// respuesta.
    public func refresh() async {
        activity = .checking
        defer { activity = .idle }
        await reloadStatus()
        loadInspectionSetting()
    }

    public func finish() {
        isFinished = true
    }

    public func dismissNotice() {
        notice = nil
        showsRemovalGuidance = false
    }

    public func dismissConfirmation() {
        confirmation = nil
    }

    /// El perfil ya se ha entregado (o el usuario ha cerrado la hoja sin entregarlo).
    ///
    /// **No borra el fichero**, por lo mismo que el export de conexiones no lo borra al cerrar su hoja:
    /// la hoja del sistema puede seguir leyéndolo mientras se cierra, y quien se lo lleva es la
    /// siguiente escritura o el cambio de CA. Lo que se suelta es la *petición* de entregarlo, y por eso
    /// vive aquí y no en la vista: sin soltarla, volver a pedir el mismo perfil escribiría la misma URL
    /// y la vista no tendría forma de distinguir "otra vez" de "todavía".
    public func dismissProfile() {
        profileURL = nil
    }

    // MARK: - Las acciones de la etapa

    /// El despachador que usa la vista: cada botón lleva su acción y no un `if` sobre la etapa.
    public func perform(_ action: CertificateSetupAction) async {
        switch action {
        case .acknowledgeTradeOff:
            acknowledgeTradeOff()
        case .generate:
            await generate()
        case .shareProfile:
            await prepareProfile()
        case .recheckTrust:
            await recheckTrust()
        case .enableInspection:
            await enableInspection()
        case .finish:
            finish()
        case .retryStatus:
            await refresh()
        }
    }

    /// El paso 0, leído. No crea nada: solo abre la puerta que hay delante de crear.
    public func acknowledgeTradeOff() {
        tradeOffAcknowledged = true
    }

    /// Paso 1. Solo cuando **consta** que no hay CA: rehacer la que ya existe es otra acción, con su
    /// propia confirmación, porque se lleva por delante el certificado que el usuario instaló.
    public func generate() async {
        guard let status, CertificateStatusPolicy.canGenerate(status) else { return }
        await createCertificate()
    }

    /// Paso 2: preparar el perfil y dejarlo en disco para el share sheet.
    ///
    /// Se construye **cada vez** desde la raíz del llavero en lugar de guardarse el de la última
    /// generación: el fichero es determinista (`CertificateProfile.make`), así que reconstruirlo no
    /// cuesta nada y evita el único fallo interesante — entregar el perfil de una raíz que ya no es la
    /// que firma.
    public func prepareProfile() async {
        activity = .preparingProfile
        defer { activity = .idle }

        let certificate: Data?
        do {
            certificate = try await rootCertificate()
        } catch {
            notice = CertificateSetupPresentation.profileUnavailable(String(describing: error))
            return
        }
        guard let certificate else {
            // La CA ha desaparecido entre dos vueltas. No es una avería del gesto: ya no hay qué
            // entregar, y la etapa tiene que volver a donde de verdad está el usuario.
            notice = CertificateSetupPresentation.certificateMissing
            profileURL = nil
            await reloadStatus()
            return
        }

        do {
            profileURL = try await exporter.write(CertificateProfile.make(rootCertificateDER: certificate))
        } catch {
            notice = CertificateSetupPresentation.profileUnavailable(String(describing: error))
        }
    }

    /// Paso 3→4: volver a preguntarle al sistema. Es la **única** forma de saber si los dos pasos de
    /// los Ajustes de iOS se hicieron, porque no se pueden observar: se comprueba el resultado.
    public func recheckTrust() async {
        await refresh()
        guard let status else { return }
        switch status.authority {
        case .generated(.trusted):
            notice = CertificateSetupPresentation.nowTrusted
        case .generated(.installedWithoutFullTrust):
            // El único caso en el que se puede nombrar el gesto que falta en vez de repetir los dos.
            notice = CertificateSetupPresentation.installedButNotFullyTrusted
        case .generated(.notTrusted), .generated(.cannotEvaluate):
            notice = CertificateSetupPresentation.stillNotTrusted
        case .notGenerated:
            notice = CertificateSetupPresentation.certificateMissing
        case .unknown:
            // La etapa entera pasa a explicar que no se pudo mirar; un aviso encima diría lo mismo dos
            // veces.
            notice = nil
        }
    }

    /// Paso 4: encender la inspección, que es lo que el flujo venía a conseguir. Solo desde la etapa
    /// `ready`: el resto de etapas no pueden afirmar que el sistema confíe en la raíz.
    public func enableInspection() async {
        guard stage == .ready, !inspectionEnabled else { return }
        switch await setInspection(true) {
        case .ok:
            notice = CertificateSetupPresentation.inspectionTurnedOn
        case .liveNotApplied(let detail):
            notice = CertificateSetupPresentation.inspectionOnButNotLive(detail)
        case .failed(let detail):
            notice = CertificateSetupPresentation.inspectionCouldNotBeTurnedOn(detail)
        }
    }

    // MARK: - Las dos acciones destructivas

    public func requestRegenerate() {
        guard canRegenerate else { return }
        confirmation = CertificateSetupPresentation.regenerate
    }

    public func requestRemove() {
        guard canRemove else { return }
        confirmation = CertificateSetupPresentation.remove
    }

    /// Ejecuta una confirmación aceptada.
    ///
    /// **Recibe la confirmación en vez de leerla del estado, y eso es el arreglo de un fallo real**
    /// (2026-08-23, visto en el iPhone): un `confirmationDialog` de SwiftUI **se descarta antes** de
    /// ejecutar la acción de su botón, así que para cuando esto corría, el `set` del binding ya había
    /// llamado a `dismissConfirmation()` y `confirmation` era `nil`. El `guard let` de la primera
    /// línea se salía sin hacer nada y sin decirlo: salía el diálogo, se aceptaba y no pasaba nada.
    /// El valor lo entrega el propio diálogo por su closure `presenting`, que es lo que ya hacía —y
    /// por lo que sí funcionaba— la confirmación de borrado de Captures.
    ///
    /// Se vuelve a comprobar la regla, y no por desconfianza del botón: entre pedir la confirmación y
    /// aceptarla puede haber pasado un refresco que cambie lo que se puede ofrecer — la pantalla
    /// relee el estado de la CA cada vez que la escena vuelve a estar activa, que es justo lo que
    /// ocurre al volver de los Ajustes de iOS. Cuando la regla ya no se cumple **no se toca nada y se
    /// dice**: una acción destructiva confirmada que no se lleva a cabo y no lo cuenta es
    /// indistinguible de una app rota.
    public func confirm(_ confirmation: CertificateSetupConfirmation) async {
        self.confirmation = nil
        switch confirmation.kind {
        case .regenerate:
            guard canRegenerate else { return await nothingToChange() }
            guard await turnInspectionOffBeforeTouchingTheCA() else { return }
            await createCertificate()
        case .remove:
            guard canRemove else { return await nothingToChange() }
            guard await turnInspectionOffBeforeTouchingTheCA() else { return }
            await deleteCertificate()
        }
    }

    /// Lo confirmado ya no se puede hacer. Se cuenta y **se relee el estado**, para que la pantalla
    /// quede diciendo lo que de verdad hay en vez de lo que había cuando se ofreció el botón.
    private func nothingToChange() async {
        await reloadStatus()
        notice = CertificateSetupPresentation.nothingToChange
    }

    // MARK: - Interno

    private func reloadStatus() async {
        status = await readStatus()
    }

    /// El ajuste guardado. Que no se deje leer se resuelve como "apagada", que es el estado de fábrica
    /// y el único seguro: lo contrario ofrecería apagar algo que quizá no está encendido. Contarlo es
    /// de la pantalla de Ajustes, que lee el mismo almacén y tiene sitio para decirlo.
    private func loadInspectionSetting() {
        inspectionEnabled = (try? store.load())?.tlsInspectionEnabled ?? false
    }

    /// Crear la CA, venga de la etapa 1 o de rehacerla. El perfil anterior se tira **antes**: es el de
    /// una raíz que está a punto de dejar de existir, y compartirlo instalaría un ancla que no firma
    /// nada.
    private func createCertificate() async {
        activity = .generating
        defer { activity = .idle }

        await exporter.discard()
        profileURL = nil
        // Una CA nueva deja sin sentido las instrucciones de retirar el perfil de la anterior, y en la
        // misma visita las dos cosas se quedaban en pantalla a la vez: *quita el perfil* encima de
        // *instala este certificado*, que son órdenes contradictorias. Además el perfil nuevo lleva el
        // mismo identificador y **reemplaza** al viejo al instalarse (`CertificateProfile.identifier`),
        // así que no hay nada que retirar aparte. Medido en Simulator el 2026-08-23, borrando y
        // creando seguido.
        showsRemovalGuidance = false

        do {
            try await generateCA()
        } catch {
            notice = CertificateSetupPresentation.generationFailed(String(describing: error))
            return
        }

        await reloadStatus()
        notice = CertificateSetupPresentation.certificateCreated
    }

    private func deleteCertificate() async {
        activity = .removing
        defer { activity = .idle }

        do {
            try await removeCA()
        } catch {
            notice = CertificateSetupPresentation.removalFailed(String(describing: error))
            return
        }

        await exporter.discard()
        profileURL = nil
        // Volver a encenderla es volver a tomar la misma decisión, así que el flujo vuelve a su
        // explicación en vez de dejar al usuario a un toque de crear otra CA sin más.
        tradeOffAcknowledged = false
        showsRemovalGuidance = true
        await reloadStatus()
        notice = CertificateSetupPresentation.certificateRemoved
    }

    /// La regla 2, en una función: apagar la inspección antes de tocar la CA, y no tocarla si no se
    /// pudo apagar. Que el cambio no alcance a la sesión viva **sí** deja seguir: sin clave raíz la
    /// extensión no puede firmar ningún leaf, así que la inspección se cae por sí sola.
    private func turnInspectionOffBeforeTouchingTheCA() async -> Bool {
        switch await setInspection(false) {
        case .ok, .liveNotApplied:
            return true
        case .failed(let detail):
            notice = CertificateSetupPresentation.inspectionCouldNotBeTurnedOff(detail)
            return false
        }
    }

    /// Cómo terminó una escritura del ajuste de inspección.
    private enum InspectionWrite: Equatable {
        /// Guardado, y la sesión viva (si la había) lo cogió.
        case ok
        /// Guardado, pero la sesión en curso no lo aplicó.
        case liveNotApplied(String)
        /// No se pudo guardar: lo duradero sigue como estaba.
        case failed(String)
    }

    /// Escribe el ajuste de inspección en el almacén compartido y lo aplica en caliente.
    ///
    /// Lee, cambia un campo y guarda el blob entero, igual que la pantalla de Ajustes y que el intro:
    /// el almacén guarda un solo valor. Se lee **del disco** y no de una copia en memoria a propósito
    /// — esta pantalla no es la dueña de los ajustes, y escribir un blob que lleve en memoria desde
    /// antes se llevaría por delante lo que el usuario haya cambiado mientras tanto. Un blob ilegible
    /// se repara escribiendo encima, que es lo que ya hacen las otras dos escrituras del producto.
    private func setInspection(_ enabled: Bool) async -> InspectionWrite {
        do {
            var settings: AppSettings
            do {
                settings = try store.load()
            } catch SettingsStoreError.corruptData {
                settings = .default
            }
            if settings.tlsInspectionEnabled != enabled {
                settings.tlsInspectionEnabled = enabled
                try store.save(settings)
            }
            inspectionEnabled = enabled
        } catch {
            return .failed(String(describing: error))
        }

        do {
            switch try await send(.setTLSInspectionEnabled(enabled)) {
            case .ok:
                return .ok
            case .notRunning:
                // La carrera normal entre la UI y `stopTunnel`. No hay sesión que aplicar nada y el
                // ajuste ya está guardado para la siguiente.
                return .ok
            case .failed(let detail):
                return .liveNotApplied(detail)
            case .stats:
                return .liveNotApplied("Unexpected reply from the tunnel.")
            }
        } catch TunnelControlError.notRunning {
            return .ok
        } catch {
            return .liveNotApplied(String(describing: error))
        }
    }
}
