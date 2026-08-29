import Foundation

/// Constructor de bytes de handshake TLS para los tests del escáner de ClientHello y del relay.
///
/// Los vectores son **a mano**, como los goldens del parser de M3: el punto de un test de parser es
/// afirmar contra bytes escritos byte a byte, no contra los que produce el mismo código que se está
/// probando. Cada pieza se compone por separado (cuerpo → mensaje → record) para poder romper
/// exactamente una y dejar el resto bien formado.
enum ClientHelloFixtures {

    static let handshakeContentType: UInt8 = 22
    static let clientHelloMessageType: UInt8 = 1
    static let serverHelloMessageType: UInt8 = 2

    /// Una extensión cualquiera con su relleno, para poder poner cosas antes o después del SNI.
    struct Extension {
        let type: UInt16
        let payload: [UInt8]

        init(type: UInt16, payload: [UInt8] = []) {
            self.type = type
            self.payload = payload
        }

        /// `supported_versions` con TLS 1.3, la que de verdad va delante del SNI en muchos clientes.
        static let supportedVersions = Extension(type: 43, payload: [0x02, 0x03, 0x04])

        /// `padding` (RFC 7685) del tamaño que pida el test: es la forma honesta de inflar un
        /// ClientHello hasta el tamaño que hoy le dan los key shares post-cuánticos.
        static func padding(_ count: Int) -> Extension {
            Extension(type: 21, payload: [UInt8](repeating: 0, count: count))
        }

        /// La del nombre de servidor (RFC 6066), con una `ServerNameList` de una entrada.
        static func serverName(_ host: String, nameType: UInt8 = 0) -> Extension {
            let name = [UInt8](host.utf8)
            return serverName(rawName: name, nameType: nameType)
        }

        /// Igual que la anterior pero con los bytes del nombre puestos a mano: para los nombres que
        /// no son texto ASCII válido y que el escáner debe rechazar.
        static func serverName(rawName: [UInt8], nameType: UInt8 = 0) -> Extension {
            var entry: [UInt8] = [nameType]
            entry += ClientHelloFixtures.uint16(UInt16(rawName.count))
            entry += rawName
            return Extension(type: 0, payload: ClientHelloFixtures.uint16(UInt16(entry.count)) + entry)
        }

        /// Una `ServerNameList` vacía: el cliente manda la extensión y no nombra a nadie.
        static let emptyServerNameList = Extension(type: 0, payload: [0x00, 0x00])

        var bytes: [UInt8] {
            ClientHelloFixtures.uint16(type) + ClientHelloFixtures.uint16(UInt16(payload.count)) + payload
        }
    }

    // MARK: - Composición

    /// Cuerpo de un ClientHello con las extensiones que se le pasen. `extensions: nil` produce un
    /// ClientHello **sin bloque de extensiones**, que es lo que manda un cliente TLS 1.0–1.2.
    static func clientHelloBody(extensions: [Extension]?) -> [UInt8] {
        var body: [UInt8] = [0x03, 0x03]                            // legacy_version = TLS 1.2
        body += [UInt8](repeating: 0xAB, count: 32)                 // random
        body += [32] + [UInt8](repeating: 0xCD, count: 32)          // legacy_session_id
        body += uint16(4) + [0x13, 0x01, 0x13, 0x02]                // cipher_suites
        body += [1, 0]                                              // legacy_compression_methods

        guard let extensions else { return body }
        let encoded = extensions.flatMap(\.bytes)
        body += uint16(UInt16(encoded.count)) + encoded
        return body
    }

    /// Envuelve un cuerpo en su cabecera de mensaje de handshake (tipo + longitud de 3 bytes).
    static func handshakeMessage(type: UInt8 = clientHelloMessageType, body: [UInt8]) -> [UInt8] {
        [type, UInt8(body.count >> 16 & 0xFF), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)] + body
    }

    /// Envuelve un payload en un record TLS (tipo + versión + longitud).
    static func record(type: UInt8 = handshakeContentType, version: [UInt8] = [0x03, 0x01], payload: [UInt8]) -> [UInt8] {
        [type] + version + uint16(UInt16(payload.count)) + payload
    }

    /// El caso normal: un ClientHello con SNI, en un solo record, listo para dárselo al escáner.
    static func clientHello(host: String, extraExtensions: [Extension] = []) -> Data {
        let extensions = [Extension.supportedVersions, .serverName(host)] + extraExtensions
        return Data(record(payload: handshakeMessage(body: clientHelloBody(extensions: extensions))))
    }

    /// Un ClientHello inflado por encima de la MTU del túnel: el tamaño que tienen hoy de verdad
    /// los que llevan key shares post-cuánticos, y por tanto el que llega partido en dos segmentos.
    static func oversizedClientHello(host: String) -> Data {
        clientHello(host: host, extraExtensions: [.padding(1_400)])
    }

    /// El mismo mensaje repartido en varios records de `chunk` bytes: la fragmentación de handshake
    /// que algunos clientes y middleboxes producen.
    static func clientHelloInRecords(host: String, chunk: Int) -> Data {
        let message = handshakeMessage(body: clientHelloBody(extensions: [.serverName(host)]))
        var out: [UInt8] = []
        var index = 0
        while index < message.count {
            let end = min(index + chunk, message.count)
            out += record(payload: Array(message[index..<end]))
            index = end
        }
        return Data(out)
    }

    static func uint16(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xFF)]
    }
}
