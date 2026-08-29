import Foundation
import Network
import Security
import Shared

/// Emisión del leaf de un host, abstraída para que el motor de terminación no dependa del llavero.
///
/// Existe por lo mismo que `RelayConnectionFactory`: la conformidad real (`LocalCA`) importa la clave
/// raíz del llavero y arma un `SecIdentity`, y eso no se puede guionizar en un test. Con la costura, lo
/// que sí se puede afirmar es el orden que importa —**primero el leaf y solo después la red**—, que es
/// lo que impide abrir una conexión al servidor real por un flujo que nunca se iba a poder inspeccionar.
public protocol LeafMinting: Sendable {
    /// Emite (o recupera de su caché) el certificado de hoja para `host`, firmado por la CA local.
    func mintLeaf(forHost host: String) async throws -> SecIdentity
}

extension LocalCA: LeafMinting {
    /// La CA emite con SANs opcionales; el motor solo necesita el host del ClientHello.
    public func mintLeaf(forHost host: String) async throws -> SecIdentity {
        try await mintLeaf(forHost: host, sans: [])
    }
}

/// Conformidad de producción de `TLSTerminationEngine`: arma la terminación de un flujo con las dos
/// piezas reales —la sesión de servidor de loopback con el leaf del host y una `NWConnection` con TLS
/// contra el servidor de verdad— y las empareja en un `TLSTerminationConnection`.
///
/// **El invariante de seguridad vive aquí, y es una omisión deliberada:** la pata saliente **no** lleva
/// bloque de verificación propio, así que la evalúa el sistema como la de cualquier app. Al servidor
/// real le somos un cliente corriente: no vemos nada que no pudiéramos ver legítimamente, y un
/// certificado que el sistema rechace tumba el flujo en vez de inspeccionarlo (spec § *Security
/// invariants*). Añadir aquí un `sec_protocol_options_set_verify_block` sería exactamente lo que el
/// ADR 0003 prohíbe.
///
/// Se valida por compilación, como `NetworkRelayConnection` y el propio provider: lo que orquesta —el
/// emparejamiento y el trasiego— sí está probado, en `TLSTerminationConnection`.
public struct NetworkTLSTerminationEngine: TLSTerminationEngine {

    private let ca: any LeafMinting
    private let queue: DispatchQueue
    /// Cómo se construye la pata saliente. Inyectable solo para poder afirmar que **no** se construye
    /// cuando no hay leaf; en producción es siempre `Self.upstream`.
    private let makeUpstream: @Sendable (IPEndpoint, String, DispatchQueue) -> any RelayConnection

    public init(
        ca: any LeafMinting,
        queue: DispatchQueue = DispatchQueue(label: "com.juanmmm21.tunnelvision.tls")
    ) {
        self.init(ca: ca, queue: queue, makeUpstream: Self.upstream)
    }

    init(
        ca: any LeafMinting,
        queue: DispatchQueue,
        makeUpstream: @escaping @Sendable (IPEndpoint, String, DispatchQueue) -> any RelayConnection
    ) {
        self.ca = ca
        self.queue = queue
        self.makeUpstream = makeUpstream
    }

    public func makeTermination(
        host: String,
        to endpoint: IPEndpoint,
        plaintext: (@Sendable (Data, Direction) -> Void)?,
        onOutcome: @escaping @Sendable (TLSTerminationOutcome) -> Void
    ) async throws -> any RelayConnection {
        // El leaf primero: sin algo que presentarle al cliente no hay inspección posible, y abrir la
        // conexión al servidor real antes de saberlo sería estrenar tráfico por un flujo que va a
        // acabar en passthrough de todas formas.
        let identity = try await ca.mintLeaf(forHost: host)
        return TLSTerminationConnection(
            session: LoopbackTLSServerSession(identity: identity, queue: queue),
            upstream: makeUpstream(endpoint, host, queue),
            plaintext: plaintext,
            onOutcome: onOutcome
        )
    }

    /// La pata saliente de producción: TCP + TLS contra la **misma dirección** a la que iba el
    /// dispositivo, anunciando el nombre que anunció él.
    ///
    /// No se resuelve el nombre por DNS a propósito: el destino lo eligió el dispositivo y inspeccionar
    /// no puede cambiar con quién se habla. El nombre solo se usa para dos cosas, que son las que hacen
    /// un cliente TLS corriente: mandarlo en nuestro ClientHello (SNI) y validar contra él el
    /// certificado del servidor — sin él, la validación iría contra una IP, que no es lo que afirma
    /// ningún certificado de internet.
    static func upstream(
        to endpoint: IPEndpoint,
        serverName: String,
        queue: DispatchQueue
    ) -> any RelayConnection {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, serverName)
        let connection = NWConnection(
            host: NetworkConnectionFactory.host(for: endpoint.address),
            port: NetworkConnectionFactory.port(for: endpoint),
            using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        )
        return NetworkRelayConnection(connection: connection, queue: queue, mode: .stream)
    }
}
