import Foundation
import XCTest
@testable import Shared

/// Lo que el Flow Inspector enseña de una conexión y de cada uno de sus paquetes.
///
/// Aquí vive la decisión de copia del incremento: traducir las siglas TCP a lo que significaron en la
/// vida de la conexión. Es exactamente el sitio donde se cuela la jerga —o algo peor, una traducción
/// que dice lo que no fue—, así que se afirma en vez de revisarse a ojo.
final class FlowInspectorPresentationTests: XCTestCase {

    private let flow = HistoryFixtures.historyFlow(firstSeen: 0, lastSeen: 10)

    // MARK: - Qué fue cada paquete

    func testAHandshakeReadsAsOpeningAndAccepting() {
        XCTAssertEqual(PacketEvent.classify(flags: [.syn], proto: .tcp), .opened)
        XCTAssertEqual(PacketEvent.classify(flags: [.syn, .ack], proto: .tcp), .accepted)
    }

    func testDataAndPureAcknowledgementsAreToldApart() {
        XCTAssertEqual(PacketEvent.classify(flags: [.psh, .ack], proto: .tcp), .data)
        XCTAssertEqual(PacketEvent.classify(flags: [.ack], proto: .tcp), .acknowledged)
    }

    func testAGracefulCloseAndACutConnectionAreNotTheSameThing() {
        XCTAssertEqual(PacketEvent.classify(flags: [.fin, .ack], proto: .tcp), .closing)
        XCTAssertEqual(PacketEvent.classify(flags: [.rst], proto: .tcp), .reset)
        // Y solo el corte se pinta como aviso: si un cierre normal alarmara, el color dejaría de
        // significar nada.
        XCTAssertEqual(PacketEvent.closing.role, .neutral)
        XCTAssertEqual(PacketEvent.reset.role, .warning)
    }

    /// El orden de las comprobaciones es la decisión: un RST llega casi siempre con el ACK puesto, y
    /// leerlo como "confirmación" escondería justo lo que hay que contar.
    func testResetWinsOverEveryOtherFlag() {
        XCTAssertEqual(PacketEvent.classify(flags: [.rst, .ack], proto: .tcp), .reset)
        XCTAssertEqual(PacketEvent.classify(flags: [.rst, .fin, .psh, .ack], proto: .tcp), .reset)
    }

    /// Fuera de TCP no hay flags que interpretar: un datagrama es su propia carga.
    func testUDPPacketsAreJustData() {
        XCTAssertEqual(PacketEvent.classify(flags: [], proto: .udp), .data)
        XCTAssertEqual(PacketEvent.classify(flags: [], proto: .icmp), .data)
    }

    /// Un TCP sin ningún flag no debería existir; nombrarlo es más honesto que colarlo como dato.
    func testATCPPacketWithNoFlagsIsCalledUnusual() {
        XCTAssertEqual(PacketEvent.classify(flags: [], proto: .tcp), .other)
    }

    /// Ninguna etiqueta puede ser una sigla: eso es lo que esta pantalla existe para evitar.
    func testNoEventIsLabelledWithProtocolJargon() {
        let jargon = ["SYN", "ACK", "FIN", "RST", "PSH", "URG", "TCP"]
        for event in PacketEvent.allCases {
            XCTAssertFalse(event.label.isEmpty)
            XCTAssertFalse(event.detail.isEmpty, "la explicación la lee VoiceOver")
            for word in jargon {
                XCTAssertFalse(
                    event.label.contains(word),
                    "\(event) se enseña como jerga: \(event.label)"
                )
            }
        }
    }

    // MARK: - Las siglas, en secundario

    func testFlagsAreListedInReadingOrderAndVanishWhenThereAreNone() {
        XCTAssertEqual(FlowInspectorPresentation.flagsDetail([.ack, .syn]), "SYN, ACK")
        XCTAssertEqual(FlowInspectorPresentation.flagsDetail([.fin, .ack]), "ACK, FIN")
        XCTAssertNil(
            FlowInspectorPresentation.flagsDetail([]),
            "un datagrama UDP no tiene siglas que enseñar, y un guion no aporta nada"
        )
    }

    // MARK: - La lista

    func testPacketsAreTimedFromTheStartOfTheConnection() {
        let packets = [
            HistoryFixtures.storedPacket(id: 1, at: 0, tcpFlags: [.syn]),
            HistoryFixtures.storedPacket(id: 2, at: 0.004, direction: .inbound, tcpFlags: [.syn, .ack]),
            HistoryFixtures.storedPacket(id: 3, at: 1.5, length: 60, tcpFlags: [.psh, .ack]),
        ]

        let summaries = FlowInspectorPresentation.summaries(packets, flow: flow)

        XCTAssertEqual(summaries.map(\.id), [1, 2, 3])
        XCTAssertEqual(summaries.map(\.event), [.opened, .accepted, .data])
        XCTAssertEqual(summaries[0].offset, 0, accuracy: 0.0001)
        XCTAssertEqual(summaries[1].offset, 0.004, accuracy: 0.0001)
        XCTAssertEqual(summaries[2].offset, 1.5, accuracy: 0.0001)
        XCTAssertEqual(summaries[1].direction, .inbound)
        XCTAssertEqual(summaries[2].length, 60)
    }

    /// El sentido y el tamaño están en la fila, pero solo como icono y número: sin esto VoiceOver
    /// leería cuatro trozos sueltos sin decir qué fue el paquete.
    func testWhatVoiceOverReadsOfAPacketSaysWhatItWas() {
        let summary = FlowInspectorPresentation.summaries(
            [HistoryFixtures.storedPacket(at: 0.25, direction: .inbound, length: 1_500, tcpFlags: [.rst])],
            flow: flow
        )[0]

        let spoken = FlowInspectorPresentation.row(summary).accessibilityLabel
        XCTAssertTrue(spoken.contains("Connection cut off"))
        XCTAssertTrue(spoken.contains("Received"))
        XCTAssertTrue(spoken.contains("1.5 KB"))
        XCTAssertTrue(spoken.contains("0.250 s"))
        XCTAssertTrue(spoken.contains("RST"), "las siglas siguen ahí, para quien las sepa leer")
    }

    // MARK: - Cabecera

    func testTheHeaderSaysWhereItWentHowLongAndHowMuchInEachDirection() {
        let facts = FlowInspectorPresentation.facts(
            for: HistoryFixtures.historyFlow(remotePort: 443, firstSeen: 0, lastSeen: 10, sni: "example.com")
        )

        XCTAssertEqual(facts.map(\.label), [
            "Service", "First to last packet", "Duration", "Packets", "Received", "Sent",
        ])
        XCTAssertEqual(facts.first?.value, .text("TCP · port 443"))
        XCTAssertEqual(facts[2].value, .text("10 s"))
        XCTAssertEqual(facts[4].value, .text("2 KB"))
        XCTAssertEqual(facts[5].value, .text("1 KB"))
        // El tramo viaja como dos fechas, no como texto: la hora sí se localiza —y el guion que las
        // separa también— y las formatea la vista, al revés que los números.
        guard case .span(let seen) = facts[1].value else {
            return XCTFail("el tramo no puede venir ya formateado")
        }
        XCTAssertEqual(seen.lowerBound.timeIntervalSince(seen.upperBound), -10)
    }

    /// **La rejilla son dos columnas leídas por filas, así que un dato impar deja una fila suelta.**
    /// Eran siete y la séptima colgaba sola al final de la cabecera. Que sean pares no es una
    /// casualidad que se pueda romper añadiendo un dato: el día que alguien meta el octavo, esto le
    /// obliga a meter también el noveno o a decidir de quién es vecino.
    func testTheHeaderFillsItsGridWithoutLeavingARowHalfEmpty() {
        XCTAssertTrue(
            FlowInspectorPresentation.facts(for: flow).count.isMultiple(of: 2),
            "un número impar de datos deja una fila suelta al final de la rejilla"
        )
    }

    /// Los dos sentidos **caen en la misma fila**, que es la única comparación que la cabecera pide:
    /// cuánto entró contra cuánto salió. En una rejilla que se lee por filas eso es una posición par
    /// seguida de la impar de al lado — repartidos entre dos filas habría que leerlos en diagonal,
    /// que es justo lo que hacían los dos extremos del tramo antes de fundirse en uno.
    func testTheTwoDirectionsAreReadSideBySideAndNotDiagonally() {
        let ids = FlowInspectorPresentation.facts(for: flow).map(\.id)

        guard let inbound = ids.firstIndex(of: "bytesIn"), let outbound = ids.firstIndex(of: "bytesOut") else {
            return XCTFail("la cabecera dejó de decir los dos sentidos")
        }
        XCTAssertTrue(inbound.isMultiple(of: 2), "lo recibido no empieza fila, así que su vecino es otro")
        XCTAssertEqual(outbound, inbound + 1)
    }

    /// El tramo se acota donde se construye: el historial es una fuente externa y un `Range` con el
    /// final antes del principio **aborta el proceso**, no dibuja una celda rara. Un último paquete
    /// imposible se queda en un tramo vacío, que es lo único honesto que se puede decir de él.
    func testASpanNeverEndsBeforeItBegins() {
        let backwards = HistoryFixtures.historyFlow(firstSeen: 10, lastSeen: 0)

        guard case .span(let seen)? = FlowInspectorPresentation.facts(for: backwards)
            .first(where: { $0.id == "seen" })?.value else {
            return XCTFail("la cabecera dejó de decir el tramo")
        }
        XCTAssertTrue(seen.isEmpty)
    }

    /// La cabecera y la fila que la abrió son la misma conexión: si el reparto de extremos falló, las
    /// dos tienen que decir lo mismo en vez de que una invente un host.
    func testAFlowWithoutResolvedEndpointsKeepsItsHonestHeader() {
        let unresolved = HistoryFixtures.historyFlow(localAddresses: [])
        XCTAssertEqual(FlowDisplay.host(unresolved), FlowDisplay.unknownHost)
        XCTAssertEqual(FlowDisplay.service(unresolved), "TCP", "sin extremos no hay puerto que enseñar")
    }

    // MARK: - Estados

    func testNothingLoadedYetIsLoading() {
        XCTAssertEqual(FlowInspectorPresentation.content(state: .idle, rows: []), .loading)
        XCTAssertEqual(FlowInspectorPresentation.content(state: .loading, rows: []), .loading)
    }

    /// Que una conexión esté guardada no obliga a que lo estén sus paquetes: la captura pudo estar en
    /// metadatos-solo o la retención habérselos llevado. No hay nada roto, así que no hay reintento.
    func testAConnectionWithoutStoredPacketsExplainsItselfWithoutOfferingARetry() {
        guard case .placeholder(let placeholder) =
            FlowInspectorPresentation.content(state: .loaded, rows: [])
        else { return XCTFail("una lista vacía tiene que explicarse") }

        XCTAssertNil(placeholder.action)
        XCTAssertEqual(placeholder.role, .neutral)
    }

    func testAFailureIsActionableAndKeepsItsDiagnostic() {
        guard case .placeholder(let placeholder) = FlowInspectorPresentation.content(
            state: .failed(.queryFailed("database is locked")), rows: []
        ) else { return XCTFail("un fallo tiene que enseñarse") }

        XCTAssertEqual(placeholder.action, .retry)
        XCTAssertEqual(placeholder.actionTitle, "Try again")
        XCTAssertEqual(placeholder.diagnostic, "database is locked")
        XCTAssertEqual(placeholder.role, .warning)
    }

    func testACorruptRowIsNotTheSameMessageAsAQueryThatFailed() {
        guard case .placeholder(let corrupt) = FlowInspectorPresentation.content(
            state: .failed(.corruptData("fila 12")), rows: []
        ), case .placeholder(let failed) = FlowInspectorPresentation.content(
            state: .failed(.queryFailed("fila 12")), rows: []
        ) else { return XCTFail("los dos fallos tienen que enseñarse") }

        XCTAssertNotEqual(corrupt.title, failed.title)
    }

    /// La regla que manda, igual que en la Timeline: una lista ya pintada no la tapa nada.
    func testADrawnListIsNeverCoveredByALaterFailure() {
        let rows = FlowInspectorPresentation.rows(
            for: FlowInspectorPresentation.summaries([HistoryFixtures.storedPacket()], flow: flow)
        )
        XCTAssertEqual(
            FlowInspectorPresentation.content(state: .failed(.queryFailed("x")), rows: rows),
            .packets(rows)
        )
        XCTAssertEqual(
            FlowInspectorPresentation.content(state: .loading, rows: rows),
            .packets(rows)
        )
    }

    // MARK: - La copia fuera del camino de dibujo (M11)

    /// La fila viaja **con** su copia y no con el paquete a secas: es lo que hace imposible pintar una
    /// fila con la copia de otra, que es justo donde se separan un diccionario por id y la lista.
    func testEachRowCarriesItsOwnCopyAlreadyComposed() {
        let summaries = FlowInspectorPresentation.summaries(
            [
                HistoryFixtures.storedPacket(id: 1, at: 0, tcpFlags: [.syn]),
                HistoryFixtures.storedPacket(id: 2, at: 0.25, direction: .inbound, length: 1_500, tcpFlags: [.rst]),
            ],
            flow: flow
        )

        let rows = FlowInspectorPresentation.rows(for: summaries)

        XCTAssertEqual(rows.map(\.packet), summaries)
        XCTAssertEqual(rows.map(\.id), [1, 2], "la identidad es la del paquete, nunca la de su copia")
        XCTAssertEqual(rows[0].presentation.event, "Connection opened")
        XCTAssertEqual(rows[1].presentation.event, "Connection cut off")
        for row in rows {
            XCTAssertEqual(
                row.presentation,
                FlowInspectorPresentation.row(row.packet),
                "la fila \(row.id) lleva la copia de otro paquete"
            )
        }
    }

    /// Las dos cifras llegan ya formateadas: la vista no vuelve a llamar a `DisplayFormat` por
    /// fotograma, y de paso son deterministas y no bailan al actualizarse.
    func testTheFiguresOfARowArriveAlreadyFormatted() {
        let summary = FlowInspectorPresentation.summaries(
            [HistoryFixtures.storedPacket(at: 0.25, length: 1_500)], flow: flow
        )[0]

        let presentation = FlowInspectorPresentation.row(summary)

        XCTAssertEqual(presentation.offset, DisplayFormat.offset(0.25))
        XCTAssertEqual(presentation.length, DisplayFormat.bytes(1_500))
    }

    /// Sin siglas la frase accesible no arrastra un *Flags* vacío: son dos claves hermanas y la
    /// segunda solo existe cuando hay algo que decir (un datagrama UDP no las tiene).
    func testAPacketWithoutFlagsIsSpokenWithoutThem() {
        let plain = FlowInspectorPresentation.summaries(
            [HistoryFixtures.storedPacket(at: 0.25, tcpFlags: [])], flow: flow
        )[0]

        let spoken = FlowInspectorPresentation.row(plain).accessibilityLabel

        XCTAssertFalse(spoken.contains("Flags"))
        XCTAssertTrue(spoken.hasSuffix("."), "la frase se cierra igual, con siglas o sin ellas")
    }

    // MARK: - Lista recortada

    /// El tope de `HistoryPolicy.packetsPerFlow` evita traer media BD al abrir una conexión larga,
    /// pero callarlo dejaría al usuario creyendo que una conexión de miles de paquetes tuvo 500.
    func testATruncatedListSaysSo() {
        XCTAssertEqual(
            FlowInspectorPresentation.truncationNote(shown: 500, recorded: 1_204),
            "Showing the first 500 of 1,204 packets recorded for this connection."
        )
    }

    func testAWholeListSaysNothing() {
        XCTAssertNil(FlowInspectorPresentation.truncationNote(shown: 12, recorded: 12))
        // Y tampoco cuando el contador del flujo se ha quedado corto respecto a lo que se leyó: eso
        // no es un recorte, y anunciarlo sería contar una mentira al revés.
        XCTAssertNil(FlowInspectorPresentation.truncationNote(shown: 12, recorded: 10))
    }

    /// El singular del aviso **no es una rama muerta**: una conexión con un paquete contado y ninguno
    /// guardado lo alcanza. Se escribe como dos claves hermanas y nunca con el marcado de concordancia
    /// automática, que sin catálogo —y el bundle de tests no lleva ninguno— saldría crudo a la pantalla.
    func testTheTruncationNoteHasASingularAndDoesNotUseInflectionMarkup() {
        XCTAssertEqual(
            FlowInspectorPresentation.truncationNote(shown: 0, recorded: 1),
            "Showing the first 0 of 1 packet recorded for this connection."
        )

        for note in [
            FlowInspectorPresentation.truncationNote(shown: 0, recorded: 1),
            FlowInspectorPresentation.truncationNote(shown: 500, recorded: 1_204),
        ] {
            XCTAssertFalse(note?.contains("inflect:") == true, "el plural se escribe a mano: \(note ?? "")")
        }
    }

    // MARK: - La copia por el catálogo (M11)

    /// La identidad de un dato de la cabecera **no es su rótulo**, que es lo que era: al volverse
    /// traducible, la rejilla habría cambiado de identidad al cambiar de idioma —el mismo arreglo que
    /// necesitaron `IntroCardAction` y `ScrubCursorAction`.
    func testAFactIsIdentifiedByWhatItIsAndNotByWhatItSays() {
        let facts = FlowInspectorPresentation.facts(for: flow)

        XCTAssertEqual(facts.map(\.id), [
            "service", "seen", "duration", "packetCount", "bytesIn", "bytesOut",
        ])
        XCTAssertEqual(Set(facts.map(\.id)).count, facts.count, "dos datos con la misma identidad")
        for fact in facts {
            XCTAssertNotEqual(fact.id, fact.label, "\(fact.id) vuelve a identificarse por su copia")
        }
    }

    /// Los dos *Packets* de la pantalla dicen hoy la misma palabra y son **dos claves**: uno rotula una
    /// cifra de la rejilla y el otro nombra la sección de la lista, y un idioma puede necesitar decirlos
    /// distinto. Que coincidan es justo lo que hace tentador fundirlos, así que la coincidencia se
    /// afirma: el día que una de las dos se reescriba, esta decisión se vuelve a tomar a conciencia.
    func testTheSectionHeadingAndThePacketCountStillSayTheSameWord() {
        XCTAssertFalse(FlowInspectorPresentation.packetsSectionTitle.isEmpty)
        XCTAssertEqual(
            FlowInspectorPresentation.packetsSectionTitle,
            FlowInspectorPresentation.facts(for: flow).first(where: { $0.id == "packetCount" })?.label
        )
    }

    /// Toda la copia de la pantalla, con el sitio del que sale. Las horas no entran: las formatea la
    /// vista con el huso del dispositivo y no son copia.
    private var everyPieceOfCopy: [(where: String, text: String)] {
        var copy: [(where: String, text: String)] = [
            ("section.packets", FlowInspectorPresentation.packetsSectionTitle),
        ]

        for fact in FlowInspectorPresentation.facts(for: flow) {
            copy.append(("fact.\(fact.id)", fact.label))
        }

        for event in PacketEvent.allCases {
            copy.append(("event.\(event).label", event.label))
            copy.append(("event.\(event).detail", event.detail))
        }

        let packet = FlowInspectorPresentation.summaries(
            [HistoryFixtures.storedPacket(at: 0.25, direction: .inbound, length: 1_500, tcpFlags: [.rst])],
            flow: flow
        )[0]
        let row = FlowInspectorPresentation.row(packet)
        copy.append(("packetRow.event", row.event))
        copy.append(("packetRow.accessibilityLabel", row.accessibilityLabel))

        let plain = FlowInspectorPresentation.summaries(
            [HistoryFixtures.storedPacket(at: 0.25, tcpFlags: [])], flow: flow
        )[0]
        copy.append((
            "packetRow.accessibilityLabel.noFlags",
            FlowInspectorPresentation.row(plain).accessibilityLabel
        ))

        for (name, note) in [
            ("truncation.one", FlowInspectorPresentation.truncationNote(shown: 0, recorded: 1)),
            ("truncation.other", FlowInspectorPresentation.truncationNote(shown: 500, recorded: 1_204)),
        ] {
            if let note { copy.append((name, note)) }
        }

        for (name, state) in [
            ("empty.noPackets", FlowInspectorState.loaded),
            ("failure.queryFailed", .failed(.queryFailed("db locked"))),
            ("failure.corruptData", .failed(.corruptData("row 12"))),
        ] {
            guard case .placeholder(let placeholder) =
                FlowInspectorPresentation.content(state: state, rows: [])
            else { continue }
            copy.append(("\(name).title", placeholder.title))
            copy.append(("\(name).message", placeholder.message))
            if let actionTitle = placeholder.actionTitle {
                copy.append(("\(name).action", actionTitle))
            }
        }

        copy.append(("section.content", FlowInspectorPresentation.contentSectionTitle))
        copy.append(("content.summary", FlowInspectorPresentation.conversationRowTitle(storedBytes: 2_048)))
        for absence in [
            FlowContentAbsence.notEncrypted, .notInspected, .notInspectable, .notSaved,
        ] {
            copy.append(("content.absent.\(absence)", FlowInspectorPresentation.absenceMessage(absence)))
        }

        return copy
    }

    // MARK: - La sección del contenido descifrado

    func testAConnectionWithSavedContentOffersIt() {
        let section = FlowInspectorPresentation.contentSection(
            for: HistoryFixtures.historyFlow(tlsStatus: .inspected),
            chunks: [
                HistoryFixtures.storedChunk(id: 1, storedLength: 100),
                HistoryFixtures.storedChunk(id: 2, direction: .inbound, storedLength: 24),
            ]
        )

        XCTAssertEqual(section, .conversation(storedBytes: 124))
    }

    func testSavedContentOutranksWhatTheFlowSaysAboutItsTLS() {
        // Un cliente puede rechazar nuestro certificado **después** de haber hablado, y lo que se
        // descifró antes sigue siendo suyo.
        let section = FlowInspectorPresentation.contentSection(
            for: HistoryFixtures.historyFlow(tlsStatus: .notInspectable),
            chunks: [HistoryFixtures.storedChunk(storedLength: 40)]
        )

        XCTAssertEqual(section, .conversation(storedBytes: 40))
    }

    func testTheFourWaysOfHavingNothingAreToldApart() {
        let cases: [(TLSInspectionStatus, FlowContentAbsence)] = [
            (.plaintext, .notEncrypted),
            (.encrypted, .notInspected),
            (.notInspectable, .notInspectable),
            (.inspected, .notSaved),
        ]

        for (status, absence) in cases {
            XCTAssertEqual(
                FlowInspectorPresentation.contentSection(
                    for: HistoryFixtures.historyFlow(tlsStatus: status), chunks: []
                ),
                .absent(absence),
                "\(status) tiene su propia explicación"
            )
        }
    }

    func testPinningIsToldAsAGuaranteeAndNotAsAFailure() {
        let message = FlowInspectorPresentation.absenceMessage(.notInspectable)

        XCTAssertTrue(message.contains("stayed private"), message)
        XCTAssertTrue(message.contains("never works around"), message)
    }

    func testTheRowSaysHowMuchWasKeptAndNotHowManyTurns() {
        XCTAssertEqual(
            FlowInspectorPresentation.conversationRowTitle(storedBytes: 2_048),
            "\(DisplayFormat.bytes(2_048)) saved"
        )
    }

    /// El fallo característico de una migración al catálogo: una llamada sin `defaultValue` devuelve
    /// **la clave**, y una clave estructural se lee perfectamente en un diff sin llamar la atención.
    func testNoCopyIsARawCatalogKey() {
        for piece in everyPieceOfCopy {
            for prefix in ["flowInspector.", "packet.", "traffic.", "common."] {
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
