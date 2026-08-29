import Foundation
import Shared
import XCTest

/// La copia de la Dashboard: los dos vacíos, la señal de back-pressure, lo que se oye del gráfico y
/// lo que dice una fila de host.
///
/// Desde M11 esta copia sale del código por el catálogo de cadenas, y estas afirmaciones siguen
/// significando lo mismo por lo que dice `docs/development/02-coding-standards.md`: el bundle de
/// tests no lleva catálogo, así que toda búsqueda cae al `defaultValue` escrito en el Swift de al
/// lado — el mismo texto que la app enseña mientras no haya traducciones.
final class DashboardPresentationTests: XCTestCase {

    private func talker(
        bytesIn: UInt64 = 2_000,
        bytesOut: UInt64 = 1_000,
        flowCount: Int = 3
    ) -> TopTalker {
        TopTalker(
            address: IPAddress(version: .v4, bytes: [93, 184, 216, 34]),
            bytesIn: bytesIn,
            bytesOut: bytesOut,
            packetCount: 12,
            flowCount: flowCount
        )
    }

    // MARK: - Los dos vacíos

    /// La regla que separa el vacío honesto del que miente: sin feed enganchado la app **espera** a
    /// que la extensión arranque, y con feed y sin paquetes es que de verdad no ha pasado tráfico.
    /// Decir lo segundo cuando pasa lo primero afirmaría algo que nadie ha medido.
    func testTheTwoEmptyStatesAreToldApartAndNeitherClaimsWhatItCannotKnow() {
        let waiting = DashboardPresentation.talkersEmptyState(isAttached: false)
        let listening = DashboardPresentation.talkersEmptyState(isAttached: true)

        XCTAssertNotEqual(waiting, listening)
        XCTAssertNotEqual(waiting.title, listening.title)
        XCTAssertNotEqual(waiting.message, listening.message)
        XCTAssertNotEqual(waiting.systemImage, listening.systemImage)

        // Sin haber mirado nunca el tráfico no se puede afirmar que no lo haya habido.
        XCTAssertFalse(waiting.title.contains("No traffic"))
        XCTAssertEqual(listening.title, "No traffic yet")
    }

    /// El vacío que se enseña antes de encender nombra lo que lo llena, que es el botón que está
    /// arriba de esa misma pantalla: un hueco que no dice qué hacer es el que deja parado al usuario.
    func testTheEmptyStateBeforeMonitoringNamesWhatFillsIt() {
        let waiting = DashboardPresentation.talkersEmptyState(isAttached: false)
        XCTAssertTrue(waiting.message.contains("Start monitoring"))
        XCTAssertFalse(waiting.title.isEmpty)
    }

    // MARK: - Back-pressure

    /// Lo que hace honesta a la señal no es decir que se perdieron registros, sino decir qué **no**
    /// se perdió: los contadores los lleva la extensión antes del ring, así que siguen siendo
    /// exactos. Sin esa frase, la señal solo siembra la duda de si todo lo demás también miente.
    func testTheBackPressureNoticeSaysWhatWasNotLost() {
        let notice = DashboardPresentation.droppedRecordsNotice(12)
        XCTAssertTrue(notice.contains("counters stay accurate"))
        XCTAssertTrue(notice.contains("12"))
    }

    /// La cifra va formateada como en el resto de la app: dos formatos distintos para el mismo tipo
    /// de número harían leer dos pantallas como si contaran cosas distintas.
    func testTheBackPressureNoticeCountsLikeEverywhereElse() {
        XCTAssertTrue(DashboardPresentation.droppedRecordsNotice(1_204).contains("1,204"))
        XCTAssertEqual(
            DashboardPresentation.droppedRecordsNotice(1_204).contains("1204"),
            false,
            "la cifra tiene que llevar el separador de millares de DisplayFormat"
        )
    }

    // MARK: - El gráfico

    /// VoiceOver anuncia el dato y la ventana, nunca el chisme: "gráfico" no le sirve de nada a quien
    /// no lo ve, y es justo lo único que no puede leer por sí mismo.
    func testTheChartIsAnnouncedByItsDataAndNotByBeingAChart() {
        let label = DashboardPresentation.chartAccessibilityLabel.lowercased()
        XCTAssertFalse(label.contains("chart"))
        XCTAssertFalse(label.contains("graph"))
        XCTAssertTrue(label.contains("traffic"))
    }

    /// Las dos tasas se oyen en el mismo orden en que se ven, y con el mismo formato: recibido
    /// primero, enviado después. El orden lo decide el núcleo puro y no la vista porque en otro
    /// idioma puede no ser ese.
    func testTheChartValueReadsBothRatesInTheOrderTheyAreDrawn() {
        let value = DashboardPresentation.chartAccessibilityValue(rateIn: 2_000, rateOut: 500)
        guard
            let inbound = value.range(of: DisplayFormat.rate(bytesPerSecond: 2_000)),
            let outbound = value.range(of: DisplayFormat.rate(bytesPerSecond: 500))
        else {
            return XCTFail("el valor debería llevar las dos tasas: \(value)")
        }
        XCTAssertTrue(inbound.lowerBound < outbound.lowerBound, "la tasa de entrada se dice primero")
    }

    /// Un gráfico parado se anuncia con ceros y no callándose: el silencio se confunde con un fallo.
    func testAnIdleChartStillHasAValue() {
        let value = DashboardPresentation.chartAccessibilityValue(rateIn: 0, rateOut: 0)
        XCTAssertFalse(value.isEmpty)
        XCTAssertTrue(value.contains("0 B/s"))
    }

    // MARK: - Las filas de host

    /// La fila se nombra por el host y **solo** por el host: las cifras son su valor y se leen
    /// después, así que meterlas también en el nombre haría que VoiceOver las dijera dos veces.
    func testAHostRowIsNamedByItsHostAndNothingElse() {
        let presentation = DashboardPresentation.topTalker(talker())
        XCTAssertEqual(presentation.accessibilityLabel, presentation.host)
        XCTAssertFalse(presentation.accessibilityLabel.contains(presentation.bytesIn))
        XCTAssertFalse(presentation.accessibilityLabel.contains(presentation.connections))
    }

    /// Los tres datos de la fila se oyen en una sola frase, compuesta aquí y no en SwiftUI: los
    /// separadores y el orden son propiedades del idioma y un traductor no llega a una vista.
    func testAHostRowIsHeardAsOneSentenceWithItsThreeNumbers() {
        let presentation = DashboardPresentation.topTalker(talker(bytesIn: 2_000, bytesOut: 1_000, flowCount: 3))
        XCTAssertTrue(presentation.accessibilityValue.contains(presentation.connections))
        XCTAssertTrue(presentation.accessibilityValue.contains(presentation.bytesIn))
        XCTAssertTrue(presentation.accessibilityValue.contains(presentation.bytesOut))
        XCTAssertEqual(presentation.bytesIn, "2 KB")
        XCTAssertEqual(presentation.bytesOut, "1 KB")
    }

    /// El host no se traduce ni se compone: es una dirección, y pasarla por el mismo sitio que la
    /// copia sería invitar a que algún día se "adapte".
    func testTheHostIsTheAddressItself() {
        let talker = talker()
        XCTAssertEqual(DashboardPresentation.topTalker(talker).host, talker.displayHost)
    }

    // MARK: - El plural

    /// Una conexión se dice en singular. Es la mitad del plural hecho a mano que documenta
    /// `DashboardPresentation.connectionsSummary`.
    func testOneConnectionIsSaidInTheSingular() {
        XCTAssertEqual(DashboardPresentation.topTalker(talker(flowCount: 1)).connections, "1 connection")
    }

    /// Cualquier otra cantidad va en plural, el cero incluido: "0 connection" sería un error de
    /// idioma en la única fila donde nadie lo miraría dos veces.
    func testAnyOtherCountIsSaidInThePlural() {
        XCTAssertEqual(DashboardPresentation.topTalker(talker(flowCount: 0)).connections, "0 connections")
        XCTAssertEqual(DashboardPresentation.topTalker(talker(flowCount: 2)).connections, "2 connections")
        XCTAssertEqual(DashboardPresentation.topTalker(talker(flowCount: 1_204)).connections, "1,204 connections")
    }

    /// El guardián de la decisión medida: la concordancia gramatical automática de Foundation
    /// (`^[…](inflect: true)`) **no se resuelve sin catálogo**, y el bundle de tests no lo lleva — el
    /// marcado saldría crudo a la pantalla en el mismo caso en que estos tests seguirían pasando por
    /// otra razón. Si alguien "mejora" el plural con ese marcado, esto se entera.
    func testTheConnectionCountNeverLeaksLocalizationMarkup() {
        for count in [0, 1, 2, 1_204] {
            let connections = DashboardPresentation.topTalker(talker(flowCount: count)).connections
            XCTAssertFalse(connections.contains("^["), "\(count): marcado de concordancia sin resolver")
            XCTAssertFalse(connections.contains("inflect"), "\(count): marcado de concordancia sin resolver")
        }
    }

    // MARK: - Los rótulos de la pantalla

    /// El título y el rótulo de la pestaña son dos claves distintas —la pestaña comparte ancho con
    /// otras tres y un idioma puede necesitar acortar ahí—, pero mientras nadie traduzca dicen lo
    /// mismo: la pantalla tiene un solo nombre.
    func testTheScreenHasOneNameInBothPlaces() {
        XCTAssertFalse(DashboardPresentation.screenTitle.isEmpty)
        XCTAssertEqual(DashboardPresentation.tabTitle, DashboardPresentation.screenTitle)
    }

    /// Las tres fichas de contadores se nombran una sola vez en toda la app: las dos de sentido las
    /// pone `DirectionLabel`, que es la misma palabra que usan el gráfico, las filas de host y la
    /// lista de paquetes de otra pantalla.
    func testTheCountersAreNamedOnceForTheWholeApp() {
        XCTAssertEqual(DashboardPresentation.packetsCounterLabel, "Packets")
        XCTAssertEqual(DirectionLabel.inbound, "Received")
        XCTAssertEqual(DirectionLabel.outbound, "Sent")
        XCTAssertEqual(DirectionLabel.of(.inbound), DirectionLabel.inbound)
        XCTAssertEqual(DirectionLabel.of(.outbound), DirectionLabel.outbound)
    }

    /// Los dos grupos de datos de la pantalla hablan de **periodos distintos** —lo acumulado de la
    /// sesión y lo que se mueve ahora mismo— y por eso los dos llevan rótulo. Que digan cosas
    /// distintas es lo que impide que la Dashboard enseñe dos veces *Received* y *Sent* sin decir cuál
    /// es la tasa y cuál el total.
    func testTheTwoDataGroupsAreNamedAndNameDifferentPeriods() {
        XCTAssertEqual(DashboardPresentation.countersTitle, "This session")
        XCTAssertFalse(DashboardPresentation.countersTitle.hasPrefix("dashboard."))
        XCTAssertNotEqual(DashboardPresentation.countersTitle, DashboardPresentation.talkersTitle)
    }
}
