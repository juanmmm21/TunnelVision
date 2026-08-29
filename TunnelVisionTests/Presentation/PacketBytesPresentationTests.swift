import Foundation
import XCTest
import Shared

/// Tests del núcleo puro de la pantalla de los bytes de un paquete (M9).
///
/// Dos cosas se afirman aquí y no en ningún otro sitio: que el volcado hexadecimal es **legible y
/// determinista** (posiciones, columnas y ASCII), y que los bytes solo se pintan cuando son los **de
/// este paquete** — que es la única comprobación que se puede hacer y la razón de que exista
/// `CaptureLocation`.
final class PacketBytesPresentationTests: XCTestCase {

    // MARK: - Utilidades

    private func record(
        bytes: Data,
        originalLength: UInt32? = nil,
        sequence: UInt32 = 7,
        offset: UInt64 = 1_024
    ) -> CaptureRecord {
        CaptureRecord(
            location: CaptureLocation(fileSequence: sequence, recordOffset: offset),
            bytes: bytes,
            originalLength: originalLength ?? UInt32(bytes.count),
            timestampMicroseconds: 1_500
        )
    }

    private func summary(
        length: UInt32 = 64,
        direction: Direction = .outbound,
        event: PacketEvent = .data,
        flags: String? = nil,
        capture: CaptureLocation? = CaptureLocation(fileSequence: 7, recordOffset: 1_024)
    ) -> PacketSummary {
        PacketSummary(
            id: 1,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            offset: 0.004,
            direction: direction,
            length: length,
            event: event,
            flagsDetail: flags,
            capture: capture
        )
    }

    // MARK: - Volcado hexadecimal

    func testALineHoldsSixteenBytesInTwoGroupsWithItsAsciiReading() {
        // "GET /index.html " — 16 bytes ASCII imprimibles, para ver las tres columnas a la vez.
        let line = HexDump.lines(Data("GET /index.html ".utf8))[0]

        XCTAssertEqual(line.offset, 0)
        XCTAssertEqual(line.offsetLabel, "0000")
        // El hueco doble a mitad de línea es la referencia con la que se cuentan bytes con el dedo.
        XCTAssertEqual(line.hex, "47 45 54 20 2f 69 6e 64  65 78 2e 68 74 6d 6c 20")
        XCTAssertEqual(line.ascii, "GET /index.html ")
    }

    func testUnprintableBytesBecomeDotsSoTheColumnsStayAligned() {
        let line = HexDump.lines(Data([0x00, 0x0a, 0x7f, 0x80, 0xff, 0x20, 0x7e, 0x41]))[0]

        // El `0x0a` es un salto de línea real: pintarlo partiría la fila y descuadraría la única
        // columna que hace legible el volcado. El espacio (0x20) y la `~` (0x7e) sí son imprimibles,
        // y son los extremos del rango: fuera de ellos, punto.
        XCTAssertEqual(line.ascii, "..... ~A")
        XCTAssertEqual(line.hex, "00 0a 7f 80 ff 20 7e 41")
    }

    func testLinesAreNumberedByTheirPositionInThePacket() {
        let lines = HexDump.lines(Data(repeating: 0xEE, count: 40))

        XCTAssertEqual(lines.map(\.offset), [0, 16, 32])
        XCTAssertEqual(lines.map(\.offsetLabel), ["0000", "0010", "0020"])
        // La última línea va corta y **no** se rellena: alinear columnas es de la vista, que es quien
        // sabe con qué fuente se pinta.
        XCTAssertEqual(lines[2].hex, "ee ee ee ee ee ee ee ee")
    }

    func testAnEmptyPacketHasNoLinesAtAll() {
        XCTAssertTrue(HexDump.lines(Data()).isEmpty)
    }

    func testTheDumpIsCappedSoAHugePacketDoesNotBuildThousandsOfLines() {
        let lines = HexDump.lines(Data(repeating: 0x01, count: 5_000), limit: 64)

        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines.last?.offset, 48)
    }

    func testTheDumpReadsASliceFromItsOwnStartAndNotFromIndexZero() {
        // Los bytes de un registro salen de una lectura por offset, así que pueden llegar como una
        // porción cuyos índices no empiezan en 0. Indexar con enteros crudos leería otra cosa.
        let slice = Data([0xde, 0xad, 0xbe, 0xef, 0x41, 0x42])[4...]

        XCTAssertEqual(HexDump.lines(slice), [HexDumpLine(offset: 0, hex: "41 42", ascii: "AB")])
    }

    // MARK: - El volcado que sale de la app

    /// El texto que se comparte es el de `xxd`: tres columnas, y la del medio con el mismo hueco a la
    /// mitad que la de pantalla. No pasa por el catálogo porque no es copia — es un artefacto para
    /// pegar en otra herramienta, como los sellos ISO del export de conexiones.
    func testTheSharedDumpIsThreeAlignedColumns() {
        let text = HexDump.text(HexDump.lines(Data("GET /index.html ".utf8)))

        XCTAssertEqual(text, "0000  47 45 54 20 2f 69 6e 64  65 78 2e 68 74 6d 6c 20  GET /index.html ")
    }

    /// Aquí la última línea **sí** se rellena, al revés que en pantalla: no hay una vista que alinee
    /// nada, así que sin el relleno la columna de texto se desplazaría en el último renglón y el bloque
    /// dejaría de leerse pegado en cualquier otro sitio.
    func testTheLastLineIsPaddedSoTheTextColumnStaysPut() {
        let lines = HexDump.text(HexDump.lines(Data(repeating: 0xEE, count: 20)))
            .split(separator: "\n")

        XCTAssertEqual(lines.count, 2)
        // Posición (4) + dos espacios + la columna hexadecimal llena (48) + dos espacios. Lo único que
        // cambia entre las dos líneas es lo que hay **después**, que es su texto.
        let textColumnStart = 4 + 2 + 48 + 2
        XCTAssertEqual(lines[0].count, textColumnStart + 16)
        XCTAssertEqual(lines[1].count, textColumnStart + 4, "la corta rellena su hexadecimal, no su texto")
    }

    func testAnEmptyDumpIsAnEmptyString() {
        XCTAssertEqual(HexDump.text([]), "")
    }

    // MARK: - Los bytes son de este paquete

    func testBytesAreShownWhenTheRecordDescribesThisPacket() {
        let state = PacketBytesPresentation.verify(record(bytes: Data(repeating: 1, count: 64)), expectedLength: 64)

        guard case .loaded = state else { return XCTFail("estado inesperado: \(state)") }
    }

    /// La comprobación que da sentido a todo el increment: si el registro leído dice medir otra cosa,
    /// el offset ha llevado a otro paquete, y enseñar esos bytes sería atribuirle a una conexión el
    /// tráfico de otra. No debería pasar —una secuencia borrada no se reutiliza—, y por eso mismo se
    /// afirma: es el invariante, no un caso frecuente.
    func testBytesThatDescribeAnotherPacketAreNotShown() {
        let state = PacketBytesPresentation.verify(
            record(bytes: Data(repeating: 1, count: 40), originalLength: 40), expectedLength: 64
        )

        XCTAssertEqual(state, .unavailable(.mismatched(expected: 64, found: 40)))
        // Y el hueco no ofrece reintentar: repetir la lectura devolvería exactamente lo mismo.
        XCTAssertNil(PacketBytesPresentation.placeholder(for: .mismatched(expected: 64, found: 40)).action)
    }

    /// Un paquete recortado por `snaplen` **no** es un descuadre: `orig_len` sigue siendo el tamaño
    /// real, que es contra lo que se compara. Sin esto, todo paquete grande se leería como corrupto.
    func testATruncatedRecordStillDescribesItsPacket() {
        let state = PacketBytesPresentation.verify(
            record(bytes: Data(repeating: 1, count: 32), originalLength: 1_500), expectedLength: 1_500
        )

        guard case .loaded = state else { return XCTFail("estado inesperado: \(state)") }
    }

    // MARK: - Por qué no hay bytes

    func testADeletedCaptureIsNotReportedAsABreakage() {
        XCTAssertEqual(PacketBytesPresentation.unavailable(for: .notFound(9)), .fileDeleted(9))

        let placeholder = PacketBytesPresentation.placeholder(for: .fileDeleted(9))
        // Ni papel de aviso ni reintento: el fichero lo borró su dueño y no va a volver. Lo que sí
        // dice es lo que **no** se perdió, que es la conexión.
        XCTAssertEqual(placeholder.role, .neutral)
        XCTAssertNil(placeholder.action)
        XCTAssertTrue(placeholder.message.contains("stay in your history"))
    }

    func testAPacketThatWasNeverCapturedExplainsItselfWithoutOfferingARetry() {
        let placeholder = PacketBytesPresentation.placeholder(for: .notCaptured)

        XCTAssertEqual(placeholder.role, .neutral)
        XCTAssertNil(placeholder.action)
    }

    func testOnlyARealReadFailureOffersToTryAgain() {
        for error in [
            CaptureLibraryError.recordUnreadable("cut short"),
            .containerUnavailable("group.test"),
            .deletionFailed("nope"),
        ] {
            XCTAssertEqual(PacketBytesPresentation.unavailable(for: error), .failed(error))
        }

        let placeholder = PacketBytesPresentation.placeholder(for: .failed(.recordUnreadable("cut short")))
        XCTAssertEqual(placeholder.role, .warning)
        XCTAssertEqual(placeholder.action, .retry)
        // El detalle técnico va aparte de la copia, como en todas las pantallas.
        XCTAssertEqual(placeholder.diagnostic, "cut short")
    }

    // MARK: - Cuerpo

    func testEveryStateFallsInExactlyOneBody() {
        XCTAssertEqual(PacketBytesPresentation.content(state: .idle), .loading)
        XCTAssertEqual(PacketBytesPresentation.content(state: .loading), .loading)

        let bytes = PacketBytesPresentation.content(state: .loaded(record(bytes: Data([0x41, 0x42]))))
        XCTAssertEqual(bytes, .bytes([HexDumpLine(offset: 0, hex: "41 42", ascii: "AB")]))

        guard case .placeholder = PacketBytesPresentation.content(state: .unavailable(.notCaptured)) else {
            return XCTFail("un motivo sin bytes se pinta como hueco")
        }
    }

    // MARK: - Avisos y datos

    func testAWholePacketSaysNothingAboutTruncation() {
        XCTAssertNil(PacketBytesPresentation.truncationNote(for: record(bytes: Data(repeating: 0, count: 64))))
    }

    func testTheTwoWaysOfShowingLessThanThePacketAreCountedApart() throws {
        // (1) El `snaplen` se llevó parte **al capturar**: eso ya no tiene vuelta.
        let snaplenNote = try XCTUnwrap(
            PacketBytesPresentation.truncationNote(
                for: record(bytes: Data(repeating: 0, count: 32), originalLength: 1_500)
            )
        )
        XCTAssertTrue(snaplenNote.contains("1.5 KB"))
        XCTAssertFalse(snaplenNote.contains("Showing the first"))

        // (2) La pantalla pinta menos de lo que hay: eso solo afecta a lo que se ve.
        let limitNote = try XCTUnwrap(
            PacketBytesPresentation.truncationNote(
                for: record(bytes: Data(repeating: 0, count: 4_000)), limit: 2_048
            )
        )
        XCTAssertTrue(limitNote.contains("Showing the first 2 KB"))

        // (3) Los dos a la vez se cuentan los dos: confundirlos dejaría al usuario creyendo que un
        // paquete de 9 KB midió 2 KB.
        let both = try XCTUnwrap(
            PacketBytesPresentation.truncationNote(
                for: record(bytes: Data(repeating: 0, count: 4_000), originalLength: 9_000), limit: 2_048
            )
        )
        XCTAssertTrue(both.contains("9 KB"))
        XCTAssertTrue(both.contains("Showing the first 2 KB"))
    }

    func testThePacketFactsDoNotNeedAnyFileToBeOpened() {
        let facts = PacketBytesPresentation.packetFacts(summary(length: 1_514, direction: .inbound))

        XCTAssertEqual(facts.map(\.label), ["When", "Direction", "Size"])
        XCTAssertEqual(facts[0].value, .text("0.004 s"))
        XCTAssertEqual(facts[1].value, .text(DirectionLabel.inbound))
        XCTAssertEqual(facts[2].value, .text("1.5 KB"))
    }

    /// El resumen tiene **la misma forma en todos los paquetes**, y eso es lo que resuelve la fila
    /// suelta que arrastraba: las siglas eran un cuarto dato que solo trae TCP, así que una rejilla de
    /// dos columnas dejaba un hueco en todo lo que no lo es —DNS y QUIC van sobre UDP—. Fijas en tres,
    /// caben en una fila y no sobra ninguna.
    func testThePacketFactsAreAlwaysThreeSoTheGridNeverEndsInAnOrphan() {
        XCTAssertEqual(PacketBytesPresentation.packetFacts(summary(flags: "SYN, ACK")).count, 3)
        XCTAssertEqual(PacketBytesPresentation.packetFacts(summary(flags: nil)).count, 3)
    }

    /// Las siglas se fueron al titular, que es su lectura, y allí se leen solas: dichas en voz alta y
    /// sin nada delante son una sílaba suelta, así que la frase que las nombra se compone aquí —donde
    /// los dos puntos y el orden son traducibles— y no en la vista.
    func testTheFlagsSayTheirOwnNameToVoiceOverNowThatTheGridDoesNot() {
        let spoken = PacketBytesPresentation.flagsAccessibilityLabel("SYN, ACK")

        XCTAssertTrue(spoken.contains("SYN, ACK"), spoken)
        XCTAssertNotEqual(spoken, "SYN, ACK", "sin rótulo, VoiceOver dice unas siglas sin decir de qué")
    }

    /// Son **dos** y nombran de dónde salieron los bytes, que es lo que se lee encima de ellos. El
    /// tercero que había —cuánto se guardó— no se mudó: se fue. Decía lo mismo que *Size* en todo
    /// paquete que quepa entero, y en el único donde decía otra cosa lo cuenta el pie del volcado con
    /// las dos cifras, que es lo que afirma el segundo bloque.
    func testTheRecordFactsNameTheFileTheWayTheCapturesScreenDoes() throws {
        let whole = record(bytes: Data(repeating: 0, count: 100), originalLength: 100, sequence: 7, offset: 1_048_600)
        let facts = PacketBytesPresentation.recordFacts(whole)

        XCTAssertEqual(facts.map(\.label), ["Capture file", "Position in file"])
        // Con el mismo relleno que el nombre del fichero, para poder ir a buscarlo a Captures.
        XCTAssertEqual(facts[0].value, .text("000007"))
        XCTAssertEqual(facts[1].value, .text("1,048,600 B"))

        // Lo que el dato retirado decía, dicho en los dos sitios que ya lo decían: en un paquete
        // entero es exactamente *Size*, y en uno recortado es el pie del volcado con las dos cifras.
        XCTAssertEqual(
            PacketBytesPresentation.packetFacts(summary(length: 100)).last?.value,
            .text(DisplayFormat.bytes(UInt64(whole.capturedLength)))
        )
        let cut = try XCTUnwrap(PacketBytesPresentation.truncationNote(
            for: record(bytes: Data(repeating: 0, count: 100), originalLength: 1_500)
        ))
        XCTAssertTrue(cut.contains("100 B"), "el pie no dice cuánto se guardó: \(cut)")
        XCTAssertTrue(cut.contains("1.5 KB"), "el pie no dice cuánto medía: \(cut)")
    }

    // MARK: - La copia por el catálogo (M11)

    /// La identidad de un dato **no es su rótulo**, que es lo que era: dos rótulos que un idioma dijera
    /// igual colisionarían en un `ForEach` y SwiftUI dejaría de pintar uno. Las dos listas ya no van
    /// concatenadas —los datos del registro se leen bajo *Raw bytes*—, y se siguen afirmando juntas:
    /// son datos del mismo tipo y volver a juntarlas no puede costar una colisión.
    func testTheTwoFactListsNeverShareAnIdentity() {
        let record = record(bytes: Data(repeating: 0, count: 100), originalLength: 1_500)
        let grid = PacketBytesPresentation.packetFacts(summary(flags: "SYN, ACK"))
            + PacketBytesPresentation.recordFacts(record)

        XCTAssertEqual(grid.map(\.id), [
            "when", "direction", "size", "captureFile", "positionInFile",
        ])
        XCTAssertEqual(Set(grid.map(\.id)).count, grid.count, "dos datos con la misma identidad")
        for fact in grid {
            XCTAssertNotEqual(fact.id, fact.label, "\(fact.id) vuelve a identificarse por su copia")
        }
    }

    /// Lo que VoiceOver oye de una línea del volcado lo compone `HexDumpLine` y no la vista: el
    /// separador y el orden son de un idioma. Y sigue callándose los pares hexadecimales, que es lo que
    /// hace la línea escuchable.
    func testWhatVoiceOverHearsOfADumpLineSaysThePositionAndTheTextButNotTheHex() {
        let line = HexDump.lines(Data("GET /index.html ".utf8))[0]

        let spoken = line.accessibilityLabel
        XCTAssertTrue(spoken.contains("0000"), spoken)
        XCTAssertTrue(spoken.contains("GET /index.html"), spoken)
        XCTAssertFalse(spoken.contains(line.hex), "los 16 pares no se leen en voz alta: \(spoken)")
    }

    /// Los dos avisos pueden salir solos o juntos, y juntarlos es **una clave** y no un `joined` en
    /// Swift: pegar dos frases con un espacio decide fuera del catálogo el orden y el separador.
    func testTheTwoTruncationNotesAreSaidTogetherAsOneSentence() throws {
        let snaplen = try XCTUnwrap(
            PacketBytesPresentation.truncationNote(
                for: record(bytes: Data(repeating: 0, count: 4_000), originalLength: 9_000), limit: 4_096
            )
        )
        let limited = try XCTUnwrap(
            PacketBytesPresentation.truncationNote(
                for: record(bytes: Data(repeating: 0, count: 4_000)), limit: 2_048
            )
        )
        let both = try XCTUnwrap(
            PacketBytesPresentation.truncationNote(
                for: record(bytes: Data(repeating: 0, count: 4_000), originalLength: 9_000), limit: 2_048
            )
        )

        XCTAssertTrue(both.hasPrefix(snaplen), both)
        XCTAssertTrue(both.hasSuffix(limited), both)
        XCTAssertFalse(both.contains("  "), "las dos frases van con un solo espacio: \(both)")
    }

    /// Toda la copia de la pantalla, con el sitio del que sale. Los diagnósticos no entran: son detalle
    /// técnico y no pasan por el catálogo, igual que el del llavero en el flujo de la CA.
    private var everyPieceOfCopy: [(where: String, text: String)] {
        let record = record(bytes: Data(repeating: 0, count: 4_000), originalLength: 9_000)
        var copy: [(where: String, text: String)] = [
            ("section.rawBytes", PacketBytesPresentation.rawBytesSectionTitle),
            ("hexDump.line", HexDump.lines(Data("GET /".utf8))[0].accessibilityLabel),
        ]

        for fact in PacketBytesPresentation.packetFacts(summary(flags: "SYN, ACK")) {
            copy.append(("fact.\(fact.id)", fact.label))
        }
        for fact in PacketBytesPresentation.recordFacts(record) {
            copy.append(("fact.\(fact.id)", fact.label))
        }
        copy.append(("flags.accessibilityLabel", PacketBytesPresentation.flagsAccessibilityLabel("SYN, ACK")))

        for (name, note) in [
            ("truncation.whenCaptured", PacketBytesPresentation.truncationNote(for: record, limit: 8_192)),
            ("truncation.whenShown", PacketBytesPresentation.truncationNote(
                for: self.record(bytes: Data(repeating: 0, count: 4_000)), limit: 2_048
            )),
            ("truncation.both", PacketBytesPresentation.truncationNote(for: record, limit: 2_048)),
        ] {
            if let note { copy.append((name, note)) }
        }

        for (name, reason) in [
            ("empty.notCaptured", PacketBytesUnavailable.notCaptured),
            ("empty.fileDeleted", .fileDeleted(9)),
            ("empty.mismatched", .mismatched(expected: 64, found: 40)),
            ("failure.unreadable", .failed(.recordUnreadable("cut short"))),
        ] {
            let placeholder = PacketBytesPresentation.placeholder(for: reason)
            copy.append(("\(name).title", placeholder.title))
            copy.append(("\(name).message", placeholder.message))
            if let actionTitle = placeholder.actionTitle {
                copy.append(("\(name).action", actionTitle))
            }
        }

        return copy
    }

    /// El fallo característico de una migración al catálogo: una llamada sin `defaultValue` devuelve
    /// **la clave**, y una clave estructural se lee perfectamente en un diff sin llamar la atención.
    func testNoCopyIsARawCatalogKey() {
        for piece in everyPieceOfCopy {
            for prefix in ["packetDetail.", "packet.", "traffic.", "common."] {
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
}
