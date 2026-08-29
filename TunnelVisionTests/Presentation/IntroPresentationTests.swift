import Foundation
import XCTest

/// El núcleo puro del intro de la primera ejecución (M10). Lo que se afirma aquí son reglas de
/// consentimiento con consecuencias reales —una tarjeta con un solo botón, una última tarjeta que no
/// dice lo que va a hacer, una serie que no dice cuánto queda—, así que se prueban y no se miran a
/// ojo en el Simulator.
final class IntroPresentationTests: XCTestCase {

    private var all: [IntroPresentation] {
        IntroPresentation.cards.map(IntroPresentation.forCard)
    }

    // MARK: - La serie

    /// El orden es el de la spec y no un detalle: cada tarjeta prepara la siguiente, y la tercera
    /// prepara el diálogo del sistema que viene después de ella.
    func testTheCardsAreTheThreeOfTheSpecInOrder() {
        XCTAssertEqual(IntroPresentation.cards, [.whatItDoes, .howItWorks, .yourPrivacy])
    }

    func testEachCardKnowsItsPlaceInTheSeries() {
        for (index, presentation) in all.enumerated() {
            XCTAssertEqual(presentation.step, index + 1)
            XCTAssertEqual(presentation.stepCount, 3)
        }
        XCTAssertEqual(all.map(\.isLast), [false, false, true])
    }

    func testNavigationEndsAtTheLastCardInsteadOfWrappingAround() {
        XCTAssertEqual(IntroPresentation.card(after: .whatItDoes), .howItWorks)
        XCTAssertEqual(IntroPresentation.card(after: .howItWorks), .yourPrivacy)
        // Volver a la primera dejaría un intro del que no se sale avanzando.
        XCTAssertNil(IntroPresentation.card(after: .yourPrivacy))
    }

    /// La simétrica, que es la que sostiene el recorrido hacia atrás sin vista (`IntroAccessibility`):
    /// ningún botón de la pantalla retrocede, así que quien decide dónde se acaba la serie por detrás
    /// es esta función y nadie más.
    func testNavigationBackwardsEndsAtTheFirstCard() {
        XCTAssertEqual(IntroPresentation.card(before: .yourPrivacy), .howItWorks)
        XCTAssertEqual(IntroPresentation.card(before: .howItWorks), .whatItDoes)
        XCTAssertNil(IntroPresentation.card(before: .whatItDoes))
    }

    /// La última es la que pide encender: es el destino del salto al final, y lo que hace que ese salto
    /// valga la pena ofrecerlo.
    func testTheLastCardOfTheSeriesIsTheOneThatAsksToStart() {
        XCTAssertEqual(IntroPresentation.lastCard, .yourPrivacy)
        XCTAssertEqual(IntroPresentation.lastCard.map(IntroPresentation.forCard)?.action, .startMonitoring)
    }

    // MARK: - Las dos salidas de cada tarjeta

    /// La regla dura de `docs/ux/onboarding-and-consent.md`: siempre hay un camino para no hacerlo, y
    /// nunca un solo botón. También en la última, donde el primario ya no es "seguir leyendo".
    func testEveryCardOffersAWayOut() {
        for presentation in all {
            XCTAssertFalse(presentation.skipTitle.isEmpty, "\(presentation.card) se quedó sin salida")
            XCTAssertFalse(presentation.actionTitle.isEmpty)
        }
    }

    /// Las dos salidas no se llaman igual porque no significan lo mismo: en las primeras se salta lo
    /// que queda, en la última se decide no encender todavía. Llamar *Skip* a la segunda haría creer
    /// que hay más tarjetas detrás.
    func testTheWayOutIsNamedForWhatItActuallySkips() {
        XCTAssertEqual(IntroPresentation.forCard(.whatItDoes).skipTitle, "Skip")
        XCTAssertEqual(IntroPresentation.forCard(.howItWorks).skipTitle, "Skip")
        XCTAssertEqual(IntroPresentation.forCard(.yourPrivacy).skipTitle, "Not now")
    }

    /// Solo la última pide encender, y lo dice con esas palabras. Un *Done* dejaría al usuario en la
    /// Dashboard sin saber que lo que acaba de pulsar era el arranque.
    func testOnlyTheLastCardAsksToStartAndSaysSo() {
        XCTAssertEqual(all.map(\.action), [.next, .next, .startMonitoring])
        XCTAssertEqual(IntroPresentation.forCard(.yourPrivacy).actionTitle, "Start monitoring")
        for presentation in all where !presentation.isLast {
            XCTAssertEqual(presentation.actionTitle, "Continue")
        }
    }

    // MARK: - La copia

    func testEveryCardHasCopyAndASymbol() {
        for presentation in all {
            XCTAssertFalse(presentation.title.isEmpty, "\(presentation.card) sin titular")
            XCTAssertFalse(presentation.message.isEmpty, "\(presentation.card) sin explicación")
            XCTAssertFalse(presentation.systemImage.isEmpty, "\(presentation.card) sin símbolo")
        }
    }

    /// La expectativa del icono de VPN se pone **antes** del diálogo del sistema, no después. Es la
    /// razón de ser de la segunda tarjeta: sin ella, el icono aparece en la barra de estado sin que
    /// nadie lo haya nombrado.
    func testTheVPNAndItsIconAreNamedBeforeAnySystemPrompt() {
        let howItWorks = IntroPresentation.forCard(.howItWorks)
        XCTAssertTrue(howItWorks.message.contains("VPN"))
        XCTAssertTrue(howItWorks.message.contains("icon"))
    }

    /// La promesa que sostiene el producto entero, dicha con todas las letras y no insinuada.
    func testThePrivacyCardPromisesNothingLeavesTheDevice() {
        let privacy = IntroPresentation.forCard(.yourPrivacy)
        XCTAssertTrue(privacy.message.contains("No account"))
        XCTAssertTrue(privacy.message.contains("Nothing is uploaded"))
        XCTAssertTrue(privacy.message.contains("stop monitoring at any time"))
    }

    /// Ninguna tarjeta habla el idioma de las specs (principio 3 de `docs/ux/00-ux-principles.md`).
    func testTheCopyUsesNoJargon() {
        let jargon = ["5-tuple", "MITM", "reassembly", "packet tunnel", "NEPacketTunnelProvider", "TLS"]
        for presentation in all {
            for word in jargon {
                XCTAssertFalse(
                    presentation.message.localizedCaseInsensitiveContains(word),
                    "\(presentation.card) usa jerga: \(word)"
                )
                XCTAssertFalse(presentation.title.localizedCaseInsensitiveContains(word))
            }
        }
    }
}
