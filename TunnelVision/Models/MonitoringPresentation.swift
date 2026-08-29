import Foundation

/// Lo que puede hacer el usuario desde el control de monitorización.
///
/// `startAfterPriming` y `start` disparan la **misma** acción del controlador; se distinguen porque
/// solo la primera provoca el diálogo del sistema (no hay perfil guardado todavía), y
/// `docs/ux/onboarding-and-consent.md` prohíbe que ese diálogo aparezca en frío: antes va la hoja de
/// explicación. Que la diferencia sea un valor y no una comprobación suelta en la vista es lo que
/// permite probar que la hoja se exige exactamente cuando toca.
public enum MonitoringAction: Sendable, Equatable {
    /// Encender pasando primero por la hoja de explicación: iOS pedirá permiso para añadir la VPN.
    case startAfterPriming
    /// Encender directamente: el perfil ya está guardado, no hay diálogo del sistema.
    case start
    /// Apagar.
    case stop
    /// Reintentar tras un fallo. No repite la hoja de priming porque la tarjeta de fallo que el
    /// usuario está leyendo **ya** explica qué hace falta y por qué: volver a explicarlo sería un
    /// paso de más justo cuando quiere salir del error.
    case retry
}

/// Cuánto sitio se lleva el control de monitorización en la pantalla.
///
/// Es la mitad del defecto que encontró usar la app terminada (`docs/ux/screens.md` § *Dashboard*):
/// el control ocupaba media Dashboard **siempre**, y con el túnel encendido la pantalla existe por el
/// gráfico, los contadores y los hosts. Lo que cambia con esto es el **peso**, nunca la claridad.
///
/// La decisión vive aquí y no en la vista por lo mismo que la copia: qué estado merece una tarjeta
/// entera y cuál una franja es una regla de producto, así que se afirma en un test en vez de
/// comprobarse a ojo.
public enum MonitoringProminence: Sendable, Equatable {
    /// Una tarjeta con su explicación y su acción ocupando el ancho: hay algo que ofrecer (encender)
    /// o algo que arreglar (un fallo). Es lo primero que ofrece una Dashboard vacía.
    case offer
    /// Una franja de una línea: el túnel ya está trabajando o yendo a algún sitio, y lo que el usuario
    /// quiere mirar está debajo.
    case status
}

/// Lo que pinta el control de monitorización de la Dashboard para un `TunnelState` dado.
///
/// Es la copia de la pantalla convertida en dato: título, explicación, símbolo, papel de color y la
/// acción disponible. Al ser un valor puro, las reglas de UX que importan —que un fallo **siempre**
/// ofrece salida, que nunca se anuncia "monitorizando" mientras el túnel se restablece— son
/// afirmaciones de un test y no algo que haya que comprobar a ojo en el Simulator.
public struct MonitoringPresentation: Sendable, Equatable {

    /// Titular del control, en lenguaje del usuario.
    public let title: String

    /// Una frase explicando el estado y, si hay algo que hacer, qué pasará al hacerlo.
    public let detail: String

    /// El texto del botón, o `nil` si no hay nada que pulsar (transiciones).
    public let actionTitle: String?

    /// La acción del botón, o `nil` mientras el sistema está a lo suyo.
    public let action: MonitoringAction?

    public let systemImage: String
    public let role: StatusRole

    /// Si el estado es transitorio y la vista debe enseñar un indicador de progreso.
    public let isBusy: Bool

    /// Cuánto sitio merece el control en este estado. No tiene valor por defecto **a propósito**: un
    /// estado nuevo tiene que elegir su peso, no heredarlo.
    public let prominence: MonitoringProminence

    /// El texto del sistema tras un fallo, para enseñarlo en segundo plano.
    ///
    /// Existe porque la copia principal **no** puede ser un mensaje de framework (principio 7 de
    /// `docs/ux/00-ux-principles.md`: errores accionables, nunca un código crudo), pero tragárselo
    /// dejaría al usuario sin nada que contar si pide ayuda. Va en la tarjeta, en secundario.
    public let diagnostic: String?

    public init(
        title: String,
        detail: String,
        actionTitle: String?,
        action: MonitoringAction?,
        systemImage: String,
        role: StatusRole,
        prominence: MonitoringProminence,
        isBusy: Bool = false,
        diagnostic: String? = nil
    ) {
        self.title = title
        self.detail = detail
        self.actionTitle = actionTitle
        self.action = action
        self.systemImage = systemImage
        self.role = role
        self.prominence = prominence
        self.isBusy = isBusy
        self.diagnostic = diagnostic
    }

    /// Cómo se atiende una petición de encender que llega **de fuera** de la pantalla — hoy, la
    /// última tarjeta del intro, que se despide con *Start monitoring* (M10).
    ///
    /// No es `action`, y la diferencia no es cosmética: desde `live` la acción de la pantalla es
    /// **parar**, así que atender con ella una petición de encender apagaría la monitorización, que es
    /// justo lo contrario de lo que se pidió. Y en una transición no hay nada que pedir todavía: el
    /// sistema ya está yendo a algún sitio.
    ///
    /// Lo que sí se conserva es el resto de la decisión ya probada: sin perfil guardado se pasa por la
    /// hoja de explicación y con perfil se arranca directo, de modo que quien viene del intro y quien
    /// pulsa el botón de la Dashboard recorren exactamente el mismo camino.
    public var startRequestAction: MonitoringAction? {
        switch action {
        case .startAfterPriming, .start, .retry: return action
        case .stop, .none: return nil
        }
    }

    /// El botón de encender. Es una sola clave para los dos estados que lo ofrecen porque es la misma
    /// acción con las mismas palabras: lo que los distingue es si iOS pedirá permiso antes, y eso no
    /// se dice en el botón sino en la hoja que aparece después.
    private static var startTitle: String {
        String(
            localized: "monitoring.action.start",
            defaultValue: "Start monitoring",
            comment: """
                Primary button of the monitoring control when it is off. It names the action in the \
                product's own words: 'monitoring' is what this app does, never 'connect' or \
                'enable VPN' — the VPN is the mechanism, not the point.
                """
        )
    }

    /// La presentación que le corresponde a un estado del túnel.
    public static func forState(_ state: TunnelState) -> MonitoringPresentation {
        switch state {
        case .notInstalled:
            return MonitoringPresentation(
                title: String(
                    localized: "monitoring.notInstalled.title",
                    defaultValue: "Monitoring is off",
                    comment: """
                        Headline of the monitoring control before the VPN configuration has ever \
                        been saved. It says the same as the plain off state on purpose: the user \
                        has no reason to care that iOS has nothing stored yet.
                        """
                ),
                detail: String(
                    localized: "monitoring.notInstalled.detail",
                    defaultValue: """
                        TunnelVision watches your connections through a private VPN that runs on this \
                        device. Nothing is uploaded anywhere.
                        """,
                    comment: """
                        Body of the monitoring control the first time round, when starting will \
                        bring up the system's VPN permission dialog. It introduces the mechanism \
                        before the system asks about it, and denies the upload the word 'VPN' \
                        makes people fear. 'Private' here means local to the device.
                        """
                ),
                actionTitle: startTitle,
                action: .startAfterPriming,
                systemImage: "shield.lefthalf.filled",
                role: .neutral,
                prominence: .offer
            )

        case .off:
            return MonitoringPresentation(
                title: String(
                    localized: "monitoring.off.title",
                    defaultValue: "Monitoring is off",
                    comment: "Headline of the monitoring control while it is stopped and the VPN configuration is already saved."
                ),
                detail: String(
                    localized: "monitoring.off.detail",
                    defaultValue: "Start monitoring to see the connections this device makes.",
                    comment: """
                        Body of the monitoring control while it is stopped. Shorter than the \
                        first-run one: the explanation has been given already, what is missing is \
                        what the button is for.
                        """
                ),
                actionTitle: startTitle,
                action: .start,
                systemImage: "shield.lefthalf.filled",
                role: .neutral,
                prominence: .offer
            )

        case .starting:
            return MonitoringPresentation(
                title: String(
                    localized: "monitoring.starting.title",
                    defaultValue: "Starting…",
                    comment: "Headline of the monitoring control while iOS brings the VPN up. Ends in an ellipsis: it is a transition, not a state to settle in."
                ),
                detail: String(
                    localized: "monitoring.starting.detail",
                    defaultValue: "Waiting for iOS to bring the VPN up.",
                    comment: """
                        Body of the monitoring control while starting. It names who is being \
                        waited on — the system, not the app — because that is what tells the user \
                        there is nothing for them to do.
                        """
                ),
                actionTitle: nil,
                action: nil,
                systemImage: "shield.lefthalf.filled",
                role: .neutral,
                prominence: .status,
                isBusy: true
            )

        case .live:
            return MonitoringPresentation(
                title: String(
                    localized: "monitoring.live.title",
                    defaultValue: "Monitoring on",
                    comment: "Headline of the monitoring control while traffic is actually being watched."
                ),
                detail: String(
                    localized: "monitoring.live.detail",
                    defaultValue: "iOS shows a VPN icon while monitoring is on. Everything stays on this device.",
                    comment: """
                        Body of the monitoring control while it is running. Both claims are \
                        load-bearing: the status-bar VPN icon is explained here so it is never a \
                        surprise, and the promise that nothing leaves the device is the one the \
                        user can read exactly while it matters.
                        """
                ),
                actionTitle: String(
                    localized: "monitoring.action.stop",
                    defaultValue: "Stop monitoring",
                    comment: "Primary button of the monitoring control while it is running. The counterpart of the start button, in the same words."
                ),
                action: .stop,
                // El escudo **cerrado** y no el mismo de apagado: en la franja de estado el símbolo va
                // solo, sin la prosa que en la tarjeta decía de qué estado se hablaba, así que es él
                // quien tiene que distinguir encendido de apagado sin depender del color.
                systemImage: "checkmark.shield.fill",
                role: .accent,
                prominence: .status
            )

        case .stopping:
            return MonitoringPresentation(
                title: String(
                    localized: "monitoring.stopping.title",
                    defaultValue: "Stopping…",
                    comment: "Headline of the monitoring control while iOS takes the VPN down. Ends in an ellipsis, like its starting counterpart."
                ),
                detail: String(
                    localized: "monitoring.stopping.detail",
                    defaultValue: "Waiting for iOS to take the VPN down.",
                    comment: "Body of the monitoring control while stopping. Names the system as the one being waited on, like its starting counterpart."
                ),
                actionTitle: nil,
                action: nil,
                systemImage: "shield.lefthalf.filled",
                role: .neutral,
                prominence: .status,
                isBusy: true
            )

        case .failed(let error):
            return failure(error)
        }
    }

    /// La tarjeta de fallo. **Siempre** ofrece reintentar: un fallo sin salida es exactamente lo que
    /// prohíbe `docs/ux/onboarding-and-consent.md`.
    private static func failure(_ error: TunnelControlError) -> MonitoringPresentation {
        let title: String
        let detail: String
        let diagnostic: String?

        switch error {
        case .permissionDenied:
            title = String(
                localized: "monitoring.failure.permissionDenied.title",
                defaultValue: "Permission needed",
                comment: """
                    Headline after the user (or the system) refused the VPN permission. It names \
                    what is missing, never blames: the refusal may well have been deliberate.
                    """
            )
            detail = String(
                localized: "monitoring.failure.permissionDenied.detail",
                defaultValue: """
                    iOS didn't get permission to add the VPN configuration, so monitoring can't start. \
                    The VPN is local: your traffic is not sent to us or anyone else.
                    """,
                comment: """
                    Body shown after the VPN permission was refused. It repeats that the VPN is \
                    local because this is precisely the moment the user was suspicious enough to \
                    say no, and it is what they need in order to decide again.
                    """
            )
            diagnostic = nil

        case .notInstalled:
            title = String(
                localized: "monitoring.failure.notInstalled.title",
                defaultValue: "No VPN configuration yet",
                comment: "Headline when starting was asked for but nothing was ever saved for iOS to bring up."
            )
            detail = String(
                localized: "monitoring.failure.notInstalled.detail",
                defaultValue: "The VPN configuration wasn't saved, so there's nothing to start. Try adding it again.",
                comment: "Body when there is no saved VPN configuration to start. The way out is to add it, which is what the retry button does."
            )
            diagnostic = nil

        case .configurationFailed(let message):
            title = String(
                localized: "monitoring.failure.configurationFailed.title",
                defaultValue: "Couldn't save the VPN configuration",
                comment: "Headline when iOS refused to store the VPN configuration."
            )
            detail = String(
                localized: "monitoring.failure.configurationFailed.detail",
                defaultValue: "iOS refused to store the configuration. Try again, and check Settings › General › VPN if it keeps failing.",
                comment: """
                    Body when iOS refused to store the VPN configuration. The path names screens \
                    of iOS itself: use the wording those screens have in the target language, not \
                    a literal translation of the English one.
                    """
            )
            diagnostic = message

        case .startFailed(let message):
            title = String(
                localized: "monitoring.failure.startFailed.title",
                defaultValue: "Couldn't start monitoring",
                comment: "Headline when the configuration exists but iOS did not bring the tunnel up."
            )
            detail = String(
                localized: "monitoring.failure.startFailed.detail",
                defaultValue: "The VPN configuration is saved but iOS didn't bring it up. Try again.",
                comment: "Body when the saved configuration failed to start. It says what is already in place, so retrying does not read as starting from scratch."
            )
            diagnostic = message

        case .notRunning:
            title = String(
                localized: "monitoring.failure.notRunning.title",
                defaultValue: "Monitoring stopped",
                comment: "Headline when monitoring turned out not to be running — typically the tunnel went down on its own."
            )
            detail = String(
                localized: "monitoring.failure.notRunning.detail",
                defaultValue: "Monitoring isn't running any more. Start it again to keep watching connections.",
                comment: "Body when monitoring is no longer running. Nothing broke that the user must fix: the way out is simply to start again."
            )
            diagnostic = nil

        case .controlChannelFailed(let message):
            title = String(
                localized: "monitoring.failure.controlChannelFailed.title",
                defaultValue: "Lost contact with the monitor",
                comment: """
                    Headline when the app cannot talk to the running extension. 'The monitor' is \
                    the part of the app doing the watching: naming the extension or the IPC \
                    channel would mean nothing to the user.
                    """
            )
            detail = String(
                localized: "monitoring.failure.controlChannelFailed.detail",
                defaultValue: "Monitoring is on but the app can't talk to it. Stopping and starting again usually fixes it.",
                comment: "Body when the control channel failed. It states the odd part — monitoring is still on — and gives the one move that fixes it."
            )
            diagnostic = message

        case .malformedResponse:
            title = String(
                localized: "monitoring.failure.malformedResponse.title",
                defaultValue: "Lost contact with the monitor",
                comment: """
                    Headline when the extension answered something unintelligible. Same wording as \
                    the lost-channel case because it is the same fact for the user, and a separate \
                    key so rewording one never silently changes the other.
                    """
            )
            detail = String(
                localized: "monitoring.failure.malformedResponse.detail",
                defaultValue: "The monitor answered something the app didn't understand. Stopping and starting again usually fixes it.",
                comment: "Body when the extension's answer could not be decoded. Same way out as the lost-channel case."
            )
            diagnostic = nil
        }

        return MonitoringPresentation(
            title: title,
            detail: detail,
            actionTitle: String(
                localized: "monitoring.action.retry",
                defaultValue: "Try again",
                comment: """
                    Button on every failure card of the monitoring control. There is always one: a \
                    failure with no way out is what docs/ux/onboarding-and-consent.md forbids.
                    """
            ),
            action: .retry,
            systemImage: "exclamationmark.triangle",
            role: .warning,
            prominence: .offer,
            diagnostic: diagnostic
        )
    }
}
