import Foundation
import Observation
import Shared

/// El view model de la pantalla de Ajustes (M9): la capa entre lo que el usuario elige y las tres
/// cosas que eso toca — el almacén compartido que lee la extensión (`SettingsStore`), la sesión viva
/// (el canal de control) y el disco (`StorageManager`).
///
/// Tres reglas gobiernan todo lo que hay aquí, y ninguna es de dibujo:
///
/// 1. **Se guarda primero y se aplica en caliente después.** Lo duradero es el almacén: un comando
///    perdido en una carrera con `stopTunnel` no puede dejar el ajuste sin guardar, mientras que al
///    revés el usuario solo pierde que el cambio alcance a la sesión en curso — y eso se le dice.
/// 2. **Un ajuste que no se pudo guardar vuelve a su valor anterior.** Dejar el interruptor en la
///    posición nueva afirmaría que se guardó, que es exactamente lo que no pasó.
/// 3. **Nada se borra sin saber qué fichero está abierto.** El fichero que la extensión está
///    escribiendo no se toca nunca, y quién es se deduce del listado del directorio
///    (`CapturesPresentation.recordingSequence`) — la misma y única forma que usa la pantalla de
///    capturas. Sin listado no hay forma de saberlo, así que no se borra.
///
/// Es `@MainActor` y `@Observable` como los demás view models de la app; el disco vive detrás de dos
/// actores (`StorageManager`, `CaptureLibrary`) a los que se les habla con `await`.
@MainActor
@Observable
public final class SettingsViewModel {

    // MARK: - Lo que pinta la vista

    /// Lo que hay guardado ahora mismo, que es también lo que la extensión leerá al arrancar.
    public private(set) var settings: AppSettings = .default

    /// `nil` hasta la primera lectura del disco con éxito.
    public private(set) var usage: StorageUsage?

    public private(set) var activity: SettingsActivity = .idle

    public private(set) var notice: SettingsNotice?

    /// Si la inspección TLS se puede encender. Se consulta aparte de los ajustes porque es un hecho
    /// del dispositivo (¿está la CA instalada y confiada?) y no una preferencia guardada.
    public private(set) var tlsAvailability: TLSInspectionAvailability = .certificateNotReady

    /// Si el túnel está vivo, que es lo que decide si hay un fichero abierto ahora mismo y si tiene
    /// sentido mandar un cambio en caliente. Lo empuja la vista desde el controlador, igual que en la
    /// pantalla de capturas.
    public private(set) var isMonitoring: Bool = false

    // MARK: - Dependencias

    private let store: SettingsStore
    private let storage: StorageManager
    private let library: CaptureLibrary
    private let send: @Sendable (ControlCommand) async throws -> ControlResponse

    /// Se lee en cada refresco y no se cachea, por lo mismo que `TLSInterceptor` relee su `caReady`:
    /// el usuario puede quitar la confianza del certificado desde los Ajustes de iOS entre dos
    /// visitas a esta pantalla, y un valor cacheado seguiría ofreciendo encender lo que ya no se
    /// puede.
    private let availability: @Sendable () async -> TLSInspectionAvailability

    public init(
        store: SettingsStore,
        storage: StorageManager,
        library: CaptureLibrary,
        send: @escaping @Sendable (ControlCommand) async throws -> ControlResponse,
        availability: @escaping @Sendable () async -> TLSInspectionAvailability
    ) {
        self.store = store
        self.storage = storage
        self.library = library
        self.send = send
        self.availability = availability
    }

    /// La construcción normal: el controlador del túnel como canal de control.
    ///
    /// La disponibilidad de la CA entra como closure y no como valor porque es un hecho del
    /// dispositivo que puede cambiar entre dos refrescos. Desde M10 la puebla de verdad
    /// `CertificateStatusReader` (el llavero compartido + `SecTrust`), y `AppEnvironment` es quien la
    /// enchufa; el default sigue siendo el "no se puede" para previews y tests, que no tienen llavero
    /// que mirar.
    public convenience init(
        store: SettingsStore,
        storage: StorageManager,
        library: CaptureLibrary,
        controller: TunnelController,
        availability: @escaping @Sendable () async -> TLSInspectionAvailability = { .certificateNotReady }
    ) {
        self.init(
            store: store,
            storage: storage,
            library: library,
            send: { command in try await controller.send(command) },
            availability: availability
        )
    }

    // MARK: - Carga

    /// Lee los ajustes, comprueba si la inspección se puede encender, **aplica los topes** y mide el
    /// disco. La dispara la aparición de la pantalla y el tirar para refrescar.
    ///
    /// Los topes se aplican aquí porque hoy este es el único sitio que los hace valer: la retención
    /// la ejecuta la app, así que con la app cerrada nadie corta nada. Aplicarlos al abrir la
    /// pantalla no es una sorpresa —es lo que un tope significa, y el pie del bloque lo dice con
    /// todas las letras—, y la medida se toma **después** para que la cifra sea la de después de
    /// limpiar y no la de un directorio que ya no existe así.
    public func refresh() async {
        if usage == nil { activity = .loading }
        defer { activity = .idle }

        loadSettings()
        tlsAvailability = await availability()
        await enforceCaps(trigger: .automatic)
        await refreshUsage()
    }

    /// Sincroniza con el estado del túnel. Solo `live` cuenta como "hay alguien escribiendo", por lo
    /// mismo que en la pantalla de capturas: en `starting`/`stopping` el writer aún no existe o ya se
    /// cerró.
    public func tunnelStateDidChange(to state: TunnelState) {
        isMonitoring = (state == .live)
    }

    // MARK: - Ajustes

    /// Encender la inspección exige que la CA esté lista; **apagarla no exige nada**, porque una
    /// función que solo se puede desactivar cuando el sistema coopera sería irreversible en la
    /// práctica, y la reversibilidad es innegociable (`docs/ux/onboarding-and-consent.md`).
    public func setTLSInspection(_ enabled: Bool) async {
        if enabled, tlsAvailability != .ready {
            notice = SettingsPresentation.tlsCannotBeEnabled
            return
        }
        var updated = settings
        updated.tlsInspectionEnabled = enabled
        await save(updated, liveCommand: .setTLSInspectionEnabled(enabled))
    }

    /// Vuelve a preguntarle al sistema por la CA y **apaga la inspección si ya no la acepta**.
    ///
    /// Es la mitad que faltaba del interruptor: `setTLSInspection` comprueba la confianza al
    /// **encender**, pero el ajuste es duradero y la confianza no. Entre dos arranques el usuario
    /// puede retirarla desde los Ajustes de iOS, y entonces la inspección sigue encendida terminando
    /// cada conexión al 443 con un certificado que nadie acepta: el dispositivo se queda **sin
    /// navegación**, y nada en pantalla lo explica. Eso ocurrió de verdad el 2026-08-15 —por un falso
    /// positivo de la comprobación, ya arreglado— y esto es lo que impide que vuelva a ocurrir por
    /// cualquier otra vía.
    ///
    /// La llama la raíz de la app al aparecer y al volver a primer plano, que es cuando el usuario
    /// puede haber estado justo en esos Ajustes. **No cuesta nada si no hay nada que hacer**: sin la
    /// inspección encendida no se apaga nada, y la respuesta del sistema no se cachea nunca.
    public func revalidateTLSTrust() async {
        let current = await availability()
        tlsAvailability = current
        guard CertificateStatusPolicy.mustRevokeInspection(
            availability: current,
            inspectionEnabled: settings.tlsInspectionEnabled
        ) else { return }

        // Se apagan por los mismos caminos que usa el usuario, y **el plaintext primero**: su comando
        // en caliente corta la grabación en el acto incluso para las conexiones que ya están
        // descifrando, mientras que apagar la inspección solo impide que nazcan terminaciones nuevas.
        // Al revés, una terminación viva seguiría escribiendo en claro un rato más.
        if settings.plaintextPersistenceEnabled {
            await setPlaintextPersistence(false)
        }
        await setTLSInspection(false)
        notice = SettingsPresentation.tlsTurnedOffByTrust
    }

    /// Guardar el contenido descifrado (ADR 0007). Es un ajuste propio y no un efecto de la
    /// inspección, y aquí eso significa dos cosas.
    ///
    /// **Encenderlo exige la inspección encendida**: sin ella no se descifra nada, así que sería un
    /// interruptor que no gobierna nada. **Apagarlo no exige nada**, por lo mismo que en la
    /// inspección — y aquí pesa más, porque lo que se revoca es el permiso de guardar lo que uno dice
    /// por dentro: el comando en caliente corta la grabación en el acto, incluso para las conexiones
    /// que ya están descifrando (`ControlCommand.setPlaintextPersistenceEnabled`).
    public func setPlaintextPersistence(_ enabled: Bool) async {
        if enabled, !settings.tlsInspectionEnabled {
            notice = SettingsPresentation.plaintextCannotBeEnabled
            return
        }
        guard enabled != settings.plaintextPersistenceEnabled else { return }
        var updated = settings
        updated.plaintextPersistenceEnabled = enabled
        await save(updated, liveCommand: .setPlaintextPersistenceEnabled(enabled))
    }

    /// El plazo del contenido descifrado. Se aplica en el acto igual que los topes de captura, y por
    /// una razón más: acortarlo es lo que hace un usuario que quiere que algo deje de estar guardado
    /// **ya**, y hacerle esperar al siguiente barrido convertiría esa decisión en una intención.
    public func setPlaintextRetentionAge(_ age: PlaintextRetentionAge) async {
        guard age != settings.retention.maxPlaintextAge else { return }
        var updated = settings
        updated.retention.maxPlaintextAge = age
        guard await save(updated, liveCommand: nil) else { return }
        await applyCapsNow()
    }

    public func setCaptureEnabled(_ enabled: Bool) async {
        var updated = settings
        updated.captureEnabled = enabled
        await save(updated, liveCommand: .setCaptureEnabled(enabled))
    }

    /// El detalle de captura sí alcanza a la sesión viva, y cuesta un fichero: el `snaplen` va en la
    /// cabecera global del `.pcap`, así que el detalle nuevo solo puede empezar en un fichero nuevo y
    /// la extensión **rota** al aplicarlo (`PcapWriter.setSnaplen`).
    ///
    /// Esa rotación es visible —aparece una captura más en la lista— así que se dice. Antes esto se
    /// guardaba y punto, con un aviso de que empezaría a valer en la siguiente sesión: era honesto,
    /// pero obligaba a apagar y encender la monitorización para algo que el usuario acababa de elegir.
    public func setCaptureDetail(_ detail: CaptureDetail) async {
        guard detail != settings.captureDetail else { return }
        var updated = settings
        updated.captureDetail = detail
        guard await save(updated, liveCommand: .setCaptureDetail(detail)) else { return }
        // Solo si `save` no dejó ya un aviso propio: el suyo cuenta que algo no salió, y taparlo con
        // este diría que se aplicó justo lo que no se aplicó.
        if isMonitoring, notice == nil {
            notice = SettingsPresentation.captureDetailStartedANewFile
        }
    }

    /// Cambiar un tope lo aplica en el acto: eso es lo que un tope significa, y el pie del bloque lo
    /// advierte antes de tocarlo. Lo que se haya borrado se cuenta —el gesto es del usuario y merece
    /// respuesta—, al revés que la aplicación automática al abrir la pantalla.
    public func setRetentionAge(_ age: RetentionAge) async {
        guard age != settings.retention.maxAge else { return }
        var updated = settings
        updated.retention.maxAge = age
        guard await save(updated, liveCommand: nil) else { return }
        await applyCapsNow()
    }

    public func setRetentionSize(_ size: RetentionSize) async {
        guard size != settings.retention.maxCaptureSize else { return }
        var updated = settings
        updated.retention.maxCaptureSize = size
        guard await save(updated, liveCommand: nil) else { return }
        await applyCapsNow()
    }

    // MARK: - Almacenamiento

    /// Aplica los topes ahora, a petición del usuario.
    public func applyCapsNow() async {
        guard activity == .idle else { return }
        activity = .enforcing
        defer { activity = .idle }

        await enforceCaps(trigger: .manual)
        await refreshUsage()
    }

    /// Borra **solo** el contenido descifrado: ni el historial ni las capturas (ADR 0007, punto 3).
    ///
    /// No pregunta qué captura está abierta —no toca ninguna— pero sí le pasa al barrido si se está
    /// monitorizando, que es lo que protege el `.tvpt` que la extensión pueda estar escribiendo.
    public func clearPlaintext() async {
        guard activity == .idle else { return }
        activity = .clearing
        defer { activity = .idle }

        let outcome = await storage.clearPlaintext(settings.retention, isMonitoring: isMonitoring)
        notice = SettingsPresentation.plaintextCleared(outcome, isMonitoring: isMonitoring)
        await refreshUsage()
    }

    /// Borra el historial entero y todas las capturas menos la que se esté escribiendo.
    public func clearEverything() async {
        guard activity == .idle else { return }
        guard let recording = await recordingSequence() else {
            notice = SettingsPresentation.recordingFileUnknown
            return
        }

        activity = .clearing
        defer { activity = .idle }

        do {
            let outcome = try await storage.clearEverything(recordingSequence: recording.value)
            // Vaciado el índice, **todo** fichero de contenido descifrado queda huérfano, y quien
            // sabe borrarlos del disco es el barrido. Sin esta segunda mitad, "borrarlo todo"
            // dejaría en el dispositivo justo lo más sensible que este producto llega a guardar.
            let plaintext = await storage.sweepPlaintext(settings.retention, isMonitoring: isMonitoring)
            notice = SettingsPresentation.cleared(outcome, plaintext: plaintext)
        } catch {
            notice = SettingsPresentation.storageUnavailable(String(describing: error))
        }
        await refreshUsage()
    }

    public func dismissNotice() {
        notice = nil
    }

    // MARK: - Derivados

    public var storageDisplay: StorageDisplay? {
        usage.map(SettingsPresentation.storage)
    }

    /// El interruptor de inspección se deja tocar si se puede encender **o** si ya está encendido:
    /// lo segundo es lo que garantiza que siempre se pueda apagar.
    public var isTLSInspectionEditable: Bool {
        tlsAvailability == .ready || settings.tlsInspectionEnabled
    }

    /// El interruptor de guardar lo descifrado se deja tocar si la inspección está encendida **o** si
    /// ya está guardando: lo segundo es lo que garantiza que siempre se pueda dejar de guardar, aunque
    /// la inspección se haya apagado por el camino.
    public var isPlaintextPersistenceEditable: Bool {
        settings.tlsInspectionEnabled || settings.plaintextPersistenceEnabled
    }

    /// Si hay algo que borrar con "borrarlo todo". Con el disco sin medir se asume que sí: negar el
    /// gesto por no haber podido medir sería peor que ofrecerlo y que no se lleve nada.
    public var hasAnythingToClear: Bool {
        guard let usage else { return true }
        return usage.captureFileCount > 0 || usage.historyFlowCount > 0 || usage.hasPlaintext
    }

    /// Si hay contenido descifrado que borrar. Misma regla que arriba con el disco sin medir.
    public var hasPlaintextToClear: Bool {
        guard let usage else { return true }
        return usage.hasPlaintext
    }

    // MARK: - Interno

    /// El resultado de resolver qué fichero está abierto: distingue "no hay ninguno" (`nil` dentro)
    /// de "no se ha podido saber" (`nil` fuera), que es justo lo que no se puede confundir antes de
    /// borrar.
    private struct RecordingSequence {
        let value: UInt32?
    }

    /// Qué fichero está escribiendo la extensión.
    ///
    /// Con el túnel parado no hay ninguno y no hace falta listar nada. Con el túnel vivo el listado
    /// es imprescindible: sin él no se sabe cuál es el abierto, y borrar a ciegas podría llevarse
    /// justo ese — la extensión seguiría escribiendo en un fichero sin nombre, sin dar un solo error
    /// y sin dejar nada que exportar.
    private func recordingSequence() async -> RecordingSequence? {
        guard isMonitoring else { return RecordingSequence(value: nil) }
        do {
            let files = try await library.files()
            return RecordingSequence(
                value: CapturesPresentation.recordingSequence(files: files, isMonitoring: true)
            )
        } catch {
            return nil
        }
    }

    private func loadSettings() {
        do {
            settings = try store.load()
        } catch {
            // Los de fábrica y un aviso: lo guardado se ha perdido, pero la pantalla tiene que poder
            // enseñar algo editable — y la primera escritura repara el blob ilegible.
            settings = .default
            notice = SettingsPresentation.settingsUnreadable(String(describing: error))
        }
    }

    /// Guarda el `AppSettings` entero y, si hay comando en caliente y sesión viva, lo aplica también
    /// a la sesión en curso. Devuelve si la escritura salió, para que quien llame no encadene un
    /// aviso sobre un ajuste que no se guardó.
    @discardableResult
    private func save(_ updated: AppSettings, liveCommand: ControlCommand?) async -> Bool {
        let previous = settings
        settings = updated
        activity = .saving
        defer { activity = .idle }

        do {
            try store.save(updated)
        } catch {
            // Regla 2: el valor vuelve a lo que hay de verdad en el almacén.
            settings = previous
            notice = SettingsPresentation.saveFailed(String(describing: error))
            return false
        }

        notice = nil
        guard let liveCommand, isMonitoring else { return true }

        do {
            switch try await send(liveCommand) {
            case .ok:
                break
            case .notRunning:
                // El túnel se paró entre el gesto y el envío. No hay nada que aplicar y el ajuste ya
                // está guardado para la próxima sesión: no es un fallo que contar.
                break
            case .failed(let detail):
                notice = SettingsPresentation.liveChangeNotApplied(detail)
            case .stats:
                notice = SettingsPresentation.liveChangeNotApplied("Unexpected reply from the tunnel.")
            }
        } catch TunnelControlError.notRunning {
            // Igual que la respuesta `.notRunning`: la sesión se paró entre el gesto y el envío.
            return true
        } catch {
            notice = SettingsPresentation.liveChangeNotApplied(String(describing: error))
        }
        return true
    }

    /// El cuerpo compartido por la aplicación automática y la manual. No toca `activity`: lo hace
    /// quien la llama, que es quien sabe si esto es la carga de la pantalla o un gesto del usuario.
    private func enforceCaps(trigger: RetentionTrigger) async {
        // El contenido descifrado se barre **antes de mirar los topes y pase lo que pase**: los de
        // capturas son del usuario y puede quitarlos, pero lo descifrado siempre caduca (ADR 0007), y
        // colgarlo del `guard` de abajo lo habría dejado sin barrer justo en los dispositivos cuyo
        // dueño quitó sus topes. Cuesta abrir el índice aunque no haya un solo fichero, y es a
        // propósito: unas filas que sobrevivan a sus bytes seguirían contando como contenido guardado.
        let plaintext = await storage.sweepPlaintext(settings.retention, isMonitoring: isMonitoring)

        guard !settings.retention.isUnlimited else {
            if let notice = SettingsPresentation.retention(RetentionOutcome(), plaintext: plaintext, trigger: trigger) {
                self.notice = notice
            }
            return
        }

        guard let recording = await recordingSequence() else {
            notice = SettingsPresentation.recordingFileUnknown
            return
        }

        do {
            let outcome = try await storage.enforce(
                settings.retention,
                recordingSequence: recording.value
            )
            if let notice = SettingsPresentation.retention(outcome, plaintext: plaintext, trigger: trigger) {
                self.notice = notice
            }
        } catch {
            notice = SettingsPresentation.storageUnavailable(String(describing: error))
        }
    }

    /// Vuelve a medir el disco. Un fallo aquí **no** tapa la pantalla ni borra la última medida
    /// conocida: es la cifra que se enseña, no la razón de existir de la pantalla.
    private func refreshUsage() async {
        do {
            usage = try await storage.usage()
        } catch {
            if usage == nil {
                notice = SettingsPresentation.storageUnavailable(String(describing: error))
            }
        }
    }
}
