import Foundation
import XCTest
import Shared

/// Tests del núcleo puro de la pantalla de Ajustes (M9).
///
/// Lo que se afirma aquí no es la redacción, es lo que la copia **tiene que decir**: qué se va a
/// borrar antes de borrarlo, qué se puede afirmar de un ajuste recién guardado, y que un tope que no
/// se puede cumplir se cuente en vez de callarse.
final class SettingsPresentationTests: XCTestCase {

    // MARK: - Etiquetas

    func testEveryChoiceHasItsOwnLabel() {
        // Dos opciones con la misma etiqueta serían un selector en el que no se puede elegir.
        XCTAssertEqual(Set(CaptureDetail.allCases.map(SettingsPresentation.label(for:))).count, CaptureDetail.allCases.count)
        XCTAssertEqual(Set(RetentionAge.allCases.map(SettingsPresentation.label(for:))).count, RetentionAge.allCases.count)
        XCTAssertEqual(Set(RetentionSize.allCases.map(SettingsPresentation.label(for:))).count, RetentionSize.allCases.count)
    }

    func testTheDetailExplanationSpeaksOfBytesAndNeverOfSnaplen() {
        let headers = SettingsPresentation.explanation(for: .metadataOnly)

        // El número sale del propio ajuste: si `snaplen` cambia, la copia no puede quedarse mintiendo.
        XCTAssertTrue(headers.contains("\(CaptureDetail.metadataOnly.snaplen)"))
        for detail in CaptureDetail.allCases {
            XCTAssertFalse(SettingsPresentation.explanation(for: detail).lowercased().contains("snaplen"))
        }
    }

    // MARK: - Confirmación de los topes

    func testApplyingCapsNamesBothCutsAndSaysItCannotBeUndone() {
        let prompt = SettingsPresentation.applyCapsPrompt(
            RetentionSettings(maxAge: .oneWeek, maxCaptureSize: .megabytes256)
        )

        XCTAssertTrue(prompt.contains("1 week"))
        XCTAssertTrue(prompt.contains("256 MB"))
        XCTAssertTrue(prompt.contains("can't be undone"))
    }

    func testACapThatIsOffIsNotAnnouncedAsACut() {
        let onlyAge = SettingsPresentation.applyCapsPrompt(
            RetentionSettings(maxAge: .oneDay, maxCaptureSize: .unlimited)
        )
        XCTAssertTrue(onlyAge.contains("1 day"))
        XCTAssertFalse(onlyAge.contains("oldest first"))

        let onlySize = SettingsPresentation.applyCapsPrompt(
            RetentionSettings(maxAge: .unlimited, maxCaptureSize: .gigabyte1)
        )
        XCTAssertTrue(onlySize.contains("1 GB"))
        XCTAssertFalse(onlySize.contains("older than"))
    }

    func testWithBothCapsOffThereIsNothingToConfirm() {
        let prompt = SettingsPresentation.applyCapsPrompt(
            RetentionSettings(maxAge: .unlimited, maxCaptureSize: .unlimited)
        )

        XCTAssertTrue(prompt.contains("nothing to delete"))
        XCTAssertFalse(prompt.contains("can't be undone"))
    }

    // MARK: - Confirmación de borrarlo todo

    func testClearingEverythingSaysWhatGoesAndHowMuchItFrees() {
        let usage = StorageUsage(
            captureBytes: 350_000_000,
            captureFileCount: 4,
            historyBytes: 12_000_000,
            historyFlowCount: 1_204
        )

        let prompt = SettingsPresentation.clearEverythingPrompt(usage: usage, isMonitoring: false)

        XCTAssertTrue(prompt.contains("1,204"))
        XCTAssertTrue(prompt.contains("350 MB"))
        XCTAssertTrue(prompt.contains("can't be undone"))
        // Con el túnel parado no hay fichero abierto, así que prometer que se conserva uno sería falso.
        XCTAssertFalse(prompt.contains("kept"))
    }

    func testWhileMonitoringTheRecordingFileIsAnnouncedAsKept() {
        let prompt = SettingsPresentation.clearEverythingPrompt(usage: nil, isMonitoring: true)

        XCTAssertTrue(prompt.contains("kept"))
        XCTAssertTrue(prompt.contains("Captures"))
    }

    // MARK: - Almacenamiento

    /// La cuenta y el tamaño llegan **separados**, que es lo que permite que la columna de cifras se
    /// lea de un vistazo. Iban unidos por un `·` dentro de una sola cadena, así que la única cifra por
    /// la que se lee la sección compartía papel y color con una que no se compara con ninguna otra.
    func testStorageKeepsTheCountApartFromTheSize() {
        let display = SettingsPresentation.storage(
            StorageUsage(captureBytes: 2_500_000, captureFileCount: 2, historyBytes: 500_000, historyFlowCount: 3)
        )

        XCTAssertEqual(display.captures.count, "2 files")
        XCTAssertEqual(display.captures.size, "2.5 MB")
        XCTAssertEqual(display.history.count, "3 connections")
        XCTAssertEqual(display.history.size, "500 KB")
        XCTAssertEqual(display.total.size, "3 MB")

        // Y el separador se fue del todo: lo que separa las dos cifras es el papel y el color, así
        // que un `·` en cualquiera de ellas sería puntuación decidida donde no se puede traducir.
        for figure in [display.captures, display.history, display.total] {
            XCTAssertFalse(figure.size.contains("·"))
            XCTAssertFalse(figure.count?.contains("·") ?? false)
        }
    }

    /// El total **nunca** cuenta nada, y esa ausencia es la decisión: suma ficheros, conexiones y
    /// trozos de conversación, que no son la misma cosa, así que una cuenta ahí sería un número que
    /// no cuenta nada.
    func testTheTotalIsTheOnlyRowWithNothingToCount() {
        let display = SettingsPresentation.storage(
            StorageUsage(
                captureBytes: 2_500_000,
                captureFileCount: 2,
                historyBytes: 500_000,
                historyFlowCount: 3,
                plaintextBytes: 5_000,
                plaintextChunkCount: 7
            )
        )

        XCTAssertNil(display.total.count)
        // Lo descifrado tampoco: su unidad es un trozo de conversación, y contarlos obligaría a
        // entender el troceo para poder ignorar el número.
        XCTAssertNil(display.plaintext?.count)
        XCTAssertNotNil(display.captures.count)
        XCTAssertNotNil(display.history.count)
    }

    func testASingleFileAndASingleConnectionAreNotPluralised() {
        let display = SettingsPresentation.storage(
            StorageUsage(captureBytes: 1_000, captureFileCount: 1, historyBytes: 2_000, historyFlowCount: 1)
        )

        XCTAssertEqual(display.captures.count, "1 file")
        XCTAssertEqual(display.history.count, "1 connection")
    }

    /// Lo que se oye de una fila es **una** frase y no tres elementos seguidos, y empieza por lo que
    /// ocupa, que es el orden en que la fila se lee.
    func testAStorageRowIsHeardAsOneSentenceLedByItsSize() {
        let display = SettingsPresentation.storage(
            StorageUsage(captureBytes: 2_500_000, captureFileCount: 2, historyBytes: 500_000, historyFlowCount: 3)
        )

        let value = SettingsPresentation.storageRowAccessibilityValue(display.captures)
        XCTAssertTrue(value.hasPrefix("2.5 MB"))
        XCTAssertTrue(value.contains("2 files"))

        // Una fila sin cuenta se describe por su tamaño y ya: no se inventa una coma suelta.
        XCTAssertEqual(
            SettingsPresentation.storageRowAccessibilityValue(display.total),
            display.total.size
        )
    }

    func testTheHistoryNoteExplainsWhyItsSizeDoesNotDrop() {
        // Sin esto, borrar diez mil conexiones y ver la misma cifra se lee como que no pasó nada.
        XCTAssertTrue(SettingsPresentation.historyDoesNotShrinkNote.contains("reused"))
    }

    /// El mecanismo —que el espacio de una fila borrada no vuelve— se dice **una vez**, pegado a la
    /// cifra que lo enseña. Estaba escrito también bajo los topes, a media pantalla de distancia, así
    /// que la pantalla decía dos veces el mismo hecho.
    func testWhyTheDatabaseDoesNotShrinkIsSaidInOnePlaceOnly() {
        XCTAssertTrue(SettingsPresentation.historyDoesNotShrinkNote.contains("reused"))
        XCTAssertFalse(SettingsPresentation.sizeCapFooter.contains("reused"))
        XCTAssertFalse(SettingsPresentation.sizeCapFooter.contains("hand back"))

        // Y lo que queda en su sitio es la consecuencia, con el nombre de la sección donde está el
        // mecanismo tomado de la clave que lo dibuja: una instrucción no puede llamar a una sección
        // de otra manera que la propia sección.
        XCTAssertTrue(SettingsPresentation.sizeCapFooter.contains(SettingsPresentation.storageSectionTitle))
    }

    // MARK: - Resultado de una limpieza

    func testAnAutomaticCleanupThatFoundNothingSaysNothing() {
        XCTAssertNil(SettingsPresentation.retention(RetentionOutcome(), trigger: .automatic))
    }

    func testACleanupTheUserAskedForAlwaysAnswers() {
        let notice = SettingsPresentation.retention(RetentionOutcome(), trigger: .manual)

        XCTAssertEqual(notice?.role, .neutral)
        XCTAssertTrue(notice?.message.contains("Nothing to delete") ?? false)
    }

    func testWhatWasDeletedIsCountedInBothHalves() throws {
        let notice = try XCTUnwrap(
            SettingsPresentation.retention(
                RetentionOutcome(deletedFiles: [0, 1], bytesReclaimed: 4_000_000, prunedFlows: 12),
                trigger: .automatic
            )
        )

        XCTAssertTrue(notice.message.contains("2 captures"))
        XCTAssertTrue(notice.message.contains("4 MB"))
        XCTAssertTrue(notice.message.contains("12 connections"))
        XCTAssertEqual(notice.role, .accent)
    }

    func testAnUnreachableSizeCapIsToldAndNamesTheWayOut() {
        let notice = SettingsPresentation.retention(
            RetentionOutcome(sizeCapUnreachable: true),
            trigger: .automatic
        )

        // Se cuenta aunque nada se haya borrado: si no, el usuario vería su tope incumplido sin
        // explicación y creería que la limpieza no funciona.
        XCTAssertEqual(notice?.role, .warning)
        XCTAssertTrue(notice?.message.contains("new capture file") ?? false)
    }

    func testAPartialFailureStillReportsWhatWasFreed() {
        let notice = SettingsPresentation.retention(
            RetentionOutcome(
                deletedFiles: [0],
                bytesReclaimed: 1_000_000,
                failures: ["Capture 1 couldn't be deleted: locked"]
            ),
            trigger: .automatic
        )

        // Perder la cuenta de lo que **sí** se liberó es peor que no contar lo que falló.
        XCTAssertEqual(notice?.role, .warning)
        XCTAssertTrue(notice?.message.contains("1 capture") ?? false)
        XCTAssertEqual(notice?.diagnostic, "Capture 1 couldn't be deleted: locked")
    }

    func testClearingEverythingWithNothingLeftIsNotAFailure() {
        let notice = SettingsPresentation.cleared(RetentionOutcome())

        XCTAssertEqual(notice.role, .neutral)
        XCTAssertTrue(notice.message.contains("nothing left"))
    }

    func testClearingEverythingCountsBothHalves() {
        let notice = SettingsPresentation.cleared(
            RetentionOutcome(deletedFiles: [0, 1, 2], bytesReclaimed: 9_000, prunedFlows: 1)
        )

        XCTAssertEqual(notice.role, .accent)
        XCTAssertTrue(notice.message.contains("3 captures"))
        XCTAssertTrue(notice.message.contains("1 connection"))
    }

    // MARK: - El barrido del contenido descifrado (ADR 0007)

    func testDeletedDecryptedContentIsToldWithoutCountingSlices() throws {
        let notice = try XCTUnwrap(
            SettingsPresentation.retention(
                RetentionOutcome(),
                plaintext: PlaintextSweepOutcome(
                    prunedChunks: 812,
                    deletedFiles: [0, 1],
                    bytesReclaimed: 3_000_000
                ),
                trigger: .automatic
            )
        )

        XCTAssertTrue(notice.message.contains("decrypted content"))
        XCTAssertTrue(notice.message.contains("3 MB"))
        // Un "trozo" es un pedazo de conversación tal y como salió de la terminación: un número que
        // el usuario tendría que entender para poder ignorarlo.
        XCTAssertFalse(notice.message.contains("812"))
    }

    func testExpiredDecryptedContentThatFreedNoFileIsStillTold() throws {
        let notice = try XCTUnwrap(
            SettingsPresentation.retention(
                RetentionOutcome(),
                plaintext: PlaintextSweepOutcome(prunedChunks: 3),
                trigger: .automatic
            )
        )

        XCTAssertTrue(notice.message.contains("past its limit"))
    }

    /// Lo que el ADR 0007 obliga a decir: el techo no es un ajuste, así que esta frase es el único
    /// sitio donde el usuario puede enterarse de por qué falta algo que estaba dentro de su plazo.
    func testTheFixedCeilingExplainsItselfWhenItTakesMoreThanTheExpiryWould() throws {
        let notice = try XCTUnwrap(
            SettingsPresentation.retention(
                RetentionOutcome(),
                plaintext: PlaintextSweepOutcome(
                    unindexedChunks: 5,
                    deletedFiles: [0],
                    bytesReclaimed: 1_000,
                    ceilingEnforced: true
                ),
                trigger: .automatic
            )
        )

        XCTAssertTrue(notice.message.contains("fixed limit"))
    }

    func testASweepFailureTravelsInTheSameNoticeAsTheCaptures() throws {
        let notice = try XCTUnwrap(
            SettingsPresentation.retention(
                RetentionOutcome(deletedFiles: [0], bytesReclaimed: 1_000_000),
                plaintext: PlaintextSweepOutcome(failures: ["Decrypted content file 2 couldn't be deleted"]),
                trigger: .automatic
            )
        )

        XCTAssertEqual(notice.role, .warning)
        XCTAssertTrue(notice.message.contains("1 capture"))
        XCTAssertEqual(notice.diagnostic, "Decrypted content file 2 couldn't be deleted")
    }

    func testClearingEverythingSaysTheDecryptedContentWentToo() {
        let notice = SettingsPresentation.cleared(
            RetentionOutcome(deletedFiles: [0], bytesReclaimed: 9_000, prunedFlows: 1),
            plaintext: PlaintextSweepOutcome(deletedFiles: [0, 1], bytesReclaimed: 2_000_000)
        )

        XCTAssertEqual(notice.role, .accent)
        XCTAssertTrue(notice.message.contains("decrypted content went too"))
        XCTAssertTrue(notice.message.contains("2 MB"))
    }

    /// Un vaciado que solo se llevó contenido descifrado **no** es "no había nada que borrar".
    func testClearingEverythingWithOnlyDecryptedContentLeftIsNotNothing() {
        let notice = SettingsPresentation.cleared(
            RetentionOutcome(),
            plaintext: PlaintextSweepOutcome(deletedFiles: [0], bytesReclaimed: 1_000)
        )

        XCTAssertEqual(notice.role, .accent)
        XCTAssertTrue(notice.message.contains("decrypted content went too"))
    }

    func testAFailedClearSaysPartOfTheDataIsStillThere() {
        let notice = SettingsPresentation.cleared(
            RetentionOutcome(failures: ["The history couldn't be cleared: locked"])
        )

        XCTAssertEqual(notice.role, .warning)
        XCTAssertTrue(notice.message.contains("still on the device"))
        XCTAssertNotNil(notice.diagnostic)
    }

    // MARK: - La pantalla del contenido descifrado (ADR 0007)

    /// La copia que el ADR nombra como el precio de tener dos interruptores: si el segundo no dice en
    /// qué se diferencia del primero, es un misterio. Se afirma que **los dos verbos aparecen y son
    /// distintos**, no la redacción.
    func testTheSecondSwitchExplainsHowItDiffersFromTheFirst() {
        let footer = SettingsPresentation.plaintextFooter(isInspectionEnabled: true)

        XCTAssertTrue(footer.contains("while it happens"), "falta el acto que ya hace la inspección")
        XCTAssertTrue(footer.contains("keeps a copy"), "falta el acto que añade este interruptor")
        XCTAssertTrue(footer.contains("after it's over"))
        // El rótulo del interruptor no puede repetir el verbo del de arriba ni el de las capturas.
        XCTAssertNotEqual(
            SettingsPresentation.plaintextPersistenceToggleTitle,
            SettingsPresentation.tlsInspectionToggleTitle
        )
        XCTAssertNotEqual(
            SettingsPresentation.plaintextPersistenceToggleTitle,
            SettingsPresentation.captureToggleTitle
        )
    }

    /// Con la inspección apagada el interruptor no gobierna nada, y decir por qué es lo que impide
    /// que se lea como averiado.
    func testWithInspectionOffTheFooterSaysThereIsNothingToSaveYet() {
        let footer = SettingsPresentation.plaintextFooter(isInspectionEnabled: false)

        XCTAssertTrue(footer.contains("nothing to save"))
        XCTAssertTrue(footer.contains("Turn it on above"))
        XCTAssertNotEqual(footer, SettingsPresentation.plaintextFooter(isInspectionEnabled: true))
        XCTAssertTrue(SettingsPresentation.plaintextCannotBeEnabled.message.contains("inspection is on"))
        XCTAssertEqual(SettingsPresentation.plaintextCannotBeEnabled.role, .neutral)
    }

    func testEveryDecryptedContentAgeHasItsOwnLabelAndNoneOffersForever() {
        let labels = PlaintextRetentionAge.allCases.map(SettingsPresentation.label(for:))

        XCTAssertEqual(Set(labels).count, PlaintextRetentionAge.allCases.count)
        // La ausencia de un "sin límite" **es** la decisión del ADR 0007: ninguna opción puede
        // ofrecerlo, ni con las palabras que sí usa el selector de las capturas.
        for label in labels {
            XCTAssertNotEqual(label, SettingsPresentation.label(for: RetentionAge.unlimited))
        }
    }

    /// El pie dice el techo con una cifra escrita, así que este test es lo único que impide que se
    /// desvíe de lo que el barrido aplica de verdad.
    func testTheRetentionFooterNamesTheCeilingTheSweepEnforces() {
        XCTAssertEqual(
            RetentionSettings.plaintextByteCeiling,
            512 * 1024 * 1024,
            "si el techo cambia, la frase del selector tiene que cambiar con él"
        )
        XCTAssertTrue(SettingsPresentation.plaintextRetentionFooter.contains("512 MB"))
        XCTAssertTrue(SettingsPresentation.plaintextRetentionFooter.contains("keep forever"))
    }

    // MARK: - Borrar solo lo descifrado

    /// Lo que hace que el gesto se distinga del de abajo: dice qué **se queda**.
    func testDeletingTheDecryptedContentSaysWhatSurvivesIt() {
        let usage = StorageUsage(
            captureBytes: 1_000,
            captureFileCount: 1,
            historyBytes: 2_000,
            historyFlowCount: 1,
            plaintextBytes: 4_500_000,
            plaintextChunkCount: 12
        )

        let prompt = SettingsPresentation.clearPlaintextPrompt(usage: usage, isMonitoring: false)

        XCTAssertTrue(prompt.contains("4.5 MB"))
        XCTAssertTrue(prompt.contains("history and your captures stay"))
        XCTAssertTrue(prompt.contains("can't be undone"))
        XCTAssertFalse(prompt.contains("stop monitoring"))
    }

    func testWithNothingMeasuredTheDeletionPromisesNoFigure() {
        let prompt = SettingsPresentation.clearPlaintextPrompt(usage: nil, isMonitoring: true)

        XCTAssertFalse(prompt.contains("freeing"))
        // Y mientras se graba, que parte de lo descifrado sobrevive se dice **antes** de aceptar.
        XCTAssertTrue(prompt.contains("stop monitoring"))
    }

    func testDeletingTheDecryptedContentAnswersWithWhatItFreed() {
        let notice = SettingsPresentation.plaintextCleared(
            PlaintextClearOutcome(clearedChunks: 40, deletedFiles: [0, 1], bytesReclaimed: 2_000_000),
            isMonitoring: false
        )

        XCTAssertEqual(notice.role, .accent)
        XCTAssertTrue(notice.message.contains("2 MB"))
        XCTAssertFalse(notice.message.contains("40"), "un trozo no es una unidad del usuario")
    }

    /// Que quede algo detrás no es un fallo —el fichero abierto no se toca nunca— pero callarlo
    /// dejaría al usuario creyendo que se fue hasta el último byte descifrado.
    func testWhatTheOpenFileKeepsIsSaidWhileMonitoring() {
        let outcome = PlaintextClearOutcome(
            clearedChunks: 40,
            deletedFiles: [0],
            bytesReclaimed: 1_000,
            bytesKept: 9_000
        )

        let monitoring = SettingsPresentation.plaintextCleared(outcome, isMonitoring: true)
        let stopped = SettingsPresentation.plaintextCleared(outcome, isMonitoring: false)

        XCTAssertTrue(monitoring.message.contains("stop monitoring"))
        // Parado, unos bytes que sobreviven son otra cosa, y esa sale por el aviso de fallo.
        XCTAssertFalse(stopped.message.contains("stop monitoring"))
    }

    func testDeletingNothingIsAFactAndNotAFailure() {
        let notice = SettingsPresentation.plaintextCleared(PlaintextClearOutcome(), isMonitoring: false)

        XCTAssertEqual(notice.role, .neutral)
        XCTAssertTrue(notice.message.contains("no decrypted content"))
    }

    func testAFailedDeletionSaysPartOfItIsStillThere() {
        let notice = SettingsPresentation.plaintextCleared(
            PlaintextClearOutcome(failures: ["The decrypted content index couldn't be cleared: locked"]),
            isMonitoring: false
        )

        XCTAssertEqual(notice.role, .warning)
        XCTAssertTrue(notice.message.contains("still on the device"))
        XCTAssertNotNil(notice.diagnostic)
    }

    /// El diálogo de "borrarlo todo" nombraba el historial y las capturas, así que sin esta frase lo
    /// descifrado se leía como superviviente justo en el gesto que se lo lleva.
    func testDeletingEverythingNamesTheDecryptedContentWhenThereIsAny() {
        let withPlaintext = StorageUsage(
            captureBytes: 1_000,
            captureFileCount: 1,
            historyBytes: 2_000,
            historyFlowCount: 1,
            plaintextBytes: 3_000_000,
            plaintextChunkCount: 4
        )

        let prompt = SettingsPresentation.clearEverythingPrompt(usage: withPlaintext, isMonitoring: false)

        XCTAssertTrue(prompt.contains("decrypted content"))
        XCTAssertTrue(prompt.contains("3 MB"))
        // Y sin contenido descifrado no se nombra: no se habla de lo que no existe.
        let without = StorageUsage(
            captureBytes: 1_000,
            captureFileCount: 1,
            historyBytes: 2_000,
            historyFlowCount: 1
        )
        XCTAssertFalse(
            SettingsPresentation.clearEverythingPrompt(usage: without, isMonitoring: false)
                .contains("decrypted content")
        )
    }

    // MARK: - Almacenamiento del contenido descifrado

    func testTheStorageRowAppearsOnlyWhenSomethingWasDecrypted() {
        let empty = SettingsPresentation.storage(
            StorageUsage(captureBytes: 1_000, captureFileCount: 1, historyBytes: 2_000, historyFlowCount: 1)
        )
        XCTAssertNil(empty.plaintext)
        XCTAssertEqual(empty.total.size, "3 KB")

        let withPlaintext = SettingsPresentation.storage(
            StorageUsage(
                captureBytes: 1_000,
                captureFileCount: 1,
                historyBytes: 2_000,
                historyFlowCount: 1,
                plaintextBytes: 5_000,
                plaintextChunkCount: 2
            )
        )
        // Solo el tamaño: la fila no cuenta trozos, y el total sí lo suma.
        XCTAssertEqual(withPlaintext.plaintext?.size, "5 KB")
        XCTAssertEqual(withPlaintext.total.size, "8 KB")
    }

    /// Unas filas que sobreviven a sus ficheros siguen prometiendo un contenido que la pantalla de
    /// una conexión ofrecería abrir, así que cuentan como algo que hay que poder borrar.
    func testAnIndexWithoutFilesStillCountsAsSomethingStored() {
        let usage = StorageUsage(
            captureBytes: 0,
            captureFileCount: 0,
            historyBytes: 0,
            historyFlowCount: 0,
            plaintextBytes: 0,
            plaintextChunkCount: 3
        )

        XCTAssertTrue(usage.hasPlaintext)
        XCTAssertEqual(SettingsPresentation.storage(usage).plaintext?.size, "0 B")
    }

    // MARK: - Fallos y ajustes que no alcanzan a la sesión viva

    func testUnreadableSettingsSayTheChoicesAreGoneAndHowToRepairThem() {
        let notice = SettingsPresentation.settingsUnreadable("corruptData")

        XCTAssertEqual(notice.role, .warning)
        XCTAssertTrue(notice.message.contains("defaults"))
        XCTAssertEqual(notice.diagnostic, "corruptData")
    }

    func testAFailedSaveSaysTheSettingIsStillAsItWas() {
        let notice = SettingsPresentation.saveFailed("writeFailed")

        XCTAssertEqual(notice.role, .warning)
        XCTAssertTrue(notice.message.contains("still as it was"))
    }

    /// El detalle sí se aplica ya, pero abriendo un fichero nuevo. Las dos mitades tienen que estar:
    /// callarse la segunda dejaría al usuario encontrándose una captura de más sin explicación.
    func testCaptureDetailSaysBothThatItAppliedAndWhatItCost() {
        let notice = SettingsPresentation.captureDetailStartedANewFile

        XCTAssertEqual(notice.role, .neutral)
        XCTAssertTrue(notice.message.contains("Applied"))
        XCTAssertTrue(notice.message.contains("new one was started"))
        XCTAssertTrue(notice.message.contains("Captures"), "nombra la pantalla donde va a aparecer")
    }

    func testALiveChangeThatWasRejectedStillSaysItWasSaved() {
        let notice = SettingsPresentation.liveChangeNotApplied("disk full")

        XCTAssertEqual(notice.role, .warning)
        XCTAssertTrue(notice.message.contains("Saved"))
        XCTAssertEqual(notice.diagnostic, "disk full")
    }

    func testTheUnknownRecordingFileRefusesInsteadOfDeletingBlind() {
        XCTAssertEqual(SettingsPresentation.recordingFileUnknown.role, .warning)
        XCTAssertTrue(SettingsPresentation.recordingFileUnknown.message.contains("nothing was deleted"))
    }

    // MARK: - Inspección TLS

    func testTheUnavailableInspectionReadsAsASetupStepAndNotAsAFailure() {
        let footer = SettingsPresentation.tlsFooter(.certificateNotReady)

        XCTAssertTrue(footer.contains("certificate"))
        XCTAssertNotEqual(footer, SettingsPresentation.tlsFooter(.ready))
        // No es una avería: es que falta un paso que el usuario da él mismo.
        XCTAssertFalse(footer.lowercased().contains("error"))
        XCTAssertFalse(footer.lowercased().contains("failed"))
    }

    func testTheReadyFooterKeepsThePinningGuarantee() {
        // ADR 0003: lo pinneado no se descifra, y eso se cuenta como garantía y no como límite.
        XCTAssertTrue(SettingsPresentation.tlsFooter(.ready).contains("pin"))
    }

    /// La fila que abre el flujo guiado (M10). Dice *configurar* mientras no se pueda afirmar que el
    /// certificado esté confiado —`certificateNotReady` no distingue "no hay" de "lo hay sin
    /// confianza", así que "configurar" es verdad en los dos casos— y con la inspección lista lo que se
    /// abre ya no es una configuración, sino lo que hay puesto.
    func testTheCertificateSetupRowSaysWhatItOpens() {
        XCTAssertNotEqual(
            SettingsPresentation.certificateSetupTitle(.ready),
            SettingsPresentation.certificateSetupTitle(.certificateNotReady)
        )
        XCTAssertTrue(
            SettingsPresentation.certificateSetupTitle(.certificateNotReady).lowercased().contains("set up")
        )
    }

    /// La copia que se habría quedado vieja: mientras el flujo guiado no existía, esta pantalla decía
    /// que la instalación del certificado "todavía no está disponible". Ya lo está, y seguir diciéndolo
    /// negaría al usuario justo lo que tiene delante.
    func testTheNotReadyCopyNoLongerDeniesTheGuidedSetup() {
        let texts = [
            SettingsPresentation.tlsFooter(.certificateNotReady),
            SettingsPresentation.tlsCannotBeEnabled.message,
        ]

        for text in texts {
            XCTAssertFalse(text.lowercased().contains("isn't available"), text)
            XCTAssertFalse(text.lowercased().contains("not available"), text)
        }
    }

    // MARK: - La copia por el catálogo (M11)

    /// Una cifra con su unidad **no es copia**: se dice igual en todos los idiomas, y meterla en el
    /// catálogo solo crearía una unidad de traducción que alguien puede equivocar. Los tres topes de
    /// tamaño se quedan tal cual y solo *No limit*, que sí es una palabra nuestra, tiene clave.
    func testTheSizeCapsAreFiguresAndNotCopy() {
        XCTAssertEqual(SettingsPresentation.label(for: RetentionSize.megabytes256), "256 MB")
        XCTAssertEqual(SettingsPresentation.label(for: RetentionSize.gigabyte1), "1 GB")
        XCTAssertEqual(SettingsPresentation.label(for: RetentionSize.gigabytes4), "4 GB")
    }

    /// Los dos *No limit* de la pantalla son **dos claves**: uno dice que nada se borra por antigüedad
    /// y el otro que la carpeta de capturas puede crecer sin tope, que son dos afirmaciones distintas
    /// sobre dos políticas distintas. Que hoy digan la misma palabra es lo que hace tentador fundirlas,
    /// así que la coincidencia se afirma — el día que una se reescriba, la decisión se vuelve a tomar.
    func testTheTwoUnlimitedOptionsCoincideTodayAndStayApart() {
        XCTAssertEqual(
            SettingsPresentation.label(for: RetentionAge.unlimited),
            SettingsPresentation.label(for: RetentionSize.unlimited)
        )
    }

    /// El corte por antigüedad **interpola el rótulo del selector** en vez de reescribirlo: es el mismo
    /// valor que el usuario acaba de elegir dos filas más arriba, y dos literales iguales son justo lo
    /// que una traducción mueve de uno en uno, dejando una frase que se lee bien y nombra una opción
    /// que la pantalla llama de otra manera.
    func testTheAgeCutNamesTheOptionWithThePickersOwnWords() {
        for age in RetentionAge.allCases where age.maxAge != nil {
            let prompt = SettingsPresentation.applyCapsPrompt(
                RetentionSettings(maxAge: age, maxCaptureSize: .unlimited)
            )
            XCTAssertTrue(
                prompt.contains(SettingsPresentation.label(for: age)),
                "\(age): la confirmación no dice lo que dice el selector"
            )
        }
    }

    /// Lo mismo con la pantalla a la que manda ir: la frase nombra la pestaña de capturas leyendo **su**
    /// clave, así que no puede mandar al usuario a un sitio que la app llama de otra manera.
    func testTheKeptRecordingNamesTheCapturesTabWithItsOwnWords() {
        let prompt = SettingsPresentation.clearEverythingPrompt(usage: nil, isMonitoring: true)

        XCTAssertTrue(prompt.contains(CapturesPresentation.tabTitle))
    }

    /// Las dos cuentas de "borrado todo" van en la misma frase, así que el plural se elige por
    /// separado en cada mitad: cuatro claves hermanas y no dos. Lo que se afirma es que las cuatro
    /// combinaciones dicen bien las dos cifras — un `1 captures` es exactamente lo que esto evita.
    func testDeletingEverythingSaysBothCountsInEveryCombination() {
        let cases: [(captures: Int, connections: Int, expected: String)] = [
            (1, 1, "Deleted 1 capture and 1 connection."),
            (1, 4, "Deleted 1 capture and 4 connections."),
            (3, 1, "Deleted 3 captures and 1 connection."),
            (3, 4, "Deleted 3 captures and 4 connections."),
        ]

        for expectation in cases {
            let notice = SettingsPresentation.cleared(
                RetentionOutcome(
                    deletedFiles: (0..<expectation.captures).map(UInt32.init),
                    bytesReclaimed: 1_000,
                    prunedFlows: expectation.connections
                )
            )
            XCTAssertEqual(notice.message, expectation.expected)
        }
    }

    /// Las frases de un aviso se juntan **por el catálogo** y no con un `joined(separator:)` en Swift,
    /// que decidiría fuera de él el orden y el separador. Con tres frases la clave se aplica en
    /// cascada, y lo que se afirma es que el párrafo sale entero y sin costuras.
    func testAThreeSentenceNoticeComesOutAsOneParagraph() throws {
        let notice = SettingsPresentation.retention(
            RetentionOutcome(
                deletedFiles: [0, 1],
                bytesReclaimed: 4_000_000,
                prunedFlows: 12,
                sizeCapUnreachable: true
            ),
            trigger: .automatic
        )

        XCTAssertEqual(
            try XCTUnwrap(notice?.message),
            """
            Deleted 2 captures and freed 4 MB. Removed 12 connections from your history. The \
            capture being recorded is already larger than your size limit, so it can't be met \
            until you start a new capture file.
            """
        )
    }

    /// El fallo característico de una migración al catálogo: una llamada sin `defaultValue` devuelve
    /// **la clave**, y una clave estructural se lee perfectamente en un diff sin llamar la atención.
    func testNoCopyIsARawCatalogKey() {
        for piece in everyPieceOfCopy {
            for prefix in ["settings.", "captures.", "common."] {
                XCTAssertFalse(piece.text.hasPrefix(prefix), "\(piece.where): \(piece.text)")
            }
            XCTAssertFalse(piece.text.isEmpty, "\(piece.where) se quedó sin copia")
        }
    }

    /// El otro fallo característico, y el que ningún test de contenido ve: al mudar un literal
    /// multilínea cambia dónde caen las continuaciones (`\`), y una mal puesta mete un espacio doble o
    /// deja un sobrante en un extremo. El texto sigue diciendo lo mismo y se ve mal.
    func testNoCopyCarriesStrayWhitespace() {
        for piece in everyPieceOfCopy {
            XCTAssertFalse(piece.text.contains("  "), "\(piece.where): espacio doble en «\(piece.text)»")
            XCTAssertEqual(
                piece.text.trimmingCharacters(in: .whitespacesAndNewlines),
                piece.text,
                "\(piece.where): sobra espacio en un extremo"
            )
            for line in piece.text.split(separator: "\n") {
                XCTAssertFalse(line.hasSuffix(" "), "\(piece.where): una línea acaba en espacio")
            }
        }
    }

    /// Toda la copia de la pantalla, con el sitio del que sale. Entran también los rótulos que hasta
    /// este incremento escribía `SettingsView` a mano: son los que nadie afirmaba.
    private var everyPieceOfCopy: [(where: String, text: String)] {
        var copy: [(where: String, text: String)] = [
            ("tab", SettingsPresentation.tabTitle),
            ("screen.title", SettingsPresentation.screenTitle),
            ("secureTraffic.section", SettingsPresentation.secureTrafficSectionTitle),
            ("secureTraffic.toggle", SettingsPresentation.tlsInspectionToggleTitle),
            ("secureTraffic.notice.cannotEnable", SettingsPresentation.tlsCannotBeEnabled.message),
            ("capture.section", SettingsPresentation.captureSectionTitle),
            ("capture.toggle", SettingsPresentation.captureToggleTitle),
            ("capture.detail.picker", SettingsPresentation.captureDetailPickerTitle),
            ("capture.footer", SettingsPresentation.captureFooter),
            ("storage.section", SettingsPresentation.storageSectionTitle),
            ("storage.captures", SettingsPresentation.storageCapturesRowTitle),
            ("storage.history", SettingsPresentation.storageHistoryRowTitle),
            ("storage.total", SettingsPresentation.storageTotalRowTitle),
            ("storage.footer", SettingsPresentation.historyDoesNotShrinkNote),
            ("limits.section", SettingsPresentation.limitsSectionTitle),
            ("limits.age.picker", SettingsPresentation.retentionAgePickerTitle),
            ("limits.size.picker", SettingsPresentation.retentionSizePickerTitle),
            ("limits.footer", SettingsPresentation.retentionFooter),
            ("limits.sizeCap.note", SettingsPresentation.sizeCapFooter),
            ("limits.apply.button", SettingsPresentation.applyCapsButtonTitle),
            ("limits.apply.confirm.title", SettingsPresentation.applyCapsDialogTitle),
            ("limits.apply.confirm.action", SettingsPresentation.applyCapsConfirmTitle),
            ("clear.action", SettingsPresentation.clearEverythingTitle),
            ("clear.confirm.title", SettingsPresentation.clearEverythingDialogTitle),
            ("intro.section", SettingsPresentation.introSectionTitle),
            ("intro.replay", SettingsPresentation.introReplayTitle),
            ("intro.footer", SettingsPresentation.introFooter),
            ("intro.cannotBeRemembered", SettingsPresentation.introCannotBeRemembered),
            ("privacy.section", SettingsPresentation.privacySectionTitle),
            ("privacy.note", SettingsPresentation.privacyNote),
            ("notice.recordingFileUnknown", SettingsPresentation.recordingFileUnknown.message),
            ("notice.captureDetailNewFile", SettingsPresentation.captureDetailStartedANewFile.message),
            ("notice.settingsUnreadable", SettingsPresentation.settingsUnreadable("d").message),
            ("notice.saveFailed", SettingsPresentation.saveFailed("d").message),
            ("notice.storageUnavailable", SettingsPresentation.storageUnavailable("d").message),
            ("notice.liveChangeNotApplied", SettingsPresentation.liveChangeNotApplied("d").message),
            ("clear.failure", SettingsPresentation.cleared(RetentionOutcome(failures: ["d"])).message),
            ("clear.nothingLeft", SettingsPresentation.cleared(RetentionOutcome()).message),
            ("plaintext.section", SettingsPresentation.decryptedContentSectionTitle),
            ("plaintext.toggle", SettingsPresentation.plaintextPersistenceToggleTitle),
            ("plaintext.age.picker", SettingsPresentation.plaintextAgePickerTitle),
            ("plaintext.age.footer", SettingsPresentation.plaintextRetentionFooter),
            ("plaintext.notice.cannotEnable", SettingsPresentation.plaintextCannotBeEnabled.message),
            ("plaintext.clear.action", SettingsPresentation.clearPlaintextTitle),
            ("plaintext.clear.confirm.title", SettingsPresentation.clearPlaintextDialogTitle),
            ("storage.plaintext", SettingsPresentation.storagePlaintextRowTitle),
            (
                "plaintext.clear.failure",
                SettingsPresentation.plaintextCleared(
                    PlaintextClearOutcome(failures: ["d"]),
                    isMonitoring: false
                ).message
            ),
            (
                "plaintext.clear.nothingLeft",
                SettingsPresentation.plaintextCleared(PlaintextClearOutcome(), isMonitoring: false).message
            ),
            (
                "plaintext.clear.done",
                SettingsPresentation.plaintextCleared(
                    PlaintextClearOutcome(clearedChunks: 3),
                    isMonitoring: false
                ).message
            ),
            (
                "plaintext.clear.doneAndFreed",
                SettingsPresentation.plaintextCleared(
                    PlaintextClearOutcome(clearedChunks: 3, deletedFiles: [0], bytesReclaimed: 1_000),
                    isMonitoring: false
                ).message
            ),
            (
                "plaintext.clear.recordingKept",
                SettingsPresentation.plaintextCleared(
                    PlaintextClearOutcome(
                        clearedChunks: 3,
                        deletedFiles: [0],
                        bytesReclaimed: 1_000,
                        bytesKept: 500
                    ),
                    isMonitoring: true
                ).message
            ),
        ]

        for enabled in [true, false] {
            copy.append((
                "plaintext.footer.inspection\(enabled ? "On" : "Off")",
                SettingsPresentation.plaintextFooter(isInspectionEnabled: enabled)
            ))
        }
        for age in PlaintextRetentionAge.allCases {
            copy.append(("plaintext.age.\(age.rawValue)", SettingsPresentation.label(for: age)))
        }
        for (name, measured, monitoring) in [
            ("counted", true, false),
            ("uncounted", false, false),
            ("recordingKept", true, true),
        ] {
            copy.append((
                "plaintext.clear.confirm.\(name)",
                SettingsPresentation.clearPlaintextPrompt(
                    usage: measured
                        ? StorageUsage(
                            captureBytes: 0,
                            captureFileCount: 0,
                            historyBytes: 0,
                            historyFlowCount: 0,
                            plaintextBytes: 2_000_000,
                            plaintextChunkCount: 9
                        )
                        : nil,
                    isMonitoring: monitoring
                )
            ))
        }
        copy.append((
            "clear.confirm.plaintext",
            SettingsPresentation.clearEverythingPrompt(
                usage: StorageUsage(
                    captureBytes: 1_000,
                    captureFileCount: 1,
                    historyBytes: 2_000,
                    historyFlowCount: 1,
                    plaintextBytes: 3_000,
                    plaintextChunkCount: 1
                ),
                isMonitoring: false
            )
        ))

        for detail in CaptureDetail.allCases {
            copy.append(("capture.detail.\(detail.rawValue)", SettingsPresentation.label(for: detail)))
            copy.append((
                "capture.detail.explanation.\(detail.rawValue)",
                SettingsPresentation.explanation(for: detail)
            ))
        }
        for age in RetentionAge.allCases {
            copy.append(("limits.age.\(age.rawValue)", SettingsPresentation.label(for: age)))
        }
        copy.append(("limits.size.unlimited", SettingsPresentation.label(for: RetentionSize.unlimited)))

        for availability in [TLSInspectionAvailability.ready, .certificateNotReady] {
            copy.append(("secureTraffic.footer.\(availability)", SettingsPresentation.tlsFooter(availability)))
            copy.append((
                "secureTraffic.setup.\(availability)",
                SettingsPresentation.certificateSetupTitle(availability)
            ))
        }

        // Las dos confirmaciones y el resultado de una limpieza, en todas las formas que puede tomar
        // cada párrafo: es donde viven las claves que se juntan en cascada.
        for settings in [
            RetentionSettings(maxAge: .unlimited, maxCaptureSize: .unlimited),
            RetentionSettings(maxAge: .oneWeek, maxCaptureSize: .unlimited),
            RetentionSettings(maxAge: .unlimited, maxCaptureSize: .gigabyte1),
            RetentionSettings(maxAge: .oneMonth, maxCaptureSize: .gigabytes4),
        ] {
            copy.append((
                "limits.apply.confirm[\(settings.maxAge)/\(settings.maxCaptureSize)]",
                SettingsPresentation.applyCapsPrompt(settings)
            ))
        }

        let usage = StorageUsage(
            captureBytes: 350_000_000,
            captureFileCount: 4,
            historyBytes: 12_000_000,
            historyFlowCount: 1_204
        )
        for (name, measured, monitoring) in [
            ("counted", true, false),
            ("uncounted", false, false),
            ("recordingKept", true, true),
        ] {
            copy.append((
                "clear.confirm.\(name)",
                SettingsPresentation.clearEverythingPrompt(
                    usage: measured ? usage : nil,
                    isMonitoring: monitoring
                )
            ))
        }

        let single = SettingsPresentation.storage(
            StorageUsage(captureBytes: 1_000, captureFileCount: 1, historyBytes: 2_000, historyFlowCount: 1)
        )
        let many = SettingsPresentation.storage(usage)
        copy.append(("storage.captures.count.one", single.captures.count ?? ""))
        copy.append(("storage.history.count.one", single.history.count ?? ""))
        copy.append(("storage.captures.count.other", many.captures.count ?? ""))
        copy.append(("storage.history.count.other", many.history.count ?? ""))
        copy.append((
            "storage.row.accessibilityValue",
            SettingsPresentation.storageRowAccessibilityValue(many.captures)
        ))

        for (name, outcome) in [
            ("retention.deleted.one", RetentionOutcome(deletedFiles: [0], bytesReclaimed: 1_000)),
            ("retention.deleted.other", RetentionOutcome(deletedFiles: [0, 1], bytesReclaimed: 2_000)),
            ("retention.pruned.one", RetentionOutcome(prunedFlows: 1)),
            ("retention.pruned.other", RetentionOutcome(prunedFlows: 12)),
            ("retention.sizeCapUnreachable", RetentionOutcome(sizeCapUnreachable: true)),
            ("retention.partialFailure", RetentionOutcome(deletedFiles: [0], failures: ["d"])),
            ("retention.nothingToDelete", RetentionOutcome()),
            ("clear.done.one.one", RetentionOutcome(deletedFiles: [0], prunedFlows: 1)),
            ("clear.done.other.other", RetentionOutcome(deletedFiles: [0, 1], prunedFlows: 5)),
        ] {
            if name.hasPrefix("clear.") {
                copy.append((name, SettingsPresentation.cleared(outcome).message))
            } else if let notice = SettingsPresentation.retention(outcome, trigger: .manual) {
                copy.append((name, notice.message))
            }
        }

        return copy
    }
}
