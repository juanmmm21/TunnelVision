import Foundation
import Shared

/// Lee el nombre de host (**SNI**) que un cliente TLS anuncia en su ClientHello, alimentándose del
/// stream saliente del flujo tal y como va llegando. Y, del mismo mensaje, **lo que el cliente
/// ofreció**: las versiones de TLS que acepta y sus protocolos de aplicación (`offer`).
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
///
/// **El nombre y la oferta son dos lecturas del mismo mensaje, y ninguna depende de la otra.** Por
/// eso la oferta no viaja dentro de `Outcome`, que habla del nombre: un ClientHello sin SNI acaba
/// en `.unavailable(.noServerName)` y aun así ha dicho qué versiones acepta. Y al revés, una
/// oferta que no se deja leer nunca le quita el nombre a un flujo que lo tenía.
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
    // Los cuatro códigos están comprobados contra el registro de extensiones de TLS de IANA.
    private static let serverNameExtension: UInt16 = 0
    private static let applicationProtocolsExtension: UInt16 = 16
    private static let supportedVersionsExtension: UInt16 = 43
    private static let encryptedClientHelloExtension: UInt16 = 65037
    private static let hostNameType: UInt8 = 0
    /// `legacy_version` de un record: el byte mayor es 3 en todo lo que existe (SSL 3.0 hasta
    /// TLS 1.3, que sigue anunciándose como 3.1 por compatibilidad con middleboxes).
    private static let recordVersionMajor: UInt8 = 3
    /// Longitud máxima de un `host_name` de RFC 6066: un FQDN no pasa de 253 caracteres.
    private static let maxHostNameLength = 253
    /// Cuántos identificadores de ALPN se guardan de un ClientHello, y de qué longitud como mucho.
    /// El cable admite cientos de 255 bytes; los que existen son un puñado y ninguno pasa de
    /// veinte caracteres. El tope es para que la lista que un flujo se lleva a la tabla y a su fila
    /// tenga un tamaño que no elija el otro extremo; lo que no entra se cuenta, no se calla.
    static let maxApplicationProtocols = 16
    static let maxApplicationProtocolLength = 64

    private let config: Config
    /// Bytes del stream aún sin trocear en records.
    private var stream: [UInt8]
    /// Payload de handshake ya extraído de los records, a la espera de completar el mensaje.
    private var handshake: [UInt8]
    /// Desenlace definitivo, si ya se alcanzó.
    private var settled: Outcome?

    /// Lo que el cliente ofreció, una vez que `scan` ha devuelto un desenlace definitivo.
    ///
    /// `nil` mientras el escáner sigue pidiendo bytes, si el stream no llevaba un ClientHello, y
    /// también si lo llevaba pero **no se pudo recorrer entero**: las versiones van en una
    /// extensión, y de un bloque de extensiones a medio leer no se puede afirmar que no estaba.
    /// Decir entonces «hasta `legacy_version`» sería inventarse una oferta.
    public private(set) var offer: ClientTLSOffer?

    public init(config: Config = Config()) {
        self.config = config
        self.stream = []
        self.handshake = []
        self.settled = nil
        self.offer = nil
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
    private mutating func parseHandshakeMessage() -> Outcome? {
        // Cabecera de mensaje: tipo (1) + longitud (3).
        guard handshake.count >= 4 else { return nil }
        guard handshake[0] == Self.clientHelloMessageType else { return .unavailable(.notClientHello) }

        let length = Int(handshake[1]) << 16 | Int(handshake[2]) << 8 | Int(handshake[3])
        guard length <= config.maxHandshakeBytes else { return .unavailable(.tooLarge) }
        guard handshake.count >= 4 + length else { return nil }

        return parseClientHello(handshake[4..<(4 + length)])
    }

    // MARK: - ClientHello

    /// Recorre el cuerpo del ClientHello y sus extensiones: de ahí salen el nombre de servidor
    /// (el desenlace) y la oferta del cliente (`offer`).
    private mutating func parseClientHello(_ body: ArraySlice<UInt8>) -> Outcome {
        var reader = TLSByteReader(body)

        // `legacy_version` (2) + `random` (32), y luego tres vectores que no nos dicen nada.
        guard let legacyVersion = reader.uint16(),
              reader.skip(32),
              reader.skipVector(prefix: .oneByte),    // legacy_session_id
              reader.skipVector(prefix: .twoBytes),   // cipher_suites
              reader.skipVector(prefix: .oneByte)     // legacy_compression_methods
        else { return .unavailable(.malformed) }

        // Un ClientHello sin bloque de extensiones es legal (TLS 1.0–1.2): simplemente no dice a
        // quién llama, que es exactamente `noServerName` y no una malformación. Su oferta es su
        // `legacy_version` y nada más.
        guard !reader.isAtEnd else {
            offer = Self.offer(legacyVersion: legacyVersion, versions: nil, protocols: nil, hasEncryptedClientHello: false)
            return .unavailable(.noServerName)
        }
        guard let extensions = reader.vector(prefix: .twoBytes) else { return .unavailable(.malformed) }

        // De cada extensión vale la primera: un ClientHello no puede repetirlas, y si lo hace no
        // se le deja elegir con la segunda qué versión de sí mismo queda apuntada.
        var serverName: ArraySlice<UInt8>?
        var versions: ArraySlice<UInt8>?
        var protocols: ArraySlice<UInt8>?
        var hasEncryptedClientHello = false
        var walkedWhole = true

        var list = TLSByteReader(extensions)
        while !list.isAtEnd {
            guard let type = list.uint16(), let payload = list.vector(prefix: .twoBytes) else {
                walkedWhole = false
                break
            }
            switch type {
            case Self.serverNameExtension:
                serverName = serverName ?? payload
            case Self.supportedVersionsExtension:
                versions = versions ?? payload
            case Self.applicationProtocolsExtension:
                protocols = protocols ?? payload
            case Self.encryptedClientHelloExtension:
                hasEncryptedClientHello = true
            default:
                continue
            }
        }

        if walkedWhole {
            offer = Self.offer(
                legacyVersion: legacyVersion,
                versions: versions,
                protocols: protocols,
                hasEncryptedClientHello: hasEncryptedClientHello
            )
        }

        guard let serverName else {
            return .unavailable(walkedWhole ? .noServerName : .malformed)
        }
        // Un bloque que se rompe **después** del nombre no le quita el nombre al flujo: ya se
        // había leído entero, y es lo que este escáner contestaba cuando se paraba en él.
        return parseServerNameList(serverName)
    }

    /// Lee la `ServerNameList` de RFC 6066 y devuelve su primera entrada de tipo `host_name`.
    private func parseServerNameList(_ payload: ArraySlice<UInt8>) -> Outcome {
        var reader = TLSByteReader(payload)
        guard let list = reader.vector(prefix: .twoBytes) else { return .unavailable(.malformed) }

        var entries = TLSByteReader(list)
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

    // MARK: - Lo que ofreció el cliente

    /// Compone la oferta a partir del `legacy_version` y de los payloads de las extensiones que
    /// hubiera, o `nil` si alguna de las dos declara más de lo que trae: una oferta leída a medias
    /// no es una oferta más corta, es una que no se sabe cuál es.
    static func offer(
        legacyVersion: UInt16,
        versions: ArraySlice<UInt8>?,
        protocols: ArraySlice<UInt8>?,
        hasEncryptedClientHello: Bool
    ) -> ClientTLSOffer? {
        let offered: OfferedTLSVersions
        if let versions {
            guard let list = offeredVersions(from: versions) else { return nil }
            offered = .listed(list)
        } else {
            // Sin la extensión, el campo antiguo es lo que hay y significa lo que significaba
            // antes de TLS 1.3: la versión más alta que el cliente acepta.
            offered = .upTo(TLSProtocolVersion(rawValue: legacyVersion))
        }

        var names: [String] = []
        var omitted = 0
        if let protocols {
            guard let read = applicationProtocols(from: protocols) else { return nil }
            names = read.names
            omitted = read.omitted
        }

        return ClientTLSOffer(
            versions: offered,
            applicationProtocols: names,
            omittedApplicationProtocols: omitted,
            hasEncryptedClientHello: hasEncryptedClientHello
        )
    }

    /// Lee el payload de `supported_versions` en su forma de **lista**, que es la de un
    /// ClientHello (RFC 8446 § 4.2.1), y le quita los valores GREASE.
    static func offeredVersions(from payload: ArraySlice<UInt8>) -> [TLSProtocolVersion]? {
        var reader = TLSByteReader(payload)
        guard let list = reader.vector(prefix: .oneByte), reader.isAtEnd, list.count.isMultiple(of: 2) else {
            return nil
        }

        var versions: [TLSProtocolVersion] = []
        var entries = TLSByteReader(list)
        while let value = entries.uint16() {
            // Un valor GREASE no es una versión: es relleno que el cliente mete para que los
            // servidores no se acostumbren a una lista fija. Guardarlo además estropearía
            // cualquier «la más baja ofrecida», porque `0x0A0A` ordena por debajo de SSL 3.0.
            guard !isGREASE(value) else { continue }
            versions.append(TLSProtocolVersion(rawValue: value))
        }
        return versions
    }

    /// Lee la `ProtocolNameList` de RFC 7301. Lo que no se puede guardar se cuenta en `omitted`.
    static func applicationProtocols(from payload: ArraySlice<UInt8>) -> (names: [String], omitted: Int)? {
        var reader = TLSByteReader(payload)
        guard let list = reader.vector(prefix: .twoBytes), reader.isAtEnd else { return nil }

        var names: [String] = []
        var omitted = 0
        var entries = TLSByteReader(list)
        while !entries.isAtEnd {
            guard let name = entries.vector(prefix: .oneByte) else { return nil }
            // Los GREASE de ALPN son identificadores de dos bytes con el mismo dibujo que los de
            // versión. Tampoco son protocolos, y por eso no cuentan ni como omitidos.
            if name.count == 2, let first = name.first, let last = name.last,
               isGREASE(UInt16(first) << 8 | UInt16(last)) {
                continue
            }
            guard names.count < maxApplicationProtocols, let text = applicationProtocol(from: name) else {
                omitted += 1
                continue
            }
            names.append(text)
        }
        return (names, omitted)
    }

    /// Convierte los bytes de un identificador de ALPN en texto, o `nil` si no se puede guardar.
    ///
    /// Un identificador es opaco en el cable, pero todos los registrados son ASCII imprimible y
    /// sin espacios (`h2`, `http/1.1`), y es lo único que se admite: estos bytes los elige el otro
    /// extremo y acaban en una columna que separa por espacios y en un informe.
    static func applicationProtocol(from bytes: ArraySlice<UInt8>) -> String? {
        guard (1...maxApplicationProtocolLength).contains(bytes.count) else { return nil }

        var scalars = String.UnicodeScalarView()
        for byte in bytes {
            guard (0x21...0x7E).contains(byte) else { return nil }
            scalars.append(UnicodeScalar(byte))
        }
        return String(scalars)
    }

    /// Los dieciséis valores reservados por RFC 8701: los dos bytes iguales y acabados en `A`
    /// (`0x0A0A`, `0x1A1A`… `0xFAFA`).
    static func isGREASE(_ value: UInt16) -> Bool {
        value & 0x0F0F == 0x0A0A && value >> 8 == value & 0xFF
    }
}
