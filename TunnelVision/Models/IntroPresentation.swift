import Foundation

/// Una de las tres tarjetas del intro de la primera ejecución
/// (`docs/ux/onboarding-and-consent.md`, *First run*).
///
/// El orden del `CaseIterable` **es** el orden en que se enseñan, y es el que fija la spec: qué hace,
/// cómo funciona, tu privacidad. No es decorativo — cada tarjeta prepara la siguiente, y la tercera
/// prepara el diálogo del sistema que viene después.
public enum IntroCard: String, Sendable, Equatable, CaseIterable, Identifiable {

    /// Qué gana el usuario. Antes de pedirle nada.
    case whatItDoes

    /// Que hay una VPN de por medio y que iOS lo va a enseñar en la barra de estado. La expectativa
    /// se pone **antes** del diálogo del sistema, no después (regla de copia de la spec).
    case howItWorks

    /// Qué no pasa: ni cuenta, ni nube, ni subida, y se puede parar cuando se quiera.
    case yourPrivacy

    public var id: String { rawValue }
}

/// Lo que hace el botón primario de una tarjeta.
public enum IntroAction: Sendable, Equatable {

    /// Pasar a la siguiente tarjeta.
    case next

    /// Terminar el intro **pidiendo encender**. Solo lo ofrece la última tarjeta.
    case startMonitoring
}

/// Cómo terminó el intro, que es lo único que la app necesita saber de él.
///
/// Es un valor y no dos closures porque las dos salidas tienen que ser igual de válidas: la spec
/// exige que el intro sea saltable, así que "no encender todavía" no puede ser un camino de segunda
/// que se implemente distinto.
public enum IntroOutcome: Sendable, Equatable {

    /// Se aterriza en la Dashboard sin pedir nada. Es lo que hace *Skip*, y también el *Not now* de la
    /// última tarjeta.
    case dismissed

    /// Se aterriza en la Dashboard pidiéndole lo mismo que su propio botón de encender.
    case startMonitoring
}

/// Lo que pinta una tarjeta del intro: su copia, su símbolo, dónde va en la serie y las dos salidas.
///
/// Es un valor puro por lo mismo que `MonitoringPresentation`: las reglas que importan aquí son de
/// consentimiento —que **ninguna** tarjeta tenga un solo botón, que la última diga *Start monitoring*
/// y no *Done*, que la copia nombre lo que iOS va a enseñar antes de que lo enseñe— y esas se afirman
/// en un test, no a ojo en el Simulator.
public struct IntroPresentation: Sendable, Equatable {

    public let card: IntroCard

    public let title: String

    public let message: String

    public let systemImage: String

    /// Posición en la serie, empezando por 1. La usa el indicador de página y la lee VoiceOver: un
    /// intro sin sitio ("2 de 3") no deja saber cuánto queda, y eso es lo que hace que se salte.
    public let step: Int

    public let stepCount: Int

    public let actionTitle: String

    public let action: IntroAction

    /// El texto de la salida. **Nunca es `nil`**: la regla de consentimiento de la spec dice que
    /// siempre hay un camino para no hacerlo, y una tarjeta con un solo botón lo incumpliría aunque
    /// ese botón no haga nada irreversible.
    public let skipTitle: String

    public init(
        card: IntroCard,
        title: String,
        message: String,
        systemImage: String,
        step: Int,
        stepCount: Int,
        actionTitle: String,
        action: IntroAction,
        skipTitle: String
    ) {
        self.card = card
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.step = step
        self.stepCount = stepCount
        self.actionTitle = actionTitle
        self.action = action
        self.skipTitle = skipTitle
    }

    public var isLast: Bool { step == stepCount }

    // MARK: - La serie

    /// Las tarjetas en el orden en que se enseñan.
    public static let cards: [IntroCard] = IntroCard.allCases

    /// La siguiente, o `nil` si esta es la última. Es toda la navegación del intro, y vive aquí y no
    /// en el view model para que "de la última no se avanza" sea una afirmación probada y no el
    /// resultado de un índice que por poco no se sale.
    public static func card(after card: IntroCard) -> IntroCard? {
        guard let index = cards.firstIndex(of: card), index + 1 < cards.count else { return nil }
        return cards[index + 1]
    }

    /// La anterior, o `nil` si esta es la primera. Existe desde M11 porque el intro se recorre también
    /// hacia atrás cuando no se ve (`IntroAccessibility`), y ningún botón de la pantalla vuelve: hasta
    /// entonces volver era solo un deslizamiento. Vive aquí, pegada a `card(after:)`, para que los dos
    /// extremos de la serie los decida el mismo sitio.
    public static func card(before card: IntroCard) -> IntroCard? {
        guard let index = cards.firstIndex(of: card), index > 0 else { return nil }
        return cards[index - 1]
    }

    /// La última de la serie, que es la que pide encender — y por eso es un sitio al que se quiere
    /// poder ir de una vez. Es opcional y no un `cards.last!` porque una serie vacía es representable
    /// aunque hoy no lo esté, y una interrogación cuesta menos que la caída que evita.
    public static var lastCard: IntroCard? { cards.last }

    /// La presentación de una tarjeta.
    public static func forCard(_ card: IntroCard) -> IntroPresentation {
        let step = (cards.firstIndex(of: card) ?? 0) + 1
        let count = cards.count
        let isLast = step == count

        // La última se despide pidiendo encender, y con esas palabras: la spec dice *Start monitoring*
        // y no *Done* porque el botón hace algo, y llamarlo de otra forma dejaría al usuario en la
        // Dashboard sin saber que lo que acaba de pulsar era el arranque.
        let actionTitle = isLast
            ? String(
                localized: "intro.action.start",
                defaultValue: "Start monitoring",
                comment: """
                    Primary button on the last intro card. It starts capturing traffic, so it \
                    must name the action and not merely close the intro (never 'Done').
                    """
            )
            : String(
                localized: "intro.action.continue",
                defaultValue: "Continue",
                comment: """
                    Primary button on the intro cards that are not the last one. It only moves \
                    to the next card and starts nothing.
                    """
            )
        let action: IntroAction = isLast ? .startMonitoring : .next

        // Las dos salidas dicen cosas distintas porque lo son: en las primeras se salta el resto de la
        // explicación, en la última se decide no encender todavía. Llamar *Skip* a la segunda haría
        // creer que quedan tarjetas.
        let skipTitle = isLast
            ? String(
                localized: "intro.exit.notNow",
                defaultValue: "Not now",
                comment: """
                    Way out of the last intro card. Here there is nothing left to skip: the \
                    choice is not to start monitoring yet.
                    """
            )
            : String(
                localized: "intro.exit.skip",
                defaultValue: "Skip",
                comment: """
                    Way out of an intro card that still has cards behind it. It leaves the \
                    intro without starting anything.
                    """
            )

        switch card {
        case .whatItDoes:
            return IntroPresentation(
                card: card,
                title: String(
                    localized: "intro.card.whatItDoes.title",
                    defaultValue: "See what your device talks to",
                    comment: """
                        Headline of the first intro card: what the user gets, before being \
                        asked for anything.
                        """
                ),
                message: String(
                    localized: "intro.card.whatItDoes.message",
                    defaultValue: """
                        TunnelVision shows you which apps and servers this device connects to, and \
                        how much data they use. Everything stays on your device.
                        """,
                    comment: """
                        Body of the first intro card. Plain language on purpose: no protocol \
                        or networking jargon (see docs/ux/00-ux-principles.md, principle 3).
                        """
                ),
                systemImage: "network",
                step: step,
                stepCount: count,
                actionTitle: actionTitle,
                action: action,
                skipTitle: skipTitle
            )

        case .howItWorks:
            return IntroPresentation(
                card: card,
                title: String(
                    localized: "intro.card.howItWorks.title",
                    defaultValue: "How it works",
                    comment: "Headline of the second intro card."
                ),
                message: String(
                    localized: "intro.card.howItWorks.message",
                    defaultValue: """
                        TunnelVision watches traffic through a private VPN that runs on this device \
                        — nothing is routed through a server of ours. While it is on, iOS shows a \
                        VPN icon in the status bar.
                        """,
                    comment: """
                        Body of the second intro card. It must keep naming the VPN and the \
                        status bar icon: this is what sets the expectation before iOS shows its \
                        own permission prompt. 'VPN' is the system's own word here, not jargon.
                        """
                ),
                systemImage: "shield.lefthalf.filled",
                step: step,
                stepCount: count,
                actionTitle: actionTitle,
                action: action,
                skipTitle: skipTitle
            )

        case .yourPrivacy:
            return IntroPresentation(
                card: card,
                title: String(
                    localized: "intro.card.yourPrivacy.title",
                    defaultValue: "Your privacy",
                    comment: "Headline of the third intro card."
                ),
                message: String(
                    localized: "intro.card.yourPrivacy.message",
                    defaultValue: """
                        No account. No cloud. Nothing is uploaded. What TunnelVision records stays \
                        on this device, and you can stop monitoring at any time.
                        """,
                    comment: """
                        Body of the third intro card. It is the promise the whole product \
                        rests on, so each of the three denials (no account, no cloud, nothing \
                        uploaded) must survive translation, as must the way out at the end.
                        """
                ),
                systemImage: "lock.iphone",
                step: step,
                stepCount: count,
                actionTitle: actionTitle,
                action: action,
                skipTitle: skipTitle
            )
        }
    }
}
