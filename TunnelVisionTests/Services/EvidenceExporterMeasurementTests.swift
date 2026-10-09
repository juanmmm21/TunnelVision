import Foundation
import XCTest
@testable import Shared

/// La medida de una exportación grande: cuánto tarda y cuánta memoria pide de más.
///
/// No afirma un umbral —lo que mide depende de la máquina— y por eso **no corre con la suite**:
/// siembra cientos de megas y tarda minutos. Se pide a propósito:
///
/// ```bash
/// TEST_RUNNER_TV_MEASURE_EVIDENCE_EXPORT=1 xcodebuild test -scheme TunnelVision \
///   -destination 'platform=iOS Simulator,name=iPhone 17' \
///   -only-testing:TunnelVisionTests/EvidenceExporterMeasurementTests
/// ```
///
/// `TEST_RUNNER_TV_MEASURE_FLOWS`, `…_PACKETS_PER_FLOW` y `…_PACKET_BYTES` cambian el tamaño. La
/// cifra sale en una línea que empieza por `EVIDENCE-EXPORT-MEASURE`.
///
/// Existe como test y no como una nota porque lo que el paquete tiene en memoria —todos los flujos
/// y sus documentos— crece con cada cosa que se le añada, y quien la añada tiene que poder volver a
/// medir con el mismo comando.
final class EvidenceExporterMeasurementTests: XCTestCase {

    private var root: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evidence-export-measure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Captures", isDirectory: true),
            withIntermediateDirectories: true
        )
        dbURL = PersistenceFixtures.temporaryDatabaseURL()
    }

    override func tearDownWithError() throws {
        PersistenceFixtures.removeDatabase(at: dbURL)
        try? FileManager.default.removeItem(at: root)
    }

    func testALargeSessionExportsWithinMeasuredTimeAndMemory() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TV_MEASURE_EVIDENCE_EXPORT"] == "1" else {
            throw XCTSkip("medida bajo demanda: TEST_RUNNER_TV_MEASURE_EVIDENCE_EXPORT=1")
        }
        let flowCount = environment["TV_MEASURE_FLOWS"].flatMap(Int.init) ?? 20_000
        let packetsPerFlow = environment["TV_MEASURE_PACKETS_PER_FLOW"].flatMap(Int.init) ?? 20
        let packetBytes = environment["TV_MEASURE_PACKET_BYTES"].flatMap(Int.init) ?? 600

        let captureDir = root.appendingPathComponent("Captures", isDirectory: true)
        let store = try FlowStore(databaseURL: dbURL, anchor: PersistenceFixtures.anchor)
        let sessionID = try await seed(
            store, captureDir: captureDir,
            flowCount: flowCount, packetsPerFlow: packetsPerFlow, packetBytes: packetBytes
        )
        let exporter = EvidenceExporter(
            directory: root.appendingPathComponent("EvidenceExports", isDirectory: true),
            captureDirectory: captureDir,
            openingStore: { store }
        )

        let sampler = FootprintSampler()
        let before = FootprintSampler.footprint()
        sampler.start()
        let started = Date()
        let result = try await exporter.export(
            sessionID: sessionID, exportedWith: "measure", now: PersistenceFixtures.date(1_000_000)
        )
        let elapsed = Date().timeIntervalSince(started)
        let peak = await sampler.stop()

        XCTAssertEqual(result.flowCount, flowCount)
        XCTAssertEqual(result.capture.packets.written, flowCount * packetsPerFlow)

        let megabyte = 1_048_576.0
        let captureBytes = Double(flowCount * packetsPerFlow * packetBytes)
        print(
            "EVIDENCE-EXPORT-MEASURE flows=\(flowCount) packets=\(flowCount * packetsPerFlow)"
            + " captureMB=\(String(format: "%.1f", captureBytes / megabyte))"
            + " sourceFiles=\(result.capture.sourceFiles.count)"
            + " seconds=\(String(format: "%.2f", elapsed))"
            + " footprintBeforeMB=\(String(format: "%.1f", Double(before) / megabyte))"
            + " footprintPeakMB=\(String(format: "%.1f", Double(peak) / megabyte))"
            + " zipMB=\(String(format: "%.1f", Double(result.byteCount) / megabyte))"
        )
    }

    /// Una sesión cerrada de `flowCount` flujos, cada uno con `packetsPerFlow` paquetes capturados.
    private func seed(
        _ store: FlowStore,
        captureDir: URL,
        flowCount: Int,
        packetsPerFlow: Int,
        packetBytes: Int
    ) async throws -> Int64 {
        let writer = try PcapWriter(config: .init(directory: captureDir))
        let project = try await store.createAuditProject(
            AuditProjectDraft(
                name: "Measured", bundleIdentifier: nil, catalogueVersion: nil,
                allowlist: [AllowlistEntry(pattern: try DomainPattern(parsing: "*.example-health.com"), note: "")]
            ),
            at: PersistenceFixtures.date(0)
        )
        let session = try await store.startAuditSession(
            AuditSessionDraft(
                projectID: project.id,
                kind: .audit(AppRelease(version: "1.0", build: "1")),
                environment: AuditEnvironment(deviceModel: "iPhone18,3", osVersion: "27.0", toolVersion: "measure"),
                inspection: InspectionConditions(inspectionEnabled: false, caTrusted: false),
                notes: ""
            ),
            at: PersistenceFixtures.date(1)
        )

        let payload = Data(repeating: 0x5A, count: packetBytes)
        for index in 0..<flowCount {
            // Remoto y puerto local varían juntos para que cada flujo tenga su 5-tupla, y uno de
            // cada diez va a un host fuera de la allowlist: un paquete sin hallazgos no mide
            // `findings.json` ni los comentarios de la captura.
            let remote = ModelFixtures.v4(11, UInt8(index >> 16 & 0xFF), UInt8(index >> 8 & 0xFF), UInt8(index & 0xFF))
            let localPort = UInt16(10_000 + index % 50_000)
            let second = UInt64(2 + index % 3_000)
            let flowID = try await store.upsertFlow(PersistenceFixtures.flow(
                remote: remote, localPort: localPort, firstSeen: second, lastSeen: second + 1,
                sni: index % 10 == 0 ? "tracker-\(index).example.net" : "api-\(index % 40).example-health.com"
            ))
            var metas: [PacketMeta] = []
            metas.reserveCapacity(packetsPerFlow)
            for _ in 0..<packetsPerFlow {
                let location = try await writer.write(
                    packet: payload, originalLength: packetBytes,
                    timestamp: Int64(1_700_000_000 + second) * 1_000_000_000
                )
                metas.append(PersistenceFixtures.packet(
                    timestamp: second,
                    key: PersistenceFixtures.key(remote: remote, localPort: localPort),
                    capture: location
                ))
            }
            try await store.appendPackets(metas, flowID: flowID)
        }
        await writer.close()
        _ = try await store.endAuditSession(id: session.id, at: PersistenceFixtures.date(4_000))
        return session.id
    }
}

/// Muestrea la huella de memoria del proceso mientras corre otra cosa y se queda con el máximo.
private final class FootprintSampler: @unchecked Sendable {

    private let lock = NSLock()
    private var peak: UInt64 = 0
    private var task: Task<Void, Never>?

    func start() {
        task = Task.detached(priority: .high) { [self] in
            while !Task.isCancelled {
                let now = Self.footprint()
                lock.withLock { peak = max(peak, now) }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    func stop() async -> UInt64 {
        task?.cancel()
        await task?.value
        let last = Self.footprint()
        return lock.withLock { max(peak, last) }
    }

    /// `phys_footprint`: lo que el sistema le cuenta al proceso contra su límite de memoria.
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
