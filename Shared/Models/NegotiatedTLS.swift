import Foundation

/// Una versión del protocolo TLS tal y como viaja en el cable: dos bytes.
///
/// Es una estructura sobre el valor crudo y no un enum cerrado porque **el valor lo elige el otro
/// extremo**: un servidor puede contestar con un borrador (`0x7F..`) o con algo que no existe, y
/// eso es evidencia que hay que conservar tal cual, no colapsar en un «desconocido» que pierda el
/// número. Las versiones que existen tienen nombre; las demás siguen siendo comparables y
/// guardables por su valor.
public struct TLSProtocolVersion: RawRepresentable, Sendable, Hashable, Codable {

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
public struct TLSCipherSuite: RawRepresentable, Sendable, Hashable, Codable {

    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }
}

/// De dónde sale una lectura de lo que eligió el servidor, que es también **a qué ClientHello
/// estaba contestando**.
///
/// No se deduce de `TLSInspectionStatus`, y por eso viaja con la lectura: un flujo cuyo cliente
/// rechazó nuestro leaf queda `notInspectable` y uno cuya terminación falló a medias se queda
/// `encrypted`, y los dos pueden llevar una lectura de la conexión de subida, que llegó a
/// negociar antes. Y la diferencia importa a quien firme un informe: lo que el servidor le
/// contesta a un cliente que ofrece TLS 1.3 no dice qué habría negociado una app que solo
/// ofrece 1.2.
public enum TLSAnswerSource: String, Sendable, Hashable, Codable {
    /// Leída del ServerHello que viajó en claro hacia el dispositivo: es la respuesta al
    /// ClientHello **de la app**, y por tanto lo que esa conexión negoció de verdad.
    case serverHello
    /// La dio el sistema de la conexión que **el túnel** abrió contra el servidor real para
    /// inspeccionar el flujo: es la respuesta del servidor a nuestro ClientHello, no al de la
    /// app. Dice qué acepta el servidor; no qué ofreció la app.
    case upstreamConnection
}

/// Lo que el **servidor** eligió para una conexión TLS: la versión y la suite.
///
/// En un flujo que no se inspecciona es una lectura de bytes que viajan en claro —el ServerHello
/// va antes de que exista ninguna clave—, así que no necesita la CA local. En uno inspeccionado
/// ese ServerHello es el de nuestra terminación y no se lee: la cifra es la que negoció la
/// conexión de subida. `source` dice cuál de las dos.
public struct NegotiatedTLS: Sendable, Hashable, Codable {

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
    ///
    /// Una lectura de la conexión de subida lo lleva siempre a `false`: el sistema informa de un
    /// handshake **terminado**, así que la cifra es la definitiva hubiera o no un reintento por
    /// medio, y si lo hubo no lo cuenta.
    public let fromHelloRetryRequest: Bool

    public let source: TLSAnswerSource

    public init(
        version: TLSProtocolVersion,
        cipherSuite: TLSCipherSuite,
        fromHelloRetryRequest: Bool,
        source: TLSAnswerSource
    ) {
        self.version = version
        self.cipherSuite = cipherSuite
        self.fromHelloRetryRequest = fromHelloRetryRequest
        self.source = source
    }
}

/// Lo que el servidor **contestó** al ClientHello de un flujo, que es lo que el flujo se lleva
/// puesto al historial.
///
/// Son dos casos y no un `NegotiatedTLS?` porque una negativa también es una respuesta: un servidor
/// que no acepta ninguna versión ofrecida no manda un ServerHello, manda una alerta, y eso es un
/// dato sobre el TLS de esa conexión que un informe tiene que poder citar. Lo que **no** es
/// ninguna de las dos cosas —un stream que no era TLS, un mensaje ilegible— no dice nada del
/// servidor y no llega aquí: el flujo se queda sin respuesta apuntada y lo cuenta `RelayStats`.
public enum ServerTLSAnswer: Sendable, Hashable, Codable {
    /// Hubo ServerHello (o HelloRetryRequest): esto es lo que eligió.
    case negotiated(NegotiatedTLS)
    /// Contestó con una alerta en vez de negociar. `alert` es su código tal cual (RFC 8446 § 6),
    /// sin interpretar por la misma razón que la versión y la suite: lo elige el otro extremo.
    case refused(alert: UInt8)
}
