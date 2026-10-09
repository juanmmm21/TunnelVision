import Foundation

/// Un extremo de un flujo tal como se escribe.
public struct EvidenceEndpoint: Encodable, Sendable, Hashable {
    public let address: String
    public let port: UInt16

    public init(_ endpoint: IPEndpoint) {
        self.address = endpoint.address.description
        self.port = endpoint.port
    }
}

/// El nombre contra el que se juzgó un flujo, con su origen.
public struct EvidenceFlowName: Encodable, Sendable, Hashable {
    public let text: String

    /// `sni` si lo anunció la conexión, `dns` si se dedujo de una búsqueda anterior.
    public let origin: String

    public init(_ name: FlowName) {
        self.text = name.text
        switch name.origin {
        case .sni: self.origin = "sni"
        case .dns: self.origin = "dns"
        }
    }
}

/// Lo que el cliente ofreció en su ClientHello.
public struct EvidenceClientTLS: Encodable, Sendable, Hashable {

    /// `listed` si `versions` es la lista exacta de `supported_versions`; `upTo` si solo había un
    /// `legacy_version`, y entonces `versions` lleva una sola: el **techo**, no una lista de una.
    public let versionsForm: String
    public let versions: [EvidenceTLSVersion]

    public let applicationProtocols: [String]
    public let omittedApplicationProtocols: Int

    /// Con la marca puesta, esta oferta es la del ClientHello exterior y puede no ser la que el
    /// servidor contestó.
    public let hasEncryptedClientHello: Bool

    public init(_ offer: ClientTLSOffer) {
        switch offer.versions {
        case .listed(let versions):
            self.versionsForm = "listed"
            self.versions = versions.map(EvidenceTLSVersion.init)
        case .upTo(let ceiling):
            self.versionsForm = "upTo"
            self.versions = [EvidenceTLSVersion(ceiling)]
        }
        self.applicationProtocols = offer.applicationProtocols
        self.omittedApplicationProtocols = offer.omittedApplicationProtocols
        self.hasEncryptedClientHello = offer.hasEncryptedClientHello
    }
}

/// Lo que el servidor contestó al ClientHello: una negociación o una alerta.
public struct EvidenceServerTLS: Encodable, Sendable, Hashable {

    /// `negotiated` o `refused`.
    public let answer: String

    public let version: EvidenceTLSVersion?
    public let cipherSuite: EvidenceWireCode?
    public let fromHelloRetryRequest: Bool?

    /// `serverHello` (la respuesta al ClientHello de la app) o `upstreamConnection` (la respuesta
    /// al del túnel, en un flujo inspeccionado). Quien cite la versión cita esto con ella.
    public let source: String?

    /// Solo con `refused`: el código de la alerta, sin interpretar.
    public let alert: UInt8?

    public init(_ answer: ServerTLSAnswer) {
        switch answer {
        case .negotiated(let negotiated):
            self.answer = "negotiated"
            self.version = EvidenceTLSVersion(negotiated.version)
            self.cipherSuite = EvidenceWireCode(negotiated.cipherSuite)
            self.fromHelloRetryRequest = negotiated.fromHelloRetryRequest
            self.source = negotiated.source.rawValue
            self.alert = nil
        case .refused(let alert):
            self.answer = "refused"
            self.version = nil
            self.cipherSuite = nil
            self.fromHelloRetryRequest = nil
            self.source = nil
            self.alert = alert
        }
    }
}

/// La versión de QUIC de un flujo y el extremo del que se leyó.
public struct EvidenceQUIC: Encodable, Sendable, Hashable {
    public let version: EvidenceWireCode

    /// `client` es la versión que el cliente **propuso**; `server`, la que el servidor habla.
    public let source: String

    public init(_ reading: QUICVersionReading) {
        self.version = EvidenceWireCode(reading.version)
        self.source = reading.source.rawValue
    }
}

/// Un certificado que el servidor presentó. Nadie lo ha validado.
public struct EvidenceCertificate: Encodable, Sendable, Hashable {
    public let subject: String
    public let subjectIsTruncated: Bool
    public let issuer: String
    public let issuerIsTruncated: Bool
    public let notAfter: Date

    public init(_ certificate: ServerCertificate) {
        self.subject = certificate.subject.text
        self.subjectIsTruncated = certificate.subject.isTruncated
        self.issuer = certificate.issuer.text
        self.issuerIsTruncated = certificate.issuer.isTruncated
        self.notAfter = certificate.notAfter
    }
}

/// Qué se sabe del certificado del servidor de un flujo, con el motivo cuando no se sabe. Va
/// siempre: un campo ausente no distinguiría «TLS 1.3 lo manda cifrado» de «no se leyó».
public struct EvidenceCertificateVisibility: Encodable, Sendable, Hashable {

    /// `presented`, `notSent`, `encryptedInHandshake`, `replacedByInspection`, `noNegotiation` o
    /// `notRead`.
    public let visibility: String

    /// Solo con `notSent`: `resumedSession` o `noCertificateMessage`.
    public let absence: String?

    /// Solo con `presented`: la cadena, el del servidor primero. Es un principio de lo que mandó.
    public let chain: [EvidenceCertificate]?

    /// Solo con `presented`: `chain` es la cadena entera.
    public let chainIsComplete: Bool?

    public init(_ visibility: ServerCertificateVisibility) {
        switch visibility {
        case .presented(let chain):
            self.init(
                named: "presented",
                chain: chain.certificates.map(EvidenceCertificate.init),
                chainIsComplete: chain.isComplete
            )
        case .notSent(let absence):
            self.init(named: "notSent", absence: absence.rawValue)
        case .encryptedInHandshake:
            self.init(named: "encryptedInHandshake")
        case .replacedByInspection:
            self.init(named: "replacedByInspection")
        case .noNegotiation:
            self.init(named: "noNegotiation")
        case .notRead:
            self.init(named: "notRead")
        }
    }

    private init(
        named visibility: String,
        absence: String? = nil,
        chain: [EvidenceCertificate]? = nil,
        chainIsComplete: Bool? = nil
    ) {
        self.visibility = visibility
        self.absence = absence
        self.chain = chain
        self.chainIsComplete = chainIsComplete
    }
}

/// Un flujo de la sesión tal como se escribe en `flows.json`.
///
/// Solo van los dos extremos como están guardados (`peers`), sin repartir en local y remoto: la
/// 5-tupla canónica no sabe cuál de los dos es el dispositivo, y decirlo aquí sería inventarlo.
/// El sentido sí está en `bytesOut` / `bytesIn`, que se contaron paquete a paquete.
public struct EvidenceFlow: Encodable, Sendable, Hashable {

    public let id: Int64
    public let proto: String
    public let peers: [EvidenceEndpoint]

    public let firstSeen: Date
    public let lastSeen: Date
    public let durationSeconds: TimeInterval

    public let bytesOut: UInt64
    public let bytesIn: UInt64
    public let packetCount: UInt64

    /// `plaintext`, `encrypted`, `inspected` o `notInspectable`. En TCP los dos primeros nacen
    /// del **puerto**: lo que se observó de verdad está en `streamOpening` y en las lecturas de TLS.
    public let tlsStatus: String

    /// El nombre contra el que se juzgó el flujo, o ausente si no tiene.
    public let name: EvidenceFlowName?

    public let sni: String?
    public let dnsName: String?

    /// Los demás nombres que la dirección tenía vivos: el flujo pudo ser de cualquiera de ellos.
    public let dnsOtherNames: [String]

    /// `tlsHandshake`, `httpRequest` o `unrecognised`; ausente si no se leyó el arranque.
    public let streamOpening: String?

    public let clientTLS: EvidenceClientTLS?
    public let serverTLS: EvidenceServerTLS?
    public let quic: EvidenceQUIC?
    public let serverCertificate: EvidenceCertificateVisibility

    /// Los hallazgos de `findings.json` que este flujo prueba, en su orden.
    public let findingIDs: [String]

    public init(_ flow: StoredFlow, findingIDs: [String]) {
        self.id = flow.id
        self.proto = Self.name(of: flow.key.proto)
        self.peers = [EvidenceEndpoint(flow.key.endpointA), EvidenceEndpoint(flow.key.endpointB)]
        self.firstSeen = flow.firstSeen
        self.lastSeen = flow.lastSeen
        self.durationSeconds = flow.duration
        self.bytesOut = flow.bytesOut
        self.bytesIn = flow.bytesIn
        self.packetCount = flow.packetCount
        self.tlsStatus = Self.name(of: flow.tlsStatus)
        self.name = flow.name.map(EvidenceFlowName.init)
        self.sni = flow.sni
        self.dnsName = flow.resolvedName?.name
        self.dnsOtherNames = flow.resolvedName?.otherNames ?? []
        self.streamOpening = flow.streamOpening?.rawValue
        self.clientTLS = flow.clientTLS.map(EvidenceClientTLS.init)
        self.serverTLS = flow.serverTLS.map(EvidenceServerTLS.init)
        self.quic = flow.quic.map(EvidenceQUIC.init)
        self.serverCertificate = EvidenceCertificateVisibility(flow.certificateVisibility)
        self.findingIDs = findingIDs
    }

    /// `protocol` es palabra reservada en Swift, y en el fichero tiene que leerse como lo que es.
    private enum CodingKeys: String, CodingKey {
        case id
        case proto = "protocol"
        case peers, firstSeen, lastSeen, durationSeconds
        case bytesOut, bytesIn, packetCount, tlsStatus
        case name, sni, dnsName, dnsOtherNames, streamOpening
        case clientTLS, serverTLS, quic, serverCertificate, findingIDs
    }

    // Identificadores estables y no los `rawValue` numéricos de los enums: esto lo lee un script.

    static func name(of proto: IPProtocolNumber) -> String {
        switch proto {
        case .tcp: return "tcp"
        case .udp: return "udp"
        case .icmp: return "icmp"
        case .icmpv6: return "icmpv6"
        case .other: return "other"
        }
    }

    static func name(of status: TLSInspectionStatus) -> String {
        switch status {
        case .plaintext: return "plaintext"
        case .encrypted: return "encrypted"
        case .inspected: return "inspected"
        case .notInspectable: return "notInspectable"
        }
    }
}

/// `flows.json`: todos los flujos de la sesión, en el orden del historial.
public struct EvidenceFlowsDocument: Encodable, Sendable, Hashable {

    /// Lo que hay que saber para leer las lecturas de TLS sin sacar de ellas más de lo que dicen.
    public static let contentsNote =
        "Connection metadata only: no payloads. Certificate fields are what the server presented; "
        + "nothing was validated. A TLS answer with source upstreamConnection is what the server "
        + "negotiated with the tunnel's own connection, not with the app. A key that is absent is "
        + "a reading that was not made."

    public let format: String
    public let formatVersion: Int
    public let sessionID: Int64
    public let contents: String
    public let flowCount: Int
    public let flows: [EvidenceFlow]

    init(sessionID: Int64, flows: [EvidenceFlow]) {
        self.format = EvidenceBundleFormat.flowsIdentifier
        self.formatVersion = EvidenceBundleFormat.version
        self.sessionID = sessionID
        self.contents = Self.contentsNote
        self.flowCount = flows.count
        self.flows = flows
    }
}
