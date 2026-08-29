import Foundation
import XCTest
import Shared

/// Tests de la comparación entre el inventario de capturas y los topes de Ajustes
/// (`CaptureHeadroom`): cuánto sitio queda, cuándo se va la más antigua, y los casos en que una de
/// las dos preguntas no tiene respuesta que dar.
final class CaptureHeadroomTests: XCTestCase {

    private let directory = URL(fileURLWithPath: "/tmp/captures", isDirectory: true)

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func file(_ sequence: UInt32, bytes: UInt64, createdAt: Date? = nil) -> CaptureFileInfo {
        CaptureFileInfo(
            sequence: sequence,
            url: directory.appendingPathComponent(
                CaptureFileName.make(sequence: sequence, date: createdAt ?? Date(timeIntervalSince1970: 0))
            ),
            byteCount: bytes,
            createdAt: createdAt
        )
    }

    private func settings(
        size: RetentionSize = .gigabyte1,
        age: RetentionAge = .oneWeek
    ) -> RetentionSettings {
        RetentionSettings(maxAge: age, maxCaptureSize: size)
    }

    // MARK: - El tope de tamaño

    func testWhatFitsSaysHowMuchRoomIsLeft() {
        let reading = CaptureHeadroom.reading(
            files: [file(1, bytes: 6 * 1024 * 1024), file(2, bytes: 4 * 1024 * 1024)],
            settings: settings(size: .megabytes256),
            now: now,
            recordingSequence: nil
        )

        guard case .bounded(let size, _) = reading else {
            return XCTFail("con topes puestos la lectura debería ser acotada")
        }
        XCTAssertEqual(size, .within(used: 10 * 1024 * 1024, limit: 256 * 1024 * 1024))
        XCTAssertEqual(size.free, 246 * 1024 * 1024)
    }

    func testWhatAlreadyFillsTheLimitIsNotZeroRoomLeft() {
        let reading = CaptureHeadroom.reading(
            files: [file(1, bytes: 200 * 1024 * 1024), file(2, bytes: 100 * 1024 * 1024)],
            settings: settings(size: .megabytes256, age: .unlimited),
            now: now,
            recordingSequence: nil
        )

        guard case .bounded(let size, _) = reading else {
            return XCTFail("con topes puestos la lectura debería ser acotada")
        }
        // No es `within` con cero libre: ahí no queda sitio del que hablar, y lo que hay que decir es
        // que se va a perder algo.
        XCTAssertEqual(size, .reached(used: 300 * 1024 * 1024, limit: 256 * 1024 * 1024))
        XCTAssertNil(size.free)
    }

    func testALimitTheOpenCaptureAloneExceedsCannotBeMet() {
        // La que se está grabando no se borra nunca, así que un tope por debajo de su tamaño no se
        // puede cumplir por mucho que se borre todo lo demás.
        let reading = CaptureHeadroom.reading(
            files: [file(1, bytes: 10 * 1024 * 1024), file(2, bytes: 300 * 1024 * 1024)],
            settings: settings(size: .megabytes256, age: .unlimited),
            now: now,
            recordingSequence: 2
        )

        guard case .bounded(let size, _) = reading else {
            return XCTFail("con topes puestos la lectura debería ser acotada")
        }
        XCTAssertEqual(size, .unmeetable(used: 310 * 1024 * 1024, limit: 256 * 1024 * 1024))
    }

    func testNoSizeLimitStillCountsWhatIsOccupied() {
        let reading = CaptureHeadroom.reading(
            files: [file(1, bytes: 2_048)],
            settings: settings(size: .unlimited),
            now: now,
            recordingSequence: nil
        )

        guard case .bounded(let size, _) = reading else {
            return XCTFail("queda el tope de antigüedad, así que la lectura es acotada")
        }
        XCTAssertEqual(size, .unlimited(used: 2_048))
        XCTAssertNil(size.fill)
    }

    func testTheBarNeverOverflowsItsTrack() {
        let over = CaptureSizeStanding.reached(used: 600, limit: 400)

        // Lo que se pasa del tope no se puede dibujar, y una barra que se sale del carril no dice
        // "hay de más": dice que el dibujo está roto. Cuánto se ha pasado lo dicen las cifras.
        XCTAssertEqual(over.fill, 1)
        XCTAssertEqual(CaptureSizeStanding.within(used: 100, limit: 400).fill, 0.25)
    }

    // MARK: - El tope de antigüedad

    func testTheOldestExpiresAWeekAfterItWasClosed() {
        let closedAt = now.addingTimeInterval(-24 * 60 * 60)
        let reading = CaptureHeadroom.reading(
            files: [
                file(1, bytes: 100, createdAt: now.addingTimeInterval(-48 * 60 * 60)),
                file(2, bytes: 100, createdAt: closedAt),
            ],
            settings: settings(age: .oneWeek),
            now: now,
            recordingSequence: nil
        )

        // Un fichero se sigue engordando hasta que aparece el siguiente, así que su antigüedad cuenta
        // desde que se cerró —la fecha de su sucesor— y no desde que se abrió. Es la regla de
        // `RetentionPlanner`, y fecharlo por la propia adelantaría la caducidad de tráfico que aún
        // está dentro del plazo.
        guard case .bounded(_, .on(let date)) = reading else {
            return XCTFail("la más antigua tiene sucesor con fecha, así que tiene caducidad")
        }
        XCTAssertEqual(date, closedAt.addingTimeInterval(7 * 24 * 60 * 60))
    }

    func testCapturesPastTheirExpiryAreCountedInsteadOfDated() {
        let old = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let reading = CaptureHeadroom.reading(
            files: [
                file(1, bytes: 100, createdAt: old.addingTimeInterval(-60)),
                file(2, bytes: 100, createdAt: old),
                file(3, bytes: 100, createdAt: old.addingTimeInterval(60)),
            ],
            settings: settings(age: .oneWeek),
            now: now,
            recordingSequence: nil
        )

        // Una fecha ya pasada se leería como una promesa incumplida. Las dos que tienen sucesor están
        // vencidas; la tercera no tiene sucesor y por tanto no tiene fecha.
        guard case .bounded(_, .overdue(let count)) = reading else {
            return XCTFail("dos capturas han pasado el corte")
        }
        XCTAssertEqual(count, 2)
    }

    func testACaptureNothingHasClosedYetHasNoExpiryDate() {
        let reading = CaptureHeadroom.reading(
            files: [file(1, bytes: 100, createdAt: now.addingTimeInterval(-60))],
            settings: settings(age: .oneWeek),
            now: now,
            recordingSequence: 1
        )

        // Se dice en vez de callarse: una fila que aparece y desaparece sin explicación se lee como
        // una avería intermitente.
        XCTAssertEqual(reading, .bounded(size: .within(used: 100, limit: 1024 * 1024 * 1024), expiry: .undated))
    }

    func testAnExpiryTurnedOffIsSaidAndNotHidden() {
        let reading = CaptureHeadroom.reading(
            files: [file(1, bytes: 100, createdAt: now), file(2, bytes: 100, createdAt: now)],
            settings: settings(age: .unlimited),
            now: now,
            recordingSequence: nil
        )

        guard case .bounded(_, let expiry) = reading else {
            return XCTFail("queda el tope de tamaño, así que la lectura es acotada")
        }
        XCTAssertEqual(expiry, .never)
    }

    func testTheRecordingCaptureNeverExpires() {
        let old = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let reading = CaptureHeadroom.reading(
            files: [file(1, bytes: 100, createdAt: old), file(2, bytes: 100, createdAt: old)],
            settings: settings(age: .oneWeek),
            now: now,
            recordingSequence: 1
        )

        // La 1 se está grabando, así que no cuenta como vencida por vieja que sea su fecha; la 2 no
        // tiene sucesor, así que no tiene fecha. No queda ninguna que fechar.
        guard case .bounded(_, let expiry) = reading else {
            return XCTFail("con topes puestos la lectura debería ser acotada")
        }
        XCTAssertEqual(expiry, .undated)
    }

    // MARK: - Sin ningún tope

    func testWithNeitherLimitTheAnswerIsOneCaseAndNotTwoHalves() {
        let reading = CaptureHeadroom.reading(
            files: [file(1, bytes: 700), file(2, bytes: 300)],
            settings: settings(size: .unlimited, age: .unlimited),
            now: now,
            recordingSequence: nil
        )

        // Dos mitades diciendo cada una que su tope no existe obligarían al usuario a juntar dos
        // negaciones para llegar a la única frase que importa: nada borra una captura si no la borra
        // él.
        XCTAssertEqual(reading, .unbounded(used: 1_000))
        XCTAssertEqual(reading.used, 1_000)
    }

    func testAnEmptyFolderStillAnswers() {
        let reading = CaptureHeadroom.reading(
            files: [],
            settings: settings(),
            now: now,
            recordingSequence: nil
        )

        XCTAssertEqual(
            reading,
            .bounded(size: .within(used: 0, limit: 1024 * 1024 * 1024), expiry: .undated)
        )
    }

    // MARK: - Coherencia con quien de verdad borra

    func testWhatIsSaidToExpireIsWhatThePlannerWouldDelete() {
        let closedAt = now.addingTimeInterval(-8 * 24 * 60 * 60)
        let files = [
            file(1, bytes: 100, createdAt: now.addingTimeInterval(-9 * 24 * 60 * 60)),
            file(2, bytes: 100, createdAt: closedAt),
            file(3, bytes: 100, createdAt: now),
        ]
        let settings = settings(size: .unlimited, age: .oneWeek)

        let reading = CaptureHeadroom.reading(
            files: files,
            settings: settings,
            now: now,
            recordingSequence: nil
        )
        let plan = RetentionPlanner.plan(
            files: files,
            settings: settings,
            now: now,
            recordingSequence: nil
        )

        // Lo que esta pantalla promete y lo que la limpieza hace de verdad salen de la misma regla: un
        // tope no puede significar una cosa delante del usuario y otra a sus espaldas.
        guard case .bounded(_, .overdue(let count)) = reading else {
            return XCTFail("la 1 está vencida, así que la lectura debería contarla")
        }
        XCTAssertEqual(count, plan.filesToDelete.count)
        XCTAssertEqual(plan.filesToDelete, [1])
    }
}
