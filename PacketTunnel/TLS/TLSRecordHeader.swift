import Foundation

/// La cabecera de un record de TLS —tipo (1) + versión (2) + longitud (2)— leída del principio de
/// un stream que todavía puede estar llegando.
///
/// Lo comparten `ServerHelloScanner` y `ServerCertificateScanner`, que trocean el mismo stream
/// uno detrás del otro: dos copias de esta lectura serían dos sitios donde decidir distinto qué
/// es un record.
enum TLSRecordHeader {

    /// Los tipos de record que puede llevar un handshake (registro *TLS ContentType* de IANA).
    enum ContentType {
        static let changeCipherSpec: UInt8 = 20
        static let alert: UInt8 = 21
        static let handshake: UInt8 = 22
    }

    enum Reading: Equatable {
        /// Aún no ha llegado la cabecera entera, y lo que hay no la desmiente.
        case needMoreBytes
        /// Esto no es un record de los que se esperaban.
        case notTLS
        /// `length` es la longitud **declarada** del fragmento, que puede no haber llegado.
        case record(contentType: UInt8, length: Int)
    }

    static let length = 5
    /// Una alerta son exactamente dos bytes: nivel y descripción.
    static let alertLength = 2
    /// Un record en claro no lleva más de 2^14 bytes de fragmento (RFC 5246 § 6.2.1).
    static let maxFragmentLength = 16384
    /// `legacy_version` de un record: el byte mayor es 3 en todo lo que existe.
    private static let versionMajor: UInt8 = 3

    /// Lee la cabecera del record con el que empieza `stream`.
    ///
    /// Un tipo que no está en `accepting` o una versión imposible se delatan **en el primer y el
    /// segundo byte**, sin esperar a la cabecera entera: un stream que no es TLS no tiene por qué
    /// llegar a mandar cinco.
    static func read(_ stream: [UInt8], accepting: Set<UInt8>) -> Reading {
        if let contentType = stream.first, !accepting.contains(contentType) { return .notTLS }
        if stream.count >= 2, stream[1] != versionMajor { return .notTLS }
        guard stream.count >= length else { return .needMoreBytes }
        return .record(contentType: stream[0], length: Int(stream[3]) << 8 | Int(stream[4]))
    }
}
