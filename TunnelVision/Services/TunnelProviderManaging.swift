import Foundation

/// El perfil VPN de la app y su sesión, abstraídos sobre `NETunnelProviderManager`.
///
/// Misma costura que `RelayConnection` sobre `NWConnection` o los sumideros del pipeline: instalar un
/// perfil VPN exige un dispositivo real (y un diálogo del sistema), así que la orquestación corre en
/// tests contra un doble guionizado y solo la conformidad de producción
/// —`NETunnelProviderManagerAdapter`— toca NetworkExtension.
///
/// **Contrato de errores:** todo lo que lanza aquí es un `TunnelControlError`. Traducir el `NSError`
/// del sistema es trabajo de la cáscara, para que nada por encima tenga que adivinar un dominio ni un
/// código.
public protocol TunnelProviderManaging: Sendable {
    /// Carga el perfil guardado de esta app y devuelve su status. `.notInstalled` si no hay ninguno.
    func loadStatus() async throws -> TunnelStatus

    /// Crea o actualiza el perfil y lo guarda. **Aquí es donde iOS pregunta al usuario**, así que
    /// lanza `.permissionDenied` si lo deniega.
    func install(_ configuration: TunnelConfiguration) async throws

    /// Arranca el túnel del perfil guardado. Exige un `install` previo (`.notInstalled` si no).
    func start() async throws

    /// Para el túnel. Parar uno ya parado no es un error.
    func stop() async throws

    /// Envía un mensaje por el canal de control y devuelve la respuesta cruda, o `nil` si no hay
    /// sesión que conteste. El codec (`ControlCommand`/`ControlResponse`) es cosa del llamante: aquí
    /// solo viajan bytes, igual que en `handleAppMessage` al otro lado.
    func sendControl(_ payload: Data) async throws -> Data?

    /// Cambios de status del túnel, incluido el actual si se conoce. La cáscara los deriva del
    /// observador de `NEVPNStatusDidChange`. Termina cuando la cáscara se libera.
    func statusUpdates() -> AsyncStream<TunnelStatus>
}
