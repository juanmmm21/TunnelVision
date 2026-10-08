import Foundation

/// De dónde sale la versión de TLS que se le atribuye a un flujo.
public enum TLSVersionBasis: Sendable, Hashable {
    /// Leída del ServerHello que contestó a la app: es lo que esa conexión negoció. Con
    /// `fromHelloRetryRequest` la cifra salió de un HelloRetryRequest y no del mensaje definitivo
    /// (`NegotiatedTLS.fromHelloRetryRequest`).
    case serverHello(fromHelloRetryRequest: Bool)
    /// La negoció la conexión que **el túnel** abrió contra el servidor para inspeccionar el
    /// flujo. Dice qué acepta el servidor de nuestro cliente, no qué negoció la app.
    case upstreamConnection
    /// El flujo habla esta versión de QUIC, que lleva TLS 1.3 por definición (RFC 9001).
    case quic(QUICVersion)
}

/// Una versión de TLS observada en un flujo, con su origen. Quien la cite cita las dos cosas.
public struct TLSVersionObservation: Sendable, Hashable {
    public let version: TLSProtocolVersion
    public let basis: TLSVersionBasis

    public init(version: TLSProtocolVersion, basis: TLSVersionBasis) {
        self.version = version
        self.basis = basis
    }
}

/// Por qué la oferta del cliente no basta para afirmar que la app no habría negociado menos que el
/// mínimo. Solo se consulta cuando la única cifra del flujo es la de la conexión del túnel.
public enum ClientOfferGap: Sendable, Hashable {
    /// No se leyó el ClientHello de la app.
    case notRead
    /// La oferta llevaba Encrypted Client Hello: la de verdad puede ir cifrada dentro, con otras
    /// versiones.
    case encryptedClientHello
    /// Sin `supported_versions` solo hay un techo: dónde está el suelo no viaja en el mensaje.
    case ceilingOnly(TLSProtocolVersion)
    /// La lista incluye al menos una versión publicada por debajo del mínimo: la app la habría
    /// aceptado.
    case listsWeakerVersion
    /// La lista está vacía o lleva valores que no son versiones publicadas, y no se pueden ordenar.
    case listNotConclusive
}

/// Por qué no se pudo decir nada de la versión de TLS de un flujo que sí parece llevarlo.
public enum TLSVersionGap: Sendable, Hashable {
    /// Hay señales de TLS —el estado del flujo o un ClientHello leído— pero no una respuesta del
    /// servidor: el handshake pasó antes de la captura, se cortó o no se dejó leer. En TCP contra
    /// el 443 el estado `encrypted` lo pone el puerto, así que también cubre un 443 que no hablaba
    /// TLS.
    case serverAnswerNotRead
    /// El servidor contestó con una alerta: no se negoció ninguna versión.
    case serverRefused(alert: UInt8)
    /// El valor leído no es una versión publicada y no se puede comparar con el mínimo.
    case unrecognisedVersion(TLSVersionObservation)
    /// El servidor negoció con el túnel una versión aceptable, pero qué negoció —o habría
    /// negociado— la app no se observó, y su oferta no lo descarta.
    case appNegotiationNotObserved(upstream: TLSProtocolVersion, offer: ClientOfferGap)
    /// La versión de QUIC solo se leyó del cliente: es la que propuso, y el servidor pudo cambiarla.
    case quicVersionOnlyProposed(QUICVersion)
    /// La versión de QUIC no es una de las que se sabe qué TLS llevan.
    case unrecognisedQUICVersion(QUICVersion)
}

/// Lo que se puede decir de la versión de TLS de **un** flujo frente a un mínimo.
///
/// Son cuatro casos y ninguno por defecto porque los cuatro acaban en sitios distintos del
/// informe: un hallazgo, una observación sin incidencia, un «no evaluado» con su motivo, y un
/// flujo que no es de esta comprobación.
public enum TLSVersionAssessment: Sendable, Hashable {

    /// La versión observada está por debajo del mínimo.
    case weak(TLSVersionObservation)

    /// La app no negoció menos que el mínimo. Con origen `serverHello` o `quic` es la versión de
    /// esa conexión; con `upstreamConnection` es la que el servidor negoció con el túnel, y el
    /// caso solo se da cuando el ClientHello de la app enumeraba sus versiones y ninguna quedaba
    /// por debajo.
    case acceptable(TLSVersionObservation)

    case notAssessed(TLSVersionGap)

    /// El flujo no muestra ninguna señal de TLS ni de QUIC. **No es una afirmación de que vaya en
    /// claro**: fuera del 443 nadie busca un handshake.
    case notApplicable

    /// - Parameter minimum: la versión más baja que se acepta. Tiene que ser una versión
    ///   publicada (`FindingsPolicy` lo garantiza): es con lo que se compara.
    public init(of flow: StoredFlow, minimum: TLSProtocolVersion) {
        switch flow.serverTLS {
        case .negotiated(let negotiated):
            self = Self.assess(negotiated, offer: flow.clientTLS, minimum: minimum)
        case .refused(let alert):
            self = .notAssessed(.serverRefused(alert: alert))
        case nil:
            if let quic = flow.quic {
                self = Self.assess(quic, minimum: minimum)
            } else if flow.tlsStatus != .plaintext || flow.clientTLS != nil {
                self = .notAssessed(.serverAnswerNotRead)
            } else {
                self = .notApplicable
            }
        }
    }

    private static func assess(
        _ negotiated: NegotiatedTLS,
        offer: ClientTLSOffer?,
        minimum: TLSProtocolVersion
    ) -> TLSVersionAssessment {
        let basis: TLSVersionBasis
        switch negotiated.source {
        case .serverHello:
            basis = .serverHello(fromHelloRetryRequest: negotiated.fromHelloRetryRequest)
        case .upstreamConnection:
            basis = .upstreamConnection
        }
        let observation = TLSVersionObservation(version: negotiated.version, basis: basis)
        guard negotiated.version.isPublished else {
            return .notAssessed(.unrecognisedVersion(observation))
        }
        // Una versión débil lo es venga de donde venga: si ni a nuestro cliente, que ofrece las
        // actuales, le da el servidor más que esto, la app tampoco pudo negociar más.
        guard negotiated.version.rawValue >= minimum.rawValue else {
            return .weak(observation)
        }
        switch negotiated.source {
        case .serverHello:
            return .acceptable(observation)
        case .upstreamConnection:
            // El servidor aceptó una versión buena **del túnel**. De la app solo sale su oferta, y
            // solo una lista exacta sin nada por debajo descarta que negociara menos.
            if let gap = clientOfferGap(offer, minimum: minimum) {
                return .notAssessed(.appNegotiationNotObserved(upstream: negotiated.version, offer: gap))
            }
            return .acceptable(observation)
        }
    }

    private static func assess(_ quic: QUICVersionReading, minimum: TLSProtocolVersion) -> TLSVersionAssessment {
        guard quic.version.hasKnownPacketProtection else {
            return .notAssessed(.unrecognisedQUICVersion(quic.version))
        }
        guard quic.source == .server else {
            return .notAssessed(.quicVersionOnlyProposed(quic.version))
        }
        let observation = TLSVersionObservation(version: .tls13, basis: .quic(quic.version))
        return TLSProtocolVersion.tls13.rawValue >= minimum.rawValue ? .acceptable(observation) : .weak(observation)
    }

    /// `nil` si la oferta descarta que la app aceptase menos que el mínimo.
    private static func clientOfferGap(_ offer: ClientTLSOffer?, minimum: TLSProtocolVersion) -> ClientOfferGap? {
        guard let offer else { return .notRead }
        guard !offer.hasEncryptedClientHello else { return .encryptedClientHello }
        switch offer.versions {
        case .upTo(let ceiling):
            return .ceilingOnly(ceiling)
        case .listed(let versions):
            if versions.contains(where: { $0.isPublished && $0.rawValue < minimum.rawValue }) {
                return .listsWeakerVersion
            }
            if versions.isEmpty || versions.contains(where: { !$0.isPublished }) {
                return .listNotConclusive
            }
            return nil
        }
    }
}
