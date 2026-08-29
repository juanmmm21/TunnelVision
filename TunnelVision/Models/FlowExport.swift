import Foundation
import Shared

/// El listado de conexiones exportado en JSON (`docs/ux/screens.md`, pantalla *Captures*): qué lleva
/// cada conexión, cómo se arma el documento y cómo se nombra el fichero.
///
/// Es el núcleo puro del export: aquí no se toca el disco. Quien escribe es `FlowExporter`, y lo hace
/// **a trozos** — prólogo, una entrada por conexión y epílogo —, así que el documento se construye
/// por partes y nunca existe entero en memoria. Ese troceado es la razón de que el armazón se escriba
/// aquí a mano en vez de codificar un objeto raíz de una vez: un historial de decenas de miles de
/// conexiones serializado en un solo `Data` es justo lo que el resto del proyecto evita.
///
/// **Nunca viajan cargas útiles.** El historial guarda metadatos de paquete, no bytes, así que un
/// export que prometiera contenido mentiría sobre lo que el producto hace. Los bytes crudos ya
/// tienen su formato y su sitio: el `.pcap`, que se comparte desde esta misma pantalla.

/// Un extremo de la conexión tal y como sale en el JSON.
public struct FlowExportEndpoint: Codable, Sendable, Equatable {

    public let address: String
    public let port: UInt16

    public init(address: String, port: UInt16) {
        self.address = address
        self.port = port
    }

    public init(_ endpoint: IPEndpoint) {
        self.init(address: endpoint.address.description, port: endpoint.port)
    }
}

/// Una conexión del historial, lista para escribirse.
///
/// Los extremos salen **dos veces a propósito**. `peers` son los dos tal y como están guardados (la
/// 5-tupla canónica, que por diseño no sabe cuál de los dos es el dispositivo) y siempre están;
/// `local`/`remote` son ese mismo par ya repartido, y son `null` cuando el reparto no se pudo hacer.
/// Sin `peers`, una conexión cuyos extremos no se pudieron repartir se exportaría sin direcciones —
/// perder el dato por no saber ordenarlo sería peor que darlo sin ordenar.
public struct FlowExportEntry: Codable, Sendable, Equatable {

    /// La fila del historial. Es lo que permite volver a esta conexión en la app tras leer el fichero.
    public let id: Int64

    public let proto: String

    /// Lo que la app enseña como host: el SNI si se vio, y si no la IP del extremo remoto. Es `null`
    /// cuando no se pudo repartir los extremos, por lo mismo que en pantalla: señalar al propio
    /// dispositivo como si fuera el otro lado invertiría lo que el usuario lee.
    public let host: String?

    /// El nombre que viajó en el ClientHello, si lo hubo. Va aparte de `host` porque no son lo mismo:
    /// `host` puede ser una IP.
    public let sni: String?

    public let local: FlowExportEndpoint?
    public let remote: FlowExportEndpoint?
    public let peers: [FlowExportEndpoint]

    public let firstSeen: Date
    public let lastSeen: Date
    public let durationSeconds: TimeInterval

    public let bytesOut: UInt64
    public let bytesIn: UInt64
    public let packetCount: UInt64

    public let tlsStatus: String

    public init(
        id: Int64,
        proto: String,
        host: String?,
        sni: String?,
        local: FlowExportEndpoint?,
        remote: FlowExportEndpoint?,
        peers: [FlowExportEndpoint],
        firstSeen: Date,
        lastSeen: Date,
        durationSeconds: TimeInterval,
        bytesOut: UInt64,
        bytesIn: UInt64,
        packetCount: UInt64,
        tlsStatus: String
    ) {
        self.id = id
        self.proto = proto
        self.host = host
        self.sni = sni
        self.local = local
        self.remote = remote
        self.peers = peers
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.durationSeconds = durationSeconds
        self.bytesOut = bytesOut
        self.bytesIn = bytesIn
        self.packetCount = packetCount
        self.tlsStatus = tlsStatus
    }

    /// `protocol` es palabra reservada en Swift, y en el fichero tiene que leerse como lo que es.
    private enum CodingKeys: String, CodingKey {
        case id
        case proto = "protocol"
        case host, sni, local, remote, peers
        case firstSeen, lastSeen, durationSeconds
        case bytesOut, bytesIn, packetCount, tlsStatus
    }
}

public enum FlowExport {

    // MARK: - Identidad del formato

    public static let formatIdentifier = "tunnelvision.connections"

    /// Sube cuando cambie la forma de una entrada. Va en el fichero para que un script que lo lea
    /// pueda negarse a interpretar un formato que no conoce en vez de adivinar.
    public static let formatVersion = 1

    /// Lo que el fichero dice de sí mismo. Está para que quien lo abra fuera de la app sepa qué **no**
    /// va a encontrar dentro, sin tener que deducirlo de la ausencia de un campo.
    public static let contentsNote =
        "Connection metadata only. TunnelVision does not record packet payloads; "
        + "the raw bytes live in the .pcap captures."

    // MARK: - Topes

    /// Conexiones que entran como máximo en un export.
    ///
    /// Existe por lo mismo que los topes del `HistoryReader`: el historial lo escribe la extensión y
    /// no tiene techo, así que un export sin tope crecería con el tráfico acumulado. Al alcanzarlo el
    /// fichero lo dice (`truncated`) y la pantalla también: son las conexiones **más recientes**, que
    /// es el trozo que alguien que exporta quiere de verdad.
    public static let defaultLimit = 20_000

    /// Conexiones que se piden al historial por vuelta. No es un tope de contenido sino de memoria:
    /// lo único que existe a la vez es una página y la entrada que se está escribiendo.
    public static let defaultPageSize = 500

    // MARK: - Nombre del fichero

    public static let fileExtension = "json"

    /// `tunnelvision-connections-<yyyyMMdd-HHmmss>.json`, con el sello en UTC como el de las capturas:
    /// el fichero se va a compartir fuera de la app y su nombre es lo único que lo identifica allí.
    public static func fileName(exportedAt date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return "tunnelvision-connections-\(formatter.string(from: date)).\(fileExtension)"
    }

    /// Si un nombre es de un export nuestro. Lo usa el exportador para limpiar el anterior sin tocar
    /// nada que no haya escrito él.
    public static func isExportFileName(_ name: String) -> Bool {
        name.hasPrefix("tunnelvision-connections-") && name.hasSuffix(".\(fileExtension)")
    }

    // MARK: - Traducción

    /// Cómo se escribe un protocolo. No es `displayName`: aquel es texto de pantalla y puede cambiar
    /// de redacción, mientras que esto lo lee un script y tiene que ser estable.
    public static func name(of proto: IPProtocolNumber) -> String {
        switch proto {
        case .tcp: return "tcp"
        case .udp: return "udp"
        case .icmp: return "icmp"
        case .icmpv6: return "icmpv6"
        case .other: return "other"
        }
    }

    /// Cómo se escribe el estado de cifrado, con el mismo criterio: identificadores estables, no la
    /// copia de la pantalla. `notInspectable` es una **garantía** (la conexión rechazó nuestra CA y se
    /// relayeó intacta, ADR 0003), no una avería, y el nombre lo dice sin adjetivos.
    public static func name(of status: TLSInspectionStatus) -> String {
        switch status {
        case .plaintext: return "plaintext"
        case .encrypted: return "encrypted"
        case .inspected: return "inspected"
        case .notInspectable: return "notInspectable"
        }
    }

    /// Una conexión del historial convertida en lo que se escribe.
    public static func entry(for flow: HistoryFlow) -> FlowExportEntry {
        FlowExportEntry(
            id: flow.id,
            proto: name(of: flow.proto),
            host: flow.displayHost,
            sni: flow.stored.sni,
            local: flow.endpoints.map { FlowExportEndpoint($0.local) },
            remote: flow.endpoints.map { FlowExportEndpoint($0.remote) },
            peers: [
                FlowExportEndpoint(flow.stored.key.endpointA),
                FlowExportEndpoint(flow.stored.key.endpointB)
            ],
            firstSeen: flow.firstSeen,
            lastSeen: flow.lastSeen,
            durationSeconds: flow.duration,
            bytesOut: flow.stored.bytesOut,
            bytesIn: flow.stored.bytesIn,
            packetCount: flow.stored.packetCount,
            tlsStatus: name(of: flow.tlsStatus)
        )
    }
}

/// El armazón del documento, trozo a trozo: `start()`, un `append(_:)` por conexión y `finish(...)`.
///
/// **Los recuentos van en el epílogo y no en la cabecera**, y eso es lo que hace posible escribir en
/// streaming: cuántas conexiones entraron y si se llegó al tope solo se sabe al final, y adelantarlo
/// obligaría o a contarlas antes (otra pasada por el historial) o a tenerlas todas en memoria. En un
/// objeto JSON el orden de las claves no significa nada, así que no se pierde nada por decirlo al
/// final.
///
/// No es `Sendable` a propósito: lleva dentro un `JSONEncoder`, que es una clase, y su sitio es dentro
/// del actor que escribe el fichero — un serializador compartido entre tareas escribiría un documento
/// con las entradas entrelazadas.
public struct FlowExportSerializer {

    /// ISO-8601 con fracción de segundo y en UTC: el fichero se lee fuera de la app, puede que en
    /// otra máquina, así que el instante tiene que ser absoluto y no depender de la región de nadie.
    /// Es un `FormatStyle` y no un `ISO8601DateFormatter` porque el segundo es una clase que no es
    /// `Sendable`, y el codificador de fechas exige una closure que sí lo sea.
    private static let iso8601 = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true,
        timeZone: TimeZone(identifier: "UTC") ?? .gmt
    )

    private let exportedAt: Date
    private let encoder: JSONEncoder

    /// Cuántas entradas se han escrito ya. Es lo que acaba en el epílogo.
    public private(set) var writtenCount = 0

    public init(exportedAt: Date) {
        self.exportedAt = exportedAt

        let encoder = JSONEncoder()
        // Legible al abrirlo en Files o en un editor: exportar sirve para mirar los datos, y un
        // fichero de una sola línea de megabytes no se puede mirar. Las claves ordenadas hacen que
        // dos exports del mismo historial sean el mismo fichero, que es lo que permite compararlos.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(FlowExportSerializer.iso8601))
        }
        self.encoder = encoder
    }

    /// La cabecera del documento y la apertura del array. No lleva nada del usuario dentro, así que
    /// no hay nada que escapar: los únicos valores son constantes del formato y la fecha en ISO-8601.
    public func start() -> Data {
        Data("""
        {
          "format": "\(FlowExport.formatIdentifier)",
          "formatVersion": \(FlowExport.formatVersion),
          "exportedAt": "\(exportedAt.formatted(Self.iso8601))",
          "contents": "\(FlowExport.contentsNote)",
          "connections": [
        """.utf8)
    }

    /// Una conexión más. La coma va **delante** de cada entrada salvo la primera: un array JSON no
    /// admite coma final, y saberlo aquí evita que el escritor tenga que llevar la cuenta.
    public mutating func append(_ flow: HistoryFlow) throws -> Data {
        let separator = writtenCount == 0 ? "\n" : ",\n"
        let encoded = try encoder.encode(FlowExport.entry(for: flow))
        writtenCount += 1
        return Data(separator.utf8) + encoded
    }

    /// El cierre del array y los recuentos.
    ///
    /// `truncated` no se deduce de `writtenCount`: que un export tenga exactamente el tope de
    /// conexiones no significa que hubiera más, y decir "recortado" cuando el historial se acabó justo
    /// ahí sería inventarse un historial que no existe. Lo sabe quien pagina, y por eso entra.
    public func finish(truncated: Bool) -> Data {
        Data("""
        \n  ],
          "connectionCount": \(writtenCount),
          "truncated": \(truncated)
        }
        """.utf8)
    }
}
