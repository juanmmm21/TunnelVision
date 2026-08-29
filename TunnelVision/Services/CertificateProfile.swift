import Foundation

/// Cómo se le entrega a iOS el certificado raíz de la CA local (M10, pasos 2 y 3 de
/// `docs/ux/onboarding-and-consent.md`).
///
/// Es la única incógnita **técnica** que quedaba del flujo guiado, y se decide aquí porque cambia el
/// número de pasos que la pantalla tiene que enseñar: iOS no ofrece ninguna API para instalar un ancla
/// de confianza —eso es a propósito, y ADR 0003 dice por qué está bien que lo sea—, así que el
/// certificado tiene que salir de la app como un fichero que el usuario abre. Las dos formas posibles
/// eran un `.cer` pelado y un **perfil de configuración** (`.mobileconfig`), y gana el segundo:
///
/// - **El flujo que la spec describe es el de un perfil.** "Profile Downloaded" y *Ajustes → General →
///   VPN y gestión de dispositivos* son la interfaz de los perfiles; con un `.cer` suelto, la copia de
///   los pasos 2 y 3 estaría describiendo una pantalla que el usuario no tiene delante.
/// - **Un perfil se presenta con nombre y explicación.** Lo que iOS le pide al usuario que instale
///   lleva `PayloadDisplayName` y `PayloadDescription`, así que dice *TunnelVision* y para qué es, en
///   vez de un sujeto X.509 y una huella hexadecimal que no significan nada fuera de este documento.
/// - **Un perfil se puede quitar entero desde Ajustes**, que es la mitad de la reversibilidad que no
///   vive en el llavero (`LocalCA.removeFromKeychain` se lleva la clave; el ancla instalada la retira
///   el usuario, y este es el objeto que iOS le enseña para hacerlo).

/// El perfil listo para entregar: los bytes y el nombre con el que se comparte.
public struct ConfigurationProfile: Sendable, Equatable {

    /// Nombre del fichero. La extensión `.mobileconfig` es lo que hace que iOS lo trate como un perfil
    /// al abrirlo, en vez de como un documento cualquiera.
    public let fileName: String

    /// El plist XML del perfil.
    public let data: Data

    public init(fileName: String, data: Data) {
        self.fileName = fileName
        self.data = data
    }
}

public enum CertificateProfileError: Error, Sendable, Equatable {
    /// No hay certificado que meter dentro. Un perfil con un ancla vacía se instala igual y no ancla
    /// nada, así que es peor que no ofrecerlo: el usuario haría los tres pasos y seguiría sin poder
    /// encender la inspección, sin nada que se lo explicase.
    case emptyCertificate
    /// El plist no se pudo serializar.
    case serializationFailed(String)
    /// El fichero no se pudo escribir (directorio irresoluble, disco lleno, permisos).
    case writeFailed(String)
}

/// Construye el perfil de configuración que instala la raíz de la CA local como ancla de confianza.
public enum CertificateProfile {

    /// Nombre del fichero que se comparte.
    public static let fileName = "TunnelVision.mobileconfig"

    /// Cómo se llama el perfil en la pantalla de instalación de iOS y en *VPN y gestión de
    /// dispositivos*, que es donde el usuario lo buscará para quitarlo.
    public static let displayName = "TunnelVision certificate"

    /// Identificador y UUID **fijos**, y esa es la decisión que no es evidente.
    ///
    /// iOS identifica un perfil por estos dos valores: instalar uno con el mismo identificador
    /// **sustituye** al que hubiera, y con uno distinto lo **añade al lado**. Derivarlos del
    /// certificado (un UUID por raíz) parecería más limpio y sería justo lo contrario: al rehacer la
    /// CA, la raíz vieja se quedaría instalada y confiada para siempre junto a la nueva, y el usuario
    /// tendría dos perfiles casi iguales sin forma de saber cuál sobra. Fijos, rehacer la CA
    /// **reemplaza** el ancla anterior, que es lo que el usuario cree que está haciendo.
    public static let identifier = "com.juanmmm21.tunnelvision.ca"
    static let profileUUID = "5B0C0A4E-1C39-4C0A-9E7B-3A5E7F9D2C11"
    static let payloadIdentifier = "com.juanmmm21.tunnelvision.ca.root"
    static let payloadUUID = "9F2D6C71-84B4-4B2E-8B0A-6C1D4E5F7A22"

    /// El nombre con el que el certificado viaja **dentro** del perfil. iOS lo enseña en el detalle del
    /// perfil instalado.
    static let certificateFileName = "TunnelVision.cer"

    /// Lo que el perfil dice de sí mismo. Se escribe aquí y no en la pantalla porque esto es lo que el
    /// usuario lee **fuera** de la app, en la hoja de instalación de iOS, donde ya no hay nada nuestro
    /// que se lo explique.
    static let description = """
        Lets TunnelVision show you the contents of your own HTTPS traffic on this device. \
        The certificate is created on this device and never leaves it. Apps that pin their \
        certificates are never decrypted. Remove this profile at any time to undo it.
        """

    /// Construye el perfil a partir del certificado raíz en DER.
    ///
    /// Es **determinista**: los mismos bytes de entrada dan el mismo fichero, porque no hay UUIDs
    /// aleatorios ni fechas dentro. Eso es lo que permite afirmarlo byte a byte en un test y, sobre
    /// todo, lo que hace que reinstalar sea reinstalar y no acumular perfiles.
    ///
    /// **El perfil va sin firmar**, y no por dejadez: firmarlo exigiría un certificado en el que el
    /// dispositivo ya confiara, y el único que la app tiene es justo el que todavía no está instalado
    /// —firmar con él sería circular—. iOS lo marcará en rojo como *No firmado*, así que la pantalla lo
    /// dice **antes** (`CertificateSetupPresentation.installSteps`), que es la misma regla de "explicar
    /// antes, nunca después" del permiso de VPN.
    public static func make(rootCertificateDER der: Data) throws -> ConfigurationProfile {
        guard !der.isEmpty else { throw CertificateProfileError.emptyCertificate }

        let certificatePayload: [String: Any] = [
            "PayloadType": "com.apple.security.root",
            "PayloadVersion": 1,
            "PayloadIdentifier": payloadIdentifier,
            "PayloadUUID": payloadUUID,
            "PayloadDisplayName": displayName,
            "PayloadDescription": description,
            "PayloadCertificateFileName": certificateFileName,
            "PayloadContent": der,
        ]

        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": identifier,
            "PayloadUUID": profileUUID,
            "PayloadDisplayName": displayName,
            "PayloadDescription": description,
            "PayloadOrganization": "TunnelVision",
            // Explícito y no por omisión: que el usuario pueda quitar el perfil cuando quiera es
            // innegociable (`docs/ux/onboarding-and-consent.md`), y un perfil que no se deja borrar
            // convertiría una función opcional en algo irreversible desde dentro del propio fichero.
            "PayloadRemovalDisallowed": false,
            "PayloadContent": [certificatePayload],
        ]

        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: profile,
                format: .xml,
                options: 0
            )
            return ConfigurationProfile(fileName: fileName, data: data)
        } catch {
            throw CertificateProfileError.serializationFailed(String(describing: error))
        }
    }
}

/// Deja el perfil en disco para que el usuario lo abra (M10).
///
/// Es el mismo reparto que `FlowExporter` y por los mismos motivos: escribe en el **temporal de la
/// app** y no en el contenedor del App Group —no es una captura, y entre ellas entraría en el listado
/// de la pantalla y en los planes de retención—, y cada escritura se lleva la anterior, porque un
/// perfil obsoleto que sobreviviera al de la CA actual instalaría un ancla que ya no firma nada.
///
/// Es un `actor` por lo mismo que `CaptureLibrary`: toca disco, y el disco no se toca desde el hilo
/// principal. No retiene el directorio: lo resuelve en cada escritura, así que un fallo temprano no se
/// queda pegado a la pantalla para siempre.
public actor CertificateProfileExporter {

    private let resolveDirectory: @Sendable () throws -> URL

    /// Sobre un directorio concreto. Es lo que usan los tests, sobre un temporal.
    public init(directory: URL) {
        self.init(resolvingDirectory: { directory })
    }

    public init(resolvingDirectory: @escaping @Sendable () throws -> URL) {
        self.resolveDirectory = resolvingDirectory
    }

    /// Sobre el directorio de perfiles de la app, dentro de su temporal.
    public init() {
        self.init(resolvingDirectory: {
            FileManager.default.temporaryDirectory.appendingPathComponent("Certificate", isDirectory: true)
        })
    }

    /// Escribe el perfil y devuelve el fichero listo para compartir.
    ///
    /// La escritura es atómica: un perfil a medias no es un error visible al abrirlo, es un plist que
    /// iOS rechaza sin decir por qué, y el usuario no tendría forma de distinguirlo de un fallo suyo.
    public func write(_ profile: ConfigurationProfile) throws -> URL {
        let directory = try prepareDirectory()
        let url = directory.appendingPathComponent(profile.fileName)
        do {
            try profile.data.write(to: url, options: .atomic)
        } catch {
            throw CertificateProfileError.writeFailed(String(describing: error))
        }
        return url
    }

    /// Se lleva el perfil que hubiera escrito. La llama el flujo cuando la CA cambia: un perfil de una
    /// raíz que ya no existe instalaría un ancla que no firma nada.
    public func discard() {
        guard let directory = try? resolveDirectory() else { return }
        // Que no se pueda borrar no es motivo para romper nada: lo que se pierde es espacio temporal
        // del sistema, que se recicla solo.
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(CertificateProfile.fileName))
    }

    private func prepareDirectory() throws -> URL {
        let directory: URL
        do {
            directory = try resolveDirectory()
        } catch {
            throw CertificateProfileError.writeFailed(String(describing: error))
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw CertificateProfileError.writeFailed(String(describing: error))
        }
        return directory
    }
}
