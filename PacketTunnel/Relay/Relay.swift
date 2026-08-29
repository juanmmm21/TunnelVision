import Foundation
import Shared

/// Reenvía el tráfico del dispositivo a internet de verdad y reinyecta las respuestas.
///
/// Es la ruta por defecto de casi todo el tráfico. El provider (device-only) lee un datagrama del
/// dispositivo, el pipeline (M7) lo registra y decide `.passthrough`, y entonces el provider se lo
/// entrega aquí. Las conexiones que **origina la extensión** no las reenruta iOS al túnel, así que
/// salen a internet directamente; sus respuestas se reconstruyen en datagramas IP con
/// `PacketEmitter` y se devuelven al dispositivo por `packetFlow.writePackets`.
///
/// Contrato de sentido: cada `ParsedPacket` que llega a `passthrough` es **outbound** (lo entrega el
/// dispositivo), así que `packet.source` es el dispositivo y `packet.destination` el servidor. El
/// relay no conoce la IP del túnel —eso lo resuelve el pipeline—, así que depende de que el provider
/// solo le pase paquetes salientes, que es lo único que produce `readPackets`.
///
/// **Alcance:** UDP/QUIC (passthrough puro y sin estado) y **TCP** (passthrough con terminación en
/// userspace). Para TCP el relay no reenvía datagramas tal cual: mantiene un `TCPRelayFlow` por flujo
/// —la máquina de estados pura que hace de servidor hacia el dispositivo— y ejecuta las
/// `TCPRelayAction` que devuelve (abrir/escribir/half-close de la conexión saliente, y serializar +
/// reinyectar segmentos hacia el dispositivo). Un paquete que no sea ni UDP ni TCP se cuenta en
/// `RelayStats.unsupportedPackets` y no se reenvía, para que un enrutado indebido sea visible en vez de
/// silencioso.
///
/// De paso —y solo porque los bytes ya pasan por aquí en orden— el relay **le lee el nombre** a los
/// flujos TLS: el SNI del ClientHello, que viaja en claro, sale por `SNIObserving` hacia quien lleva
/// la tabla de flujos. Es lo que hace que la app diga con *quién* habló el dispositivo en vez de con
/// qué dirección, y no descifra nada (`readHandshake`).
///
/// ## Inspección TLS (opt-in): la conexión saliente se **sustituye**
///
/// Un flujo que el pipeline enruta a `.inspect` entra por `inspect(_:raw:)` en vez de por
/// `passthrough(_:raw:)`, y la única diferencia es que se abre como **candidato**. Todo lo demás —la
/// máquina de estados, el SYN-ACK, la re-segmentación— es idéntico, porque una terminación
/// (`TLSTerminationConnection`) tiene forma de `RelayConnection`: engancharla es cambiar *qué
/// conexión* lleva el flujo, no abrir un segundo camino.
///
/// El orden de los acontecimientos es lo que da forma a todo esto y no se puede invertir: **el
/// SYN-ACK va antes que el nombre**, porque el ClientHello llega después de él. Así que un candidato
/// abre igual que cualquier otro flujo su conexión saliente llana —y con ella su SYN-ACK es fiel: si
/// el servidor rechaza, el dispositivo ve un rechazo de verdad y no uno inventado— y lo que cambia es
/// que **retiene** lo que el dispositivo manda en vez de reenviarlo, hasta saber si hay nombre:
///
/// - **hay nombre** ⇒ se construye la terminación, se cancela la conexión llana (que no llegó a
///   mandar un byte), la terminación ocupa su sitio y recibe lo retenido;
/// - **no lo hay** —un 443 que no habla TLS, como la mensajería de WhatsApp, que habla Noise— ⇒ el
///   flujo vuelve al passthrough y lo retenido sale por la conexión llana, sin perder un byte. Sin
///   esto, encender la inspección rompería tráfico de todos los días.
///
/// El desenlace llega cuando el flujo acaba y sale por `TLSStatusObserving`. Un `pinned` marca el
/// flujo `notInspectable` **y** apunta su host en `PinnedHostMemory`, porque el reintento del cliente
/// llega con otra `FlowKey` y sin esa memoria volveríamos a romperle la conexión (ADR 0003).
public actor Relay {

    /// Reinyección hacia el dispositivo: la contraparte de `readPackets`. En producción es
    /// `packetFlow.writePackets(_:withProtocols:)` inyectada como closure, igual que la fuente de
    /// paquetes en `TunnelRuntime`, para mantener el relay fuera de NetworkExtension y testeable.
    private let reinject: @Sendable ([Data], [NSNumber]) -> Void
    private let factory: RelayConnectionFactory
    /// Quien recoge el nombre de host que el relay lee del handshake. Sin observador no se escanea
    /// nada: guardar bytes de handshake de un flujo que nadie va a nombrar sería memoria de la
    /// extensión gastada a cambio de nada.
    private let sniObserver: (any SNIObserving)?
    /// Quien construye las terminaciones TLS. Sin interceptor no hay inspección posible, así que un
    /// flujo candidato se comporta exactamente como uno de passthrough.
    private let inspector: (any FlowInspecting)?
    /// Quien recoge el desenlace de un intento de inspección (`inspected` / `notInspectable`).
    private let statusObserver: (any TLSStatusObserving)?
    /// Quien guarda el contenido en claro que produce una terminación. Sin él —o con la persistencia
    /// apagada— a la terminación no se le pasa sumidero y no se copia ni un byte.
    private let plaintextObserver: (any PlaintextObserving)?
    /// Si el usuario quiere que lo descifrado se guarde (ADR 0007). Es **su propio interruptor**,
    /// independiente del de inspeccionar: mirar lo que pasa mientras pasa y dejar un registro
    /// duradero de ello son dos actos distintos, y este es el segundo.
    private var plaintextPersistenceEnabled: Bool
    private let tcpConfig: TCPRelayFlow.Config
    /// Genera el ISN del lado servidor para cada flujo TCP. En producción es impredecible (RNG del
    /// sistema, requisito de seguridad de TCP); los tests lo fijan para un round-trip determinista.
    private let serverISNProvider: @Sendable () -> UInt32

    /// Una conexión UDP saliente viva por flujo, con los endpoints necesarios para reconstruir las
    /// respuestas (que van en sentido invertido).
    private struct UDPFlowConnection {
        let connection: RelayConnection
        /// El dispositivo: destino de las respuestas reinyectadas.
        let localEndpoint: IPEndpoint
        /// El servidor real: origen de las respuestas reinyectadas.
        let remoteEndpoint: IPEndpoint
    }

    /// En qué punto está el intento de inspeccionar un flujo TCP. Solo los candidatos salen de
    /// `.off`, y solo mientras están fuera de él el relay retiene lo que el dispositivo manda.
    private enum Inspection {
        /// No es candidato, o se decidió no inspeccionarlo: passthrough puro. Es lo normal.
        case off
        /// Candidato a la espera de nombre: lo que el dispositivo manda se retiene, porque todavía no
        /// se sabe si esos bytes van al servidor real o a una terminación.
        case scanning(held: Data)
        /// Hay nombre y se está construyendo la terminación (hay un `await` por medio); lo que llegue
        /// entretanto se sigue reteniendo.
        case opening(held: Data)
        /// La conexión del flujo **es** una terminación.
        ///
        /// `rollback` es lo que el dispositivo lleva mandado, conservado **solo mientras la vuelta
        /// atrás siga siendo posible**: hasta que el dispositivo reciba el primer byte producido por
        /// la terminación, nada de lo que hemos hecho ha llegado al otro lado y el flujo todavía
        /// puede seguir por una conexión llana como si nunca se hubiera intentado. En cuanto lo
        /// recibe, su TLS queda comprometido con nuestro leaf y ya no hay vuelta: entonces vale
        /// `nil`, que es la forma de decir que la ventana se cerró.
        case terminating(rollback: Data?)
    }

    /// Estado de un flujo TCP: la máquina de estados pura, la conexión saliente (nula hasta que la
    /// abre `connectToServer`) y los endpoints para emitir segmentos en sentido invertido.
    private struct TCPFlowState {
        var flow: TCPRelayFlow
        var connection: RelayConnection?
        /// El dispositivo: destino de los segmentos reinyectados.
        let localEndpoint: IPEndpoint
        /// El servidor real: origen de los segmentos reinyectados.
        let remoteEndpoint: IPEndpoint
        /// Lector del ClientHello mientras el flujo pueda dar todavía un nombre. Se pone a `nil` en
        /// cuanto lo da (o en cuanto se sabe que no lo dará), que es lo que hace que el resto del
        /// stream —ya cifrado— no se vuelva a mirar.
        var handshake: ClientHelloScanner?
        var inspection: Inspection = .off
        /// El dispositivo ya mandó su FIN. Se anota en vez de trasladarse cuando el flujo está
        /// reteniendo bytes: el EOF va **detrás** de lo retenido, y lo aplica quien acabe soltándolo.
        var deviceSendClosed: Bool = false
        /// Cuántas conexiones salientes ha tenido el flujo. Es lo que hace que los callbacks de la
        /// conexión **anterior** no muevan la máquina de estados cuando una terminación la sustituye:
        /// cancelar una `NWConnection` dispara su `onClose`, y sin esta marca ese cierre llegaría
        /// indistinguible del de la conexión viva y derribaría el flujo justo al inspeccionarlo.
        var epoch: UInt32 = 0
    }

    private var connections: [FlowKey: UDPFlowConnection]
    private var tcpFlows: [FlowKey: TCPFlowState]
    /// Hosts que ya rechazaron nuestro leaf en esta sesión: no se les vuelve a intentar (ADR 0003).
    private var pinnedHosts: PinnedHostMemory
    /// La cola serial del contenido descifrado y la tarea que la drena. Se crean con la **primera**
    /// terminación que va a guardar algo: un túnel que no inspecciona —o que inspecciona sin
    /// persistir— no arranca ninguna tarea de fondo por si acaso.
    private var plaintextQueue: PlaintextChunkQueue?
    private var plaintextPump: Task<Void, Never>?

    /// Los contadores tal y como los lleva el relay. Se leen por `stats`, que les añade lo que se
    /// cuenta fuera del aislamiento del actor.
    private var counters: RelayStats

    /// Contadores acumulados. Se compone al leerse porque uno de ellos —los trozos de contenido
    /// descifrado que la cola no pudo aceptar— lo cuenta el `yield`, que corre en el hilo del que
    /// entrega el plaintext y no aquí dentro.
    public var stats: RelayStats {
        var snapshot = counters
        snapshot.plaintextChunksDropped = plaintextQueue?.droppedCount ?? 0
        return snapshot
    }

    public init(
        reinject: @escaping @Sendable ([Data], [NSNumber]) -> Void,
        connectionFactory: RelayConnectionFactory = NetworkConnectionFactory(),
        sniObserver: (any SNIObserving)? = nil,
        inspector: (any FlowInspecting)? = nil,
        statusObserver: (any TLSStatusObserving)? = nil,
        plaintextObserver: (any PlaintextObserving)? = nil,
        plaintextPersistenceEnabled: Bool = false,
        tcpConfig: TCPRelayFlow.Config = TCPRelayFlow.Config(),
        serverISNProvider: @escaping @Sendable () -> UInt32 = { UInt32.random(in: .min ... .max) }
    ) {
        self.reinject = reinject
        self.factory = connectionFactory
        self.sniObserver = sniObserver
        self.inspector = inspector
        self.statusObserver = statusObserver
        self.plaintextObserver = plaintextObserver
        self.plaintextPersistenceEnabled = plaintextPersistenceEnabled
        self.tcpConfig = tcpConfig
        self.serverISNProvider = serverISNProvider
        self.connections = [:]
        self.tcpFlows = [:]
        self.pinnedHosts = PinnedHostMemory()
        self.counters = RelayStats()
    }

    // MARK: - Passthrough

    /// Reenvía un datagrama outbound hacia internet. UDP: extrae el payload y lo envía por la conexión
    /// del flujo (abriéndola en el primer paquete). TCP: alimenta el segmento a la máquina de estados y
    /// ejecuta las acciones resultantes. No bloquea ni bufferiza el flujo entero.
    public func passthrough(_ packet: ParsedPacket, raw: Data) async {
        await forward(packet, raw: raw, candidate: false)
    }

    /// Reenvía un datagrama outbound que el pipeline enrutó a `.inspect`: TCP contra el 443, con la
    /// inspección encendida y sobre un flujo que no haya rechazado ya la CA.
    ///
    /// Hace **lo mismo** que `passthrough` salvo por una cosa: si abre un flujo TCP nuevo, lo abre
    /// como candidato a terminación. Que sean dos puertas y no un booleano es deliberado — el
    /// pipeline ya tomó esa decisión y le puso nombre (`PacketDisposition`), así que el relay la
    /// obedece en vez de recalcularla.
    ///
    /// La candidatura se revisa en **cada** paquete mientras el flujo siga esperando nombre: si el
    /// usuario apaga la inspección a media apertura, el siguiente paquete llega por `passthrough` y
    /// el flujo vuelve al camino de siempre con lo retenido. Una vez la terminación está en marcha ya
    /// no hay vuelta atrás posible —el cliente está hablando TLS con nuestro leaf— y apagar la
    /// inspección deja de tener efecto sobre ese flujo, que muere con su conexión.
    public func inspect(_ packet: ParsedPacket, raw: Data) async {
        await forward(packet, raw: raw, candidate: true)
    }

    private func forward(_ packet: ParsedPacket, raw: Data, candidate: Bool) async {
        if let udp = packet.udp {
            // Un `.inspect` solo lo produce el pipeline para TCP, así que aquí `candidate` es
            // siempre falso; el UDP no tiene terminación que ofrecer y sigue su camino de siempre.
            passthroughUDP(packet, udp: udp, raw: raw)
        } else if let tcp = packet.tcp {
            passthroughTCP(packet, tcp: tcp, raw: raw, candidate: candidate)
        } else {
            counters.unsupportedPackets &+= 1
        }
    }

    // MARK: - Passthrough UDP

    private func passthroughUDP(_ packet: ParsedPacket, udp: UDPHeader, raw: Data) {
        let connection = udpConnection(for: packet)
        // El payload va en offsets 0-based sobre el datagrama (así los produce el parser); se copia a
        // un `Data` propio para no arrastrar la referencia al buffer entero de lectura.
        connection.send(Data(raw[udp.payloadRange]))
        counters.datagramsSentOutbound &+= 1
        // Las consultas de DNS se cuentan **aparte** porque su pareja —consultas sin respuesta— es el
        // único síntoma medible de que el resolver anunciado no sirve, que es en lo que acaba un túnel
        // que se llevó las rutas por defecto y anunció el DNS de otra red. No se mira contra qué
        // resolver: cualquier consulta al 53 vale, y así el contador sigue significando lo mismo si el
        // usuario cambia de resolver o si el túnel reanuncia otro a mitad de sesión.
        if udp.destinationPort == Self.dnsPort {
            counters.dnsQueriesSent &+= 1
        }
    }

    /// Devuelve la conexión UDP del flujo, creándola y arrancándola en el primer paquete.
    private func udpConnection(for packet: ParsedPacket) -> RelayConnection {
        if let existing = connections[packet.flowKey] {
            return existing.connection
        }

        let connection = factory.makeUDPConnection(to: packet.destination)
        connections[packet.flowKey] = UDPFlowConnection(
            connection: connection,
            localEndpoint: packet.source,
            remoteEndpoint: packet.destination
        )
        counters.udpFlowsOpened &+= 1

        let key = packet.flowKey
        connection.start(
            onReady: {},    // UDP no espera a estar listo: `send` bufferiza hasta que la conexión arranca.
            onReceive: { [weak self] data in
                Task { await self?.handleUDPInbound(key: key, transportBytes: data) }
            },
            onClose: { [weak self] error in
                Task { await self?.handleUDPClosed(key: key, error: error) }
            }
        )
        return connection
    }

    /// Una respuesta UDP del servidor: se reconstruye el datagrama en sentido invertido (origen
    /// servidor, destino dispositivo) y se reinyecta. Si el flujo ya se cerró, se descarta.
    private func handleUDPInbound(key: FlowKey, transportBytes: Data) async {
        guard let state = connections[key] else { return }

        let datagram: Data
        do {
            datagram = try PacketEmitter.udp(
                source: state.remoteEndpoint,
                destination: state.localEndpoint,
                payload: transportBytes
            )
        } catch {
            // Un payload que no cabe en un datagrama (o una familia incoherente) no puede tumbar el
            // relay: se cuenta y esa respuesta se pierde, como un paquete caído en la red.
            counters.emitterFailures &+= 1
            return
        }

        reinject([datagram], [NSNumber(value: Self.addressFamily(for: state.remoteEndpoint.address.version))])
        counters.datagramsReinjected &+= 1
        // La otra mitad del par: una respuesta **desde** el 53. Se mira el puerto del extremo remoto y
        // no el del payload porque la conexión saliente es nuestra y su origen es, por construcción, el
        // servidor al que se preguntó.
        if state.remoteEndpoint.port == Self.dnsPort {
            counters.dnsRepliesReceived &+= 1
        }
    }

    /// La conexión UDP terminó por su cuenta (el servidor cerró, o falló). Se libera su hueco; si ya no
    /// estaba (cierre explícito vía `close`), no hay nada que hacer.
    private func handleUDPClosed(key: FlowKey, error: RelayConnectionError?) async {
        guard connections.removeValue(forKey: key) != nil else { return }
        counters.connectionsClosed &+= 1
        if error != nil {
            counters.connectionFailures &+= 1
        }
    }

    // MARK: - Passthrough TCP

    /// Alimenta un segmento del dispositivo a la máquina de estados del flujo (creándola en el primer
    /// paquete) y ejecuta las acciones resultantes.
    private func passthroughTCP(_ packet: ParsedPacket, tcp: TCPHeader, raw: Data, candidate: Bool) {
        let key = packet.flowKey
        if tcpFlows[key] == nil {
            let isTLSPort = packet.destination.port == Self.tlsPort
            // El lector del handshake solo se crea para lo que puede ser TLS —TCP contra el 443, la
            // misma regla con la que `FlowTable.initialTLSStatus` marca un flujo `encrypted`— y solo
            // si el nombre le sirve a alguien: para nombrar el flujo, para inspeccionarlo, o ambas.
            let inspects = candidate && inspector != nil && isTLSPort
            let readsHandshake = isTLSPort && (sniObserver != nil || inspects)
            tcpFlows[key] = TCPFlowState(
                flow: TCPRelayFlow(config: tcpConfig, serverISN: serverISNProvider()),
                connection: nil,
                localEndpoint: packet.source,
                remoteEndpoint: packet.destination,
                handshake: readsHandshake ? ClientHelloScanner() : nil,
                inspection: inspects ? .scanning(held: Data()) : .off
            )
            counters.tcpFlowsOpened &+= 1
            if inspects { counters.inspectionCandidates &+= 1 }
        } else if !candidate {
            // El pipeline ha dejado de enrutar este flujo a `.inspect` (el usuario apagó la
            // inspección, o el flujo acaba de marcarse `notInspectable`): si todavía estaba
            // esperando nombre, se le devuelve al passthrough con todo lo retenido.
            abandonInspection(for: key)
        }

        let segment = InboundSegment(header: tcp, payload: Data(raw[tcp.payloadRange]))
        let actions = mutateFlow(key) { $0.receiveFromDevice(segment) }
        execute(actions, for: key)
    }

    /// La conexión saliente TCP quedó establecida: la máquina de estados difiere ahora el SYN-ACK.
    ///
    /// Una terminación que sustituye a la conexión llana también pasa por aquí al levantar su pata
    /// saliente, y entonces esto es un no-op: el flujo ya está `established` desde el SYN-ACK de la
    /// conexión llana y la máquina de estados ignora un `serverDidConnect` fuera de `connecting`.
    private func handleServerReady(key: FlowKey, epoch: UInt32) {
        guard isCurrent(epoch, for: key) else { return }
        let actions = mutateFlow(key) { $0.serverDidConnect() }
        execute(actions, for: key)
    }

    /// Llegó un trozo de stream del servidor: la máquina de estados lo re-segmenta hacia el dispositivo.
    private func handleServerData(key: FlowKey, epoch: UInt32, bytes: Data) {
        guard isCurrent(epoch, for: key) else { return }
        closeRollbackWindow(for: key)
        let actions = mutateFlow(key) { $0.receiveFromServer(bytes) }
        execute(actions, for: key)
    }

    /// La conexión saliente TCP terminó. `nil` es un cierre limpio / EOF de recepción (FIN del
    /// servidor); un error es un fallo de red. Cada uno dispara el evento correspondiente de la máquina
    /// de estados. Si el flujo ya no está (teardown previo), `mutateFlow` no hace nada.
    ///
    /// Salvo una excepción, que es la que hace que un fallo de la inspección no cueste la conexión:
    /// si quien acaba de morir es una terminación que **no llegó a decirle nada al dispositivo**, el
    /// flujo vuelve al passthrough en vez de derribarse (`rollbackTermination`).
    private func handleServerClose(key: FlowKey, epoch: UInt32, error: RelayConnectionError?) {
        guard isCurrent(epoch, for: key) else { return }
        guard !rollbackTermination(for: key) else { return }
        let actions = mutateFlow(key) { error == nil ? $0.serverDidClose() : $0.serverDidFail() }
        execute(actions, for: key)
    }

    /// Cierra la ventana de vuelta atrás: el dispositivo va a recibir bytes que produjo la
    /// terminación —el ServerHello firmado con nuestro leaf—, así que a partir de aquí su TLS está
    /// comprometido con nosotros y sustituirla por una conexión llana le dejaría a media conversación
    /// con un interlocutor que ya no existe.
    private func closeRollbackWindow(for key: FlowKey) {
        guard var state = tcpFlows[key], case .terminating(.some) = state.inspection else { return }
        state.inspection = .terminating(rollback: nil)
        tcpFlows[key] = state
    }

    /// Si el evento viene de la conexión que el flujo tiene **ahora**. Los de una conexión ya
    /// sustituida se descartan en silencio: no son un fallo, son el eco de un cierre que pidió el
    /// propio relay.
    private func isCurrent(_ epoch: UInt32, for key: FlowKey) -> Bool {
        tcpFlows[key]?.epoch == epoch
    }

    /// Aplica una mutación a la máquina de estados del flujo y devuelve las acciones. Guarda el estado
    /// de vuelta. Si el flujo ya no existe (cerrado), es un no-op que devuelve `[]`.
    private func mutateFlow(_ key: FlowKey, _ body: (inout TCPRelayFlow) -> [TCPRelayAction]) -> [TCPRelayAction] {
        guard var state = tcpFlows[key] else { return [] }
        let actions = body(&state.flow)
        tcpFlows[key] = state
        return actions
    }

    /// Ejecuta las acciones que pide la máquina de estados. Dentro de una misma tanda, la máquina
    /// siempre emite el `segmentToDevice` (p. ej. un RST) **antes** del `teardown`, así que emitir con
    /// el flujo aún presente y borrarlo después es correcto.
    private func execute(_ actions: [TCPRelayAction], for key: FlowKey) {
        for action in actions {
            switch action {
            case .connectToServer:
                openServerConnection(for: key)
            case .sendToServer(let data):
                sendToServer(data, for: key)
            case .closeServerSend:
                closeServerSend(for: key)
            case .segmentToDevice(let segment):
                emitToDevice(segment, for: key)
            case .teardown:
                teardownTCP(key)
            }
        }
    }

    /// Escribe hacia el servidor los bytes ya reensamblados que pide la máquina de estados.
    ///
    /// Es el punto en el que un candidato se comporta distinto: **no manda nada** mientras espera
    /// nombre, porque hasta saberlo no se sabe si esos bytes van al servidor real (passthrough) o a
    /// una terminación. Lo retenido sale entero por uno de los dos caminos, en orden y sin perder un
    /// byte — que es lo que hace que encender la inspección no rompa un 443 que no hable TLS.
    private func sendToServer(_ data: Data, for key: FlowKey) {
        guard var state = tcpFlows[key] else { return }

        switch state.inspection {
        case .off:
            state.connection?.send(data)
            counters.tcpBytesToServer &+= UInt64(data.count)
            // Después de enviar, nunca antes: leer un nombre es metadato y no puede meterse
            // delante de los bytes que el usuario está mandando.
            readHandshake(data, for: key)
        case .terminating(let rollback):
            state.connection?.send(data)
            counters.tcpBytesToServer &+= UInt64(data.count)
            // Mientras la vuelta atrás siga abierta hay que conservar **todo** lo que el dispositivo
            // manda, no solo lo retenido antes del cambio: si la terminación se cae, la conexión
            // llana que la sustituya tiene que poder mandar la conversación entera y en orden. Pasado
            // el tope se renuncia a poder volver —crecer sin límite dentro de la extensión sería
            // peor—, y el flujo sigue con su terminación como hasta ahora.
            if var rollback {
                rollback.append(data)
                state.inspection = .terminating(rollback: rollback.count > Self.maximumHeldBytes ? nil : rollback)
                tcpFlows[key] = state
            }
            readHandshake(data, for: key)
        case .scanning(var held):
            held.append(data)
            state.inspection = .scanning(held: held)
            tcpFlows[key] = state
            // Aquí sí va antes: es lo que decide a dónde van estos bytes, así que no hay envío que
            // pueda adelantarlo. `readHandshake` puede dejar el flujo en cualquiera de los otros
            // estados, y el tope se comprueba después justamente por eso.
            readHandshake(data, for: key)
            enforceHeldCeiling(for: key)
        case .opening(var held):
            held.append(data)
            state.inspection = .opening(held: held)
            tcpFlows[key] = state
            enforceHeldCeiling(for: key)
        }
    }

    /// Devuelve el flujo al passthrough si lo retenido se pasa del tope. Solo puede ocurrir mientras
    /// se construye la terminación (el escáner tiene su propio techo, y al alcanzarlo suelta lo
    /// retenido por su cuenta): un dispositivo que llene 64 KB en ese hueco es una salida que nunca
    /// llegó a levantarse, y crecer sin límite dentro de la extensión sería peor que no inspeccionar.
    private func enforceHeldCeiling(for key: FlowKey) {
        guard let state = tcpFlows[key] else { return }
        let held: Data
        switch state.inspection {
        case .scanning(let data), .opening(let data): held = data
        case .off, .terminating: return
        }
        guard held.count > Self.maximumHeldBytes else { return }
        abandonInspection(for: key)
    }

    /// Abre la conexión saliente TCP del flujo y la arranca; sus callbacks reentran al actor y
    /// alimentan la máquina de estados (ready → SYN-ACK, datos → re-segmentación, cierre → FIN/RST).
    private func openServerConnection(for key: FlowKey) {
        guard var state = tcpFlows[key], state.connection == nil else { return }
        let connection = factory.makeTCPConnection(to: state.remoteEndpoint)
        state.connection = connection
        tcpFlows[key] = state

        start(connection, for: key, epoch: state.epoch)
    }

    /// Registra los callbacks de una conexión saliente (llana o terminación) y la arranca. El `epoch`
    /// viaja capturado para que sus eventos se descarten si para entonces el flujo ya lleva otra.
    private func start(_ connection: any RelayConnection, for key: FlowKey, epoch: UInt32) {
        connection.start(
            onReady: { [weak self] in
                Task { await self?.handleServerReady(key: key, epoch: epoch) }
            },
            onReceive: { [weak self] data in
                Task { await self?.handleServerData(key: key, epoch: epoch, bytes: data) }
            },
            onClose: { [weak self] error in
                Task { await self?.handleServerClose(key: key, epoch: epoch, error: error) }
            }
        )
    }

    /// Serializa un segmento hacia el dispositivo (origen = servidor, destino = dispositivo) y lo
    /// reinyecta. Un fallo del emisor se cuenta y el segmento se pierde, sin tumbar el relay.
    private func emitToDevice(_ segment: OutboundSegment, for key: FlowKey) {
        guard let state = tcpFlows[key] else { return }

        let datagram: Data
        do {
            datagram = try PacketEmitter.tcp(
                source: state.remoteEndpoint,
                destination: state.localEndpoint,
                sequence: segment.sequence,
                acknowledgment: segment.acknowledgment,
                flags: segment.flags,
                windowSize: segment.window,
                payload: segment.payload
            )
        } catch {
            counters.emitterFailures &+= 1
            return
        }

        reinject([datagram], [NSNumber(value: Self.addressFamily(for: state.remoteEndpoint.address.version))])
        counters.tcpSegmentsReinjected &+= 1
        if segment.flags.contains(.rst) {
            counters.tcpResetsToDevice &+= 1
        }
    }

    // MARK: - Nombre del flujo (SNI)

    /// Alimenta el lector del ClientHello con los bytes que acaban de salir hacia el servidor.
    ///
    /// **Se lee aquí, y no en el pipeline, por una razón concreta:** esto es el stream ya
    /// reensamblado y en orden que entrega `TCPRelayFlow`, mientras que el pipeline solo ve el
    /// payload suelto de cada segmento. Un ClientHello de los de hoy —con los key shares híbridos
    /// post-cuánticos— pasa de la MTU del túnel y llega partido en dos segmentos, así que leerlo
    /// segmento a segmento se quedaría sin nombre justo en el caso normal, y una retransmisión o un
    /// segmento fuera de orden lo estropearían del todo. El precio es esta costura hacia quien sabe
    /// de flujos (`SNIObserving`); duplicar aquí el reensamblado, que ya estaba escrito y probado,
    /// habría sido peor: dos implementaciones de lo mismo en el camino de un paquete.
    ///
    /// El ClientHello viaja **en claro** (es el primer mensaje del handshake, antes de que exista
    /// ninguna clave), así que esto no descifra nada, no usa la CA local y no roza el ADR 0003.
    private func readHandshake(_ data: Data, for key: FlowKey) {
        guard var state = tcpFlows[key], var scanner = state.handshake else { return }

        let outcome = scanner.scan(data)
        switch outcome {
        case .needMoreBytes:
            state.handshake = scanner
            tcpFlows[key] = state
        case .found(let host):
            state.handshake = nil
            counters.sniObserved &+= 1
            tcpFlows[key] = state
            if let sniObserver {
                // Fuera del camino de los bytes a propósito: lo que el dispositivo mandó ya salió, y
                // el nombre llega a la tabla de flujos un salto después. Es una sola vez por flujo,
                // así que no hay orden que preservar entre dos de estas.
                Task { await sniObserver.observe(sni: host, for: key) }
            }
            beginTermination(host: host, for: key)
        case .unavailable:
            state.handshake = nil
            counters.sniUnavailable &+= 1
            tcpFlows[key] = state
            // Un 443 que no habla TLS —la mensajería de WhatsApp habla Noise— no tiene nombre y no
            // se puede terminar: vuelve al passthrough con todo lo retenido.
            abandonInspection(for: key)
        }
    }

    // MARK: - Inspección TLS

    /// Hay nombre, así que se puede pedir la terminación.
    ///
    /// El flujo pasa a `.opening` **antes** del salto asíncrono, y no después: mientras se construye
    /// la terminación el dispositivo puede seguir mandando, y esos bytes tienen que seguir
    /// reteniéndose o se colarían por la conexión llana que está a punto de sobrar.
    private func beginTermination(host: String, for key: FlowKey) {
        guard inspector != nil, var state = tcpFlows[key], case .scanning(let held) = state.inspection else { return }

        guard !pinnedHosts.contains(host) else {
            // Este host ya rechazó nuestro leaf en esta sesión, y el reintento del cliente llega con
            // otra `FlowKey`: volver a intentarlo solo le rompería la conexión otra vez. El flujo se
            // relaya intacto y se marca como lo que es, no inspeccionable (ADR 0003).
            counters.pinnedHostSkips &+= 1
            abandonInspection(for: key)
            let observer = statusObserver
            Task { await observer?.observe(tlsStatus: .notInspectable, for: key) }
            return
        }

        state.inspection = .opening(held: held)
        tcpFlows[key] = state

        let endpoint = state.remoteEndpoint
        Task { [weak self] in
            await self?.finishTermination(key: key, host: host, endpoint: endpoint)
        }
    }

    /// Le pide la terminación al interceptor y la instala. Un fallo aquí es una razón **transitoria**
    /// (la CA no está lista, no se pudo emitir el leaf, la pila no levantó): el flujo se relaya
    /// intacto y **sin** marcar, porque la causa puede desaparecer y marcarlo sería acusar de pinning
    /// a quien no lo hace.
    private func finishTermination(key: FlowKey, host: String, endpoint: IPEndpoint) async {
        guard let inspector else { return }

        let termination: any RelayConnection
        do {
            termination = try await inspector.open(
                to: endpoint,
                clientHelloSNI: host,
                // El sumidero solo existe si el usuario quiere que lo descifrado se guarde: sin él la
                // terminación no copia ni un byte, que es lo que hace que el interruptor signifique
                // algo aquí abajo y no solo en la pantalla (ADR 0007).
                plaintext: plaintextSink(for: key),
                onResolve: { [weak self] decision in
                    Task { await self?.resolve(decision, host: host, for: key) }
                }
            )
        } catch {
            abandonInspection(for: key)
            return
        }
        install(termination, for: key)
    }

    /// Sustituye la conexión llana del flujo por la terminación y le entrega lo retenido.
    private func install(_ termination: any RelayConnection, for key: FlowKey) {
        guard var state = tcpFlows[key], case .opening(let held) = state.inspection else {
            // El flujo murió —o volvió al passthrough— mientras se construía: la terminación se
            // deshace sin haber arrancado, así que no llega a tocar al servidor real.
            termination.cancel()
            return
        }

        let previous = state.connection
        state.epoch &+= 1
        state.connection = termination
        // Lo retenido se le entrega a la terminación **y** se conserva: hasta que el dispositivo
        // reciba el primer byte suyo, esto es lo único que hace falta para deshacer el cambio.
        state.inspection = .terminating(rollback: held)
        tcpFlows[key] = state
        counters.terminationsOpened &+= 1

        // La llana se cancela **después** de anotar la sustitución: su cierre llega con el epoch
        // viejo y se descarta en vez de derribar el flujo. No mandó un solo byte, así que el servidor
        // real solo ha visto abrirse y cerrarse un TCP; el tráfico lo lleva ya la terminación.
        previous?.cancel()
        start(termination, for: key, epoch: state.epoch)

        if !held.isEmpty {
            termination.send(held)
            counters.tcpBytesToServer &+= UInt64(held.count)
        }
        if state.deviceSendClosed {
            termination.closeSend()
        }
    }

    /// Deshace la sustitución: la terminación murió **antes de que el dispositivo recibiera un solo
    /// byte suyo**, así que el flujo vuelve al passthrough con una conexión llana nueva y todo lo que
    /// el dispositivo mandó, entero y en orden.
    ///
    /// Es la misma promesa que ya cumplía un candidato al que no se le llega a instalar nada —un 443
    /// que no habla TLS, una CA que no está lista— extendida al único tramo donde faltaba, y es lo
    /// que separa *«la inspección no funciona»* de *«no tengo internet»*: si la pila de terminación
    /// no levanta en el dispositivo (el sandbox negándole el listener de loopback, por ejemplo), sin
    /// esto **cada** conexión al 443 muere con un RST y no se abre una sola web, que es exactamente
    /// lo contrario de la degradación silenciosa que el producto promete.
    ///
    /// El dispositivo no se entera de nada: su TCP sigue establecido desde el SYN-ACK que dio la
    /// conexión llana original, y la máquina de estados ni se toca — un `serverDidConnect` de la
    /// conexión nueva fuera de `connecting` ya era un no-op.
    ///
    /// - Returns: si el flujo volvió al passthrough, y por tanto no hay cierre que trasladarle.
    @discardableResult
    private func rollbackTermination(for key: FlowKey) -> Bool {
        guard var state = tcpFlows[key], case .terminating(.some(let held)) = state.inspection else { return false }

        let dead = state.connection
        state.inspection = .off
        // Otra época: el cierre que dispare cancelar la terminación llega con la vieja y se descarta,
        // igual que el de la conexión llana cuando fue ella la sustituida.
        state.epoch &+= 1
        let connection = factory.makeTCPConnection(to: state.remoteEndpoint)
        state.connection = connection
        tcpFlows[key] = state
        counters.terminationsRolledBack &+= 1

        dead?.cancel()
        start(connection, for: key, epoch: state.epoch)

        if !held.isEmpty {
            // No se vuelven a contar en `tcpBytesToServer`: ya se contaron al entregárselos a la
            // terminación, y son los mismos bytes del dispositivo saliendo una sola vez.
            connection.send(held)
        }
        if state.deviceSendClosed {
            connection.closeSend()
        }
        return true
    }

    /// Cómo acabó el intento de inspeccionar un flujo. Llega cuando el flujo termina, no cuando se
    /// abre, así que puede llegar con el flujo ya soltado: marcarlo entonces es un no-op de la tabla.
    private func resolve(_ decision: TLSInterceptionPolicy.Decision, host: String, for key: FlowKey) async {
        switch decision {
        case .inspected:
            counters.flowsInspected &+= 1
            await statusObserver?.observe(tlsStatus: .inspected, for: key)
        case .notInspectable:
            // El invariante del ADR 0003 en sus dos mitades: este flujo queda marcado, y el host
            // queda apuntado para que su reintento —que llega con otra clave— no se vuelva a forzar.
            counters.flowsPinned &+= 1
            pinnedHosts.remember(host)
            await statusObserver?.observe(tlsStatus: .notInspectable, for: key)
        case .fail:
            // Transitoria y con la terminación ya en marcha: no queda flujo intacto que relayar, así
            // que lo que se pierde es esa conexión y el reintento del cliente entra como flujo nuevo.
            counters.terminationsFailed &+= 1
        }
    }

    // MARK: - Contenido descifrado

    /// El sumidero que se le pasa a una terminación, o `nil` si lo descifrado no se guarda.
    ///
    /// La decisión se toma **al abrir** porque es lo que evita la copia: una terminación sin sumidero
    /// no toca el plaintext que trasiega. Encender la persistencia a mitad de sesión, entonces, empieza
    /// a valer en el flujo siguiente — igual que encender la inspección—, y **apagarla vale en el
    /// acto**, que es lo que de verdad importa: la asimetría es a propósito, porque dejar de grabar no
    /// puede hacerse esperar (lo aplica `deliver`).
    private func plaintextSink(for key: FlowKey) -> (@Sendable (Data, Direction) -> Void)? {
        guard plaintextPersistenceEnabled, plaintextObserver != nil else { return nil }
        let queue = startPlaintextPumpIfNeeded()
        return { data, direction in
            guard !data.isEmpty else { return }
            queue.enqueue(PlaintextChunkQueue.Chunk(key: key, data: data, direction: direction))
        }
    }

    /// Crea la cola y la tarea que la drena, si no existían.
    private func startPlaintextPumpIfNeeded() -> PlaintextChunkQueue {
        if let plaintextQueue { return plaintextQueue }
        let queue = PlaintextChunkQueue()
        plaintextQueue = queue
        plaintextPump = Task { [weak self] in
            // Un solo consumidor y un `await` por trozo: el orden de la conversación se conserva
            // por construcción, que es la razón de ser de la cola.
            for await chunk in queue.stream {
                await self?.deliver(plaintext: chunk)
            }
        }
        return queue
    }

    /// Entrega un trozo a quien lo guarda, en orden.
    private func deliver(plaintext chunk: PlaintextChunkQueue.Chunk) async {
        // El interruptor se vuelve a mirar aquí, y no solo al abrir el flujo: apagarlo tiene que
        // dejar de grabar en el acto, incluso lo que ya estaba en la cola. Un usuario que revoca el
        // permiso de guardar lo que dice por dentro no puede esperar a que acaben sus conexiones.
        guard plaintextPersistenceEnabled, let plaintextObserver else { return }
        counters.plaintextChunksObserved &+= 1
        await plaintextObserver.observe(plaintext: chunk.data, direction: chunk.direction, for: chunk.key)
    }

    /// Enciende o apaga la persistencia del contenido descifrado en caliente (canal de control).
    public func setPlaintextPersistenceEnabled(_ enabled: Bool) {
        plaintextPersistenceEnabled = enabled
    }

    /// Devuelve un flujo candidato al passthrough: suelta lo retenido por la conexión llana, entero y
    /// en orden, y deja de esperar nombre. Es la vuelta atrás que hace que encender la inspección no
    /// rompa el tráfico que no se puede inspeccionar.
    ///
    /// - Returns: si había algo que abandonar (un flujo que ya no era candidato no cuenta).
    @discardableResult
    private func abandonInspection(for key: FlowKey) -> Bool {
        guard var state = tcpFlows[key] else { return false }
        let held: Data
        switch state.inspection {
        case .scanning(let data), .opening(let data): held = data
        case .off, .terminating: return false
        }

        state.inspection = .off
        tcpFlows[key] = state
        counters.inspectionsAbandoned &+= 1

        guard let connection = state.connection else { return true }
        if !held.isEmpty {
            connection.send(held)
            counters.tcpBytesToServer &+= UInt64(held.count)
        }
        if state.deviceSendClosed {
            connection.closeSend()
        }
        return true
    }

    /// El dispositivo terminó de enviar (FIN). Un flujo que todavía retiene bytes no cierra nada aún:
    /// el EOF va detrás de lo retenido, y lo aplica quien acabe soltándolo. Cerrar aquí le enseñaría
    /// al servidor el final antes que el principio.
    private func closeServerSend(for key: FlowKey) {
        guard var state = tcpFlows[key] else { return }
        state.deviceSendClosed = true
        tcpFlows[key] = state

        switch state.inspection {
        case .off, .terminating: state.connection?.closeSend()
        case .scanning, .opening: break
        }
    }

    /// El flujo TCP terminó (por decisión de la propia máquina de estados): cancela la conexión
    /// saliente y olvida el flujo.
    private func teardownTCP(_ key: FlowKey) {
        guard let state = tcpFlows.removeValue(forKey: key) else { return }
        state.connection?.cancel()
        counters.tcpFlowsClosed &+= 1
    }

    // MARK: - Cierre

    /// Cierra un flujo cuando `FlowTable` lo da por terminado (FIN/RST, evicción LRU o inactividad).
    /// Sin esto las `NWConnection` se acumularían. Cubre ambos protocolos: es el cierre que decide el
    /// pipeline, no el que la máquina de estados TCP ya resuelve por su cuenta (esos emiten `teardown`).
    public func close(_ key: FlowKey) {
        if let state = connections.removeValue(forKey: key) {
            state.connection.cancel()
        }
        if let tcp = tcpFlows.removeValue(forKey: key) {
            tcp.connection?.cancel()
        }
    }

    /// Cierra todos los flujos. La llama el provider al parar el túnel.
    ///
    /// Y **espera a que la cola del contenido descifrado se vacíe**, por lo mismo que el provider
    /// espera al registrador de lo reinyectado: son bytes que el usuario ya descifró y que están a un
    /// salto de su fichero, así que perderlos en la puerta sería un agujero en la conversación
    /// guardada. No hay bloqueo posible: la cola es finita y el `await` suelta el actor, así que la
    /// bomba puede reentrar a entregar lo que le queda.
    public func closeAll() async {
        let liveUDP = connections
        let liveTCP = tcpFlows
        connections.removeAll()
        tcpFlows.removeAll()
        for state in liveUDP.values {
            state.connection.cancel()
        }
        for state in liveTCP.values {
            state.connection?.cancel()
        }

        plaintextQueue?.finish()
        await plaintextPump?.value
        plaintextPump = nil
        // La cola se conserva: su cuenta de descartes sigue siendo parte de los contadores de la
        // sesión, y lo que la lee es `stats`, que se puede pedir después de parar.
    }

    /// Flujos con conexión viva (UDP + TCP). Expuesto para verificar el ciclo de vida en tests.
    public var activeFlowCount: Int { connections.count + tcpFlows.count }

    /// Solo los flujos TCP vivos. Expuesto para los tests del passthrough TCP.
    public var activeTCPFlowCount: Int { tcpFlows.count }

    // MARK: - Utilidades

    /// El puerto en el que se busca un ClientHello. Es la misma definición de "esto es TLS" que usa
    /// `FlowTable.initialTLSStatus` para marcar un flujo `encrypted`: si un día deja de ser el 443,
    /// tiene que dejar de serlo en los dos sitios a la vez o un flujo cifrado y un flujo con nombre
    /// dejarían de ser el mismo conjunto.
    private static let tlsPort: UInt16 = 443

    /// El puerto del DNS. Se cuenta el tráfico que va y viene de él porque **consultas sin respuesta
    /// es el síntoma** de que el resolver anunciado no sirve, y esa es la avería que deja al
    /// dispositivo con las páginas cargando para siempre. DNS sobre TLS o sobre HTTPS no pasa por aquí
    /// y por eso este par no dice nada de él: mide lo que ve, que es el DNS de toda la vida.
    private static let dnsPort: UInt16 = 53

    /// Tope de bytes del dispositivo retenidos mientras un flujo candidato espera a saber si se puede
    /// inspeccionar. Es el mismo número, y por la misma razón, que el de `TLSTerminationConnection`:
    /// pasarse significa que la terminación no llegó a levantarse, y entonces lo correcto es volver
    /// al passthrough en vez de crecer sin límite dentro de una extensión con presupuesto de memoria.
    private static let maximumHeldBytes = 64 * 1024

    private static func addressFamily(for version: IPVersion) -> Int32 {
        switch version {
        case .v4: return AF_INET
        case .v6: return AF_INET6
        }
    }
}

