import Foundation
import XCTest
@testable import Shared

/// Tests de la captura del paquete de evidencia, de punta a punta: un `FlowStore` real, ficheros
/// escritos por un `PcapWriter` real y el `.pcapng` leído de vuelta por un lector que no comparte
/// código con el que lo escribe. Lo que se afirma es lo que un evaluador va a dar por cierto al
/// abrirlo: que están los paquetes de la sesión y solo esos, cada uno con su flujo, y que de los
/// que faltan se dice cuántos y por qué.
final class EvidenceCaptureWriterTests: XCTestCase {

    private var root: URL!
    private var dbURL: URL!
    private var captureDir: URL!
    private var folder: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evidence-capture-tests-\(UUID().uuidString)", isDirectory: true)
        captureDir = root.appendingPathComponent("Captures", isDirectory: true)
        folder = root.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: captureDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        dbURL = PersistenceFixtures.temporaryDatabaseURL()
    }

    override func tearDownWithError() throws {
        PersistenceFixtures.removeDatabase(at: dbURL)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Utilidades

    private static let a = ModelFixtures.v4(1, 1, 1, 1)
    private static let b = ModelFixtures.v4(2, 2, 2, 2)
    private static let outside = ModelFixtures.v4(9, 9, 9, 9)

    private func makeStore() throws -> FlowStore {
        try FlowStore(databaseURL: dbURL, anchor: PersistenceFixtures.anchor)
    }

    private func makeWriter(snaplen: UInt32 = 262_144) throws -> PcapWriter {
        try PcapWriter(config: .init(directory: captureDir, snaplen: snaplen))
    }

    /// Microsegundos desde el epoch de `seconds` segundos después del ancla: lo que tiene que
    /// llevar el paquete en la captura.
    private func micro(_ seconds: UInt64) -> UInt64 {
        (1_700_000_000 + seconds) * 1_000_000
    }

    private func startSession(_ store: FlowStore, at seconds: UInt64 = 10) async throws -> AuditSession {
        let project = try await store.createAuditProject(
            AuditProjectDraft(name: "Example Health", bundleIdentifier: nil, catalogueVersion: nil, allowlist: []),
            at: PersistenceFixtures.date(0)
        )
        return try await store.startAuditSession(
            AuditSessionDraft(
                projectID: project.id,
                kind: .audit(AppRelease(version: "2.4.0", build: "187")),
                environment: AuditEnvironment(deviceModel: "iPhone18,3", osVersion: "27.0", toolVersion: "1.0 (1)"),
                inspection: InspectionConditions(inspectionEnabled: false, caTrusted: false),
                notes: ""
            ),
            at: PersistenceFixtures.date(seconds)
        )
    }

    private func flow(
        _ store: FlowStore,
        remote: IPAddress,
        remotePort: UInt16 = 443,
        firstSeen: UInt64 = 12,
        lastSeen: UInt64 = 20,
        streamOpening: StreamOpening? = nil
    ) async throws -> Int64 {
        try await store.upsertFlow(PersistenceFixtures.flow(
            remote: remote, remotePort: remotePort, firstSeen: firstSeen, lastSeen: lastSeen,
            sni: "api.example.com", streamOpening: streamOpening
        ))
    }

    /// Escribe un paquete en la captura y devuelve su metadato, ya con dónde quedó.
    private func captured(
        _ writer: PcapWriter,
        at seconds: UInt64,
        remote: IPAddress,
        remotePort: UInt16 = 443,
        direction: Direction = .outbound,
        fill: UInt8,
        length: Int = 40,
        originalLength: Int? = nil
    ) async throws -> PacketMeta {
        let location = try await writer.write(
            packet: Data(repeating: fill, count: length),
            originalLength: originalLength ?? length,
            timestamp: Int64(1_700_000_000 + seconds) * 1_000_000_000
        )
        return PersistenceFixtures.packet(
            timestamp: seconds,
            key: PersistenceFixtures.key(remote: remote, remotePort: remotePort),
            direction: direction,
            capture: location
        )
    }

    private func uncaptured(at seconds: UInt64, remote: IPAddress) -> PacketMeta {
        PersistenceFixtures.packet(timestamp: seconds, key: PersistenceFixtures.key(remote: remote), capture: nil)
    }

    /// Cierra la sesión y arma su paquete con todos sus flujos, menos los que se pida dejar fuera.
    private func closeAndBundle(
        _ store: FlowStore,
        _ session: AuditSession,
        at seconds: UInt64 = 100,
        leavingOut: Set<Int64> = []
    ) async throws -> EvidenceBundle {
        let closed = try await store.endAuditSession(id: session.id, at: PersistenceFixtures.date(seconds))
        let found = try await store.auditProject(id: session.projectID)
        let project = try XCTUnwrap(found)
        let flows = try await store.flows(inAuditSession: session.id, limit: 1_000)
        return try EvidenceBundle(
            project: project,
            session: closed,
            markers: [],
            flows: flows.filter { !leavingOut.contains($0.id) },
            catalogue: try RequirementCatalogueLibrary.catalogue(for: project),
            exportedWith: "1.1 (4)",
            exportedAt: PersistenceFixtures.date(200)
        )
    }

    private func write(_ bundle: EvidenceBundle, _ store: FlowStore, into folder: URL? = nil) async throws -> EvidenceCapture {
        try await EvidenceCaptureWriter.write(
            for: bundle, from: store, captureDirectory: captureDir, into: folder ?? self.folder
        )
    }

    private var captureURL: URL { folder.appendingPathComponent("capture.pcapng") }

    private func comment(of flowID: Int64, in bundle: EvidenceBundle) throws -> String {
        let flow = try XCTUnwrap(bundle.flows.flows.first { $0.id == flowID })
        return EvidenceCaptureComment.text(flowID: flowID, findingIDs: flow.findingIDs)
    }

    private func tally(of flowID: Int64, in capture: EvidenceCapture) throws -> EvidencePacketTally {
        try XCTUnwrap(capture.document.flows.first { $0.id == flowID }).packets
    }

    // MARK: - Lo que lleva

    func testTheCaptureHoldsTheSessionsPacketsAndOnlyThoseInTheOrderTheyWereCaptured() async throws {
        let store = try makeStore()
        let writer = try makeWriter()

        // Antes de la sesión, en el mismo fichero que ella: no es suyo.
        let stranger = try await flow(store, remote: Self.outside, firstSeen: 1, lastSeen: 2)
        try await store.appendPackets(
            [try await captured(writer, at: 1, remote: Self.outside, fill: 0xEE)], flowID: stranger
        )

        let session = try await startSession(store)
        let first = try await flow(store, remote: Self.a)
        let second = try await flow(store, remote: Self.b)
        let a1 = try await captured(writer, at: 12, remote: Self.a, fill: 0xA1)
        let a2 = try await captured(writer, at: 13, remote: Self.a, direction: .inbound, fill: 0xA2, length: 61)
        let b1 = try await captured(writer, at: 14, remote: Self.b, direction: .inbound, fill: 0xB1)
        // La captura rota en medio de la sesión: los paquetes siguen en orden.
        try await writer.rotate()
        let a3 = try await captured(writer, at: 15, remote: Self.a, fill: 0xA3)
        await writer.close()
        // El historial los recibe en otro orden: el de la captura es el del fichero.
        try await store.appendPackets([a3, a1, a2], flowID: first)
        try await store.appendPackets([b1], flowID: second)

        let bundle = try await closeAndBundle(store, session)
        let capture = try await write(bundle, store)

        let decoded = try TestPcapngReader.read(captureURL)
        XCTAssertEqual(decoded.blockTypes, [0x0A0D_0D0A, 1, 6, 6, 6, 6])
        XCTAssertEqual(decoded.sections.first?.options, [.init(code: 4, value: Data("TunnelVision 1.1 (4)".utf8))])
        XCTAssertEqual(decoded.interfaces.map(\.linkType), [101])
        XCTAssertEqual(decoded.interfaces.map(\.snaplen), [262_144])

        XCTAssertEqual(decoded.packets.map(\.data), [
            Data(repeating: 0xA1, count: 40),
            Data(repeating: 0xA2, count: 61),
            Data(repeating: 0xB1, count: 40),
            Data(repeating: 0xA3, count: 40),
        ])
        XCTAssertEqual(decoded.packets.map(\.timestamp), [micro(12), micro(13), micro(14), micro(15)])
        XCTAssertEqual(decoded.packets.map(\.directionBits), [2, 1, 1, 2])
        XCTAssertEqual(decoded.packets.map(\.interfaceID), [0, 0, 0, 0])
        let firstComment = try comment(of: first, in: bundle)
        let secondComment = try comment(of: second, in: bundle)
        XCTAssertEqual(decoded.packets.map(\.comment), [firstComment, firstComment, secondComment, firstComment])

        XCTAssertEqual(capture.document.packets, EvidencePacketTally(written: 4))
        XCTAssertEqual(capture.document.flows.map(\.id), bundle.flows.flows.map(\.id))
        XCTAssertEqual(try tally(of: first, in: capture), EvidencePacketTally(written: 3))
        XCTAssertEqual(try tally(of: second, in: capture), EvidencePacketTally(written: 1))
        XCTAssertEqual(capture.document.sourceFiles, [
            .init(sequence: 0, state: .read, packetsReferenced: 3, packetsWritten: 3),
            .init(sequence: 1, state: .read, packetsReferenced: 1, packetsWritten: 1),
        ])
        XCTAssertEqual(capture.document.writtenOutsideSession, .init(beforeStart: 0, afterEnd: 0))
        XCTAssertEqual(capture.document.snaplen, 262_144)
    }

    func testTheManifestEntryIsTheDigestOfTheBytesOnDisk() async throws {
        let store = try makeStore()
        let writer = try makeWriter()
        let session = try await startSession(store)
        let first = try await flow(store, remote: Self.a)
        var metas: [PacketMeta] = []
        for index in 0..<50 {
            metas.append(try await captured(writer, at: 12, remote: Self.a, fill: UInt8(index), length: 1_200))
        }
        await writer.close()
        try await store.appendPackets(metas, flowID: first)

        let bundle = try await closeAndBundle(store, session)
        let capture = try await write(bundle, store)

        let onDisk = try Data(contentsOf: captureURL)
        XCTAssertEqual(capture.entry.name, "capture.pcapng")
        XCTAssertEqual(capture.entry.byteCount, onDisk.count)
        XCTAssertEqual(capture.entry.sha256, EvidenceManifest.sha256(of: onDisk))

        // Y entra en el manifiesto del paquete junto a su documento.
        let files = try bundle.documentFiles() + [try capture.documentFile()]
        let manifest = try bundle.manifest(of: files, adding: [capture.entry])
        XCTAssertEqual(
            manifest.files.map(\.name),
            ["capture.json", "capture.pcapng", "findings.json", "flows.csv", "flows.json", "session.json"]
        )
    }

    func testTheSameSessionGivesTheSameBytesAndReplacesAnEarlierCapture() async throws {
        let store = try makeStore()
        let writer = try makeWriter()
        let session = try await startSession(store)
        let first = try await flow(store, remote: Self.a)
        try await store.appendPackets(
            [
                try await captured(writer, at: 12, remote: Self.a, fill: 0xA1),
                try await captured(writer, at: 13, remote: Self.a, fill: 0xA2),
            ],
            flowID: first
        )
        await writer.close()
        let bundle = try await closeAndBundle(store, session)

        // Lo que hubiera con ese nombre se sustituye entero, aunque fuera más largo.
        try Data(repeating: 0x55, count: 4_096).write(to: captureURL)
        let once = try await write(bundle, store)
        let bytes = try Data(contentsOf: captureURL)
        let twice = try await write(bundle, store)

        XCTAssertEqual(once, twice)
        XCTAssertEqual(try Data(contentsOf: captureURL), bytes)
        XCTAssertEqual(try TestPcapngReader.read(bytes).packets.count, 2)
    }

    func testAPacketCarriesTheFindingsItsFlowIsEvidenceOf() async throws {
        let store = try makeStore()
        let writer = try makeWriter()
        let session = try await startSession(store)
        // Una petición de HTTP vista en claro: `cleartextTraffic`.
        let clear = try await flow(store, remote: Self.a, remotePort: 80, streamOpening: .httpRequest)
        try await store.appendPackets(
            [try await captured(writer, at: 12, remote: Self.a, remotePort: 80, fill: 0xA1)], flowID: clear
        )
        await writer.close()

        let bundle = try await closeAndBundle(store, session)
        _ = try await write(bundle, store)

        let findingIDs = try XCTUnwrap(bundle.flows.flows.first { $0.id == clear }).findingIDs
        XCTAssertFalse(findingIDs.isEmpty, "el flujo en claro tiene que probar algún hallazgo")
        XCTAssertEqual(
            try TestPcapngReader.read(captureURL).packets.map(\.comment),
            ["flow=\(clear) findings=\(findingIDs.joined(separator: ","))"]
        )
    }

    func testThePacketCommentNamesTheFlowAndItsFindings() {
        XCTAssertEqual(EvidenceCaptureComment.text(flowID: 12, findingIDs: []), "flow=12")
        XCTAssertEqual(EvidenceCaptureComment.text(flowID: 12, findingIDs: ["F3"]), "flow=12 findings=F3")
        XCTAssertEqual(EvidenceCaptureComment.text(flowID: 1, findingIDs: ["F1", "F30"]), "flow=1 findings=F1,F30")
    }

    func testAPacketCutBySnaplenSaysWhatItMeasuredAndTheInterfaceTakesTheLargestSnaplen() async throws {
        let store = try makeStore()
        let writer = try makeWriter(snaplen: 64)
        let session = try await startSession(store)
        let first = try await flow(store, remote: Self.a)
        let cut = try await captured(writer, at: 12, remote: Self.a, fill: 0xA1, length: 200, originalLength: 200)
        // Cambiar el `snaplen` rota: cada fichero declara el suyo.
        try await writer.setSnaplen(128)
        let whole = try await captured(writer, at: 13, remote: Self.a, fill: 0xA2, length: 100)
        await writer.close()
        try await store.appendPackets([cut, whole], flowID: first)

        let bundle = try await closeAndBundle(store, session)
        let capture = try await write(bundle, store)

        let decoded = try TestPcapngReader.read(captureURL)
        XCTAssertEqual(decoded.interfaces.map(\.snaplen), [128])
        XCTAssertEqual(decoded.packets.map(\.capturedLength), [64, 100])
        XCTAssertEqual(decoded.packets.map(\.originalLength), [200, 100])
        XCTAssertEqual(capture.document.snaplen, 128)
    }

    // MARK: - Lo que falta

    func testEveryPacketWithoutBytesIsCountedUnderItsReason() async throws {
        let store = try makeStore()
        let writer = try makeWriter()
        let session = try await startSession(store)
        let first = try await flow(store, remote: Self.a)
        let second = try await flow(store, remote: Self.b)

        // Fichero 0: se borrará. Fichero 1: dejará de ser una captura. Fichero 2: su último
        // registro se quedará a medias. Fichero 3: entero.
        var ofFirst: [PacketMeta] = []
        var ofSecond: [PacketMeta] = []
        ofFirst.append(try await captured(writer, at: 12, remote: Self.a, fill: 0x01))
        ofSecond.append(try await captured(writer, at: 12, remote: Self.b, fill: 0x02))
        try await writer.rotate()
        ofFirst.append(try await captured(writer, at: 13, remote: Self.a, fill: 0x11))
        ofFirst.append(try await captured(writer, at: 13, remote: Self.a, fill: 0x12))
        try await writer.rotate()
        ofFirst.append(try await captured(writer, at: 14, remote: Self.a, fill: 0x21))
        let cutShort = try await captured(writer, at: 14, remote: Self.b, fill: 0x22)
        ofSecond.append(cutShort)
        try await writer.rotate()
        ofSecond.append(try await captured(writer, at: 15, remote: Self.b, fill: 0x31))
        await writer.close()
        // Y tres que nunca se capturaron.
        ofFirst.append(uncaptured(at: 16, remote: Self.a))
        ofFirst.append(uncaptured(at: 17, remote: Self.a))
        ofSecond.append(uncaptured(at: 16, remote: Self.b))
        try await store.appendPackets(ofFirst, flowID: first)
        try await store.appendPackets(ofSecond, flowID: second)

        try FileManager.default.removeItem(at: try XCTUnwrap(CaptureDirectory.url(forSequence: 0, in: captureDir)))
        try Data(repeating: 0, count: 512).write(to: try XCTUnwrap(CaptureDirectory.url(forSequence: 1, in: captureDir)))
        let handle = try FileHandle(forWritingTo: try XCTUnwrap(CaptureDirectory.url(forSequence: 2, in: captureDir)))
        try handle.truncate(atOffset: try XCTUnwrap(cutShort.capture).recordOffset + 16 + 10)
        try handle.close()

        let bundle = try await closeAndBundle(store, session)
        let capture = try await write(bundle, store)

        // En la captura están solo los dos que se pudieron leer.
        XCTAssertEqual(
            try TestPcapngReader.read(captureURL).packets.map(\.data),
            [Data(repeating: 0x21, count: 40), Data(repeating: 0x31, count: 40)]
        )
        XCTAssertEqual(
            try tally(of: first, in: capture),
            EvidencePacketTally(written: 1, lost: [.captureFileMissing: 1, .recordUnreadable: 2, .notCaptured: 2])
        )
        XCTAssertEqual(
            try tally(of: second, in: capture),
            EvidencePacketTally(written: 1, lost: [.captureFileMissing: 1, .recordUnreadable: 1, .notCaptured: 1])
        )
        XCTAssertEqual(
            capture.document.packets,
            EvidencePacketTally(written: 2, lost: [.captureFileMissing: 2, .recordUnreadable: 3, .notCaptured: 3])
        )
        XCTAssertEqual(capture.document.packets.recorded, 10)
        XCTAssertEqual(capture.document.sourceFiles, [
            .init(sequence: 0, state: .missing, packetsReferenced: 2, packetsWritten: 0),
            .init(sequence: 1, state: .unreadable, packetsReferenced: 2, packetsWritten: 0),
            .init(sequence: 2, state: .read, packetsReferenced: 2, packetsWritten: 1),
            .init(sequence: 3, state: .read, packetsReferenced: 1, packetsWritten: 1),
        ])
        // El `snaplen` es el de los ficheros que se leyeron.
        XCTAssertEqual(capture.document.snaplen, 262_144)
    }

    func testASessionWithNoBytesStillGivesACaptureThatOpensAndSaysSo() async throws {
        let store = try makeStore()
        let session = try await startSession(store)
        let first = try await flow(store, remote: Self.a)
        let quiet = try await flow(store, remote: Self.b)
        try await store.appendPackets([uncaptured(at: 12, remote: Self.a)], flowID: first)

        let bundle = try await closeAndBundle(store, session)
        let capture = try await write(bundle, store)

        let decoded = try TestPcapngReader.read(captureURL)
        XCTAssertEqual(decoded.blockTypes, [0x0A0D_0D0A, 1])
        // Sin ningún fichero leído no hay tope que declarar.
        XCTAssertEqual(decoded.interfaces.map(\.snaplen), [0])
        XCTAssertNil(capture.document.snaplen)
        XCTAssertEqual(capture.document.sourceFiles, [])
        XCTAssertEqual(capture.document.packets, EvidencePacketTally(lost: [.notCaptured: 1]))
        // Un flujo sin ningún paquete guardado está en la lista, con todo a cero.
        XCTAssertEqual(try tally(of: quiet, in: capture), EvidencePacketTally())
        XCTAssertEqual(capture.entry.byteCount, try Data(contentsOf: captureURL).count)
    }

    func testPacketsOfAFlowFromBeforeOrAfterTheSessionAreWrittenAndCounted() async throws {
        let store = try makeStore()
        let writer = try makeWriter()

        // El flujo empieza antes de la sesión y sigue vivo después de que se cierre.
        let early = try await flow(store, remote: Self.a, firstSeen: 5, lastSeen: 6)
        try await store.appendPackets([try await captured(writer, at: 5, remote: Self.a, fill: 0x05)], flowID: early)
        let session = try await startSession(store, at: 10)
        let tagged = try await flow(store, remote: Self.a, firstSeen: 5, lastSeen: 20)
        XCTAssertEqual(tagged, early)
        try await store.appendPackets(
            [
                // En el primer y en el último instante de la sesión: dentro.
                try await captured(writer, at: 10, remote: Self.a, fill: 0x10),
                try await captured(writer, at: 100, remote: Self.a, fill: 0x64),
            ],
            flowID: early
        )
        let bundle = try await closeAndBundle(store, session, at: 100)
        try await store.appendPackets([try await captured(writer, at: 150, remote: Self.a, fill: 0x96)], flowID: early)
        await writer.close()

        let capture = try await write(bundle, store)

        XCTAssertEqual(
            try TestPcapngReader.read(captureURL).packets.map(\.timestamp),
            [micro(5), micro(10), micro(100), micro(150)]
        )
        XCTAssertEqual(capture.document.packets, EvidencePacketTally(written: 4))
        XCTAssertEqual(capture.document.writtenOutsideSession, .init(beforeStart: 1, afterEnd: 1))
    }

    // MARK: - Lo que no se escribe

    func testPacketsOfAFlowTheBundleDoesNotListStopTheCaptureAndLeaveNoFile() async throws {
        let store = try makeStore()
        let writer = try makeWriter()
        let session = try await startSession(store)
        let first = try await flow(store, remote: Self.a)
        let second = try await flow(store, remote: Self.b)
        try await store.appendPackets([try await captured(writer, at: 12, remote: Self.a, fill: 0xA1)], flowID: first)
        try await store.appendPackets([try await captured(writer, at: 13, remote: Self.b, fill: 0xB1)], flowID: second)
        await writer.close()

        // Al paquete no se le dieron todos los flujos de la sesión.
        let bundle = try await closeAndBundle(store, session, leavingOut: [second])
        try Data(repeating: 0x55, count: 64).write(to: captureURL)

        do {
            _ = try await write(bundle, store)
            XCTFail("una captura con paquetes de un flujo que flows.json no lista no se escribe")
        } catch {
            XCTAssertEqual(error as? EvidenceCaptureError, .flowNotInBundle(id: second))
        }
        // Lo que había con ese nombre no se toca: se falla antes de abrir nada.
        XCTAssertEqual(try Data(contentsOf: captureURL), Data(repeating: 0x55, count: 64))
    }

    func testAFolderThatIsNotThereIsAnErrorOfItsOwn() async throws {
        let store = try makeStore()
        let session = try await startSession(store)
        let bundle = try await closeAndBundle(store, session)

        do {
            _ = try await write(bundle, store, into: root.appendingPathComponent("absent", isDirectory: true))
            XCTFail("sin carpeta no hay dónde escribir")
        } catch {
            XCTAssertEqual(error as? EvidenceCaptureError, .destinationUnavailable("capture.pcapng"))
        }
    }

    // MARK: - capture.json

    func testThePacketTallyAccountsForEveryRecordedPacket() {
        let tally = EvidencePacketTally(written: 5, lost: [.notCaptured: 2, .recordUnreadable: 1])

        XCTAssertEqual(tally.recorded, 8)
        XCTAssertEqual(tally.withoutBytes.total, 3)
        XCTAssertEqual(tally.withoutBytes.captureFileMissing, 0)
        XCTAssertEqual(EvidencePacketTally().recorded, 0)
    }

    func testTheCaptureDocumentSumsItsFlowsAndListsSourceFilesBySequence() throws {
        let document = EvidenceCaptureDocument(
            sessionID: 7,
            snaplen: nil,
            flows: [
                .init(id: 9, packets: EvidencePacketTally(written: 3, lost: [.notCaptured: 1])),
                .init(id: 4, packets: EvidencePacketTally(written: 2, lost: [.captureFileMissing: 5])),
            ],
            sourceFiles: [
                .init(sequence: 8, state: .missing, packetsReferenced: 5, packetsWritten: 0),
                .init(sequence: 2, state: .read, packetsReferenced: 5, packetsWritten: 5),
            ],
            writtenOutsideSession: .init(beforeStart: 1, afterEnd: 0)
        )

        XCTAssertEqual(document.packets, EvidencePacketTally(written: 5, lost: [.notCaptured: 1, .captureFileMissing: 5]))
        // Los flujos, en el orden dado (el de flows.json); los ficheros, por secuencia.
        XCTAssertEqual(document.flows.map(\.id), [9, 4])
        XCTAssertEqual(document.sourceFiles.map(\.sequence), [2, 8])

        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try EvidenceBundleFormat.encode(document)) as? [String: Any]
        )
        XCTAssertEqual(json["format"] as? String, "tunnelvision.evidence.capture")
        XCTAssertEqual(json["formatVersion"] as? Int, EvidenceBundleFormat.version)
        XCTAssertEqual(json["sessionID"] as? Int, 7)
        XCTAssertEqual(json["file"] as? String, "capture.pcapng")
        XCTAssertEqual(json["fileFormat"] as? String, "pcapng")
        XCTAssertEqual(json["linkType"] as? Int, 101)
        // Sin ningún fichero leído, el `snaplen` es una clave ausente y no un cero.
        XCTAssertNil(json["snaplen"])
        XCTAssertEqual(json["contents"] as? String, EvidenceWording.captureContentsNote)
        XCTAssertEqual(json["packetComments"] as? String, EvidenceWording.capturePacketCommentsNote)

        let packets = try XCTUnwrap(json["packets"] as? [String: Any])
        XCTAssertEqual(packets["recorded"] as? Int, 11)
        XCTAssertEqual(packets["written"] as? Int, 5)
        XCTAssertEqual(
            packets["withoutBytes"] as? [String: Int],
            ["notCaptured": 1, "captureFileMissing": 5, "recordUnreadable": 0]
        )
        XCTAssertEqual(json["writtenOutsideSession"] as? [String: Int], ["beforeStart": 1, "afterEnd": 0])
        let files = try XCTUnwrap(json["sourceFiles"] as? [[String: Any]])
        XCTAssertEqual(files.map { $0["state"] as? String }, ["read", "missing"])
    }

    /// La nota tiene que nombrar las claves que explica tal como salen en el documento.
    func testTheContentsNoteNamesTheKeysItExplains() {
        let note = EvidenceWording.captureContentsNote
        for key in ["withoutBytes", "notCaptured", "captureFileMissing", "recordUnreadable", "writtenOutsideSession"] {
            XCTAssertTrue(note.contains(key), "la nota no nombra \(key)")
        }
        XCTAssertTrue(EvidenceWording.capturePacketCommentsNote.contains("flow=<id> findings=<id>,<id>"))
    }
}
