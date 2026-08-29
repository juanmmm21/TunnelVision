import Foundation
import XCTest
import Shared

/// Tests del planificador de retención (M9): quién se va cuando los topes aprietan.
///
/// Es una función pura sobre el listado del directorio, así que se afirma con ficheros de mentira y
/// tamaños de gigabytes sin escribir un byte — que es justo para lo que existe la separación entre
/// decidir (`RetentionPlanner`) y borrar (`StorageManager`).
final class RetentionPlannerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func file(_ sequence: UInt32, bytes: UInt64, createdDaysAgo: Double?) -> CaptureFileInfo {
        CaptureFileInfo(
            sequence: sequence,
            url: URL(fileURLWithPath: "/tmp/capture-\(sequence).pcap"),
            byteCount: bytes,
            createdAt: createdDaysAgo.map { now.addingTimeInterval(-$0 * 86_400) }
        )
    }

    private func plan(
        _ files: [CaptureFileInfo],
        age: RetentionAge = .unlimited,
        size: RetentionSize = .unlimited,
        recording: UInt32? = nil
    ) -> RetentionPlan {
        RetentionPlanner.plan(
            files: files,
            settings: RetentionSettings(maxAge: age, maxCaptureSize: size),
            now: now,
            recordingSequence: recording
        )
    }

    private let megabyte: UInt64 = 1024 * 1024

    // MARK: - Sin topes

    func testWithoutCapsThereIsNothingToDo() {
        let result = plan([
            file(0, bytes: 4 * 1024 * megabyte, createdDaysAgo: 400),
            file(1, bytes: 4 * 1024 * megabyte, createdDaysAgo: 399)
        ])

        XCTAssertFalse(result.hasWork)
        XCTAssertNil(result.historyCutoff)
        XCTAssertTrue(result.filesToDelete.isEmpty)
        XCTAssertEqual(result.bytesReclaimed, 0)
        XCTAssertFalse(result.sizeCapUnreachable)
    }

    // MARK: - Tope de antigüedad

    func testTheHistoryCutoffIsTheChosenAgeBeforeNow() {
        let result = plan([], age: .oneWeek)

        XCTAssertEqual(result.historyCutoff, now.addingTimeInterval(-7 * 86_400))
        // Hay trabajo aunque no haya ni un fichero: cuántas filas son más viejas que el corte no se sabe
        // hasta preguntárselo al store.
        XCTAssertTrue(result.hasWork)
    }

    func testAFileIsAgedOutByItsSuccessorsDateAndNotByItsOwn() {
        // El fichero 1 se abrió hace 9 días, así que **él** es más viejo que el corte de 7 — pero se le
        // estuvo escribiendo hasta que apareció el 2, hace 1 día: contiene tráfico más reciente que el
        // corte y borrarlo se lo llevaría. El 0, en cambio, dejó de escribirse hace 9 días.
        let result = plan([
            file(0, bytes: megabyte, createdDaysAgo: 10),
            file(1, bytes: megabyte, createdDaysAgo: 9),
            file(2, bytes: megabyte, createdDaysAgo: 1)
        ], age: .oneWeek)

        XCTAssertEqual(result.filesToDelete, [0])
        XCTAssertEqual(result.bytesReclaimed, megabyte)
        XCTAssertEqual(result.captureBytesAfter, 2 * megabyte)
    }

    func testTheNewestFileIsNeverAgedOut() {
        // No tiene sucesor, así que no hay nada que diga cuándo se dejó de escribir: puede ser el que se
        // está escribiendo ahora mismo, por antiguo que sea su nombre.
        let result = plan([file(0, bytes: megabyte, createdDaysAgo: 400)], age: .oneDay)

        XCTAssertTrue(result.filesToDelete.isEmpty)
        XCTAssertNotNil(result.historyCutoff, "el historial sí se corta")
    }

    func testAFileWhoseSuccessorHasNoDateIsLeftAlone() {
        // Sin la fecha del sucesor no se sabe hasta cuándo se escribió el anterior, y borrar por una
        // antigüedad que no se conoce es borrar a ciegas.
        let result = plan([
            file(0, bytes: megabyte, createdDaysAgo: 100),
            file(1, bytes: megabyte, createdDaysAgo: nil),
            file(2, bytes: megabyte, createdDaysAgo: 1)
        ], age: .oneWeek)

        XCTAssertTrue(result.filesToDelete.isEmpty)
    }

    // MARK: - Tope de tamaño

    func testTheSizeCapDeletesTheOldestFilesUntilItFits() {
        let result = plan([
            file(0, bytes: 200 * megabyte, createdDaysAgo: 3),
            file(1, bytes: 200 * megabyte, createdDaysAgo: 2),
            file(2, bytes: 100 * megabyte, createdDaysAgo: 1)
        ], size: .megabytes256)

        // 500 MB para un tope de 256: se van los dos más antiguos y queda uno de 100.
        XCTAssertEqual(result.filesToDelete, [0, 1])
        XCTAssertEqual(result.bytesReclaimed, 400 * megabyte)
        XCTAssertEqual(result.captureBytesAfter, 100 * megabyte)
        XCTAssertFalse(result.sizeCapUnreachable)
    }

    func testTheSizeCapStopsAsSoonAsItFits() {
        let result = plan([
            file(0, bytes: 200 * megabyte, createdDaysAgo: 3),
            file(1, bytes: 100 * megabyte, createdDaysAgo: 2),
            file(2, bytes: 100 * megabyte, createdDaysAgo: 1)
        ], size: .megabytes256)

        XCTAssertEqual(result.filesToDelete, [0], "no se borra ni un fichero más de lo necesario")
    }

    func testTheSizeCapMeasuresWhatTheAgeCapAlreadyReclaimed() {
        // 500 MB para un tope de 256, y el corte por antigüedad ya se lleva 300: el tope de tamaño mide
        // **después** y no pide ni un borrado más. Si midiera sobre el total de antes, borraría para
        // caber en un tope que ya se estaba cumpliendo.
        let result = plan([
            file(0, bytes: 300 * megabyte, createdDaysAgo: 30),
            file(1, bytes: 100 * megabyte, createdDaysAgo: 29),
            file(2, bytes: 100 * megabyte, createdDaysAgo: 1)
        ], age: .oneWeek, size: .megabytes256)

        XCTAssertEqual(result.filesToDelete, [0], "solo el que la antigüedad condena")
        XCTAssertEqual(result.captureBytesAfter, 200 * megabyte)
        XCTAssertFalse(result.sizeCapUnreachable)
    }

    // MARK: - El fichero que se está escribiendo

    func testTheRecordingFileIsNeverInThePlan() {
        let result = plan([
            file(0, bytes: 100 * megabyte, createdDaysAgo: 30),
            file(1, bytes: 300 * megabyte, createdDaysAgo: 29)
        ], age: .oneDay, size: .megabytes256, recording: 1)

        XCTAssertEqual(result.filesToDelete, [0])
        // 300 MB siguen por encima del tope de 256 y no hay nada más que borrar: se dice, en vez de
        // dejar al usuario con su tope incumplido y sin explicación.
        XCTAssertTrue(result.sizeCapUnreachable)
        XCTAssertEqual(result.captureBytesAfter, 300 * megabyte)
    }

    func testTheSizeCapIsReachableWhenNothingIsBeingRecorded() {
        // El mismo directorio con el túnel parado: ya no hay fichero abierto, así que el último también
        // se puede borrar.
        let result = plan([
            file(0, bytes: 100 * megabyte, createdDaysAgo: 30),
            file(1, bytes: 300 * megabyte, createdDaysAgo: 29)
        ], size: .megabytes256)

        XCTAssertEqual(result.filesToDelete, [0, 1])
        XCTAssertFalse(result.sizeCapUnreachable)
        XCTAssertEqual(result.captureBytesAfter, 0)
    }

    // MARK: - Forma del plan

    func testThePlanIsOrderedOldestFirstWhateverTheListingOrder() {
        let result = plan([
            file(2, bytes: 200 * megabyte, createdDaysAgo: 1),
            file(0, bytes: 200 * megabyte, createdDaysAgo: 3),
            file(1, bytes: 200 * megabyte, createdDaysAgo: 2)
        ], size: .megabytes256)

        XCTAssertEqual(result.filesToDelete, [0, 1])
    }

    func testReclaimedAndRemainingAddUpToTheDirectory() {
        let files = [
            file(0, bytes: 300 * megabyte, createdDaysAgo: 3),
            file(1, bytes: 200 * megabyte, createdDaysAgo: 2),
            file(2, bytes: 100 * megabyte, createdDaysAgo: 1)
        ]
        let total = files.reduce(UInt64(0)) { $0 + $1.byteCount }

        let result = plan(files, size: .megabytes256)

        XCTAssertEqual(result.bytesReclaimed + result.captureBytesAfter, total)
    }
}
