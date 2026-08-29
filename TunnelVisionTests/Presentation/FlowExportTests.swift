import Foundation
import XCTest
import Shared

/// Tests del núcleo puro del export del listado de conexiones (M9): qué lleva cada entrada, cómo se
/// arma el documento por trozos y cómo se nombra el fichero.
///
/// Todo lo que se afirma aquí se afirma **contra el JSON de verdad**: cada prueba concatena los
/// trozos que produce el serializador y los decodifica con `JSONSerialization`. Comprobar el texto
/// generado carácter a carácter afirmaría el formateo del codificador, no el contrato — y lo que
/// tiene que valer es que el fichero se pueda leer, que es lo que hará quien lo exporte.
final class FlowExportTests: XCTestCase {

    // MARK: - Utilidades

    /// El documento entero, tal y como lo escribiría `FlowExporter`.
    private func document(
        _ flows: [HistoryFlow],
        exportedAt: Date = HistoryFixtures.anchorWallClock,
        truncated: Bool = false
    ) throws -> [String: Any] {
        var serializer = FlowExportSerializer(exportedAt: exportedAt)
        var data = serializer.start()
        for flow in flows {
            data += try serializer.append(flow)
        }
        data += serializer.finish(truncated: truncated)

        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "el documento no decodificó a un objeto JSON"
        )
    }

    private func connections(_ document: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(document["connections"] as? [[String: Any]])
    }

    // MARK: - El documento

    func testAnEmptyExportIsStillValidJSON() throws {
        // Es el caso que rompe cualquier armazón hecho a mano: sin entradas, la coma que separa no
        // se llega a escribir nunca y el array tiene que cerrar igual.
        let object = try document([])

        XCTAssertEqual(object["format"] as? String, FlowExport.formatIdentifier)
        XCTAssertEqual(object["formatVersion"] as? Int, FlowExport.formatVersion)
        XCTAssertEqual(try connections(object).count, 0)
        XCTAssertEqual(object["connectionCount"] as? Int, 0)
        XCTAssertEqual(object["truncated"] as? Bool, false)
    }

    func testTheHeaderSaysWhenItWasExportedInUTC() throws {
        let object = try document([], exportedAt: Date(timeIntervalSince1970: 1_700_000_000))

        // ISO-8601 en UTC y con fracción de segundo: el fichero se lee fuera de la app, puede que en
        // otra máquina, así que el instante no puede depender de la región de nadie.
        XCTAssertEqual(object["exportedAt"] as? String, "2023-11-14T22:13:20.000Z")
    }

    func testTheCountsTravelInTheTrailerAndCountWhatWasWritten() throws {
        let flows = (1...3).map { HistoryFixtures.historyFlow(id: Int64($0), remote: HistoryFixtures.remote(UInt8($0))) }

        let object = try document(flows, truncated: true)

        XCTAssertEqual(try connections(object).count, 3)
        XCTAssertEqual(object["connectionCount"] as? Int, 3)
        // El recorte lo dice quien pagina, no el recuento: un export con exactamente el tope de
        // conexiones no significa que hubiera más.
        XCTAssertEqual(object["truncated"] as? Bool, true)
    }

    func testTheFileSaysOutLoudThatItCarriesNoPayloads() throws {
        let object = try document([HistoryFixtures.historyFlow()])
        let note = try XCTUnwrap(object["contents"] as? String)

        XCTAssertTrue(note.contains("payload"))
        // Y no lo dice solo la nota: ninguna entrada tiene por dónde colar contenido.
        let entry = try connections(object)[0]
        XCTAssertNil(entry["payload"])
        XCTAssertNil(entry["bytes"])
        XCTAssertNil(entry["content"])
    }

    func testTheSerializerCountsWhatItHasWritten() throws {
        var serializer = FlowExportSerializer(exportedAt: HistoryFixtures.anchorWallClock)
        XCTAssertEqual(serializer.writtenCount, 0)

        _ = serializer.start()
        _ = try serializer.append(HistoryFixtures.historyFlow(id: 1))
        _ = try serializer.append(HistoryFixtures.historyFlow(id: 2))

        XCTAssertEqual(serializer.writtenCount, 2)
    }

    // MARK: - Una conexión

    func testAConnectionCarriesTheFiveTupleTheTimesAndTheVolumes() throws {
        let flow = HistoryFixtures.historyFlow(
            id: 42,
            remote: HistoryFixtures.remote(34),
            remotePort: 443,
            proto: .tcp,
            firstSeen: 0,
            lastSeen: 10,
            tlsStatus: .encrypted,
            sni: "example.com"
        )

        let entry = try connections(try document([flow]))[0]

        XCTAssertEqual(entry["id"] as? Int64, 42)
        XCTAssertEqual(entry["protocol"] as? String, "tcp")
        XCTAssertEqual(entry["host"] as? String, "example.com")
        XCTAssertEqual(entry["sni"] as? String, "example.com")
        XCTAssertEqual(entry["tlsStatus"] as? String, "encrypted")
        XCTAssertEqual(entry["bytesOut"] as? UInt64, 1_000)
        XCTAssertEqual(entry["bytesIn"] as? UInt64, 2_000)
        XCTAssertEqual(entry["packetCount"] as? UInt64, 12)
        XCTAssertEqual(entry["durationSeconds"] as? Double, 10)
        XCTAssertEqual(entry["firstSeen"] as? String, "2023-11-14T22:13:20.000Z")
        XCTAssertEqual(entry["lastSeen"] as? String, "2023-11-14T22:13:30.000Z")
    }

    func testTheHostIsTheRemoteAddressWhenThereWasNoSNI() throws {
        let flow = HistoryFixtures.historyFlow(remote: HistoryFixtures.remote(34), sni: nil)

        let entry = try connections(try document([flow]))[0]

        XCTAssertEqual(entry["host"] as? String, "93.184.216.34")
        XCTAssertNil(entry["sni"] as? String)
    }

    func testTheEndpointsComeSplitWhenTheDeviceCouldBeTold() throws {
        let flow = HistoryFixtures.historyFlow(remote: HistoryFixtures.remote(34), remotePort: 443)

        let entry = try connections(try document([flow]))[0]

        let local = try XCTUnwrap(entry["local"] as? [String: Any])
        let remote = try XCTUnwrap(entry["remote"] as? [String: Any])
        XCTAssertEqual(local["address"] as? String, HistoryFixtures.deviceIPv4.description)
        XCTAssertEqual(local["port"] as? UInt16, 51_000)
        XCTAssertEqual(remote["address"] as? String, "93.184.216.34")
        XCTAssertEqual(remote["port"] as? UInt16, 443)
    }

    func testAConnectionThatCouldNotBeSplitStillCarriesBothAddresses() throws {
        // Sin las IPs del túnel no hay forma de saber cuál de los dos extremos es el dispositivo. La
        // entrada sale sin repartir, pero **no** sin direcciones: perder el dato por no saber
        // ordenarlo sería peor que darlo sin ordenar.
        let flow = HistoryFixtures.historyFlow(localAddresses: [])

        let entry = try connections(try document([flow]))[0]

        XCTAssertNil(entry["local"] as? [String: Any])
        XCTAssertNil(entry["remote"] as? [String: Any])
        XCTAssertNil(entry["host"] as? String)

        let peers = try XCTUnwrap(entry["peers"] as? [[String: Any]])
        XCTAssertEqual(peers.count, 2)
        let addresses = Set(peers.compactMap { $0["address"] as? String })
        XCTAssertEqual(addresses, [HistoryFixtures.deviceIPv4.description, "93.184.216.34"])
    }

    func testThePeersAreThereEvenWhenTheSplitWorked() throws {
        let flow = HistoryFixtures.historyFlow()

        let entry = try connections(try document([flow]))[0]

        XCTAssertEqual((entry["peers"] as? [[String: Any]])?.count, 2)
    }

    // MARK: - Nombres estables

    func testProtocolNamesAreIdentifiersAndNotScreenCopy() {
        XCTAssertEqual(FlowExport.name(of: .tcp), "tcp")
        XCTAssertEqual(FlowExport.name(of: .udp), "udp")
        XCTAssertEqual(FlowExport.name(of: .icmp), "icmp")
        XCTAssertEqual(FlowExport.name(of: .icmpv6), "icmpv6")
        XCTAssertEqual(FlowExport.name(of: .other), "other")
    }

    func testTLSStatusNamesCoverTheFourCases() {
        XCTAssertEqual(FlowExport.name(of: .plaintext), "plaintext")
        XCTAssertEqual(FlowExport.name(of: .encrypted), "encrypted")
        XCTAssertEqual(FlowExport.name(of: .inspected), "inspected")
        // ADR 0003: es una garantía (se relayeó intacta), no una avería, y el nombre no la adjetiva.
        XCTAssertEqual(FlowExport.name(of: .notInspectable), "notInspectable")
    }

    // MARK: - Nombre del fichero

    func testTheFileNameCarriesAUTCStampAndTheJSONExtension() {
        let name = FlowExport.fileName(exportedAt: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertEqual(name, "tunnelvision-connections-20231114-221320.json")
        XCTAssertTrue(FlowExport.isExportFileName(name))
    }

    func testOnlyOurOwnExportsAreRecognised() {
        // Es lo que decide qué se borra al preparar el export siguiente: nada que no haya escrito
        // este servicio.
        XCTAssertFalse(FlowExport.isExportFileName("tunnelvision-000001-20231114-221320.pcap"))
        XCTAssertFalse(FlowExport.isExportFileName("notes.json"))
        XCTAssertFalse(FlowExport.isExportFileName("tunnelvision-connections-20231114-221320.txt"))
    }
}
