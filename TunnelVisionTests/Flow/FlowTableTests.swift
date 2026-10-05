import Foundation
import XCTest
import Shared

/// Tests de la tabla de flujos (M4). Cubren: agregación de bytes/paquetes por sentido, evicción
/// LRU emitiendo el `FlowRecord` correcto, refresco del LRU al reutilizar un flujo, cierre por
/// RST y por FIN bidireccional, expiración por inactividad, estado TLS inicial y fijado, y que una
/// tormenta de 10k flujos mantenga la tabla acotada a `maxFlows`.
final class FlowTableTests: XCTestCase {

    private func local(_ port: UInt16) -> IPEndpoint { FlowFixtures.endpoint(FlowFixtures.localV4, port) }
    private func remote(_ port: UInt16) -> IPEndpoint { FlowFixtures.endpoint(FlowFixtures.remoteV4, port) }

    // MARK: - Agregación

    func testObserveAggregatesBothDirections() async {
        let table = FlowTable(config: .init(), clock: ManualClock())
        let out = FlowFixtures.tcp(source: local(51000), destination: remote(443))
        let inbound = FlowFixtures.tcp(source: remote(443), destination: local(51000))

        _ = await table.observe(out, direction: .outbound, length: 100, resolvedName: nil)
        let live = await table.observe(inbound, direction: .inbound, length: 40, resolvedName: nil)

        XCTAssertEqual(live.record.bytesOut, 100)
        XCTAssertEqual(live.record.bytesIn, 40)
        XCTAssertEqual(live.record.packetCount, 2)
        let count = await table.count
        XCTAssertEqual(count, 1)   // ambos sentidos son el mismo flujo canónico
    }

    // MARK: - Estado TLS

    func testInitialTLSStatus() async {
        let table = FlowTable(config: .init(), clock: ManualClock())
        let https = await table.observe(FlowFixtures.tcp(source: local(51000), destination: remote(443)), direction: .outbound, length: 60, resolvedName: nil)
        XCTAssertEqual(https.record.tlsStatus, .encrypted)

        let http = await table.observe(FlowFixtures.tcp(source: local(51001), destination: remote(80)), direction: .outbound, length: 60, resolvedName: nil)
        XCTAssertEqual(http.record.tlsStatus, .plaintext)

        let dns = await table.observe(FlowFixtures.udp(source: local(51002), destination: remote(53)), direction: .outbound, length: 60, resolvedName: nil)
        XCTAssertEqual(dns.record.tlsStatus, .plaintext)
    }

    func testSetTLSStatusUpdatesFlow() async {
        let table = FlowTable(config: .init(), clock: ManualClock())
        let packet = FlowFixtures.tcp(source: local(51000), destination: remote(443))
        _ = await table.observe(packet, direction: .outbound, length: 60, resolvedName: nil)

        await table.setTLSStatus(.inspected, for: packet.flowKey, sni: "example.com")
        let live = await table.observe(packet, direction: .outbound, length: 60, resolvedName: nil)

        XCTAssertEqual(live.record.tlsStatus, .inspected)
        XCTAssertEqual(live.record.sni, "example.com")
    }

    /// El nombre que el relay lee del ClientHello **no** asciende al flujo a inspeccionado: saber a
    /// quién llama es gratis y no implica haber descifrado nada.
    func testSetSNINamesTheFlowWithoutChangingItsTLSStatus() async {
        let table = FlowTable(config: .init(), clock: ManualClock())
        let packet = FlowFixtures.tcp(source: local(51000), destination: remote(443))
        _ = await table.observe(packet, direction: .outbound, length: 60, resolvedName: nil)

        await table.setSNI("www.example.com", for: packet.flowKey)
        let live = await table.observe(packet, direction: .outbound, length: 60, resolvedName: nil)

        XCTAssertEqual(live.record.sni, "www.example.com")
        XCTAssertEqual(live.record.tlsStatus, .encrypted)
    }

    /// El nombre llega por una tarea aparte, así que puede llegar tarde: el flujo ya cerrado no
    /// existe, y anotarlo no puede resucitarlo ni tocar a quien reutilice esa 5-tupla después.
    func testSetSNIOnAnUnknownFlowIsANoOp() async {
        let table = FlowTable(config: .init(), clock: ManualClock())
        let packet = FlowFixtures.tcp(source: local(51000), destination: remote(443))

        await table.setSNI("www.example.com", for: packet.flowKey)

        let count = await table.count
        XCTAssertEqual(count, 0)
        let live = await table.observe(packet, direction: .outbound, length: 60, resolvedName: nil)
        XCTAssertNil(live.record.sni)
    }

    /// El flujo cerrado se lleva su nombre puesto al store: es el último record el que se vuelca.
    func testClosedFlowCarriesItsName() async {
        let table = FlowTable(config: .init(), clock: ManualClock())
        let packet = FlowFixtures.tcp(source: local(51000), destination: remote(443), flags: [.rst])
        let opening = FlowFixtures.tcp(source: local(51000), destination: remote(443))
        _ = await table.observe(opening, direction: .outbound, length: 60, resolvedName: nil)

        await table.setSNI("www.example.com", for: opening.flowKey)
        _ = await table.observe(packet, direction: .outbound, length: 60, resolvedName: nil)

        let closed = await table.drainClosed()
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed.first?.sni, "www.example.com")
    }

    // MARK: - Respuesta TLS del servidor

    private static let tls13 = ServerTLSAnswer.negotiated(
        NegotiatedTLS(version: .tls13, cipherSuite: TLSCipherSuite(rawValue: 0x1301), fromHelloRetryRequest: false)
    )

    /// Lo que el servidor contestó se apunta sin tocar ni el estado de inspección ni el nombre: es
    /// otra lectura de bytes en claro, y haberla hecho no es haber descifrado nada.
    func testSetServerTLSRecordsTheAnswerWithoutChangingStatusOrName() async {
        let table = FlowTable(config: .init(), clock: ManualClock())
        let packet = FlowFixtures.tcp(source: local(51000), destination: remote(443))
        _ = await table.observe(packet, direction: .outbound, length: 60, resolvedName: nil)
        await table.setSNI("www.example.com", for: packet.flowKey)

        await table.setServerTLS(Self.tls13, for: packet.flowKey)
        let live = await table.observe(packet, direction: .inbound, length: 60, resolvedName: nil)

        XCTAssertEqual(live.record.serverTLS, Self.tls13)
        XCTAssertEqual(live.record.tlsStatus, .encrypted)
        XCTAssertEqual(live.record.sni, "www.example.com")
    }

    func testAFlowStartsWithoutAServerAnswer() async {
        let table = FlowTable(config: .init(), clock: ManualClock())
        let packet = FlowFixtures.tcp(source: local(51000), destination: remote(443))

        let live = await table.observe(packet, direction: .outbound, length: 60, resolvedName: nil)

        XCTAssertNil(live.record.serverTLS)
    }

    /// Llega por una tarea aparte, como el nombre, así que puede llegar con el flujo ya cerrado:
    /// no lo resucita ni se lo apunta a quien reutilice esa 5-tupla después.
    func testSetServerTLSOnAnUnknownFlowIsANoOp() async {
        let table = FlowTable(config: .init(), clock: ManualClock())
        let packet = FlowFixtures.tcp(source: local(51000), destination: remote(443))

        await table.setServerTLS(.refused(alert: 70), for: packet.flowKey)

        let count = await table.count
        XCTAssertEqual(count, 0)
        let live = await table.observe(packet, direction: .outbound, length: 60, resolvedName: nil)
        XCTAssertNil(live.record.serverTLS)
    }

    /// Una conexión que el servidor rechaza se cierra enseguida: el record de cierre es el único
    /// que va a llegar al store, y tiene que llevar la negativa puesta.
    func testClosedFlowCarriesItsServerAnswer() async {
        let table = FlowTable(config: .init(), clock: ManualClock())
        let opening = FlowFixtures.tcp(source: local(51000), destination: remote(443))
        let reset = FlowFixtures.tcp(source: local(51000), destination: remote(443), flags: [.rst])
        _ = await table.observe(opening, direction: .outbound, length: 60, resolvedName: nil)

        await table.setServerTLS(.refused(alert: 70), for: opening.flowKey)
        _ = await table.observe(reset, direction: .outbound, length: 60, resolvedName: nil)

        let closed = await table.drainClosed()
        XCTAssertEqual(closed.first?.serverTLS, .refused(alert: 70))
    }

    // MARK: - Nombre resuelto por DNS

    /// El nombre se fija al crear el flujo: el que llega con sus paquetes siguientes no lo cambia.
    func testAFlowKeepsTheResolvedNameItWasCreatedWith() async {
        let table = FlowTable(config: .init(), clock: ManualClock())
        let packet = FlowFixtures.udp(source: local(51000), destination: remote(443))
        let first = ResolvedFlowName(name: "api.example.com", otherNames: ["cdn.example.net"])
        let later = ResolvedFlowName(name: "other.example.com", otherNames: [])

        let created = await table.observe(packet, direction: .outbound, length: 60, resolvedName: first)
        let updated = await table.observe(packet, direction: .outbound, length: 60, resolvedName: later)

        XCTAssertEqual(created.record.resolvedName, first)
        XCTAssertEqual(updated.record.resolvedName, first)
    }

    /// Y uno que nació sin nombre no lo adquiere después: la respuesta que llega tarde no dice a
    /// qué nombre iba una conexión que ya estaba abierta.
    func testAFlowCreatedWithoutANameDoesNotAcquireOneLater() async {
        let table = FlowTable(config: .init(), clock: ManualClock())
        let packet = FlowFixtures.udp(source: local(51000), destination: remote(443))

        _ = await table.observe(packet, direction: .outbound, length: 60, resolvedName: nil)
        let live = await table.observe(
            packet, direction: .outbound, length: 60,
            resolvedName: ResolvedFlowName(name: "api.example.com", otherNames: [])
        )

        XCTAssertNil(live.record.resolvedName)
    }

    /// El record de cierre lo lleva también, aunque el flujo muera en su primer paquete.
    func testTheClosingRecordCarriesTheResolvedName() async {
        let table = FlowTable(config: .init(), clock: ManualClock())
        let name = ResolvedFlowName(name: "api.example.com", otherNames: [])
        let reset = FlowFixtures.tcp(source: local(51000), destination: remote(443), flags: [.rst])

        _ = await table.observe(reset, direction: .outbound, length: 40, resolvedName: name)

        let closed = await table.drainClosed()
        XCTAssertEqual(closed.map(\.resolvedName), [name])
    }

    /// El SNI y el nombre resuelto son campos distintos y ninguno pisa al otro.
    func testTheSNIAndTheResolvedNameAreKeptApart() async {
        let table = FlowTable(config: .init(), clock: ManualClock())
        let packet = FlowFixtures.tcp(source: local(51000), destination: remote(443))
        let name = ResolvedFlowName(name: "api.example.com", otherNames: [])

        _ = await table.observe(packet, direction: .outbound, length: 60, resolvedName: name)
        await table.setSNI("www.example.com", for: packet.flowKey)

        let record = await table.record(for: packet.flowKey)
        XCTAssertEqual(record?.sni, "www.example.com")
        XCTAssertEqual(record?.resolvedName, name)
    }

    // MARK: - Cierre

    func testRSTClosesImmediately() async {
        let table = FlowTable(config: .init(), clock: ManualClock())
        let packet = FlowFixtures.tcp(source: local(51000), destination: remote(443), flags: [.rst])
        _ = await table.observe(packet, direction: .inbound, length: 60, resolvedName: nil)

        let count = await table.count
        XCTAssertEqual(count, 0)
        let closed = await table.drainClosed()
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed.first?.key, packet.flowKey)
    }

    func testFinInBothDirectionsCloses() async {
        let table = FlowTable(config: .init(), clock: ManualClock())
        let finOut = FlowFixtures.tcp(source: local(51000), destination: remote(443), flags: [.fin, .ack])
        let finIn = FlowFixtures.tcp(source: remote(443), destination: local(51000), flags: [.fin, .ack])

        _ = await table.observe(finOut, direction: .outbound, length: 60, resolvedName: nil)
        var count = await table.count
        XCTAssertEqual(count, 1, "un solo FIN no cierra el flujo")

        _ = await table.observe(finIn, direction: .inbound, length: 60, resolvedName: nil)
        count = await table.count
        XCTAssertEqual(count, 0)
        let closed = await table.drainClosed()
        XCTAssertEqual(closed.count, 1)
    }

    // MARK: - LRU

    func testLRUEvictionEmitsRecord() async {
        let table = FlowTable(config: .init(maxFlows: 2), clock: ManualClock())
        _ = await table.observe(FlowFixtures.tcp(source: local(1), destination: remote(443)), direction: .outbound, length: 10, resolvedName: nil)
        _ = await table.observe(FlowFixtures.tcp(source: local(2), destination: remote(443)), direction: .outbound, length: 20, resolvedName: nil)
        // El tercer flujo desborda: evicta el LRU (el flujo 1).
        _ = await table.observe(FlowFixtures.tcp(source: local(3), destination: remote(443)), direction: .outbound, length: 30, resolvedName: nil)

        let count = await table.count
        XCTAssertEqual(count, 2)
        let closed = await table.drainClosed()
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed.first?.bytesOut, 10)   // el flujo 1 era el LRU
    }

    func testReuseRefreshesLRU() async {
        let table = FlowTable(config: .init(maxFlows: 2), clock: ManualClock())
        let flow1 = FlowFixtures.tcp(source: local(1), destination: remote(443))
        _ = await table.observe(flow1, direction: .outbound, length: 10, resolvedName: nil)
        _ = await table.observe(FlowFixtures.tcp(source: local(2), destination: remote(443)), direction: .outbound, length: 20, resolvedName: nil)
        // Reusar el flujo 1 lo pasa al frente; ahora el LRU es el flujo 2.
        _ = await table.observe(flow1, direction: .outbound, length: 5, resolvedName: nil)
        _ = await table.observe(FlowFixtures.tcp(source: local(3), destination: remote(443)), direction: .outbound, length: 30, resolvedName: nil)

        let closed = await table.drainClosed()
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed.first?.bytesOut, 20)   // se evictó el flujo 2, no el 1
    }

    // MARK: - Inactividad

    func testExpireIdleClosesStaleFlows() async {
        let clock = ManualClock(0)
        let table = FlowTable(config: .init(idleTimeout: 1_000), clock: clock)
        _ = await table.observe(FlowFixtures.tcp(source: local(1), destination: remote(443)), direction: .outbound, length: 10, resolvedName: nil)

        // Aún fresco: no expira.
        var expired = await table.expireIdle(now: 500)
        XCTAssertTrue(expired.isEmpty)
        var count = await table.count
        XCTAssertEqual(count, 1)

        // Pasado el timeout: expira y sale de la tabla.
        expired = await table.expireIdle(now: 1_000)
        XCTAssertEqual(expired.count, 1)
        count = await table.count
        XCTAssertEqual(count, 0)
    }

    func testExpireIdleKeepsRecentFlow() async {
        let clock = ManualClock(0)
        let table = FlowTable(config: .init(idleTimeout: 1_000), clock: clock)
        _ = await table.observe(FlowFixtures.tcp(source: local(1), destination: remote(443)), direction: .outbound, length: 10, resolvedName: nil)
        clock.set(900)
        // Un segundo flujo más nuevo no debe expirar aunque el primero sí.
        _ = await table.observe(FlowFixtures.tcp(source: local(2), destination: remote(443)), direction: .outbound, length: 10, resolvedName: nil)

        let expired = await table.expireIdle(now: 1_000)
        XCTAssertEqual(expired.count, 1)                    // solo el primero (visto en t=0)
        let count = await table.count
        XCTAssertEqual(count, 1)
    }

    // MARK: - Cota de memoria

    func test10kFlowStormStaysBounded() async {
        let maxFlows = 4096
        let table = FlowTable(config: .init(maxFlows: maxFlows), clock: ManualClock())
        for i in 0..<10_000 {
            let packet = FlowFixtures.tcp(source: local(UInt16(20_000 + i)), destination: remote(443))
            _ = await table.observe(packet, direction: .outbound, length: 40, resolvedName: nil)
        }
        let count = await table.count
        XCTAssertEqual(count, maxFlows, "la tabla nunca supera su tope duro")
        let closed = await table.drainClosed()
        XCTAssertEqual(closed.count, 10_000 - maxFlows, "todos los flujos evictados se emiten para volcarlos")
    }
}
