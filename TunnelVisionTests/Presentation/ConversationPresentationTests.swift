import Foundation
import XCTest
import Shared

/// Tests del núcleo puro de la mitad descifrada del Flow Inspector (M8, pieza 4).
///
/// Aquí se afirman las tres decisiones de la pantalla, que son lo único de esta pieza que no estaba ya
/// resuelto por debajo: **qué es un turno** (una racha del mismo sentido, no un trozo), **qué se dice
/// de lo que no cupo** (lo de un turno con cifras, lo de después sin ninguna) y **cómo se pinta** lo
/// leído (texto cuando es texto, hexadecimal cuando no).
final class ConversationPresentationTests: XCTestCase {

    // MARK: - Utilidades

    private let flow = HistoryFixtures.historyFlow(tlsStatus: .inspected)

    private func turn(
        direction: Direction = .outbound,
        chunks: [StoredPlaintextChunk]
    ) -> ConversationTurn {
        ConversationTurn(
            id: chunks.first?.id ?? 1,
            direction: direction,
            date: HistoryFixtures.anchorWallClock,
            offset: 0.25,
            chunks: chunks
        )
    }

    // MARK: - Qué es un turno

    func testConsecutiveChunksOfTheSameSideAreOneTurn() {
        let chunks = [
            HistoryFixtures.storedChunk(id: 1, at: 0.1, direction: .outbound),
            HistoryFixtures.storedChunk(id: 2, at: 0.2, direction: .outbound),
            HistoryFixtures.storedChunk(id: 3, at: 0.3, direction: .outbound),
        ]

        let turns = ConversationPresentation.turns(chunks, flow: flow)

        XCTAssertEqual(turns.count, 1, "Tres lecturas seguidas del mismo lado son una sola cosa dicha.")
        XCTAssertEqual(turns.first?.chunks.count, 3)
        XCTAssertEqual(turns.first?.direction, .outbound)
    }

    func testTheOnlyBoundaryIsTheChangeOfSide() {
        let chunks = [
            HistoryFixtures.storedChunk(id: 1, at: 0.1, direction: .outbound),
            HistoryFixtures.storedChunk(id: 2, at: 0.2, direction: .inbound),
            HistoryFixtures.storedChunk(id: 3, at: 0.3, direction: .inbound),
            HistoryFixtures.storedChunk(id: 4, at: 0.4, direction: .outbound),
        ]

        let turns = ConversationPresentation.turns(chunks, flow: flow)

        XCTAssertEqual(turns.map(\.direction), [.outbound, .inbound, .outbound])
        XCTAssertEqual(turns.map(\.chunks.count), [1, 2, 1])
    }

    func testALongSilenceDoesNotSplitATurn() {
        // Una respuesta lenta sigue siendo **una** respuesta: cortar por un hueco de tiempo exigiría
        // un umbral inventado, y esta es la afirmación que lo impide.
        let chunks = [
            HistoryFixtures.storedChunk(id: 1, at: 0.1, direction: .inbound),
            HistoryFixtures.storedChunk(id: 2, at: 30, direction: .inbound),
        ]

        XCTAssertEqual(ConversationPresentation.turns(chunks, flow: flow).count, 1)
    }

    func testATurnIsIdentifiedByItsFirstChunkAndDatedFromTheConnectionStart() {
        let chunks = [
            HistoryFixtures.storedChunk(id: 41, at: 0.5, direction: .inbound),
            HistoryFixtures.storedChunk(id: 42, at: 0.6, direction: .inbound),
        ]

        let turn = ConversationPresentation.turns(chunks, flow: flow).first

        XCTAssertEqual(turn?.id, 41)
        XCTAssertEqual(turn?.date, HistoryFixtures.anchorWallClock.addingTimeInterval(0.5))
        // El origen es `firstSeen` del flujo, no el primer trozo: antes del primer byte descifrado va
        // el handshake, así que los dos nunca coinciden.
        XCTAssertEqual(turn?.offset ?? 0, 0.5, accuracy: 0.0001)
    }

    func testNoChunksMakeNoTurns() {
        XCTAssertTrue(ConversationPresentation.turns([], flow: flow).isEmpty)
    }

    func testATurnAddsUpWhatWasKeptAndWhatItMeasured() {
        let turn = turn(chunks: [
            HistoryFixtures.storedChunk(id: 1, storedLength: 100, originalLength: 100),
            HistoryFixtures.storedChunk(id: 2, storedLength: 40, originalLength: 900),
        ])

        XCTAssertEqual(turn.storedLength, 140)
        XCTAssertEqual(turn.originalLength, 1_000)
        XCTAssertTrue(turn.isTruncated)
    }

    // MARK: - Qué se lee

    func testReadingATurnStopsAtItsFirstTruncatedChunk() {
        // Los bytes de un trozo recortado no continúan en el siguiente: concatenarlos empalmaría dos
        // posiciones del stream y enseñaría una frase que nadie escribió.
        let turn = turn(chunks: [
            HistoryFixtures.storedChunk(id: 1, storedLength: 10),
            HistoryFixtures.storedChunk(id: 2, storedLength: 10, originalLength: 5_000),
            HistoryFixtures.storedChunk(id: 3, storedLength: 10),
        ])

        XCTAssertEqual(ConversationPresentation.readable(turn).map(\.id), [1, 2])
    }

    func testATurnIsReadWholeAndNotOnlyItsPreview() {
        // Lo que la pantalla dibuja está acotado; lo que el botón de compartir entrega, no. Leer solo
        // la vista previa dejaría el resto guardado y fuera del alcance de su dueño.
        let turn = turn(chunks: (1...10).map {
            HistoryFixtures.storedChunk(id: Int64($0), storedLength: 4_000)
        })

        XCTAssertEqual(ConversationPresentation.readable(turn).count, 10)
    }

    // MARK: - Cómo se pinta

    func testTextIsDrawnAsText() {
        let request = Data("GET /index.html HTTP/1.1\r\nHost: example.com\r\n\r\n".utf8)

        XCTAssertEqual(
            ConversationPresentation.body(for: request),
            .text("GET /index.html HTTP/1.1\r\nHost: example.com")
        )
    }

    func testTheClosingOfAProtocolIsNotMaterialAndIsNotDrawn() {
        // Toda cabecera HTTP acaba en una línea en blanco, así que sin esto **todo** turno de texto
        // pinta un carril de aire al pie del pozo: cuatro líneas ocupaban seis, medido en el
        // Simulator, y lo que sobraba cambiaba con cada turno.
        let response = Data("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n".utf8)

        XCTAssertEqual(
            ConversationPresentation.body(for: response),
            .text("HTTP/1.1 204 No Content\r\nConnection: close")
        )
    }

    func testTheBlankLineInsideAResponseIsStructureAndStays() {
        // La de dentro separa la cabecera del cuerpo: quitarla pegaría el JSON al último encabezado
        // y convertiría en un párrafo lo que se lee por bloques.
        let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}\r\n".utf8)

        XCTAssertEqual(
            ConversationPresentation.body(for: response),
            .text("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}")
        )
    }

    func testTrimmingNeverEmptiesATurn() {
        // Un turno que solo dijo espacios no tenía cierre que quitarle: enmarcar la nada no es lo
        // mismo que no haber dicho nada, y un pozo vacío promete algo que no está.
        XCTAssertEqual(ConversationPresentation.body(for: Data("\r\n\r\n".utf8)), .text("\r\n\r\n"))
    }

    func testWhatIsCoveredIsWhatWasReadAndNotWhatIsDrawn() {
        // La diferencia entre las dos es el cierre, y medir por lo dibujado haría que una petición
        // entera anunciara que se ve a medias.
        let request = Data("GET / HTTP/1.1\r\n\r\n".utf8)

        let preview = ConversationPresentation.preview(for: request)

        XCTAssertEqual(preview.covered, request.count)
        XCTAssertEqual(preview.body, .text("GET / HTTP/1.1"))
    }

    func testACharacterCutInHalfByTheEndDoesNotSendTheWholeTurnToHexadecimal() {
        // Un turno acaba donde el presupuesto lo cortó, y eso parte el último carácter de cualquier
        // idioma que no sea inglés. Tirar el texto entero por ese byte mandaría a hexadecimal media
        // web del mundo.
        var bytes = Data("Añadió".utf8)
        XCTAssertNil(String(data: bytes.dropLast(), encoding: .utf8), "La `ó` mide dos bytes.")
        bytes.removeLast()

        guard case .text(let text) = ConversationPresentation.body(for: bytes) else {
            return XCTFail("Un carácter partido por el final no convierte el texto en binario.")
        }
        XCTAssertEqual(text, "Añadi")
    }

    func testBinaryIsDrawnAsHexadecimal() {
        let frame = Data([0x00, 0x00, 0x12, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00])

        guard case .hex(let lines) = ConversationPresentation.body(for: frame) else {
            return XCTFail("Un binario se vuelca, no se finge texto.")
        }
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.offset, 0)
    }

    func testAControlByteInsideValidUTF8StillCountsAsBinary() {
        // Un `NUL` es UTF-8 válido, así que la prueba de decodificación sola dejaría pasar binarios
        // enteros y la fila saldría vacía con rombos.
        let bytes = Data("HTTP".utf8) + Data([0x00]) + Data("body".utf8)

        guard case .hex = ConversationPresentation.body(for: bytes) else {
            return XCTFail("Los bytes de control delatan a un binario que decodifica por casualidad.")
        }
    }

    func testTabsAndNewlinesAreStructureAndNotControlBytes() {
        let headers = Data("Header: one\r\n\tcontinued\n".utf8)

        guard case .text = ConversationPresentation.body(for: headers) else {
            return XCTFail("Sin tabuladores ni saltos, un protocolo de texto se lee como un párrafo.")
        }
    }

    func testTheBodyIsCutToWhatTheScreenDraws() {
        let long = Data(String(repeating: "a", count: 10_000).utf8)

        guard case .text(let text) = ConversationPresentation.body(for: long, limit: 100) else {
            return XCTFail("Un turno largo sigue siendo texto.")
        }
        XCTAssertEqual(text.count, 100)
    }

    func testADumpIsCutHarderThanTextBecauseALineHoldsFarLess() {
        // Con el tope del texto, un turno binario salían 256 filas de una tirada. Se vio en el
        // Simulator, y el arreglo es que el corte se aplique **después** de decidir cómo se pinta.
        let binary = Data(repeating: 0x00, count: 8_000)

        guard case .hex(let lines) = ConversationPresentation.body(for: binary) else {
            return XCTFail("Ocho mil ceros no son texto.")
        }
        XCTAssertEqual(
            lines.count, ConversationPresentation.maxHexBytesShown / HexDump.bytesPerLine
        )
        XCTAssertLessThan(
            ConversationPresentation.maxHexBytesShown, ConversationPresentation.maxBytesShown
        )
    }

    func testNothingSaidIsEmptyTextAndNotAnEmptyDump() {
        XCTAssertEqual(ConversationPresentation.body(for: Data()), .text(""))
    }

    // MARK: - Lo que no cupo

    func testACutTurnSaysWhatWasKeptAndThatItsSideStoppedBeingKept() {
        let sent = turn(
            direction: .outbound,
            chunks: [HistoryFixtures.storedChunk(storedLength: 1_024, originalLength: 4_096)]
        )

        let note = ConversationPresentation.truncationNote(for: sent)

        XCTAssertNotNil(note)
        // La segunda mitad es la que no se puede omitir: agotado el presupuesto no queda fila que
        // contar, así que sin ella la conversación parecería acabar donde acaba el fichero.
        XCTAssertTrue(note?.contains("sent afterwards was kept") == true, note ?? "")
    }

    func testTheTwoDirectionsSayItWithTheirOwnWords() {
        let received = turn(
            direction: .inbound,
            chunks: [HistoryFixtures.storedChunk(storedLength: 1_024, originalLength: 4_096)]
        )

        XCTAssertTrue(
            ConversationPresentation.truncationNote(for: received)?
                .contains("received afterwards was kept") == true
        )
    }

    func testAWholeTurnSaysNothingAboutTruncation() {
        let whole = turn(chunks: [HistoryFixtures.storedChunk(storedLength: 512)])

        XCTAssertNil(ConversationPresentation.truncationNote(for: whole))
    }

    func testNoFigureIsEverClaimedForTheWholeConnection() {
        // La decisión de esta pieza: la única cifra derivable hoy es una cota inferior, y una cota
        // inferior presentada como total es mentira. Lo que se afirma aquí es que **no se afirma**:
        // ninguna frase de la pantalla lleva un total de la conversación.
        let cut = turn(chunks: [HistoryFixtures.storedChunk(storedLength: 64, originalLength: 3_200_000)])

        let note = ConversationPresentation.truncationNote(for: cut) ?? ""

        XCTAssertTrue(note.contains(DisplayFormat.bytes(64)), note)
        XCTAssertTrue(note.contains(DisplayFormat.bytes(3_200_000)), note)
        XCTAssertFalse(note.contains("in total"), note)
    }

    func testABodyDrawnInPartSaysSoWithoutClaimingAnythingWasLost() {
        let long = turn(chunks: [HistoryFixtures.storedChunk(storedLength: 10_000)])
        let preview = ConversationPresentation.preview(
            for: Data(String(repeating: "a", count: 10_000).utf8), limit: 100
        )

        let note = ConversationPresentation.bodyNote(for: long, preview: preview)

        XCTAssertEqual(
            note, "Showing the first \(DisplayFormat.bytes(100)) — sharing hands over all of it."
        )
    }

    func testABodyDrawnWholeSaysNothing() {
        let short = turn(chunks: [HistoryFixtures.storedChunk(storedLength: 4)])

        XCTAssertNil(
            ConversationPresentation.bodyNote(
                for: short, preview: ConversationBodyPreview(body: .text("abcd"), covered: 4)
            )
        )
    }

    func testAWholeTurnDoesNotClaimToBeCutBecauseOfItsClosingLines() {
        // El cierre que `material(of:)` descuenta no es material que se deje de enseñar. Contándolo,
        // toda petición HTTP —que siempre acaba en una línea en blanco— anunciaba que se veía a
        // medias, que es justo la confusión entre *no se guardó* y *no se dibuja*.
        let request = Data("GET / HTTP/1.1\r\n\r\n".utf8)
        let whole = turn(
            chunks: [HistoryFixtures.storedChunk(storedLength: UInt32(request.count))]
        )

        XCTAssertNil(
            ConversationPresentation.bodyNote(
                for: whole, preview: ConversationPresentation.preview(for: request)
            )
        )
    }

    func testAnUnreadableBodyHasNothingToSayAboutDrawing() {
        let turn = turn(chunks: [HistoryFixtures.storedChunk(storedLength: 4)])

        XCTAssertNil(
            ConversationPresentation.bodyNote(
                for: turn,
                preview: ConversationBodyPreview(body: .unavailable(.swept(3)), covered: 0)
            )
        )
    }

    func testAQueryThatFilledItsLimitSaysThereWasMore() {
        XCTAssertNotNil(ConversationPresentation.chunkLimitNote(shown: 500, limit: 500))
        XCTAssertNil(ConversationPresentation.chunkLimitNote(shown: 499, limit: 500))
    }

    // MARK: - La fila

    func testARowCarriesWhoSpokeWhenAndHowMuch() {
        let turn = turn(
            direction: .inbound,
            chunks: [HistoryFixtures.storedChunk(storedLength: 2_048)]
        )

        let row = ConversationPresentation.row(turn, bytes: .read(Data("hello".utf8)))

        XCTAssertEqual(row.id, turn.id)
        XCTAssertEqual(row.presentation.direction, DirectionLabel.inbound)
        XCTAssertEqual(row.presentation.size, DisplayFormat.bytes(2_048))
        XCTAssertEqual(row.presentation.offset, DisplayFormat.offset(0.25))
    }

    func testWhatVoiceOverHearsNeverIncludesTheContents() {
        // Un turno puede ser un megabyte de JSON o un volcado hexadecimal, y ninguno de los dos se
        // oye: el cuerpo se lee aparte, donde el usuario ya eligió leerlo.
        let secret = "password=hunter2"
        let turn = turn(chunks: [HistoryFixtures.storedChunk(storedLength: 16)])

        let row = ConversationPresentation.row(turn, bytes: .read(Data(secret.utf8)))

        XCTAssertFalse(row.presentation.accessibilityLabel.contains(secret))
        XCTAssertTrue(row.presentation.accessibilityLabel.contains(DirectionLabel.outbound))
    }

    func testAnUnreadableTurnSaysSoInsteadOfItsSize() {
        let turn = turn(chunks: [HistoryFixtures.storedChunk(storedLength: 16)])

        let row = ConversationPresentation.row(turn, bytes: .unavailable(.swept(4)))

        XCTAssertTrue(row.presentation.accessibilityLabel.contains("not available"))
        XCTAssertFalse(row.presentation.accessibilityLabel.contains(DisplayFormat.bytes(16)))
    }

    // MARK: - El cuerpo de la pantalla

    func testTurnsAreDrawnWhenThereAreTurns() {
        let row = ConversationPresentation.row(
            turn(chunks: [HistoryFixtures.storedChunk()]), bytes: .read(Data("hi".utf8))
        )

        XCTAssertEqual(ConversationPresentation.content(state: .loaded([row])), .turns([row]))
    }

    func testNothingLoadedYetIsLoadingAndNotAnEmpty() {
        XCTAssertEqual(ConversationPresentation.content(state: .idle), .loading)
        XCTAssertEqual(ConversationPresentation.content(state: .loading), .loading)
    }

    func testAConversationWithNoTurnsExplainsItselfWithoutOfferingARetry() {
        guard case .placeholder(let placeholder) =
            ConversationPresentation.content(state: .loaded([]))
        else {
            return XCTFail("Sin turnos hay que explicar por qué, no dejar la pantalla en blanco.")
        }
        XCTAssertNil(placeholder.action)
        XCTAssertEqual(placeholder.role, .neutral)
    }

    func testEveryTurnSweptCollapsesIntoOneExplanationWithNoRetry() {
        let rows = (1...3).map { id in
            ConversationPresentation.row(
                turn(chunks: [HistoryFixtures.storedChunk(id: Int64(id))]),
                bytes: .unavailable(.swept(9))
            )
        }

        guard case .placeholder(let placeholder) =
            ConversationPresentation.content(state: .loaded(rows))
        else {
            return XCTFail("Tres filas repitiendo la misma frase no son una conversación.")
        }
        XCTAssertNil(placeholder.action, "Un barrido no se deshace reintentando.")
        XCTAssertEqual(placeholder.role, .neutral)
    }

    func testAFaultWinsOverASweepWhenCollapsing() {
        // Un hueco que dijera "caducó" tapando un fichero ilegible se llevaría por delante el
        // reintento, que es la única salida que hay aquí.
        let rows = [
            ConversationPresentation.row(
                turn(chunks: [HistoryFixtures.storedChunk(id: 1)]), bytes: .unavailable(.swept(9))
            ),
            ConversationPresentation.row(
                turn(chunks: [HistoryFixtures.storedChunk(id: 2)]),
                bytes: .unavailable(.unreadable("cut short"))
            ),
        ]

        guard case .placeholder(let placeholder) =
            ConversationPresentation.content(state: .loaded(rows))
        else {
            return XCTFail("Ningún turno legible es un hueco.")
        }
        XCTAssertEqual(placeholder.action, .retry)
        XCTAssertEqual(placeholder.role, .warning)
        XCTAssertEqual(placeholder.diagnostic, "cut short")
    }

    func testOneUnreadableTurnAmongReadableOnesKeepsItsPlaceInTheConversation() {
        // Quitarla dejaría la conversación con forma de completa sin serlo.
        let rows = [
            ConversationPresentation.row(
                turn(chunks: [HistoryFixtures.storedChunk(id: 1)]), bytes: .read(Data("GET /".utf8))
            ),
            ConversationPresentation.row(
                turn(chunks: [HistoryFixtures.storedChunk(id: 2)]), bytes: .unavailable(.swept(9))
            ),
        ]

        XCTAssertEqual(ConversationPresentation.content(state: .loaded(rows)), .turns(rows))
    }

    // MARK: - De qué falla a qué se dice

    func testASweptFileIsNotAFailure() {
        XCTAssertEqual(ConversationPresentation.unavailable(for: .notFound(12)), .swept(12))

        guard case .placeholder(let placeholder) = ConversationPresentation.content(
            state: .loaded([
                ConversationPresentation.row(
                    turn(chunks: [HistoryFixtures.storedChunk()]), bytes: .unavailable(.swept(12))
                )
            ])
        ) else {
            return XCTFail("Un fichero barrido tiene su propia explicación.")
        }
        XCTAssertEqual(placeholder.role, .neutral)
    }

    func testAForeignRecordIsNeverShown() {
        XCTAssertEqual(
            ConversationPresentation.unavailable(for: .recordMismatch("belongs to 7, not 3")),
            .mismatched("belongs to 7, not 3")
        )

        let placeholder = ConversationPresentation.placeholder(
            for: .mismatched("belongs to 7, not 3")
        )
        XCTAssertNil(placeholder.action, "Reintentar no cambiaría de quién son esos bytes.")
        XCTAssertEqual(placeholder.role, .warning)
    }

    func testOnlyARealReadFailureOffersARetry() {
        XCTAssertEqual(
            ConversationPresentation.unavailable(for: .recordUnreadable("cut short")),
            .unreadable("cut short")
        )
        XCTAssertEqual(
            ConversationPresentation.unavailable(for: .containerUnavailable("group.tv")),
            .unreadable("group.tv")
        )
        XCTAssertEqual(
            ConversationPresentation.placeholder(for: .unreadable("cut short")).action, .retry
        )
    }

    // MARK: - Copia

    func testTheScreenIsCalledWhatTheSwitchThatFillsItIsCalled() {
        // Que coincidan es lo que ata el interruptor de Ajustes a lo que produce. Son claves distintas
        // a propósito, así que esto se afirma para que el día que una se reescriba la decisión se
        // vuelva a tomar.
        XCTAssertEqual(
            ConversationPresentation.title, SettingsPresentation.decryptedContentSectionTitle
        )
        XCTAssertEqual(
            FlowInspectorPresentation.contentSectionTitle, ConversationPresentation.title
        )
    }

    func testSharingNamesWhatIsDrawnAndNotTheConversation() {
        XCTAssertFalse(ConversationPresentation.shareTitle.lowercased().contains("conversation"))
    }

    // MARK: - Compartir

    func testSharingHandsOverEverythingKeptAndNotOnlyThePreview() {
        // Un turno llega a 64 KiB y ninguna pantalla lo aguanta, así que si compartir diese lo
        // dibujado el resto quedaría guardado en el dispositivo y fuera del alcance de su dueño.
        let long = Data(String(repeating: "a", count: 10_000).utf8)
        let turn = turn(chunks: [HistoryFixtures.storedChunk(storedLength: 10_000)])

        let row = ConversationPresentation.row(turn, bytes: .read(long))

        guard case .text(let drawn) = row.body else { return XCTFail("Diez mil letras son texto.") }
        XCTAssertEqual(drawn.count, ConversationPresentation.maxBytesShown)
        XCTAssertEqual(row.shareable?.count, 10_000)
    }

    func testABinaryIsSharedAsItsWholeDumpAndNotAsRawBytes() {
        let binary = Data(repeating: 0x00, count: 2_000)

        let row = ConversationPresentation.row(
            turn(chunks: [HistoryFixtures.storedChunk(storedLength: 2_000)]), bytes: .read(binary)
        )

        guard case .hex(let drawn) = row.body else { return XCTFail("Dos mil ceros no son texto.") }
        XCTAssertEqual(
            drawn.count, ConversationPresentation.maxHexBytesShown / HexDump.bytesPerLine
        )
        XCTAssertEqual(row.shareable, HexDump.text(HexDump.lines(binary, limit: binary.count)))
    }

    func testThereIsNothingToShareOfATurnWithoutBytes() {
        let turn = turn(chunks: [HistoryFixtures.storedChunk(storedLength: 4)])

        XCTAssertNil(ConversationPresentation.row(turn, bytes: .read(Data())).shareable)
        XCTAssertNil(ConversationPresentation.row(turn, bytes: .unavailable(.swept(3))).shareable)
    }
}
