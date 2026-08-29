import Foundation
import Network
import NetworkExtension
import Security
import Shared

/// Punto de entrada de la extensión: la **única** parte de M7 que solo corre en dispositivo real.
///
/// Es deliberadamente delgada. Todo lo que se puede decidir sin `packetFlow` vive en
/// `PacketPipeline` (`PacketTunnel/Pipeline`), que sí se prueba en Simulator; aquí solo queda el
/// ciclo de vida del túnel, el bucle de lectura y el canal de control. Si aparece lógica nueva que
/// se pueda testear, va al pipeline, no a este fichero (`docs/spec/tunnel-provider.md`).
///
/// `@unchecked Sendable` es honesto aquí: esta clase no tiene estado mutable propio. Su único
/// almacenamiento es `runtime`, un actor que guarda todo lo mutable, así que lo que cruza entre
/// tareas es solo una referencia inmutable. De `packetFlow` (de la superclase) se **lee** solo desde
/// el bucle de lectura, que es una sola tarea secuencial, y se **escribe** solo desde el actor del
/// relay, que serializa sus reinyecciones: son los dos sentidos independientes del interfaz virtual,
/// y ninguno de los dos tiene concurrencia consigo mismo.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {

    private let runtime = TunnelRuntime()

    // MARK: - Ciclo de vida

    /// Se usa la forma con completion handler y no la `async` porque `options` es un
    /// `[String: NSObject]?`: un tipo no `Sendable` que Swift 6 no deja cruzar hacia un override
    /// asíncrono. No se pierde nada — no leemos `options`: los ajustes del usuario los lee `start`
    /// del almacén compartido (`SettingsStore`), que es donde viven de forma duradera, y los cambios
    /// en caliente sobre una sesión ya viva llegan por el canal de control.
    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let completion = UncheckedSendableBox(completionHandler)

        // **Antes** de aplicar nada: los resolvers que se van a anunciar son los que el sistema
        // tiene *ahora*, y en cuanto el túnel se declare primario esa respuesta será la nuestra.
        let reported = SystemResolvers.reported()
        // El filtro vive en `Shared/Models` y está probado; aquí solo se aplica. Se guardan las dos
        // listas —la cruda y la anunciable— porque su diferencia es lo único que separa "el sistema
        // no tenía resolvers" de "los tenía y ninguno se podía anunciar".
        let announceable = TunnelResolvers.announceable(from: reported ?? [])

        // El orden importa: sin `setTunnelNetworkSettings` aplicado, `packetFlow` no entrega nada.
        setTunnelNetworkSettings(Self.makeNetworkSettings(resolvers: announceable)) { [weak self] error in
            if let error {
                completion.value(error)
                return
            }
            guard let self else {
                completion.value(TunnelRuntime.TunnelError.providerDeallocated)
                return
            }
            Task {
                do {
                    try await self.runtime.start(
                        announced: announceable,
                        reported: reported,
                        packetSource: { [weak self] in await self?.nextBatch() },
                        // La contraparte de `readPackets`, inyectada por la misma razón: así el
                        // runtime —y el relay que la recibe— no dependen de NetworkExtension. Si el
                        // provider ya no existe, la respuesta se pierde, que es lo que le pasa a un
                        // paquete cuyo interfaz se ha ido.
                        reinject: { [weak self] datagrams, protocols in
                            self?.packetFlow.writePackets(datagrams, withProtocols: protocols)
                        }
                    )
                    // El vigilante de la red arranca **después** del runtime y no antes: su primera
                    // notificación llega en cuanto se enciende, y sin runtime detrás no tendría dónde
                    // apuntar la red sobre la que se acaba de anunciar.
                    self.startPathMonitor()
                    completion.value(nil)
                } catch {
                    completion.value(error)
                }
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        pathMonitor.cancel()
        await runtime.stop()
    }

    // MARK: - Cambios de red

    /// Vigila por qué red sale el dispositivo. Es lo que convierte "salir de casa" en un evento.
    ///
    /// Se crea con el provider y **no se recrea**: un `NWPathMonitor` cancelado no se puede volver a
    /// arrancar, y este solo vive lo que vive la extensión.
    private let pathMonitor = NWPathMonitor()

    /// Cola propia y serial para las notificaciones del vigilante. Serial importa: dos cambios de red
    /// seguidos harían dos reanuncios solapados, y un reanuncio quita los ajustes de red antes de
    /// volver a ponerlos — solaparlos es la forma de acabar sin ninguno.
    private let pathMonitorQueue = DispatchQueue(label: "com.juanmmm21.tunnelvision.path")

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let signature = Self.signature(of: path)
            Task {
                await self.runtime.networkPathChanged(to: signature, settings: self.networkSettingsControl)
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    /// Reduce un `NWPath` a lo que distingue una red de otra.
    ///
    /// Solo entran los interfaces **físicos** por los que se puede salir. El `utun` del propio túnel
    /// llega como `.other` en cuanto los ajustes están aplicados, así que meterlo haría que cada
    /// reanuncio cambiase la firma y provocase el siguiente; el `loopback` no describe ninguna red.
    private static func signature(of path: NWPath) -> NetworkPathSignature {
        let physical: Set<NWInterface.InterfaceType> = [.wifi, .cellular, .wiredEthernet]
        return NetworkPathSignature(
            isSatisfied: path.status == .satisfied,
            interfaces: path.availableInterfaces.filter { physical.contains($0.type) }.map(\.name),
            // `NWEndpoint` describe el router; su texto basta para compararlo con el de antes, que es
            // lo único que se hace con él.
            gateways: path.gateways.map { String(describing: $0) }
        )
    }

    /// Aplica unos ajustes de red nuevos, o los **quita** si no hay resolvers que anunciar.
    ///
    /// `nil` no es "sin DNS" sino "sin ajustes": es el gesto que deja de hacernos el interfaz primario,
    /// que es lo único que `startTunnel` hace distinto y lo que permite leer los resolvers de verdad
    /// (`ResolverRefresh`). `reasserting` lo lleva quien orquesta, no esta función.
    private func applyNetworkSettings(resolvers: [Shared.IPAddress]?) async throws {
        let settings = resolvers.map { Self.makeNetworkSettings(resolvers: $0) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setTunnelNetworkSettings(settings) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Las dos únicas cosas que el reanuncio necesita del provider, empaquetadas para que el runtime
    /// —que es quien lleva el estado y por tanto quien orquesta— no tenga que importar NetworkExtension.
    ///
    /// `reasserting` va aquí y no dentro de `apply` porque su alcance es **toda** la operación: le dice
    /// al sistema que el túnel se está restableciendo mientras dura la ventana sin ajustes, y esa
    /// ventana cubre dos aplicaciones, no una.
    private var networkSettingsControl: TunnelRuntime.NetworkSettingsControl {
        TunnelRuntime.NetworkSettingsControl(
            apply: { [weak self] resolvers in
                guard let self else { throw TunnelRuntime.TunnelError.providerDeallocated }
                try await self.applyNetworkSettings(resolvers: resolvers)
            },
            setReasserting: { [weak self] value in
                self?.reasserting = value
            }
        )
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        let response = await runtime.handle(messageData: messageData)
        do {
            return try response.encoded()
        } catch {
            // Si ni la propia respuesta se puede serializar no queda nada que contarle a la app:
            // recibe `nil` y lo interpreta como "sin respuesta".
            return nil
        }
    }

    // MARK: - Ajustes de red

    /// Geometría del interfaz virtual. `includedRoutes` por defecto en ambas familias es lo que
    /// hace que el sistema enrute **todo** el tráfico hacia nosotros; sin eso no capturaríamos nada.
    ///
    /// - Parameter resolvers: los que el sistema tenía antes de que este túnel existiera, ya
    ///   filtrados por `TunnelResolvers`. Vacío deja `dnsSettings` sin tocar.
    ///
    /// `Shared.IPAddress` va cualificado porque `Network` —que `NetworkExtension` arrastra— tiene un
    /// protocolo con ese mismo nombre, y sin el módulo delante el tipo es ambiguo.
    private static func makeNetworkSettings(resolvers: [Shared.IPAddress]) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: TunnelAddressing.tunnelRemoteAddress)

        let ipv4 = NEIPv4Settings(
            addresses: [TunnelAddressing.ipv4AddressString],
            subnetMasks: [TunnelAddressing.ipv4SubnetMask]
        )
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        let ipv6 = NEIPv6Settings(
            addresses: [TunnelAddressing.ipv6AddressString],
            networkPrefixLengths: [NSNumber(value: TunnelAddressing.ipv6PrefixLength)]
        )
        ipv6.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6

        settings.mtu = NSNumber(value: TunnelAddressing.mtu)

        // El túnel **reanuncia los resolvers que el sistema ya tenía** (`TunnelResolvers`, con el
        // porqué entero). Hasta 2026-08-15 esto se dejaba a `nil` creyendo que las consultas
        // entrarían igualmente por las rutas por defecto; un `.pcap` del dispositivo demostró que no
        // llegaba ninguna, y un interfaz primario sin resolución de nombres deja al sistema sin red.
        // Sigue sin fijarse un resolver público: redirigiría el DNS del usuario a un tercero que no
        // ha elegido, que es lo contrario del propósito de esta app.
        if !resolvers.isEmpty {
            let dns = NEDNSSettings(servers: resolvers.map(\.description))
            // `[""]` es el sufijo de cualquier nombre, así que **todas** las consultas casan y estos
            // resolvers son los del sistema entero y no los de un dominio. Dejarlo a `nil` también
            // funciona mientras el túnel sea primario, pero entonces la regla vive en una condición
            // implícita en vez de en esta línea.
            dns.matchDomains = [""]
            settings.dnsSettings = dns
        }
        return settings
    }

    // MARK: - Lectura de paquetes

    /// Espera al siguiente lote del interfaz virtual.
    ///
    /// `readPackets` entrega los datagramas en lotes y hay que re-armarlo tras cada entrega; se
    /// envuelve en `async` para que el bucle sea secuencial por construcción. Con un `Task` por
    /// lote no lo sería: dos lotes podrían entrar al pipeline en orden invertido y corromper el
    /// reensamblado y los sellos de tiempo.
    private func nextBatch() async -> TunnelRuntime.PacketBatch {
        await withCheckedContinuation { continuation in
            packetFlow.readPackets { packets, protocols in
                // El `NSNumber` de la familia se colapsa a `Int32` aquí, dentro del closure, para que
                // lo que cruce a la tarea sea un valor `Sendable` y no un objeto de Foundation.
                continuation.resume(returning: Array(zip(packets, protocols.map(\.int32Value))))
            }
        }
    }
}

/// Cuenta las respuestas que la cola del registrador no pudo aceptar.
///
/// Existe como objeto aparte porque el descarte ocurre en el `yield`, que corre en el actor del
/// relay, y el contador se lee desde el `TunnelRuntime` al responder a `.stats`: son dos
/// aislamientos distintos y el dato tiene que cruzar. El `@unchecked` lo justifica el candado, que
/// protege el único campo mutable — la misma solución que el doble del feed en los tests.
private final class DroppedRecordCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func increment() {
        lock.lock()
        value &+= 1
        lock.unlock()
    }

    var count: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// La CA local vista por el motor de terminación: la carga del llavero **la primera vez que hace
/// falta** y la conserva.
///
/// No se resuelve al arrancar el túnel a propósito. El usuario puede generar la CA y confiarla con el
/// túnel ya corriendo, y una CA leída una sola vez en `start` dejaría la inspección apagada hasta el
/// siguiente arranque sin que nada lo explicase. Conservarla tampoco es un adorno: `LocalCA` cachea
/// los leaves que emite, así que recargarla por flujo tiraría esa caché y volvería a recomponer la
/// raíz —una firma P-256— en cada handshake.
///
/// Device-only por lo mismo que el resto de este fichero: el llavero necesita entitlements, así que
/// se valida por compilación.
///
/// Es una clase con candado y **no un actor** por una razón de tipos que importa: un `SecIdentity` no
/// es `Sendable`, así que devolverlo desde el aislamiento de un actor no compila. `LocalCA` resuelve
/// eso mismo siendo un `struct Sendable` cuyos métodos corren en el aislamiento de quien llama, y
/// esto lo imita: lo único que hay que proteger es el hueco donde se guarda la CA cargada.
private final class LazyLocalCA: LeafMinting, @unchecked Sendable {

    private let lock = NSLock()
    private var loaded: LocalCA?

    func mintLeaf(forHost host: String) async throws -> SecIdentity {
        let ca = try resolve()
        return try await ca.mintLeaf(forHost: host, sans: [])
    }

    /// - Throws: `TLSInterceptError.noCA` si no hay CA que cargar, que es la razón **transitoria**
    ///   que el interceptor ya sabe tratar (relay intacto y sin marcar el flujo); el usuario todavía
    ///   puede generarla. Un fallo del llavero se propaga tal cual.
    private func resolve() throws -> LocalCA {
        lock.lock()
        defer { lock.unlock() }
        if let loaded { return loaded }
        guard let ca = try LocalCA.load() else { throw TLSInterceptError.noCA }
        loaded = ca
        return ca
    }
}

/// Transporta un completion handler de NetworkExtension hasta una `Task`.
///
/// Los handlers de `NEPacketTunnelProvider` son closures no `Sendable`, así que Swift 6 no los deja
/// capturar en una tarea. El `@unchecked` es seguro por uso: cada handler se invoca **exactamente
/// una vez**, desde una sola tarea, y la caja no tiene estado mutable que proteger.
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) {
        self.value = value
    }
}

/// Dueño de todo el estado mutable del túnel: el pipeline, los recursos que este solo recibe
/// inyectados (store, ring y captura) y las dos tareas de fondo.
///
/// Es un `actor` porque `startTunnel`, `stopTunnel` y `handleAppMessage` llegan desde el sistema sin
/// garantía de venir de la misma cola, y el bucle de lectura corre en paralelo a los tres.
actor TunnelRuntime {

    /// Un lote de `readPackets` ya despojado de Foundation: datagrama + familia de protocolo.
    typealias PacketBatch = [(Data, Int32)]

    /// Fuente de datagramas. Se inyecta como closure en vez de leer de `packetFlow` directamente
    /// para que este actor no dependa de la superclase de NetworkExtension. `nil` ⇒ el provider ya
    /// no existe y el bucle debe terminar.
    typealias PacketSource = @Sendable () async -> PacketBatch?

    /// Reinyección hacia el dispositivo (`packetFlow.writePackets`), inyectada por lo mismo que la
    /// fuente. Es la forma que `Relay.init` ya tenía prevista para su `reinject`.
    typealias PacketReinjector = @Sendable ([Data], [NSNumber]) -> Void

    /// Lo que el reanuncio del DNS necesita del provider. Se inyecta por lo mismo que las dos de
    /// arriba: el runtime lleva el estado y orquesta, pero no conoce NetworkExtension.
    struct NetworkSettingsControl: Sendable {
        /// Aplica unos ajustes de red con esos resolvers, o los **quita** con `nil`.
        let apply: @Sendable ([Shared.IPAddress]?) async throws -> Void
        /// Marca el túnel como restableciéndose mientras dura la operación entera.
        let setReasserting: @Sendable (Bool) -> Void
    }

    /// Una respuesta ya entregada al dispositivo, camino del registro. Lleva la familia consigo
    /// porque el pipeline la necesita para parsear y el relay ya la sabe.
    private struct ReinjectedDatagram: Sendable {
        let packet: Data
        let protocolFamily: Int32
    }

    enum TunnelError: Error, Sendable, Equatable {
        /// El contenedor del App Group no está disponible. Sin él no hay dónde escribir: es fatal
        /// para el arranque, y casi siempre significa entitlements mal firmados.
        case appGroupUnavailable
        /// El sistema liberó el provider mientras se aplicaban los ajustes de red. No es un fallo
        /// que el usuario pueda arreglar: el túnel ya no existe, solo hay que contarlo y salir.
        case providerDeallocated
    }

    /// Cada cuánto se expiran los flujos inactivos y se vuelca el lote pendiente. Cinco segundos es
    /// un compromiso: bastante fino para que el historial no se quede atrás de forma visible, y
    /// bastante grueso para no despertar la extensión constantemente y gastar batería.
    private static let tickInterval = Duration.seconds(5)

    /// Registros que caben en el ring del feed en vivo. Potencia de dos (lo exige el productor).
    /// 8192 × 64 B ≈ 512 KB: a 10k paquetes/s la app tiene ~800 ms para drenar antes de perder
    /// registros, y el coste en el presupuesto de memoria de la extensión es despreciable.
    private static let ringSlotCount = 8192

    /// Respuestas reinyectadas que caben en la cola del registrador. El tope es de memoria: cada
    /// elemento retiene el datagrama entero, así que 512 × MTU ≈ 768 KB en el peor caso, y eso es lo
    /// que la extensión puede permitirse si el registro se retrasa detrás de una escritura de disco
    /// lenta. Lleno, se descarta el más antiguo y se cuenta: lo que se pierde es la fila del
    /// historial, nunca la respuesta, que ya salió hacia el dispositivo.
    private static let reinjectedRecordCapacity = 512

    /// Cada cuánto, como mucho, se despierta a la app por respuestas reinyectadas. Una señal por
    /// respuesta la despertaría miles de veces por segundo para decirle lo mismo; y saltarse alguna
    /// no esconde nada, porque el lector del feed drena por su cuenta cada segundo aunque no le
    /// llegue ninguna señal (`LiveFeedPolicy.idlePollInterval`).
    private static let reinjectSignalInterval: UInt64 = 100_000_000

    private var pipeline: PacketPipeline?
    private var relay: Relay?
    private var pcap: PcapWriter?
    /// Escritor del contenido descifrado. Se construye siempre, también con la persistencia apagada:
    /// no toca el disco hasta que hay algo que guardar (`docs/spec/plaintext.md`), y quien decide si
    /// llega algo es el relay, que solo le pasa el sumidero a una terminación si el usuario lo quiere.
    private var plaintext: PlaintextWriter?
    private var ring: RingBufferProducer?
    private var store: FlowStore?
    private var readTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var recordTask: Task<Void, Never>?

    /// Entrada de la cola por la que las respuestas reinyectadas llegan al registro. La escribe el
    /// actor del relay (desde el closure de reinyección) y la consume `recordTask`.
    private var reinjectedRecords: AsyncStream<ReinjectedDatagram>.Continuation?
    /// Lo que la cola descartó por estar llena. Vive fuera del actor porque el descarte ocurre en el
    /// `yield`, que corre en el relay.
    private var droppedRecords = DroppedRecordCounter()
    /// Reloj de la sesión, para espaciar las señales al feed. Es el mismo tipo que usan la tabla de
    /// flujos y el pipeline; `SystemMonotonicClock` no tiene estado, así que compartir el valor y
    /// tener uno propio son la misma cosa.
    private let clock = SystemMonotonicClock()
    private var lastReinjectSignal: UInt64 = 0

    /// Dónde vive la captura de esta sesión. Se guarda porque la retención lo necesita después del
    /// arranque, y resolver otra vez el contenedor del App Group en cada barrido sería repetir el
    /// único paso que puede fallar cuando ya se sabe que no falla.
    private var capturesDirectory: URL?

    /// La secuencia que tenía el writer la última vez que se miró. Comparar contra la de ahora es lo
    /// que convierte una rotación en un evento: el writer rota solo, por tamaño, desde dentro de
    /// `write`, así que nadie fuera del hot path se entera si no pregunta.
    private var lastSeenSequence: UInt32?

    /// Dónde vive el contenido descifrado, por lo mismo que el de capturas: el barrido lo necesita en
    /// cada pasada y resolver el contenedor del App Group otra vez sería repetir el único paso que
    /// puede fallar cuando ya se sabe que no falla.
    private var plaintextDirectory: URL?

    /// Lo mismo para el escritor del contenido descifrado. Se compara igual, pero **también cuenta el
    /// paso a "ninguno abierto"**: este escritor suelta su fichero al rotar y no abre el siguiente
    /// hasta que hay algo que meter en él, así que un `nil` no es que no haya pasado nada — es que
    /// acaba de cerrarse un fichero entero.
    private var lastSeenPlaintextSequence: UInt32?

    /// Si el barrido del contenido descifrado aún no ha corrido en esta sesión.
    ///
    /// Hace falta porque las rotaciones no bastan como único disparo: lo que quedó escrito ayer
    /// caduca aunque hoy no se descifre ni un byte, y esperar a la próxima visita a Ajustes dejaría
    /// contenido descifrado vivo indefinidamente en un dispositivo cuyo dueño no abre esa pantalla.
    /// El túnel arrancando es el otro momento en que hay alguien mirando el directorio.
    private var plaintextSweepPending = true

    /// Los resolvers que el túnel tiene anunciados **ahora**: los del arranque, o los del último
    /// reanuncio. `nil` mientras no hay sesión.
    ///
    /// Se conserva porque con el túnel puesto ya no se puede volver a saber —`res_getservers` contesta
    /// por el interfaz primario, que somos nosotros (medido en el iPhone el 2026-08-16)— y porque es
    /// contra esto contra lo que se compara lo releído en un cambio de red.
    private var announcedResolvers: [Shared.IPAddress]?

    /// Lo que el sistema contestó, sin filtrar, justo antes del anuncio que sigue en pie.
    private var reportedWhenAnnounced: [String]?

    /// La red por la que se anunció lo que hay puesto. Comparar contra ella es lo que separa "he
    /// cambiado de red" de "la Wi-Fi ha parpadeado".
    private var announcedForPath: NetworkPathSignature?

    private var resolverCounters = ResolverCounters()

    /// Lo que llevan los reanuncios de esta sesión. Van aparte de los de retención por lo de siempre:
    /// contestan otra pregunta, y esta es la que dice si el túnel sobrevive a salir de casa.
    private struct ResolverCounters {
        var networkChanges: UInt64 = 0
        var resolversRelearned: UInt64 = 0
        var failures: UInt64 = 0
        var lastError: String?
    }

    private var retentionCounters = RetentionCounters()

    /// Lo que la retención lleva hecho en esta sesión, para poder contarlo por el canal de control.
    /// La extensión no tiene a quién enseñárselo, y tragárselo dejaría un tope incumplido sin
    /// explicación posible.
    private struct RetentionCounters {
        var reclaimed: UInt64 = 0
        var failures: UInt64 = 0
        var lastError: String?
        var plaintextChunksExpired: UInt64 = 0
        var plaintextFilesReclaimed: UInt64 = 0
    }

    // MARK: - Arranque

    /// Crea los colaboradores reales, se los inyecta al pipeline y arranca el bucle de lectura y el
    /// timer. Si algo falla a mitad, deshace lo ya creado antes de propagar: una extensión que no
    /// arranca no puede dejarse un `mmap` o un fichero abiertos detrás.
    ///
    /// - Parameters:
    ///   - announced: los resolvers que el provider acaba de anunciar.
    ///   - reported: lo que el sistema contestó al leerlos, sin filtrar (`nil` = no se pudo preguntar).
    ///
    /// Los dos llegan desde fuera porque solo se pueden leer **antes** de aplicar los ajustes de red,
    /// que es antes de que este actor exista para nadie.
    func start(
        announced: [Shared.IPAddress],
        reported: [String]?,
        packetSource: @escaping PacketSource,
        reinject: @escaping PacketReinjector
    ) async throws {
        // Los ajustes del usuario se leen **una vez por sesión**, aquí: son la verdad duradera
        // (`SettingsStore`), sobreviven a que la extensión muera, y lo que cambia en caliente sobre una
        // sesión viva viaja por el canal de control, que es para lo que existe.
        let settings = Self.loadSettings()

        // La ruta la resuelve `CaptureDirectory` y no el provider: la app tiene que llegar al mismo
        // directorio para resolver la `CaptureLocation` de un paquete en un fichero concreto.
        guard let captures = CaptureDirectory.url(inAppGroup: AppGroup.identifier) else {
            throw TunnelError.appGroupUnavailable
        }
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)

        // El directorio del contenido descifrado **no se crea aquí**: lo crea su escritor con el
        // primer byte que haya que guardar. Un túnel que no descifra no deja ni una carpeta vacía
        // insinuando que sí (`docs/spec/plaintext.md`).
        guard let plaintextDirectory = PlaintextDirectory.url(inAppGroup: AppGroup.identifier) else {
            throw TunnelError.appGroupUnavailable
        }

        // Un ancla para toda la sesión, compartida con el pipeline: el contenido descifrado se fecha
        // **dos veces** —absoluto en su fichero, monotónico en la fila que lo indexa— y con dos anclas
        // distintas el mismo trozo diría dos instantes.
        let anchor = MonotonicAnchor.now()
        let store = try FlowStore(appGroupID: AppGroup.identifier, anchor: anchor)

        // Recrear el productor reinicia los índices del ring: al arrancar, lo que quedara de la
        // sesión anterior es basura que la app no debe drenar.
        let ring = try RingBufferProducer(appGroupID: AppGroup.identifier, slotCount: Self.ringSlotCount)

        let pcap: PcapWriter
        do {
            // El writer arranca por encima de lo que el historial ya referencia, no solo por encima
            // de lo que hay en disco: si se borró un fichero cuyos paquetes siguen guardados,
            // reutilizar su secuencia les daría los bytes de otra conexión.
            pcap = try PcapWriter(
                config: .init(
                    directory: captures,
                    // El `snaplen` va en la cabecera global del fichero, así que es del fichero y no del
                    // registro: cambiar el detalle de captura obliga a abrir uno nuevo, y por eso se
                    // fija al arrancar la sesión.
                    snaplen: settings.captureDetail.snaplen,
                    highestReferencedSequence: try await store.highestCaptureFileSequence()
                )
            )
        } catch {
            ring.close()
            throw error
        }

        // Arranca por encima de lo que el índice ya referencia, por lo mismo que el de capturas:
        // reutilizar una secuencia o una conversación le daría a una fila guardada el contenido de
        // otra. No abre nada al construirse, así que no entra en el deshacer-a-medias del arranque.
        let plaintext: PlaintextWriter
        do {
            plaintext = PlaintextWriter(
                config: .init(
                    directory: plaintextDirectory,
                    highestReferencedSequence: try await store.highestPlaintextFileSequence(),
                    highestReferencedStream: try await store.highestPlaintextStream()
                )
            )
        } catch {
            await pcap.close()
            ring.close()
            throw error
        }

        // Un único reloj compartido: la tabla de flujos, la captura y el pipeline sellan todos en ns
        // desde el mismo origen. Con dos relojes, los timeouts de inactividad y los timestamps del
        // `.pcap` medirían contra orígenes distintos.
        let flowTable = FlowTable(config: .init(), clock: clock)

        self.store = store
        self.ring = ring
        self.pcap = pcap
        self.plaintext = plaintext
        self.capturesDirectory = captures
        self.plaintextDirectory = plaintextDirectory
        self.lastSeenSequence = await pcap.currentFileSequence
        self.lastSeenPlaintextSequence = nil
        self.plaintextSweepPending = true
        self.announcedResolvers = announced
        self.reportedWhenAnnounced = reported
        self.announcedForPath = nil
        self.resolverCounters = ResolverCounters()
        self.retentionCounters = RetentionCounters()
        // La cola por la que las respuestas ya entregadas van al registro. Es **serial y con tope**:
        // serial porque dos respuestas registradas en orden invertido desordenarían la captura y el
        // feed, y con tope porque la memoria de la extensión no puede crecer detrás de un disco lento.
        let (records, recordSink) = AsyncStream<ReinjectedDatagram>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.reinjectedRecordCapacity)
        )
        self.reinjectedRecords = recordSink
        self.droppedRecords = DroppedRecordCounter()
        self.lastReinjectSignal = 0

        // El pipeline se construye antes que el relay porque el relay lo necesita: es quien recoge
        // los nombres de host que el relay lee del handshake (`SNIObserving`). Ninguno de los dos
        // abre nada al construirse, así que el orden entre ellos no cambia nada del deshacer-a-medias
        // del arranque: los dos van después de todo lo que puede fallar.
        let pipeline = PacketPipeline(
            flowTable: flowTable,
            liveFeed: ring,
            capture: pcap,
            plaintext: plaintext,
            store: store,
            clock: clock,
            config: .init(
                localIPv4: TunnelAddressing.localIPv4,
                localIPv6: TunnelAddressing.localIPv6,
                tlsInspectionEnabled: settings.tlsInspectionEnabled,
                captureEnabled: settings.captureEnabled,
                anchor: anchor
            )
        )
        self.pipeline = pipeline

        let dropped = self.droppedRecords
        self.relay = Relay(reinject: { datagrams, protocols in
            // Primero el dispositivo: registrar no puede retrasar una respuesta ni un microsegundo,
            // y si el registro fallara la conectividad no debe enterarse.
            reinject(datagrams, protocols)
            for (packet, family) in zip(datagrams, protocols.map(\.int32Value)) {
                // El `NSNumber` se colapsa aquí, igual que en el bucle de lectura, para que lo que
                // cruce a la tarea del registrador sea un valor `Sendable`.
                if case .dropped = recordSink.yield(ReinjectedDatagram(packet: packet, protocolFamily: family)) {
                    dropped.increment()
                }
            }
        }, sniObserver: pipeline,
           inspector: Self.makeInspector(),
           statusObserver: pipeline,
           // El pipeline recoge también el contenido descifrado, porque la fila que lo indexa cuelga
           // del id que devuelve su propio volcado. Que se guarde o no lo dice el interruptor propio
           // del ADR 0007, que aquí llega leído del almacén compartido como todos los demás.
           plaintextObserver: pipeline,
           plaintextPersistenceEnabled: settings.plaintextPersistenceEnabled)

        readTask = Task { [weak self] in
            await self?.readLoop(source: packetSource)
        }
        recordTask = Task { [weak self] in
            for await datagram in records {
                await self?.record(reinjected: datagram)
            }
        }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.tickInterval)
                } catch {
                    return   // cancelado: es la salida normal de este bucle
                }
                await self?.tick()
            }
        }
    }

    // MARK: - Cambios de red

    /// El dispositivo ha cambiado de red: vuelve a leer los resolvers y a anunciarlos.
    ///
    /// # Por qué hay que quitar los ajustes para leer
    ///
    /// **Medido en el iPhone el 2026-08-16, y no es una suposición**: con el túnel puesto,
    /// `res_getservers` devuelve la configuración del interfaz primario —que somos nosotros—, así que
    /// releer en caliente contesta lo que acabamos de anunciar. Lo que sí funciona es apagar y
    /// encender el monitoreo, y lo único que el arranque hace distinto es leer **antes** de aplicar
    /// los ajustes. Esto reproduce eso sin tirar la sesión: quitar, leer, volver a poner.
    ///
    /// # Las tres cosas que lo hacen seguro
    ///
    /// 1. **Se vuelve a aplicar siempre.** Entre las dos llamadas el túnel no tiene ajustes, así que
    ///    ninguna rama puede terminar sin poner unos: si la relectura no da nada utilizable, se
    ///    reanuncia lo de antes (`ResolverRefresh`).
    /// 2. **Si la segunda aplicación falla, se reintenta con lo de antes.** Un túnel sin ajustes no
    ///    deja al dispositivo sin internet —el tráfico vuelve a salir por su interfaz de siempre—,
    ///    pero deja de capturar, y eso es una avería silenciosa: si el reintento también falla, se
    ///    cuenta y se guarda el texto del sistema, que es lo que se lee en *Session diagnostics*.
    /// 3. **Serial por construcción.** Las notificaciones entran por una cola serial y este actor las
    ///    atiende de una en una: dos reanuncios solapados podrían dejar el túnel con los ajustes del
    ///    primero quitados y los del segundo a medio poner.
    func networkPathChanged(to signature: NetworkPathSignature, settings: NetworkSettingsControl) async {
        // Sin sesión no hay nada que reanunciar: es la carrera normal con `stop`, no un caso raro.
        guard pipeline != nil, let announced = announcedResolvers else { return }

        guard NetworkPathSignature.warrantsReannouncement(from: announcedForPath, to: signature) else {
            // La primera red que se ve es sobre la que ya se anunció al arrancar, así que solo se
            // apunta; y una firma repetida es la misma red volviendo, cuyos resolvers no han cambiado.
            if signature.isSatisfied { announcedForPath = signature }
            return
        }

        resolverCounters.networkChanges &+= 1
        settings.setReasserting(true)
        defer { settings.setReasserting(false) }

        do {
            try await settings.apply(nil)
        } catch {
            // No se pudieron quitar: los de antes siguen puestos, así que el túnel sigue capturando
            // con el DNS de la red anterior. Es el fallo menos malo de los tres posibles.
            recordReannounceFailure(error)
            return
        }

        let reported = SystemResolvers.reported()
        let decision = ResolverRefresh.decide(reported: reported, currentlyAnnounced: announced)

        do {
            try await settings.apply(decision.announce)
        } catch {
            recordReannounceFailure(error)
            // Reintento con lo que había: la lista nueva puede ser la que el sistema rechaza, y
            // quedarse sin ajustes es peor que quedarse con los de la red anterior.
            do {
                try await settings.apply(announced)
            } catch {
                recordReannounceFailure(error)
            }
            return
        }

        announcedResolvers = decision.announce
        reportedWhenAnnounced = reported ?? reportedWhenAnnounced
        announcedForPath = signature
        if decision.learnedSomethingNew {
            resolverCounters.resolversRelearned &+= 1
        }
    }

    private func recordReannounceFailure(_ error: Error) {
        resolverCounters.failures &+= 1
        // El texto del sistema, no el nombre del caso: es lo que alguien puede citar al pedir ayuda.
        resolverCounters.lastError = (error as NSError).localizedDescription
    }

    // MARK: - Bucle de lectura

    /// El hot path visto desde el dispositivo: pedir lote, pasar cada datagrama al pipeline,
    /// reenviar a internet lo que el pipeline no descarte y avisar a la app una sola vez por lote.
    private func readLoop(source: @escaping PacketSource) async {
        while !Task.isCancelled {
            guard let batch = await source() else { return }
            guard let pipeline, let relay else { return }   // `stop()` ganó la carrera

            var published = false
            for (packet, family) in batch {
                // El pipeline ya publicó el metadato en el ring; lo que sigue es lo que le da
                // conectividad al dispositivo. El contrato de sentido del relay se cumple por
                // construcción: todo lo que llega aquí lo produjo `readPackets`, así que es saliente.
                switch await pipeline.handle(packet: packet, protocolFamily: family) {
                case .dropped:
                    // Ya contado en `PipelineStats.packetsDropped`: el datagrama muere aquí.
                    continue
                case .passthrough(let parsed):
                    await relay.passthrough(parsed, raw: packet)
                case .inspect(let parsed):
                    // La única diferencia es que un flujo nuevo se abre como candidato a terminación
                    // TLS; el reenvío es el mismo. Quién puede serlo lo decidió `route`.
                    await relay.inspect(parsed, raw: packet)
                }
                published = true
            }

            // La señal Darwin es un wakeup sin payload y se coalesce: una por lote, nunca por
            // paquete. Postearla por paquete despertaría a la app miles de veces por segundo para
            // decirle lo mismo.
            if published {
                Self.postLiveDataSignal()
            }
        }
    }

    // MARK: - Registro de lo reinyectado

    /// Registra una respuesta que el relay ya entregó al dispositivo.
    ///
    /// Va por una tarea aparte y no dentro del closure de reinyección porque el pipeline es un actor
    /// y escribir la captura toca disco: hacerlo en línea metería al relay a esperar por el disco
    /// entre una respuesta del servidor y la siguiente. Lo que se conserva es el **orden**, que es lo
    /// que un `Task` por respuesta habría perdido.
    private func record(reinjected datagram: ReinjectedDatagram) async {
        guard let pipeline else { return }
        await pipeline.record(reinjected: datagram.packet, protocolFamily: datagram.protocolFamily)
        signalLiveDataIfDue()
    }

    /// Despierta a la app, como mucho una vez cada `reinjectSignalInterval`.
    ///
    /// El bucle de lectura puede permitirse una señal por lote porque el lote lo forma el sistema;
    /// aquí no hay lotes —cada respuesta llega cuando llega— así que la ráfaga la acota el reloj. Una
    /// señal que se salta no pierde nada: el lector del feed drena por su cuenta cada segundo.
    private func signalLiveDataIfDue() {
        let now = clock.now()
        guard now &- lastReinjectSignal >= Self.reinjectSignalInterval else { return }
        lastReinjectSignal = now
        Self.postLiveDataSignal()
    }

    private func tick() async {
        await pipeline?.tick()
        await closeRelayedFlows()
        await sweepRetentionIfRotated()
        await sweepPlaintextIfNeeded()
    }

    /// Cierra en el relay los flujos que la tabla ha dado por terminados (FIN/RST, evicción LRU o
    /// inactividad). Sin esto las `NWConnection` se acumularían: una conexión UDP no tiene cierre
    /// propio —nadie manda un FIN en UDP— y la de un flujo TCP evictado tampoco se enteraría.
    ///
    /// Va después de `pipeline.tick()` porque es ese tick el que expira los inactivos, así que en la
    /// misma pasada se cierra lo que acaba de cerrarse. Los flujos TCP que terminan por su cuenta ya
    /// se habrán soltado dentro del relay (`teardown` de la máquina de estados); volver a cerrarlos
    /// aquí es un no-op, que es justo lo que `Relay.close` promete.
    private func closeRelayedFlows() async {
        guard let pipeline, let relay else { return }
        for key in await pipeline.drainClosedFlowKeys() {
            await relay.close(key)
        }
    }

    /// Aplica los topes de retención si la captura ha rotado desde el último vistazo.
    ///
    /// Es lo que hace que un tope siga valiendo **con la app cerrada**. Hasta aquí solo lo aplicaba la
    /// pantalla de Ajustes, al aparecer y al cambiarlo, así que un túnel capturando toda la noche podía
    /// pasarse del tope hasta la siguiente visita del usuario — y justo mientras nadie mira es cuando el
    /// directorio crece. La regla no se reimplementa: decide `RetentionPlanner` y ejecuta
    /// `CaptureRetention`, los mismos que usa la app, para que un tope no signifique una cosa delante del
    /// usuario y otra a sus espaldas.
    ///
    /// Se engancha a la **rotación** y no al tick porque es el único instante en que hay algo nuevo que
    /// recortar: el fichero anterior acaba de cerrarse entero. El writer rota solo, por tamaño, desde
    /// dentro de `write`, así que nadie fuera del hot path se entera si no pregunta — y preguntar es un
    /// salto de actor cada cinco segundos, no trabajo por paquete.
    private func sweepRetentionIfRotated() async {
        guard let pcap, let directory = capturesDirectory, let store else { return }
        let current = await pcap.currentFileSequence
        defer { lastSeenSequence = current }
        guard lastSeenSequence != current else { return }

        // Los ajustes se releen aquí en vez de reutilizar los del arranque: el usuario puede haber
        // cambiado un tope con el túnel corriendo, y una sesión larga acabaría aplicando una política que
        // ya no es la suya. Cuesta una lectura por rotación, fuera del camino de un paquete.
        let settings = Self.loadSettings().retention
        guard !settings.isUnlimited else { return }

        let files = CaptureDirectory.fileInfos(in: directory)
        let plan = RetentionPlanner.plan(
            files: files,
            settings: settings,
            now: Date(),
            recordingSequence: current
        )
        guard plan.hasWork else { return }

        let outcome = await CaptureRetention.execute(plan, files: files, openingHistory: { store })
        retentionCounters.reclaimed += UInt64(outcome.deletedFiles.count)
        if let lastFailure = outcome.failures.last {
            retentionCounters.failures += UInt64(outcome.failures.count)
            retentionCounters.lastError = lastFailure
        }
    }

    /// Aplica la retención del **contenido descifrado** (ADR 0007).
    ///
    /// Va aparte del barrido de las capturas y no dentro, y no por simetría: **el de arriba se salta
    /// con `isUnlimited` y este no puede saltarse nunca**. Los topes de captura son del usuario y
    /// puede quitarlos; la caducidad de lo descifrado no existe como "sin límite" a propósito, así
    /// que meter esto detrás de aquel guard habría dejado sin barrer justo lo que el ADR promete
    /// barrer siempre, y encima solo en los dispositivos cuyo dueño quitó sus topes de captura.
    ///
    /// Se dispara al arrancar la sesión —lo escrito ayer caduca aunque hoy no se descifre nada— y en
    /// cada cambio del fichero abierto, incluido el paso a "ninguno", que es cuando acaba de cerrarse
    /// uno entero. El fichero protegido se **deduce** del listado y no se pregunta al escritor
    /// (`PlaintextRetentionPlanner.openSequence`): justo después de rotar el escritor no tiene
    /// ninguno abierto y el recién cerrado es el que más probabilidades tiene de llevar trozos que el
    /// pipeline todavía no ha indexado.
    private func sweepPlaintextIfNeeded() async {
        guard let plaintext, let directory = plaintextDirectory, let store else { return }
        let current = await plaintext.currentFileSequence
        let rotated = lastSeenPlaintextSequence != current
        defer { lastSeenPlaintextSequence = current }
        guard plaintextSweepPending || rotated else { return }
        plaintextSweepPending = false

        // Releídos en cada barrido, como los de la captura: el usuario puede haber acortado la
        // caducidad con el túnel corriendo, y una sesión larga seguiría aplicando la de antes.
        let settings = Self.loadSettings().retention
        let files = PlaintextDirectory.fileInfos(in: directory)
        let outcome = await PlaintextRetention.sweep(
            settings,
            directory: directory,
            openSequence: PlaintextRetentionPlanner.openSequence(files: files, isMonitoring: true),
            openingHistory: { store }
        )
        retentionCounters.plaintextChunksExpired += UInt64(outcome.prunedChunks)
        retentionCounters.plaintextFilesReclaimed += UInt64(outcome.deletedFiles.count)
        if let lastFailure = outcome.failures.last {
            retentionCounters.failures += UInt64(outcome.failures.count)
            retentionCounters.lastError = lastFailure
        }
    }

    /// El interceptor TLS de producción: la política (`TLSInterceptionPolicy`, donde vive el ADR
    /// 0003) sobre el motor real, que emite el leaf del host con la CA del usuario y abre la pata
    /// saliente al servidor de verdad bajo confianza del sistema.
    ///
    /// Se construye siempre, también sin CA: quien decide si se inspecciona algo son las
    /// precondiciones —el pipeline enruta a `.inspect` solo con la inspección encendida, y el gate
    /// del interceptor exige CA— y las dos se leen **en cada intento**, así que una CA que aparece a
    /// mitad de sesión empieza a valer sin reiniciar el túnel.
    private static func makeInspector() -> TLSInterceptor {
        TLSInterceptor(engine: NetworkTLSTerminationEngine(ca: LazyLocalCA()), caReady: { Self.hasLocalCA() })
    }

    /// Si la CA local existe en el llavero **compartido** (el mismo item que escribe la app: no hay
    /// copia por medio). Es lo único que la extensión puede contestar por su cuenta — que el usuario
    /// la haya instalado *y confiado* en Ajustes de iOS solo lo sabe la app, y lo aporta el
    /// interruptor de inspección, que ella misma gobierna con esa comprobación.
    private static func hasLocalCA() -> Bool {
        ((try? LocalCA.load()) ?? nil) != nil
    }

    /// Los ajustes con los que arranca la sesión.
    ///
    /// Un blob ilegible cae a los de fábrica y **no** impide arrancar: negarle el túnel al usuario por
    /// unas preferencias corruptas sería un castigo desproporcionado, y arrancar con los de fábrica es
    /// exactamente lo que la app hacía antes de que estos ajustes existieran. Que no se traga en
    /// silencio lo garantiza el otro lado: la app lee el **mismo** almacén, `SettingsStore.load()` le
    /// lanza el mismo `corruptData`, y es en la pantalla de Ajustes —donde hay a quién contárselo y
    /// desde donde la siguiente escritura lo repara— donde eso se ve.
    private static func loadSettings() -> AppSettings {
        do {
            return try SettingsStore().load()
        } catch {
            return .default
        }
    }

    private static func postLiveDataSignal() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(DarwinSignal.liveDataAvailable as CFString),
            nil,
            nil,
            true
        )
    }

    // MARK: - Canal de control

    func handle(messageData: Data) async -> ControlResponse {
        let command: ControlCommand
        do {
            command = try ControlCommand(decoding: messageData)
        } catch {
            return .failed("mensaje de control ilegible")
        }

        guard let pipeline else { return .notRunning }

        switch command {
        case .setTLSInspectionEnabled(let enabled):
            await pipeline.setTLSInspectionEnabled(enabled)
            return .ok
        case .setCaptureEnabled(let enabled):
            await pipeline.setCaptureEnabled(enabled)
            return .ok
        case .setPlaintextPersistenceEnabled(let enabled):
            // Va al relay y no al pipeline porque el sumidero se lo da él a cada terminación: el
            // pipeline sabe guardar lo que le llegue, pero quien decide si llega algo es el relay.
            guard let relay else { return .notRunning }
            await relay.setPlaintextPersistenceEnabled(enabled)
            return .ok
        case .setCaptureDetail(let detail):
            guard let pcap else { return .notRunning }
            do {
                // Rota por dentro: el `snaplen` es del fichero, no del registro. Es la única forma de
                // aplicarlo sin dejar el `.pcap` abierto ilegible.
                try await pcap.setSnaplen(detail.snaplen)
                return .ok
            } catch {
                return .failed(String(describing: error))
            }
        case .rotateCapture:
            guard let pcap else { return .notRunning }
            do {
                try await pcap.rotate()
                return .ok
            } catch {
                return .failed(String(describing: error))
            }
        case .stats:
            var pipelineStats = await pipeline.stats
            // Los lleva este actor y no el pipeline porque barrer el directorio no es parte del camino
            // de un paquete. Viajan en la misma respuesta porque para la app son lo mismo —salud de la
            // sesión— y un segundo comando solo añadiría un round-trip para tres enteros.
            pipelineStats.capturesReclaimed = retentionCounters.reclaimed
            pipelineStats.retentionFailures = retentionCounters.failures
            pipelineStats.lastRetentionError = retentionCounters.lastError
            pipelineStats.plaintextChunksExpired = retentionCounters.plaintextChunksExpired
            pipelineStats.plaintextFilesReclaimed = retentionCounters.plaintextFilesReclaimed
            pipelineStats.reinjectedRecordsDropped = droppedRecords.count
            // El DNS se compone aquí: lo anunciado y sus contadores, más una relectura hecha en este
            // momento. Esa relectura ya no decide nada —está medido que con el túnel puesto repite lo
            // que anunciamos—, pero se enseña porque es la evidencia de esa afirmación, y el día que
            // deje de repetirlo será lo primero que lo diga (`Shared/IPC/ResolverStatus.swift`).
            let resolverStatus = announcedResolvers.map { announced in
                ResolverStatus(
                    announced: announced.map(\.description),
                    reportedWhenAnnounced: reportedWhenAnnounced,
                    reportedNow: SystemResolvers.reported(),
                    networkChanges: resolverCounters.networkChanges,
                    resolversRelearned: resolverCounters.resolversRelearned,
                    reannounceFailures: resolverCounters.failures,
                    lastReannounceError: resolverCounters.lastError
                )
            }
            // El relay va en su propio campo y **no se sustituye por ceros si no está**: `stop` lo
            // cierra antes que el pipeline, así que una consulta que caiga en esa ventana tiene que
            // poder decir "no hay contadores" en vez de "no se inspeccionó nada".
            return .stats(
                TunnelStats(
                    pipeline: pipelineStats,
                    relay: await relay?.stats,
                    resolvers: resolverStatus
                )
            )
        }
    }

    // MARK: - Parada

    /// Cierre explícito y ordenado. Primero se paran los productores de trabajo, luego el pipeline
    /// vuelca lo pendiente, y solo entonces se cierra lo que este actor creó: el pipeline nunca
    /// cierra lo que no es suyo.
    func stop() async {
        readTask?.cancel()
        tickTask?.cancel()
        readTask = nil
        tickTask = nil

        // El relay se cierra el primero: mientras siga habiendo conexiones vivas siguen llegando
        // respuestas del servidor, y reinyectar hacia un `packetFlow` de un túnel que se está
        // parando no lleva a ninguna parte. Cerrarlas también libera sus `NWConnection` de una vez,
        // sin esperar a un tick que ya no va a llegar.
        await relay?.closeAll()
        relay = nil

        // Cerrado el relay ya no entra nada más en la cola, así que se cierra y se **espera** a que
        // el registrador termine de vaciarla: son un puñado de respuestas ya entregadas al
        // dispositivo, y llegan al historial antes del volcado final en vez de perderse en la puerta.
        // No hay bloqueo posible: la cola es finita y `stop` está suspendido, así que el actor queda
        // libre para atender al propio registrador.
        reinjectedRecords?.finish()
        reinjectedRecords = nil
        await recordTask?.value
        recordTask = nil

        // No se espera a `readTask`: puede estar suspendida dentro de `readPackets`, que no responde
        // a la cancelación. Terminará sola en cuanto el sistema le entregue el siguiente lote y vea
        // el flag; mientras tanto, todo lo que pueda tocar ya está cerrado y lo absorbe sin romper
        // (el ring cerrado ignora los `push`, y la captura cerrada devuelve un error contable, y el
        // relay ya no está, así que el bucle sale por su `guard`).
        await pipeline?.shutdown()
        pipeline = nil

        await pcap?.close()
        pcap = nil
        capturesDirectory = nil
        lastSeenSequence = nil

        // Después del volcado del pipeline, que es quien le escribe: cerrarlo antes dejaría el último
        // trozo descifrado indexado en la BD y ausente del fichero.
        await plaintext?.close()
        plaintext = nil
        plaintextDirectory = nil
        lastSeenPlaintextSequence = nil

        ring?.close()
        ring = nil

        // Era de aquella sesión, como los contadores: el próximo túnel leerá los resolvers de la red
        // que haya entonces.
        announcedResolvers = nil
        reportedWhenAnnounced = nil
        announcedForPath = nil

        // `FlowStore` no expone `close`: GRDB cierra la conexión al liberarse la última referencia.
        store = nil
    }
}
