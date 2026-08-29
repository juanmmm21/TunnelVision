import Foundation

/// Direccionamiento del túnel: la geometría de red que `startTunnel` aplica vía
/// `NEPacketTunnelNetworkSettings`, las IPs locales que necesita `PacketPipeline.Config` para
/// resolver el sentido de cada paquete, y las que necesita la **app** para saber cuál de los dos
/// endpoints de un `FlowKey` canónico es el dispositivo y cuál el host remoto.
///
/// Vive en `Shared` justo por ese tercer consumidor: es conocimiento de los **dos** procesos, y el
/// único sitio donde ambos ven el mismo tipo es el framework compartido (el mismo motivo por el que
/// el codec del canal de control acabó en `Shared/IPC/ControlChannel.swift`). Es puro y Foundation-
/// only, así que se verifica en Simulator: ata las dos representaciones de la **misma** dirección.
///
/// Decisión: la fuente de verdad son los **bytes** (`IPAddress`), y las cadenas que pide
/// NetworkExtension se derivan de ellos con `description` (formateo RFC 5952, ya probado en M1).
/// Al revés —cadenas literales parseadas a bytes— habría dos literales que mantener sincronizados:
/// si divergieran, el túnel anunciaría una IP y el pipeline compararía contra otra, y **todo** el
/// tráfico saldría con el sentido invertido en el historial.
public enum TunnelAddressing {

    /// Extremo remoto nominal del túnel. Es un valor de presentación que iOS exige pero que no se
    /// usa para enrutar: no hay servidor VPN al otro lado, el "otro lado" es esta misma extensión.
    public static let tunnelRemoteAddress = "127.0.0.1"

    /// IP del túnel para IPv4. Rango privado (RFC 1918) elegido por ser poco habitual en redes
    /// domésticas, para no colisionar con la LAN del usuario.
    public static let localIPv4 = IPAddress(version: .v4, bytes: [10, 7, 0, 2])

    /// Máscara del /24 de `localIPv4`.
    public static let ipv4SubnetMask = "255.255.255.0"

    /// IP del túnel para IPv6, en el rango de direcciones locales únicas (RFC 4193).
    public static let localIPv6 = IPAddress(
        version: .v6,
        bytes: [0xfd, 0x00, 0x00, 0x07, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x02]
    )

    /// Longitud de prefijo del /64 de `localIPv6`.
    public static let ipv6PrefixLength = 64

    /// MTU del interfaz virtual. 1500 es la de Ethernet: no fragmentamos por debajo de lo que ya
    /// soporta el enlace real.
    public static let mtu = 1500

    /// Las dos IPs del túnel juntas. Es lo que la app necesita para repartir los endpoints de un
    /// `FlowKey` (canónico, y por tanto ciego al sentido) en dispositivo y host remoto.
    public static let localAddresses: Set<IPAddress> = [localIPv4, localIPv6]

    /// Dirección IPv4 tal como la quiere `NEIPv4Settings(addresses:)`.
    public static var ipv4AddressString: String { localIPv4.description }

    /// Dirección IPv6 tal como la quiere `NEIPv6Settings(addresses:)`.
    public static var ipv6AddressString: String { localIPv6.description }
}
