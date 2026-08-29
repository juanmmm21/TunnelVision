import Foundation
import XCTest
@testable import Shared

/// Tests del planificador del barrido de contenido descifrado (ADR 0007): quién se va y por qué, sin
/// tocar un solo fichero.
///
/// Lo que se afirma aquí es lo que separa este barrido del de capturas: la antigüedad ya no se mide
/// —viene aplicada sobre el índice— y lo que queda son dos razones distintas para borrar un fichero,
/// huérfano y techo, que no cuestan lo mismo. Un huérfano no le quita nada a nadie; una víctima del
/// techo es contenido que la caducidad del usuario habría conservado, y por eso sale señalada aparte.
final class PlaintextRetentionPlannerTests: XCTestCase {

    private func file(_ sequence: UInt32, bytes: UInt64) -> PlaintextFileInfo {
        PlaintextFileInfo(
            sequence: sequence,
            url: URL(fileURLWithPath: "/tmp/plaintext-\(sequence).tvpt"),
            byteCount: bytes
        )
    }

    // MARK: - Huérfanos

    func testDeletesFilesNoRowStillNames() {
        let plan = PlaintextRetentionPlanner.plan(
            files: [file(0, bytes: 100), file(1, bytes: 100), file(2, bytes: 100)],
            referenced: [2],
            openSequence: nil,
            ceiling: 1_000
        )

        XCTAssertEqual(plan.filesToDelete, [0, 1])
        // Un huérfano no tiene filas que soltar: eso es lo que lo hace huérfano.
        XCTAssertTrue(plan.sequencesToUnindex.isEmpty)
        XCTAssertEqual(plan.bytesReclaimed, 200)
        XCTAssertEqual(plan.bytesAfter, 100)
        XCTAssertFalse(plan.ceilingUnreachable)
    }

    func testKeepsEveryReferencedFileWhenUnderTheCeiling() {
        let plan = PlaintextRetentionPlanner.plan(
            files: [file(7, bytes: 50), file(8, bytes: 50)],
            referenced: [7, 8],
            openSequence: nil,
            ceiling: 1_000
        )

        XCTAssertFalse(plan.hasWork)
        XCTAssertEqual(plan.bytesAfter, 100)
    }

    func testNeverDeletesTheOpenFileEvenWhenOrphaned() {
        // El fichero abierto no está referenciado todavía —sus trozos aún no se han volcado al
        // índice—, que es exactamente el caso en que borrarlo sería peor.
        let plan = PlaintextRetentionPlanner.plan(
            files: [file(3, bytes: 10), file(4, bytes: 10)],
            referenced: [],
            openSequence: 4,
            ceiling: 1_000
        )

        XCTAssertEqual(plan.filesToDelete, [3])
    }

    // MARK: - El techo

    func testCeilingDeletesOldestFirstAndSaysWhichRowsGoWithThem() {
        let plan = PlaintextRetentionPlanner.plan(
            files: [file(0, bytes: 400), file(1, bytes: 400), file(2, bytes: 400)],
            referenced: [0, 1, 2],
            openSequence: nil,
            ceiling: 500
        )

        XCTAssertEqual(plan.filesToDelete, [0, 1])
        XCTAssertEqual(plan.sequencesToUnindex, [0, 1])
        XCTAssertEqual(plan.bytesAfter, 400)
        XCTAssertFalse(plan.ceilingUnreachable)
    }

    func testCeilingMeasuresOverWhatTheOrphansAlreadyFreed() {
        // Con los huérfanos fuera ya se cabe, así que el techo no pide ni un borrado de más: cada uno
        // que pidiera sería contenido vivo que el usuario no ha caducado.
        let plan = PlaintextRetentionPlanner.plan(
            files: [file(0, bytes: 900), file(1, bytes: 400)],
            referenced: [1],
            openSequence: nil,
            ceiling: 500
        )

        XCTAssertEqual(plan.filesToDelete, [0])
        XCTAssertTrue(plan.sequencesToUnindex.isEmpty)
    }

    func testCeilingIsUnreachableWhenTheOpenFileAloneIsOverIt() {
        let plan = PlaintextRetentionPlanner.plan(
            files: [file(0, bytes: 100), file(1, bytes: 900)],
            referenced: [0, 1],
            openSequence: 1,
            ceiling: 500
        )

        XCTAssertEqual(plan.filesToDelete, [0])
        XCTAssertEqual(plan.bytesAfter, 900)
        XCTAssertTrue(plan.ceilingUnreachable)
    }

    func testTheDefaultCeilingIsTheOneTheUserCannotRaise() {
        // Sin techo explícito se usa el del ADR 0007, que no es un ajuste. Si alguien lo convirtiera
        // en uno, esta llamada dejaría de compilar o de significar lo mismo.
        let plan = PlaintextRetentionPlanner.plan(
            files: [file(0, bytes: RetentionSettings.plaintextByteCeiling + 1)],
            referenced: [0],
            openSequence: nil
        )

        XCTAssertEqual(plan.filesToDelete, [0])
    }

    // MARK: - Qué fichero está abierto

    func testTheOpenFileIsTheNewestOneWhileMonitoring() {
        let files = [file(4, bytes: 1), file(9, bytes: 1), file(6, bytes: 1)]

        XCTAssertEqual(PlaintextRetentionPlanner.openSequence(files: files, isMonitoring: true), 9)
        // Con el túnel parado no hay ninguno abierto: darlo por abierto dejaría contenido descifrado
        // que nadie podría barrer nunca.
        XCTAssertNil(PlaintextRetentionPlanner.openSequence(files: files, isMonitoring: false))
        XCTAssertNil(PlaintextRetentionPlanner.openSequence(files: [], isMonitoring: true))
    }
}
