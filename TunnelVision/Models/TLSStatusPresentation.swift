import Foundation
import Shared

/// Cómo se enseña el estado de inspección de una conexión: **icono + etiqueta + color**, nunca color
/// solo (`docs/ux/design-system.md`, principio 6 de `docs/ux/00-ux-principles.md`).
///
/// Es un valor puro por lo mismo que `MonitoringPresentation`: la copia de los cuatro estados es
/// donde el producto se juega la confianza del usuario —sobre todo la de `notInspectable`, que
/// `docs/ux/screens.md` pide convertir de limitación en señal de confianza—, y como valor se puede
/// afirmar en un test en vez de revisarla a ojo.
public struct TLSStatusPresentation: Sendable, Equatable {

    /// La etiqueta del badge, corta y sin jerga (principio 3: nada de "MITM" ni "TLS termination").
    public let label: String

    /// Una frase explicando qué implica ese estado para el usuario. La lee VoiceOver junto a la
    /// etiqueta y es la que usará el Flow Inspector como explicación de cabecera.
    public let detail: String

    public let systemImage: String
    public let role: StatusRole

    public init(label: String, detail: String, systemImage: String, role: StatusRole) {
        self.label = label
        self.detail = detail
        self.systemImage = systemImage
        self.role = role
    }

    /// Lo que VoiceOver lee de un badge: la etiqueta sola no dice nada (principio 6).
    ///
    /// La frase se compone **aquí y por el catálogo** —no concatenando en la vista— porque el
    /// separador y el orden de las dos mitades son propiedad de un idioma, y un `Text` de SwiftUI es
    /// donde ningún traductor llega. Es el mismo movimiento que hizo `CertificateSetupStep`.
    public var accessibilityDescription: String {
        String(
            localized: "flow.tlsStatus.accessibilityDescription",
            defaultValue: "\(label). \(detail)",
            comment: """
                What VoiceOver reads of an encryption badge: the short label followed by the \
                sentence explaining what it means for the user. First placeholder is the label, \
                second the explanation. The label alone would not say whether it is good or bad.
                """
        )
    }

    /// Los cuatro estados en el orden en que se ofrecen al usuario: de menos a más protegido, que es
    /// como se leen. `TLSInspectionStatus` no es `CaseIterable` (vive en `Shared`, donde el orden de
    /// presentación no significa nada), así que el orden lo fija quien lo enseña.
    public static let allStatuses: [TLSInspectionStatus] = [
        .plaintext, .encrypted, .inspected, .notInspectable
    ]

    public static func forStatus(_ status: TLSInspectionStatus) -> TLSStatusPresentation {
        switch status {
        case .plaintext:
            return TLSStatusPresentation(
                label: String(
                    localized: "flow.tlsStatus.plaintext.label",
                    defaultValue: "Not encrypted",
                    comment: """
                        Badge on a connection that carried no encryption at all. It is a warning \
                        about the connection, never about the app: nothing went wrong here, this \
                        is simply what the connection did.
                        """
                ),
                detail: String(
                    localized: "flow.tlsStatus.plaintext.detail",
                    defaultValue: "Anything sent over this connection travels in the clear.",
                    comment: """
                        What the 'not encrypted' badge means for the user. 'In the clear' is the \
                        plain-language form; avoid jargon such as 'plaintext' or 'unencrypted TLS'.
                        """
                ),
                systemImage: "lock.open",
                role: .plaintext
            )

        case .encrypted:
            return TLSStatusPresentation(
                label: String(
                    localized: "flow.tlsStatus.encrypted.label",
                    defaultValue: "Encrypted",
                    comment: """
                        Badge on a connection that was encrypted and was not looked inside. This \
                        is the ordinary case and must not read as a limitation.
                        """
                ),
                detail: String(
                    localized: "flow.tlsStatus.encrypted.detail",
                    defaultValue: "TunnelVision sees who this device talked to, not what was said.",
                    comment: """
                        What the 'encrypted' badge means for the user: the app recorded the \
                        destination and the amounts, not the contents. 'TunnelVision' is the \
                        product name and stays as it is.
                        """
                ),
                systemImage: "lock",
                role: .encrypted
            )

        case .inspected:
            return TLSStatusPresentation(
                label: String(
                    localized: "flow.tlsStatus.inspected.label",
                    defaultValue: "Inspected",
                    comment: """
                        Badge on a connection that was decrypted because the user opted in and \
                        installed the certificate themselves.
                        """
                ),
                detail: String(
                    localized: "flow.tlsStatus.inspected.detail",
                    defaultValue: "Decrypted with the certificate you installed, on this device only.",
                    comment: """
                        What the 'inspected' badge means. Two load-bearing facts: the user did \
                        this deliberately ('you installed'), and nothing left the device.
                        """
                ),
                systemImage: "eye",
                role: .inspected
            )

        case .notInspectable:
            // El caso que más importa: no es un fallo ni algo por reintentar. La app **decide** no
            // tocarlo (ADR 0003), y decirlo así es lo que convierte el límite en confianza.
            return TLSStatusPresentation(
                label: String(
                    localized: "flow.tlsStatus.notInspectable.label",
                    defaultValue: "Kept private",
                    comment: """
                        Badge on a connection whose app pins its certificates, so TunnelVision \
                        relayed it untouched. The most important label on this screen: it must \
                        read as a guarantee the app makes, never as a failure or as something to \
                        retry. Do not translate it as 'could not be inspected'.
                        """
                ),
                detail: String(
                    localized: "flow.tlsStatus.notInspectable.detail",
                    defaultValue: "This app checks its own certificate, so its content stays private.",
                    comment: """
                        Why a pinned connection stays private. 'This app' is the other app on the \
                        device, not TunnelVision. It states the other app's protection as the \
                        reason, which is what turns a limit into trust.
                        """
                ),
                systemImage: "lock.shield",
                role: .notInspectable
            )
        }
    }
}

/// Cuánto se enseña del estado de cifrado **en una fila de lista**, que es donde se repite doscientas
/// veces seguidas.
///
/// Es un valor y no un detalle de dibujo por lo mismo que `MonitoringProminence` en la Dashboard:
/// cuánto sitio merece algo en la pantalla es una decisión que se puede afirmar en un test, y así un
/// estado nuevo tiene que **elegir** su peso en vez de heredar el del vecino.
public enum TLSStatusEmphasis: Sendable, Equatable {

    /// Solo la marca: el símbolo del estado, en su color, en el carril de la fila.
    case mark

    /// La marca y la palabra.
    case named
}

extension TLSStatusPresentation {

    /// Cuánto se enseña del estado en una fila del historial.
    ///
    /// La regla es de **jerarquía y no de frecuencia**: `encrypted` es la lectura por defecto de la
    /// lista —lo que este producto promete de toda conexión que no diga otra cosa—, así que escribir
    /// *Encrypted* en cada fila gasta el elemento más contrastado de la fila en repetir lo que ya se
    /// da por supuesto, y el ojo aterriza en el dato que menos informa. Los otros tres son
    /// **desviaciones** de esa promesa —nadie la protegió, la miramos por dentro, la protegió otra
    /// app— y una desviación se escribe con palabras.
    ///
    /// La marca **no desaparece nunca**: el estado se sigue diciendo con forma y con color en las
    /// cuatro filas, así que ninguna deja el dato en manos de una ausencia — que es lo que haría
    /// ilegible la diferencia entre "cifrada" y "no se sabe".
    ///
    /// A tamaños de accesibilidad se nombran los cuatro, y no por generosidad: ahí el carril no
    /// sobrevive —un símbolo en la curva del titular a AX5 se lleva el ancho que necesita el host—, y
    /// sin carril la marca no tiene dónde ir. La palabra es lo que queda.
    public static func emphasis(
        for status: TLSInspectionStatus,
        isAccessibilitySize: Bool
    ) -> TLSStatusEmphasis {
        guard !isAccessibilitySize else { return .named }

        switch status {
        case .encrypted:
            return .mark
        case .plaintext, .inspected, .notInspectable:
            return .named
        }
    }
}
