import Foundation

/// La copia de una hoja de explicación previa a un diálogo del sistema.
///
/// Existe por una regla dura de `docs/ux/onboarding-and-consent.md` —**explicar antes, nunca
/// después**, y ofrecer siempre un camino para no hacerlo—, y es un valor puro precisamente por eso:
/// que la hoja tenga siempre las dos salidas es una afirmación de un test, no algo que haya que
/// comprobar a ojo. La vista que la pinta (`ConsentSheet`) no decide ni compone nada.
public struct ConsentPresentation: Sendable, Equatable {

    /// El titular de la hoja, que dice **qué va a pasar** y no qué es esto.
    public let title: String

    /// La explicación. Es lo único que el usuario tiene para decidir, así que dice qué hará el
    /// sistema, qué no hace la app y cómo se deshace.
    public let message: String

    /// El botón que sigue adelante.
    public let confirmTitle: String

    /// La salida. **Nunca es opcional**: una hoja de consentimiento con un solo botón incumple la
    /// regla aunque el botón no haga nada irreversible.
    public let cancelTitle: String

    public init(title: String, message: String, confirmTitle: String, cancelTitle: String) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.cancelTitle = cancelTitle
    }

    /// La hoja que precede al permiso de VPN, con la copia de `docs/ux/onboarding-and-consent.md`.
    ///
    /// Es la única de la app hoy, y la que más se juega: es el momento en que iOS va a pedir añadir
    /// una configuración de VPN, que es lo que más se parece a una alarma en todo el producto. Por eso
    /// la explicación nombra las tres cosas que responden al susto — la VPN es local, iOS enseñará su
    /// icono, y esto se para cuando se quiera — antes de que el diálogo del sistema aparezca.
    public static var vpnPermission: ConsentPresentation {
        ConsentPresentation(
            title: String(
                localized: "consent.vpnPermission.title",
                defaultValue: "Before iOS asks",
                comment: """
                    Title of the sheet shown immediately before the system's own VPN permission \
                    dialog. It must place itself in time — this comes first — because the whole \
                    point is that the system prompt never appears unexplained.
                    """
            ),
            message: String(
                localized: "consent.vpnPermission.message",
                defaultValue: """
                    iOS will now ask permission to add a VPN configuration.

                    This VPN is local: your traffic is not sent to us or anyone else. It is what lets \
                    TunnelVision watch your connections on this device.

                    While monitoring is on, iOS shows a VPN icon in the status bar. You can stop \
                    monitoring at any time.
                    """,
                comment: """
                    Body of the sheet preceding the system VPN permission dialog. Three claims are \
                    load-bearing and none may be dropped in translation: the VPN is local and \
                    uploads nothing, iOS will show a VPN icon in the status bar, and monitoring can \
                    be stopped at any time. 'VPN' is the system's own word here, not jargon.
                    """
            ),
            confirmTitle: String(
                localized: "consent.vpnPermission.confirm",
                defaultValue: "Continue",
                comment: """
                    Button that dismisses the explanation and lets the system prompt appear. It \
                    grants nothing by itself: the permission is given in the system dialog.
                    """
            ),
            cancelTitle: String(
                localized: "consent.vpnPermission.cancel",
                defaultValue: "Not now",
                comment: """
                    Way out of the consent sheet. 'Not now' rather than 'Cancel': nothing is being \
                    interrupted, the user is deciding not to start monitoring yet.
                    """
            )
        )
    }
}
