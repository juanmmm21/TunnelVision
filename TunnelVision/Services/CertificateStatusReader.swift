import Foundation
import Security
import Shared

/// Lo que la app sabe de la CA local: si existe y si el sistema confía en ella (M10).
///
/// Es la respuesta al cabo suelto más viejo de la pantalla de Ajustes —la disponibilidad de la
/// inspección TLS era una closure que siempre contestaba `certificateNotReady`— y el cimiento del
/// flujo guiado de instalación (`docs/ux/onboarding-and-consent.md`). Junta dos hechos que viven en
/// sitios distintos y se preguntan de formas distintas:
///
/// - **Que exista la CA** lo dice el llavero compartido, donde `LocalCA` guarda la clave raíz. No hace
///   falta IPC: app y extensión declaran el mismo grupo de acceso, así que ven los mismos items. Por
///   eso `LocalCA` vive desde M10 en `Shared` — la alternativa (que la extensión publicara su estado en
///   el contenedor del App Group) obligaba a preguntárselo a un proceso que **solo corre con el túnel
///   encendido**, y a instalar un certificado se va con la monitorización parada.
/// - **Que el sistema confíe en su raíz** lo dice `SecTrust`, y lo puede preguntar cualquier proceso
///   porque el almacén de confianza es del dispositivo. Se pregunta **en el presente**: es el dato que
///   caduca —el usuario retira la confianza desde los Ajustes de iOS cuando quiere— y por eso no se
///   publica, no se cachea y no se guarda.
///
/// Es un `actor` y no un `struct` como `SettingsStore` porque sus dos preguntas tocan el llavero y la
/// evaluación de confianza, que son trabajo con disco de fondo: awaitarlo desde el `@MainActor` de un
/// view model sale del hilo principal por construcción. No retiene nada entre llamadas: la CA se carga
/// de cero en cada pregunta, así que no hay copia que se pueda quedar vieja.
public actor CertificateStatusReader {

    /// La sonda de la CA local (leaf de prueba + raíz), o `nil` si no hay CA ninguna. Es la costura
    /// sobre el llavero: lanza cuando no se pudo mirar, que no es lo mismo que no haber nada.
    public typealias TrustProbeSource = @Sendable () async throws -> TrustProbe?

    /// Qué dice el sistema de esa sonda. Costura sobre `Security`: la respuesta afirmativa solo se
    /// puede provocar en un dispositivo con el certificado instalado y con confianza plena, así que
    /// en Simulator se sustituye por un doble (las negativas sí son reales y están probadas contra
    /// `SecTrust`).
    public typealias TrustEvaluator = @Sendable (TrustProbe) -> CertificateStatus.SystemTrust

    private let trustProbe: TrustProbeSource
    private let evaluateTrust: TrustEvaluator

    public init(
        trustProbe: @escaping TrustProbeSource,
        evaluatingTrust: @escaping TrustEvaluator = SystemCertificateTrust.evaluate
    ) {
        self.trustProbe = trustProbe
        self.evaluateTrust = evaluatingTrust
    }

    /// La construcción normal: la CA del llavero compartido.
    ///
    /// El certificado raíz se **recompone** desde la clave persistida en cada llamada (`LocalCA.load`),
    /// que es lo que hace también la extensión al arrancar. No es byte-idéntico al que el usuario
    /// instaló —serie aleatoria y vigencia dependiente del reloj—, pero sí tiene el mismo sujeto y la
    /// misma clave pública, que es por lo que el sistema empareja un ancla de confianza: si el usuario
    /// instaló y confió la raíz de esta CA, la raíz recompuesta evalúa igual (`CertificateAuthorityTests`
    /// prueba ese invariante sobre los leaves).
    public init(keychain: LocalCA.KeychainConfiguration = LocalCA.KeychainConfiguration()) {
        self.init(trustProbe: { try await LocalCA.load(keychain: keychain)?.trustProbe() })
    }

    /// Lo que se sabe de la CA ahora mismo.
    ///
    /// La confianza **solo se evalúa si hay CA**: preguntarle al sistema por un certificado que no
    /// existe no tiene respuesta que interpretar, y ahorrársela mantiene el caso caro (una evaluación
    /// de `SecTrust`) fuera del camino normal, que hoy es no tener CA ninguna.
    public func status() async -> CertificateStatus {
        do {
            guard let probe = try await trustProbe() else {
                return CertificateStatus(authority: .notGenerated)
            }
            return CertificateStatus(authority: .generated(evaluateTrust(probe)))
        } catch {
            return CertificateStatus(authority: .unknown(String(describing: error)))
        }
    }

    /// Si la inspección TLS se puede encender. Es lo que consume la pantalla de Ajustes, que no
    /// necesita el estado entero: su interruptor solo pregunta sí o no.
    public func availability() async -> TLSInspectionAvailability {
        CertificateStatusPolicy.availability(await status())
    }
}

/// La evaluación de confianza de producción: qué dice el almacén de anclas del **dispositivo** sobre
/// una raíz.
///
/// Vive aparte del lector porque es la única parte de este módulo que habla con `Security`, y separarla
/// es lo que deja el lector afirmable con un doble. Aquí la mitad negativa **sí** se prueba de verdad:
/// una raíz recién generada no está instalada, así que el sistema no la ancla, y eso es exactamente lo
/// que este código tiene que contestar.
public enum SystemCertificateTrust {

    /// Pregunta si el dispositivo aceptaría un certificado de esta CA **en una conexión TLS**, y
    /// —solo si no— si al menos ancla su raíz para X.509 básico. Son dos preguntas y ese es el punto.
    ///
    /// **La primera es la que decide.** Se evalúa la cadena de la sonda (leaf + raíz) con
    /// `SecPolicyCreateSSL`, que es la política del handshake real, y **sin anclas explícitas**: si se
    /// pasara la raíz como ancla, la respuesta sería siempre que sí —una raíz se ancla a sí misma— y
    /// la pregunta no significaría nada. Aquí el ancla tiene que salir del almacén del dispositivo,
    /// que es justo lo que se quiere saber.
    ///
    /// **La segunda solo separa el paso que falta.** Es la evaluación que este código hacía antes y
    /// que daba el falso positivo: la raíz sola con `SecPolicyCreateBasicX509`. Como **segunda**
    /// pregunta deja de mentir y pasa a informar — si la raíz ancla para lo básico pero no para TLS,
    /// está instalada y le falta el interruptor de confianza plena, y eso se le puede decir al usuario
    /// con esas palabras en vez de mandarlo a repetir la instalación.
    public static func evaluate(_ probe: TrustProbe) -> CertificateStatus.SystemTrust {
        let chain = probe.chainDER.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard chain.count == probe.chainDER.count, let root = chain.last else {
            return .cannotEvaluate("la cadena de la sonda no es DER X.509 legible")
        }

        switch anchored(chain, policy: SecPolicyCreateSSL(true, probe.host as CFString)) {
        case .unanswerable(let reason):
            return .cannotEvaluate(reason)
        case .yes:
            return .trusted
        case .no:
            break
        }

        switch anchored([root], policy: SecPolicyCreateBasicX509()) {
        case .unanswerable(let reason):
            return .cannotEvaluate(reason)
        case .yes:
            return .installedWithoutFullTrust
        case .no:
            return .notTrusted
        }
    }

    /// La respuesta a "¿ancla el sistema esta cadena bajo esta política?". `unanswerable` es "no se
    /// pudo preguntar", que no es lo mismo que "no" — y confundirlos es lo que convierte una avería
    /// de `Security` en una negativa que el usuario intentaría arreglar instalando cosas.
    private enum Anchoring {
        case yes
        case no
        case unanswerable(String)
    }

    private static func anchored(_ chain: [SecCertificate], policy: SecPolicy) -> Anchoring {
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(chain as CFArray, policy, &trust)
        guard status == errSecSuccess, let trust else {
            return .unanswerable("SecTrustCreateWithCertificates: \(status)")
        }

        // Sin fetch de red: la cadena viaja entera y su emisor es local, así que no hay nada que
        // descargar, y dejarlo activo convertiría una pregunta local en una que puede tardar lo que
        // tarde la red o fallar por estar sin cobertura.
        SecTrustSetNetworkFetchAllowed(trust, false)

        return SecTrustEvaluateWithError(trust, nil) ? .yes : .no
    }
}
