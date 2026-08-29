import Foundation
import XCTest

/// El recorrido del intro sin vista (M11). Lo que se afirma aquí es lo que un usuario de VoiceOver
/// puede **hacer** con las tres tarjetas: moverse por ellas en las dos direcciones y plantarse en la
/// última, que es la que pide encender. Antes de esto solo había *Continue* (una tarjeta cada vez) y
/// *Skip* (que se va del intro sin ofrecer el arranque), así que ninguna de las dos cosas existía.
final class IntroAccessibilityTests: XCTestCase {

    private let first = IntroCard.whatItDoes
    private let middle = IntroCard.howItWorks
    private let last = IntroCard.yourPrivacy

    // MARK: - Recorrer el mazo

    func testMovingWalksTheSeriesOneCardAtATime() {
        XCTAssertEqual(IntroAccessibility.moved(first, by: 1), middle)
        XCTAssertEqual(IntroAccessibility.moved(middle, by: 1), last)
        XCTAssertEqual(IntroAccessibility.moved(last, by: -1), middle)
        XCTAssertEqual(IntroAccessibility.moved(middle, by: -1), first)
    }

    /// Acotado y no circular. El intro se anuncia como "3 de 3": devolver al principio al siguiente
    /// deslizamiento desmentiría lo que se acaba de decir, y dejaría un mazo del que no se sale
    /// avanzando.
    func testMovingStopsAtBothEndsInsteadOfWrappingAround() {
        XCTAssertEqual(IntroAccessibility.moved(last, by: 1), last)
        XCTAssertEqual(IntroAccessibility.moved(first, by: -1), first)
        XCTAssertEqual(IntroAccessibility.moved(last, by: 99), last)
        XCTAssertEqual(IntroAccessibility.moved(first, by: -99), first)
    }

    func testMovingNowhereStaysPut() {
        for card in IntroPresentation.cards {
            XCTAssertEqual(IntroAccessibility.moved(card, by: 0), card)
        }
    }

    /// Ir y volver deja donde se estaba siempre que haya sitio hacia donde ir. Sin esto, un redondeo o
    /// un acotado mal puesto se llevaría al usuario a una tarjeta que no pidió y que además no sabría
    /// que ha cambiado, porque lo único que se lee es la tarjeta nueva.
    func testMovingForwardAndBackIsAWashInsideTheSeries() {
        for card in IntroPresentation.cards where IntroPresentation.card(after: card) != nil {
            XCTAssertEqual(IntroAccessibility.moved(IntroAccessibility.moved(card, by: 1), by: -1), card)
        }
    }

    // MARK: - Ir al final

    /// El hueco que este incremento existe para tapar: desde la primera tarjeta se llega al arranque
    /// de una vez, sin leerse las tres.
    func testTheFirstCardCanJumpStraightToTheEnd() {
        XCTAssertTrue(IntroAccessibility.actions(for: first).contains(.lastCard))
        XCTAssertEqual(IntroAccessibility.destination(of: .lastCard, from: first), last)
    }

    /// Y el final vale la pena porque es donde está la decisión: si la última tarjeta dejara de ser la
    /// que pide encender, el salto perdería su razón de ser y este test lo diría.
    func testTheEndOfTheSeriesIsWhereTheStartIsOffered() {
        XCTAssertEqual(IntroPresentation.lastCard, last)
        XCTAssertEqual(IntroPresentation.forCard(last).action, .startMonitoring)
    }

    /// Desde la penúltima, "ir al final" y *Continue* llevan al mismo sitio. Ofrecer las dos sería un
    /// nombre más que recorrer en el rotor a cambio de nada.
    func testTheJumpIsNotOfferedWhereContinueAlreadyGoesThere() {
        XCTAssertEqual(IntroPresentation.card(after: middle), IntroPresentation.lastCard)
        XCTAssertFalse(IntroAccessibility.actions(for: middle).contains(.lastCard))
    }

    func testTheLastCardDoesNotOfferToGoToItself() {
        XCTAssertFalse(IntroAccessibility.actions(for: last).contains(.lastCard))
        XCTAssertNil(IntroAccessibility.destination(of: .lastCard, from: last))
    }

    // MARK: - Volver

    /// Volver solo se ofrece donde hay algo detrás. Es la otra mitad de lo que faltaba: ningún botón de
    /// la pantalla retrocede, así que sin esto una tarjeta que se quiso releer no se recuperaba.
    func testGoingBackIsOfferedOnlyWhereThereIsSomethingBehind() {
        XCTAssertFalse(IntroAccessibility.actions(for: first).contains(.previousCard))
        XCTAssertTrue(IntroAccessibility.actions(for: middle).contains(.previousCard))
        XCTAssertTrue(IntroAccessibility.actions(for: last).contains(.previousCard))

        XCTAssertNil(IntroAccessibility.destination(of: .previousCard, from: first))
        XCTAssertEqual(IntroAccessibility.destination(of: .previousCard, from: middle), first)
        XCTAssertEqual(IntroAccessibility.destination(of: .previousCard, from: last), middle)
    }

    // MARK: - Lo que se ofrece, en conjunto

    /// La invariante que hace que ninguna acción mienta: todo lo que se ofrece lleva a alguna parte, y
    /// esa parte nunca es la tarjeta en la que ya se está. Una acción que no hace nada es peor que no
    /// ofrecerla, porque quien la activa no ve que no ha pasado nada.
    func testEveryOfferedActionLeadsSomewhereElse() {
        for card in IntroPresentation.cards {
            for action in IntroAccessibility.actions(for: card) {
                let destination = IntroAccessibility.destination(of: action, from: card)
                XCTAssertNotNil(destination, "\(action) desde \(card) no lleva a ninguna parte")
                XCTAssertNotEqual(destination, card, "\(action) desde \(card) no se mueve")
            }
        }
    }

    /// Y la simétrica: nada que no se ofrezca se puede aplicar por la puerta de atrás.
    func testAnActionThatIsNotOfferedHasNowhereToGo() {
        for card in IntroPresentation.cards {
            let offered = IntroAccessibility.actions(for: card)
            for action in IntroCardAction.allCases where !offered.contains(action) {
                // La única que se puede no ofrecer teniendo destino es el salto desde la penúltima, y
                // ahí se calla porque *Continue* ya lleva al mismo sitio.
                if action == .lastCard && card == middle { continue }
                XCTAssertNil(
                    IntroAccessibility.destination(of: action, from: card),
                    "\(action) no se ofrece desde \(card) pero llevaría a alguna parte"
                )
            }
        }
    }

    func testEveryActionIsNamedAndNoTwoAreNamedAlike() {
        let labels = IntroCardAction.allCases.map(\.label)
        for label in labels {
            XCTAssertFalse(label.isEmpty)
        }
        XCTAssertEqual(Set(labels).count, labels.count)
    }

    /// Ninguna acción se llama como la salida. *Skip* es el botón que **termina** el intro sin encender
    /// nada; llamar igual a un movimiento dentro del mazo haría creer que se está saliendo —o al revés,
    /// que salir es solo adelantar— y eso es una decisión de consentimiento, no de copia.
    func testNoActionBorrowsTheNameOfTheWayOut() {
        let exits = IntroPresentation.cards.map { IntroPresentation.forCard($0).skipTitle }
        for action in IntroCardAction.allCases {
            for exit in exits {
                XCTAssertFalse(
                    action.label.localizedCaseInsensitiveContains(exit),
                    "\(action) se llama como la salida (\(exit))"
                )
            }
        }
    }

    // MARK: - La pista

    /// El sistema anuncia que el elemento se ajusta, pero no qué significa ajustarlo. Sin esta frase,
    /// "paso 2 de 3" no se lee como algo que se pueda mover.
    func testTheDeckSaysHowToMoveThroughIt() throws {
        let hint = try XCTUnwrap(IntroAccessibility.deckHint)
        XCTAssertTrue(hint.localizedCaseInsensitiveContains("step"))
        XCTAssertTrue(hint.localizedCaseInsensitiveContains("swipe"))
    }

    /// La pista se deriva de la serie: hoy hay tres tarjetas, y por eso la hay.
    func testTheHintExistsBecauseThereIsSomewhereToMove() {
        XCTAssertGreaterThan(IntroPresentation.cards.count, 1)
    }

    // MARK: - Lo que se lee de una tarjeta

    /// La tarjeta se oye entera y en el orden en que se lee: primero el titular, después la explicación.
    /// Se compone en el núcleo y no en la vista porque el separador y el orden son idioma.
    func testTheCardIsReadAsItsHeadlineAndThenItsExplanation() {
        for card in IntroPresentation.cards {
            let presentation = IntroPresentation.forCard(card)
            let label = IntroAccessibility.cardLabel(for: presentation)
            XCTAssertTrue(label.hasPrefix(presentation.title), "\(card) no empieza por su titular")
            XCTAssertTrue(label.contains(presentation.message), "\(card) no dice su explicación")
        }
    }

    /// El sitio en la serie se dice con los dos números, que es lo que deja saber cuánto queda. Un intro
    /// del que no se sabe cuánto queda es el que se abandona.
    func testTheCardSaysWhereItIsInTheSeries() {
        XCTAssertEqual(IntroAccessibility.stepValue(for: IntroPresentation.forCard(first)), "Step 1 of 3")
        XCTAssertEqual(IntroAccessibility.stepValue(for: IntroPresentation.forCard(middle)), "Step 2 of 3")
        XCTAssertEqual(IntroAccessibility.stepValue(for: IntroPresentation.forCard(last)), "Step 3 of 3")
    }

    /// El valor no repite el contenido: es lo único del elemento que cambia al recorrer el mazo, y
    /// meterle el titular haría que VoiceOver lo dijera dos veces en cada paso.
    func testWhereItIsDoesNotRepeatWhatItSays() {
        for card in IntroPresentation.cards {
            let presentation = IntroPresentation.forCard(card)
            let value = IntroAccessibility.stepValue(for: presentation)
            XCTAssertFalse(value.contains(presentation.title), "\(card) repite el titular en el valor")
            XCTAssertFalse(value.contains(presentation.message))
        }
    }

    /// La identidad de una acción es el caso y no su rótulo, que desde M11 es copia traducible: una
    /// lista identificada por el texto cambiaría de identidad al cambiar de idioma, y el `ForEach` de la
    /// vista reconstruiría botones que no se han movido.
    func testAnActionIsIdentifiedByWhatItIsAndNotByWhatItSays() {
        for action in IntroCardAction.allCases {
            XCTAssertFalse(action.id.isEmpty)
            XCTAssertNotEqual(action.id, action.label)
        }
        let ids = IntroCardAction.allCases.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}
