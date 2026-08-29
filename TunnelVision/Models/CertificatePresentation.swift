import Foundation
import Shared

/// Qué sabe la app de la CA local, y qué se puede afirmar con ello (M10,
/// `docs/ux/onboarding-and-consent.md`).
///
/// Mirar dentro del tráfico cifrado exige dos hechos independientes que viven en dos sitios
/// distintos: que **exista** una CA local (una clave raíz en el llavero compartido) y que el sistema
/// **confíe** en su certificado raíz (el usuario lo instaló y le dio confianza plena en los Ajustes de
/// iOS, pasos 2 y 3 del flujo guiado). Ninguno de los dos es una preferencia guardada, así que ninguno
/// se lee de `AppSettings`: se preguntan, y se preguntan **cada vez**.

/// Lo que se sabe de la CA local en el instante en que se preguntó.
///
/// No lleva sello de cuándo se supo **a propósito**: no se publica, no se cachea y no se guarda en
/// ningún sitio, así que solo existe recién preguntado. Un estado con fecha invitaría a conservarlo, y
/// un estado de la CA conservado es exactamente lo que no se puede afirmar: el usuario puede retirar
/// la confianza del certificado desde los Ajustes de iOS entre dos preguntas sin que la app se entere.
public struct CertificateStatus: Sendable, Equatable {

    /// La confianza es una propiedad **de una raíz concreta**, así que cuelga de `generated` y no
    /// convive con ella en el mismo nivel: un par `(existe, confiada)` admitiría el estado imposible
    /// "no hay CA pero el sistema confía en ella", que alguien acabaría teniendo que interpretar.
    public enum Authority: Sendable, Equatable {
        /// No hay clave raíz en el llavero: el paso 1 (generar el certificado) está por hacer.
        case notGenerated
        /// Hay CA, y esto es lo que el sistema dice de su raíz **ahora mismo**.
        case generated(SystemTrust)
        /// No se pudo mirar el llavero. Se distingue de `notGenerated` porque "no hay CA" es una
        /// afirmación, y ofrecerle generar una a quien ya tiene la suya instalada y confiada la
        /// **reemplazaría** — el certificado que instaló dejaría de valer sin que nadie se lo dijera.
        case unknown(String)
    }

    /// Qué dice el sistema del certificado raíz de la CA.
    ///
    /// Los tres primeros casos salen de **dos** preguntas distintas y no de una (`TrustProbe`): si el
    /// sistema aceptaría un leaf de esta CA en un handshake TLS, y —solo si la respuesta es que no—
    /// si al menos ancla la raíz para X.509 básico. Esa segunda pregunta es la que separa el paso que
    /// falta, y hasta el 2026-08-15 era la **única** que se hacía, lo que daba un falso positivo.
    public enum SystemTrust: Sendable, Equatable {
        /// El sistema aceptaría un certificado de esta CA en una conexión TLS: los pasos 2 y 3 están
        /// hechos. Es la única respuesta con la que se puede encender la inspección.
        case trusted
        /// **La raíz está en el almacén, pero no habilitada para TLS**: falta el interruptor de
        /// *Ajustes › General › Información › Ajustes de confianza de certificados*, que en iOS es un
        /// gesto aparte de instalar el perfil.
        ///
        /// Se distingue desde el 2026-08-15, y no es un matiz: es la diferencia entre decirle al
        /// usuario "instala el certificado" —que ya lo hizo— y decirle exactamente qué interruptor le
        /// falta. Este documento afirmaba que los dos casos eran indistinguibles; lo eran porque solo
        /// se hacía una pregunta.
        case installedWithoutFullTrust
        /// El sistema no ancla esa raíz de ninguna forma. Lo normal es que no esté instalada, pero
        /// también da esto una raíz caducada o una que el usuario retiró: lo que se afirma es lo
        /// observado —que no hay ancla—, no la causa.
        case notTrusted
        /// La evaluación no se pudo llevar a cabo (la raíz no se deja leer como certificado, o
        /// `Security` no llegó a construir la confianza). No es "no confía": es "no lo sé".
        case cannotEvaluate(String)
    }

    public let authority: Authority

    public init(authority: Authority) {
        self.authority = authority
    }

    public static let notGenerated = CertificateStatus(authority: .notGenerated)
}

/// Las reglas que convierten lo que se sabe de la CA en lo que la app puede ofrecer.
public enum CertificateStatusPolicy {

    /// Si la inspección TLS se puede **encender** ahora mismo.
    ///
    /// Solo una CA que existe y en la que el sistema confía lo permite, y las dudas se resuelven
    /// **cerrando**: encender la inspección con una raíz que el dispositivo no ancla no deja al
    /// usuario donde estaba, lo deja peor — cada handshake contra nuestro leaf fallaría y el tráfico
    /// que hoy funciona dejaría de hacerlo. Frente a eso, negarse cuando no se sabe solo mantiene el
    /// estado por defecto del producto, que es no mirar dentro de nada.
    public static func availability(_ status: CertificateStatus) -> TLSInspectionAvailability {
        switch status.authority {
        case .generated(.trusted):
            return .ready
        case .generated(.installedWithoutFullTrust), .generated(.notTrusted),
             .generated(.cannotEvaluate), .notGenerated, .unknown:
            return .certificateNotReady
        }
    }

    /// Si hay que **revocar** una inspección que ya está encendida.
    ///
    /// Es la simétrica de `availability`, y existe porque encender no es un hecho de una vez: el
    /// ajuste es duradero y la confianza no. Entre dos arranques el usuario puede retirar la confianza
    /// desde los Ajustes de iOS, o caducar la raíz, y entonces el interruptor sigue encendido
    /// gobernando una inspección que ya solo produce handshakes rechazados — que en la práctica es el
    /// dispositivo **sin navegación**, porque cada conexión al 443 se termina con un certificado que
    /// nadie acepta. Se vio en un `.pcap`: 66 de 90 conexiones cerradas por el cliente.
    ///
    /// La regla es deliberadamente asimétrica con `availability`: para **encender** hace falta un sí,
    /// y para **apagar** basta con que deje de haberlo. Un "no lo sé" apaga, porque el coste de
    /// equivocarse por cada lado no es el mismo — apagar de más cuesta dejar de mirar dentro del
    /// tráfico propio durante un rato; no apagar cuando había que hacerlo cuesta la conexión a
    /// internet del dispositivo, y sin nada en pantalla que lo explique.
    public static func mustRevokeInspection(
        availability: TLSInspectionAvailability,
        inspectionEnabled: Bool
    ) -> Bool {
        inspectionEnabled && availability != .ready
    }

    /// Si tiene sentido ofrecer **generar** una CA nueva.
    ///
    /// Se ofrece cuando consta que no hay ninguna, y no cuando no se pudo mirar: generar reemplaza la
    /// clave raíz anterior (`LocalCA.generate` borra la que hubiera con el mismo tag), así que
    /// ofrecerlo a ciegas puede tirar la CA que el usuario ya instaló y dejar su certificado instalado
    /// firmando nada. Con una CA ya generada tampoco se ofrece aquí: rehacerla es una acción destructiva
    /// y su sitio es la parte del flujo que puede explicar qué se pierde, no el primer paso.
    public static func canGenerate(_ status: CertificateStatus) -> Bool {
        switch status.authority {
        case .notGenerated:
            return true
        case .generated, .unknown:
            return false
        }
    }
}
