import Foundation

/// Contadores acumulados del relay: el reenvío, el nombre que se le lee al handshake y el desenlace
/// de cada intento de inspección.
///
/// Vive en `Shared/IPC` —y no en `PacketTunnel/Relay`, donde nació— por la misma razón que
/// `PipelineStats`: cruza el canal de control dentro de un `ControlResponse`, así que es un
/// **contrato entre los dos procesos** y la app tiene que poder decodificarlo sin enlazar la
/// extensión, cosa que además no puede hacer.
///
/// Los siete de la inspección (`inspectionCandidates`, `terminationsOpened`, `inspectionsAbandoned`,
/// `pinnedHostSkips`, `flowsInspected`, `flowsPinned`, `terminationsFailed`) son los que contestan
/// *«¿por qué no se inspecciona nada?»* delante de un dispositivo. Son de la **sesión**: nacen a cero
/// cuando arranca el túnel y mueren con él, así que un cero no significa lo mismo con el túnel recién
/// encendido que tras media hora navegando.
public struct RelayStats: Sendable, Equatable, Codable {
    /// Flujos UDP para los que se abrió una conexión saliente.
    public var udpFlowsOpened: UInt64 = 0
    /// Datagramas de payload UDP enviados hacia el servidor real.
    public var datagramsSentOutbound: UInt64 = 0
    /// Respuestas UDP reconstruidas y reinyectadas hacia el dispositivo.
    public var datagramsReinjected: UInt64 = 0
    /// Respuestas perdidas porque el emisor no pudo serializar el datagrama (p. ej. demasiado grande).
    /// Cubre tanto UDP como TCP.
    public var emitterFailures: UInt64 = 0
    /// Conexiones UDP que terminaron por su cuenta (servidor cerró o falló).
    public var connectionsClosed: UInt64 = 0
    /// De las UDP cerradas, cuántas lo hicieron por un fallo de red y no por un cierre limpio.
    public var connectionFailures: UInt64 = 0
    /// Paquetes que llegaron a `passthrough` sin ser ni UDP ni TCP (ICMP, etc.): fuera de alcance.
    public var unsupportedPackets: UInt64 = 0

    /// Consultas de DNS que el dispositivo mandó por el túnel (datagramas UDP hacia el puerto 53).
    public var dnsQueriesSent: UInt64 = 0
    /// Respuestas de DNS que volvieron. **Va pegado al anterior porque el par es el dato**: consultas
    /// saliendo y ni una respuesta es la firma de un resolver anunciado que no sirve —el caso al que
    /// lleva un cambio de red, porque los resolvers se leen una sola vez al arrancar— y es lo que el
    /// usuario vive como páginas que cargan para siempre. Solo cubre el DNS en claro sobre UDP: DoT y
    /// DoH viajan por TCP/443 y aquí no se ven.
    public var dnsRepliesReceived: UInt64 = 0

    /// Flujos TCP para los que se creó una máquina de estados (visto un SYN del dispositivo).
    public var tcpFlowsOpened: UInt64 = 0
    /// Flujos TCP terminados y liberados (por `teardown` de la máquina de estados).
    public var tcpFlowsClosed: UInt64 = 0
    /// Segmentos TCP reconstruidos y reinyectados hacia el dispositivo (datos, ACKs, SYN-ACK, FIN, RST).
    public var tcpSegmentsReinjected: UInt64 = 0
    /// Bytes de aplicación (ya en orden) escritos hacia el servidor real.
    public var tcpBytesToServer: UInt64 = 0
    /// Segmentos RST emitidos hacia el dispositivo (rechazo del servidor o degradación acotada).
    public var tcpResetsToDevice: UInt64 = 0

    /// Flujos TLS que dijeron a quién llamaban: se les leyó el SNI del ClientHello.
    public var sniObserved: UInt64 = 0
    /// Flujos hacia el 443 que se quedaron sin nombre (sin extensión SNI, o el stream no era un
    /// handshake TLS). Va al lado del anterior porque la pareja es lo que dice si la Timeline está
    /// enseñando nombres o direcciones.
    public var sniUnavailable: UInt64 = 0

    /// Flujos abiertos como candidatos a inspección (el pipeline los enrutó a `.inspect` y hay
    /// interceptor). Es el denominador de todo lo que sigue.
    public var inspectionCandidates: UInt64 = 0
    /// Candidatos que acabaron con una terminación TLS instalada y alimentada.
    public var terminationsOpened: UInt64 = 0
    /// Candidatos devueltos al passthrough antes de terminar nada: sin nombre (un 443 que no habla
    /// TLS), con la inspección apagada a media apertura, sin CA lista, o retenidos por encima del
    /// tope. Ninguno se marca `notInspectable`: la causa puede desaparecer.
    public var inspectionsAbandoned: UInt64 = 0
    /// Candidatos que ni se intentaron porque su host ya había rechazado nuestro leaf en esta sesión.
    public var pinnedHostSkips: UInt64 = 0
    /// Flujos descifrados de punta a punta.
    public var flowsInspected: UInt64 = 0
    /// Flujos cuyo cliente rechazó nuestro leaf: pinning. Se marcan `notInspectable` y no se
    /// reintentan (ADR 0003), así que este contador es el tamaño de lo que la app **no** puede ver.
    public var flowsPinned: UInt64 = 0
    /// Terminaciones que se abrieron y acabaron en una razón transitoria (el TLS contra el servidor
    /// real no se completó, o falló la pila): esas conexiones se pierden y el cliente reintenta.
    public var terminationsFailed: UInt64 = 0
    /// De las que fallaron, cuántas lo hicieron **antes de que el dispositivo recibiera un byte
    /// suyo**, así que el flujo volvió al passthrough con todo lo que había mandado y la conexión
    /// **no** se perdió. Es lo que separa una inspección que no funciona de un teléfono sin internet:
    /// si este contador va pegado a `terminationsFailed`, la pila de terminación no está levantando
    /// en este dispositivo y aun así se navega.
    public var terminationsRolledBack: UInt64 = 0

    /// Trozos de contenido descifrado entregados a quien los guarda. Con la persistencia apagada
    /// —lo de fábrica— se queda en 0, porque entonces la terminación no copia nada.
    public var plaintextChunksObserved: UInt64 = 0
    /// Trozos que la cola no pudo aceptar por estar llena (el disco no seguía el ritmo). Lo que se
    /// pierde es un pedazo de la conversación guardada, así que se cuenta en vez de callarse.
    public var plaintextChunksDropped: UInt64 = 0

    public init() {}
}

/// Lo que la extensión contesta a `ControlCommand.stats`: los contadores de sus **dos** mitades.
///
/// Van juntos en una sola respuesta porque para quien mira son una sola pregunta —cómo va la sesión—
/// y separarlos solo añadiría un round-trip; y van en campos distintos, en vez de fundidos en una
/// estructura plana, porque cada mitad responde de un componente distinto: el pipeline dice qué se
/// registró, el relay qué se reenvió y qué se inspeccionó.
public struct TunnelStats: Sendable, Equatable, Codable {
    /// Contadores del pipeline (y los del runtime que se le superponen al responder).
    public var pipeline: PipelineStats
    /// Contadores del relay, o `nil` si en ese momento no había relay al que preguntarle.
    ///
    /// Ausente **no** es cero, y por eso es opcional: el relay se cierra antes que el pipeline al
    /// parar el túnel, así que una consulta que caiga en esa ventana no tiene contadores que dar, y
    /// unos ceros dirían que no se inspeccionó nada en toda la sesión — que es justo lo contrario de
    /// lo que estos números existen para responder.
    public var relay: RelayStats?

    /// Qué DNS anunció el túnel y qué dice el sistema ahora, o `nil` si esta respuesta no lo lleva.
    ///
    /// Opcional por la misma razón que el relay, y no por simetría: una lista de anunciados vacía
    /// **afirma** que el túnel no ofreció resolución de nombres —que es justo el fallo que esto viene
    /// a hacer visible—, así que no puede ser también lo que se enseñe cuando nadie preguntó.
    public var resolvers: ResolverStatus?

    public init(
        pipeline: PipelineStats = PipelineStats(),
        relay: RelayStats? = nil,
        resolvers: ResolverStatus? = nil
    ) {
        self.pipeline = pipeline
        self.relay = relay
        self.resolvers = resolvers
    }
}
