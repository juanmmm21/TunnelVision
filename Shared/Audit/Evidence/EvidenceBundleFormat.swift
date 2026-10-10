import Foundation

/// La identidad del formato del paquete de evidencia y cómo se escriben sus documentos.
///
/// El paquete es una carpeta por sesión de auditoría (`docs/spec/audit.md` § *Evidence bundle*).
/// Aquí no se toca el disco: cada documento es un valor que se codifica a `Data`, y quien lo
/// escribe y lo comprime es otro.
public enum EvidenceBundleFormat {

    /// Sube cuando cambie la forma de **cualquier** documento del paquete: llevan todos la misma,
    /// porque se leen juntos y un `findings.json` de una versión con un `flows.json` de otra no
    /// es un paquete.
    public static let version = 1

    public static let sessionIdentifier = "tunnelvision.evidence.session"
    public static let flowsIdentifier = "tunnelvision.evidence.flows"
    public static let findingsIdentifier = "tunnelvision.evidence.findings"
    public static let captureIdentifier = "tunnelvision.evidence.capture"
    public static let manifestIdentifier = "tunnelvision.evidence.manifest"

    public static let sessionFileName = "session.json"
    public static let flowsFileName = "flows.json"
    public static let flowsCSVFileName = "flows.csv"
    public static let findingsFileName = "findings.json"
    public static let captureFileName = "capture.pcapng"
    public static let captureDocumentFileName = "capture.json"
    public static let reportFileName = "report.pdf"
    public static let manifestFileName = "manifest.json"

    // ISO-8601 con fracción de segundo y en UTC, como el export de conexiones: el paquete se lee
    // en otra máquina y el instante no puede depender de la región de nadie.
    private static let iso8601 = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true,
        timeZone: TimeZone(identifier: "UTC") ?? .gmt
    )

    /// Un instante tal como se escribe en cualquier documento del paquete, JSON o CSV.
    public static func timestamp(_ date: Date) -> String {
        date.formatted(iso8601)
    }

    /// Un documento del paquete, codificado.
    ///
    /// Las claves van ordenadas para que dos exportaciones de la misma sesión sean los mismos
    /// bytes: el manifiesto guarda el SHA-256 de cada fichero, y un orden que dependiera de un
    /// hash daría dos digests para la misma evidencia.
    public static func encode<Document: Encodable>(_ document: Document) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(EvidenceBundleFormat.timestamp(date))
        }
        return try encoder.encode(document)
    }
}

/// Un fichero del paquete ya en bytes: su nombre dentro de la carpeta y su contenido.
public struct EvidenceFile: Sendable, Hashable {
    public let name: String
    public let data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

/// Una versión de TLS tal como se escribe: el valor del cable y, si es una versión publicada, su
/// nombre. El valor va siempre porque lo elige el otro extremo y puede no tener nombre.
public struct EvidenceTLSVersion: Encodable, Sendable, Hashable {

    public let wireValue: UInt16

    /// `nil` si el valor no es una de las cinco versiones publicadas.
    public let name: String?

    public init(_ version: TLSProtocolVersion) {
        self.wireValue = version.rawValue
        self.name = Self.publishedName(of: version)
    }

    public static func publishedName(of version: TLSProtocolVersion) -> String? {
        switch version {
        case .ssl30: return "SSL 3.0"
        case .tls10: return "TLS 1.0"
        case .tls11: return "TLS 1.1"
        case .tls12: return "TLS 1.2"
        case .tls13: return "TLS 1.3"
        default: return nil
        }
    }
}

/// Un código del registro de IANA tal como se escribe: su valor y su forma hexadecimal, que es
/// como lo cita el registro. Sin nombre: la tabla de nombres es presentación y no evidencia.
public struct EvidenceWireCode: Encodable, Sendable, Hashable {

    public let wireValue: UInt32
    public let hex: String

    public init(_ suite: TLSCipherSuite) {
        self.wireValue = UInt32(suite.rawValue)
        self.hex = Self.hex(UInt32(suite.rawValue), digits: 4)
    }

    public init(_ version: QUICVersion) {
        self.wireValue = version.rawValue
        self.hex = Self.hex(version.rawValue, digits: 8)
    }

    private static func hex(_ value: UInt32, digits: Int) -> String {
        let text = String(value, radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, digits - text.count)) + text
    }
}

/// Una versión de TLS observada en un flujo, con su origen: lo que cita un hallazgo o un motivo.
public struct EvidenceTLSObservation: Encodable, Sendable, Hashable {

    public let version: EvidenceTLSVersion

    /// `serverHello`, `upstreamConnection` o `quic`. Con `upstreamConnection` la versión es la
    /// que el servidor negoció con el túnel, no con la app.
    public let basis: String

    /// Solo con `serverHello`: la cifra salió de un HelloRetryRequest y no del mensaje definitivo.
    public let fromHelloRetryRequest: Bool?

    /// Solo con `quic`: la versión de QUIC de la que se deduce TLS 1.3.
    public let quicVersion: EvidenceWireCode?

    public init(_ observation: TLSVersionObservation) {
        self.version = EvidenceTLSVersion(observation.version)
        switch observation.basis {
        case .serverHello(let fromHelloRetryRequest):
            self.basis = "serverHello"
            self.fromHelloRetryRequest = fromHelloRetryRequest
            self.quicVersion = nil
        case .upstreamConnection:
            self.basis = "upstreamConnection"
            self.fromHelloRetryRequest = nil
            self.quicVersion = nil
        case .quic(let version):
            self.basis = "quic"
            self.fromHelloRetryRequest = nil
            self.quicVersion = EvidenceWireCode(version)
        }
    }
}
