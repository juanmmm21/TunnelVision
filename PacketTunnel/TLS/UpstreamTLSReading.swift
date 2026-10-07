import Foundation
import Network
import Security
import Shared

/// Lo que negoció la conexión que **el túnel** abre contra el servidor real cuando inspecciona un
/// flujo: la versión y la suite, tal y como las da el sistema una vez terminado el handshake.
///
/// Es la cifra de un flujo inspeccionado, y existe porque su ServerHello no se puede leer del
/// stream como el de los demás: el que el dispositivo recibe es el de nuestra terminación, firmado
/// con nuestro leaf, y apuntárselo al servidor sería informar de lo que elegimos nosotros
/// (`Relay.readServerHello`). El servidor de verdad contesta en la pata saliente, que va cifrada
/// por Network.framework y de la que solo se ve el resultado.
///
/// No toca el ADR 0003: es preguntarle a nuestra propia conexión qué negoció, lo mismo que puede
/// hacer cualquier cliente TLS con la suya.
enum UpstreamTLSReading {

    /// La lectura a partir de los dos valores que da `sec_protocol_metadata`.
    ///
    /// No hay tabla de conversión porque no hace falta: `tls_protocol_version_t` y
    /// `tls_ciphersuite_t` son `uint16_t` cuyos valores **son** los del cable (0x0304, los códigos
    /// de IANA), comprobado en `SecProtocolTypes.h` y sujeto por un test. Así una versión o una
    /// suite que el SDK no nombre se guarda igual que las demás.
    ///
    /// - Returns: `nil` si el sistema no da versión (0): no se negoció TLS en esa conexión, y una
    ///   lectura con ceros sería un hallazgo inventado.
    static func negotiated(version: tls_protocol_version_t, cipherSuite: tls_ciphersuite_t) -> NegotiatedTLS? {
        guard version.rawValue != 0 else { return nil }
        return NegotiatedTLS(
            version: TLSProtocolVersion(rawValue: version.rawValue),
            cipherSuite: TLSCipherSuite(rawValue: cipherSuite.rawValue),
            // El sistema informa de un handshake terminado: la cifra es la definitiva.
            fromHelloRetryRequest: false,
            source: .upstreamConnection
        )
    }

    /// Lo que negoció `connection`, o `nil` si no lleva TLS o todavía no ha terminado su handshake
    /// (los metadatos existen desde `.ready`).
    static func negotiated(by connection: NWConnection) -> NegotiatedTLS? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            return nil
        }
        let security = metadata.securityProtocolMetadata
        return negotiated(
            version: sec_protocol_metadata_get_negotiated_tls_protocol_version(security),
            cipherSuite: sec_protocol_metadata_get_negotiated_tls_ciphersuite(security)
        )
    }
}
