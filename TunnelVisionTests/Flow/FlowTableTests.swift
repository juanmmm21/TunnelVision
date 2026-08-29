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

        _ = await table.observe(out, direction: .outbound, length: 100)
        let live = await table.observe(inbound, direction: .inbound, length: 40)

        XCTAssertEqual(live.record.bytesOut, 100)
        XCTAssertEqual(live.record.bytesIn, 40)
        XCTAssertEqual(live.record.packetCount, 2)
        let count = await table.count
        XCTAssertEqual(count, 1)   // ambos sentidos son el mismo flujo canónico
    }

    // MARK: - Estado TLS

    func testInitialTLSStatus() async {
        let table = FlowTable(config: .init(), clock: ManualClock())
        let https = await table.observe(FlowFixtures.tcp(source: local(51000), destination: remote(443)), direction: .outbound, length: 60)
        XCTAssertEqual(https.record.tlsStatus, .encrypted)

        let http = await table.observe(FlowFixtures.tcp(source: local(51001), destination: remote(80)), direction: .outbound, length: 60)
        XCTAssertEqual(http.record.tlsStatus, .plaintext)

        let dns = await table.observe(FlowFixtures.udp(source: local(51002), destination: remote(53)), direction: .outbound, length: 60)
        XCTAssertEqual(dns.record.tlsStatus, .plaintext)
    }

    func testSetTLSStatusUpdatesFlow() async {
        let table = FlowTable(config: .init(), clock: ManualClock())
        let packet = FlowFixtures.tcp(source: local(51000), destination: remote(443))
        _ = await table.observe(packet, direction: .outbound, length: 60)

        await table.setTLSStatus(.inspected, for: packet.flowKey, sni: "example.com")
        let live = await table.observe(packet, direction: .outbound, length: 60)

        XCTAssertEqual(live.record.tlsStatus, .inspected)
        XCTAssertEqual(live.record.sni, "example.com")
    }

    /// El nombre que el relay lee del ClientHello **no** asciende al flujo a inspeccionado: saber a
    /// quién llama es gratis y no implica haber descifrado nada.
    func testSetSNINamesTheFlowWithoutChangingItsTLSStatus() async {
        let table = FlowTable(config: .init(), clock: ManualClock())
        let packet = FlowFixtures.tcp(source: local(51000), destination: remote(443))
        _ = await table.observe(packet, direction: .outbound, length: 60)

        await table.setSNI("www.example.com", for: packet.flowKey)
        let live = await table.observe(packet, direction: .outbound, length: 60)

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
        let live = await table.observe(packet, direction: .outbound, length: 60)
        XCTAssertNil(live.record.sni)
    }

    /// El flujo cerrado se lleva su nombre puesto al store: es el último record el que se vuelca.
    func testClosedFlowCarriesItsName() async {
        let table = FlowTable(config: .init(), clock: ManualClock())
        let packet = FlowFixtures.tcp(source: local(51000), destination: remote(443), flags: [.rst])
        let opening = FlowFixtures.tcp(source: local(51000), destination: remote(443))
        _ = await table.observe(opening, direction: .outbound, length: 60)

        await table.setSNI("www.example.com", for: opening.flowKey)
        _ = await table.observe(packet, direction: .outbound, length: 60)

        let closed = await table.drainClosed()
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed.first?.sni, "www.example.com")
    }

    // MARK: - Cierre

    func testRSTClosesImmediately() async {
        let table = FlowTable(config: .init(), clock: ManualClock())
        let packet = FlowFixtures.tcp(source: local(51000), destination: remote(443), flags: [.rst])
        _ = await table.observe(packet, direction: .inbound, length: 60)

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

        _ = await table.observe(finOut, direction: .outbound, length: 60)
        var count = await table.count
        XCTAssertEqual(count, 1, "un solo FIN no cierra el flujo")

        _ = await table.observe(finIn, direction: .inbound, length: 60)
        count = await table.count
        XCTAssertEqual(count, 0)
        let closed = await table.drainClosed()
        XCTAssertEqual(closed.count, 1)
    }

    // MARK: - LRU

    func testLRUEvictionEmitsRecord() async {
        let table = FlowTable(config: .init(maxFlows: 2), clock: ManualClock())
        _ = await table.observe(FlowFixtures.tcp(source: local(1), destination: remote(443)), direction: .outbound, length: 10)
        _ = await table.observe(FlowFixtures.tcp(source: local(2), destination: remote(443)), direction: .outbound, length: 20)
        // El tercer flujo desborda: evicta el LRU (el flujo 1).
        _ = await table.observe(FlowFixtures.tcp(source: local(3), destination: remote(443)), direction: .outbound, length: 30)

        let count = await table.count
        XCTAssertEqual(count, 2)
        let closed = await table.drainClosed()
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed.first?.bytesOut, 10)   // el flujo 1 era el LRU
    }

    func testReuseRefreshesLRU() async {
        let table = FlowTable(config: .init(maxFlows: 2), clock: ManualClock())
        let flow1 = FlowFixtures.tcp(source: local(1), destination: remote(443))
        _ = await table.observe(flow1, direction: .outbound, length: 10)
        _ = await table.observe(FlowFixtures.tcp(source: local(2), destination: remote(443)), direction: .outbound, length: 20)
        // Reusar el flujo 1 lo pasa al frente; ahora el LRU es el flujo 2.
        _ = await table.observe(flow1, direction: .outbound, length: 5)
        _ = await table.observe(FlowFixtures.tcp(source: local(3), destination: remote(443)), direction: .outbound, length: 30)

        let closed = await table.drainClosed()
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed.first?.bytesOut, 20)   // se evictó el flujo 2, no el 1
    }

    // MARK: - Inactividad

    func testExpireIdleClosesStaleFlows() async {
        let clock = ManualClock(0)
        let table = FlowTable(config: .init(idleTimeout: 1_000), clock: clock)
        _ = await table.observe(FlowFixtures.tcp(source: local(1), destination: remote(443)), direction: .outbound, length: 10)

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
        _ = await table.observe(FlowFixtures.tcp(source: local(1), destination: remote(443)), direction: .outbound, length: 10)
        clock.set(900)
        // Un segundo flujo más nuevo no debe expirar aunque el primero sí.
        _ = await table.observe(FlowFixtures.tcp(source: local(2), destination: remote(443)), direction: .outbound, length: 10)

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
            _ = await table.observe(packet, direction: .outbound, length: 40)
        }
        let count = await table.count
        XCTAssertEqual(count, maxFlows, "la tabla nunca supera su tope duro")
        let closed = await table.drainClosed()
        XCTAssertEqual(closed.count, 10_000 - maxFlows, "todos los flujos evictados se emiten para volcarlos")
    }
}
