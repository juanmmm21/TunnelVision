import Foundation
import XCTest
import Shared

/// Tests del núcleo puro de la pantalla de capturas (M9): cuál es el fichero que se está
/// escribiendo, cómo se ordenan y describen las filas, qué cuerpo le toca a la pantalla, y qué se le
/// cuenta al usuario antes de borrar y después de cada acción.
final class CapturesPresentationTests: XCTestCase {

    private let directory = URL(fileURLWithPath: "/tmp/captures", isDirectory: true)

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

    // MARK: - Qué fichero está abierto

    func testTheOpenFileIsTheHighestSequenceWhileMonitoring() {
        let files = [file(3, bytes: 100), file(7, bytes: 200), file(5, bytes: 300)]

        XCTAssertEqual(
            CapturesPresentation.recordingSequence(files: files, isMonitoring: true),
            7
        )
    }

    func testNothingIsBeingRecordedWhileTheTunnelIsOff() {
        let files = [file(3, bytes: 100), file(7, bytes: 200)]

        // Con el túnel parado no hay writer abierto, por reciente que sea el último fichero: darlo
        // por abierto le quitaría al usuario justo el que quiere exportar.
        XCTAssertNil(CapturesPresentation.recordingSequence(files: files, isMonitoring: false))
    }

    func testNothingIsBeingRecordedWithoutFiles() {
        XCTAssertNil(CapturesPresentation.recordingSequence(files: [], isMonitoring: true))
    }

    // MARK: - Filas

    func testRowsGoNewestFirst() {
        let rows = CapturesPresentation.rows(
            [file(1, bytes: 10), file(9, bytes: 20), file(4, bytes: 30)],
            recordingSequence: nil
        )

        XCTAssertEqual(rows.map(\.sequence), [9, 4, 1])
    }

    func testRowDescribesTheFileInPlainWords() {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = CapturesPresentation.rows([file(12, bytes: 1_500, createdAt: created)], recordingSequence: nil)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].title, "Capture 12")
        XCTAssertEqual(rows[0].sizeText, "1.5 KB")
        XCTAssertEqual(rows[0].createdAt, created)
        XCTAssertFalse(rows[0].isRecording)
        XCTAssertTrue(rows[0].isActionable)
    }

    func testTheFileBeingWrittenIsMarkedAndCannotBeActedOn() {
        let rows = CapturesPresentation.rows(
            [file(1, bytes: 10), file(2, bytes: 20)],
            recordingSequence: 2
        )

        XCTAssertTrue(rows[0].isRecording)
        // Ni exportar ni borrar: sus últimos bytes pueden ser un registro a medias, y borrarlo
        // dejaría a la extensión escribiendo en un fichero sin nombre.
        XCTAssertFalse(rows[0].isActionable)
        XCTAssertFalse(rows[1].isRecording)
        XCTAssertTrue(rows[1].isActionable)
    }

    // MARK: - Resumen

    func testSummaryAddsUpWhatTheCapturesOccupy() {
        let summary = CapturesPresentation.summary([file(1, bytes: 1_000), file(2, bytes: 500)])

        XCTAssertEqual(summary.fileCount, 2)
        XCTAssertEqual(summary.totalBytes, 1_500)
        XCTAssertEqual(summary.text, "2 captures")
    }

    /// El pie decía además cuánto ocupaban, y ya no: ese tamaño se dice **una vez**, y el sitio donde
    /// se dice es donde está el tope con el que se compara (`headroom(_:)`). Los bytes siguen
    /// viajando en el resumen porque son la mitad de esa comparación.
    func testSummaryDoesNotRepeatTheSizeSaidBesideTheLimit() {
        let summary = CapturesPresentation.summary([file(1, bytes: 1_000), file(2, bytes: 500)])

        XCTAssertFalse(summary.text.contains("KB"))
        XCTAssertFalse(summary.text.contains("·"))
    }

    func testSummaryIsSingularForOneCapture() {
        let summary = CapturesPresentation.summary([file(1, bytes: 24)])

        XCTAssertEqual(summary.text, "1 capture")
    }

    func testSummaryOfNothingIsZero() {
        let summary = CapturesPresentation.summary([])

        XCTAssertEqual(summary.fileCount, 0)
        XCTAssertEqual(summary.totalBytes, 0)
        XCTAssertEqual(summary.text, "0 captures")
    }

    // MARK: - Sitio que queda

    func testWhatFitsLeadsWithTheRoomLeft() {
        let display = CapturesPresentation.headroom(
            .bounded(size: .within(used: 10_000_000, limit: 400_000_000), expiry: .never)
        )

        // La cifra por la que se lee la sección es la que contesta la pregunta con la que se abre.
        XCTAssertEqual(display.headline, "390 MB free")
        XCTAssertEqual(display.usage, "10 MB of 400 MB used")
        XCTAssertEqual(display.fill, 0.025)
        XCTAssertEqual(display.role, .accent)
    }

    func testAFullLimitSaysWhatHappensInsteadOfShowingZero() {
        let display = CapturesPresentation.headroom(
            .bounded(size: .reached(used: 500_000_000, limit: 400_000_000), expiry: .never)
        )

        XCTAssertEqual(display.headline, "Limit reached")
        XCTAssertEqual(display.detail, "The oldest captures go on the next cleanup.")
        // Alcanzar un tope es lo que un tope hace: pintarlo de alarma enseñaría a ignorar el color.
        XCTAssertEqual(display.role, .neutral)
    }

    /// El único caso en que la respuesta a *¿esto me va a llenar el móvil?* es que sí.
    func testALimitThatCannotBeMetIsTheOnlyWarningAboutSize() {
        let display = CapturesPresentation.headroom(
            .bounded(size: .unmeetable(used: 500_000_000, limit: 400_000_000), expiry: .never)
        )

        XCTAssertEqual(display.headline, "Limit can't be met")
        XCTAssertEqual(display.role, .warning)
        // La misma frase que dice Ajustes al terminar una limpieza, leída de su propiedad: es el
        // mismo hecho y la misma salida, y dos claves para eso acaban explicando dos mecanismos.
        XCTAssertEqual(display.detail, SettingsPresentation.sizeCapUnreachableExplanation)
    }

    func testNoSizeLimitHasNoBarBecauseThereIsNothingToFill() {
        let display = CapturesPresentation.headroom(
            .bounded(size: .unlimited(used: 2_048), expiry: .on(Date(timeIntervalSince1970: 0)))
        )

        XCTAssertEqual(display.headline, "No size limit")
        XCTAssertEqual(display.usage, "2 KB used")
        XCTAssertNil(display.fill)
    }

    func testWithNeitherLimitTheWholeAnswerIsOneSentence() {
        let display = CapturesPresentation.headroom(.unbounded(used: 2_048))

        XCTAssertEqual(display.headline, "No limits set")
        XCTAssertEqual(display.role, .warning)
        // No hay caducidad de la que hablar, y una fila diciendo que tampoco existe sería la segunda
        // mitad de una resta que el usuario no tiene por qué hacer.
        XCTAssertNil(display.expiry)
        XCTAssertNil(display.fill)
    }

    func testAnExpiryDateTravelsAsADateAndNotAsText() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let display = CapturesPresentation.headroom(
            .bounded(size: .unlimited(used: 10), expiry: .on(date))
        )

        // El huso y el formato son del dispositivo del usuario, y eso lo sabe la vista.
        XCTAssertEqual(display.expiry, .dated(label: "Oldest expires", date: date))
    }

    func testOverdueCapturesAreCountedWithSiblingPlurals() {
        XCTAssertEqual(
            CapturesPresentation.headroom(.bounded(size: .unlimited(used: 10), expiry: .overdue(count: 1))).expiry,
            .stated("1 capture is past its expiry and goes on the next cleanup.")
        )
        XCTAssertEqual(
            CapturesPresentation.headroom(.bounded(size: .unlimited(used: 10), expiry: .overdue(count: 4))).expiry,
            .stated("4 captures are past their expiry and go on the next cleanup.")
        )
    }

    func testNoFigureIsSaidTwiceInTheRoomSummary() {
        let display = CapturesPresentation.headroom(
            .bounded(size: .within(used: 10_000_000, limit: 400_000_000), expiry: .never)
        )

        // La frase explica qué va a pasar; las cifras están arriba. Repetirlas aquí sería el mismo
        // hecho dos veces en el mismo bloque, que es lo que esta sección existe para arreglar.
        XCTAssertFalse(display.detail.contains("MB"))
    }

    // MARK: - Cuerpo de la pantalla

    func testFirstReadShowsLoading() {
        XCTAssertEqual(CapturesPresentation.content(state: .idle, files: []), .loading)
        XCTAssertEqual(CapturesPresentation.content(state: .loading, files: []), .loading)
    }

    func testNoCapturesYetTeachesInsteadOfBlaming() {
        guard case .placeholder(let placeholder) = CapturesPresentation.content(state: .loaded, files: []) else {
            return XCTFail("sin capturas debería haber un hueco que enseña")
        }

        XCTAssertEqual(placeholder.title, "No captures yet")
        XCTAssertEqual(placeholder.role, .neutral)
        XCTAssertNil(placeholder.action)
        XCTAssertTrue(placeholder.message.contains(".pcap"))
    }

    func testFailureWithoutFilesAlwaysOffersAWayOut() {
        let content = CapturesPresentation.content(
            state: .failed(.containerUnavailable("group.test")),
            files: []
        )
        guard case .placeholder(let placeholder) = content else {
            return XCTFail("un fallo sin filas debería ser el cuerpo de la pantalla")
        }

        XCTAssertEqual(placeholder.role, .warning)
        XCTAssertEqual(placeholder.action, .retry)
        XCTAssertEqual(placeholder.diagnostic, "App Group group.test unavailable")
    }

    func testADrawnListIsNeverCoveredByAFailure() {
        let rows = CapturesPresentation.rows([file(1, bytes: 10)], recordingSequence: nil)

        // La misma regla que manda en la Timeline: lo que ya se está leyendo no se tapa; el fallo se
        // cuenta aparte (`refreshFailed`).
        XCTAssertEqual(
            CapturesPresentation.content(state: .failed(.containerUnavailable("group.test")), files: rows),
            .list
        )
        XCTAssertEqual(CapturesPresentation.content(state: .loading, files: rows), .list)
    }

    // MARK: - Copia de las acciones

    func testDeletionPromptNamesWhatIsLostAndWhatStays() {
        let row = CapturesPresentation.rows([file(4, bytes: 2_000_000)], recordingSequence: nil)[0]
        let prompt = CapturesPresentation.deletionPrompt(for: row)

        XCTAssertTrue(prompt.contains("Capture 4"))
        XCTAssertTrue(prompt.contains("2 MB"))
        XCTAssertTrue(prompt.contains("history"))
        XCTAssertTrue(prompt.contains("can't be brought back"))
    }

    func testRotatingWithTheTunnelOffIsNotAFailure() {
        // No hay nadie escribiendo a quien pedirle nada: es una carrera normal entre la UI y el
        // túnel, no una avería que teñir de aviso.
        XCTAssertEqual(CapturesPresentation.rotateUnavailable.role, .neutral)
        XCTAssertNil(CapturesPresentation.rotateUnavailable.diagnostic)
    }

    func testRotationFailureKeepsTheSystemMessageAside() {
        let notice = CapturesPresentation.rotateFailed("No space left on device")

        XCTAssertEqual(notice.role, .warning)
        XCTAssertEqual(notice.diagnostic, "No space left on device")
        XCTAssertFalse(notice.message.contains("No space left on device"))
    }

    func testRefusingToDeleteTheOpenFileNamesTheWayOut() {
        let notice = CapturesPresentation.cannotDeleteRecording

        XCTAssertEqual(notice.role, .neutral)
        XCTAssertTrue(notice.message.contains("Start a new one first"))
    }

    func testRefreshFailureSaysTheListMayBeStale() {
        let notice = CapturesPresentation.refreshFailed(.containerUnavailable("group.test"))

        XCTAssertEqual(notice.role, .warning)
        XCTAssertTrue(notice.message.contains("out of date"))
        XCTAssertEqual(notice.diagnostic, "App Group group.test unavailable")
    }

    func testDiagnosticsAreTypedPerFailure() {
        XCTAssertEqual(CapturesPresentation.diagnostic(for: .deletionFailed("EPERM")), "EPERM")
        XCTAssertEqual(CapturesPresentation.diagnostic(for: .notFound(7)), "capture 7 not found")
    }

    // MARK: - La copia por el catálogo (M11)

    /// La secuencia de una captura **identifica** —es lo que distingue una de la siguiente y lo que se
    /// nombra al borrarla—, así que se interpola sin agrupar. El fallo no se ve en un diff: la misma
    /// llamada con un número mayor empezaría a decir `Capture 1,204` sin que nada más cambiase.
    ///
    /// La primera línea, de cuatro dígitos, era hasta hoy la que pasaba **por casualidad** (el español
    /// no agrupa a esa escala); desde que el scheme fija el locale del bundle de tests
    /// (`CopyLocaleTests`) afirma lo que ve un usuario en inglés, que es el único idioma que la app
    /// enseña.
    func testACapturesNumberIsNeverGroupedInThousands() {
        XCTAssertEqual(CapturesPresentation.title(forSequence: 1_204), "Capture 1204")

        let rows = CapturesPresentation.rows([file(20_000, bytes: 10)], recordingSequence: nil)
        XCTAssertEqual(rows[0].title, "Capture 20000")
    }

    /// La fila era **tres** elementos de accesibilidad y el recorrido los entregaba en un orden que
    /// no se puede leer: el árbol va por posición y el botón de compartir, centrado contra el alto de
    /// la fila, cae entre el nombre y su propia línea de detalle («Capture 2», «Share Capture 2»,
    /// «2.2 MB · 20 Aug at 05:49»). Ahora la descripción es un elemento con una sola frase, y la
    /// frase se compone aquí y no en SwiftUI, que es donde el orden y las palabras se pueden afirmar.
    func testTheWholeRowIsSaidInOneSentence() {
        XCTAssertEqual(
            CapturesPresentation.rowAccessibilityValue(
                size: "1.5 KB",
                time: "Nov 14, 22:13",
                isRecording: false
            ),
            "1.5 KB, started Nov 14, 22:13"
        )
    }

    /// Un fichero sin fecha no deja un separador colgando: se dice solo el tamaño.
    func testACaptureWithNoDateIsSaidBySizeAlone() {
        XCTAssertEqual(
            CapturesPresentation.rowAccessibilityValue(size: "24 B", time: nil, isRecording: false),
            "24 B"
        )
    }

    /// El fichero abierto es el único que no ofrece compartir ni borrar, así que su frase tiene que
    /// decir **por qué** — y decirlo sin perder nada de lo que dicen las demás. Por eso la clave del
    /// que se está escribiendo **envuelve** a la otra en vez de repetir sus palabras: afirmar que la
    /// contiene es afirmar que las dos no pueden separarse en una traducción.
    func testTheOpenFileSaysItIsStillGrowingWithoutLosingWhatTheOthersSay() {
        let closed = CapturesPresentation.rowAccessibilityValue(
            size: "2.2 MB",
            time: "20 Aug at 05:49",
            isRecording: false
        )
        let open = CapturesPresentation.rowAccessibilityValue(
            size: "2.2 MB",
            time: "20 Aug at 05:49",
            isRecording: true
        )

        XCTAssertEqual(open, "2.2 MB, started 20 Aug at 05:49, being written right now")
        XCTAssertTrue(open.hasPrefix(closed))
        XCTAssertNotEqual(open, closed)
    }

    /// Y sin fecha tampoco se pierde: la envoltura es de la frase, no de la hora.
    func testTheOpenFileWithNoDateStillSaysItIsGrowing() {
        XCTAssertEqual(
            CapturesPresentation.rowAccessibilityValue(size: "24 B", time: nil, isRecording: true),
            "24 B, being written right now"
        )
    }

    /// Lo que se oye del botón de compartir **interpola el nombre que la fila enseña** en vez de
    /// repetirlo: si un idioma reescribiera el nombre de una captura, los dos se moverían juntos.
    func testTheShareLabelNamesTheCaptureWithTheRowsOwnWords() {
        let row = CapturesPresentation.rows([file(12, bytes: 10)], recordingSequence: nil)[0]

        XCTAssertEqual(CapturesPresentation.shareAccessibilityLabel(for: row), "Share Capture 12")
        XCTAssertTrue(CapturesPresentation.shareAccessibilityLabel(for: row).contains(row.title))
    }

    /// El plural del export, con el mismo patrón que el pie de la lista: dos claves hermanas y nunca
    /// el marcado de concordancia automática, que sin catálogo saldría crudo.
    func testAnExportOfOneConnectionIsSingular() {
        let summary = CapturesPresentation.exportPrepared(
            exportResult(connectionCount: 1, byteCount: 512)
        )

        XCTAssertEqual(summary.title, "1 connection ready to share")
        XCTAssertNil(summary.truncationNote)
    }

    func testAnExportOfManyConnectionsCountsThemGrouped() {
        let summary = CapturesPresentation.exportPrepared(
            exportResult(connectionCount: 1_204, byteCount: 4_096)
        )

        // Aquí el número **cuenta** en vez de identificar, así que sí se agrupa.
        XCTAssertEqual(summary.title, "1,204 connections ready to share")
        // El tamaño lo pone `DisplayFormat` y no es copia; lo que sí lo es —y sale de una sola clave—
        // es lo que va detrás y los separadores que lo unen.
        XCTAssertEqual(
            summary.detail,
            "\(DisplayFormat.bytes(4_096)) · JSON · metadata only, no packet contents"
        )
    }

    /// El aviso del recorte también varía su sustantivo, así que también son dos claves: un tope de
    /// una sola conexión es raro pero posible (el tope es un parámetro), y "the 1 most recent
    /// connections" es exactamente la frase que un plural mal hecho deja en pantalla.
    func testATruncatedExportOfOneConnectionReadsAsOne() {
        let note = CapturesPresentation.exportPrepared(
            exportResult(connectionCount: 1, truncated: true)
        ).truncationNote

        XCTAssertEqual(
            note,
            """
            Your history holds more than this. The export carries the most recent connection; the \
            older ones aren't in the file.
            """
        )
    }

    func testATruncatedExportSaysHowManyItCarries() {
        let note = CapturesPresentation.exportPrepared(
            exportResult(connectionCount: 20_000, truncated: true)
        ).truncationNote

        XCTAssertEqual(
            note,
            """
            Your history holds more than this. The export carries the 20,000 most recent \
            connections; the older ones aren't in the file.
            """
        )
    }

    /// El fallo característico de una migración al catálogo: una llamada sin `defaultValue` devuelve
    /// **la clave**, y una clave estructural se lee perfectamente en un diff sin llamar la atención.
    func testNoCopyIsARawCatalogKey() {
        for piece in everyPieceOfCopy {
            for prefix in ["captures.", "common."] {
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

    /// Toda la copia de la pantalla y de la hoja del export, con el sitio del que sale. Las horas no
    /// entran: las formatea la vista con el huso del dispositivo y no son copia.
    private var everyPieceOfCopy: [(where: String, text: String)] {
        let row = CapturesPresentation.rows([file(7, bytes: 2_048)], recordingSequence: nil)[0]

        var copy: [(where: String, text: String)] = [
            ("tab", CapturesPresentation.tabTitle),
            ("screen.title", CapturesPresentation.screenTitle),
            ("file.title", row.title),
            ("file.recording", CapturesPresentation.recordingBadgeTitle),
            (
                "file.accessibilityValue",
                CapturesPresentation.rowAccessibilityValue(
                    size: row.sizeText,
                    time: "22:13",
                    isRecording: false
                )
            ),
            (
                "file.accessibilityValue.recording",
                CapturesPresentation.rowAccessibilityValue(
                    size: row.sizeText,
                    time: "22:13",
                    isRecording: true
                )
            ),
            ("file.share", CapturesPresentation.shareAccessibilityLabel(for: row)),
            ("action.menu", CapturesPresentation.actionsMenuTitle),
            ("action.rotate", CapturesPresentation.rotateActionTitle),
            ("action.delete", CapturesPresentation.deleteActionTitle),
            ("action.export", CapturesPresentation.exportActionTitle),
            ("action.share", CapturesPresentation.shareActionTitle),
            ("delete.confirm.title", CapturesPresentation.deletionDialogTitle),
            ("delete.confirm.message", CapturesPresentation.deletionPrompt(for: row)),
            ("export.description", CapturesPresentation.exportActionDescription),
            ("export.sheet.title", CapturesPresentation.exportSheetTitle),
            ("export.share", CapturesPresentation.exportShareTitle),
            ("summary.one", CapturesPresentation.summary([file(1, bytes: 24)]).text),
            ("summary.other", CapturesPresentation.summary([]).text),
            ("notice.rotated", CapturesPresentation.rotated.message),
            ("notice.rotateUnavailable", CapturesPresentation.rotateUnavailable.message),
            ("notice.rotateFailed", CapturesPresentation.rotateFailed("ENOSPC").message),
            ("notice.deletionFailed", CapturesPresentation.deletionFailed("EPERM").message),
            ("notice.cannotDeleteRecording", CapturesPresentation.cannotDeleteRecording.message),
            ("notice.refreshFailed", CapturesPresentation.refreshFailed(.notFound(3)).message),
            ("export.notice.nothingToExport", CapturesPresentation.nothingToExport.message),
            ("headroom.section", CapturesPresentation.headroomSectionTitle),
            ("headroom.unreadable", CapturesPresentation.retentionUnreadable(.corruptData("bad JSON")).message),
        ]

        // El estado de los topes, en los cinco desenlaces que sabe decir. La fecha de caducidad no
        // entra por lo mismo que las horas: la formatea la vista con el huso del dispositivo.
        for (name, reading) in [
            ("headroom.unbounded", CaptureHeadroom.unbounded(used: 2_048)),
            ("headroom.within", .bounded(size: .within(used: 10, limit: 400), expiry: .never)),
            ("headroom.reached", .bounded(size: .reached(used: 600, limit: 400), expiry: .undated)),
            ("headroom.unmeetable", .bounded(size: .unmeetable(used: 600, limit: 400), expiry: .overdue(count: 1))),
            ("headroom.noSizeLimit", .bounded(size: .unlimited(used: 10), expiry: .overdue(count: 4))),
            (
                "headroom.dated",
                .bounded(size: .within(used: 10, limit: 400), expiry: .on(Date(timeIntervalSince1970: 0)))
            ),
        ] {
            let display = CapturesPresentation.headroom(reading)
            copy.append(("\(name).headline", display.headline))
            copy.append(("\(name).usage", display.usage))
            copy.append(("\(name).detail", display.detail))
            switch display.expiry {
            case .dated(let label, _):
                copy.append(("\(name).expiry.label", label))
            case .stated(let text):
                copy.append(("\(name).expiry", text))
            case nil:
                break
            }
        }

        for (name, count, truncated) in [
            ("export.summary.title.one", 1, false),
            ("export.summary.title.other", 1_204, false),
            ("export.truncation.one", 1, true),
            ("export.truncation.other", 20_000, true),
        ] {
            let summary = CapturesPresentation.exportPrepared(
                exportResult(connectionCount: count, truncated: truncated)
            )
            copy.append((name, truncated ? (summary.truncationNote ?? "") : summary.title))
            copy.append(("export.summary.detail", summary.detail))
        }

        for (name, error) in [
            ("export.failure.historyUnreadable", FlowExportError.historyUnreadable(.queryFailed("db"))),
            ("export.failure.writeFailed", .writeFailed("ENOSPC")),
        ] {
            copy.append((name, CapturesPresentation.exportFailed(error).message))
        }

        for (name, state) in [
            ("empty", CapturesState.loaded),
            ("failure.containerUnavailable", .failed(.containerUnavailable("group.test"))),
            ("failure.deletionFailed", .failed(.deletionFailed("EPERM"))),
            ("failure.notFound", .failed(.notFound(3))),
            ("failure.recordUnreadable", .failed(.recordUnreadable("short read"))),
        ] {
            guard case .placeholder(let placeholder) =
                CapturesPresentation.content(state: state, files: [])
            else { continue }
            copy.append(("\(name).title", placeholder.title))
            copy.append(("\(name).message", placeholder.message))
            if let actionTitle = placeholder.actionTitle {
                copy.append(("\(name).action", actionTitle))
            }
        }

        return copy
    }

    private func exportResult(
        connectionCount: Int,
        byteCount: UInt64 = 4_096,
        truncated: Bool = false
    ) -> FlowExportResult {
        FlowExportResult(
            url: URL(fileURLWithPath: "/tmp/tunnelvision-connections-20231114-221320.json"),
            connectionCount: connectionCount,
            byteCount: byteCount,
            truncated: truncated
        )
    }
}
