import Foundation
import XCTest
// `FixtureRandom` es interno al framework —nadie fuera tiene que sortear nada— y se prueba con
// `@testable`, como `InternetChecksum` y el codificador DER.
@testable import Shared

/// Tests del generador de capturas sintéticas (M11).
///
/// Lo que se afirma aquí no es "los datos son bonitos" sino las tres propiedades de las que depende
/// todo lo que se construya encima: que la captura sea **reproducible** (o una medición compararía
/// dos capturas distintas), que sea **coherente** (el agregado de un flujo cuadra con sus paquetes, y
/// los bytes son datagramas que el parser de al lado lee), y que **cubra** los casos que existe para
/// hacer visibles, que es justo lo que un sorteo no garantiza.
final class CaptureFixtureTests: XCTestCase {

    /// Especificación pequeña para los tests que no miran el tamaño: la de verdad genera miles de
    /// paquetes por caso y aquí solo hace falta la forma.
    private func spec(
        seed: UInt64 = 42,
        bulkFlowCount: Int = 8,
        busiestFlowPacketCount: Int = 12
    ) -> FixtureSpec {
        FixtureSpec(
            seed: seed,
            endingAt: Date(timeIntervalSince1970: 1_800_000_000),
            span: 6 * 3600,
            bulkFlowCount: bulkFlowCount,
            busiestFlowPacketCount: busiestFlowPacketCount
        )
    }

    // MARK: - Reproducibilidad

    /// La razón de ser del generador propio: la misma semilla da la misma captura byte a byte. Sin
    /// esto, un «antes y después» con Instruments mediría dos capturas distintas y una captura de
    /// pantalla del showcase no se podría rehacer.
    func testSameSeedProducesIdenticalCapture() {
        let first = CaptureFixture.make(spec())
        let second = CaptureFixture.make(spec())
        XCTAssertEqual(first, second)
    }

    func testDifferentSeedsProduceDifferentCaptures() {
        XCTAssertNotEqual(CaptureFixture.make(spec(seed: 1)), CaptureFixture.make(spec(seed: 2)))
    }

    /// El generador se afirma también por su lado: dos instancias con la misma semilla producen la
    /// misma secuencia, y semillas distintas divergen desde la primera tirada. Es lo que impide que
    /// el test de arriba pase por una coincidencia de que ambas capturas estén vacías.
    func testSeededGeneratorIsDeterministic() {
        var a = FixtureRandom(seed: 7)
        var b = FixtureRandom(seed: 7)
        var c = FixtureRandom(seed: 8)

        let fromA = (0..<32).map { _ in a.next() }
        let fromB = (0..<32).map { _ in b.next() }
        let fromC = (0..<32).map { _ in c.next() }

        XCTAssertEqual(fromA, fromB)
        XCTAssertNotEqual(fromA, fromC)
        XCTAssertEqual(Set(fromA).count, 32, "32 tiradas seguidas no deberían repetir valor")
    }

    // MARK: - Coherencia: el agregado sale de los paquetes

    /// La fila que la Timeline enseña y la lista que se abre al pulsarla tienen que contar lo mismo.
    /// Se deriva en vez de escribirse, así que lo que se afirma es que la derivación es la que la
    /// tabla de flujos de la extensión haría.
    func testFlowRecordIsDerivedFromItsPackets() {
        let fixture = CaptureFixture.make(spec())
        XCTAssertFalse(fixture.flows.isEmpty)

        for flow in fixture.flows {
            let record = flow.record
            let outbound = flow.packets.filter { $0.direction == .outbound }
            let inbound = flow.packets.filter { $0.direction == .inbound }

            XCTAssertEqual(record.packetCount, UInt64(flow.packets.count))
            XCTAssertEqual(record.bytesOut, outbound.reduce(0) { $0 + UInt64($1.length) })
            XCTAssertEqual(record.bytesIn, inbound.reduce(0) { $0 + UInt64($1.length) })
            XCTAssertEqual(record.firstSeen, flow.packets.map(\.timestamp).min())
            XCTAssertEqual(record.lastSeen, flow.packets.map(\.timestamp).max())
            XCTAssertEqual(record.key, flow.key)
            XCTAssertEqual(record.sni, flow.sni)
            XCTAssertEqual(record.id, 0, "sin persistir: el rowid lo pone el UPSERT del store")
        }
    }

    func testPacketLengthMatchesItsBytes() {
        for flow in CaptureFixture.make(spec()).flows {
            for packet in flow.packets {
                XCTAssertEqual(Int(packet.length), packet.bytes.count)
            }
        }
    }

    /// Cada flujo es una conexión distinta. Si dos compartieran 5-tupla, el UPSERT del store los
    /// fundiría en una fila y la lista saldría más corta de lo que este fixture cree haber escrito,
    /// sin que nada lo dijera.
    func testEveryFlowHasItsOwnFiveTuple() {
        let flows = CaptureFixture.make(spec(bulkFlowCount: 60)).flows
        XCTAssertEqual(Set(flows.map(\.key)).count, flows.count)
    }

    // MARK: - Coherencia: los bytes son datagramas de verdad

    /// El volcado hexadecimal de la pantalla de un paquete enseña estos bytes, así que tienen que ser
    /// un datagrama IP y no ruido: se comprueba contra el parser, que es una implementación
    /// independiente del emisor que los produjo.
    func testEveryPacketParsesBackToItsOwnFlow() throws {
        for flow in CaptureFixture.make(spec()).flows {
            for packet in flow.packets {
                let family: Int32 = flow.key.endpointA.address.version == .v4 ? AF_INET : AF_INET6
                let parsed = try PacketParser.parse(packet.bytes, protocolFamily: family)

                XCTAssertEqual(
                    parsed.flowKey, packet.flowKey,
                    "el datagrama tiene que reconstruir la clave canónica de su propio flujo"
                )
                XCTAssertEqual(parsed.ip.proto, flow.key.proto)
            }
        }
    }

    /// El túnel se asigna estas direcciones, y la app decide con ellas cuál de los dos extremos de la
    /// 5-tupla canónica es el remoto. Con cualquier otra, cada fila enseñaría como host la IP del
    /// propio dispositivo.
    func testEveryFlowHasTheTunnelOnOneEnd() {
        let local: Set<IPAddress> = TunnelAddressing.localAddresses
        for flow in CaptureFixture.make(spec()).flows {
            let ends = [flow.key.endpointA.address, flow.key.endpointB.address]
            XCTAssertEqual(
                ends.filter(local.contains).count, 1,
                "exactamente un extremo es el dispositivo: \(flow.key)"
            )
        }
    }

    /// Los datagramas caben en la MTU del túnel. No es cosmético: un paquete más grande que lo que el
    /// túnel entrega nunca habría existido, y el aviso de recorte de la pantalla del paquete se
    /// mediría contra un tamaño imposible.
    func testNoDatagramExceedsTheTunnelMTU() {
        for flow in CaptureFixture.make(spec()).flows {
            for packet in flow.packets {
                XCTAssertLessThanOrEqual(packet.bytes.count, TunnelAddressing.mtu)
            }
        }
    }

    // MARK: - Coherencia: el tiempo

    /// El último paquete cae exactamente en el `endingAt` pedido y nada se sale del historial por
    /// ninguno de los dos bordes. Es lo que hace que la Timeline abra en «hace un momento» en vez de
    /// en una fecha que delate el fixture.
    func testHistoryEndsWhenAskedAndFitsInsideItsSpan() throws {
        let asked = spec()
        let fixture = CaptureFixture.make(asked)
        let span = try XCTUnwrap(fixture.wallClockSpan)

        XCTAssertEqual(span.upperBound.timeIntervalSince1970, asked.endingAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(
            span.lowerBound.timeIntervalSince1970,
            asked.endingAt.addingTimeInterval(-asked.span).timeIntervalSince1970
        )
    }

    func testPacketsOfAFlowAreInAscendingOrder() {
        for flow in CaptureFixture.make(spec()).flows {
            let stamps = flow.packets.map(\.timestamp)
            XCTAssertEqual(stamps, stamps.sorted())
        }
    }

    // MARK: - Cobertura: los casos escritos a mano

    /// Los cuatro estados de inspección, que son la columna vertebral de la Timeline y lo que el
    /// producto promete: sin el `notInspectable` no hay forma de mirar la pantalla que explica que
    /// una app con pinning se relaya intacta.
    func testCoversEveryTLSInspectionStatus() {
        let statuses = Set(CaptureFixture.make(spec()).flows.map(\.tlsStatus))
        for status in [TLSInspectionStatus.plaintext, .encrypted, .inspected, .notInspectable] {
            XCTAssertTrue(statuses.contains(status), "falta el estado \(status)")
        }
    }

    /// Los cinco protocolos, incluidos los tres sin puertos. `.other` es lo único que recoge el filtro
    /// del mismo nombre en la Timeline, así que sin él ese filtro no se puede mirar.
    func testCoversEveryProtocol() {
        let protocols = Set(CaptureFixture.make(spec()).flows.map(\.key.proto))
        for proto in [IPProtocolNumber.tcp, .udp, .icmp, .icmpv6, .other] {
            XCTAssertTrue(protocols.contains(proto), "falta el protocolo \(proto)")
        }
    }

    func testCoversBothAddressFamilies() {
        let versions = Set(CaptureFixture.make(spec()).flows.map(\.key.endpointA.address.version))
        XCTAssertEqual(versions, [.v4, .v6])
    }

    /// Un flujo sin SNI hace que la app caiga a la IP del extremo remoto, y uno con un host larguísimo
    /// es el que decide si una fila trunca o se rompe con letra de accesibilidad. Los dos existen
    /// porque un sorteo no los produciría.
    func testCoversFlowsWithAndWithoutAHostName() {
        let flows = CaptureFixture.make(spec()).flows
        XCTAssertTrue(flows.contains { $0.sni == nil })
        XCTAssertTrue(
            flows.contains { ($0.sni?.count ?? 0) > 50 },
            "hace falta un host que no quepa en una línea"
        )
    }

    /// Los siete sucesos que la pantalla de un paquete sabe traducir. `PacketEvent` vive en la app y
    /// aquí no se puede importar, así que se afirma sobre lo que lo produce: las combinaciones de
    /// flags de las que sale cada uno.
    func testCoversEveryTCPFlagCombinationTheAppTranslates() {
        let flags = Set(
            CaptureFixture.make(spec()).flows
                .filter { $0.key.proto == .tcp }
                .flatMap { $0.packets.map(\.tcpFlags) }
        )

        XCTAssertTrue(flags.contains { $0 == .syn }, "apertura")
        XCTAssertTrue(flags.contains { $0 == [.syn, .ack] }, "aceptación")
        XCTAssertTrue(flags.contains { $0.contains(.psh) }, "datos")
        XCTAssertTrue(flags.contains { $0 == .ack }, "acuse a secas")
        XCTAssertTrue(flags.contains { $0.contains(.fin) }, "cierre ordenado")
        XCTAssertTrue(flags.contains { $0.contains(.rst) }, "corte en seco")
        XCTAssertTrue(
            flags.contains { !$0.isDisjoint(with: .urg) && $0.isDisjoint(with: [.rst, .syn, .fin, .psh, .ack]) },
            "el paquete que la app no sabe nombrar"
        )
    }

    /// Sin puertos no hay puertos: los tres protocolos que el parser acepta como metadato dejan la
    /// 5-tupla con ceros, y es lo que la pantalla de la conexión tiene que saber enseñar.
    func testPortlessProtocolsCarryZeroPorts() {
        for flow in CaptureFixture.make(spec()).flows where [.icmp, .icmpv6, .other].contains(flow.key.proto) {
            XCTAssertEqual(flow.key.endpointA.port, 0)
            XCTAssertEqual(flow.key.endpointB.port, 0)
        }
    }

    /// Las cuatro razones por las que la pantalla de un paquete puede no tener bytes que enseñar
    /// necesitan que haya paquetes sin capturar — y no solo al final de una lista, sino también en
    /// medio de una larga, que es donde en producción los deja un fallo de escritura puntual.
    func testCoversPacketsWhoseBytesWereNeverWritten() {
        let fixture = CaptureFixture.make(spec(busiestFlowPacketCount: 300))
        XCTAssertLessThan(fixture.capturedPacketCount, fixture.packetCount)

        XCTAssertTrue(
            fixture.flows.contains { $0.packets.allSatisfy { !$0.wasCaptured } },
            "hace falta un flujo entero sin capturar"
        )
        XCTAssertTrue(
            fixture.flows.contains { flow in
                flow.packets.contains(where: \.wasCaptured) && flow.packets.contains { !$0.wasCaptured }
            },
            "y un hueco en medio de un flujo que sí captura"
        )
    }

    // MARK: - Cobertura: el tamaño y la forma

    /// El eje de la Timeline necesita relieve: sin tramos vacíos no hay nada que recorra el cursor
    /// accesible ni tramo a cero que enseñe su clave propia, y sin un pico acercarse no significa
    /// nada. Se afirma sobre el reparto real de los paquetes, no sobre los pesos que lo produjeron.
    func testActivityIsUnevenOverTime() throws {
        let fixture = CaptureFixture.make(spec(bulkFlowCount: 200, busiestFlowPacketCount: 400))
        let span = try XCTUnwrap(fixture.wallClockSpan)

        let bucketCount = 24
        let width = span.upperBound.timeIntervalSince(span.lowerBound) / Double(bucketCount)
        var counts = [Int](repeating: 0, count: bucketCount)
        for flow in fixture.flows {
            let start = fixture.anchor.date(forUptime: flow.record.firstSeen)
            let index = min(bucketCount - 1, Int(start.timeIntervalSince(span.lowerBound) / width))
            counts[index] += 1
        }

        XCTAssertTrue(counts.contains(0), "hacen falta tramos vacíos, o el eje no tiene forma")
        let busiest = try XCTUnwrap(counts.max())
        let average = Double(counts.reduce(0, +)) / Double(bucketCount)
        XCTAssertGreaterThan(Double(busiest), average * 2, "hace falta un pico donde acercarse")
    }

    /// Por encima de `HistoryPolicy.packetsPerFlow` (500) el Flow Inspector recorta su lista y enseña
    /// el aviso. `HistoryPolicy` vive en la app, así que el número se escribe aquí: si allí sube, este
    /// test es el que avisa de que el fixture dejó de alcanzar ese estado.
    func testTheBusiestFlowOvershootsTheInspectorsPacketLimit() {
        let fixture = CaptureFixture.make(FixtureSpec.default(endingAt: Date()))
        let busiest = fixture.flows.map(\.packets.count).max() ?? 0
        XCTAssertGreaterThan(busiest, 500)
    }

    /// Por encima de `HistoryPolicy.pageSize` (100) la Timeline pagina de verdad, que es la condición
    /// para que un scroll mida algo. Mismo razonamiento que arriba con el número escrito a mano.
    func testTheDefaultCaptureIsLongEnoughToPaginate() {
        XCTAssertGreaterThan(CaptureFixture.make(FixtureSpec.default(endingAt: Date())).flows.count, 100)
    }

    // MARK: - Lo descifrado

    /// Sin contenido descifrado, la mitad descifrada del Flow Inspector no existe en Simulator: la
    /// única que escribe `.tvpt` es la extensión, y allí no corre.
    func testTheCatalogueIncludesDecryptedConversations() {
        let fixture = CaptureFixture.make(FixtureSpec.default(endingAt: Date()))

        let inspected = fixture.flows.filter { !$0.plaintext.isEmpty }
        XCTAssertGreaterThanOrEqual(inspected.count, 2)
        XCTAssertTrue(
            inspected.allSatisfy { $0.tlsStatus == .inspected },
            "solo un flujo inspeccionado pudo dejar contenido descifrado"
        )
        XCTAssertEqual(fixture.plaintextChunkCount, inspected.reduce(0) { $0 + $1.plaintext.count })
    }

    /// Un turno es una racha del mismo sentido, así que sin trozos consecutivos del mismo lado el
    /// fixture nunca ejercitaría la agrupación que la pantalla hace.
    func testAConversationCarriesATurnOfSeveralPieces() {
        let fixture = CaptureFixture.make(FixtureSpec.default(endingAt: Date()))
        let conversations = fixture.flows.map(\.plaintext).filter { !$0.isEmpty }

        let hasRun = conversations.contains { chunks in
            zip(chunks, chunks.dropFirst()).contains { $0.direction == $1.direction }
        }
        XCTAssertTrue(hasRun)
    }

    /// El corte no se declara: un trozo mayor que el tope por registro del escritor (64 KiB) es lo
    /// que hace que el recorte lo produzca **él**, igual que en un dispositivo.
    func testAConversationOvershootsTheWritersPerRecordCap() {
        let fixture = CaptureFixture.make(FixtureSpec.default(endingAt: Date()))
        let biggest = fixture.flows.flatMap(\.plaintext).map(\.bytes.count).max() ?? 0

        XCTAssertGreaterThan(biggest, 64 * 1024)
    }

    /// Los dos cuerpos que la pantalla sabe pintar: texto y lo que no lo es.
    func testTheConversationsCoverBothWaysOfDrawingATurn() {
        let fixture = CaptureFixture.make(FixtureSpec.default(endingAt: Date()))
        let pieces = fixture.flows.flatMap(\.plaintext).map(\.bytes)

        XCTAssertTrue(pieces.contains { String(data: $0, encoding: .utf8) != nil })
        XCTAssertTrue(pieces.contains { String(data: $0, encoding: .utf8) == nil })
    }

    /// Un trozo descifrado sale del stream que traen los paquetes, así que no puede fecharse fuera de
    /// la vida de su conexión.
    func testEveryDecryptedPieceHappensInsideItsConnection() {
        let fixture = CaptureFixture.make(FixtureSpec.default(endingAt: Date()))

        for flow in fixture.flows where !flow.plaintext.isEmpty {
            let span = flow.record.firstSeen...flow.record.lastSeen
            XCTAssertTrue(flow.plaintext.allSatisfy { span.contains($0.timestamp) })
        }
    }

    /// Determinista como el resto: la misma semilla da los mismos bytes descifrados.
    func testTheSameSeedGivesTheSameConversations() {
        let spec = FixtureSpec.default(endingAt: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertEqual(
            CaptureFixture.make(spec).flows.map(\.plaintext),
            CaptureFixture.make(spec).flows.map(\.plaintext)
        )
    }
}
