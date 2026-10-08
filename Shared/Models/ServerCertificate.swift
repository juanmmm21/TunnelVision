import Foundation

/// Un nombre distinguido de un certificado (sujeto o emisor), ya como texto.
///
/// El texto lo elige **el otro extremo**, así que llega acotado y escapado: los atributos van en la
/// forma de RFC 4514 (`CN=…,O=…,C=…`, el más específico primero) con sus caracteres especiales y
/// cualquier carácter de control o de formato escapados, para que un valor no pueda fingir un
/// atributo que no tiene ni mover el texto que lo rodea en un informe.
public struct CertificateName: Sendable, Hashable, Codable {

    public let text: String

    /// El nombre no cabía en el tope y `text` es solo su principio. Va aparte en vez de como unos
    /// puntos suspensivos dentro del texto porque un nombre recortado no es el nombre, y quien lo
    /// cite tiene que poder saberlo sin adivinarlo por cómo acaba.
    public let isTruncated: Bool

    public init(text: String, isTruncated: Bool) {
        self.text = text
        self.isTruncated = isTruncated
    }
}

/// Lo que se apunta de un certificado que un servidor presentó: de quién es, quién lo firmó y
/// hasta cuándo vale.
///
/// **No es una validación.** Son tres campos leídos de bytes que viajaron en claro; nadie ha
/// comprobado la firma, ni que la cadena llegue a una raíz, ni que el nombre sea el del host.
/// Decir «el servidor presentó esto» es todo lo que afirma.
public struct ServerCertificate: Sendable, Hashable, Codable {

    public let subject: CertificateName
    public let issuer: CertificateName

    /// El `notAfter` de su validez.
    public let notAfter: Date

    public init(subject: CertificateName, issuer: CertificateName, notAfter: Date) {
        self.subject = subject
        self.issuer = issuer
        self.notAfter = notAfter
    }
}

/// La cadena de certificados de un mensaje `Certificate`, en el orden en que el servidor la mandó:
/// el suyo primero.
public struct ServerCertificateChain: Sendable, Hashable, Codable {

    /// Los certificados leídos. Es siempre un **principio** de lo que se mandó —la lectura se
    /// para en el primero que no se deja leer en vez de saltárselo—, así que si hay alguno, el
    /// primero es el del servidor.
    public let certificates: [ServerCertificate]

    /// `certificates` es la cadena entera. `false` si el mensaje traía más de lo que se guarda
    /// (por tamaño o por número) o un certificado que no se pudo leer: lo que falta va detrás de
    /// lo que hay. Una cadena vacía e incompleta es «mandó certificados y no se leyó ninguno».
    public let isComplete: Bool

    public init(certificates: [ServerCertificate], isComplete: Bool) {
        self.certificates = certificates
        self.isComplete = isComplete
    }
}

/// Por qué un handshake de TLS ≤ 1.2 siguió adelante **sin** mensaje `Certificate`.
public enum ServerCertificateAbsence: String, Sendable, Hashable, Codable {
    /// Handshake abreviado: la sesión se reanudó y el servidor no vuelve a presentarse. El
    /// certificado es el de la conexión que abrió la sesión, que pudo pasar antes de la captura.
    case resumedSession
    /// Handshake completo sin certificado: una suite anónima o de clave precompartida.
    case noCertificateMessage
}

/// Lo que se leyó del stream de un flujo, detrás de su ServerHello, sobre el certificado del
/// servidor. Solo existe para TLS ≤ 1.2 leído en claro; qué se puede decir de los demás flujos lo
/// contesta `ServerCertificateVisibility`.
public enum ServerCertificateReading: Sendable, Hashable, Codable {
    case chain(ServerCertificateChain)
    case notSent(ServerCertificateAbsence)
}

/// Qué se sabe del certificado del servidor de un flujo, **con el motivo cuando no se sabe**.
///
/// Es lo que lee un informe en vez del campo `serverCertificates` a secas: un campo vacío no
/// distingue «TLS 1.3 lo manda cifrado» de «no se llegó a leer», y la primera es una propiedad del
/// protocolo que hay que decir, no una laguna de la herramienta. Se deriva y no se guarda, porque
/// todo lo que hace falta ya está en la respuesta del servidor y en la lectura.
public enum ServerCertificateVisibility: Sendable, Hashable {
    /// El servidor presentó esta cadena en claro.
    case presented(ServerCertificateChain)
    /// El handshake no llevaba certificado, y por qué.
    case notSent(ServerCertificateAbsence)
    /// TLS 1.3: el certificado va cifrado dentro del handshake y no se puede leer sin terminarlo.
    case encryptedInHandshake
    /// Flujo inspeccionado: el certificado que recibió la app es el de la CA local, no el del
    /// servidor, y la cifra del flujo es la de la conexión que abrió el túnel.
    case replacedByInspection
    /// El servidor se negó con una alerta: no hubo handshake que presentara nada.
    case noNegotiation
    /// No hay lectura: el flujo no era TLS sobre TCP/443, el stream se cortó o no se dejó leer,
    /// o la versión no es una de las que se sabe dónde llevan el certificado.
    case notRead

    public init(answer: ServerTLSAnswer?, reading: ServerCertificateReading?) {
        // Una lectura es una observación y manda sobre lo que se deduzca de la respuesta: si está,
        // es que el certificado (o su ausencia) pasó en claro por delante.
        switch reading {
        case .chain(let chain):
            self = .presented(chain)
            return
        case .notSent(let absence):
            self = .notSent(absence)
            return
        case nil:
            break
        }
        switch answer {
        case .refused:
            self = .noNegotiation
        case .negotiated(let negotiated) where negotiated.source == .upstreamConnection:
            self = .replacedByInspection
        case .negotiated(let negotiated) where negotiated.version == .tls13:
            self = .encryptedInHandshake
        case .negotiated, nil:
            self = .notRead
        }
    }
}

extension TLSProtocolVersion {
    /// El servidor manda su certificado **en claro** con esta versión: SSL 3.0 a TLS 1.2. En 1.3 va
    /// cifrado, y de un valor que no es ninguna versión publicada no se supone nada.
    public var sendsCertificateInClear: Bool {
        (Self.ssl30.rawValue...Self.tls12.rawValue).contains(rawValue)
    }
}
