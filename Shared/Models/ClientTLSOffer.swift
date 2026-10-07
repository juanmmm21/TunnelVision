import Foundation

/// Las versiones de TLS que un cliente dijo aceptar en su ClientHello.
///
/// Son dos casos y no una lista porque el ClientHello lo dice de dos formas que **no significan lo
/// mismo**, y la diferencia es justo lo que un informe necesita: con la extensión
/// `supported_versions` el cliente enumera cada versión que acepta, así que la lista es exacta;
/// sin ella solo hay un `legacy_version`, que es un **techo** —«hasta aquí»— y no dice dónde está
/// el suelo. De la primera se puede afirmar que el cliente no habría aceptado TLS 1.0; de la
/// segunda no.
public enum OfferedTLSVersions: Sendable, Hashable, Codable {
    /// La lista de `supported_versions`, en el orden de preferencia del cliente y tal como la
    /// mandó, sin los valores GREASE (RFC 8701), que no son versiones. Puede quedar vacía: un
    /// cliente que solo manda relleno ha mandado la extensión y no ha ofrecido nada.
    case listed([TLSProtocolVersion])
    /// No había extensión: el `legacy_version` del ClientHello, que es la versión más alta que
    /// el cliente acepta. Lo que acepte por debajo no viaja en el mensaje.
    case upTo(TLSProtocolVersion)
}

/// Lo que el **cliente** ofreció en su ClientHello: con qué versiones de TLS estaba dispuesto a
/// hablar y qué protocolos de aplicación (ALPN).
///
/// Es la otra mitad de `NegotiatedTLS`, y la que hace falta para leerla bien: lo que eligió el
/// servidor solo dice algo de la app si se sabe entre qué pudo elegir. Importa sobre todo en un
/// flujo inspeccionado, cuya lectura del servidor contesta al ClientHello **del túnel**
/// (`TLSAnswerSource.upstreamConnection`): ahí esto es lo único que sale de la app.
///
/// Se lee de bytes que viajan en claro —el ClientHello va antes de que exista ninguna clave—, así
/// que no necesita la CA local ni depende de la inspección.
public struct ClientTLSOffer: Sendable, Hashable, Codable {

    public let versions: OfferedTLSVersions

    /// Los protocolos de aplicación de la extensión ALPN (RFC 7301), en el orden de preferencia
    /// del cliente: `h2`, `http/1.1`… Vacía si no mandó la extensión.
    ///
    /// Solo entran los identificadores que son ASCII imprimible y caben en el tope: estos bytes
    /// los elige el otro extremo y de aquí van a una columna y a un informe. Los valores GREASE
    /// no son protocolos y no cuentan en ningún sitio.
    public let applicationProtocols: [String]

    /// Cuántos identificadores de ALPN mandó el cliente que **no** están en
    /// `applicationProtocols`: no eran texto imprimible, pasaban de la longitud admitida o ya no
    /// cabían en la lista. Existe para que una lista recortada no se lea como la lista entera.
    public let omittedApplicationProtocols: Int

    /// El ClientHello llevaba la extensión `encrypted_client_hello` (RFC 9849).
    ///
    /// Entonces lo leído es el ClientHello **exterior**, y el de verdad puede ir cifrado dentro
    /// con otras versiones, otro ALPN y otro nombre. «Puede», porque un cliente que no tiene
    /// configuración de ECH para ese servidor manda la extensión igualmente con relleno, y por
    /// diseño no se distingue de una de verdad. Quien cite esta oferta con la marca puesta tiene
    /// que decir que quizá no sea la que el servidor contestó.
    public let hasEncryptedClientHello: Bool

    public init(
        versions: OfferedTLSVersions,
        applicationProtocols: [String],
        omittedApplicationProtocols: Int,
        hasEncryptedClientHello: Bool
    ) {
        self.versions = versions
        self.applicationProtocols = applicationProtocols
        self.omittedApplicationProtocols = omittedApplicationProtocols
        self.hasEncryptedClientHello = hasEncryptedClientHello
    }
}
