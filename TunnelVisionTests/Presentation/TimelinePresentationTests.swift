import Foundation
import XCTest
@testable import Shared

/// Lo que la Timeline enseña para cada instantánea, y en qué se traducen sus filtros. Son las
/// decisiones que distinguen un vacío que enseña de un vacío que miente, así que se afirman aquí y no
/// se revisan a ojo.
final class TimelinePresentationTests: XCTestCase {

    private func snapshot(
        flows: [HistoryFlow] = [],
        filter: HistoryFilter = .none,
        state: HistoryState = .loaded,
        hasMore: Bool = false
    ) -> HistorySnapshot {
        HistorySnapshot(flows: flows, filter: filter, state: state, hasMore: hasMore)
    }

    private let oneFlow = [HistoryFixtures.historyFlow()]
    private let activeFilter = HistoryFilter(searchText: "example")

    // MARK: - Cuerpo

    func testNothingLoadedYetIsLoadingAndNotAnEmptyHistory() {
        XCTAssertEqual(TimelinePresentation.content(for: snapshot(state: .idle)), .loading)
        XCTAssertEqual(TimelinePresentation.content(for: snapshot(state: .loading)), .loading)
        // No debería darse (el lector marca `loading` con la lista vacía), pero si se diera, decir
        // "no hay conexiones" sería afirmar algo que todavía no se sabe.
        XCTAssertEqual(TimelinePresentation.content(for: snapshot(state: .loadingOlder)), .loading)
    }

    func testAnEmptyHistoryWithoutFiltersTeaches() {
        guard case .placeholder(let placeholder) = TimelinePresentation.content(for: snapshot())
        else { return XCTFail("un historial vacío tiene que explicar algo") }

        XCTAssertNil(placeholder.action, "no hay nada que arreglar: aún no ha pasado tráfico")
        XCTAssertNil(placeholder.diagnostic)
        XCTAssertEqual(placeholder.role, .neutral)
        XCTAssertTrue(placeholder.message.contains("nowhere else"), "la promesa se repite aquí también")
    }

    /// El otro vacío. Sin esta distinción, un filtro selectivo diría "no hay conexiones" sobre un
    /// historial lleno, y el usuario no tendría forma de saber que la culpa era suya.
    func testAnEmptyResultWithFiltersOffersToClearThem() {
        let content = TimelinePresentation.content(for: snapshot(filter: activeFilter))
        guard case .placeholder(let placeholder) = content else {
            return XCTFail("un filtro sin resultados tiene que ofrecer salida")
        }
        XCTAssertEqual(placeholder.action, .clearFilters)
        XCTAssertEqual(placeholder.actionTitle, "Clear filters")
        XCTAssertNotEqual(placeholder.title, "No connections yet")
    }

    /// El tercer vacío, y el que faltaba: una carga se para a las `maxPagesPerLoad` páginas, así que un
    /// filtro muy selectivo puede volver vacío **con historial detrás**. Decir "no matches" ahí daba por
    /// respuesta el final de una página, que es el mismo vacío que miente contra el que existen los
    /// otros dos.
    func testAnEmptyResultWithHistoryLeftOffersToKeepLooking() {
        let content = TimelinePresentation.content(for: snapshot(filter: activeFilter, hasMore: true))
        guard case .placeholder(let placeholder) = content else {
            return XCTFail("una búsqueda a medias tiene que decir que va a medias")
        }

        XCTAssertEqual(placeholder.action, .searchFurtherBack)
        XCTAssertNotEqual(placeholder.action, .clearFilters, "quitar el filtro insinuaría que ya terminó")
        XCTAssertTrue(placeholder.title.contains("yet"), "es hasta dónde se ha buscado, no la respuesta")
        XCTAssertEqual(placeholder.role, .neutral)
    }

    /// Los dos vacíos con filtro son distintos y los separa `hasMore`. Se afirma que **no** dicen lo
    /// mismo: si un día colapsaran en una sola tarjeta, el que miente volvería sin que nada fallase.
    func testTheTwoFilteredEmptiesAreNotTheSameCard() {
        let searching = TimelinePresentation.content(for: snapshot(filter: activeFilter, hasMore: true))
        let finished = TimelinePresentation.content(for: snapshot(filter: activeFilter, hasMore: false))

        XCTAssertNotEqual(searching, finished)
        guard case .placeholder(let finishedCard) = finished else {
            return XCTFail("un historial entero recorrido sin coincidencias sigue teniendo que explicarse")
        }
        XCTAssertEqual(finishedCard.action, .clearFilters, "aquí sí se acabó: la salida es quitar el filtro")
    }

    func testAFailureWithNothingDrawnIsActionableAndKeepsItsDiagnostic() {
        let content = TimelinePresentation.content(
            for: snapshot(state: .failed(.queryFailed("database is locked")))
        )
        guard case .placeholder(let placeholder) = content else {
            return XCTFail("un fallo tiene que enseñarse")
        }
        XCTAssertEqual(placeholder.action, .retry, "un fallo sin salida es el callejón que prohíbe la UX")
        XCTAssertEqual(placeholder.role, .warning)
        XCTAssertEqual(placeholder.diagnostic, "database is locked")
        XCTAssertFalse(
            placeholder.message.contains("database is locked"),
            "la copia principal nunca es el mensaje del sistema"
        )
    }

    func testCorruptHistoryIsToldApartFromAnUnreadableOne() {
        let corrupt = TimelinePresentation.content(for: snapshot(state: .failed(.corruptData("bad blob"))))
        let unreadable = TimelinePresentation.content(for: snapshot(state: .failed(.queryFailed("io"))))
        XCTAssertNotEqual(corrupt, unreadable)
    }

    /// La regla que manda sobre todas: una lista ya pintada no se tapa. Ni por una carga en curso, ni
    /// por un filtro, ni por un fallo posterior —lo que el usuario estaba leyendo sigue siendo cierto.
    func testAnyDrawnListWinsOverEveryCard() {
        for state in [HistoryState.loading, .loadingOlder, .loaded, .failed(.queryFailed("io"))] {
            XCTAssertEqual(
                TimelinePresentation.content(for: snapshot(flows: oneFlow, filter: activeFilter, state: state)),
                .list,
                "con filas, el cuerpo es siempre la lista (estado \(state))"
            )
        }
    }

    // MARK: - Pie

    func testWithoutRowsThereIsNoFooter() {
        for state in [HistoryState.idle, .loading, .loadingOlder, .loaded, .failed(.queryFailed("io"))] {
            XCTAssertEqual(TimelinePresentation.footer(for: snapshot(state: state, hasMore: true)), .none)
        }
    }

    func testTheFooterDrivesPaginationAndAnnouncesTheEnd() {
        XCTAssertEqual(
            TimelinePresentation.footer(for: snapshot(flows: oneFlow, hasMore: true)),
            .loadMore
        )
        XCTAssertEqual(
            TimelinePresentation.footer(for: snapshot(flows: oneFlow, hasMore: false)),
            .endOfHistory
        )
        XCTAssertEqual(
            TimelinePresentation.footer(for: snapshot(flows: oneFlow, state: .loadingOlder, hasMore: true)),
            .loadingOlder
        )
    }

    /// El fallo que no tapa la lista tiene que contarse en alguna parte, o el usuario creería que el
    /// historial se acaba justo donde falló la consulta.
    func testAFailureUnderADrawnListIsReportedInTheFooter() {
        let footer = TimelinePresentation.footer(
            for: snapshot(flows: oneFlow, state: .failed(.queryFailed("io")), hasMore: true)
        )
        guard case .failed(let message) = footer else {
            return XCTFail("el fallo tiene que llegar al pie")
        }
        XCTAssertTrue(message.contains("Pull down"), "y tiene que decir cómo salir de él")
    }

    // MARK: - Filtros

    /// Lo importante no es qué agrupa cada casilla, sino que **ningún** protocolo se quede fuera de
    /// todas: una conexión invisible para cualquier filtro no existe para el usuario.
    func testEveryProtocolIsCoveredBySomeOption() {
        let covered = TimelineProtocolFilter.protocols(for: Set(TimelineProtocolFilter.allCases))
        for proto in [IPProtocolNumber.tcp, .udp, .icmp, .icmpv6, .other] {
            XCTAssertTrue(covered.contains(proto), "\(proto) no lo cubre ninguna casilla")
        }
    }

    func testAnEmptySelectionMeansEveryProtocol() {
        // Vacío es lo que `HistoryFilter` entiende por "todos": no se traduce a los cinco casos.
        XCTAssertTrue(TimelineProtocolFilter.protocols(for: []).isEmpty)
    }

    func testSelectedOptionsAddUp() {
        XCTAssertEqual(TimelineProtocolFilter.protocols(for: [.tcp]), [.tcp])
        XCTAssertEqual(TimelineProtocolFilter.protocols(for: [.tcp, .udp]), [.tcp, .udp])
        XCTAssertEqual(TimelineProtocolFilter.protocols(for: [.other]), [.icmp, .icmpv6, .other])
    }

    func testEveryProtocolHasItsOwnName() {
        let names = [IPProtocolNumber.tcp, .udp, .icmp, .icmpv6, .other].map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(IPProtocolNumber.tcp.displayName, "TCP")
    }

    // MARK: - Rangos temporales

    /// Calendario fijo en UTC: `today` depende del huso, y un test que dependiera del del portátil
    /// pasaría o fallaría según la hora a la que se ejecutase.
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testAnyTimeDoesNotBoundAnything() {
        XCTAssertNil(TimelineTimeRange.anyTime.range(now: Date(), calendar: utcCalendar))
    }

    func testTheLastHourIsTheHourBeforeTheInstantItIsAsked() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let range = TimelineTimeRange.lastHour.range(now: now, calendar: utcCalendar)
        XCTAssertEqual(range?.lowerBound, now.addingTimeInterval(-3_600))
        XCTAssertEqual(range?.upperBound, now)
    }

    /// "Hoy" es el día del usuario, no las últimas 24 horas: empieza a medianoche.
    func testTodayStartsAtMidnightAndNotTwentyFourHoursAgo() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14 22:13:20 UTC
        let range = TimelineTimeRange.today.range(now: now, calendar: utcCalendar)
        XCTAssertEqual(range?.lowerBound, utcCalendar.startOfDay(for: now))
        XCTAssertEqual(range?.upperBound, now)
        XCTAssertGreaterThan(
            range!.lowerBound,
            now.addingTimeInterval(-86_400),
            "medianoche de hoy siempre cae después de hace 24 h"
        )
    }

    func testTheLastSevenDaysGoBackSevenCalendarDays() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let range = TimelineTimeRange.last7Days.range(now: now, calendar: utcCalendar)
        XCTAssertEqual(range?.lowerBound, utcCalendar.date(byAdding: .day, value: -7, to: now))
        XCTAssertEqual(range?.upperBound, now)
    }

    /// El extremo superior nunca se va al futuro: una fila fechada por delante del reloj solo puede
    /// venir de un desfase, y darla por buena la enseñaría como reciente sin serlo.
    func testNoRangeReachesIntoTheFuture() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for range in TimelineTimeRange.allCases {
            guard let interval = range.range(now: now, calendar: utcCalendar) else { continue }
            XCTAssertEqual(interval.upperBound, now, "\(range.label) se sale al futuro")
        }
    }

    func testEveryRangeHasItsOwnLabel() {
        let labels = TimelineTimeRange.allCases.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count)
    }

    // MARK: - Preset contra tramo absoluto

    /// La razón de ser del tipo: un preset se reevalúa en cada consulta y un tramo de la barra de
    /// scrub **no**. Si el absoluto se recalculase, la selección se movería sola bajo el dedo.
    func testAPresetIsRecomputedAndAnIntervalNeverIs() {
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let later = first.addingTimeInterval(600)

        let preset = TimelineDateFilter.preset(.lastHour)
        XCTAssertNotEqual(
            preset.range(now: first, calendar: utcCalendar),
            preset.range(now: later, calendar: utcCalendar)
        )

        let chosen = first.addingTimeInterval(-7_200)...first.addingTimeInterval(-3_600)
        let interval = TimelineDateFilter.interval(chosen)
        XCTAssertEqual(interval.range(now: first, calendar: utcCalendar), chosen)
        XCTAssertEqual(interval.range(now: later, calendar: utcCalendar), chosen)
    }

    /// Con un tramo puesto no hay preset marcado: dejar "Any time" señalado diría que la lista no
    /// está acotada, y lo está.
    func testAnIntervalLeavesNoPresetSelected() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let interval = TimelineDateFilter.interval(now.addingTimeInterval(-60)...now)
        XCTAssertNil(interval.preset)
        XCTAssertEqual(interval.interval, now.addingTimeInterval(-60)...now)

        XCTAssertEqual(TimelineDateFilter.preset(.today).preset, .today)
        XCTAssertNil(TimelineDateFilter.preset(.today).interval)
    }

    func testOnlyAnyTimeIsInactive() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(TimelineDateFilter.anyTime.isActive)
        XCTAssertEqual(TimelineDateFilter.anyTime, .preset(.anyTime))
        XCTAssertTrue(TimelineDateFilter.preset(.lastHour).isActive)
        XCTAssertTrue(TimelineDateFilter.interval(now.addingTimeInterval(-60)...now).isActive)
    }

    // MARK: - La fila

    /// La fila componía dentro de SwiftUI lo que oye VoiceOver, así que el separador y el orden eran
    /// decisiones de idioma tomadas donde ningún traductor llega —y donde nadie podía afirmarlas—.
    /// Ahora se componen aquí, y lo que se afirma es que **no se pierde nada por el camino**: el
    /// estado del cifrado, qué era la conexión y las tres cifras.
    func testARowIsHeardWholeAndNotOnlyByItsHost() {
        let flow = HistoryFixtures.historyFlow(tlsStatus: .notInspectable, sni: "example.com")
        let row = TimelinePresentation.row(flow)

        XCTAssertEqual(row.accessibilityLabel, row.host, "el nombre de la fila es el host y nada más")
        XCTAssertTrue(
            row.accessibilityValue.contains(
                TLSStatusPresentation.forStatus(.notInspectable).accessibilityDescription
            ),
            "el estado del cifrado se oye entero: la etiqueta sola no dice si eso es bueno o malo"
        )
        XCTAssertTrue(row.accessibilityValue.contains(row.service))
        for figure in [row.bytesIn, row.bytesOut, row.duration] {
            XCTAssertTrue(row.accessibilityValue.contains(figure), "falta \(figure) en el valor")
        }
    }

    /// Un flujo cuyos extremos no se pudieron repartir se nombra, no se adivina: `LiveFeedAddressing`
    /// devuelve `nil` a propósito, y enseñar la IP del propio dispositivo como si fuera el otro lado
    /// sería peor que decir que no se sabe.
    func testAFlowWithoutASplitIsNamedAndNotGuessed() {
        let row = TimelinePresentation.row(HistoryFixtures.historyFlow(localAddresses: []))
        XCTAssertEqual(row.host, FlowDisplay.unknownHost)
    }

    /// El puerto es un identificador, no una cantidad, y este test es lo que impide que un día salga
    /// "65.535" —que no es un puerto y que no se podría pegar en ninguna parte—.
    ///
    /// **El caso de cuatro dígitos es el que estuvo roto**, y desde que el scheme fija el locale del
    /// bundle de tests (`CopyLocaleTests`) vuelve a ser afirmable: con el idioma de la máquina —español
    /// aquí, que no agrupa los millares de cuatro dígitos— `8080` pasaba por casualidad mientras el
    /// inglés, el único idioma que la app enseña, decía "port 8,080". Los cinco dígitos se quedan
    /// porque cuestan una línea y cubren el caso en cualquier locale que alguien fuerce por encima.
    func testThePortIsWrittenAsANumberAndNotAsAnAmount() {
        let common = TimelinePresentation.row(HistoryFixtures.historyFlow(remotePort: 8_080))
        XCTAssertTrue(common.service.contains("8080"), "el puerto salió agrupado: «\(common.service)»")

        let row = TimelinePresentation.row(HistoryFixtures.historyFlow(remotePort: 65_535))
        XCTAssertTrue(row.service.contains("65535"), "el puerto salió agrupado: «\(row.service)»")
        XCTAssertTrue(row.service.contains("TCP"), "el protocolo se nombra por su nombre de cable")
    }

    /// Un protocolo que no sabemos nombrar y el cajón del filtro dicen hoy la misma palabra y **no
    /// son la misma clave**: el del filtro incluye ICMP a propósito, el de la fila significa "no
    /// sabemos cuál". Lo que se afirma es que la fila nombra por su nombre lo que sí sabe.
    func testAKnownProtocolIsNeverFiledUnderOther() {
        for proto in [IPProtocolNumber.tcp, .udp, .icmp, .icmpv6] {
            let row = TimelinePresentation.row(HistoryFixtures.historyFlow(proto: proto))
            XCTAssertTrue(
                row.service.contains(proto.displayName),
                "\(proto) se enseña como \(row.service)"
            )
            XCTAssertNotEqual(proto.displayName, IPProtocolNumber.other.displayName)
        }
    }

    // MARK: - La copia por el catálogo (M11)

    /// Quitar los filtros se ofrece en dos sitios —el menú y el vacío que no encuentra nada— y sale
    /// de **una sola propiedad**. Compartir por coincidencia de literales es cómo una traducción
    /// mueve uno y deja el otro: la frase sigue leyéndose bien y manda tocar algo que se llama de
    /// otra manera.
    func testClearingFiltersIsOfferedWithTheSameWordsInBothPlaces() {
        let content = TimelinePresentation.content(for: snapshot(filter: activeFilter))
        guard case .placeholder(let placeholder) = content else {
            return XCTFail("un filtro sin resultados tiene que ofrecer salida")
        }
        XCTAssertEqual(placeholder.actionTitle, TimelinePresentation.clearFiltersActionTitle)
    }

    /// Toda la copia de la lista y de sus filtros, con el sitio del que sale, para poder afirmar
    /// sobre ella en bloque. Los acrónimos de protocolo **no entran**: son el nombre del protocolo
    /// en el cable, no copia nuestra, y no pasan por el catálogo.
    private var everyPieceOfCopy: [(where: String, text: String)] {
        var copy: [(where: String, text: String)] = []

        for (name, placeholder) in everyPlaceholder {
            copy.append(("\(name).title", placeholder.title))
            copy.append(("\(name).message", placeholder.message))
            if let actionTitle = placeholder.actionTitle {
                copy.append(("\(name).action", actionTitle))
            }
        }

        for status in TLSStatusPresentation.allStatuses {
            let presentation = TLSStatusPresentation.forStatus(status)
            copy.append(("tlsStatus.\(status).label", presentation.label))
            copy.append(("tlsStatus.\(status).detail", presentation.detail))
            copy.append(("tlsStatus.\(status).accessibility", presentation.accessibilityDescription))
        }

        for range in TimelineTimeRange.allCases {
            copy.append(("timeRange.\(range.rawValue)", range.label))
        }
        copy.append(("protocolFilter.other", TimelineProtocolFilter.other.label))
        copy.append(("protocol.other", IPProtocolNumber.other.displayName))

        copy.append(("screen.title", TimelinePresentation.screenTitle))
        copy.append(("screen.tab", TimelinePresentation.tabTitle))
        copy.append(("search.prompt", TimelinePresentation.searchPrompt))
        copy.append(("filters.menu", TimelinePresentation.filterMenuTitle))
        copy.append(("filters.section.time", TimelinePresentation.timeSectionTitle))
        copy.append(("filters.section.protocol", TimelinePresentation.protocolSectionTitle))
        copy.append(("filters.section.encryption", TimelinePresentation.encryptionSectionTitle))
        copy.append(("filters.clear", TimelinePresentation.clearFiltersActionTitle))
        copy.append(("footer.endOfHistory", TimelinePresentation.endOfHistoryMessage))
        copy.append(("host.unknown", FlowDisplay.unknownHost))

        if case .failed(let message) = TimelinePresentation.footer(
            for: snapshot(flows: oneFlow, state: .failed(.queryFailed("io")))
        ) {
            copy.append(("footer.olderFailed", message))
        }

        let row = TimelinePresentation.row(HistoryFixtures.historyFlow(sni: "example.com"))
        copy.append(("row.service", row.service))
        copy.append(("row.accessibilityValue", row.accessibilityValue))

        return copy
    }

    /// Los cinco huecos que la pantalla puede enseñar, con su nombre.
    private var everyPlaceholder: [(String, TimelinePlaceholder)] {
        var placeholders: [(String, TimelinePlaceholder)] = [
            ("connectionUnavailable", TimelinePresentation.connectionUnavailable)
        ]
        let snapshots: [(String, HistorySnapshot)] = [
            ("noHistoryYet", snapshot()),
            ("noMatches", snapshot(filter: activeFilter)),
            ("noMatchesYet", snapshot(filter: activeFilter, hasMore: true)),
            ("queryFailed", snapshot(state: .failed(.queryFailed("io")))),
            ("corruptData", snapshot(state: .failed(.corruptData("bad blob")))),
        ]
        for (name, snapshot) in snapshots {
            guard case .placeholder(let placeholder) = TimelinePresentation.content(for: snapshot)
            else { continue }
            placeholders.append((name, placeholder))
        }
        return placeholders
    }

    /// El fallo característico de una migración al catálogo: una llamada sin `defaultValue` devuelve
    /// **la clave**, y una clave estructural se lee perfectamente en un diff sin llamar la atención.
    func testNoCopyIsARawCatalogKey() {
        for piece in everyPieceOfCopy {
            for prefix in ["timeline.", "flow.", "traffic."] {
                XCTAssertFalse(piece.text.hasPrefix(prefix), "\(piece.where): \(piece.text)")
            }
            XCTAssertFalse(piece.text.isEmpty, "\(piece.where) se quedó sin copia")
        }
    }

    /// El otro fallo característico, y el que ningún test de contenido ve: al mudar un literal
    /// multilínea cambia dónde caen las continuaciones (`\`), y una mal puesta mete un espacio doble
    /// o deja un sobrante en un extremo. El texto sigue diciendo lo mismo y se ve mal.
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
