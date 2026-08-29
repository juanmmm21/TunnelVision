import Foundation

// Todo este fichero es **solo de Debug**. No es una comodidad: una captura sintética metida en el
// contenedor compartido es indistinguible de una real una vez escrita —el historial no marca de
// dónde salió una fila—, así que la única garantía de que un usuario nunca vea tráfico inventado es
// que este código no exista en Release.
#if DEBUG

/// Qué generar. Todo lo que cambia el tamaño o la forma de la captura entra por aquí, y `seed` fija
/// el resto: dos llamadas con la misma especificación producen los mismos bytes.
///
/// Existe porque los tests no quieren la captura de verdad (miles de paquetes por caso) sino su
/// forma, mientras que el sembrador de Simulator sí la quiere entera.
public struct FixtureSpec: Sendable, Equatable {

    /// Semilla del generador. La captura es **determinista**: la misma semilla da los mismos
    /// datagramas byte a byte. Es lo que permite que una medición con Instruments compare el mismo
    /// trabajo antes y después, y que una captura de pantalla del showcase se pueda rehacer.
    public var seed: UInt64

    /// Hora de pared del paquete **más reciente**. El resto del historial queda por detrás: se fecha
    /// desde el final y no desde el principio porque lo que el usuario ve nada más abrir la Timeline
    /// es lo último, y "hace un momento" es lo que hace creíble una captura.
    public var endingAt: Date

    /// Cuánto hacia atrás llega el historial desde `endingAt`.
    public var span: TimeInterval

    /// Flujos de relleno, además del catálogo de casos. Su único cometido es que la lista sea larga:
    /// por encima de `HistoryPolicy.pageSize` (100) la Timeline pagina de verdad, que es la condición
    /// para que un scroll mida algo.
    public var bulkFlowCount: Int

    /// Paquetes del flujo más cargado. Por encima de `HistoryPolicy.packetsPerFlow` (500) el Flow
    /// Inspector recorta la lista y enseña su aviso, que es un estado de pantalla que de otro modo no
    /// se alcanza.
    public var busiestFlowPacketCount: Int

    public init(
        seed: UInt64,
        endingAt: Date,
        span: TimeInterval,
        bulkFlowCount: Int,
        busiestFlowPacketCount: Int
    ) {
        precondition(span > 0, "el historial tiene que abarcar algo de tiempo")
        precondition(bulkFlowCount >= 0, "bulkFlowCount no puede ser negativo")
        precondition(busiestFlowPacketCount >= 4, "un flujo TCP necesita al menos su apertura y su cierre")
        self.seed = seed
        self.endingAt = endingAt
        self.span = span
        self.bulkFlowCount = bulkFlowCount
        self.busiestFlowPacketCount = busiestFlowPacketCount
    }

    /// La captura que el sembrador de Simulator escribe: seis horas de historial, lista larga y un
    /// flujo por encima del tope de paquetes.
    public static func `default`(endingAt: Date = Date()) -> FixtureSpec {
        FixtureSpec(
            seed: 0x5475_6E6E_656C_5669,
            endingAt: endingAt,
            span: 6 * 3600,
            bulkFlowCount: 240,
            busiestFlowPacketCount: 4000
        )
    }
}

/// Un paquete de la captura sintética: su sello, su sentido y **sus bytes**, que son un datagrama IP
/// de verdad (el `PacketParser` de al lado lo parsea y `tcpdump` lo lee).
///
/// `length` se deriva de los bytes en vez de guardarse: es el campo que la pantalla del paquete
/// contrasta con lo que hay en el fichero, así que un fixture donde pudieran discrepar probaría lo
/// contrario de lo que quiere probar.
public struct FixturePacket: Sendable, Equatable {

    /// Nanosegundos del reloj monotónico, como los sella la extensión. La conversión a hora de pared
    /// la hace el `FlowStore` con el ancla de `CaptureFixture`.
    public let timestamp: UInt64
    public let flowKey: FlowKey
    public let direction: Direction
    public let tcpFlags: TCPFlags
    public let bytes: Data

    /// Si sus bytes llegaron al `.pcap`. Falso reproduce lo que en producción ocurre cuando la
    /// captura está apagada o el writer falló: el metadato está guardado y los bytes no, que es el
    /// caso que hace visibles las cuatro razones por las que la pantalla de un paquete puede no tener
    /// nada que enseñar.
    public let wasCaptured: Bool

    public init(
        timestamp: UInt64,
        flowKey: FlowKey,
        direction: Direction,
        tcpFlags: TCPFlags,
        bytes: Data,
        wasCaptured: Bool
    ) {
        precondition(!bytes.isEmpty, "un paquete sin bytes no es un paquete")
        self.timestamp = timestamp
        self.flowKey = flowKey
        self.direction = direction
        self.tcpFlags = tcpFlags
        self.bytes = bytes
        self.wasCaptured = wasCaptured
    }

    public var length: UInt32 { UInt32(bytes.count) }

    /// El metadato tal y como lo escribiría la extensión. La `CaptureLocation` la pone quien escribe:
    /// es lo único de un paquete que no se sabe hasta que sus bytes están en un fichero y en una
    /// posición concretos.
    public func meta(capturedAt location: CaptureLocation?) -> PacketMeta {
        PacketMeta(
            timestamp: timestamp,
            flowKey: flowKey,
            direction: direction,
            length: length,
            tcpFlags: tcpFlags,
            capture: wasCaptured ? location : nil
        )
    }
}

/// Un trozo de contenido descifrado de la captura sintética: lo que la terminación habría leído de
/// una de sus dos patas.
///
/// No es un paquete y no lleva `FlowKey`: sale de un stream ya reensamblado y descifrado, así que lo
/// único que lo sitúa es su conversación —la del flujo al que pertenece— y su sentido
/// (`docs/spec/plaintext.md`).
///
/// `originalLength` **no** está: quien recorta es el escritor de verdad, contra su tope por registro,
/// y un fixture que declarase por su cuenta cuánto se perdió estaría afirmando lo que quiere probar.
public struct FixturePlaintextChunk: Sendable, Equatable {

    /// Nanosegundos del reloj monotónico, como los de un paquete: el sembrador los pasa por el ancla
    /// de la captura, que es lo que los convierte en el instante absoluto que el fichero guarda.
    public let timestamp: UInt64

    public let direction: Direction

    /// El contenido en claro. Texto de verdad en las conversaciones de texto, para que la pantalla se
    /// pueda mirar y no solo compilar.
    public let bytes: Data

    public init(timestamp: UInt64, direction: Direction, bytes: Data) {
        precondition(!bytes.isEmpty, "un trozo vacío no deja registro: el escritor lo ignora")
        self.timestamp = timestamp
        self.direction = direction
        self.bytes = bytes
    }
}

/// Un flujo de la captura sintética con sus paquetes.
///
/// El agregado (`record`) **se deriva de los paquetes** en vez de escribirse a mano: bytes por
/// sentido, cuenta y extremos temporales son justo lo que la tabla de flujos de la extensión
/// acumula, y un fixture que los inventara por separado podría enseñar una fila que no cuadra con la
/// lista de paquetes que se abre al pulsarla.
public struct FixtureFlow: Sendable, Equatable {

    public let key: FlowKey

    /// El host del ClientHello, o `nil` si no hubo. Sin él la app enseña la IP del extremo remoto, que
    /// es un caso que también hay que poder mirar.
    public let sni: String?

    public let tlsStatus: TLSInspectionStatus

    /// En orden temporal ascendente.
    public let packets: [FixturePacket]

    /// Lo que se descifró de él, en orden temporal ascendente. Vacío en todo flujo que no se
    /// inspeccionó, que son casi todos: descifrar exige la CA puesta y la inspección encendida, y
    /// **guardarlo** exige además su propio interruptor (ADR 0007).
    public let plaintext: [FixturePlaintextChunk]

    public init(
        key: FlowKey,
        sni: String?,
        tlsStatus: TLSInspectionStatus,
        packets: [FixturePacket],
        plaintext: [FixturePlaintextChunk] = []
    ) {
        precondition(!packets.isEmpty, "un flujo sin paquetes no tiene ni principio ni final")
        precondition(
            packets.allSatisfy { $0.flowKey == key },
            "todos los paquetes de un flujo tienen que llevar su misma clave canónica"
        )
        precondition(
            zip(packets, packets.dropFirst()).allSatisfy { $0.timestamp <= $1.timestamp },
            "los paquetes de un flujo van en orden temporal ascendente"
        )
        precondition(
            zip(plaintext, plaintext.dropFirst()).allSatisfy { $0.timestamp <= $1.timestamp },
            "los trozos descifrados de un flujo van en orden temporal ascendente"
        )
        precondition(
            plaintext.isEmpty || tlsStatus == .inspected,
            "solo un flujo inspeccionado pudo dejar contenido descifrado"
        )
        self.key = key
        self.sni = sni
        self.tlsStatus = tlsStatus
        self.packets = packets
        self.plaintext = plaintext
    }

    /// `id = 0`: aún sin persistir, igual que lo que produce la tabla de flujos de la extensión. El
    /// store asigna el rowid en el UPSERT por 5-tupla.
    public var record: FlowRecord {
        var bytesOut: UInt64 = 0
        var bytesIn: UInt64 = 0
        for packet in packets {
            switch packet.direction {
            case .outbound: bytesOut += UInt64(packet.length)
            case .inbound: bytesIn += UInt64(packet.length)
            }
        }
        return FlowRecord(
            id: 0,
            key: key,
            firstSeen: packets[0].timestamp,
            lastSeen: packets[packets.count - 1].timestamp,
            bytesOut: bytesOut,
            bytesIn: bytesIn,
            packetCount: UInt64(packets.count),
            tlsStatus: tlsStatus,
            sni: sni
        )
    }
}

/// Una captura sintética completa: los flujos y **el ancla con la que hay que abrir el `FlowStore`**
/// para escribirlos.
///
/// El ancla viaja dentro y no la elige quien escribe porque los sellos de los paquetes son del reloj
/// monotónico y solo tienen sentido junto a ella: separarlas dejaría el historial fechado donde
/// cayera, que con un ancla tomada "ahora" sería seis horas en el futuro.
public struct CaptureFixture: Sendable, Equatable {

    public let anchor: MonotonicAnchor
    public let flows: [FixtureFlow]

    public init(anchor: MonotonicAnchor, flows: [FixtureFlow]) {
        self.anchor = anchor
        self.flows = flows
    }

    public var packetCount: Int { flows.reduce(0) { $0 + $1.packets.count } }

    public var capturedPacketCount: Int {
        flows.reduce(0) { $0 + $1.packets.count(where: \.wasCaptured) }
    }

    public var plaintextChunkCount: Int { flows.reduce(0) { $0 + $1.plaintext.count } }

    /// Hora de pared del primer y del último paquete, que es lo que el eje de la Timeline abarca.
    public var wallClockSpan: ClosedRange<Date>? {
        guard let first = flows.map(\.record.firstSeen).min(),
              let last = flows.map(\.record.lastSeen).max()
        else {
            return nil
        }
        return anchor.date(forUptime: first)...anchor.date(forUptime: last)
    }

    public static func make(_ spec: FixtureSpec) -> CaptureFixture {
        var builder = FixtureBuilder(spec: spec)
        return builder.build()
    }
}

// MARK: - Direcciones y nombres

/// De dónde salen las direcciones y los hosts de la captura sintética.
///
/// Todo son rangos y nombres **reservados para documentación** (RFC 5737, RFC 3849, RFC 2606). No es
/// pedantería: estas capturas acaban en las capturas de pantalla del repo público, y una lista de
/// conexiones con dominios y direcciones de terceros de verdad enseñaría tráfico ajeno que nadie ha
/// tenido nunca, con marcas que no son nuestras.
enum FixtureNetwork {

    /// El dispositivo: las mismas direcciones que el túnel se asigna. Tiene que ser exactamente esto,
    /// o la app no sabrá cuál de los dos extremos de la 5-tupla canónica es el remoto y enseñará
    /// nuestra propia IP como host de cada conexión.
    static var localV4: IPAddress { TunnelAddressing.localIPv4 }
    static var localV6: IPAddress { TunnelAddressing.localIPv6 }

    /// TEST-NET-1 (192.0.2.0/24) y TEST-NET-3 (203.0.113.0/24).
    static func remoteV4(_ index: Int) -> IPAddress {
        let host = UInt8(1 + index % 254)
        let net: [UInt8] = index % 2 == 0 ? [192, 0, 2] : [203, 0, 113]
        return IPAddress(version: .v4, bytes: net + [host])
    }

    /// 2001:db8::/32, el prefijo de documentación.
    static func remoteV6(_ index: Int) -> IPAddress {
        var bytes: [UInt8] = [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        bytes[14] = UInt8(truncatingIfNeeded: index >> 8)
        bytes[15] = UInt8(truncatingIfNeeded: index)
        return IPAddress(version: .v6, bytes: bytes)
    }

    static func local(_ version: IPVersion) -> IPAddress {
        switch version {
        case .v4: return localV4
        case .v6: return localV6
        }
    }
}

// MARK: - Las búsquedas de nombres

/// Los mensajes de DNS que lleva dentro el flujo del puerto 53.
///
/// Son consultas y respuestas **de verdad**, escritas con `DNSMessageFixture`, y existen porque desde
/// el paso 10 del roadmap ese payload ya no es relleno: un disector lo lee y la pantalla del paquete
/// enseña lo que dice. Con ruido dentro, esa parte de la pantalla solo sabría decir que no se puede
/// leer.
///
/// Están escritas a mano y no sorteadas por lo mismo que el catálogo de flujos: **las cuatro
/// lecturas** que `DNSAnswerReading` distingue tienen que salir siempre —direcciones, un nombre,
/// registros que no se desmenuzan y una respuesta sin nada—, y una propiedad que dependa de la
/// semilla no se puede afirmar en un test ni prometer en una captura de pantalla. Van en pares
/// consulta→respuesta porque el guion de un flujo UDP alterna los sentidos, así que el par cae en el
/// orden en que ocurrió.
///
/// Nombres y direcciones reservados (RFC 2606, RFC 5737), como todo lo demás del sembrador: estas
/// pantallas acaban en las capturas del repo público.
enum FixtureLookups {

    /// La dirección que resuelve la primera búsqueda. Es de otro rango que el del resolutor al que se
    /// le pregunta, para que en pantalla no parezca que el servidor se contesta a sí mismo.
    private static func resolved(_ host: UInt8) -> IPAddress {
        IPAddress(version: .v4, bytes: [203, 0, 113, host])
    }

    static let dns: [Data] = [
        // Lo normal, y lo que más cambia una captura de pantalla: un nombre y las direcciones a las
        // que resolvió. Dos, porque una sola no enseñaría cómo se lee una lista.
        DNSMessageFixture.query(id: 0x4a21, name: "api.example.com", type: .a),
        DNSMessageFixture.reply(
            id: 0x4a21, name: "api.example.com", type: .a,
            answers: [.address(resolved(10)), .address(resolved(11))]
        ),

        // La búsqueda inversa: la respuesta es un nombre y no una dirección.
        DNSMessageFixture.query(id: 0x4a22, name: "10.113.0.203.in-addr.arpa", type: .ptr),
        DNSMessageFixture.reply(
            id: 0x4a22, name: "10.113.0.203.in-addr.arpa", type: .ptr,
            answers: [.name("api.example.com", type: .ptr)]
        ),

        // Un tipo que el disector no desmenuza: contestó, y lo honesto es decir cuántos y de qué
        // clase en vez de fingir que cabe en una línea.
        DNSMessageFixture.query(id: 0x4a23, name: "example.com", type: .txt),
        DNSMessageFixture.reply(
            id: 0x4a23, name: "example.com", type: .txt,
            answers: [.opaque(type: .txt, byteCount: 40)]
        ),

        // El nombre que no existe. No es un fallo del dispositivo ni de la app: es lo que contestó el
        // servidor, y es el caso que separa "no hay registros de ese tipo" de "no hay tal nombre".
        DNSMessageFixture.query(id: 0x4a24, name: "missing.example.com", type: .a),
        DNSMessageFixture.reply(
            id: 0x4a24, name: "missing.example.com", type: .a,
            answers: [], responseCode: .nonExistentDomain
        ),
    ]
}

// MARK: - El catálogo de casos

/// Un flujo escrito a mano, no sorteado. Cada uno existe para hacer visible **un** estado que las
/// pantallas pueden enseñar y que un sorteo solo cubriría por suerte.
private struct FlowScript {
    let sni: String?
    let proto: IPProtocolNumber
    let version: IPVersion
    let remotePort: UInt16
    let tlsStatus: TLSInspectionStatus
    let packetCount: Int
    /// El flujo termina con un RST en vez de con el cierre ordenado.
    var endsWithReset = false
    /// Ni uno de sus bytes llegó al fichero: es el flujo entero sin captura.
    var capturesNothing = false
    /// Cuelan un paquete con solo URG puesto, que es el único camino a `PacketEvent.other`.
    var includesUnnamedFlag = false
    /// Qué se descifró de él, si es que se inspeccionó y se guardó.
    var conversation: FixtureConversation?
    /// El payload de cada uno de sus paquetes, escrito a mano, cuando lo que llevan dentro **tiene
    /// que significar algo**: hoy solo el flujo de DNS, cuyos datagramas los lee un disector
    /// (`DNSPresentation`) y no una vista de bytes. Vacío en todos los demás, que se rellenan de
    /// ruido reproducible porque nadie mira dentro.
    var payloads: [Data] = []
}

/// Las conversaciones descifradas que el catálogo sabe escribir.
///
/// Son dos porque la pantalla tiene dos formas de pintar un turno y **tres** estados que solo se
/// alcanzan con contenido delante: el texto, el volcado de lo que no es texto, y el turno que el
/// presupuesto cortó — que se produce mandando un trozo mayor que el tope por registro del escritor
/// **de verdad**, no declarándolo.
private enum FixtureConversation {
    /// Peticiones y respuestas HTTP en claro, con turnos de varios trozos —que es el caso que enseña
    /// que un trozo no es un turno— y una última respuesta que no cabe entera.
    case httpExchange
    /// Tramas binarias, y **solo** binarias: mezclar texto y binario en un mismo turno lo mandaría
    /// entero al volcado, que es cierto pero no es lo que este caso existe para enseñar.
    case binaryFrames
}

// MARK: - El generador

private struct FixtureBuilder {

    /// Uptime del principio del historial. No es cero a propósito: un dispositivo con seis horas de
    /// tráfico lleva más de seis horas encendido, y un sello cerca de cero delataría el fixture al
    /// primero que mirase la resta contra el ancla.
    static let originUptime: UInt64 = 9 * 3600 * 1_000_000_000

    /// En cuántos tramos se reparte la actividad. **Más finos que los que el eje llega a dibujar** —
    /// cuántos ofrece lo decide el ancho de la pantalla (`ScrubCapacity`), y en un iPhone son media
    /// docena—, para que la forma que se ve sea la que aquí se decide y no el resultado de promediar
    /// una actividad plana.
    static let burstBuckets = 24

    /// Tramos que se dejan **vacíos a la fuerza**. La barra de scrub con 24 barras iguales no tiene
    /// forma: nada donde acercarse, nada que recorra el cursor accesible y ningún tramo a cero que
    /// enseñe su clave propia. Se fuerzan en vez de esperar a que salgan porque una propiedad que
    /// depende de la semilla no se puede afirmar en un test ni prometer en una captura de pantalla.
    static let forcedEmptyBuckets = 3

    /// Peso del tramo más cargado, frente a los 0–5 de los demás: el pico que hace que acercarse a
    /// un tramo signifique algo.
    static let peakWeight = 40

    let spec: FixtureSpec
    var random: FixtureRandom
    let spanNanoseconds: UInt64

    init(spec: FixtureSpec) {
        self.spec = spec
        self.random = FixtureRandom(seed: spec.seed)
        self.spanNanoseconds = UInt64(spec.span * 1_000_000_000)
    }

    mutating func build() -> CaptureFixture {
        let weights = bucketWeights()
        let catalogue = Self.catalogue(spec)
        var flows: [FixtureFlow] = []
        flows.reserveCapacity(catalogue.count + spec.bulkFlowCount)

        for (index, script) in catalogue.enumerated() {
            flows.append(makeFlow(script, index: index, weights: weights))
        }
        for offset in 0..<spec.bulkFlowCount {
            let index = catalogue.count + offset
            flows.append(makeFlow(bulkScript(index: index), index: index, weights: weights))
        }

        // El ancla se cuelga del **último paquete que de verdad salió**, no del final nominal del
        // tramo: los flujos caen donde los pone el reparto por pesos, así que el más reciente termina
        // algunos minutos antes del borde. Anclar en el borde dejaría la Timeline abriendo en "hace
        // cinco minutos" en vez de en "hace un momento", que es lo que hace creíble la captura — y la
        // diferencia dependería de la semilla, que es peor que estar mal: sería inestable.
        let newest = flows.map(\.record.lastSeen).max() ?? Self.originUptime + spanNanoseconds
        let anchor = MonotonicAnchor(uptimeNanoseconds: newest, wallClock: spec.endingAt)
        return CaptureFixture(anchor: anchor, flows: flows)
    }

    // MARK: Reparto en el tiempo

    /// Cuánta actividad lleva cada tramo. Los tres vacíos y el pico se ponen a mano; el resto se
    /// sortea, así que el perfil cambia con la semilla pero su forma no.
    private mutating func bucketWeights() -> [Int] {
        var weights = (0..<Self.burstBuckets).map { _ in Int.random(in: 0...5, using: &random) }

        // Los vacíos se eligen entre los tramos interiores: dejar el primero o el último a cero
        // recortaría el historial en vez de agujerearlo, y el eje no lo dibujaría siquiera.
        var candidates = Array(1..<(Self.burstBuckets - 1))
        for _ in 0..<Self.forcedEmptyBuckets {
            let pick = Int.random(in: 0..<candidates.count, using: &random)
            weights[candidates.remove(at: pick)] = 0
        }

        let peak = candidates[Int.random(in: 0..<candidates.count, using: &random)]
        weights[peak] = Self.peakWeight

        // Los extremos nunca quedan a cero: son los que fijan la extensión del historial, y el eje
        // se dibuja entre el primer paquete y el último.
        weights[0] = max(weights[0], 1)
        weights[Self.burstBuckets - 1] = max(weights[Self.burstBuckets - 1], 1)
        return weights
    }

    /// Instante de arranque de un flujo: se sortea un tramo con probabilidad proporcional a su peso y
    /// luego una posición dentro de él.
    private mutating func startTime(weights: [Int]) -> UInt64 {
        let total = weights.reduce(0, +)
        var ticket = Int.random(in: 0..<total, using: &random)
        var bucket = 0
        for (index, weight) in weights.enumerated() {
            if ticket < weight {
                bucket = index
                break
            }
            ticket -= weight
        }

        let bucketWidth = spanNanoseconds / UInt64(weights.count)
        let offset = UInt64.random(in: 0..<bucketWidth, using: &random)
        return Self.originUptime + UInt64(bucket) * bucketWidth + offset
    }

    // MARK: Un flujo

    private mutating func makeFlow(_ script: FlowScript, index: Int, weights: [Int]) -> FixtureFlow {
        precondition(
            script.payloads.isEmpty || script.payloads.count == script.packetCount,
            "un guion con payloads escritos trae uno por paquete, y este trae \(script.payloads.count) para \(script.packetCount)"
        )
        let start = startTime(weights: weights)

        // Lo que dura el flujo se acota contra el final del historial: un flujo que se saliera por el
        // borde fecharía paquetes después del `endingAt` que se pidió.
        let headroom = Self.originUptime + spanNanoseconds - start
        let wanted = UInt64.random(in: 500_000_000...120_000_000_000, using: &random)
        let duration = min(wanted, headroom)

        let localEndpoint = IPEndpoint(
            address: FixtureNetwork.local(script.version),
            port: localPort(script, index: index)
        )
        let remoteEndpoint = IPEndpoint(
            address: remoteAddress(script, index: index),
            port: script.remotePort
        )
        let key = FlowKey(proto: script.proto, source: localEndpoint, destination: remoteEndpoint)

        let timestamps = self.timestamps(count: script.packetCount, start: start, duration: duration)
        let plan = Self.plan(script)

        var packets: [FixturePacket] = []
        packets.reserveCapacity(script.packetCount)
        for (offset, timestamp) in timestamps.enumerated() {
            let step = plan(offset)
            let source = step.direction == .outbound ? localEndpoint : remoteEndpoint
            let destination = step.direction == .outbound ? remoteEndpoint : localEndpoint
            let payload = script.payloads.isEmpty
                ? randomPayload(step.payloadLength)
                : script.payloads[offset]

            packets.append(
                FixturePacket(
                    timestamp: timestamp,
                    flowKey: key,
                    direction: step.direction,
                    tcpFlags: step.flags,
                    bytes: datagram(
                        proto: script.proto,
                        source: source,
                        destination: destination,
                        step: step,
                        payload: payload
                    ),
                    // Un paquete de cada 97 se queda sin bytes, además del flujo que no captura
                    // nada: el hueco tiene que aparecer también en medio de una lista larga, que es
                    // donde en producción lo deja un fallo de escritura puntual.
                    wasCaptured: !script.capturesNothing && offset % 97 != 96
                )
            )
        }
        return FixtureFlow(
            key: key,
            sni: script.sni,
            tlsStatus: script.tlsStatus,
            packets: packets,
            plaintext: Self.conversation(
                script.conversation, host: script.sni ?? "example.com", within: timestamps
            )
        )
    }

    // MARK: Lo descifrado

    /// Los trozos descifrados de un flujo, repartidos sobre los sellos de sus propios paquetes.
    ///
    /// Van sobre los paquetes y no sobre un reloj propio porque en producción **salen de ellos**: la
    /// terminación lee el stream que el relay reensambla, así que un trozo descifrado no puede
    /// fecharse antes del paquete que lo trajo. Se cuelgan del tercio central para dejar fuera el
    /// handshake y el cierre, que es donde no hay contenido de aplicación ninguno.
    ///
    /// Escrito a mano y no sorteado, por lo mismo que el catálogo de flujos: lo que aquí importa es
    /// que cada estado de la pantalla salga **siempre**, y una propiedad que depende de la semilla no
    /// se puede afirmar en un test ni prometer en una captura de pantalla.
    private static func conversation(
        _ kind: FixtureConversation?, host: String, within timestamps: [UInt64]
    ) -> [FixturePlaintextChunk] {
        guard let kind, timestamps.count >= 6 else { return [] }

        let body: [(Direction, Data)]
        switch kind {
        case .httpExchange:
            body = httpExchange(host: host)
        case .binaryFrames:
            body = binaryFrames()
        }

        // Un sello por trozo, tomados del tercio central de la conexión y en orden.
        let first = timestamps.count / 4
        let available = timestamps[first...].prefix(body.count)
        guard available.count == body.count else { return [] }

        return zip(available, body).map { timestamp, piece in
            FixturePlaintextChunk(timestamp: timestamp, direction: piece.0, bytes: piece.1)
        }
    }

    /// Tres peticiones y tres respuestas, con **turnos de varios trozos** —la cabecera y el cuerpo de
    /// una respuesta llegan por separado, que es exactamente lo que la terminación hace y lo que la
    /// pantalla tiene que juntar en una sola cosa dicha— y una última que **no cabe entera**.
    private static func httpExchange(host: String) -> [(Direction, Data)] {
        let json = """
            {"items":[{"id":1,"name":"first"},{"id":2,"name":"second"}],"next":null}
            """
        return [
            (.outbound, Data("""
                GET /v1/items?limit=2 HTTP/1.1\r
                Host: \(host)\r
                Accept: application/json\r
                User-Agent: ExampleApp/1.0\r
                \r

                """.utf8)),
            (.inbound, Data("""
                HTTP/1.1 200 OK\r
                Content-Type: application/json; charset=utf-8\r
                Content-Length: \(json.utf8.count)\r
                \r

                """.utf8)),
            (.inbound, Data(json.utf8)),
            (.outbound, Data("""
                POST /v1/items HTTP/1.1\r
                Host: \(host)\r
                Content-Type: application/json\r
                Content-Length: 24\r
                \r
                {"name":"third","id":3}
                """.utf8)),
            (.inbound, Data("""
                HTTP/1.1 201 Created\r
                Location: /v1/items/3\r
                Content-Length: 0\r
                \r

                """.utf8)),
            (.outbound, Data("""
                GET /v1/stream HTTP/1.1\r
                Host: \(host)\r
                Accept: text/event-stream\r
                \r

                """.utf8)),
            // La respuesta que no cabe. El corte **no se declara**: mide más que el tope por registro
            // del escritor (64 KiB), así que lo recorta él, igual que en un dispositivo. Va sola en su
            // turno para que el aviso salga bajo un cuerpo que se lee.
            (.inbound, Data(String(
                repeating: "{\"event\":\"tick\",\"host\":\"\(host)\",\"value\":0.000}\n",
                count: 1_600
            ).utf8)),
        ]
    }

    /// Un intercambio que no es texto: tramas con longitud, tipo y banderas por delante, como las de
    /// HTTP/2 o gRPC. Ninguna decodifica como texto, que es lo que manda el turno al volcado.
    private static func binaryFrames() -> [(Direction, Data)] {
        var frame = Data([0x00, 0x00, 0x2a, 0x01, 0x05, 0x00, 0x00, 0x00, 0x01])
        frame.append(Data((0..<42).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 0x80) }))

        var acknowledgement = Data([0x00, 0x00, 0x08, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00])
        acknowledgement.append(Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00]))

        var window = Data([0x00, 0x00, 0x04, 0x08, 0x00, 0x00, 0x00, 0x00, 0x01])
        window.append(Data([0x00, 0x00, 0x40, 0x00]))

        return [
            (.outbound, frame),
            (.inbound, acknowledgement),
            (.outbound, window),
        ]
    }

    private mutating func timestamps(count: Int, start: UInt64, duration: UInt64) -> [UInt64] {
        guard count > 1 else { return [start] }
        let stride = duration / UInt64(count - 1)
        var stamps: [UInt64] = []
        stamps.reserveCapacity(count)
        for index in 0..<count {
            // El jitter es media distancia entre paquetes, así que puede reordenar vecinos: por eso
            // se ordena después en vez de confiar en que salgan crecientes.
            let jitter = stride == 0 ? 0 : UInt64.random(in: 0...(stride / 2 + 1), using: &random)
            stamps.append(start + UInt64(index) * stride + jitter)
        }
        return stamps.sorted()
    }

    private mutating func randomPayload(_ length: Int) -> Data {
        guard length > 0 else { return Data() }
        var bytes = [UInt8]()
        bytes.reserveCapacity(length)
        // De ocho en ocho: una tirada del generador da 64 bits, y pedir uno por byte multiplicaría
        // por ocho el coste de la única parte del fixture que sí es grande.
        while bytes.count < length {
            var word = random.next()
            for _ in 0..<8 where bytes.count < length {
                bytes.append(UInt8(truncatingIfNeeded: word))
                word >>= 8
            }
        }
        return Data(bytes)
    }

    // MARK: Los bytes

    /// Serializa el datagrama. Los dos errores que `PacketEmitter` puede lanzar son de programación
    /// del caller —familias mezcladas y datagrama que no cabe—, y aquí ninguno es alcanzable: las dos
    /// direcciones salen de la misma `IPVersion` y los payloads están topados por la MTU. Se traduce
    /// a un fallo de precondición en vez de a un `try?` para que, si alguien rompe alguna de las dos
    /// invariantes, se entere en la línea que la rompió.
    private func datagram(
        proto: IPProtocolNumber,
        source: IPEndpoint,
        destination: IPEndpoint,
        step: PacketStep,
        payload: Data
    ) -> Data {
        do {
            switch proto {
            case .tcp:
                return try PacketEmitter.tcp(
                    source: source,
                    destination: destination,
                    sequence: step.sequence,
                    acknowledgment: step.acknowledgment,
                    flags: step.flags,
                    windowSize: 65535,
                    payload: payload
                )
            case .udp:
                return try PacketEmitter.udp(source: source, destination: destination, payload: payload)
            case .icmp, .icmpv6, .other:
                return try PacketEmitter.datagram(
                    source: source.address,
                    destination: destination.address,
                    rawProtocol: Self.rawProtocol(proto),
                    payload: payload
                )
            }
        } catch {
            preconditionFailure("el fixture emitió un datagrama imposible (\(error))")
        }
    }

    /// ICMP e ICMPv6 llevan su propio número; `.other` viaja como ESP (50), que es un protocolo real
    /// que `IPProtocolNumber` no modela y por tanto el parser colapsa a `.other` conservando el 50.
    private static func rawProtocol(_ proto: IPProtocolNumber) -> UInt8 {
        proto == .other ? 50 : proto.rawValue
    }

    // MARK: Direcciones y puertos

    private func remoteAddress(_ script: FlowScript, index: Int) -> IPAddress {
        switch script.version {
        case .v4: return FixtureNetwork.remoteV4(index)
        case .v6: return FixtureNetwork.remoteV6(index)
        }
    }

    /// Puerto del dispositivo. Es efímero y distinto por flujo, porque la 5-tupla es la identidad de
    /// una conexión: dos flujos que compartieran puerto contra el mismo destino serían **uno**, y el
    /// UPSERT del store fundiría sus filas dejando la lista corta sin que nada lo dijera.
    ///
    /// Cero para los protocolos que no tienen puertos. No es un detalle: el parser deja la 5-tupla a
    /// cero en los dos extremos para ICMP y compañía, así que inventarle un puerto al dispositivo
    /// produciría una clave que **sus propios bytes no reconstruyen** — un flujo cuyos paquetes, al
    /// leerlos del `.pcap`, pertenecerían a otra conexión.
    private func localPort(_ script: FlowScript, index: Int) -> UInt16 {
        switch script.proto {
        case .tcp, .udp: return UInt16(49152 + index % 16000)
        case .icmp, .icmpv6, .other: return 0
        }
    }
}

// MARK: - La forma de una conversación

/// Lo que toca en el paquete número *n* de un flujo: sentido, flags y cuánto payload.
private struct PacketStep {
    let direction: Direction
    let flags: TCPFlags
    let payloadLength: Int
    var sequence: UInt32 = 1
    var acknowledgment: UInt32 = 1
}

extension FixtureBuilder {

    /// Payload máximo de un segmento, contra la MTU del túnel: 1500 menos las cabeceras IPv4 y TCP.
    /// Se usa el peor caso de las dos familias (IPv6 tiene 40 bytes de cabecera, no 20) restando
    /// siempre 60, para que un mismo guion valga en v4 y en v6 sin pasarse.
    static let maxPayload = TunnelAddressing.mtu - 60

    /// El guion de un flujo, como función del índice del paquete. Se decide una vez por flujo y no
    /// paquete a paquete porque es donde vive la única regla que importa: que la conversación tenga
    /// principio y final, que es lo que hace que la pantalla de un paquete tenga los siete sucesos
    /// que sabe traducir y no solo *data*.
    static func plan(_ script: FlowScript) -> (Int) -> PacketStep {
        let count = script.packetCount
        switch script.proto {
        case .tcp:
            return { index in
                switch index {
                case 0:
                    return PacketStep(direction: .outbound, flags: .syn, payloadLength: 0)
                case 1:
                    return PacketStep(direction: .inbound, flags: [.syn, .ack], payloadLength: 0)
                case 2:
                    return PacketStep(direction: .outbound, flags: .ack, payloadLength: 0)
                case count - 1:
                    // Un RST se emite sin payload y corta: es lo que el usuario tiene que leer.
                    let closing: TCPFlags = script.endsWithReset ? [.rst, .ack] : [.fin, .ack]
                    return PacketStep(direction: .outbound, flags: closing, payloadLength: 0)
                case 3 where script.includesUnnamedFlag:
                    // URG a secas: el único camino hasta `PacketEvent.other`, que es lo que la
                    // pantalla enseña cuando no sabe nombrar un paquete.
                    return PacketStep(direction: .outbound, flags: .urg, payloadLength: 24)
                default:
                    // Descarga: lo que baja llena el segmento y lo que sube son peticiones cortas y
                    // ACKs. Es lo que hace que las dos cifras de una fila no se parezcan, que es lo
                    // que la fila existe para enseñar.
                    let inbound = index % 3 != 0
                    if inbound {
                        return PacketStep(
                            direction: .inbound,
                            flags: [.psh, .ack],
                            payloadLength: maxPayload,
                            sequence: UInt32(index) * 1440 + 1,
                            acknowledgment: UInt32(index) * 64 + 1
                        )
                    }
                    let isBareAck = index % 6 == 0
                    return PacketStep(
                        direction: .outbound,
                        flags: isBareAck ? .ack : [.psh, .ack],
                        payloadLength: isBareAck ? 0 : 64 + index % 200,
                        sequence: UInt32(index) * 64 + 1,
                        acknowledgment: UInt32(index) * 1440 + 1
                    )
                }
            }
        case .udp:
            // Sin apertura ni cierre: un datagrama no negocia nada, y el store guarda flags vacías.
            return { index in
                let inbound = index % 2 == 1
                return PacketStep(
                    direction: inbound ? .inbound : .outbound,
                    flags: [],
                    payloadLength: inbound ? maxPayload - 200 : 90 + index % 120
                )
            }
        case .icmp, .icmpv6, .other:
            // Echo y su respuesta: pares que alternan, con el payload fijo de un ping.
            return { index in
                PacketStep(
                    direction: index % 2 == 0 ? .outbound : .inbound,
                    flags: [],
                    payloadLength: 56
                )
            }
        }
    }

    /// Los casos escritos a mano. El orden no importa —la Timeline ordena por instante— pero la
    /// cobertura sí: aquí están los cuatro estados de inspección, los cinco protocolos, las dos
    /// familias de IP, el flujo sin SNI, el host que no cabe en una línea, el que corta en seco, el
    /// que no capturó nada y el que se pasa del tope de paquetes.
    static func catalogue(_ spec: FixtureSpec) -> [FlowScript] {
        [
            // Los cuatro estados de inspección, que son la columna vertebral de la Timeline.
            FlowScript(sni: "plain.example.org", proto: .tcp, version: .v4, remotePort: 80,
                       tlsStatus: .plaintext, packetCount: 14),
            FlowScript(sni: "www.example.com", proto: .tcp, version: .v4, remotePort: 443,
                       tlsStatus: .encrypted, packetCount: 22),
            FlowScript(sni: "api.example.com", proto: .tcp, version: .v4, remotePort: 443,
                       tlsStatus: .inspected, packetCount: 30, conversation: .httpExchange),
            // El segundo inspeccionado, y existe por la pantalla del contenido: es el que enseña un
            // turno que no es texto y otro que el presupuesto cortó, que son los dos estados que un
            // intercambio HTTP corriente no alcanza nunca.
            FlowScript(sni: "stream.example.com", proto: .tcp, version: .v4, remotePort: 443,
                       tlsStatus: .inspected, packetCount: 26, conversation: .binaryFrames),
            // El que rechaza nuestra CA: se relaya intacto y se marca. Es la promesa del producto,
            // así que tiene que poderse mirar.
            FlowScript(sni: "pinned.example.net", proto: .tcp, version: .v4, remotePort: 443,
                       tlsStatus: .notInspectable, packetCount: 8),

            // QUIC sobre IPv6 y DNS en claro: UDP por los dos lados de su rango de tamaños.
            FlowScript(sni: "quic.example.com", proto: .udp, version: .v6, remotePort: 443,
                       tlsStatus: .encrypted, packetCount: 40),
            FlowScript(sni: nil, proto: .udp, version: .v4, remotePort: 53,
                       tlsStatus: .plaintext, packetCount: FixtureLookups.dns.count,
                       payloads: FixtureLookups.dns),

            // Sin SNI: la app cae a la IP del extremo remoto, que en IPv6 es la cadena más larga que
            // una fila puede tener que encajar.
            FlowScript(sni: nil, proto: .tcp, version: .v6, remotePort: 993,
                       tlsStatus: .encrypted, packetCount: 9),
            // El host que no cabe: es el caso que decide si una fila trunca o se rompe con letra AX5.
            FlowScript(sni: "very-long-subdomain-name-that-will-not-fit.cdn.assets.example.com",
                       proto: .tcp, version: .v4, remotePort: 443,
                       tlsStatus: .encrypted, packetCount: 17),

            // Los tres protocolos sin puertos. `.other` es lo que recoge el filtro del mismo nombre.
            FlowScript(sni: nil, proto: .icmp, version: .v4, remotePort: 0,
                       tlsStatus: .plaintext, packetCount: 6),
            FlowScript(sni: nil, proto: .icmpv6, version: .v6, remotePort: 0,
                       tlsStatus: .plaintext, packetCount: 4),
            FlowScript(sni: nil, proto: .other, version: .v4, remotePort: 0,
                       tlsStatus: .plaintext, packetCount: 3),

            // Cortado en seco, y sin un solo byte guardado: las dos cosas que dejan a la pantalla de
            // un paquete sin nada que enseñar.
            FlowScript(sni: "reset.example.org", proto: .tcp, version: .v4, remotePort: 443,
                       tlsStatus: .encrypted, packetCount: 11, endsWithReset: true),
            FlowScript(sni: "uncaptured.example.org", proto: .tcp, version: .v4, remotePort: 443,
                       tlsStatus: .encrypted, packetCount: 12, capturesNothing: true),

            // El más cargado: por encima del tope del Flow Inspector, así que su lista sale recortada
            // y con aviso, y es el único con megabytes que enseñar.
            FlowScript(sni: "downloads.example.com", proto: .tcp, version: .v4, remotePort: 443,
                       tlsStatus: .encrypted, packetCount: spec.busiestFlowPacketCount,
                       includesUnnamedFlag: true),
        ]
    }

    /// Un flujo de relleno. Deliberadamente aburrido: su cometido es ocupar sitio en la lista, y
    /// cualquier caso interesante que apareciera aquí sería una coincidencia de la semilla y no algo
    /// sobre lo que se pueda afirmar nada.
    mutating func bulkScript(index: Int) -> FlowScript {
        let hosts = ["cdn", "static", "img", "api", "sync", "log", "auth", "media", "edge", "mail"]
        let host = "\(hosts[index % hosts.count])\(index % 40).example.com"
        let isV6 = index % 7 == 0
        let isUDP = index % 11 == 0
        let statuses: [TLSInspectionStatus] = [.encrypted, .encrypted, .encrypted, .inspected, .plaintext]

        return FlowScript(
            sni: host,
            proto: isUDP ? .udp : .tcp,
            version: isV6 ? .v6 : .v4,
            remotePort: isUDP ? 443 : (index % 13 == 0 ? 80 : 443),
            tlsStatus: statuses[index % statuses.count],
            packetCount: Int.random(in: 4...24, using: &random)
        )
    }
}

// MARK: - Aleatoriedad reproducible

/// SplitMix64: el generador que hace determinista todo lo de arriba.
///
/// Hace falta uno propio porque `SystemRandomNumberGenerator` **no** es reproducible, y sin
/// reproducibilidad esto no sirve para lo que existe: una medición con Instruments compararía dos
/// capturas distintas y una captura de pantalla no se podría rehacer. SplitMix64 y no algo mejor
/// porque aquí no hay ningún requisito criptográfico —son payloads de mentira— y cabe en diez líneas
/// que se pueden leer.
struct FixtureRandom: RandomNumberGenerator {

    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

#endif
