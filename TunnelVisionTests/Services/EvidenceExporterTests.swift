import Foundation
import PDFKit
import XCTest
@testable import Shared

/// Tests del exportador del paquete de evidencia, de punta a punta: un `FlowStore` real, capturas
/// escritas por un `PcapWriter` real y el `.zip` abierto con un lector que no comparte código con
/// nadie. Lo que se afirma es lo que recibe un evaluador: que dentro del zip están los ficheros del
/// paquete, que el manifiesto dice la verdad sobre cada uno, y que un fallo no deja en disco nada
/// que se pueda confundir con evidencia.
final class EvidenceExporterTests: XCTestCase {

    private var root: URL!
    private var dbURL: URL!
    private var captureDir: URL!
    private var exportDir: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evidence-export-tests-\(UUID().uuidString)", isDirectory: true)
        captureDir = root.appendingPathComponent("Captures", isDirectory: true)
        exportDir = root.appendingPathComponent("EvidenceExports", isDirectory: true)
        try FileManager.default.createDirectory(at: captureDir, withIntermediateDirectories: true)
        dbURL = PersistenceFixtures.temporaryDatabaseURL()
    }

    override func tearDownWithError() throws {
        PersistenceFixtures.removeDatabase(at: dbURL)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Utilidades

    private static let a = ModelFixtures.v4(1, 1, 1, 1)
    private static let b = ModelFixtures.v4(2, 2, 2, 2)
    private static let toolVersion = "1.1 (4)"
    private static let exportedAt = PersistenceFixtures.date(200)
    private static let folderName = "tunnelvision-evidence-session-1-20231114-221640"

    private static let bundleFileNames = [
        "capture.json", "capture.pcapng", "findings.json", "flows.csv", "flows.json",
        "manifest.json", "report.pdf", "session.json",
    ]

    private func makeStore() throws -> FlowStore {
        try FlowStore(databaseURL: dbURL, anchor: PersistenceFixtures.anchor)
    }

    private func makeExporter(_ store: FlowStore) -> EvidenceExporter {
        EvidenceExporter(directory: exportDir, captureDirectory: captureDir, openingStore: { store })
    }

    private func startSession(
        _ store: FlowStore,
        catalogueVersion: String? = nil,
        allowlist: [String] = []
    ) async throws -> AuditSession {
        let project = try await store.createAuditProject(
            AuditProjectDraft(
                name: "Example Health",
                bundleIdentifier: "com.example.health",
                catalogueVersion: catalogueVersion,
                allowlist: try allowlist.map { AllowlistEntry(pattern: try DomainPattern(parsing: $0), note: "") }
            ),
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
            at: PersistenceFixtures.date(10)
        )
    }

    private func flow(
        _ store: FlowStore,
        remote: IPAddress,
        localPort: UInt16 = 51000,
        sni: String? = "api.example-health.com",
        streamOpening: StreamOpening? = nil
    ) async throws -> Int64 {
        try await store.upsertFlow(PersistenceFixtures.flow(
            remote: remote, localPort: localPort, firstSeen: 12, lastSeen: 20,
            sni: sni, streamOpening: streamOpening
        ))
    }

    /// Escribe un paquete en la captura y devuelve su metadato, ya con dónde quedó.
    private func captured(
        _ writer: PcapWriter,
        at seconds: UInt64,
        remote: IPAddress,
        fill: UInt8,
        length: Int = 40
    ) async throws -> PacketMeta {
        let location = try await writer.write(
            packet: Data(repeating: fill, count: length),
            originalLength: length,
            timestamp: Int64(1_700_000_000 + seconds) * 1_000_000_000
        )
        return PersistenceFixtures.packet(
            timestamp: seconds, key: PersistenceFixtures.key(remote: remote), capture: location
        )
    }

    private func end(_ store: FlowStore, _ session: AuditSession) async throws {
        _ = try await store.endAuditSession(id: session.id, at: PersistenceFixtures.date(100))
    }

    private func export(_ store: FlowStore, _ session: AuditSession) async throws -> EvidenceExportResult {
        try await makeExporter(store).export(
            sessionID: session.id, exportedWith: Self.toolVersion, now: Self.exportedAt
        )
    }

    /// Lo que la exportación lanzó, o un fallo del test si no lanzó nada.
    private func exportError(
        _ exporter: EvidenceExporter, sessionID: Int64,
        file: StaticString = #filePath, line: UInt = #line
    ) async -> EvidenceExportError? {
        do {
            _ = try await exporter.export(
                sessionID: sessionID, exportedWith: Self.toolVersion, now: Self.exportedAt
            )
            XCTFail("la exportación tenía que fallar", file: file, line: line)
            return nil
        } catch let error as EvidenceExportError {
            return error
        } catch {
            XCTFail("un error sin tipar: \(error)", file: file, line: line)
            return nil
        }
    }

    /// Los ficheros del zip por su nombre dentro de la carpeta del paquete.
    private func files(in archive: URL, folder: String = folderName) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for entry in try TestZipReader.read(archive) where !entry.isDirectory {
            let prefix = folder + "/"
            XCTAssertTrue(entry.path.hasPrefix(prefix), "\(entry.path) está fuera de la carpeta del paquete")
            files[String(entry.path.dropFirst(prefix.count))] = entry.data
        }
        return files
    }

    private func json(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(data)) as? [String: Any])
    }

    private func leftOnDisk() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: exportDir.path)) ?? []).sorted()
    }

    /// Una sesión cerrada con dos flujos y tres paquetes capturados.
    private func seedClosedSession(_ store: FlowStore) async throws -> AuditSession {
        let writer = try PcapWriter(config: .init(directory: captureDir))
        let session = try await startSession(store, allowlist: ["api.example-health.com"])
        let first = try await flow(store, remote: Self.a)
        let second = try await flow(store, remote: Self.b, sni: "tracker.example.net")
        try await store.appendPackets([
            try await captured(writer, at: 12, remote: Self.a, fill: 0xA1),
            try await captured(writer, at: 13, remote: Self.a, fill: 0xA2, length: 61),
        ], flowID: first)
        try await store.appendPackets([try await captured(writer, at: 14, remote: Self.b, fill: 0xB1)], flowID: second)
        await writer.close()
        _ = try await store.addMarker(.consentGiven, toSession: session.id, at: PersistenceFixtures.date(11))
        try await end(store, session)
        return session
    }

    // MARK: - El zip

    func testTheArchiveHoldsEveryFileOfTheBundleInOneFolder() async throws {
        let store = try makeStore()
        let session = try await seedClosedSession(store)

        let result = try await export(store, session)

        XCTAssertEqual(result.url, exportDir.appendingPathComponent(Self.folderName + ".zip"))
        let entries = try TestZipReader.read(result.url)
        XCTAssertEqual(
            entries.filter { !$0.isDirectory }.map(\.path).sorted(),
            Self.bundleFileNames.map { Self.folderName + "/" + $0 }
        )
        XCTAssertEqual(result.fileNames, Self.bundleFileNames)

        let size = try XCTUnwrap(try result.url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertEqual(result.byteCount, UInt64(size))
        XCTAssertGreaterThan(size, 0)
    }

    func testTheManifestInTheArchiveIsTheDigestOfEveryOtherFileInIt() async throws {
        let store = try makeStore()
        let session = try await seedClosedSession(store)

        let files = try files(in: try await export(store, session).url)

        let manifest = try json(files["manifest.json"])
        let listed = try XCTUnwrap(manifest["files"] as? [[String: Any]])
        XCTAssertEqual(
            listed.compactMap { $0["name"] as? String },
            Self.bundleFileNames.filter { $0 != "manifest.json" }
        )
        for entry in listed {
            let name = try XCTUnwrap(entry["name"] as? String)
            let data = try XCTUnwrap(files[name], name)
            XCTAssertEqual(entry["byteCount"] as? Int, data.count, name)
            XCTAssertEqual(entry["sha256"] as? String, EvidenceManifest.sha256(of: data), name)
        }
        XCTAssertEqual(manifest["sessionID"] as? Int, Int(session.id))
    }

    func testTheDocumentsAreThoseOfTheSessionWithItsMarkersAndTheToolThatExported() async throws {
        let store = try makeStore()
        let session = try await seedClosedSession(store)

        let result = try await export(store, session)
        let files = try files(in: result.url)

        let document = try json(files["session.json"])
        XCTAssertEqual(document["exportedWith"] as? String, Self.toolVersion)
        XCTAssertEqual(document["exportedAt"] as? String, "2023-11-14T22:16:40.000Z")
        let written = try XCTUnwrap(document["session"] as? [String: Any])
        XCTAssertEqual(written["id"] as? Int, Int(session.id))
        let markers = try XCTUnwrap(document["markers"] as? [[String: Any]])
        XCTAssertEqual(markers.map { $0["kind"] as? String }, ["consentGiven"])

        let flows = try XCTUnwrap(try json(files["flows.json"])["flows"] as? [[String: Any]])
        XCTAssertEqual(flows.count, 2)
        XCTAssertEqual(result.flowCount, 2)

        // El host fuera de la allowlist es un hallazgo, y el resultado lo cuenta igual que el fichero.
        let findings = try XCTUnwrap(try json(files["findings.json"])["findings"] as? [[String: Any]])
        XCTAssertTrue(findings.contains { $0["kind"] as? String == FindingKind.hostNotInAllowlist.rawValue })
        XCTAssertEqual(result.findingCount, findings.count)

        let csv = try XCTUnwrap(String(data: try XCTUnwrap(files["flows.csv"]), encoding: .utf8))
        XCTAssertEqual(csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }.count, 3)
    }

    func testTheCaptureInTheArchiveHoldsTheSessionsPackets() async throws {
        let store = try makeStore()
        let session = try await seedClosedSession(store)

        let result = try await export(store, session)
        let files = try files(in: result.url)

        let decoded = try TestPcapngReader.read(try XCTUnwrap(files["capture.pcapng"]))
        XCTAssertEqual(decoded.packets.map(\.data), [
            Data(repeating: 0xA1, count: 40),
            Data(repeating: 0xA2, count: 61),
            Data(repeating: 0xB1, count: 40),
        ])
        XCTAssertEqual(
            decoded.sections.first?.options,
            [.init(code: 4, value: Data("TunnelVision \(Self.toolVersion)".utf8))]
        )
    }

    func testTheSessionNoteNamesTheCaptureThatTravelsBesideIt() async throws {
        let store = try makeStore()
        let session = try await seedClosedSession(store)

        let files = try files(in: try await export(store, session).url)

        let contents = try XCTUnwrap(try json(files["session.json"])["contents"] as? String)
        XCTAssertTrue(contents.contains("a capture of the session's packets"), contents)
        XCTAssertTrue(contents.contains("Decrypted content is not part of this bundle"), contents)
    }

    // MARK: - Lo que el resultado dice de la captura

    func testTheResultCarriesWhatTheCaptureLacksAsWrittenInTheArchive() async throws {
        let store = try makeStore()
        let writer = try PcapWriter(config: .init(directory: captureDir))
        let session = try await startSession(store)
        let first = try await flow(store, remote: Self.a)
        let kept = try await captured(writer, at: 12, remote: Self.a, fill: 0xA1)
        try await writer.rotate()
        let gone = try await captured(writer, at: 13, remote: Self.a, fill: 0xA2)
        await writer.close()
        let neverCaptured = PersistenceFixtures.packet(
            timestamp: 14, key: PersistenceFixtures.key(remote: Self.a), capture: nil
        )
        try await store.appendPackets([kept, gone, neverCaptured], flowID: first)
        // El segundo fichero se borra a mano: es lo único que se lleva evidencia.
        let second = try XCTUnwrap(CaptureDirectory.files(in: captureDir).last)
        try FileManager.default.removeItem(at: second.url)
        try await end(store, session)

        let result = try await export(store, session)

        XCTAssertEqual(
            result.capture.packets,
            EvidencePacketTally(written: 1, lost: [.captureFileMissing: 1, .notCaptured: 1])
        )
        let packets = try XCTUnwrap(
            try json(try files(in: result.url)["capture.json"])["packets"] as? [String: Any]
        )
        XCTAssertEqual(packets["recorded"] as? Int, 3)
        XCTAssertEqual(packets["written"] as? Int, 1)
        let withoutBytes = try XCTUnwrap(packets["withoutBytes"] as? [String: Any])
        XCTAssertEqual(withoutBytes["captureFileMissing"] as? Int, 1)
        XCTAssertEqual(withoutBytes["notCaptured"] as? Int, 1)
    }

    func testASessionWithNoTrafficStillExportsAWholeBundle() async throws {
        let store = try makeStore()
        let session = try await startSession(store)
        try await end(store, session)

        let result = try await export(store, session)

        XCTAssertEqual(result.flowCount, 0)
        XCTAssertEqual(result.findingCount, 0)
        XCTAssertEqual(result.capture.packets, EvidencePacketTally())
        let files = try files(in: result.url)
        XCTAssertEqual(files.keys.sorted(), Self.bundleFileNames)
        XCTAssertEqual(try TestPcapngReader.read(try XCTUnwrap(files["capture.pcapng"])).packets, [])
    }

    // MARK: - Todos los flujos

    func testEveryFlowOfTheSessionIsListedHoweverManyThereAre() async throws {
        let store = try makeStore()
        let writer = try PcapWriter(config: .init(directory: captureDir))
        let session = try await startSession(store)
        // Más de los que cabían en cualquier tope que se le hubiera puesto a la lectura: el último
        // lleva un paquete, y sin su flujo en la lista la captura pararía la exportación.
        let count = 1_250
        var last: Int64 = 0
        for index in 0..<count {
            last = try await flow(store, remote: Self.a, localPort: UInt16(20_000 + index))
        }
        let location = try await writer.write(
            packet: Data(repeating: 0xCC, count: 40), originalLength: 40,
            timestamp: 1_700_000_015 * 1_000_000_000
        )
        await writer.close()
        try await store.appendPackets([
            PersistenceFixtures.packet(
                timestamp: 15,
                key: PersistenceFixtures.key(remote: Self.a, localPort: UInt16(20_000 + count - 1)),
                capture: location
            ),
        ], flowID: last)
        try await end(store, session)

        let result = try await export(store, session)

        XCTAssertEqual(result.flowCount, count)
        XCTAssertEqual(result.capture.flows.count, count)
        XCTAssertEqual(result.capture.packets.written, 1)
        let flows = try XCTUnwrap(
            try json(try files(in: result.url)["flows.json"])["flows"] as? [[String: Any]]
        )
        XCTAssertEqual(flows.count, count)
    }

    // MARK: - Lo que queda en disco

    func testOnlyTheArchiveIsLeftOnDisk() async throws {
        let store = try makeStore()
        let session = try await seedClosedSession(store)

        _ = try await export(store, session)

        XCTAssertEqual(leftOnDisk(), [Self.folderName + ".zip"])
    }

    func testAnExportTakesThePreviousOneWithItAndNothingElse() async throws {
        let store = try makeStore()
        let session = try await seedClosedSession(store)
        let exporter = makeExporter(store)
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        // Lo que dejaría una exportación interrumpida, y un fichero que no es nuestro.
        let abandoned = exportDir.appendingPathComponent("tunnelvision-evidence-session-9-20200101-000000")
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: abandoned.appendingPathComponent("capture.pcapng"))
        try Data("x".utf8).write(to: exportDir.appendingPathComponent("notes.txt"))

        _ = try await exporter.export(
            sessionID: session.id, exportedWith: Self.toolVersion, now: PersistenceFixtures.date(200)
        )
        let later = try await exporter.export(
            sessionID: session.id, exportedWith: Self.toolVersion, now: PersistenceFixtures.date(260)
        )

        XCTAssertEqual(leftOnDisk(), ["notes.txt", later.url.lastPathComponent])
        XCTAssertEqual(later.url.lastPathComponent, "tunnelvision-evidence-session-1-20231114-221740.zip")
    }

    func testTwoExportsOfTheSameSessionAtTheSameInstantCarryTheSameEvidence() async throws {
        let store = try makeStore()
        let session = try await seedClosedSession(store)

        var first = try files(in: try await export(store, session).url)
        var second = try files(in: try await export(store, session).url)

        // El PDF y el manifiesto que lo cubre son los únicos que no salen byte a byte: quien
        // escribe el PDF es el sistema, y le pone la hora a la que lo hizo y un identificador
        // propio. Lo que dice sí es lo mismo.
        let reports = [first.removeValue(forKey: "report.pdf"), second.removeValue(forKey: "report.pdf")]
        let manifests = [first.removeValue(forKey: "manifest.json"), second.removeValue(forKey: "manifest.json")]
        XCTAssertEqual(first.count, 6)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try pageTexts(of: reports[0]), try pageTexts(of: reports[1]))

        let listed = try manifests.map { manifest in
            try XCTUnwrap(try json(manifest)["files"] as? [[String: Any]])
                .filter { $0["name"] as? String != "report.pdf" }
                .map { "\($0["name"] ?? "") \($0["byteCount"] ?? "") \($0["sha256"] ?? "")" }
        }
        XCTAssertEqual(listed[0].count, 6)
        XCTAssertEqual(listed[0], listed[1])
    }

    // MARK: - El informe

    private func pageTexts(of pdf: Data?) throws -> [String] {
        let document = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(pdf)))
        return try (0..<document.pageCount).map { try XCTUnwrap(document.page(at: $0)?.string) }
    }

    func testTheReportInTheArchiveIsAPDFOfThisSessionOnA4() async throws {
        let store = try makeStore()
        let session = try await seedClosedSession(store)

        let files = try files(in: try await export(store, session).url)

        let document = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(files["report.pdf"])))
        XCTAssertGreaterThan(document.pageCount, 1)
        let box = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(box.width, 595.28, accuracy: 0.01)
        XCTAssertEqual(box.height, 841.89, accuracy: 0.01)

        let text = try pageTexts(of: files["report.pdf"]).joined(separator: "\n")
        XCTAssertTrue(text.contains("Network evidence report"))
        XCTAssertTrue(text.contains("Example Health · 2.4.0 (187) · session \(session.id)"))
        XCTAssertTrue(text.contains("Page 1 of \(document.pageCount)"))
        XCTAssertEqual(
            document.documentAttributes?[PDFDocumentAttribute.creatorAttribute] as? String,
            "TunnelVision \(Self.toolVersion)"
        )
    }

    /// El informe se escribe con el `capture.json` que va a su lado, no con otro recuento.
    func testTheReportCountsThePacketsThatTheCaptureBesideItCounts() async throws {
        let store = try makeStore()
        let session = try await seedClosedSession(store)

        let result = try await export(store, session)
        let text = try pageTexts(of: try files(in: result.url)["report.pdf"]).joined(separator: "\n")

        XCTAssertEqual(result.capture.packets.written, 3)
        XCTAssertTrue(text.contains("Every packet the session recorded is in capture.pcapng."))
        XCTAssertTrue(text.contains("Packets recorded 3"), text)
        // Lo que el paquete promete no decir tampoco lo dice dibujado.
        XCTAssertNil(text.range(of: #"\bpassed\b"#, options: [.regularExpression, .caseInsensitive]))
    }

    // MARK: - Lo que no se exporta

    func testAnOpenSessionIsRefusedAndNothingIsWritten() async throws {
        let store = try makeStore()
        let session = try await startSession(store)
        _ = try await flow(store, remote: Self.a)

        let error = await exportError(makeExporter(store), sessionID: session.id)

        XCTAssertEqual(error, .sessionStillOpen)
        XCTAssertEqual(leftOnDisk(), [])
    }

    func testASessionThatIsNoLongerThereIsSaidSo() async throws {
        let store = try makeStore()
        let session = try await seedClosedSession(store)
        try await store.deleteAuditSession(id: session.id)

        let error = await exportError(makeExporter(store), sessionID: session.id)

        XCTAssertEqual(error, .sessionNotFound)
        XCTAssertEqual(leftOnDisk(), [])
    }

    func testAProjectNamingACatalogueThatIsNotBundledIsNotExportedWithAnother() async throws {
        let store = try makeStore()
        let session = try await startSession(store, catalogueVersion: "tr-03161-1_9.9")
        try await end(store, session)

        let error = await exportError(makeExporter(store), sessionID: session.id)

        XCTAssertEqual(error, .catalogueNotBundled(identifier: "tr-03161-1_9.9"))
        XCTAssertEqual(leftOnDisk(), [])
    }

    func testAHistoryThatDoesNotOpenIsAHistoryError() async throws {
        struct Unopenable: Error {}
        let exporter = EvidenceExporter(
            directory: exportDir, captureDirectory: captureDir, openingStore: { throw Unopenable() }
        )

        let error = await exportError(exporter, sessionID: 1)

        guard case .historyUnreadable(.queryFailed) = error else {
            return XCTFail("se esperaba historyUnreadable, llegó \(String(describing: error))")
        }
    }

    func testACaptureDirectoryThatDoesNotResolveStopsTheExportBeforeReadingAnything() async throws {
        struct NoContainer: Error {}
        let opened = Counter()
        let store = try makeStore()
        let exporter = EvidenceExporter(
            resolvingDirectory: { [exportDir] in try XCTUnwrap(exportDir) },
            resolvingCaptureDirectory: { throw NoContainer() },
            openingStore: {
                opened.increment()
                return store
            }
        )

        let error = await exportError(exporter, sessionID: 1)

        guard case .captureDirectoryUnavailable = error else {
            return XCTFail("se esperaba captureDirectoryUnavailable, llegó \(String(describing: error))")
        }
        XCTAssertEqual(opened.value, 0)
    }

    func testADestinationThatCannotBeCreatedIsAWriteFailure() async throws {
        let store = try makeStore()
        let session = try await seedClosedSession(store)
        // Un fichero donde tendría que ir el directorio.
        try Data("x".utf8).write(to: exportDir)

        let error = await exportError(makeExporter(store), sessionID: session.id)

        guard case .writeFailed = error else {
            return XCTFail("se esperaba writeFailed, llegó \(String(describing: error))")
        }
    }

    // MARK: - Nombres

    func testTheFolderIsNamedAfterTheSessionAndTheInstantInUTC() {
        XCTAssertEqual(
            EvidenceExportNaming.folderName(sessionID: 42, exportedAt: Date(timeIntervalSince1970: 0)),
            "tunnelvision-evidence-session-42-19700101-000000"
        )
    }

    func testOnlyNamesTheExporterWroteAreRecognisedAsItsOwn() {
        XCTAssertTrue(EvidenceExportNaming.isExportName("tunnelvision-evidence-session-1-20231114-221640"))
        XCTAssertTrue(EvidenceExportNaming.isExportName("tunnelvision-evidence-session-1-20231114-221640.zip"))
        XCTAssertFalse(EvidenceExportNaming.isExportName("tunnelvision-connections-20231114-221640.json"))
        XCTAssertFalse(EvidenceExportNaming.isExportName("notes.txt"))
    }
}

/// Cuenta llamadas desde una closure `@Sendable`.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() { lock.withLock { count += 1 } }
}
