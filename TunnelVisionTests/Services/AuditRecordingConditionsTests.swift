import Foundation
import XCTest
import Shared

/// Tests de las condiciones que una sesión de auditoría declara al abrirse. Van al informe tal cual,
/// así que lo que se afirma es que nunca salgan vacías ni digan más de lo que se sabe.
@MainActor
final class AuditRecordingConditionsTests: XCTestCase {

    private struct Unreadable: Error {}

    func testTheToolVersionNeverLeavesAGap() {
        XCTAssertEqual(AuditRecordingConditions.toolVersion(marketing: "1.0.0", build: "1"), "1.0.0 (1)")
        XCTAssertEqual(AuditRecordingConditions.toolVersion(marketing: "1.0.0", build: nil), "1.0.0")
        XCTAssertEqual(AuditRecordingConditions.toolVersion(marketing: nil, build: "7"), "(7)")
        // Un campo vacío en una evidencia se lee como un dato perdido: se dice que no se sabe.
        XCTAssertEqual(AuditRecordingConditions.toolVersion(marketing: nil, build: nil), "unknown")
    }

    func testTheSimulatorReportsTheModelItSimulatesAndNotTheMacsArchitecture() {
        XCTAssertEqual(
            AuditRecordingConditions.deviceModel(environment: ["SIMULATOR_MODEL_IDENTIFIER": "iPhone18,3"]),
            "iPhone18,3"
        )
        XCTAssertFalse(AuditRecordingConditions.deviceModel(environment: [:]).isEmpty)
    }

    func testTheEnvironmentOfThisDeviceIsComplete() {
        let environment = AuditRecordingConditions.environment()

        XCTAssertFalse(environment.deviceModel.isEmpty)
        XCTAssertFalse(environment.osVersion.isEmpty)
        XCTAssertFalse(environment.toolVersion.isEmpty)
    }

    func testInspectionConditionsComeFromTheSettingsAndTheTrustOfTheCertificate() {
        let inspecting = AppSettings(tlsInspectionEnabled: true)
        let notInspecting = AppSettings(tlsInspectionEnabled: false)

        let both = AuditRecordingConditions.inspection(loadSettings: { inspecting }, availability: .ready)
        XCTAssertTrue(both.supportsPinningEvidence)

        let untrusted = AuditRecordingConditions.inspection(
            loadSettings: { inspecting }, availability: .certificateNotReady
        )
        XCTAssertEqual(untrusted, InspectionConditions(inspectionEnabled: true, caTrusted: false))

        let off = AuditRecordingConditions.inspection(loadSettings: { notInspecting }, availability: .ready)
        XCTAssertEqual(off, InspectionConditions(inspectionEnabled: false, caTrusted: true))
    }

    /// Unos ajustes ilegibles cuentan como inspección apagada, que es lo que la extensión hace con
    /// ellos: declarar lo contrario haría que el informe leyera pinning donde no hubo handshake.
    func testUnreadableSettingsCountAsInspectionOff() {
        let conditions = AuditRecordingConditions.inspection(
            loadSettings: { throw Unreadable() }, availability: .ready
        )

        XCTAssertFalse(conditions.inspectionEnabled)
        XCTAssertFalse(conditions.supportsPinningEvidence)
    }
}
