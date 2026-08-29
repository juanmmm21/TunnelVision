import Foundation

/// El flujo guiado de la CA local: qué se enseña en cada momento y qué se puede afirmar (M10, pasos
/// 0–4 de `docs/ux/onboarding-and-consent.md`).
///
/// Es la pieza de UX más importante que le queda al producto y es también la que más veces sale del
/// app: generar el certificado, entregárselo a iOS, instalarlo, darle confianza plena y volver. Nada de
/// eso se puede *observar* desde dentro —iOS no expone qué certificados hay instalados—, así que todo
/// lo que la pantalla puede afirmar sale de dos hechos (`CertificateStatus`) y de una regla que los
/// traduce en un sitio del recorrido. Esa regla es pura y vive aquí, no en el view model, porque lo que
/// gobierna no es dibujo: es qué se le ofrece al usuario y qué se le promete.

/// Dónde está el usuario dentro del flujo.
///
/// No es un contador de pasos, es una **derivada del estado de la CA**: si el usuario instaló el
/// certificado mientras la app estaba en segundo plano, al volver está donde el sistema dice que está y
/// no donde el contador se hubiera quedado. Los pasos 2 y 3 de la spec van juntos en un único caso a
/// propósito, y la razón está en `installAndTrust`.
public enum CertificateSetupStage: Sendable, Equatable {

    /// Paso 0: qué se gana y qué no, **antes** de crear nada. Es la única etapa que no depende del
    /// estado de la CA: es la puerta que hay delante de crearla.
    case explainTradeOff

    /// Paso 1: no hay CA y se puede crear.
    case generate

    /// Pasos 2 y 3, **juntos**: la etapa enseña el recorrido entero porque desde ella se puede llegar
    /// a los dos sitios, y volver atrás no cuesta nada.
    ///
    /// **Corrección del 2026-08-15:** aquí ponía que iOS no deja distinguir "no está instalado" de
    /// "está instalado sin confianza plena". **Sí deja**, y creerlo costó una sesión con el
    /// dispositivo delante: son dos preguntas distintas al sistema, no una (`TrustProbe`). Lo que no
    /// cambia es la etapa —quien solo tiene que darle a un interruptor está igual de bien servido por
    /// una pantalla que enseña los dos pasos—; lo que cambia es el **aviso**, que ya puede nombrar el
    /// interruptor concreto en vez de mandar a repetir la instalación
    /// (`CertificateSetupPresentation.installedButNotFullyTrusted`).
    case installAndTrust

    /// Paso 4: el sistema confía en la raíz. Es lo único que se puede afirmar del otro lado.
    case ready

    /// El llavero no se dejó mirar. No se ofrece crear nada aquí: generar reemplaza la clave raíz, y
    /// hacerlo a ciegas se llevaría por delante la CA que el usuario ya instaló y confió, dejándole un
    /// certificado instalado que no firma nada.
    case unavailable(String)
}

/// Qué está haciendo el flujo ahora mismo. Existe por lo mismo que `SettingsActivity`: preguntarle al
/// llavero y al sistema de confianza tarda lo que tarda, y una pantalla muda mientras tanto invita a
/// tocar dos veces lo que solo se puede hacer una.
public enum CertificateSetupActivity: Sendable, Equatable {
    case idle
    /// Preguntando por la CA y por la confianza.
    case checking
    case generating
    case preparingProfile
    case removing
}

/// Lo que puede hacer el botón de una etapa.
public enum CertificateSetupAction: Sendable, Equatable {
    /// Seguir después de leer el paso 0. No crea nada todavía.
    case acknowledgeTradeOff
    case generate
    /// Preparar el perfil y entregárselo al sistema para que el usuario lo abra.
    case shareProfile
    /// Volver a preguntarle al sistema si confía. Es la única forma de saber si los pasos 2 y 3 se
    /// hicieron: no se observan, se comprueba el resultado.
    case recheckTrust
    /// Encender la inspección ahora que se puede.
    case enableInspection
    /// Cerrar el flujo. No cambia nada.
    case finish
    /// Volver a mirar el llavero tras un fallo.
    case retryStatus
}

/// Un botón de la pantalla: lo que dice y lo que hace.
public struct CertificateSetupButton: Sendable, Equatable {
    public let title: String
    public let action: CertificateSetupAction

    public init(title: String, action: CertificateSetupAction) {
        self.title = title
        self.action = action
    }
}

/// Una instrucción del recorrido por los Ajustes de iOS. Va numerada porque el usuario la sigue con el
/// dispositivo en la mano y saliendo de la app entre paso y paso.
public struct CertificateSetupStep: Sendable, Equatable, Identifiable {
    public let number: Int
    public let title: String
    public let detail: String

    /// El número identifica y **no** se traduce: la identidad de una fila no puede cambiar con el
    /// idioma, y es además lo único de un paso que no es copia.
    public var id: Int { number }

    public init(number: Int, title: String, detail: String) {
        self.number = number
        self.title = title
        self.detail = detail
    }

    /// Todo el paso en una sola frase, para quien no ve la lista.
    ///
    /// Vive aquí desde M11 y no en `SetupStepList`, que era donde se componía: unir número, título y
    /// detalle con puntos es una decisión del inglés, y **separador y orden son propiedad de un
    /// idioma** — compuesta dentro de una vista no habría dónde cambiarlos. El número entra en la
    /// frase, y no se calla como en el dibujo (donde el círculo es decoración), porque quien escucha
    /// necesita saber por dónde va un recorrido que se hace saliendo de la app entre paso y paso.
    public var accessibilityLabel: String {
        String(
            localized: "certificateSetup.step.accessibilityLabel",
            defaultValue: "Step \(String(number)). \(title). \(detail)",
            comment: """
                VoiceOver label of one numbered instruction in the certificate flow. First \
                placeholder is the step number, second its short title, third the instruction \
                itself; separator and order may be changed to whatever reads as one sentence in \
                this language.
                """
        )
    }
}

/// Dónde se lee la advertencia fija de una etapa.
///
/// Existe porque era un `if let note` en la vista que siempre contestaba lo mismo —una tarjeta
/// suelta entre la prosa y lo que viniera después—, y las tres notas que hay en el flujo no son la
/// misma cosa. Medido en el Simulator: dibujadas todas igual, la del paso 0 metía **las tres
/// promesas sobre las que descansa el producto** (nada se sube, la clave privada no sale, todo es
/// reversible) en la caja de menor peso de la pantalla, y la de la etapa de instalación se plantaba
/// entre el titular y la primera instrucción, que es la razón por la que se abre esa pantalla: 270
/// de los 531 puntos visibles eran preámbulo, y a AX5 el paso 1 quedaba a dos pantallas y media de
/// desplazamiento.
///
/// La regla que las separa no es cuánto miden: es **de qué son pie**. Es la misma que Ajustes ya
/// aplicó a su prosa fija —la explicación de una sección va debajo de ella y no dentro de una de sus
/// filas—, con el caso que allí se dejó fuera: una avería que ocurre **ahora** sí conserva su propia
/// superficie.
///
/// No tiene valor por defecto, por lo mismo que `MonitoringProminence` y `SymbolDisc`: una etapa
/// nueva con algo que advertir tiene que decir de qué es pie, no heredar el sitio de la anterior.
public enum SetupNotePlacement: Sendable, Equatable {

    /// Bajo la prosa de la etapa, en la misma columna y sin caja: la nota **es** lo que la etapa
    /// afirma y no hay ningún recorrido del que pueda ser pie. Fuera de la caja el texto tiene el
    /// ancho entero (370 puntos contra 333) y ocupa menos, que es el mismo efecto secundario que
    /// midió Ajustes.
    case belowMessage

    /// Al pie de las instrucciones, dentro de su tarjeta: la nota habla de **ese** recorrido —por
    /// qué siguen ahí los dos pasos, qué hacer si uno ya está dado—, así que leerla antes de la
    /// lista es leer la respuesta antes de la pregunta.
    case footOfGuidance

    /// En su propia superficie hundida: la nota **no es copia nuestra** sino lo que contestó el
    /// sistema, y eso se mira como material, igual que un volcado o el cuerpo de una conversación.
    /// Es también el único caso que sigue siendo una avería que ocurre ahora.
    case ownSurface
}

/// Lo que hay que advertir de una etapa antes de que sorprenda, y dónde se lee.
///
/// Los dos datos van juntos y no en dos campos sueltos de la presentación a propósito: una nota sin
/// sitio y un sitio sin nota son los dos estados que no existen, y separarlos deja a la vista
/// eligiendo por su cuenta cuando uno de los dos falta.
public struct CertificateSetupNote: Sendable, Equatable {
    public let text: String
    public let placement: SetupNotePlacement

    public init(text: String, placement: SetupNotePlacement) {
        self.text = text
        self.placement = placement
    }
}

/// Lo que se le cuenta al usuario tras una acción. Mismo papel que `SettingsNotice`: un aviso
/// descartable, nunca una tarjeta que tape el recorrido.
public struct CertificateSetupNotice: Sendable, Equatable {
    public let message: String
    public let diagnostic: String?
    public let role: StatusRole

    public init(message: String, diagnostic: String? = nil, role: StatusRole) {
        self.message = message
        self.diagnostic = diagnostic
        self.role = role
    }
}

/// Lo que se le dice al usuario mientras el perfil está en sus manos y la hoja del sistema delante.
///
/// Es el único momento del flujo en que un fichero de TunnelVision puede salir del dispositivo, así
/// que se explica **antes** de que la hoja aparezca —la misma regla que el permiso de VPN— y se dice
/// qué se está entregando: no el fichero de una preferencia, sino el certificado que el dispositivo va
/// a anclar.
public struct CertificateSetupHandoff: Sendable, Equatable {
    public let title: String
    public let message: String

    /// Lo que no es obvio y hay que decir aunque estorbe: esto no debería viajar a otro dispositivo.
    public let warning: String

    public let shareTitle: String

    public init(title: String, message: String, warning: String, shareTitle: String) {
        self.title = title
        self.message = message
        self.warning = warning
        self.shareTitle = shareTitle
    }
}

/// Lo que hay que decir **antes** de una acción que destruye algo. Las dos que existen aquí lo hacen:
/// rehacer la CA invalida el certificado ya instalado, y quitarla deja de poder mirar dentro de nada.
public struct CertificateSetupConfirmation: Sendable, Equatable {

    public enum Kind: Sendable, Equatable {
        case regenerate
        case remove
    }

    public let kind: Kind
    public let title: String
    public let message: String
    public let confirmTitle: String

    public init(kind: Kind, title: String, message: String, confirmTitle: String) {
        self.kind = kind
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
    }
}

/// Lo que pinta una etapa del flujo.
///
/// Desde M11 su copia sale del código hacia el catálogo de cadenas por
/// `String(localized:defaultValue:comment:)` (`docs/development/02-coding-standards.md`, *Product
/// copy*), y esta es la copia más delicada del producto: la que explica qué es un certificado, por qué
/// iOS avisará en rojo de que el perfil no está firmado y qué se concede al confiar en una raíz. Es
/// justo la que más gana con llevar el comentario del traductor pegado a cada cadena, porque traducida
/// de oído se convierte en la pantalla que enseña a la gente a saltarse los avisos de seguridad.
///
/// Todo lo que aquí lleva copia es `var` calculada y no `let`: una constante estática se resuelve una
/// sola vez, la primera vez que alguien la lee, y dejaría el idioma congelado en el que hubiera
/// entonces.
public struct CertificateSetupPresentation: Sendable, Equatable {

    public let stage: CertificateSetupStage
    public let title: String
    public let message: String
    public let systemImage: String
    public let primary: CertificateSetupButton

    /// La segunda acción de la etapa, cuando hay dos cosas distintas que hacer desde el mismo sitio.
    public let secondary: CertificateSetupButton?

    /// La salida que **no cambia nada**. Es `nil` solo cuando la acción principal ya es salir: dos
    /// botones para el mismo destino se leen como dos destinos.
    public let dismiss: CertificateSetupButton?

    /// El recorrido por los Ajustes de iOS, cuando la etapa lo tiene.
    public let guidance: [CertificateSetupStep]

    /// Lo que hay que advertir de esa etapa antes de que sorprenda —que no se puede saber cuál de los
    /// dos pasos falta, qué es lo que nunca sale del dispositivo— y **de qué es pie**, que es lo que
    /// decide dónde se lee (`SetupNotePlacement`).
    public let note: CertificateSetupNote?

    public let role: StatusRole

    public init(
        stage: CertificateSetupStage,
        title: String,
        message: String,
        systemImage: String,
        primary: CertificateSetupButton,
        secondary: CertificateSetupButton? = nil,
        dismiss: CertificateSetupButton?,
        guidance: [CertificateSetupStep] = [],
        note: CertificateSetupNote? = nil,
        role: StatusRole = .neutral
    ) {
        self.stage = stage
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.primary = primary
        self.secondary = secondary
        self.dismiss = dismiss
        self.guidance = guidance
        self.note = note
        self.role = role
    }

    // MARK: - La etapa, dibujada

    /// La presentación de una etapa. `inspectionEnabled` solo cambia la última: llegar con la
    /// inspección ya encendida no puede ofrecer encenderla otra vez.
    public static func forStage(
        _ stage: CertificateSetupStage,
        inspectionEnabled: Bool = false
    ) -> CertificateSetupPresentation {
        switch stage {
        case .explainTradeOff:
            return CertificateSetupPresentation(
                stage: stage,
                title: String(
                    localized: "certificateSetup.stage.explainTradeOff.title",
                    defaultValue: "Look inside secure traffic",
                    comment: """
                        Headline of step 0 of the certificate flow, the explanation that stands in \
                        front of creating anything. 'Secure traffic' is the product's plain-language \
                        name for HTTPS and is used on the Settings row that leads here.
                        """
                ),
                message: String(
                    localized: "certificateSetup.stage.explainTradeOff.message",
                    defaultValue: """
                        Almost everything your device sends is encrypted, so TunnelVision can see who \
                        each connection talks to but not what it says. To look inside your own \
                        encrypted traffic, you create a certificate here and install it yourself in \
                        iOS Settings.

                        Apps that pin their certificates are never decrypted — TunnelVision passes \
                        them through untouched and labels them as protected by the app. That is \
                        expected, and it is what keeps other apps' security intact.
                        """,
                    comment: """
                        Body of step 0 of the certificate flow: the whole trade-off, in two \
                        paragraphs. Both halves are load-bearing and neither may be dropped or \
                        softened. The first says the user installs the certificate themselves, in \
                        iOS Settings — the app cannot do it. The second says pinned apps are never \
                        decrypted, so their refusal reads as expected behaviour and not as a fault.
                        """
                ),
                systemImage: "lock.open.rotation",
                primary: CertificateSetupButton(
                    title: String(
                        localized: "certificateSetup.action.acknowledgeTradeOff",
                        defaultValue: "Continue",
                        comment: """
                            Primary button of step 0 of the certificate flow. It only moves on to \
                            the next step and creates nothing, so it must not promise an action.
                            """
                    ),
                    action: .acknowledgeTradeOff
                ),
                dismiss: notNowExit,
                // Bajo la prosa y sin caja: esta etapa no tiene recorrido del que ser pie, y las
                // tres promesas que lleva son lo que la etapa afirma — dibujadas como nota al pie
                // dentro de una tarjeta eran lo más apagado de la pantalla que las sostiene.
                note: CertificateSetupNote(
                    text: String(
                        localized: "certificateSetup.stage.explainTradeOff.note",
                        defaultValue: """
                            Nothing is uploaded and nothing leaves this device. The certificate is \
                            created here, its private key stays here, and you can undo all of this \
                            at any time.
                            """,
                        comment: """
                            Footnote of step 0 of the certificate flow. Three separate promises the \
                            product rests on — nothing uploaded, the private key never leaves, the \
                            whole thing is reversible — and each must survive translation on its own.
                            """
                    ),
                    placement: .belowMessage
                )
            )

        case .generate:
            return CertificateSetupPresentation(
                stage: stage,
                title: String(
                    localized: "certificateSetup.stage.generate.title",
                    defaultValue: "Create your certificate",
                    comment: "Headline of step 1 of the certificate flow, where the certificate is created."
                ),
                message: String(
                    localized: "certificateSetup.stage.generate.message",
                    defaultValue: """
                        One tap creates a certificate that only exists on this device. Its private \
                        key is stored in the device keychain and is never shared — not with us, not \
                        with any app.
                        """,
                    comment: """
                        Body of step 1 of the certificate flow. 'Keychain' is the system's own name \
                        for where the key is stored and stays as iOS names it in this language.
                        """
                ),
                systemImage: "seal",
                primary: CertificateSetupButton(
                    title: String(
                        localized: "certificateSetup.action.generate",
                        defaultValue: "Create certificate",
                        comment: """
                            Primary button of step 1 of the certificate flow: it creates the \
                            certificate on the device. Keep it short — it sits in a wide button.
                            """
                    ),
                    action: .generate
                ),
                dismiss: notNowExit
            )

        case .installAndTrust:
            return CertificateSetupPresentation(
                stage: stage,
                title: String(
                    localized: "certificateSetup.stage.installAndTrust.title",
                    defaultValue: "Install it and turn on trust",
                    comment: """
                        Headline of steps 2 and 3 of the certificate flow, which are shown together. \
                        It names both because iOS does not let the app tell which of the two is \
                        still missing.
                        """
                ),
                message: String(
                    localized: "certificateSetup.stage.installAndTrust.message",
                    defaultValue: """
                        Your certificate is ready. iOS asks you to do the next part yourself, in two \
                        separate places — that friction is deliberate, and it is what stops any app \
                        from quietly gaining this power.
                        """,
                    comment: """
                        Body of steps 2 and 3 of the certificate flow. The point is that the extra \
                        work is a protection and not an obstacle: presenting it as a nuisance would \
                        teach the user to hurry through the one barrier that guards this power.
                        """
                ),
                systemImage: "gearshape",
                primary: CertificateSetupButton(title: shareProfileTitle, action: .shareProfile),
                secondary: CertificateSetupButton(title: recheckTrustTitle, action: .recheckTrust),
                dismiss: CertificateSetupButton(
                    title: String(
                        localized: "certificateSetup.exit.finishLater",
                        defaultValue: "Finish later",
                        comment: """
                            Way out of steps 2 and 3 of the certificate flow. Not 'Not now' like the \
                            earlier steps: the certificate already exists, so what is being put off \
                            is finishing something already started.
                            """
                    ),
                    action: .finish
                ),
                guidance: installSteps + trustSteps,
                // Al pie de la lista: lo que explica es por qué siguen ahí los cinco pasos, así que
                // delante de ellos es la respuesta antes de la pregunta — y en medio empujaba la
                // primera instrucción hasta el punto 462 de una ventana de 531.
                note: CertificateSetupNote(
                    text: String(
                        localized: "certificateSetup.stage.installAndTrust.note",
                        defaultValue: """
                            iOS doesn't let TunnelVision see which certificates are installed, so \
                            both steps stay here until the system reports your certificate as \
                            trusted. If you have already done one of them, go straight to the other.
                            """,
                        comment: """
                            Footnote of steps 2 and 3 of the certificate flow, explaining why both \
                            are still on screen. It must stay an explanation of a system limit, \
                            never an apology and never a claim about which step is missing.
                            """
                    ),
                    placement: .footOfGuidance
                )
            )

        case .ready:
            guard inspectionEnabled else {
                return CertificateSetupPresentation(
                    stage: stage,
                    title: String(
                        localized: "certificateSetup.stage.ready.title",
                        defaultValue: "Your certificate is trusted",
                        comment: """
                            Headline of step 4 of the certificate flow when the system trusts the \
                            certificate but inspection has not been turned on yet.
                            """
                    ),
                    message: readyMessage,
                    systemImage: "checkmark.seal",
                    primary: CertificateSetupButton(
                        title: String(
                            localized: "certificateSetup.action.enableInspection",
                            defaultValue: "Turn on inspection",
                            comment: """
                                Primary button of step 4 of the certificate flow: it turns on \
                                decryption of the user's own HTTPS traffic.
                                """
                        ),
                        action: .enableInspection
                    ),
                    dismiss: notNowExit,
                    role: .accent
                )
            }
            return CertificateSetupPresentation(
                stage: stage,
                title: String(
                    localized: "certificateSetup.stage.ready.enabled.title",
                    defaultValue: "Inspection is on",
                    comment: """
                        Headline of step 4 of the certificate flow when inspection is already on. It \
                        states the current state rather than congratulating: nothing is left to do.
                        """
                ),
                message: readyMessage,
                systemImage: "checkmark.seal.fill",
                primary: CertificateSetupButton(
                    title: String(
                        localized: "certificateSetup.action.done",
                        defaultValue: "Done",
                        comment: """
                            Primary button of step 4 of the certificate flow once inspection is on. \
                            It only closes the flow, and it is the one place in the flow where the \
                            main button is the way out.
                            """
                    ),
                    action: .finish
                ),
                dismiss: nil,
                role: .accent
            )

        case .unavailable(let diagnostic):
            return CertificateSetupPresentation(
                stage: stage,
                title: String(
                    localized: "certificateSetup.stage.unavailable.title",
                    defaultValue: "Couldn't check your certificate",
                    comment: """
                        Headline shown when the device keychain could not be read, so the flow does \
                        not know whether a certificate exists. It says the check failed, never that \
                        there is no certificate.
                        """
                ),
                message: String(
                    localized: "certificateSetup.stage.unavailable.message",
                    defaultValue: """
                        TunnelVision couldn't read the device keychain, so it can't tell whether you \
                        already have a certificate. Nothing has been changed, and nothing will be \
                        until it can: creating one would replace a certificate you may already be \
                        using.
                        """,
                    comment: """
                        Body shown when the device keychain could not be read. It has to say two \
                        things: that nothing was changed, and why nothing is offered — creating a \
                        certificate blind would replace one the user may already have installed.
                        """
                ),
                systemImage: "questionmark.circle",
                primary: CertificateSetupButton(
                    title: String(
                        localized: "certificateSetup.action.retryStatus",
                        defaultValue: "Try again",
                        comment: """
                            Primary button shown when the device keychain could not be read. It \
                            looks again and changes nothing on its own.
                            """
                    ),
                    action: .retryStatus
                ),
                dismiss: CertificateSetupButton(
                    title: String(
                        localized: "certificateSetup.exit.close",
                        defaultValue: "Close",
                        comment: """
                            Way out of the stage where the keychain could not be read. Neutral on \
                            purpose: there is nothing here to postpone, so 'Not now' would suggest \
                            a decision the user is not being asked to make.
                            """
                    ),
                    action: .finish
                ),
                // El diagnóstico es del sistema y no copia nuestra: no se traduce ni se maquilla, y
                // por eso mismo se mira como material y no como prosa — su propia superficie, que es
                // lo que la conversación descifrada hace con lo que no ha escrito nadie de aquí.
                note: CertificateSetupNote(text: diagnostic, placement: .ownSurface),
                role: .warning
            )
        }
    }

    /// El rótulo del botón que entrega el certificado, **compartido** con el paso numerado que le pide
    /// al usuario que lo toque.
    ///
    /// Están juntos porque una instrucción que nombra un botón deja de ser cierta en cuanto uno de los
    /// dos se reescribe, y en una traducción eso no se ve: la frase sigue leyéndose bien y manda buscar
    /// algo que en la pantalla se llama de otra manera. Compartir la clave lo hace imposible, y es la
    /// misma razón por la que `notNowExit` existe.
    private static var shareProfileTitle: String {
        String(
            localized: "certificateSetup.action.shareProfile",
            defaultValue: "Install certificate",
            comment: """
                Primary button of steps 2 and 3 of the certificate flow. It hands the certificate \
                file to the system so the user can save and open it; the install itself happens in \
                iOS Settings, which the numbered steps explain. The first numbered step names this \
                button, so whatever it says here is what the instruction will say.
                """
        )
    }

    /// El otro rótulo que un paso nombra: el de comprobar. Mismo motivo.
    private static var recheckTrustTitle: String {
        String(
            localized: "certificateSetup.action.recheckTrust",
            defaultValue: "I've done both",
            comment: """
                Secondary button of steps 2 and 3 of the certificate flow. It asks the system \
                whether the certificate is trusted now. First person on purpose: the user reports \
                what they did, because the app cannot observe it. The last numbered step names this \
                button, so whatever it says here is what the instruction will say.
                """
        )
    }

    /// La salida que comparten las etapas en las que todavía no se ha hecho nada irreversible.
    ///
    /// Es **una sola clave** para las tres porque en las tres dice lo mismo —no hacer esto todavía— y
    /// partirla en tres invitaría a que tres traducciones se separasen sin motivo. Las otras dos formas
    /// de salir sí son claves propias: *Finish later* se dice sobre algo ya empezado y *Close* sobre
    /// una etapa en la que no hay nada que posponer.
    private static var notNowExit: CertificateSetupButton {
        CertificateSetupButton(
            title: String(
                localized: "certificateSetup.exit.notNow",
                defaultValue: "Not now",
                comment: """
                    Way out of the certificate flow steps where nothing irreversible has happened \
                    yet (the explanation, creating the certificate, and turning inspection on). It \
                    means 'not doing this yet', never 'cancel what is running'.
                    """
            ),
            action: .finish
        )
    }

    /// Lo que se ve y lo que sigue sin verse, dicho en los dos sitios donde el flujo puede terminar.
    /// Nombrar lo que **no** cambia es lo que impide que la inspección se lea como "ahora se ve todo".
    static var readyMessage: String {
        String(
            localized: "certificateSetup.stage.ready.message",
            defaultValue: """
                Your own HTTPS traffic can now be decrypted, so connections show what was requested \
                and what came back. Apps that pin their certificates stay private and are labelled \
                as protected by the app — that is normal and expected. You can turn this off at any \
                time.
                """,
            comment: """
                Body of step 4 of the certificate flow, shown both before and after inspection is \
                turned on. Naming what does not change is the whole point: without the pinned-apps \
                sentence and the way out at the end, the user reads this as 'everything is visible \
                now', which is the one promise the product must not make.
                """
        )
    }

    // MARK: - El recorrido por los Ajustes de iOS

    /// Paso 2: instalar el perfil. Se nombra el aviso de *No firmado* **antes** de que aparezca: es la
    /// misma regla que la hoja del permiso de VPN, y aquí importa más, porque un aviso en rojo sobre un
    /// certificado es exactamente lo que enseña a la gente a no seguir adelante.
    ///
    /// Las tres instrucciones son la copia más difícil de traducir del producto y no por su prosa:
    /// **la mitad de sus palabras son del sistema** —rutas de los Ajustes, nombres de pantallas y
    /// respuestas que iOS da en su propio idioma—, y traducirlas de oído manda al usuario a buscar en
    /// Ajustes algo que no existe. Por eso cada comentario dice cuáles son y de dónde salen.
    public static var installSteps: [CertificateSetupStep] {
        [
            CertificateSetupStep(
                number: 1,
                title: String(
                    localized: "certificateSetup.step.saveFile.title",
                    defaultValue: "Save the certificate",
                    comment: "Title of the first numbered step of the certificate flow: saving the file."
                ),
                detail: String(
                    localized: "certificateSetup.step.saveFile.detail",
                    defaultValue: """
                        Tap \(shareProfileTitle) below and choose Save to Files. Any folder on this \
                        device works — the file never leaves it.
                        """,
                    comment: """
                        First numbered step of the certificate flow. The placeholder is the button \
                        right below on this screen, inserted so the instruction cannot name a \
                        button that says something else. 'Save to Files' is iOS's own wording in \
                        the system share sheet and must match what the device shows in this \
                        language. The last clause answers the fear the share sheet raises: the file \
                        stays on the device.
                        """
                )
            ),
            CertificateSetupStep(
                number: 2,
                title: String(
                    localized: "certificateSetup.step.openFromFiles.title",
                    defaultValue: "Open it from Files",
                    comment: """
                        Title of the second numbered step of the certificate flow. 'Files' is the \
                        iOS app of that name and takes whatever the system calls it in this language.
                        """
                ),
                detail: String(
                    localized: "certificateSetup.step.openFromFiles.detail",
                    defaultValue: """
                        Open the Files app and tap TunnelVision.mobileconfig. iOS answers with \
                        “Profile Downloaded”.
                        """,
                    comment: """
                        Second numbered step of the certificate flow. Two names are not ours: the \
                        Files app and iOS's 'Profile Downloaded' answer, which must match what the \
                        device shows in this language. 'TunnelVision.mobileconfig' is the file name \
                        and never changes.
                        """
                )
            ),
            CertificateSetupStep(
                number: 3,
                title: String(
                    localized: "certificateSetup.step.installProfile.title",
                    defaultValue: "Install the profile",
                    comment: "Title of the third numbered step of the certificate flow: installing the profile."
                ),
                detail: String(
                    localized: "certificateSetup.step.installProfile.detail",
                    defaultValue: """
                        Go to Settings → General → VPN & Device Management → TunnelVision \
                        certificate → Install. iOS marks it as Not Signed, which is expected: this \
                        certificate was created on your device moments ago, not issued by a company.
                        """,
                    comment: """
                        Third numbered step of the certificate flow. The whole path is iOS's own \
                        and must be written with the words the device uses in this language, or the \
                        user searches Settings for a screen that is not there; only 'TunnelVision \
                        certificate' is ours (it is the profile's name). 'Not Signed' is the red \
                        warning iOS shows, named here before it appears — the sentence after it is \
                        what stops the user from reading that warning as a reason to back out, so \
                        it must not be softened or dropped.
                        """
                )
            ),
        ]
    }

    /// Paso 3: la confianza plena, que iOS pide aparte a propósito.
    public static var trustSteps: [CertificateSetupStep] {
        [
            CertificateSetupStep(
                number: 4,
                title: String(
                    localized: "certificateSetup.step.fullTrust.title",
                    defaultValue: "Turn on full trust",
                    comment: """
                        Title of the fourth numbered step of the certificate flow. 'Full trust' is \
                        iOS's own term, from the Certificate Trust Settings screen.
                        """
                ),
                detail: String(
                    localized: "certificateSetup.step.fullTrust.detail",
                    defaultValue: """
                        Go to Settings → General → About → Certificate Trust Settings and turn on \
                        TunnelVision certificate. iOS makes this a separate, manual step so that no \
                        app can gain this power without you doing it yourself.
                        """,
                    comment: """
                        Fourth numbered step of the certificate flow, and the one that is easiest \
                        to miss. The path is iOS's own and must match what the device shows in this \
                        language; 'TunnelVision certificate' is the profile's name and is ours. The \
                        second sentence presents the extra work as a protection, never as a \
                        nuisance: this is the barrier that guards the whole capability.
                        """
                )
            ),
            CertificateSetupStep(
                number: 5,
                title: String(
                    localized: "certificateSetup.step.comeBack.title",
                    defaultValue: "Come back and check",
                    comment: "Title of the fifth numbered step of the certificate flow: returning to the app."
                ),
                detail: String(
                    localized: "certificateSetup.step.comeBack.detail",
                    defaultValue: """
                        Tap “\(recheckTrustTitle)” below. TunnelVision asks the system whether your \
                        certificate is trusted — it can't see the steps you took, only the answer.
                        """,
                    comment: """
                        Fifth numbered step of the certificate flow. The placeholder is the second \
                        button on this screen, inserted so the instruction cannot name a button \
                        that says something else; the quotation marks around it are the ones this \
                        language uses. The clause after the dash is a statement of what the app \
                        cannot observe and is why the user has to report it.
                        """
                )
            ),
        ]
    }

    /// La otra mitad de la reversibilidad: la clave se borra desde aquí, el perfil lo quita el usuario.
    /// Se enseña **después** de borrar la clave y no antes, porque hasta entonces no hay nada que
    /// retirar y sería una instrucción para deshacer algo que sigue puesto.
    public static var removalSteps: [CertificateSetupStep] {
        [
            CertificateSetupStep(
                number: 1,
                title: String(
                    localized: "certificateSetup.step.removeProfile.title",
                    defaultValue: "Remove the profile",
                    comment: """
                        Title of the only numbered step left after the certificate's private key \
                        has been deleted: removing the installed profile in iOS Settings.
                        """
                ),
                detail: String(
                    localized: "certificateSetup.step.removeProfile.detail",
                    defaultValue: """
                        Go to Settings → General → VPN & Device Management → TunnelVision \
                        certificate → Remove Profile. Nothing can be decrypted in the meantime — \
                        the private key is already gone from this device.
                        """,
                    comment: """
                        The step left after the private key was deleted. The path and 'Remove \
                        Profile' are iOS's own words and must match what the device shows in this \
                        language; 'TunnelVision certificate' is the profile's name and is ours. The \
                        clause after the dash says the user is not exposed while the profile is \
                        still installed, and is the reason this can be left for later.
                        """
                )
            ),
        ]
    }

    /// El encabezado de esas instrucciones. Va aparte del aviso de que la clave ya no está porque son
    /// dos cosas distintas: lo que **ya** ha pasado en el dispositivo y lo que le queda por hacer al
    /// usuario fuera de la app.
    public static var removalGuidanceTitle: String {
        String(
            localized: "certificateSetup.guidance.removal.title",
            defaultValue: "One step left, in iOS Settings",
            comment: """
                Heading over the instructions shown after the certificate's private key has been \
                deleted. It says how much is left and where it happens; what already happened is \
                said separately, by the notice above it, so that done and pending never blur.
                """
        )
    }

    // MARK: - La entrega del perfil

    /// La hoja que precede a la del sistema. Dice las tres cosas que no se ven en la hoja de compartir:
    /// qué hacer con el fichero (guardarlo aquí y abrirlo desde Ficheros), qué contesta iOS
    /// (*Profile Downloaded*, que **no** es "instalado") y por qué no se manda a ningún sitio.
    public static var profileHandoff: CertificateSetupHandoff {
        CertificateSetupHandoff(
            title: String(
                localized: "certificateSetup.handoff.title",
                defaultValue: "Your certificate file",
                comment: """
                    Title of the sheet shown just before the system share sheet, where the \
                    certificate file is handed over. It names the thing being handed over, because \
                    the system sheet that follows says nothing about what it is carrying.
                    """
            ),
            message: String(
                localized: "certificateSetup.handoff.message",
                defaultValue: """
                    Choose Save to Files and pick any folder on this device. Then open the file \
                    from the Files app: iOS answers with “Profile Downloaded”, which means it is \
                    ready to install, not installed — the install itself happens in Settings, in \
                    the steps below.
                    """,
                comment: """
                    Body of the profile handoff sheet. 'Save to Files', the Files app and iOS's \
                    'Profile Downloaded' answer are the system's own words and must match what the \
                    device shows in this language. The 'ready to install, not installed' \
                    distinction is the point of the whole sentence: reading it as 'installed' \
                    leaves the user waiting for something that already happened, without doing the \
                    step that is missing.
                    """
            ),
            warning: String(
                localized: "certificateSetup.handoff.warning",
                defaultValue: """
                    Keep this file on this device. It holds the certificate itself — never its \
                    private key, which cannot leave this device's keychain — and any device that \
                    installs it would start trusting certificates TunnelVision creates here.
                    """,
                comment: """
                    Warning on the profile handoff sheet. This is the one moment a file of ours can \
                    leave the device, and the system share sheet does not tell saving to Files \
                    apart from sending it elsewhere. All three parts are needed: what to do, what \
                    the file does and does not contain, and the reason — a prohibition without a \
                    reason is the kind users skip. 'Keychain' is the system's own name for where \
                    the key stays.
                    """
            ),
            shareTitle: String(
                localized: "certificateSetup.handoff.share",
                defaultValue: "Save the certificate",
                comment: """
                    Button that opens the system share sheet from the profile handoff sheet. It is \
                    worded as saving rather than sharing, because saving to Files is the only thing \
                    that should be done with this file.
                    """
            )
        )
    }

    // MARK: - La pantalla

    /// El título de la pantalla. Es **su propia clave** aunque hoy diga lo mismo que la sección de
    /// Ajustes desde la que se llega: son dos sitios distintos —una cabecera de lista y el título de
    /// una pantalla— y un idioma puede necesitar acortar uno sin tocar el otro. Es el mismo criterio
    /// por el que *Look inside secure traffic* no se funde con la fila que lleva aquí.
    public static var screenTitle: String {
        String(
            localized: "certificateSetup.screen.title",
            defaultValue: "Secure traffic",
            comment: """
                Navigation title of the certificate flow screen. 'Secure traffic' is the product's \
                plain-language name for HTTPS, used wherever encryption is talked about without \
                naming the protocol. It sits in a navigation bar, so it has to stay short.
                """
        )
    }

    // MARK: - Las dos acciones destructivas

    /// El rótulo de la acción, que no es el del botón que la confirma: aquí se **pide**, y en la
    /// confirmación se acepta después de leer lo que cuesta.
    public static var regenerateActionTitle: String {
        String(
            localized: "certificateSetup.manage.regenerate",
            defaultValue: "Create a new certificate",
            comment: """
                Row that asks to replace the certificate on this device. It only opens a \
                confirmation, so it must not sound like the deed is done; the button that carries \
                it out is a separate, shorter key.
                """
        )
    }

    public static var removeActionTitle: String {
        String(
            localized: "certificateSetup.manage.remove",
            defaultValue: "Remove certificate from this device",
            comment: """
                Row that asks to delete the certificate. 'From this device' is load-bearing: it is \
                the private key stored here that goes, and the user still has to remove the profile \
                in iOS Settings afterwards.
                """
        )
    }

    /// Lo que agrupa a las dos. Se dice que la primera reemplaza y la segunda borra, porque desde
    /// fuera las dos se leen como "empezar de cero".
    public static var manageFooter: String {
        String(
            localized: "certificateSetup.manage.footer",
            defaultValue: """
                Creating a new certificate replaces the one on this device; removing it deletes its \
                private key. Neither touches your history or your captures.
                """,
            comment: """
                Footer under the two destructive rows of the certificate flow. From outside both \
                read as 'start over', so the two verbs must stay distinct (replace vs delete), and \
                what neither one touches has to be named.
                """
        )
    }

    // MARK: - Confirmaciones

    /// Rehacer la CA. No es "generar otra vez": el certificado que el usuario instaló y confió deja de
    /// firmar nada en cuanto la clave raíz cambia, así que hay que nombrarlo antes.
    public static var regenerate: CertificateSetupConfirmation {
        CertificateSetupConfirmation(
            kind: .regenerate,
            title: String(
                localized: "certificateSetup.confirm.regenerate.title",
                defaultValue: "Create a new certificate?",
                comment: """
                    Title of the confirmation for replacing the certificate. A question because it \
                    can still be cancelled.
                    """
            ),
            message: String(
                localized: "certificateSetup.confirm.regenerate.message",
                defaultValue: """
                    The certificate you already installed stops working, and you'll have to install \
                    and trust the new one before secure traffic can be inspected again. Inspection \
                    is turned off while you do.
                    """,
                comment: """
                    Body of the confirmation for replacing the certificate. It names the cost before \
                    it is paid: the certificate already installed and trusted stops working, and the \
                    two manual steps in iOS Settings have to be done again.
                    """
            ),
            confirmTitle: String(
                localized: "certificateSetup.confirm.regenerate.confirm",
                defaultValue: "Create new certificate",
                comment: """
                    Button that carries out the replacement. It names the action rather than \
                    agreeing ('OK' would leave the user confirming they read something).
                    """
            )
        )
    }

    /// Quitar la CA del dispositivo.
    public static var remove: CertificateSetupConfirmation {
        CertificateSetupConfirmation(
            kind: .remove,
            title: String(
                localized: "certificateSetup.confirm.remove.title",
                defaultValue: "Remove your certificate?",
                comment: "Title of the confirmation for deleting the certificate."
            ),
            message: String(
                localized: "certificateSetup.confirm.remove.message",
                defaultValue: """
                    Inspection is turned off and the certificate's private key is deleted from this \
                    device, so nothing can be decrypted any more. You'll then be shown how to remove \
                    the profile from iOS Settings. Your history and captures are not touched, and \
                    you can create a new certificate whenever you want.
                    """,
                comment: """
                    Body of the confirmation for deleting the certificate. Four things, all needed: \
                    what happens now, that one step in iOS Settings is left afterwards, what is not \
                    touched (history and captures), and that the decision can be taken again.
                    """
            ),
            confirmTitle: String(
                localized: "certificateSetup.confirm.remove.confirm",
                defaultValue: "Remove certificate",
                comment: "Button that carries out the deletion of the certificate."
            )
        )
    }

    // MARK: - Avisos

    public static var certificateCreated: CertificateSetupNotice {
        CertificateSetupNotice(
            message: String(
                localized: "certificateSetup.notice.certificateCreated",
                defaultValue: "Your certificate is ready. Two steps in iOS Settings and you're done.",
                comment: """
                    Shown right after the certificate is created. It says how much is left, because \
                    the work that remains happens outside the app and would otherwise be a surprise.
                    """
            ),
            role: .accent
        )
    }

    public static func generationFailed(_ detail: String) -> CertificateSetupNotice {
        CertificateSetupNotice(
            message: String(
                localized: "certificateSetup.notice.generationFailed",
                defaultValue: "The certificate couldn't be created, so nothing on this device has changed.",
                comment: """
                    Shown when creating the certificate failed. The second half is the reassurance \
                    that matters: a half-created certificate would be the frightening reading.
                    """
            ),
            diagnostic: detail,
            role: .warning
        )
    }

    public static func profileUnavailable(_ detail: String) -> CertificateSetupNotice {
        CertificateSetupNotice(
            message: String(
                localized: "certificateSetup.notice.profileUnavailable",
                defaultValue: "The certificate file couldn't be prepared, so there's nothing to install yet.",
                comment: """
                    Shown when the file that carries the certificate to iOS could not be written. \
                    The certificate itself is unaffected — only the file handed over is missing.
                    """
            ),
            diagnostic: detail,
            role: .warning
        )
    }

    /// La CA desapareció entre una comprobación y la siguiente (otra sesión la rehizo, o el llavero
    /// dejó de responder). No es una avería del gesto: es que ya no hay qué entregar.
    public static var certificateMissing: CertificateSetupNotice {
        CertificateSetupNotice(
            message: String(
                localized: "certificateSetup.notice.certificateMissing",
                defaultValue: "There's no certificate on this device any more, so there's nothing to install.",
                comment: """
                    Shown when the certificate disappeared between one check and the next. It states \
                    a fact rather than reporting a failure: the action did not break, its subject is \
                    simply gone.
                    """
            ),
            role: .neutral
        )
    }

    /// Comprobar y que siga sin confiar **no es un fallo**: es el estado normal entre el paso 2 y el
    /// paso 3, y llamarlo error empujaría al usuario a rehacer lo que ya hizo bien.
    public static var stillNotTrusted: CertificateSetupNotice {
        CertificateSetupNotice(
            message: String(
                localized: "certificateSetup.notice.stillNotTrusted",
                defaultValue: """
                    iOS still doesn't trust this certificate. Both steps have to be finished — \
                    turning on full trust in Settings → General → About is the one that's easy to \
                    miss.
                    """,
                comment: """
                    Shown when the check ran and the system still does not trust the certificate. \
                    This is the normal state between the two manual steps, so it must not read as an \
                    error: calling it one would push the user to redo what they already did right. \
                    The Settings path must match iOS's own wording in this language.
                    """
            ),
            role: .neutral
        )
    }

    /// El caso que se puede nombrar desde el 2026-08-15: el certificado **está instalado** y lo que
    /// falta es el interruptor de confianza plena, que en iOS es un gesto aparte y en otra pantalla.
    ///
    /// Es el aviso que más trabajo ahorra de toda la pantalla, y por eso no comparte texto con
    /// `stillNotTrusted`: mandar a repetir la instalación a quien ya instaló es lo que hace que la
    /// gente abandone aquí. Se sabe cuál de los dos es porque se hacen **dos** preguntas al sistema
    /// (`TrustProbe`), no una.
    public static var installedButNotFullyTrusted: CertificateSetupNotice {
        CertificateSetupNotice(
            message: String(
                localized: "certificateSetup.notice.installedButNotFullyTrusted",
                defaultValue: """
                    The certificate is installed — one switch left. In Settings → General → About → \
                    Certificate Trust Settings, turn it on for TunnelVision.
                    """,
                comment: """
                    Shown when the check finds the root installed but not enabled for TLS. It must \
                    open by crediting what the user already did: the whole point of this notice is \
                    that they do not redo the installation. The Settings path must match iOS's own \
                    wording in this language.
                    """
            ),
            role: .neutral
        )
    }

    public static var nowTrusted: CertificateSetupNotice {
        CertificateSetupNotice(
            message: String(
                localized: "certificateSetup.notice.nowTrusted",
                defaultValue: "iOS trusts your certificate. Inspection can be turned on now.",
                comment: """
                    Shown when the check finds the certificate trusted. 'Can be' on purpose: nothing \
                    has been turned on yet, that is still the user's decision.
                    """
            ),
            role: .accent
        )
    }

    public static var inspectionTurnedOn: CertificateSetupNotice {
        CertificateSetupNotice(
            message: String(
                localized: "certificateSetup.notice.inspectionTurnedOn",
                defaultValue: "Inspection is on. Your own HTTPS traffic is decrypted; pinned apps stay private.",
                comment: """
                    Shown once inspection has been turned on. It names the limit in the same breath \
                    as the capability, so the first pinned app that stays opaque reads as expected.
                    """
            ),
            role: .accent
        )
    }

    /// Guardado, pero la sesión en curso no lo cogió. Se dicen las dos cosas, como en Ajustes: tragarse
    /// el fallo dejaría al usuario creyendo que ya está viendo dentro de sus conexiones.
    public static func inspectionOnButNotLive(_ detail: String) -> CertificateSetupNotice {
        CertificateSetupNotice(
            message: String(
                localized: "certificateSetup.notice.inspectionOnButNotLive",
                defaultValue: """
                    Inspection is saved as on, but monitoring didn't take the change — it applies \
                    the next time you start monitoring.
                    """,
                comment: """
                    Shown when the setting was saved but the running capture session did not pick it \
                    up. Both halves are needed: swallowing the second would leave the user believing \
                    they are already seeing inside their connections.
                    """
            ),
            diagnostic: detail,
            role: .warning
        )
    }

    public static var certificateRemoved: CertificateSetupNotice {
        CertificateSetupNotice(
            message: String(
                localized: "certificateSetup.notice.certificateRemoved",
                defaultValue: "The certificate's private key has been deleted from this device.",
                comment: """
                    Shown after the private key is deleted. It reports only what already happened — \
                    the step the user still has to take in iOS Settings is headed separately, so \
                    that what is done and what is left never blur together.
                    """
            ),
            role: .accent
        )
    }

    /// Lo que se confirmó ya no se puede hacer: entre pedir la confirmación y aceptarla dejó de
    /// constar que hubiera una CA en este dispositivo.
    ///
    /// **Existe porque callarse era el defecto.** Las dos acciones destructivas comprobaban la regla
    /// otra vez al aceptar —bien— y, si ya no se cumplía, **se salían sin decir nada**: el usuario
    /// confirmaba algo irreversible y la pantalla se quedaba igual, que es indistinguible de una app
    /// rota. Es la misma regla que gobierna el resto del producto: una acción que no se hace tiene que
    /// decir por qué.
    ///
    /// No nombra cuál de las dos era: desde fuera las dos se leen como "hacer algo con mi
    /// certificado", y lo que hay que contar es que **no había nada sobre lo que actuar** y que la
    /// pantalla ya está al día.
    public static var nothingToChange: CertificateSetupNotice {
        CertificateSetupNotice(
            message: String(
                localized: "certificateSetup.notice.nothingToChange",
                defaultValue: """
                    Nothing was changed: there is no longer a certificate on this device. \
                    This screen is up to date now.
                    """,
                comment: """
                    Shown when a confirmed action could no longer be carried out because the \
                    certificate stopped being there between asking and confirming. It says that \
                    nothing happened and that the screen has caught up, rather than leaving a \
                    confirmed destructive action with no visible result at all.
                    """
            ),
            role: .warning
        )
    }

    public static func removalFailed(_ detail: String) -> CertificateSetupNotice {
        CertificateSetupNotice(
            message: String(
                localized: "certificateSetup.notice.removalFailed",
                defaultValue: "The certificate couldn't be removed, so it's still on this device.",
                comment: """
                    Shown when deleting the certificate failed. It says where that leaves things, \
                    because a removal that half happened is the reading to rule out.
                    """
            ),
            diagnostic: detail,
            role: .warning
        )
    }

    /// El caso que aborta: no se pudo apagar la inspección, así que **no se toca la CA**. Dejar el
    /// ajuste encendido con una raíz que ya no vale es lo único que rompe tráfico que hoy funciona.
    public static func inspectionCouldNotBeTurnedOff(_ detail: String?) -> CertificateSetupNotice {
        CertificateSetupNotice(
            message: String(
                localized: "certificateSetup.notice.inspectionCouldNotBeTurnedOff",
                defaultValue: """
                    Inspection couldn't be turned off, so your certificate was left exactly as it \
                    was — changing it while inspection is on would break the connections it's \
                    decrypting.
                    """,
                comment: """
                    Shown when a destructive action was abandoned because inspection could not be \
                    turned off first. It must say both that nothing was touched and why that is the \
                    safe outcome, or it reads as a failure that left things half done.
                    """
            ),
            diagnostic: detail,
            role: .warning
        )
    }

    public static func inspectionCouldNotBeTurnedOn(_ detail: String?) -> CertificateSetupNotice {
        CertificateSetupNotice(
            message: String(
                localized: "certificateSetup.notice.inspectionCouldNotBeTurnedOn",
                defaultValue: "Inspection couldn't be turned on, so it stays off and traffic is recorded as it is.",
                comment: """
                    Shown when turning inspection on failed. It names the state the user is left in, \
                    which is the product's default: traffic is still recorded, just not decrypted.
                    """
            ),
            diagnostic: detail,
            role: .warning
        )
    }
}

/// Las reglas del flujo: dónde está el usuario y qué se le puede ofrecer.
public enum CertificateSetupPolicy {

    /// La etapa que toca.
    ///
    /// El paso 0 **solo se interpone delante de crear**. Con una CA ya generada la explicación ya se
    /// leyó (no hay otra forma de haber llegado ahí), así que volver a exigirla sería insistir; y con
    /// el llavero ilegible no hay nada que explicar todavía, porque no se sabe qué se está mirando.
    public static func stage(
        for status: CertificateStatus,
        tradeOffAcknowledged: Bool
    ) -> CertificateSetupStage {
        switch status.authority {
        case .unknown(let diagnostic):
            return .unavailable(diagnostic)
        case .generated(.trusted):
            return .ready
        case .generated(.installedWithoutFullTrust), .generated(.notTrusted), .generated(.cannotEvaluate):
            // La duda cierra: una confianza que no se pudo evaluar no es confianza, así que el flujo
            // sigue enseñando lo que queda por hacer en vez de dar por bueno el otro lado. Los tres
            // caen en la misma **etapa** a propósito —lo que queda por hacer está ahí—; lo que separa
            // al primero es el aviso, que nombra el interruptor concreto en vez de los dos pasos.
            return .installAndTrust
        case .notGenerated:
            return tradeOffAcknowledged ? .generate : .explainTradeOff
        }
    }

    /// Si se puede ofrecer **rehacer** la CA. Solo con una que consta que existe: es una acción
    /// destructiva, y ofrecerla sobre un llavero que no se dejó mirar la convertiría en una forma de
    /// borrar a ciegas la CA del usuario.
    public static func canRegenerate(_ status: CertificateStatus) -> Bool {
        switch status.authority {
        case .generated: return true
        case .notGenerated, .unknown: return false
        }
    }

    /// Si se puede ofrecer **quitarla**. Mismo criterio: quitar lo que no consta que exista solo puede
    /// terminar en un gesto que dice haber hecho algo que no hizo.
    public static func canRemove(_ status: CertificateStatus) -> Bool {
        canRegenerate(status)
    }
}
