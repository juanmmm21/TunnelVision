import Foundation

/// Descripción del perfil VPN que la app instala en Ajustes, en forma de valor puro.
///
/// La cáscara la vuelca sobre un `NETunnelProviderProtocol`; aquí no se importa NetworkExtension,
/// así que la validación —lo único que puede fallar por nuestra culpa— se prueba en Simulator.
public struct TunnelConfiguration: Sendable, Equatable {
    /// Bundle id de la extensión. **Tiene que coincidir** con `PRODUCT_BUNDLE_IDENTIFIER` del target
    /// `PacketTunnel` en `project.yml`: si no, iOS guarda el perfil pero no encuentra el proveedor y
    /// el túnel falla al arrancar sin decir por qué.
    public var providerBundleIdentifier: String
    /// Lo que iOS enseña como "servidor" en Ajustes → VPN. Es texto para el usuario, no un host: el
    /// túnel termina en el propio dispositivo y el ajuste lo dice, para no insinuar que el tráfico
    /// sale a ningún sitio.
    public var serverAddress: String
    /// Nombre del perfil en Ajustes.
    public var localizedDescription: String

    public init(providerBundleIdentifier: String, serverAddress: String, localizedDescription: String) {
        self.providerBundleIdentifier = providerBundleIdentifier
        self.serverAddress = serverAddress
        self.localizedDescription = localizedDescription
    }

    public static let `default` = TunnelConfiguration(
        providerBundleIdentifier: "com.juanmmm21.tunnelvision.PacketTunnel",
        serverAddress: "On this device",
        localizedDescription: "TunnelVision"
    )

    /// Rechaza una configuración que iOS aceptaría a medias. Los tres campos acaban en la UI del
    /// sistema o en la resolución del proveedor, y un vacío ahí produce un perfil que existe pero no
    /// se puede explicar ni arrancar.
    public func validate() throws {
        try Self.requireNonBlank(providerBundleIdentifier, field: "providerBundleIdentifier")
        try Self.requireNonBlank(serverAddress, field: "serverAddress")
        try Self.requireNonBlank(localizedDescription, field: "localizedDescription")
    }

    private static func requireNonBlank(_ value: String, field: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TunnelControlError.configurationFailed("\(field) está vacío")
        }
    }
}
