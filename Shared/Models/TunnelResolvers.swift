import Foundation

/// Qué resolvers de DNS puede anunciar el túnel, dados los que el sistema ya tenía.
///
/// # Por qué el túnel tiene que anunciar alguno
///
/// El interfaz virtual se lleva la **ruta por defecto de las dos familias** —es lo que hace que
/// capturemos todo—, así que se convierte en el interfaz primario del dispositivo. Un interfaz
/// primario que no ofrece resolución de nombres deja al sistema sin DNS: la sonda de conectividad
/// de iOS falla, la red se da por caída y el navegador no intenta ni una IP literal. Se creyó
/// durante un tiempo lo contrario —que las consultas entrarían por el túnel igualmente, capturadas
/// por las rutas por defecto—, y un `.pcap` del dispositivo lo desmintió: en 34 segundos de sesión
/// no hubo **ni una** consulta de DNS.
///
/// # Por qué se anuncian los del sistema y no uno público
///
/// Fijar aquí `1.1.1.1` u `8.8.8.8` arreglaría el síntoma en una línea, pero redirigiría el DNS del
/// usuario a un tercero que no ha elegido, que es lo contrario del propósito de esta app. Anunciando
/// los que el dispositivo ya tenía, sus consultas siguen yendo exactamente adonde iban —su router,
/// su operador— y lo único que cambia es que ahora **pasan por el túnel**, que es donde esta app
/// puede verlas.
///
/// Un resolver de la LAN (`192.168.1.1`) sigue siendo alcanzable después de anunciarlo: la consulta
/// entra por el túnel, y el relay abre su conexión saliente **por el interfaz real**, que es la misma
/// mecánica con la que ya sale todo lo demás.
public enum TunnelResolvers {

    /// Los que se pueden anunciar, en el orden en que llegaron.
    ///
    /// El orden **es** la preferencia del sistema, así que ni se ordena ni se baraja: solo se
    /// descarta. Y se descarta poco y por motivos concretos, porque cada resolver que se cae es una
    /// preferencia del usuario que se pierde:
    ///
    /// - **Loopback** (`127.0.0.0/8`, `::1`, y el mapeado `::ffff:127.x.x.x`): anunciado por el
    ///   túnel, manda las consultas a la propia máquina en vez de al túnel — o sea, exactamente el
    ///   síntoma que esto existe para arreglar. Que el sistema tenga uno significa que hay un proxy
    ///   de DNS local resolviendo, y ese proxy no es alcanzable desde el otro lado del interfaz.
    /// - **Link-local IPv6** (`fe80::/10`): su alcance es un interfaz concreto y sin la zona
    ///   (`%en0`) no significa nada; con ella, `NEDNSSettings.servers` no la admite. Anunciada a
    ///   secas, la consulta saldría por el interfaz equivocado.
    /// - **La dirección sin especificar** (`0.0.0.0`, `::`): no es un destino.
    /// - **Lo que no parsea** como IP literal, que no debería ocurrir porque el origen es
    ///   `inet_ntop`, pero un resolver inventado es peor que uno de menos.
    /// - **Duplicados**, conservando la primera aparición.
    ///
    /// Nótese lo que **no** se descarta: una IP privada (`192.168.0.0/16`, `10.0.0.0/8`) o
    /// link-local IPv4 (`169.254.0.0/16`) se anuncian tal cual. Son alcanzables por el relay desde
    /// el interfaz real y no necesitan zona para significar algo, que es justo la línea que separa
    /// estos casos del `fe80::`.
    public static func announceable(from raw: [String]) -> [IPAddress] {
        var seen: Set<IPAddress> = []
        var result: [IPAddress] = []
        for text in raw {
            guard let address = IPAddress(parsing: text) else { continue }
            guard isAnnounceable(address) else { continue }
            guard seen.insert(address).inserted else { continue }
            result.append(address)
        }
        return result
    }

    /// Si una dirección concreta sirve como resolver anunciado por el túnel.
    public static func isAnnounceable(_ address: IPAddress) -> Bool {
        !isUnspecified(address) && !isLoopback(address) && !isIPv6LinkLocal(address)
    }

    // MARK: - Clasificación

    private static func isUnspecified(_ address: IPAddress) -> Bool {
        address.bytes.allSatisfy { $0 == 0 }
    }

    private static func isLoopback(_ address: IPAddress) -> Bool {
        switch address.version {
        case .v4:
            return address.bytes.first == 127
        case .v6:
            if address.bytes == Self.ipv6Loopback { return true }
            // `::ffff:127.x.x.x` es la misma dirección escrita en la otra familia, y llegar por ahí
            // al loopback tendría exactamente la misma consecuencia.
            guard address.bytes.count == 16,
                  address.bytes.prefix(10).allSatisfy({ $0 == 0 }),
                  address.bytes[10] == 0xff, address.bytes[11] == 0xff else { return false }
            return address.bytes[12] == 127
        }
    }

    private static func isIPv6LinkLocal(_ address: IPAddress) -> Bool {
        guard address.version == .v6, address.bytes.count == 16 else { return false }
        // fe80::/10: los diez primeros bits son 1111 1110 10.
        return address.bytes[0] == 0xfe && (address.bytes[1] & 0xc0) == 0x80
    }

    private static let ipv6Loopback: [UInt8] = {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[15] = 1
        return bytes
    }()
}
