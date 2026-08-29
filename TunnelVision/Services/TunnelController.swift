import Foundation
import Observation
import Shared

/// El servicio que la UI usa para encender, apagar y consultar el túnel (M9).
///
/// Orquesta el núcleo puro (`TunnelStatePolicy`, `TunnelConfiguration`) contra la cáscara inyectada
/// (`TunnelProviderManaging`), así que corre entero en Simulator contra un doble. Es `@MainActor` y
/// `@Observable` porque su única razón de existir es alimentar vistas: el estado se publica, no se
/// consulta a golpe de polling.
///
/// **Las acciones del interruptor no lanzan.** Un fallo se convierte en `state = .failed(...)`, que es
/// lo que exige `docs/ux/onboarding-and-consent.md`: el usuario que deniega el permiso tiene que
/// poder ver qué pasó y reintentar, no quedarse ante un interruptor que no hace nada. `send(_:)` sí
/// lanza, porque quien lo llama (Ajustes) reacciona a que *ese* comando concreto falle.
@MainActor
@Observable
public final class TunnelController {

    /// Estado que pinta la vista. Arranca en `.notInstalled` y se corrige con el primer `refresh()`.
    public private(set) var state: TunnelState = .notInstalled

    private let manager: any TunnelProviderManaging
    private let configuration: TunnelConfiguration

    /// La tarea que consume `statusUpdates()`. Se cierra explícitamente con `stopObservingStatus()`;
    /// además captura `self` débilmente, así que un controlador que nadie retiene no la mantiene viva.
    @ObservationIgnored private var statusTask: Task<Void, Never>?

    public init(manager: any TunnelProviderManaging, configuration: TunnelConfiguration = .default) {
        self.manager = manager
        self.configuration = configuration
    }

    // MARK: - Estado

    /// Sincroniza el estado con el perfil guardado. Es lo primero que hace la pantalla al aparecer.
    public func refresh() async {
        do {
            state = TunnelStatePolicy.state(for: try await manager.loadStatus())
        } catch {
            state = .failed(Self.controlError(from: error))
        }
    }

    /// Empieza a seguir los cambios de status del sistema. Idempotente: llamarla dos veces no abre dos
    /// observadores.
    public func startObservingStatus() {
        guard statusTask == nil else { return }
        let updates = manager.statusUpdates()
        statusTask = Task { [weak self] in
            for await status in updates {
                // La cancelación se comprueba también **dentro** del bucle: un valor ya en vuelo
                // cuando `stopObservingStatus()` cancela llegaría igualmente, y escribir estado
                // después de que la vista deje de observar es justo lo que ese cierre impide.
                guard let self, !Task.isCancelled else { return }
                self.state = TunnelStatePolicy.next(from: self.state, status: status)
            }
        }
    }

    /// Deja de seguirlos y libera la tarea. La llama la vista al desaparecer.
    public func stopObservingStatus() {
        statusTask?.cancel()
        statusTask = nil
    }

    // MARK: - Acciones del usuario

    /// Instala (o actualiza) el perfil VPN. **Aquí sale el diálogo del sistema**, así que la UI tiene
    /// que haberlo explicado antes (sheet de priming de `onboarding-and-consent.md`).
    public func install() async {
        do {
            try configuration.validate()
            try await manager.install(configuration)
            state = TunnelStatePolicy.state(for: try await manager.loadStatus())
        } catch {
            state = .failed(Self.controlError(from: error))
        }
    }

    /// Enciende la monitorización: instala el perfil si aún no existe y arranca el túnel.
    ///
    /// El flujo se decide leyendo el status real, no el `state` actual, para que un reintento tras una
    /// denegación vuelva a pasar por la instalación (que es justo lo que faltaba) en vez de intentar
    /// arrancar un perfil que no existe.
    public func startMonitoring() async {
        do {
            try configuration.validate()
            var status = try await manager.loadStatus()
            if status == .notInstalled {
                try await manager.install(configuration)
                status = try await manager.loadStatus()
            }
            switch status {
            case .notInstalled:
                // El perfil se guardó pero sigue sin existir: no hay nada que arrancar y decirlo es
                // mejor que dejar al usuario mirando un "arrancando" eterno.
                throw TunnelControlError.notInstalled
            case .connected, .connecting, .reasserting:
                // Ya está encendido (o encendiéndose): no se pide un segundo arranque.
                state = TunnelStatePolicy.state(for: status)
            case .disconnected, .disconnecting:
                state = .starting
                try await manager.start()
            }
        } catch {
            state = .failed(Self.controlError(from: error))
        }
    }

    /// Apaga la monitorización y deja el estado sincronizado con el sistema.
    public func stopMonitoring() async {
        state = .stopping
        do {
            try await manager.stop()
        } catch {
            state = .failed(Self.controlError(from: error))
            return
        }
        await refresh()
    }

    // MARK: - Canal de control

    /// Envía un comando a la extensión y devuelve su respuesta. Lanza `TunnelControlError`: sin sesión
    /// viva, `.notRunning`; con bytes que no son del canal, `.malformedResponse`.
    @discardableResult
    public func send(_ command: ControlCommand) async throws -> ControlResponse {
        let payload: Data
        do {
            payload = try command.encoded()
        } catch {
            throw TunnelControlError.controlChannelFailed("no se pudo codificar el comando: \(error)")
        }

        let reply: Data?
        do {
            reply = try await manager.sendControl(payload)
        } catch {
            throw Self.controlError(from: error)
        }

        // Sin respuesta = no hay sesión al otro lado. Es la carrera normal entre la UI y `stopTunnel`.
        guard let reply else { throw TunnelControlError.notRunning }

        do {
            return try ControlResponse(decoding: reply)
        } catch {
            throw TunnelControlError.malformedResponse
        }
    }

    // MARK: - Errores

    /// Garantiza un error tipado aunque una cáscara futura se salte el contrato del protocolo y deje
    /// escapar un `NSError` del sistema.
    private static func controlError(from error: Error) -> TunnelControlError {
        if let typed = error as? TunnelControlError { return typed }
        let nsError = error as NSError
        return TunnelControlError.classifying(
            domain: nsError.domain,
            code: nsError.code,
            message: nsError.localizedDescription
        )
    }
}
