import Foundation

/// El recorrido del intro de la primera ejecución para quien no ve las tarjetas.
///
/// La serie se maneja con dos cosas que dan por supuesta la vista: **deslizar** el mazo de una tarjeta
/// a otra y **mirar los puntos** para saber cuántas quedan. Los puntos ya están contados en voz alta
/// desde M10 (`Step 2 of 3`), pero el deslizamiento no: con VoiceOver la tarjeta es un solo elemento y
/// el gesto de página no es el mismo gesto, así que de la navegación del intro solo sobrevivía lo que
/// hay en botones — *Continue*, que avanza de una en una, y *Skip*, que **se va del intro**.
///
/// Eso deja dos huecos, y ninguno es de adorno:
///
/// 1. **No se puede volver.** Ningún botón de la pantalla retrocede; una tarjeta que se quiso releer
///    solo se recuperaba deslizando.
/// 2. **No se puede ir al final.** La última tarjeta es la que pide encender, y la única forma de
///    llegar era leerse las tres enteras. La spec promete un intro *saltable*
///    (`docs/ux/onboarding-and-consent.md`), y el único salto que había se llevaba al usuario fuera
///    **sin** ofrecerle nunca el arranque — que es justo lo que un intro saltable no debería costar.
///
/// Lo que falta, entonces, es lo mismo que le faltaba al eje de la Timeline: que el elemento se pueda
/// **recorrer** (`accessibilityAdjustableAction`) y que lo que el dedo hace de un vistazo tenga un
/// nombre (`accessibilityActions`). Y como allí, la decisión de qué se ofrece es puro producto y vive
/// aquí, no en la vista: lo que VoiceOver puede hacer y lo que un dedo puede hacer no pueden separarse.
public enum IntroCardAction: String, Sendable, Equatable, Identifiable, CaseIterable {

    /// Volver a la tarjeta anterior. No la ofrece la primera.
    case previousCard

    /// Ir a la última tarjeta, que es donde está el arranque.
    case lastCard

    /// La identidad es el caso y **no su rótulo**: desde M11 el rótulo es copia traducible, así que
    /// una lista identificada por él cambiaría de identidad al cambiar de idioma —dos acciones
    /// distintas podrían incluso coincidir en una traducción descuidada— y `ForEach` reconstruiría
    /// botones que no han cambiado de sitio. Lo que se enseña se traduce; lo que identifica, no.
    public var id: String { rawValue }

    /// Lo que se lee de la acción.
    ///
    /// La de ir al final **no se llama *Skip*** a propósito, aunque sea lo que hace un vidente cuando
    /// se salta la explicación: *Skip* es el nombre del botón que **termina** el intro, y dos cosas
    /// llamadas igual —una que se mueve dentro y otra que se va— es exactamente la confusión que este
    /// recorrido existe para quitar. Se nombra por su destino y no por lo que ahorra.
    public var label: String {
        switch self {
        case .previousCard:
            String(
                localized: "intro.cardAction.previousCard",
                defaultValue: "Go back to the previous step",
                comment: """
                    VoiceOver action on an intro card: go back one card. Named after where it \
                    goes, not after what it saves.
                    """
            )
        case .lastCard:
            String(
                localized: "intro.cardAction.lastCard",
                defaultValue: "Go to the last step",
                comment: """
                    VoiceOver action on an intro card: jump to the last card, which is the \
                    one that asks to start. It must NOT be translated as 'Skip': that word \
                    names the button that leaves the intro, and this one stays inside it.
                    """
            )
        }
    }
}

public enum IntroAccessibility {

    /// Mueve la tarjeta `steps` sitios dentro de la serie, acotada a los extremos.
    ///
    /// Se acota y **no da la vuelta**, por lo mismo que el eje de la Timeline y con una razón de más:
    /// el intro se anuncia como "3 de 3", así que decir que se ha llegado al final y devolver al
    /// principio al siguiente deslizamiento sería desmentirse solo. Una tarjeta que no está en la serie
    /// se queda donde está — no hay ningún sitio desde el que contar.
    public static func moved(_ card: IntroCard, by steps: Int) -> IntroCard {
        let cards = IntroPresentation.cards
        guard let index = cards.firstIndex(of: card), !cards.isEmpty else { return card }
        return cards[min(max(index + steps, 0), cards.count - 1)]
    }

    /// Las acciones con nombre que tiene sentido ofrecer desde una tarjeta.
    ///
    /// Avanzar **no está** entre ellas: el botón primario de la tarjeta ya es "la siguiente", y ponerle
    /// un segundo nombre alargaría el rotor sin añadir nada que hacer. Por lo mismo, ir al final solo
    /// se ofrece cuando el final no es ya la siguiente tarjeta — desde la penúltima, *Continue* lleva
    /// exactamente al mismo sitio.
    public static func actions(for card: IntroCard) -> [IntroCardAction] {
        var actions: [IntroCardAction] = []
        if IntroPresentation.card(before: card) != nil {
            actions.append(.previousCard)
        }
        if let last = IntroPresentation.lastCard,
           last != card,
           last != IntroPresentation.card(after: card) {
            actions.append(.lastCard)
        }
        return actions
    }

    /// A qué tarjeta lleva una acción, o `nil` si desde esta no lleva a ninguna parte.
    ///
    /// Es una función y no un valor guardado en el propio `IntroCardAction` porque adónde se va depende
    /// de dónde se está, y un caso de enum que ya supiera su destino obligaría a construir uno distinto
    /// por tarjeta para decir lo mismo.
    public static func destination(of action: IntroCardAction, from card: IntroCard) -> IntroCard? {
        switch action {
        case .previousCard:
            return IntroPresentation.card(before: card)
        case .lastCard:
            guard let last = IntroPresentation.lastCard, last != card else { return nil }
            return last
        }
    }

    /// Lo que hay que decir para que recorrer el mazo se pueda descubrir: el sistema anuncia que el
    /// elemento se ajusta, pero no qué significa ajustarlo, y "paso 2 de 3" no se lee como algo que se
    /// pueda mover.
    ///
    /// Es `nil` si no hay adónde moverse. Se deriva de la serie en vez de darse por hecho: un intro de
    /// una sola tarjeta prometería un recorrido que no existe.
    public static var deckHint: String? {
        guard IntroPresentation.cards.count > 1 else { return nil }
        return String(
            localized: "intro.deck.hint",
            defaultValue: "Swipe up or down to move between steps.",
            comment: """
                VoiceOver hint on an intro card. 'Swipe up or down' is the system's own gesture for \
                an adjustable element, so it must match whatever iOS calls it in this language.
                """
        )
    }

    // MARK: - Lo que se lee de una tarjeta

    /// Todo lo que la tarjeta dice, en una sola frase.
    ///
    /// Vive aquí y no en la vista desde M11 por dos razones que van juntas. La primera es la de siempre:
    /// la vista no decide copia. La segunda es que **el orden y el separador son idioma**: unir titular
    /// y explicación con un punto es una decisión del inglés, y una traducción que necesite otra cosa
    /// —otro signo, otro orden— no tendría dónde decirlo si la frase se compusiera con una interpolación
    /// dentro de la vista. Aquí es una cadena con dos huecos, que es justo lo que un traductor mueve.
    public static func cardLabel(for presentation: IntroPresentation) -> String {
        String(
            localized: "intro.card.accessibilityLabel",
            defaultValue: "\(presentation.title). \(presentation.message)",
            comment: """
                VoiceOver label of an intro card: its headline, then its explanation. The first \
                placeholder is the headline and the second is the body; separator and order may be \
                changed to whatever reads as one sentence in this language.
                """
        )
    }

    /// El sitio en la serie, que es lo único de la tarjeta que cambia al recorrer el mazo.
    ///
    /// Se dice aparte del contenido (es el *value* del elemento, no su *label*) porque quien escucha no
    /// ve los puntos del `TabView`: sin esto no hay forma de saber cuánto queda, y un intro del que no
    /// se sabe cuánto queda es el que se abandona. Los dos números van en la cadena y no concatenados
    /// fuera de ella: hay idiomas que no los ordenan como el inglés.
    public static func stepValue(for presentation: IntroPresentation) -> String {
        String(
            localized: "intro.card.accessibilityValue",
            defaultValue: "Step \(presentation.step) of \(presentation.stepCount)",
            comment: """
                VoiceOver value of an intro card: where it sits in the deck. First placeholder is \
                the current card, second is how many there are.
                """
        )
    }
}
