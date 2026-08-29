import Foundation

/// Un mensaje de DNS ya leído (RFC 1035 § 4), que es lo que viaja dentro de un datagrama UDP del
/// puerto 53.
///
/// Es el primer disector por encima de L4 del proyecto (`docs/development/03-roadmap.md`, paso 10) y
/// llega antes que HTTP, los records de TLS o QUIC por una razón que no es de gusto: **es la única
/// capa que un iPhone de 2026 sigue mandando en claro**, así que es la única que se puede leer en
/// hardware sin la inspección de por medio, y la que convierte *UDP · puerto 53 · 76 B* en el nombre
/// que el dispositivo estaba buscando.
///
/// **Solo el mensaje, no la conversación.** Aquí no se emparejan consulta y respuesta por su `id`:
/// eso exigiría estado entre paquetes, y la pantalla que lo lee describe **un** paquete. Y solo se
/// leen las dos secciones que contestan algo —preguntas y respuestas—; la de autoridad y la adicional
/// se dejan sin recorrer a propósito, porque nada las enseña y recorrerlas solo añadiría superficie
/// donde equivocarse.
///
/// ADR 0003 no entra en juego aquí y conviene decirlo: esto lee lo que el dispositivo de su dueño
/// mandó y lo que le contestaron, en claro y sin tocar la seguridad de nadie.
public struct DNSMessage: Sendable, Hashable {

    /// El identificador con el que el que preguntó reconocerá la respuesta.
    public let id: UInt16

    /// El bit QR. Es lo primero que hay que saber de un mensaje: una consulta y su respuesta tienen la
    /// misma forma y las mismas preguntas dentro.
    public let isResponse: Bool

    /// El opcode crudo (0 = consulta estándar). Se lee y **no se enseña**: en el puerto 53 de un
    /// teléfono no hay otra cosa, y un rótulo que siempre dice lo mismo no es un dato. Está aquí
    /// porque es un campo de la cabecera y este tipo *es* la cabecera.
    public let opcode: UInt8

    public let isAuthoritative: Bool

    /// El bit TC: la respuesta no cupo en el datagrama y el que preguntó tendrá que repetir por TCP.
    /// Lo que se lee de ella es cierto pero está incompleto.
    public let isTruncated: Bool

    public let recursionDesired: Bool
    public let recursionAvailable: Bool

    /// Lo que el servidor contestó cuando no contestó un registro.
    public let responseCode: DNSResponseCode

    /// Lo que se preguntó. Es una lista porque el formato la hace lista, aunque en la práctica
    /// siempre traiga una.
    public let questions: [DNSQuestion]

    /// Lo que se contestó, en el orden en que vino. Vacío en toda consulta.
    public let answers: [DNSResourceRecord]

    public init(
        id: UInt16,
        isResponse: Bool,
        opcode: UInt8,
        isAuthoritative: Bool,
        isTruncated: Bool,
        recursionDesired: Bool,
        recursionAvailable: Bool,
        responseCode: DNSResponseCode,
        questions: [DNSQuestion],
        answers: [DNSResourceRecord]
    ) {
        self.id = id
        self.isResponse = isResponse
        self.opcode = opcode
        self.isAuthoritative = isAuthoritative
        self.isTruncated = isTruncated
        self.recursionDesired = recursionDesired
        self.recursionAvailable = recursionAvailable
        self.responseCode = responseCode
        self.questions = questions
        self.answers = answers
    }
}

/// Una pregunta: qué nombre y de qué tipo.
public struct DNSQuestion: Sendable, Hashable {

    /// El nombre, ya en su forma de presentación y **con los bytes raros escapados**
    /// (`DNSMessageParser`).
    public let name: String

    public let type: DNSRecordType

    /// La clase (1 = IN, internet). Se lee porque el formato la trae; nada la enseña, por lo mismo que
    /// el opcode.
    public let recordClass: UInt16

    public init(name: String, type: DNSRecordType, recordClass: UInt16) {
        self.name = name
        self.type = type
        self.recordClass = recordClass
    }
}

/// Un registro de la sección de respuestas.
public struct DNSResourceRecord: Sendable, Hashable {

    public let name: String
    public let type: DNSRecordType
    public let recordClass: UInt16

    /// Cuánto vale la respuesta, en segundos.
    public let timeToLive: UInt32

    public let data: DNSRecordData

    public init(
        name: String,
        type: DNSRecordType,
        recordClass: UInt16,
        timeToLive: UInt32,
        data: DNSRecordData
    ) {
        self.name = name
        self.type = type
        self.recordClass = recordClass
        self.timeToLive = timeToLive
        self.data = data
    }
}

/// El contenido de un registro, leído hasta donde se sabe leerlo.
///
/// **`opaque` no es un fallo**, y por eso no es un error del parser: un TXT o un SOA son registros
/// perfectamente válidos que este disector no desmenuza. Guardar cuánto ocupaban es lo que se sabe de
/// ellos sin inventar nada, y es lo que permite decir *«3 registros TXT»* en vez de callarse.
public enum DNSRecordData: Sendable, Hashable {

    /// A (una IPv4) o AAAA (una IPv6).
    case address(IPAddress)

    /// CNAME, PTR o NS: la respuesta es otro nombre.
    case name(String)

    /// Cualquier otro tipo, o uno de los de arriba con una longitud que no es la suya —un A que no
    /// mide cuatro bytes no es una dirección por mucho que lo diga su tipo—.
    case opaque(byteCount: Int)
}

/// Qué clase de registro pide una pregunta o trae una respuesta.
///
/// Es un envoltorio del número de 16 bits y **no** un `enum` con caso `.other`, al revés que
/// `IPProtocolNumber`: aquí el número es el dato que se enseña cuando el tipo no se conoce —`TYPE64`
/// es como los nombra el propio DNS (RFC 3597 § 5)—, así que colapsar los desconocidos obligaría a
/// guardar el original aparte para no perderlo, y dos representaciones del mismo tipo podrían dejar de
/// ser iguales entre sí.
public struct DNSRecordType: Sendable, Hashable, RawRepresentable {

    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let a = DNSRecordType(rawValue: 1)
    public static let ns = DNSRecordType(rawValue: 2)
    public static let cname = DNSRecordType(rawValue: 5)
    public static let soa = DNSRecordType(rawValue: 6)
    public static let ptr = DNSRecordType(rawValue: 12)
    public static let mx = DNSRecordType(rawValue: 15)
    public static let txt = DNSRecordType(rawValue: 16)
    public static let aaaa = DNSRecordType(rawValue: 28)
    public static let srv = DNSRecordType(rawValue: 33)
    public static let https = DNSRecordType(rawValue: 65)

    /// El nombre del tipo. **No pasa por el catálogo de cadenas**, por lo mismo que `TCP` o `IPv4`: es
    /// el nombre propio del registro y no cambia con el idioma.
    public var displayName: String {
        switch self {
        case .a: return "A"
        case .ns: return "NS"
        case .cname: return "CNAME"
        case .soa: return "SOA"
        case .ptr: return "PTR"
        case .mx: return "MX"
        case .txt: return "TXT"
        case .aaaa: return "AAAA"
        case .srv: return "SRV"
        case .https: return "HTTPS"
        default: return "TYPE\(rawValue)"
        }
    }
}

/// Lo que el servidor contestó cuando no contestó un registro (RFC 1035 § 4.1.1).
///
/// Envoltorio del número por lo mismo que `DNSRecordType`: los códigos que no se conocen se dicen por
/// su número, que es lo único que se sabe de ellos.
public struct DNSResponseCode: Sendable, Hashable, RawRepresentable {

    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Sin error. En una respuesta **sin registros** no significa que todo fuera bien: significa que
    /// el nombre existe y no tiene registros de ese tipo, que es un desenlace distinto de que no
    /// exista.
    public static let noError = DNSResponseCode(rawValue: 0)
    public static let formatError = DNSResponseCode(rawValue: 1)
    public static let serverFailure = DNSResponseCode(rawValue: 2)
    public static let nonExistentDomain = DNSResponseCode(rawValue: 3)
    public static let notImplemented = DNSResponseCode(rawValue: 4)
    public static let refused = DNSResponseCode(rawValue: 5)
}
