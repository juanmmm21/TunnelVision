# Spec — Packet tunnel provider (`PacketTunnel`)

The extension's entry point and the only device-only orchestration in the app. It wires the
pure components (parser, flow table, reassembler, relay, pcap, store, ring buffer) into the
`packetFlow` read/write loop. Keep it thin: no parsing or reassembly logic lives here, only
lifecycle and dispatch.

## Lifecycle

```swift
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    // Forma con completion handler, no `async`: `options` es `[String: NSObject]?`, un tipo no
    // Sendable que Swift 6 no deja cruzar hacia un override asíncrono. No se lee: la config viva
    // llega por el canal de control.
    override func startTunnel(options: [String: NSObject]?,
                             completionHandler: @escaping (Error?) -> Void)
    override func stopTunnel(with reason: NEProviderStopReason) async
    override func handleAppMessage(_ messageData: Data) async -> Data?    // control from the app
}
```

`@unchecked Sendable` es honesto: la clase no tiene estado mutable propio. Todo lo mutable (el
pipeline, los recursos que crea y las dos tareas de fondo) vive en `TunnelRuntime`, un `actor`, así
que lo único que cruza entre tareas es una referencia inmutable.

El direccionamiento vive en `TunnelAddressing` (en `Shared/Models`, porque la app también lo
necesita: ver [`app-services.md`](app-services.md)), aparte y **testeado**: es el punto donde la misma
dirección existe en dos representaciones —bytes para `PacketPipeline.Config`, texto para
`NEIPv4Settings`/`NEIPv6Settings`—. La fuente de verdad son los bytes y el texto se deriva con
`IPAddress.description`; con dos literales, una divergencia haría que el túnel anunciase una IP y el
pipeline comparase contra otra, invirtiendo el sentido de **todo** el tráfico del historial.

### `startTunnel`

1. Build `NEPacketTunnelNetworkSettings` and apply it, then start reading:

```swift
let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
settings.ipv4Settings = {
    let s = NEIPv4Settings(addresses: ["10.7.0.2"], subnetMasks: ["255.255.255.0"])
    s.includedRoutes = [NEIPv4Route.default()]     // capturar todo el tráfico IPv4
    return s
}()
settings.ipv6Settings = {
    let s = NEIPv6Settings(addresses: ["fd00:7::2"], networkPrefixLengths: [64])
    s.includedRoutes = [NEIPv6Route.default()]
    return s
}()
settings.mtu = 1500
setTunnelNetworkSettings(settings) { error in /* then start read loop */ }
```

### `dnsSettings`: el túnel reanuncia los resolvers del sistema

```swift
// Antes de setTunnelNetworkSettings: después, la respuesta ya sería la nuestra.
let reported = SystemResolvers.reported()                       // [String]?  (nil = no se pudo leer)
let announceable = TunnelResolvers.announceable(from: reported ?? [])
let status = ResolverStatus(announced: announceable.map(\.description), reportedAtStart: reported)
if !announceable.isEmpty {
    let dns = NEDNSSettings(servers: announceable.map(\.description))
    dns.matchDomains = [""]                        // "" es sufijo de todo: casan todas las consultas
    settings.dnsSettings = dns
}
```

`SystemResolvers.reported()` devuelve lo que el sistema contesta **sin filtrar**, y el filtro lo
aplica quien anuncia. La separación no es de estilo: es lo único que permite distinguir *el sistema no
tenía resolvers* de *los tenía y ninguno se podía anunciar*, y esas dos cosas llevan a sitios
distintos (la segunda es lo que justifica dejar que el usuario fije uno).

**Esto cambió el 2026-08-15 y la razón importa.** Hasta entonces `dnsSettings` se dejaba sin fijar,
razonando que el sistema conservaría sus resolvers y que sus consultas entrarían por el túnel
igualmente, capturadas por las rutas por defecto. **Un `.pcap` exportado del dispositivo lo
desmintió**: en 34 segundos de sesión no llegó **ni una** consulta de DNS. Un interfaz que se lleva la
ruta por defecto de las dos familias es el interfaz primario, y uno primario sin resolución de nombres
deja al sistema sin red — la sonda de conectividad falla, iOS da la Wi-Fi por caída y el navegador no
intenta ni una IP literal. Lo único que sobrevivía eran conexiones ya establecidas con IPs fijas.

Lo que **no** cambió: no se fija un resolver público. Redirigiría el DNS del usuario a un tercero que
no ha elegido, justo lo contrario del propósito de la app. Se anuncian **los suyos**, así que sus
consultas siguen yendo adonde ya iban y lo único nuevo es que pasan por el túnel — que es, de paso,
lo que abriría poder nombrar los flujos por DNS.

Tres cosas que hacen que esto funcione y que no son evidentes:

- **Se leen antes de aplicar los ajustes.** Después, `res_getservers` devuelve la configuración del
  propio túnel, así que nos estaríamos anunciando lo que acabamos de anunciar.
- **Un resolver de la LAN sigue siendo alcanzable.** La consulta entra por el túnel y el relay abre su
  conexión saliente por el interfaz real, que es la misma mecánica de todo lo demás.
- **No todos se pueden anunciar.** Los filtra `TunnelResolvers` (`Shared/Models`), que es donde vive
  la decisión y sus motivos: fuera el loopback (mandaría las consultas a la propia máquina en vez de
  al túnel), fuera el link-local IPv6 (sin zona no significa nada y `NEDNSSettings.servers` no la
  admite), fuera la dirección sin especificar y los duplicados. Dentro, las privadas y las link-local
  IPv4, que son alcanzables sin zona.

**El caso abierto: que no quede ninguno.** Es alcanzable de verdad — una red que solo anuncie un
resolver IPv6 link-local dejaría la lista vacía — y entonces el túnel vuelve al comportamiento de
antes, o sea a dejar el dispositivo sin nombres. Lo cierra el ajuste del usuario (elegir entre los del
sistema, uno público o uno propio), que es la otra mitad de la decisión de 2026-08-15.

### `ResolverStatus`: lo que se anunció deja de ser un secreto

Lo anterior tenía un agujero que no era de comportamiento sino de **observabilidad**: pasara lo que
pasara —que no se pudiera preguntar, que la red no tuviera resolvers, que ninguno fuese anunciable—,
el túnel se declaraba primario y **nadie lo contaba**. Ese silencio es exactamente lo que hizo falta
tres sesiones para deshacer.

`ResolverStatus` (`Shared/IPC`, porque cruza el canal) lleva las tres listas: `announced` —lo que se
le pasó a `NEDNSSettings.servers`, y **vacío significa que el dispositivo no puede resolver
nombres**—, `reportedAtStart` —lo que el sistema contestó, sin filtrar, con `nil` para "no se pudo
preguntar"— y `reportedNow`.

**`reportedNow` era una medición, y está contestada — no la reabras.** Medido en el iPhone el
2026-08-16: **con el túnel puesto, esa lectura repite lo anunciado**. `res_getservers` contesta por el
interfaz primario, que somos nosotros. Lo que **sí** trae los resolvers de la red nueva es apagar y
encender el monitoreo, y lo único que el arranque hace distinto es leer **antes** de aplicar los
ajustes. El campo se conserva como evidencia de esa afirmación —el día que deje de repetir lo
anunciado será lo primero en decirlo—, pero **ya no sostiene ningún veredicto**.

### Reanunciar al cambiar de red

De aquella medición sale la forma del arreglo, que es reproducir por dentro lo que hace apagar y
encender — **construido y confirmado en el iPhone el 2026-08-16**: con el túnel encendido, cambiar de
red ya no deja al dispositivo sin resolución de nombres.

```swift
// NWPathMonitor → TunnelRuntime.networkPathChanged(to:settings:)
guard NetworkPathSignature.warrantsReannouncement(from: announcedForPath, to: signature) else { return }
try await settings.apply(nil)                                  // dejar de ser el interfaz primario
let reported = SystemResolvers.reported()                      // leer ya sin serlo
let decision = ResolverRefresh.decide(reported: reported, currentlyAnnounced: announced)
try await settings.apply(decision.announce)                    // volver a poner: SIEMPRE
```

Las dos decisiones son puras y viven en `Shared/Models`, que es donde se pueden probar:

- **`NetworkPathSignature`** dice *cuándo* merece reaccionar: solo caminos satisfechos, nunca el
  primero que se ve (es la red sobre la que `startTunnel` ya anunció) y solo si cambian los interfaces
  **físicos** o los routers. El `utun` propio queda fuera de la firma, porque si entrase, cada
  reanuncio provocaría el siguiente. Su punto ciego está asumido y escrito: dos redes con el mismo
  interfaz y el mismo router son indistinguibles desde aquí; ese caso lo recoge el par
  `dnsQueriesSent`/`dnsRepliesReceived` del relay, que mide el síntoma en vez de la causa.
- **`ResolverRefresh`** dice *qué* anunciar después, y su regla nace de que en ese instante **el túnel
  no tiene ajustes aplicados**: si la relectura no da nada utilizable se reanuncia lo de antes, porque
  ninguna rama puede dejar al dispositivo sin resolución de nombres.

Tres propiedades del orquestador que no son opcionales: **se vuelve a aplicar siempre** (entre las dos
llamadas no hay ajustes), **un fallo al aplicar reintenta con lo anterior** y, si tampoco, se cuenta
con el texto del sistema —un túnel sin ajustes no deja al dispositivo sin internet, pero deja de
capturar, y eso es una avería silenciosa que solo se ve en *Session diagnostics*—, y las
notificaciones llegan por una **cola serial**, porque dos reanuncios solapados son la forma de acabar
sin ninguno. `reasserting` cubre la operación entera, no cada aplicación.

Lo único prohibido sigue igual: **la relectura de `.stats` no vuelve a `makeNetworkSettings`**. La que
alimenta un anuncio es siempre la que se hace sin ser primario.

2. Open the App Group `FlowStore`, map the ring buffer producer, create the `PcapWriter` and the
   `PlaintextWriter`, build the `FlowTable`, and read the current inspection config
   (`handleAppMessage` can update it live). One `MonotonicAnchor` is taken here and given to **both**
   the store and the pipeline: decrypted content is dated twice — absolute in its file, monotonic in
   the row that indexes it — and two anchors would have the same chunk claim two instants. The
   pipeline uses that same anchor for the `.pcap`, whose record headers are wall clock too
   ([`pcap.md`](pcap.md)). The
   plaintext directory is **not** created here: its writer creates it with the first byte worth
   keeping, so a tunnel that never decrypts leaves not even an empty folder implying it did.
3. Create the `Relay` with `packetFlow.writePackets(_:withProtocols:)` as its `reinject` closure.
   Va **el último** de los colaboradores: no abre nada al construirse (sus conexiones nacen con el
   primer paquete de cada flujo), así que no entra en el deshacer-a-medias del arranque, y el bucle
   de lectura nunca llega a ver un pipeline sin relay.
4. Start the async read loop.

### Read/write loop

`readPackets` entrega los datagramas en lotes y hay que re-armarlo tras cada entrega. Se envuelve en
`async` (una `withCheckedContinuation`) y el bucle se escribe como un `while`, de modo que es
**secuencial por construcción**:

```swift
private func readLoop(source: @escaping PacketSource) async {
    while !Task.isCancelled {
        guard let batch = await source() else { return }
        guard let pipeline, let relay else { return }   // stop() ganó la carrera
        for (packet, family) in batch {
            let disposition = await pipeline.handle(packet: packet, protocolFamily: family)
            guard let toRelay = disposition.packetToRelay else { continue }  // .dropped: ya contado
            await relay.passthrough(toRelay, raw: packet)
            published = true
        }
        if published { postLiveDataSignal() }       // una señal Darwin por lote, nunca por paquete
    }
}
```

El **contrato de sentido** del relay ([`relay-and-tls.md`](relay-and-tls.md)) se cumple aquí por
construcción: el relay asume que todo lo que le entra es saliente y no conoce la IP del túnel, y lo
único que llega a este bucle es lo que produce `readPackets`. `.inspect` sale por la misma puerta que
`.passthrough` mientras no exista el motor de terminación TLS de producción: sin relay para el 443,
encender la inspección dejaría sin conectividad justo al tráfico que más importa.

Con un `Task` por lote **no** sería secuencial: dos lotes podrían entrar al pipeline en orden
invertido y corromper el reensamblado y los sellos de tiempo. La fuente de paquetes se inyecta como
closure (`PacketSource`) para que `TunnelRuntime` no dependa de la superclase de NetworkExtension.

`handle(packet:)` per the hot path in [`00-overview.md`](00-overview.md):

1. `PacketParser.parse` → `ParsedPacket` (count + drop on `PacketParseError`).
2. `flowTable.observe(...)` → `LiveFlow` (updates byte/packet counters).
3. **Route:**
   - UDP / non-443 TCP / `notInspectable` / inspection off ⇒ **passthrough** via the relay
     (see [`relay-and-tls.md`](relay-and-tls.md)); reinjection of responses is done by writing
     packets back with `packetFlow.writePackets(_:withProtocols:)`.
   - Port-443 TCP with inspection on and not-yet-pinned ⇒ hand to the userspace TCP + TLS path.
4. Push `PacketMeta` to the ring buffer (live) and enqueue for a batched `FlowStore` write.
5. Stream bytes to `PcapWriter`, record the returned `CaptureLocation` back into `PacketMeta`.

### Reinjection

Response traffic that the relay receives from the real server is turned back into IP packets
and delivered to the system via `packetFlow.writePackets(_:withProtocols:)`, so from the OS's
point of view the reply arrived on the tunnel interface.

La escritura se le **inyecta** al runtime como closure (`PacketReinjector`), igual que la fuente de
paquetes: así ni `TunnelRuntime` ni el relay dependen de NetworkExtension. De `packetFlow` se lee
solo desde el bucle de lectura y se escribe solo desde el actor del relay — los dos sentidos
independientes del interfaz virtual, ninguno concurrente consigo mismo.

**Lo reinyectado también se registra.** El bucle de lectura solo ve lo que el dispositivo envía, así
que sin esto la mitad de cada conversación es invisible: `bytesIn` a cero, la Dashboard sin tasa de
bajada y un `.pcap` con las preguntas y sin las respuestas. El closure de reinyección hace dos cosas
en este orden: entrega al dispositivo y **encola** el datagrama para registrarlo con
`PacketPipeline.record(reinjected:protocolFamily:)`.

La cola es **serial y con tope**. Serial porque dos respuestas registradas en orden invertido
desordenarían la captura y el feed, y un `Task` por respuesta no conserva el orden. Con tope
(`AsyncStream` + `.bufferingNewest`) porque la memoria de la extensión no puede crecer detrás de una
escritura de disco lenta: llena, se descarta el registro **más antiguo** y se cuenta en
`PipelineStats.reinjectedRecordsDropped` — lo que se pierde es la fila del historial, nunca la
respuesta, que ya salió. Y va en una tarea aparte, no dentro del closure, para no meter al relay a
esperar por el disco entre dos respuestas del servidor.

El sentido **no se le pasa** al pipeline: se deduce comparando el origen con la IP del túnel, igual
que el de cualquier otro paquete, así que un datagrama reinyectado se clasifica `inbound` por lo que
es. Su `FlowKey` es canónica, de modo que ida y vuelta suman en el mismo `FlowRecord`. Efecto
secundario que esto desbloquea: la tabla de flujos por fin ve el FIN de vuelta, así que un cierre TCP
limpio cierra el flujo en vez de dejarlo esperando a la inactividad.

La señal Darwin de estas respuestas va **acotada por reloj** (una cada 100 ms como mucho) y no por
lote: aquí no hay lotes, cada respuesta llega cuando llega. Saltarse una no esconde nada — el lector
del feed drena por su cuenta cada segundo (`LiveFeedPolicy.idlePollInterval`).

### Cierre de flujos

Un flujo que termina —FIN/RST, evicción LRU o inactividad— deja viva la `NWConnection` que el relay
mantiene por él, y en UDP eso no se arregla solo: nadie manda un FIN en UDP. El pipeline es el único
que sabe que un flujo terminó (la tabla de flujos vive dentro), pero no cierra nada: acumula las
claves y el provider las drena en cada `tick` con `drainClosedFlowKeys()` y llama a `Relay.close(_:)`.
Cerrar hasta un tick tarde no cuesta nada (es liberar memoria, no una decisión de conectividad) y a
cambio el hot path no gana un salto de actor por paquete.

### `stopTunnel`

Close every relay flow (`closeAll()`) **first** — mientras haya conexiones vivas siguen llegando
respuestas, y reinyectarlas hacia un túnel que se para no lleva a ninguna parte —, then flush the
pcap writer, flush pending `FlowStore` writes, close the plaintext writer (**after** the pipeline's
final flush, which is what writes to it: closing it earlier would leave the last chunk indexed in the
database and absent from the file), unmap the ring buffer, close the DB, and call the completion
handler. `closeAll()` also drains the relay's plaintext queue before letting go: those are bytes the
user already decrypted, one hop away from their file. Explicit teardown — no reliance on process death to release resources.

### `handleAppMessage` (control channel)

The app sends small control messages (start/stop inspection, toggle capture, rotate pcap, request
stats). Payload is a small `Codable` command enum encoded to `Data`. This is separate from the
high-rate live feed (which is the ring buffer) — do not use `handleAppMessage` for per-packet data.

El codec vive en `Shared/IPC/ControlChannel.swift`, fuera del provider y **testeado**: app y extensión
se compilan por separado y solo se encuentran en ejecución, así que lo que hay que verificar es que
hablan el mismo idioma. Está en `Shared` —y no en la extensión, donde nació en M7— porque el emisor
es la app: un app-extension no se puede enlazar desde el target de la app, así que el único sitio
donde ambos pueden ver el mismo tipo es el framework compartido. `PipelineStats` viajó con él por lo
mismo. El lado app del canal es `TunnelController.send(_:)` (ver
[`app-services.md`](app-services.md)).

```swift
public enum ControlCommand: Codable, Sendable, Equatable {
    case setTLSInspectionEnabled(Bool)   // ⇒ PacketPipeline.setTLSInspectionEnabled
    case setCaptureEnabled(Bool)         // ⇒ PacketPipeline.setCaptureEnabled (rearma el corte por fallo)
    case setCaptureDetail(CaptureDetail) // ⇒ PcapWriter.setSnaplen(_:), que **rota** (M11)
    case setPlaintextPersistenceEnabled(Bool)  // ⇒ Relay.setPlaintextPersistenceEnabled (ADR 0007)
    case rotateCapture                   // ⇒ PcapWriter.rotate(), para exportar sin parar el túnel
    case stats                           // ⇒ TunnelStats (pipeline + relay)
}

public enum ControlResponse: Codable, Sendable, Equatable {
    case ok
    case stats(TunnelStats)          // .pipeline + .relay (opcional: ver abajo)
    case failed(String)   // p. ej. disco lleno al rotar: la app solo puede contárselo al usuario
    case notRunning       // no hay pipeline: carrera normal entre la UI y stopTunnel, no un error
}
```

El transporte es JSON: a esta frecuencia la compacidad no importa, y a cambio un mensaje de una
versión desconocida o de un emisor ajeno falla al decodificar (`ControlMessageError.malformed`) en
vez de reinterpretarse como un comando válido.

`setCaptureDetail` **rota el fichero de captura** y eso no es un efecto secundario: el `snaplen` va en
la cabecera global del `.pcap`, así que un detalle nuevo solo puede empezar en un fichero nuevo
([`pcap.md`](pcap.md)). La app lo dice al usuario, porque lo que ve es una captura más en su lista.

`PipelineStats` lleva además, desde M11, tres contadores que **no** son del pipeline sino del runtime:
`capturesReclaimed`, `retentionFailures` y `lastRetentionError`. Son de la retención que la extensión
aplica al rotar, y viajan aquí porque un barrido que falla sin nadie delante no tiene otro sitio donde
contarse — el runtime los superpone sobre los del pipeline al responder a `.stats`.

`RelayStats` viaja con ellos desde M11 (`Shared/IPC/RelayStats.swift`, movido allí desde
`PacketTunnel/Relay` por lo mismo que `PipelineStats`: cruza el canal, así que es contrato entre
procesos). Van en **campos distintos** de un `TunnelStats` y no fundidos en una estructura plana,
porque cada mitad responde de un componente: el pipeline dice qué se registró, el relay qué se
reenvió y qué se inspeccionó. Y `relay` es **opcional**: `stop` cierra el relay antes que el
pipeline, así que una consulta que caiga en esa ventana no tiene contadores que dar — y unos ceros
dirían que no se inspeccionó nada en toda la sesión, que es lo contrario de lo que estos números
existen para contestar. Los siete de la inspección (`inspectionCandidates`, `terminationsOpened`,
`inspectionsAbandoned`, `pinnedHostSkips`, `flowsInspected`, `flowsPinned`, `terminationsFailed`) son
los que contestan *«¿por qué no se inspecciona nada?»*; quien los lee y los convierte en una
conclusión es `DiagnosticsPresentation` ([`app-services.md`](app-services.md)).

La tercera mitad de la respuesta es `ResolverStatus` (§ [*`ResolverStatus`*](#resolverstatus-lo-que-se-anunció-deja-de-ser-un-secreto)),
y es **también opcional** por el mismo motivo y no por simetría: `announced: []` **afirma** que el
túnel dejó al dispositivo sin resolución de nombres, así que no puede ser además lo que se enseñe
cuando nadie preguntó. Se compone al contestar: lo guardado del arranque más una relectura del sistema
hecha en ese momento.

## Memory and battery

- Batch `FlowStore` writes (e.g. every N records or M milliseconds) to avoid per-packet SQLite
  overhead; the ring buffer carries the real-time feed.
- Do not reassemble or buffer passthrough flows.
- Keep the per-packet closure allocation-free where possible; reuse buffers.
- A periodic timer calls `flowTable.expireIdle` and `drainClosed` to release memory.

## `PacketPipeline` — the hot path without the device

Everything `handle(packet:)` does other than touching `packetFlow` lives in `PacketPipeline`
(`PacketTunnel/Pipeline`), an actor the provider owns and delegates to. That split is what makes
M7 testable: the provider keeps the device-only lifecycle, the pipeline is pure and replayable
against fixture captures on the Simulator.

```swift
public actor PacketPipeline {
    public struct Config: Sendable {
        public var localIPv4: IPAddress          // IP del túnel; fija el sentido del paquete
        public var localIPv6: IPAddress?         // nil ⇒ el tráfico IPv6 se descarta
        public var tlsInspectionEnabled: Bool    // opt-in; false por defecto
        public var captureEnabled: Bool
        public var batchSize: Int                // paquetes que fuerzan un volcado al store
        public var flushInterval: UInt64         // ns que lo fuerzan aunque no se llene el lote
        public var anchor: MonotonicAnchor       // la del store: fecha el .pcap y lo descifrado
        public var plaintextBytesPerDirection: Int   // presupuesto por flujo y sentido (ADR 0007)
    }

    public init(flowTable: FlowTable, liveFeed: any LiveFeedSink, capture: (any CaptureSink)?,
                plaintext: (any PlaintextSink)?, store: any FlowPersisting,
                clock: any MonotonicClock, config: Config)

    @discardableResult
    public func handle(packet: Data, protocolFamily: Int32) async -> PacketDisposition
    public func record(reinjected packet: Data, protocolFamily: Int32) async   // la respuesta ya entregada
    public func flush() async        // vuelca el lote pendiente
    public func tick() async         // timer: expira flujos inactivos + vuelca
    public func drainClosedFlowKeys() -> [FlowKey]   // flujos terminados, para que el provider los cierre en el relay
    public func shutdown() async     // stopTunnel: vuelca y sincroniza la captura
    public func setTLSInspectionEnabled(_ enabled: Bool)   // canal de control
    public func setCaptureEnabled(_ enabled: Bool)
    public func observe(plaintext: Data, direction: Direction, for key: FlowKey) async   // PlaintextObserving
    public private(set) var stats: PipelineStats
}

/// Qué hace el provider con el paquete. El pipeline observa y decide; no toca la red.
public enum PacketDisposition: Sendable, Equatable {
    case passthrough(ParsedPacket)
    case inspect(ParsedPacket)
    case dropped(DropReason)   // .parseFailed / .unparseable / .noLocalAddress

    /// El paquete que hay que entregarle al relay, o nil si el datagrama muere aquí.
    public var packetToRelay: ParsedPacket? { get }
}
```

Las dos rutas que reenvían llevan dentro el `ParsedPacket` porque el relay lo necesita ya parseado
(endpoints, cabecera de transporte y rangos del payload) y el provider no puede permitirse parsear
dos veces cada datagrama del hot path.

Los cuatro sumideros son protocolos (`LiveFeedSink`, `CaptureSink`, `PlaintextSink`,
`FlowPersisting`) que `RingBufferProducer`, `PcapWriter`, `PlaintextWriter` y `FlowStore` cumplen; el
pipeline nunca los instancia. El
provider crea los reales, se los inyecta y **es quien los cierra**: `shutdown()` solo garantiza
que nada quede sin escribir.

Reglas que fija el pipeline:

- **Sentido:** `FlowKey` es canónico, así que el sentido sale de comparar con `localIPv4`/
  `localIPv6`. Sin dirección local para la familia del paquete se descarta (`.noLocalAddress`)
  en vez de adivinar.
- **Orden:** la captura va **antes** de publicar en el ring, porque el `PacketMeta` transporta la
  localización del registro (`CaptureLocation`: fichero + offset); sin captura queda a `nil`. El
  fichero va con el offset porque el writer rota y cada fichero reinicia los offsets tras su
  cabecera global, así que el offset suelto no identificaría unos bytes.
- **Pinning:** un flujo en `notInspectable` vuelve a `.passthrough` para siempre; nunca se
  reintenta la terminación ([`../decisions/0003-no-third-party-pinning-bypass.md`](../decisions/0003-no-third-party-pinning-bypass.md)).
- **Contenido descifrado:** un trozo que llega del relay se escribe **solo si su flujo sigue teniendo
  un record al que colgarlo** —bytes que ninguna fila nombra no se podrían leer ni podría barrerlos la
  retención—, se acota con el presupuesto por sentido antes de tocar el disco, y su fila viaja en el
  mismo lote que los paquetes, con el mismo `flowID`. El presupuesto muere por el mismo embudo que
  cierra los flujos (`merge(closed:)`), así que un puerto efímero reciclado no hereda el sitio ya
  gastado por otra conexión. Que llegue algo o no lo decide el relay, que es quien tiene el
  interruptor del ADR 0007.
- **Fallos acotados:** un fallo de captura (disco lleno) apaga la captura y se cuenta; un fallo del
  store pierde el lote y se cuenta. Ninguno tumba el túnel, y un lote fallido **no se reencola** —
  reintentar contra un store roto haría crecer la memoria de la extensión hasta que el OS la mate.

## Tests

The loop itself is device-only, but its collaborators are all injected and tested on Simulator:
`PacketPipeline` is replayed against synthetic datagrams with in-memory doubles for the three
sinks, incluidas las dos cosas que el bucle necesita del pipeline para gobernar el relay (que la
disposición lleve el paquete parseado, y que las claves de los flujos terminados salgan por
`drainClosedFlowKeys` cierre quien cierre el flujo). Lo que queda device-only es el cableado en sí,
validado por compilación bajo concurrencia estricta. Device smoke tests per
[`../development/04-testing-strategy.md`](../development/04-testing-strategy.md).
