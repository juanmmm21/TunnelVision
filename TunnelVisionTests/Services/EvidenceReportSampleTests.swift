import Foundation
import XCTest
@testable import Shared

/// El `report.pdf` de la sesión que siembra `-TVSeedFixture`, escrito donde se pueda abrir.
///
/// No afirma nada sobre cómo se ve —eso no lo afirma un test— y por eso **no corre con la suite**:
/// existe para que quien cambie el informe pueda volver a tenerlo delante con un comando, sin
/// conducir la app hasta la hoja de exportar y sacar el zip de su contenedor:
///
/// ```bash
/// TEST_RUNNER_TV_REPORT_SAMPLE_DIRECTORY=/tmp/report xcodebuild test -scheme TunnelVision \
///   -destination 'platform=iOS Simulator,name=iPhone 17' \
///   -only-testing:TunnelVisionTests/EvidenceReportSampleTests
/// ```
///
/// Deja `report-session-<id>.pdf` por cada sesión sembrada (la baseline y la auditoría).
/// `TEST_RUNNER_TV_REPORT_SAMPLE_FLOWS` cambia cuántos flujos lleva la captura sembrada, para
/// verlo con una sesión grande: cada sesión se lleva un cuarto.
final class EvidenceReportSampleTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evidence-report-sample-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTheSeededSessionsAreWrittenAsReports() async throws {
        guard let destination = ProcessInfo.processInfo.environment["TV_REPORT_SAMPLE_DIRECTORY"] else {
            throw XCTSkip("muestra bajo demanda: TEST_RUNNER_TV_REPORT_SAMPLE_DIRECTORY=<carpeta>")
        }
        let output = URL(fileURLWithPath: destination, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let database = root.appendingPathComponent("TunnelVision.sqlite")
        let captures = root.appendingPathComponent("Captures", isDirectory: true)
        let seeder = FixtureSeeder(
            databaseURL: database,
            captureDirectory: captures,
            plaintextDirectory: root.appendingPathComponent("Plaintext", isDirectory: true)
        )
        // Un instante fijo: el informe de la muestra es el mismo cada vez que se pide.
        var spec = FixtureSpec.default(endingAt: Date(timeIntervalSince1970: 1_800_000_000))
        if let flows = ProcessInfo.processInfo.environment["TV_REPORT_SAMPLE_FLOWS"].flatMap(Int.init) {
            spec.bulkFlowCount = flows
        }
        _ = try await seeder.seed(CaptureFixture.make(spec))

        let store = try FlowStore(databaseURL: database)
        let exporter = EvidenceExporter(
            directory: root.appendingPathComponent("EvidenceExports", isDirectory: true),
            captureDirectory: captures,
            openingStore: { store }
        )
        var written = 0
        for project in try await store.auditProjects() {
            for session in try await store.auditSessions(forProject: project.id) {
                let result = try await exporter.export(
                    sessionID: session.id,
                    exportedWith: "1.0.0 (1)",
                    now: Date(timeIntervalSince1970: 1_800_003_600)
                )
                let report = try XCTUnwrap(
                    TestZipReader.read(result.url).first {
                        $0.path.hasSuffix("/" + EvidenceBundleFormat.reportFileName)
                    }
                )
                try report.data.write(
                    to: output.appendingPathComponent("report-session-\(session.id).pdf"),
                    options: .atomic
                )
                written += 1
            }
        }
        XCTAssertGreaterThan(written, 0, "el fixture no sembró ninguna sesión de auditoría")
    }
}
