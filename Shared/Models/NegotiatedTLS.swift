import Foundation

/// Una versión del protocolo TLS tal y como viaja en el cable: dos bytes.
///
/// Es una estructura sobre el valor crudo y no un enum cerrado porque **el valor lo elige el otro
/// extremo**: un servidor puede contestar con un borrador (`0x7F..`) o con algo que no existe, y
/// eso es evidencia que hay que conservar tal cual, no colapsar en un «desconocido» que pierda el
/// número. Las versiones que existen tienen nombre; las demás siguen siendo comparables y
/// guardables por su valor.
public struct TLSProtocolVersion: RawRepresentable, Sendable, Hashable {

    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let ssl30 = TLSProtocolVersion(rawValue: 0x0300)
    public static let tls10 = TLSProtocolVersion(rawValue: 0x0301)
    public static let tls11 = TLSProtocolVersion(rawValue: 0x0302)
    public static let tls12 = TLSProtocolVersion(rawValue: 0x0303)
    public static let tls13 = TLSProtocolVersion(rawValue: 0x0304)
}

/// Una suite de cifrado TLS por su código del registro de IANA: dos bytes.
///
/// Se guarda el código y no un nombre: el nombre es una tabla de presentación que se puede
/// corregir sin que cambie lo observado, y el código es lo que el servidor mandó.
public struct TLSCipherSuite: RawRepresentable, Sendable, Hashable {

    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }
}

/// Lo que el **servidor** eligió para una conexión TLS: la versión y la suite de su ServerHello.
///
/// Es una lectura de bytes que viajan en claro —el ServerHello va antes de que exista ninguna
/// clave—, así que vale para los flujos que no se inspeccionan y no necesita la CA local.
public struct NegotiatedTLS: Sendable, Hashable {

    /// La versión elegida: la de la extensión `supported_versions` si el servidor la mandó (así
    /// se anuncia TLS 1.3, que en `legacy_version` sigue diciendo 1.2) y `legacy_version` si no.
    public let version: TLSProtocolVersion

    public let cipherSuite: TLSCipherSuite

    /// La lectura salió de un **HelloRetryRequest** y no del ServerHello definitivo.
    ///
    /// Un HelloRetryRequest es un ServerHello con un `random` fijo (RFC 8446 § 4.1.3) con el que
    /// el servidor pide al cliente que repita su ClientHello. Ya lleva la versión y la suite, y
    /// el ServerHello que venga después está obligado a repetirlas (§ 4.1.4: el cliente aborta si
    /// cambian), así que la lectura vale para cualquier handshake que llegue a completarse. Se
    /// marca porque no es lo mismo que haberlo leído del mensaje definitivo, y quien firme un
    /// informe con esto tiene que poder saberlo.
    public let fromHelloRetryRequest: Bool

    public init(version: TLSProtocolVersion, cipherSuite: TLSCipherSuite, fromHelloRetryRequest: Bool) {
        self.version = version
        self.cipherSuite = cipherSuite
        self.fromHelloRetryRequest = fromHelloRetryRequest
    }
}
