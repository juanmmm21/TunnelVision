import Foundation
import NetworkExtension

/// Conformidad de producción de `TunnelProviderManaging` sobre NetworkExtension.
///
/// Es la única parte de la app que importa NetworkExtension, y por tanto la única que **no** se puede
/// ejercitar en Simulator: instalar un perfil VPN exige dispositivo real, entitlement y un diálogo del
/// sistema. Igual que `NetworkRelayConnection` o `PacketTunnelProvider.swift`, se valida **por
/// compilación** bajo concurrencia estricta y su corrección viva es un smoke test de dispositivo; toda
/// la lógica que se puede decidir sin el sistema vive en `TunnelStatePolicy` y `TunnelController`.
///
/// Es un `actor` porque `NETunnelProviderManager` no es `Sendable` y no debe salir de aquí: lo que
/// cruza son valores (`TunnelStatus`, `Data`).
public actor NETunnelProviderManagerAdapter: TunnelProviderManaging {

    /// El perfil de esta app, si ya se cargó. Se recarga en cada operación porque el usuario puede
    /// haberlo borrado desde Ajustes mientras la app estaba en segundo plano.
    private var manager: NETunnelProviderManager?

    public init() {}

    // MARK: - Perfil

    public func loadStatus() async throws -> TunnelStatus {
        guard let manager = try await loadManager() else { return .notInstalled }
        return TunnelStatus(manager.connection.status)
    }

    public func install(_ configuration: TunnelConfiguration) async throws {
        try configuration.validate()

        let target = try await loadManager() ?? NETunnelProviderManager()
        let providerProtocol = NETunnelProviderProtocol()
        providerProtocol.providerBundleIdentifier = configuration.providerBundleIdentifier
        providerProtocol.serverAddress = configuration.serverAddress
        target.protocolConfiguration = providerProtocol
        target.localizedDescription = configuration.localizedDescription
        target.isEnabled = true

        do {
            try await target.saveToPreferences()
            // NetworkExtension exige releer tras guardar: el objeto en memoria queda obsoleto y su
            // `connection` no sirve para arrancar hasta que se recarga.
            try await target.loadFromPreferences()
        } catch {
            throw Self.mapped(error)
        }
        manager = target
    }

    // MARK: - Sesión

    public func start() async throws {
        guard let manager = try await loadManager() else { throw TunnelControlError.notInstalled }
        guard let session = manager.connection as? NETunnelProviderSession else {
            throw TunnelControlError.startFailed("la conexión del perfil no es una sesión de proveedor")
        }
        do {
            try session.startVPNTunnel()
        } catch {
            throw TunnelControlError.startFailed((error as NSError).localizedDescription)
        }
    }

    public func stop() async throws {
        // Un perfil que ya no existe es un túnel que ya está parado: no es un error que contar.
        guard let manager = try await loadManager() else { return }
        manager.connection.stopVPNTunnel()
    }

    public func sendControl(_ payload: Data) async throws -> Data? {
        guard let manager = try await loadManager(),
              let session = manager.connection as? NETunnelProviderSession else {
            throw TunnelControlError.notRunning
        }
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try session.sendProviderMessage(payload) { response in
                    continuation.resume(returning: response)
                }
            } catch {
                continuation.resume(
                    throwing: TunnelControlError.controlChannelFailed((error as NSError).localizedDescription)
                )
            }
        }
    }

    public nonisolated func statusUpdates() -> AsyncStream<TunnelStatus> {
        AsyncStream { continuation in
            // Se observan **todas** las conexiones VPN y se filtra por la nuestra dentro del bucle: el
            // perfil puede no existir aún cuando la vista empieza a observar (primer arranque), así que
            // atarse a un objeto concreto aquí perdería justo la transición que interesa.
            let task = Task {
                let notifications = NotificationCenter.default.notifications(named: .NEVPNStatusDidChange)
                for await notification in notifications {
                    guard let connection = notification.object as? NEVPNConnection else { continue }
                    continuation.yield(TunnelStatus(connection.status))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Interno

    private func loadManager() async throws -> NETunnelProviderManager? {
        do {
            let all = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = all.first
            return manager
        } catch {
            throw Self.mapped(error)
        }
    }

    /// Traduce el `NSError` del sistema al error tipado del contrato, para que nada por encima de esta
    /// cáscara tenga que conocer `NEVPNErrorDomain`.
    private static func mapped(_ error: Error) -> TunnelControlError {
        if let typed = error as? TunnelControlError { return typed }
        let nsError = error as NSError
        return TunnelControlError.classifying(
            domain: nsError.domain,
            code: nsError.code,
            message: nsError.localizedDescription
        )
    }
}

extension TunnelStatus {
    /// Espejo de `NEVPNStatus`. Un caso futuro desconocido se trata como `disconnected`: es la única
    /// lectura que nunca miente al usuario diciéndole que está monitorizando cuando no lo sabemos.
    init(_ status: NEVPNStatus) {
        switch status {
        case .invalid: self = .notInstalled
        case .disconnected: self = .disconnected
        case .connecting: self = .connecting
        case .connected: self = .connected
        case .reasserting: self = .reasserting
        case .disconnecting: self = .disconnecting
        @unknown default: self = .disconnected
        }
    }
}
