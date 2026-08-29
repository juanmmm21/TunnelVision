import Foundation
import XCTest
import Shared

/// Tests del pipeline (M7). Cubren: el registro de un paquete de punta a punta (sentido, feed en
/// vivo, captura, store), la decisión de routing en todas sus ramas —incluida la de pinning—, los
/// descartes explícitos, el volcado por lotes (por tamaño, por intervalo y por cierre de flujo),
/// la degradación ante un fallo de captura o de store, el canal de control y una carga sostenida.
final class PacketPipelineTests: XCTestCase {

    /// Banco de pruebas: el pipeline con sus tres dobles y un reloj manual, para poder afirmar
    /// sobre cada sumidero por separado.
    private struct Harness {
        let pipeline: PacketPipeline
        let table: FlowTable
        let feed: RecordingLiveFeed
        let capture: RecordingCapture
        let store: RecordingStore
        let clock: ManualClock
        let anchor: MonotonicAnchor
    }

    /// Ancla de la sesión con una hora de pared fija: es lo que hace afirmable el instante absoluto
    /// que el pipeline le pasa a la captura, que si no dependería de cuándo se ejecuta el test.
    private static let wallClock = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeHarness(
        tlsInspectionEnabled: Bool = false,
        captureEnabled: Bool = true,
        batchSize: Int = 256,
        flushInterval: UInt64 = 500_000_000,
        localIPv6: IPAddress? = nil,
        idleTimeout: UInt64 = 120_000_000_000,
        maxFlows: Int = 4096
    ) -> Harness {
        let clock = ManualClock(1_000)
        let anchor = MonotonicAnchor(uptimeNanoseconds: 1_000, wallClock: Self.wallClock)
        let table = FlowTable(config: .init(maxFlows: maxFlows, idleTimeout: idleTimeout), clock: clock)
        let feed = RecordingLiveFeed()
        let capture = RecordingCapture()
        let store = RecordingStore()
        let config = PacketPipeline.Config(
            localIPv4: PipelineFixtures.localV4,
            localIPv6: localIPv6,
            tlsInspectionEnabled: tlsInspectionEnabled,
            captureEnabled: captureEnabled,
            batchSize: batchSize,
            flushInterval: flushInterval,
            anchor: anchor
        )
        let pipeline = PacketPipeline(
            flowTable: table,
            liveFeed: feed,
            capture: capture,
            store: store,
            clock: clock,
            config: config
        )
        return Harness(
            pipeline: pipeline, table: table, feed: feed,
            capture: capture, store: store, clock: clock, anchor: anchor
        )
    }

    // MARK: - Registro de punta a punta

    func testHandleRecordsOutboundPacketEverywhere() async {
        let h = makeHarness()
        let packet = PipelineFixtures.tcpV4(outbound: true, payloadBytes: 20)

        let disposition = await h.pipeline.handle(packet: packet, protocolFamily: Int32(AF_INET))

        XCTAssertPassthrough(disposition)

        // Feed en vivo: exactamente un metadato, con el sentido y la longitud del datagrama.
        let metas = h.feed.metas
        XCTAssertEqual(metas.count, 1)
        XCTAssertEqual(metas[0].direction, .outbound)
        XCTAssertEqual(metas[0].length, UInt32(packet.count))
        XCTAssertEqual(metas[0].timestamp, 1_000)
        XCTAssertEqual(metas[0].flowKey, PipelineFixtures.tcpV4Key())

        // Captura: el datagrama entero, sellado con el mismo instante del reloj pero **absoluto**.
        let written = await h.capture.written
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(written[0].originalLength, packet.count)
        XCTAssertEqual(written[0].timestamp, h.anchor.wallClockNanoseconds)

        let stats = await h.pipeline.stats
        XCTAssertEqual(stats.packetsHandled, 1)
        XCTAssertEqual(stats.packetsDropped, 0)
        XCTAssertEqual(stats.bytesHandled, UInt64(packet.count))
    }

    /// El sentido no sale de la `FlowKey` (que es canónica) sino de comparar con la IP del túnel.
    func testDirectionIsResolvedAgainstTheLocalTunnelAddress() async {
        let h = makeHarness()

        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(outbound: true), protocolFamily: Int32(AF_INET))
        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(outbound: false), protocolFamily: Int32(AF_INET))

        XCTAssertEqual(h.feed.metas.map(\.direction), [.outbound, .inbound])

        // Ambos sentidos son el mismo flujo: la tabla agrega uno solo.
        let count = await h.table.count
        XCTAssertEqual(count, 1)
    }

    func testCaptureLocationTravelsIntoTheLiveMeta() async {
        let h = makeHarness()
        let first = PipelineFixtures.tcpV4(payloadBytes: 10)

        await h.pipeline.handle(packet: first, protocolFamily: Int32(AF_INET))
        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(payloadBytes: 30), protocolFamily: Int32(AF_INET))

        // El primer registro va justo tras la cabecera global (24 B); el segundo, tras el primero.
        let locations = h.feed.metas.map(\.capture)
        XCTAssertEqual(
            locations,
            [
                CaptureLocation(fileSequence: 0, recordOffset: 24),
                CaptureLocation(fileSequence: 0, recordOffset: 24 + 16 + UInt64(first.count)),
            ]
        )

        let key = PipelineFixtures.tcpV4Key()
        await h.pipeline.flush()
        let persisted = await h.store.packets(for: key)
        XCTAssertEqual(persisted.map(\.capture), locations)
    }

    /// Al rotar, los offsets vuelven a empezar: lo que distingue a los dos registros que comparten
    /// el offset 24 es el fichero, y por eso el metadato tiene que llevar la pareja entera.
    func testCaptureLocationDistinguishesRecordsAcrossFiles() async {
        let h = makeHarness()

        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(), protocolFamily: Int32(AF_INET))
        await h.capture.rotate()
        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(), protocolFamily: Int32(AF_INET))

        XCTAssertEqual(
            h.feed.metas.map(\.capture),
            [
                CaptureLocation(fileSequence: 0, recordOffset: 24),
                CaptureLocation(fileSequence: 1, recordOffset: 24),
            ]
        )
    }

    func testCaptureDisabledLeavesNoLocationAndWritesNothing() async {
        let h = makeHarness(captureEnabled: false)

        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(), protocolFamily: Int32(AF_INET))

        XCTAssertEqual(h.feed.metas.map(\.capture), [nil])
        let written = await h.capture.written
        XCTAssertTrue(written.isEmpty)
    }

    // MARK: - Routing

    func testInspectionOffKeepsHTTPSAsPassthrough() async {
        let h = makeHarness(tlsInspectionEnabled: false)
        let disposition = await h.pipeline.handle(packet: PipelineFixtures.tcpV4(remotePort: 443), protocolFamily: Int32(AF_INET))
        XCTAssertPassthrough(disposition)
    }

    func testInspectionOnRoutesPort443TCPToInspection() async {
        let h = makeHarness(tlsInspectionEnabled: true)
        let disposition = await h.pipeline.handle(packet: PipelineFixtures.tcpV4(remotePort: 443), protocolFamily: Int32(AF_INET))
        XCTAssertInspect(disposition)
    }

    func testInspectionOnStillPassesThroughNonHTTPSAndUDP() async {
        let h = makeHarness(tlsInspectionEnabled: true)

        let plainTCP = await h.pipeline.handle(packet: PipelineFixtures.tcpV4(remotePort: 8080), protocolFamily: Int32(AF_INET))
        let udp = await h.pipeline.handle(packet: PipelineFixtures.udpV4(), protocolFamily: Int32(AF_INET))
        // UDP contra el 443 (QUIC) tampoco se termina: la ruta de inspección es TCP.
        let quic = await h.pipeline.handle(packet: PipelineFixtures.udpV4(remotePort: 443), protocolFamily: Int32(AF_INET))

        XCTAssertPassthrough(plainTCP)
        XCTAssertPassthrough(udp)
        XCTAssertPassthrough(quic)
    }

    /// La regla del ADR 0003: si un flujo rechazó nuestra CA, se relaya intacto para siempre.
    func testPinnedFlowIsNeverRoutedToInspectionAgain() async {
        let h = makeHarness(tlsInspectionEnabled: true)
        let key = PipelineFixtures.tcpV4Key()

        let before = await h.pipeline.handle(packet: PipelineFixtures.tcpV4(), protocolFamily: Int32(AF_INET))
        XCTAssertInspect(before)

        await h.table.setTLSStatus(.notInspectable, for: key, sni: "pinned.example")
        let after = await h.pipeline.handle(packet: PipelineFixtures.tcpV4(), protocolFamily: Int32(AF_INET))

        XCTAssertPassthrough(after)
    }

    func testInspectionCanBeToggledLive() async {
        let h = makeHarness(tlsInspectionEnabled: false)
        let packet = PipelineFixtures.tcpV4(remotePort: 443)

        let beforeEnabling = await h.pipeline.handle(packet: packet, protocolFamily: Int32(AF_INET))
        await h.pipeline.setTLSInspectionEnabled(true)
        let whileEnabled = await h.pipeline.handle(packet: packet, protocolFamily: Int32(AF_INET))
        await h.pipeline.setTLSInspectionEnabled(false)
        let afterDisabling = await h.pipeline.handle(packet: packet, protocolFamily: Int32(AF_INET))

        XCTAssertPassthrough(beforeEnabling)
        XCTAssertInspect(whileEnabled)
        XCTAssertPassthrough(afterDisabling)
    }

    /// Las dos rutas que reenvían llevan dentro el paquete ya parseado: es lo que el provider le
    /// entrega al relay, y sin ello tendría que volver a parsear cada datagrama del hot path.
    func testForwardingDispositionsCarryTheParsedDatagram() async {
        let h = makeHarness(tlsInspectionEnabled: true)

        let passthrough = await h.pipeline.handle(packet: PipelineFixtures.udpV4(), protocolFamily: Int32(AF_INET))
        let inspect = await h.pipeline.handle(packet: PipelineFixtures.tcpV4(remotePort: 443), protocolFamily: Int32(AF_INET))
        let dropped = await h.pipeline.handle(packet: Data([0x45, 0x00]), protocolFamily: Int32(AF_INET))

        XCTAssertEqual(passthrough.packetToRelay?.flowKey, PipelineFixtures.udpV4Key())
        XCTAssertNotNil(passthrough.packetToRelay?.udp)
        XCTAssertEqual(inspect.packetToRelay?.flowKey, PipelineFixtures.tcpV4Key())
        // El sentido que el relay asume: origen el dispositivo, destino el servidor.
        XCTAssertEqual(inspect.packetToRelay?.source.address, PipelineFixtures.localV4)
        XCTAssertEqual(inspect.packetToRelay?.destination.port, 443)
        XCTAssertNil(dropped.packetToRelay)
    }

    // MARK: - Registro de lo reinyectado

    /// Una respuesta reinyectada se clasifica `inbound` **por lo que es** —su origen no es la IP del
    /// túnel—, no porque lo diga quien la registra.
    func testReinjectedDatagramIsRecordedAsInbound() async {
        let h = makeHarness()
        let response = PipelineFixtures.tcpV4(outbound: false, payloadBytes: 40)

        await h.pipeline.record(reinjected: response, protocolFamily: Int32(AF_INET))

        XCTAssertEqual(h.feed.metas.map(\.direction), [.inbound])
        XCTAssertEqual(h.feed.metas.first?.length, UInt32(response.count))
        let stats = await h.pipeline.stats
        XCTAssertEqual(stats.packetsHandled, 1)
        XCTAssertEqual(stats.bytesHandled, UInt64(response.count))
    }

    /// El motivo de existir del registro: sin él `bytesIn` se queda a cero para siempre y la app
    /// enseña media conversación. La `FlowKey` es canónica, así que ida y vuelta caen en el mismo flujo.
    func testReinjectedBytesLandInTheSameFlowAsTheRequest() async {
        let h = makeHarness()

        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(outbound: true, payloadBytes: 10), protocolFamily: Int32(AF_INET))
        await h.pipeline.record(reinjected: PipelineFixtures.tcpV4(outbound: false, payloadBytes: 100), protocolFamily: Int32(AF_INET))
        await h.pipeline.flush()

        let flows = await h.store.flows
        let record = flows[PipelineFixtures.tcpV4Key()]
        XCTAssertNotNil(record)
        XCTAssertGreaterThan(record?.bytesOut ?? 0, 0)
        XCTAssertGreaterThan(record?.bytesIn ?? 0, 0)
        XCTAssertEqual(record?.packetCount, 2)

        // Un solo flujo, no dos: el sentido no parte la conversación en dos filas.
        let liveFlows = await h.table.count
        XCTAssertEqual(liveFlows, 1)
    }

    /// La otra mitad de lo mismo, en el `.pcap`: una captura con las preguntas y sin las respuestas
    /// no es una captura, y quien la abra en Wireshark solo ve un lado.
    func testReinjectedDatagramGoesIntoTheCapture() async {
        let h = makeHarness()

        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(outbound: true), protocolFamily: Int32(AF_INET))
        await h.pipeline.record(reinjected: PipelineFixtures.tcpV4(outbound: false), protocolFamily: Int32(AF_INET))

        let written = await h.capture.written
        XCTAssertEqual(written.count, 2)
    }

    /// El `.pcap` fecha en **hora de pared**, no en uptime: sus `ts_sec`/`ts_usec` los lee Wireshark
    /// como un instante absoluto, así que pasarle el sello monotónico del hot path dejaba toda
    /// captura exportada en 1970. Se convierte con el ancla de la sesión, la misma del store.
    func testCaptureIsStampedInWallClockAndKeepsTheSpacingBetweenPackets() async {
        let h = makeHarness()

        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(outbound: true), protocolFamily: Int32(AF_INET))
        h.clock.advance(by: 2_500_000_000)
        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(outbound: true), protocolFamily: Int32(AF_INET))

        let written = await h.capture.written
        XCTAssertEqual(written.count, 2)

        // El primero cae exactamente en la hora de pared del ancla (el reloj arranca en su uptime).
        XCTAssertEqual(written[0].timestamp, h.anchor.wallClockNanoseconds)
        // Y el segundo, 2,5 s después: la conversión es entera, así que el espaciado es exacto.
        XCTAssertEqual(written[1].timestamp - written[0].timestamp, 2_500_000_000)

        // La fecha resultante es la del ancla, no 1970: es el defecto que este test cierra.
        let date = Date(timeIntervalSince1970: Double(written[0].timestamp) / 1_000_000_000)
        XCTAssertEqual(date.timeIntervalSince1970, Self.wallClock.timeIntervalSince1970, accuracy: 0.001)
    }

    /// Un datagrama reinyectado ilegible sería un fallo de nuestro propio emisor, así que se cuenta
    /// como cualquier otro descarte en vez de tragarse.
    func testMalformedReinjectedDatagramIsDroppedAndCounted() async {
        let h = makeHarness()

        await h.pipeline.record(reinjected: Data([0x45, 0x00]), protocolFamily: Int32(AF_INET))

        XCTAssertTrue(h.feed.pushed.isEmpty)
        let stats = await h.pipeline.stats
        XCTAssertEqual(stats.packetsDropped, 1)
        XCTAssertEqual(stats.packetsHandled, 0)
    }

    /// Efecto secundario que el registro desbloquea: hasta ahora la tabla nunca veía el FIN de vuelta
    /// —lo que entra al dispositivo no pasaba por aquí—, así que un cierre TCP limpio no cerraba nada
    /// y el flujo esperaba a la inactividad. Ahora se cierra cuando de verdad se cierra.
    func testInboundFinFromTheRelayClosesTheFlow() async {
        let h = makeHarness()

        // 0x11 = FIN|ACK en los dos sentidos.
        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(outbound: true, flagsByte: 0x11), protocolFamily: Int32(AF_INET))
        await h.pipeline.record(reinjected: PipelineFixtures.tcpV4(outbound: false, flagsByte: 0x11), protocolFamily: Int32(AF_INET))
        await h.pipeline.flush()

        let closed = await h.pipeline.drainClosedFlowKeys()
        XCTAssertEqual(closed, [PipelineFixtures.tcpV4Key()])
        let liveFlows = await h.table.count
        XCTAssertEqual(liveFlows, 0)
    }

    // MARK: - Cierre de flujos (lo que el provider le cierra al relay)

    /// Un RST cierra el flujo en la tabla, y su clave tiene que llegar al provider para que suelte
    /// la conexión saliente que el relay mantenga por él.
    func testFlowClosedByResetSurfacesItsKeyOnce() async {
        let h = makeHarness()

        // 0x14 = RST|ACK.
        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(flagsByte: 0x14), protocolFamily: Int32(AF_INET))
        await h.pipeline.flush()

        let closed = await h.pipeline.drainClosedFlowKeys()
        XCTAssertEqual(closed, [PipelineFixtures.tcpV4Key()])

        // Drenar vacía: leerlo dos veces no puede hacer que el provider cierre dos veces lo mismo
        // (y lo segundo que cierre podría ser ya otro flujo con la misma 5-tupla).
        let again = await h.pipeline.drainClosedFlowKeys()
        XCTAssertTrue(again.isEmpty)
    }

    /// El caso que de verdad lo justifica: un flujo UDP no se cierra nunca solo —nadie manda un FIN
    /// en UDP—, así que sin la expiración por inactividad su `NWConnection` viviría para siempre.
    func testIdleUDPFlowSurfacesItsKeyOnTick() async {
        let h = makeHarness(idleTimeout: 10_000)

        await h.pipeline.handle(packet: PipelineFixtures.udpV4(), protocolFamily: Int32(AF_INET))
        let whileAlive = await h.pipeline.drainClosedFlowKeys()
        XCTAssertTrue(whileAlive.isEmpty)

        h.clock.set(1_000 + 20_000)
        await h.pipeline.tick()

        let closed = await h.pipeline.drainClosedFlowKeys()
        XCTAssertEqual(closed, [PipelineFixtures.udpV4Key()])
    }

    /// La evicción LRU también termina un flujo, y ocurre dentro del hot path (no en el tick): su
    /// clave viaja por el mismo sitio que las demás.
    func testEvictedFlowSurfacesItsKey() async {
        let h = makeHarness(maxFlows: 1)

        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(localPort: 51000), protocolFamily: Int32(AF_INET))
        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(localPort: 51001), protocolFamily: Int32(AF_INET))
        await h.pipeline.flush()

        let closed = await h.pipeline.drainClosedFlowKeys()
        XCTAssertEqual(closed, [PipelineFixtures.tcpV4Key(localPort: 51000)])
    }

    /// Un flujo vivo no se cierra: el relay no puede perder la conexión de una conversación en curso.
    func testLiveFlowsAreNotSurfacedAsClosed() async {
        let h = makeHarness()

        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(), protocolFamily: Int32(AF_INET))
        await h.pipeline.flush()
        await h.pipeline.tick()

        let closed = await h.pipeline.drainClosedFlowKeys()
        XCTAssertTrue(closed.isEmpty)
    }

    // MARK: - Descartes

    func testMalformedPacketIsDroppedAndCountedWithoutTouchingAnySink() async {
        let h = makeHarness()

        let disposition = await h.pipeline.handle(packet: Data([0x45, 0x00]), protocolFamily: Int32(AF_INET))

        guard case .dropped(.parseFailed) = disposition else {
            return XCTFail("Se esperaba un descarte por parseo, no \(disposition)")
        }
        XCTAssertTrue(h.feed.pushed.isEmpty)
        let written = await h.capture.written
        XCTAssertTrue(written.isEmpty)
        let stats = await h.pipeline.stats
        XCTAssertEqual(stats.packetsDropped, 1)
        XCTAssertEqual(stats.packetsHandled, 0)
    }

    /// Sin IP local IPv6 no se puede saber el sentido de un paquete IPv6, así que se descarta en
    /// vez de adivinar (y contaminar el histórico con sentidos invertidos).
    func testIPv6WithoutLocalIPv6IsDropped() async {
        let h = makeHarness(localIPv6: nil)

        let disposition = await h.pipeline.handle(packet: PipelineFixtures.tcpV6(), protocolFamily: Int32(AF_INET6))

        XCTAssertEqual(disposition, .dropped(.noLocalAddress(.v6)))
        XCTAssertTrue(h.feed.pushed.isEmpty)
    }

    func testIPv6IsHandledWhenTheTunnelHasAnIPv6Address() async {
        let h = makeHarness(tlsInspectionEnabled: true, localIPv6: PipelineFixtures.localV6)

        let disposition = await h.pipeline.handle(packet: PipelineFixtures.tcpV6(), protocolFamily: Int32(AF_INET6))

        XCTAssertInspect(disposition)
        XCTAssertEqual(h.feed.metas.map(\.direction), [.outbound])
    }

    // MARK: - Volcado por lotes

    func testStoreIsNotTouchedUntilTheBatchFills() async {
        let h = makeHarness(batchSize: 4, flushInterval: .max)

        for _ in 0..<3 {
            await h.pipeline.handle(packet: PipelineFixtures.tcpV4(), protocolFamily: Int32(AF_INET))
        }
        var upserts = await h.store.upsertCount
        XCTAssertEqual(upserts, 0)
        var pending = await h.pipeline.pendingPacketCount
        XCTAssertEqual(pending, 3)

        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(), protocolFamily: Int32(AF_INET))

        upserts = await h.store.upsertCount
        pending = await h.pipeline.pendingPacketCount
        XCTAssertEqual(upserts, 1)          // un solo upsert para los 4 paquetes del mismo flujo
        XCTAssertEqual(pending, 0)
        let persisted = await h.store.packets(for: PipelineFixtures.tcpV4Key())
        XCTAssertEqual(persisted.count, 4)

        let stats = await h.pipeline.stats
        XCTAssertEqual(stats.flowsPersisted, 1)
        XCTAssertEqual(stats.packetsPersisted, 4)
    }

    func testBatchGroupsPacketsByFlow() async {
        let h = makeHarness(batchSize: 4, flushInterval: .max)

        for port in [UInt16(51000), UInt16(51001)] {
            await h.pipeline.handle(packet: PipelineFixtures.tcpV4(localPort: port), protocolFamily: Int32(AF_INET))
            await h.pipeline.handle(packet: PipelineFixtures.tcpV4(localPort: port), protocolFamily: Int32(AF_INET))
        }

        let upserts = await h.store.upsertCount
        XCTAssertEqual(upserts, 2)          // dos flujos, un upsert cada uno
        let first = await h.store.packets(for: PipelineFixtures.tcpV4Key(localPort: 51000))
        let second = await h.store.packets(for: PipelineFixtures.tcpV4Key(localPort: 51001))
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(second.count, 2)
    }

    /// Un flujo lento no puede quedarse fuera del historial esperando a llenar el lote.
    func testFlushIsForcedByTheIntervalEvenWithAnUnfilledBatch() async {
        let h = makeHarness(batchSize: 1_000, flushInterval: 100)

        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(), protocolFamily: Int32(AF_INET))
        var upserts = await h.store.upsertCount
        XCTAssertEqual(upserts, 0)

        h.clock.advance(by: 100)
        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(), protocolFamily: Int32(AF_INET))

        upserts = await h.store.upsertCount
        XCTAssertEqual(upserts, 1)
        let persisted = await h.store.packets(for: PipelineFixtures.tcpV4Key())
        XCTAssertEqual(persisted.count, 2)
    }

    /// El record final de un flujo cerrado (RST) llega al store con sus totales, aunque sus
    /// paquetes ya se hubieran volcado en un lote anterior.
    func testClosedFlowFinalRecordReachesTheStore() async {
        let h = makeHarness(batchSize: 1, flushInterval: .max)
        let key = PipelineFixtures.tcpV4Key()

        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(payloadBytes: 8), protocolFamily: Int32(AF_INET))
        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(flagsByte: 0x04), protocolFamily: Int32(AF_INET))  // RST
        await h.pipeline.flush()

        let record = await h.store.flows[key]
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.packetCount, 2)
        // El flujo ya no ocupa memoria en la tabla.
        let live = await h.table.count
        XCTAssertEqual(live, 0)
    }

    // MARK: - Nombre de un flujo (SNI)

    /// Lo que el relay lee del ClientHello acaba en el historial: es lo que hace que la Timeline
    /// enseñe un nombre y no una dirección.
    func testObservedSNIReachesTheStore() async {
        let h = makeHarness(batchSize: 1_000, flushInterval: .max)
        let key = PipelineFixtures.tcpV4Key()

        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(), protocolFamily: Int32(AF_INET))
        await h.pipeline.observe(sni: "www.example.com", for: key)
        // El siguiente paquete del flujo ya arrastra el record con el nombre puesto.
        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(payloadBytes: 8), protocolFamily: Int32(AF_INET))
        await h.pipeline.flush()

        let record = await h.store.flows[key]
        XCTAssertEqual(record?.sni, "www.example.com")
        // Tener nombre no es haber sido inspeccionado.
        XCTAssertEqual(record?.tlsStatus, .encrypted)
    }

    /// Un flujo que se cierra justo después del handshake también llega con nombre: el record de
    /// cierre pasa por el mismo embudo, así que no hace falta que llegue otro paquete.
    func testObservedSNIReachesTheStoreEvenIfTheFlowClosesRightAfter() async {
        let h = makeHarness(batchSize: 1_000, flushInterval: .max)
        let key = PipelineFixtures.tcpV4Key()

        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(), protocolFamily: Int32(AF_INET))
        await h.pipeline.observe(sni: "www.example.com", for: key)
        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(flagsByte: 0x04), protocolFamily: Int32(AF_INET))  // RST
        await h.pipeline.flush()

        let record = await h.store.flows[key]
        XCTAssertEqual(record?.sni, "www.example.com")
    }

    // MARK: - Desenlace de la inspección de un flujo

    /// La otra mitad del enganche: lo que el relay decide sobre una terminación acaba en el historial,
    /// que es donde la pantalla del flujo lee si se descifró o no.
    func testObservedTLSStatusReachesTheStore() async {
        let h = makeHarness(tlsInspectionEnabled: true, batchSize: 1_000, flushInterval: .max)
        let key = PipelineFixtures.tcpV4Key()

        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(), protocolFamily: Int32(AF_INET))
        await h.pipeline.observe(sni: "www.example.com", for: key)
        await h.pipeline.observe(tlsStatus: TLSInspectionStatus.inspected, for: key)
        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(payloadBytes: 8), protocolFamily: Int32(AF_INET))
        await h.pipeline.flush()

        let record = await h.store.flows[key]
        XCTAssertEqual(record?.tlsStatus, .inspected)
        // Y no se lleva por delante el nombre, que llegó por la otra costura.
        XCTAssertEqual(record?.sni, "www.example.com")
    }

    /// El invariante del ADR 0003 recorrido entero por la costura que lo trae: un cliente que pinnea
    /// marca su flujo, y desde el paquete siguiente ese flujo deja de enrutarse a inspección.
    func testAFlowReportedNotInspectableStopsBeingRoutedToInspection() async {
        let h = makeHarness(tlsInspectionEnabled: true)
        let key = PipelineFixtures.tcpV4Key()

        let before = await h.pipeline.handle(packet: PipelineFixtures.tcpV4(), protocolFamily: Int32(AF_INET))
        XCTAssertInspect(before)

        await h.pipeline.observe(tlsStatus: .notInspectable, for: key)
        let after = await h.pipeline.handle(packet: PipelineFixtures.tcpV4(), protocolFamily: Int32(AF_INET))

        XCTAssertPassthrough(after)
    }

    func testTickExpiresIdleFlowsAndPersistsThem() async {
        let h = makeHarness(batchSize: 1_000, flushInterval: .max, idleTimeout: 1_000)

        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(), protocolFamily: Int32(AF_INET))
        h.clock.advance(by: 5_000)
        await h.pipeline.tick()

        let live = await h.table.count
        XCTAssertEqual(live, 0)
        let record = await h.store.flows[PipelineFixtures.tcpV4Key()]
        XCTAssertEqual(record?.packetCount, 1)
        let persisted = await h.store.packets(for: PipelineFixtures.tcpV4Key())
        XCTAssertEqual(persisted.count, 1)
    }

    func testShutdownFlushesPendingWorkAndSyncsTheCapture() async {
        let h = makeHarness(batchSize: 1_000, flushInterval: .max)

        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(), protocolFamily: Int32(AF_INET))
        await h.pipeline.shutdown()

        let persisted = await h.store.packets(for: PipelineFixtures.tcpV4Key())
        XCTAssertEqual(persisted.count, 1)
        let flushes = await h.capture.flushCount
        XCTAssertEqual(flushes, 1)
        let pending = await h.pipeline.pendingPacketCount
        XCTAssertEqual(pending, 0)
    }

    // MARK: - Degradación ante fallos

    /// Un disco lleno apaga la captura, pero el tráfico y el feed en vivo siguen.
    func testCaptureFailureDisablesCaptureWithoutStoppingTheHotPath() async {
        let h = makeHarness()
        await h.capture.failNextWrites(true)

        let disposition = await h.pipeline.handle(packet: PipelineFixtures.tcpV4(), protocolFamily: Int32(AF_INET))
        XCTAssertPassthrough(disposition)

        var stats = await h.pipeline.stats
        XCTAssertEqual(stats.captureFailures, 1)
        XCTAssertNotNil(stats.lastCaptureError)
        XCTAssertEqual(stats.packetsHandled, 1)
        XCTAssertEqual(h.feed.metas.map(\.capture), [nil])

        // Ya no se reintenta: el segundo paquete ni siquiera llama al writer, así que aunque el
        // disco vuelva, la captura sigue apagada hasta que la app la rearme.
        await h.capture.failNextWrites(false)
        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(), protocolFamily: Int32(AF_INET))
        var written = await h.capture.written
        XCTAssertTrue(written.isEmpty)
        stats = await h.pipeline.stats
        XCTAssertEqual(stats.captureFailures, 1)

        await h.pipeline.setCaptureEnabled(true)
        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(), protocolFamily: Int32(AF_INET))
        written = await h.capture.written
        XCTAssertEqual(written.count, 1)
    }

    /// El store puede caerse sin llevarse el túnel por delante: el lote se pierde, se cuenta, y no
    /// se reencola (reintentar haría crecer la memoria de la extensión sin tope).
    func testStoreFailureIsCountedAndTheBatchIsDroppedNotRetained() async {
        let h = makeHarness(batchSize: 2, flushInterval: .max)
        await h.store.fail(true)

        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(), protocolFamily: Int32(AF_INET))
        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(), protocolFamily: Int32(AF_INET))

        var stats = await h.pipeline.stats
        XCTAssertEqual(stats.storeFailures, 1)
        XCTAssertNotNil(stats.lastStoreError)
        XCTAssertEqual(stats.packetsPersisted, 0)
        var pending = await h.pipeline.pendingPacketCount
        XCTAssertEqual(pending, 0)

        // El feed en vivo no depende del store: el usuario siguió viendo su tráfico.
        XCTAssertEqual(h.feed.metas.count, 2)

        // Y cuando el store vuelve, el lote siguiente se persiste con normalidad.
        await h.store.fail(false)
        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(), protocolFamily: Int32(AF_INET))
        await h.pipeline.handle(packet: PipelineFixtures.tcpV4(), protocolFamily: Int32(AF_INET))
        stats = await h.pipeline.stats
        XCTAssertEqual(stats.storeFailures, 1)
        XCTAssertEqual(stats.packetsPersisted, 2)
        pending = await h.pipeline.pendingPacketCount
        XCTAssertEqual(pending, 0)
    }

    // MARK: - Carga sostenida

    /// 5.000 paquetes sobre 50 flujos: nada se pierde, el lote nunca crece por encima de su tope
    /// y cada sumidero ve exactamente lo que le toca.
    func testSustainedLoadKeepsEveryRecordAndBoundsTheBatch() async {
        let h = makeHarness(batchSize: 64, flushInterval: .max)
        let flowCount = 50
        let perFlow = 100

        for round in 0..<perFlow {
            for flow in 0..<flowCount {
                let port = UInt16(52_000 + flow)
                let packet = PipelineFixtures.tcpV4(outbound: round.isMultiple(of: 2), localPort: port)
                await h.pipeline.handle(packet: packet, protocolFamily: Int32(AF_INET))
                let pending = await h.pipeline.pendingPacketCount
                XCTAssertLessThan(pending, 64)
            }
        }
        await h.pipeline.flush()

        let total = flowCount * perFlow
        XCTAssertEqual(h.feed.metas.count, total)
        let written = await h.capture.written
        XCTAssertEqual(written.count, total)
        let persisted = await h.store.totalPackets
        XCTAssertEqual(persisted, total)

        let stats = await h.pipeline.stats
        XCTAssertEqual(stats.packetsHandled, UInt64(total))
        XCTAssertEqual(stats.packetsPersisted, UInt64(total))
        XCTAssertEqual(stats.storeFailures, 0)
        XCTAssertEqual(stats.captureFailures, 0)

        // Un flujo por puerto local, con sus dos sentidos agregados en el mismo record.
        let record = await h.store.flows[PipelineFixtures.tcpV4Key(localPort: 52_000)]
        XCTAssertEqual(record?.packetCount, UInt64(perFlow))
        let live = await h.table.count
        XCTAssertEqual(live, flowCount)
    }
}
