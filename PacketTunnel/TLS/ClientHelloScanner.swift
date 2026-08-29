import Foundation

/// Lee el nombre de host (**SNI**) que un cliente TLS anuncia en su ClientHello, alimentándose del
/// stream saliente del flujo tal y como va llegando.
///
/// El ClientHello es el primer mensaje del handshake, antes de que exista ninguna clave, así que
/// viaja **en claro**: esto no descifra nada, no necesita la CA local y no roza el ADR 0003. Es un
/// parser de bytes puro, del mismo corte que `PacketParser`, y es lo que hace que la Timeline diga
/// *con quién* habló el dispositivo en vez de enseñar una dirección IP.
///
/// **Es incremental porque el stream llega a trozos, y eso no es una comodidad.** Un ClientHello
/// moderno —con los key shares híbridos post-cuánticos que negocian los clientes actuales— pasa de
/// los 1500 bytes de la MTU del túnel, así que la mayoría de las veces llega **partido en dos
/// segmentos TCP**; un parser de un solo disparo se quedaría sin nombre justo en el caso normal.
/// Por eso se alimenta con lo que el relay entrega al servidor —bytes ya reensamblados y en
/// orden— y contesta `.needMoreBytes` hasta poder decidir.
///
/// **Termina y se queda quieto.** En cuanto devuelve algo que no es `.needMoreBytes`, suelta sus
/// buffers y todas las llamadas siguientes devuelven ese mismo desenlace sin mirar un byte más:
/// quien lo usa puede tenerlo vivo por flujo sin llevar la cuenta, y el resto del stream —que ya va
/// cifrado— no se recorre nunca.
public struct ClientHelloScanner: Sendable {

    public struct Config: Sendable {
        /// Techo de bytes de handshake acumulados antes de rendirse. Un record TLS no puede llevar
        /// más de 2^14 bytes de fragmento, así que un ClientHello que no quepa aquí no es un
        /// ClientHello que vayamos a entender: el tope existe para que un stream que empieza como un
        /// handshake y sigue como cualquier otra cosa no pueda hacer crecer la memoria de la
        /// extensión.
        public var maxHandshakeBytes: Int

        public init(maxHandshakeBytes: Int = 16384) {
            self.maxHandshakeBytes = maxHandshakeBytes
        }
    }

    /// Qué se sabe del flujo tras alimentar el último trozo del stream.
    public enum Outcome: Sendable, Equatable {
        /// Aún no hay bytes suficientes para decidir. El único desenlace no definitivo.
        case needMoreBytes
        /// El cliente anunció este host.
        case found(String)
        /// No habrá nombre para este flujo, y por qué. Es un desenlace legítimo y frecuente (una
        /// conexión a una IP pelada no lleva SNI), no un error que haya que propagar.
        case unavailable(Reason)
    }

    /// Por qué un flujo se queda sin nombre. Se distinguen porque significan cosas distintas para
    /// quien mira el tráfico —no es lo mismo "esto no era TLS" que "era TLS y no dijo a quién
    /// llamaba"— y porque una malformación es lo único que apuntaría a un fallo nuestro.
    public enum Reason: Sendable, Equatable {
        /// El stream no empieza por un record de handshake TLS (texto plano, otro protocolo...).
        case notTLSHandshake
        /// Es un handshake, pero su primer mensaje no es un ClientHello.
        case notClientHello
        /// El ClientHello no se puede recorrer entero: algún vector declara más de lo que hay.
        case malformed
        /// ClientHello sin extensión SNI, o con un nombre que no se puede enseñar ni guardar.
        case noServerName
        /// El mensaje supera `maxHandshakeBytes` antes de poder decidirse.
        case tooLarge
    }

    private static let handshakeContentType: UInt8 = 22
    private static let clientHelloMessageType: UInt8 = 1
    private static let serverNameExtension: UInt16 = 0
    private static let hostNameType: UInt8 = 0
    /// `legacy_version` de un record: el byte mayor es 3 en todo lo que existe (SSL 3.0 hasta
    /// TLS 1.3, que sigue anunciándose como 3.1 por compatibilidad con middleboxes).
    private static let recordVersionMajor: UInt8 = 3
    /// Longitud máxima de un `host_name` de RFC 6066: un FQDN no pasa de 253 caracteres.
    private static let maxHostNameLength = 253

    private let config: Config
    /// Bytes del stream aún sin trocear en records.
    private var stream: [UInt8]
    /// Payload de handshake ya extraído de los records, a la espera de completar el mensaje.
    private var handshake: [UInt8]
    /// Desenlace definitivo, si ya se alcanzó.
    private var settled: Outcome?

    public init(config: Config = Config()) {
        self.config = config
        self.stream = []
        self.handshake = []
        self.settled = nil
    }

    /// Alimenta el escáner con el siguiente trozo del stream saliente y devuelve qué se sabe ya.
    public mutating func scan(_ bytes: Data) -> Outcome {
        if let settled { return settled }

        stream.append(contentsOf: bytes)
        let outcome = advance()
        guard outcome != .needMoreBytes else { return outcome }

        // Definitivo: se sueltan los buffers en el acto. Un flujo TLS vive minutos y mueve
        // megabytes, y no hay ninguna razón para que arrastre su handshake todo ese rato.
        stream = []
        handshake = []
        settled = outcome
        return outcome
    }

    // MARK: - Records

    /// Trocea el stream en records de handshake y va completando el primer mensaje.
    private mutating func advance() -> Outcome {
        while true {
            // El tipo se comprueba con el primer byte y no esperando a la cabecera entera: un stream
            // que no es TLS suele delatarse en el primer byte, y descartarlo ahí evita quedarse
            // esperando cuatro bytes que no van a cambiar nada.
            if let contentType = stream.first, contentType != Self.handshakeContentType {
                return .unavailable(.notTLSHandshake)
            }
            if stream.count >= 2, stream[1] != Self.recordVersionMajor {
                return .unavailable(.notTLSHandshake)
            }
            // Cabecera de record: tipo (1) + versión (2) + longitud (2).
            guard stream.count >= 5 else { return .needMoreBytes }

            let length = Int(stream[3]) << 8 | Int(stream[4])
            guard stream.count >= 5 + length else { return .needMoreBytes }

            handshake.append(contentsOf: stream[5..<(5 + length)])
            stream.removeFirst(5 + length)
            guard handshake.count <= config.maxHandshakeBytes else { return .unavailable(.tooLarge) }

            // Un mensaje incompleto no es un fallo: puede venir repartido en varios records (lo hacen
            // algunos clientes y algún middlebox), así que se sigue leyendo.
            if let outcome = parseHandshakeMessage() { return outcome }
        }
    }

    /// Intenta leer el primer mensaje de handshake acumulado. `nil` = aún incompleto.
    private func parseHandshakeMessage() -> Outcome? {
        // Cabecera de mensaje: tipo (1) + longitud (3).
        guard handshake.count >= 4 else { return nil }
        guard handshake[0] == Self.clientHelloMessageType else { return .unavailable(.notClientHello) }

        let length = Int(handshake[1]) << 16 | Int(handshake[2]) << 8 | Int(handshake[3])
        guard length <= config.maxHandshakeBytes else { return .unavailable(.tooLarge) }
        guard handshake.count >= 4 + length else { return nil }

        return parseClientHello(handshake[4..<(4 + length)])
    }

    // MARK: - ClientHello

    /// Recorre el cuerpo del ClientHello hasta sus extensiones y busca la del nombre de servidor.
    private func parseClientHello(_ body: ArraySlice<UInt8>) -> Outcome {
        var reader = ByteReader(body)

        // `legacy_version` (2) + `random` (32), y luego tres vectores que no nos dicen nada.
        guard reader.skip(34),
              reader.skipVector(prefix: .oneByte),    // legacy_session_id
              reader.skipVector(prefix: .twoBytes),   // cipher_suites
              reader.skipVector(prefix: .oneByte)     // legacy_compression_methods
        else { return .unavailable(.malformed) }

        // Un ClientHello sin bloque de extensiones es legal (TLS 1.0–1.2): simplemente no dice a
        // quién llama, que es exactamente `noServerName` y no una malformación.
        guard !reader.isAtEnd else { return .unavailable(.noServerName) }
        guard let extensions = reader.vector(prefix: .twoBytes) else { return .unavailable(.malformed) }

        var list = ByteReader(extensions)
        while !list.isAtEnd {
            guard let type = list.uint16(), let payload = list.vector(prefix: .twoBytes) else {
                return .unavailable(.malformed)
            }
            guard type == Self.serverNameExtension else { continue }
            return parseServerNameList(payload)
        }
        return .unavailable(.noServerName)
    }

    /// Lee la `ServerNameList` de RFC 6066 y devuelve su primera entrada de tipo `host_name`.
    private func parseServerNameList(_ payload: ArraySlice<UInt8>) -> Outcome {
        var reader = ByteReader(payload)
        guard let list = reader.vector(prefix: .twoBytes) else { return .unavailable(.malformed) }

        var entries = ByteReader(list)
        while !entries.isAtEnd {
            guard let type = entries.uint8(), let name = entries.vector(prefix: .twoBytes) else {
                return .unavailable(.malformed)
            }
            // La lista solo tiene definido `host_name`, pero puede llevar tipos que no conocemos.
            guard type == Self.hostNameType else { continue }
            guard let host = Self.hostName(from: name) else { return .unavailable(.noServerName) }
            return .found(host)
        }
        return .unavailable(.noServerName)
    }

    /// Convierte los bytes del `host_name` en un nombre que se pueda enseñar y guardar, o `nil`.
    ///
    /// Se valida porque **estos bytes los elige el otro extremo**, y de aquí salen directos a una
    /// fila de la Timeline y a una columna de SQLite: un nombre con bytes de control o con
    /// caracteres que no son de un dominio no es mejor que no tener nombre, es peor. RFC 6066 fija
    /// el listón —el `host_name` es ASCII (los nombres internacionales viajan ya en Punycode) y no
    /// lleva punto final— y es el que se aplica aquí.
    ///
    /// Se normaliza a minúsculas porque un nombre de dominio no distingue mayúsculas: sin esto, el
    /// mismo host anunciado de dos formas serían dos hosts distintos en la Timeline y en el filtro.
    static func hostName(from bytes: ArraySlice<UInt8>) -> String? {
        guard (1...maxHostNameLength).contains(bytes.count) else { return nil }
        guard bytes.first != UInt8(ascii: "."), bytes.last != UInt8(ascii: ".") else { return nil }

        var scalars = String.UnicodeScalarView()
        for byte in bytes {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"):
                scalars.append(UnicodeScalar(byte &+ 0x20))
            case UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"):
                scalars.append(UnicodeScalar(byte))
            default:
                return nil
            }
        }
        return String(scalars)
    }

    // MARK: - Lectura de bytes

    /// Cursor con control de límites sobre los bytes de un mensaje.
    ///
    /// TLS codifica casi todo como vectores con su longitud delante, así que el parser es
    /// literalmente "salta un vector, lee el siguiente". Tenerlo en un tipo evita repetir el mismo
    /// control de límites en cada campo, que es justo donde viven los desbordamientos de un parser
    /// de red.
    private struct ByteReader {
        /// Anchura del prefijo de longitud de un vector TLS.
        enum LengthPrefix {
            case oneByte
            case twoBytes
        }

        private let bytes: ArraySlice<UInt8>
        private var index: Int

        init(_ bytes: ArraySlice<UInt8>) {
            self.bytes = bytes
            self.index = bytes.startIndex
        }

        var isAtEnd: Bool { index >= bytes.endIndex }

        private var remaining: Int { bytes.endIndex - index }

        mutating func uint8() -> UInt8? {
            guard remaining >= 1 else { return nil }
            defer { index += 1 }
            return bytes[index]
        }

        mutating func uint16() -> UInt16? {
            guard let high = uint8(), let low = uint8() else { return nil }
            return UInt16(high) << 8 | UInt16(low)
        }

        mutating func skip(_ count: Int) -> Bool {
            guard remaining >= count else { return false }
            index += count
            return true
        }

        /// Lee un vector con su longitud delante y devuelve su contenido.
        mutating func vector(prefix: LengthPrefix) -> ArraySlice<UInt8>? {
            let length: Int
            switch prefix {
            case .oneByte:
                guard let value = uint8() else { return nil }
                length = Int(value)
            case .twoBytes:
                guard let value = uint16() else { return nil }
                length = Int(value)
            }
            guard remaining >= length else { return nil }
            defer { index += length }
            return bytes[index..<(index + length)]
        }

        mutating func skipVector(prefix: LengthPrefix) -> Bool {
            vector(prefix: prefix) != nil
        }
    }
}
