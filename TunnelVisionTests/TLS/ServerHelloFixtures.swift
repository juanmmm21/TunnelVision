import Foundation

/// Constructor de bytes de ServerHello para los tests de su escáner.
///
/// Como en `ClientHelloFixtures`, de quien toma las piezas comunes (extensión, mensaje, record), los
/// vectores son **a mano**: cada pieza se compone por separado para poder romper exactamente una y
/// dejar el resto bien formado.
enum ServerHelloFixtures {

    typealias Extension = ClientHelloFixtures.Extension

    static let alertContentType: UInt8 = 21

    /// El `random` de un HelloRetryRequest (RFC 8446 § 4.1.3), escrito aquí otra vez a propósito:
    /// el test afirma contra el valor del RFC, no contra la constante del código que prueba.
    static let helloRetryRequestRandom: [UInt8] = [
        0xCF, 0x21, 0xAD, 0x74, 0xE5, 0x9A, 0x61, 0x11, 0xBE, 0x1D, 0x8C, 0x02, 0x1E, 0x65, 0xB8, 0x91,
        0xC2, 0xA2, 0x11, 0x16, 0x7A, 0xBB, 0x8C, 0x5E, 0x07, 0x9E, 0x09, 0xE2, 0xC8, 0xA8, 0x33, 0x9C,
    ]

    static let ordinaryRandom = [UInt8](repeating: 0xAB, count: 32)

    /// `supported_versions` tal y como va en un ServerHello: una sola versión, sin lista.
    static func selectedVersion(_ version: UInt16) -> Extension {
        Extension(type: 43, payload: ClientHelloFixtures.uint16(version))
    }

    /// `key_share` con un relleno cualquiera: la que un servidor TLS 1.3 manda junto a la versión.
    static let keyShare = Extension(type: 51, payload: [0x00, 0x1D, 0x00, 0x02, 0xAA, 0xBB])

    /// `renegotiation_info` vacía: la extensión que un servidor TLS 1.2 manda casi siempre.
    static let renegotiationInfo = Extension(type: 0xFF01, payload: [0x00])

    // MARK: - Composición

    /// Cuerpo de un ServerHello. `extensions: nil` produce uno **sin bloque de extensiones**, legal
    /// hasta TLS 1.2.
    static func serverHelloBody(
        legacyVersion: UInt16 = 0x0303,
        random: [UInt8] = ordinaryRandom,
        sessionID: [UInt8] = [UInt8](repeating: 0xCD, count: 32),
        cipherSuite: UInt16,
        extensions: [Extension]?
    ) -> [UInt8] {
        var body = ClientHelloFixtures.uint16(legacyVersion)
        body += random
        body += [UInt8(sessionID.count)] + sessionID                // legacy_session_id_echo
        body += ClientHelloFixtures.uint16(cipherSuite)
        body += [0]                                                 // legacy_compression_method

        guard let extensions else { return body }
        let encoded = extensions.flatMap(\.bytes)
        body += ClientHelloFixtures.uint16(UInt16(encoded.count)) + encoded
        return body
    }

    static func message(body: [UInt8]) -> [UInt8] {
        ClientHelloFixtures.handshakeMessage(type: ClientHelloFixtures.serverHelloMessageType, body: body)
    }

    /// Un cuerpo envuelto en su mensaje y en un solo record, listo para el escáner.
    static func record(body: [UInt8]) -> Data {
        Data(ClientHelloFixtures.record(version: [0x03, 0x03], payload: message(body: body)))
    }

    /// El caso normal de hoy: TLS 1.3, anunciado en `supported_versions` con `legacy_version` 1.2.
    static func tls13(cipherSuite: UInt16 = 0x1301, random: [UInt8] = ordinaryRandom) -> Data {
        record(body: serverHelloBody(
            random: random,
            cipherSuite: cipherSuite,
            extensions: [keyShare, selectedVersion(0x0304)]
        ))
    }

    /// TLS 1.2: sin `supported_versions`, la versión es la de `legacy_version`.
    static func tls12(cipherSuite: UInt16 = 0xC02F) -> Data {
        record(body: serverHelloBody(cipherSuite: cipherSuite, extensions: [renegotiationInfo]))
    }

    /// Un mensaje `Certificate` de mentira, del tamaño que se pida: lo que un servidor TLS 1.2 mete
    /// detrás del ServerHello, a menudo en el mismo record.
    static func certificateMessage(size: Int) -> [UInt8] {
        ClientHelloFixtures.handshakeMessage(type: 11, body: [UInt8](repeating: 0x5A, count: size))
    }

    /// Un record de alerta: nivel y descripción.
    static func alert(level: UInt8 = 2, description: UInt8) -> Data {
        Data(ClientHelloFixtures.record(type: alertContentType, version: [0x03, 0x03], payload: [level, description]))
    }
}
