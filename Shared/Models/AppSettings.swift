import Foundation

/// Cuánto de cada paquete se guarda en el `.pcap` (`docs/ux/screens.md`, Ajustes → *Capture detail*).
///
/// Los metadatos del paquete —longitud real, flags, sentido, sello— se guardan en el historial pase lo
/// que pase: esto solo decide cuántos bytes del datagrama acaban en el fichero de captura. Por eso
/// `metadataOnly` no pierde nada de lo que enseñan la Timeline ni el Flow Inspector; lo que recorta es
/// el volcado hexadecimal de la pantalla de un paquete, y el `.pcap` exportado.
public enum CaptureDetail: String, Codable, Sendable, Equatable, CaseIterable {

    /// Solo las cabeceras. 128 bytes cubren el peor caso de una cabecera IPv6 (40) más una TCP con
    /// todas sus opciones (60) sin recortar nada que sirva para interpretar la conexión.
    case metadataOnly

    /// El paquete entero, hasta el máximo que el formato admite en la práctica.
    case fullPayload

    /// El `snaplen` que se escribe en la cabecera global del `.pcap` y con el que el writer recorta
    /// cada registro. Va en el fichero, no en el registro, así que **cambiarlo obliga a rotar**: un
    /// fichero cuyos registros midan más de lo que su cabecera declara se lee como corrupto (el lector
    /// acota `incl_len` contra ese `snaplen` antes de reservar memoria, `docs/spec/pcap.md`).
    public var snaplen: UInt32 {
        switch self {
        case .metadataOnly: 128
        case .fullPayload: 262_144
        }
    }
}

/// Tope de antigüedad del historial y de las capturas (`docs/ux/screens.md`, Ajustes → *Storage*).
///
/// Es antigüedad **real**, medida contra la hora de pared, que es la razón por la que el store guarda
/// fechas absolutas y no sellos monotónicos (`docs/spec/persistence.md`): un corte por antigüedad sobre
/// un reloj que se reinicia con el dispositivo sería directamente incorrecto.
public enum RetentionAge: String, Codable, Sendable, Equatable, CaseIterable {
    case oneDay
    case oneWeek
    case oneMonth
    /// Nada se borra por antigüedad. El tope de tamaño sigue aplicando si está puesto.
    case unlimited

    /// `nil` cuando no hay tope.
    public var maxAge: TimeInterval? {
        switch self {
        case .oneDay: 24 * 60 * 60
        case .oneWeek: 7 * 24 * 60 * 60
        case .oneMonth: 30 * 24 * 60 * 60
        case .unlimited: nil
        }
    }
}

/// Tope de tamaño de las **capturas** (`docs/ux/screens.md`, Ajustes → *Storage*).
///
/// Gobierna los `.pcap` y no la base de datos, y no por descuido: el historial son metadatos (decenas
/// de bytes por paquete frente a los cientos o miles del datagrama), y sobre todo SQLite **no
/// devuelve** el espacio al borrar filas — reutiliza sus páginas —, así que un tope en bytes sobre la
/// BD no se podría cumplir aunque se borrase todo. Un tope que no se puede hacer valer sería una
/// mentira; el historial se acota por antigüedad, que sí se puede.
public enum RetentionSize: String, Codable, Sendable, Equatable, CaseIterable {
    case megabytes256
    case gigabyte1
    case gigabytes4
    /// Las capturas crecen sin tope. Solo la antigüedad las corta, si está puesta.
    case unlimited

    /// `nil` cuando no hay tope.
    public var maxBytes: UInt64? {
        switch self {
        case .megabytes256: 256 * 1024 * 1024
        case .gigabyte1: 1024 * 1024 * 1024
        case .gigabytes4: 4 * 1024 * 1024 * 1024
        case .unlimited: nil
        }
    }
}

/// Tope de antigüedad del **contenido descifrado** (`docs/decisions/0007-decrypted-content-retention.md`).
///
/// Es aparte del de las capturas y **más corto**, y no por simetría mal entendida: una semana de
/// `.pcap` y una semana de plaintext no son el mismo objeto aunque ocupen el mismo contenedor. Una
/// guarda lo que viajó cifrado; la otra, lo que el usuario leyó, escribió y recibió.
///
/// **No tiene `unlimited`, y esa ausencia es la decisión**: un producto que descifra en nombre del
/// usuario no puede ofrecerse a guardar el resultado para siempre. Por eso `maxAge` aquí no es
/// opcional — siempre hay un corte.
public enum PlaintextRetentionAge: String, Codable, Sendable, Equatable, CaseIterable {
    case oneHour
    case oneDay
    case oneWeek

    public var maxAge: TimeInterval {
        switch self {
        case .oneHour: 60 * 60
        case .oneDay: 24 * 60 * 60
        case .oneWeek: 7 * 24 * 60 * 60
        }
    }
}

/// Los topes de retención, que son políticas distintas y se aplican todas.
public struct RetentionSettings: Codable, Sendable, Equatable {

    public var maxAge: RetentionAge

    public var maxCaptureSize: RetentionSize

    /// Cuánto se queda el contenido descifrado. De fábrica **un día**, frente a la semana de las
    /// capturas (ADR 0007).
    public var maxPlaintextAge: PlaintextRetentionAge

    /// Techo de disco del contenido descifrado que el usuario **no puede subir**, aplicado por el
    /// mismo barrido que la antigüedad.
    ///
    /// No es un ajuste a propósito: el presupuesto por flujo ya acota el **ritmo** al que esto crece,
    /// así que un segundo mando sería sobre todo un número que el usuario tiene que entender para
    /// poder ignorarlo. Lo que hace falta es la protección, no la pregunta — y que la pantalla diga
    /// cuándo el techo se ha llevado algo que la antigüedad habría conservado, como ya se dice de las
    /// capturas (`sizeCapUnreachable`).
    public static let plaintextByteCeiling: UInt64 = 512 * 1024 * 1024

    /// Con topes por defecto, no sin ellos: una captura local sin tope llena el disco del dispositivo,
    /// que es exactamente lo que pasaba mientras esto no existía. La pantalla de Ajustes los dice en
    /// palabras y se pueden quitar, pero el estado de fábrica no puede ser el que rompe el dispositivo.
    public static let `default` = RetentionSettings()

    public init(
        maxAge: RetentionAge = .oneWeek,
        maxCaptureSize: RetentionSize = .gigabyte1,
        maxPlaintextAge: PlaintextRetentionAge = .oneDay
    ) {
        self.maxAge = maxAge
        self.maxCaptureSize = maxCaptureSize
        self.maxPlaintextAge = maxPlaintextAge
    }

    /// Si no hay nada que recortar **del historial ni de las capturas**.
    ///
    /// No habla por el contenido descifrado, que **siempre** tiene corte (ADR 0007): quien use esto
    /// para saltarse un barrido entero tiene que preguntar aparte si hay plaintext que barrer.
    public var isUnlimited: Bool { maxAge == .unlimited && maxCaptureSize == .unlimited }

    // Decodificación tolerante, por lo mismo que en `AppSettings`: un campo que no se entiende vuelve
    // a su valor de fábrica sin arrastrar a los demás.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = RetentionSettings.default
        self.maxAge = (try? container.decode(RetentionAge.self, forKey: .maxAge)) ?? fallback.maxAge
        self.maxCaptureSize =
            (try? container.decode(RetentionSize.self, forKey: .maxCaptureSize)) ?? fallback.maxCaptureSize
        self.maxPlaintextAge =
            (try? container.decode(PlaintextRetentionAge.self, forKey: .maxPlaintextAge)) ?? fallback.maxPlaintextAge
    }
}

/// Lo que el usuario ha decidido, tal y como lo leen **los dos procesos** (`docs/ux/screens.md`,
/// pantalla *Settings*).
///
/// Es la verdad **duradera**: la escribe la app cuando el usuario toca un ajuste y la lee la extensión
/// al arrancar el túnel, así que un ajuste sobrevive a que la extensión se reinicie o a que el
/// dispositivo se apague. El canal de control (`ControlChannel`) es la otra mitad y no la sustituye:
/// sirve para aplicar un cambio **en caliente** sobre una sesión que ya está corriendo, y un comando
/// que se pierde por una carrera con `stopTunnel` no puede dejar el ajuste sin guardar.
///
/// No lleva el interruptor de *UDP/streaming passthrough* que `docs/ux/screens.md` menciona: hoy el
/// pipeline enruta **siempre** UDP a passthrough (no hay inspección de QUIC ni está prevista), así que
/// el ajuste no tendría nada que apagar y solo podría mentir.
public struct AppSettings: Codable, Sendable, Equatable {

    /// Mirar dentro del tráfico cifrado. Apagado de fábrica, y encenderlo exige que el usuario haya
    /// instalado y confiado la CA local: eso lo comprueba la app antes de guardar (`ADR 0003`).
    public var tlsInspectionEnabled: Bool

    /// Guardar en disco el **contenido descifrado** de los flujos inspeccionados
    /// (`docs/decisions/0007-decrypted-content-retention.md`).
    ///
    /// Es un interruptor propio y **apagado de fábrica aunque la inspección esté encendida**, porque
    /// son dos actos distintos: inspeccionar deja *ver* lo que pasa mientras pasa; persistir convierte
    /// esa vista en un registro duradero de lo que el usuario leyó, escribió y recibió. Con esto
    /// apagado la inspección funciona entera y **no se copia ni un byte** — el relay le pasa `nil` al
    /// sumidero de la terminación, que es el estado en el que no hay nada que observar.
    public var plaintextPersistenceEnabled: Bool

    /// Escribir los `.pcap`. Apagarlo deja el historial funcionando —los metadatos siguen entrando—
    /// y solo deja de guardar bytes crudos.
    public var captureEnabled: Bool

    public var captureDetail: CaptureDetail

    public var retention: RetentionSettings

    /// Si el usuario ya ha visto el intro de la primera ejecución
    /// (`docs/ux/onboarding-and-consent.md`, *First run*).
    ///
    /// Es el **único** campo que la extensión no lee, y vive aquí de todas formas a conciencia: la
    /// alternativa es un `UserDefaults` propio de la app, que partiría en dos soportes la única verdad
    /// duradera que el producto tiene —dos sitios que pueden fallar por separado, dos cosas que
    /// resetear, dos formatos que versionar— para ahorrarle a la extensión un `Bool` que ni mira. La
    /// decodificación tolerante campo a campo se escribió justo para poder crecer así.
    ///
    /// De fábrica es `false`, y eso es lo que hace que **no haber guardado nada todavía** —una
    /// instalación recién hecha— signifique enseñar el intro, sin necesidad de un centinela aparte.
    public var hasSeenIntro: Bool

    /// El estado de fábrica: lo que hace la app antes de que el usuario toque nada. Coincide con lo
    /// que la extensión hacía cuando estos ajustes no existían (inspección apagada, captura encendida,
    /// paquete completo), así que estrenarlos no cambia por sorpresa lo que ya se capturaba.
    public static let `default` = AppSettings()

    public init(
        tlsInspectionEnabled: Bool = false,
        plaintextPersistenceEnabled: Bool = false,
        captureEnabled: Bool = true,
        captureDetail: CaptureDetail = .fullPayload,
        retention: RetentionSettings = .default,
        hasSeenIntro: Bool = false
    ) {
        self.tlsInspectionEnabled = tlsInspectionEnabled
        self.plaintextPersistenceEnabled = plaintextPersistenceEnabled
        self.captureEnabled = captureEnabled
        self.captureDetail = captureDetail
        self.retention = retention
        self.hasSeenIntro = hasSeenIntro
    }

    // La decodificación es tolerante **campo a campo**: uno que falta o que no se entiende vuelve a su
    // valor de fábrica y los demás se conservan. No es laxitud: estos ajustes crecen —`hasSeenIntro`
    // llegó con M10 y el flujo de la CA traerá más—, y con la decodificación estricta de `Codable`
    // añadir un campo dejaría el blob guardado sin decodificar, borrando de golpe todo lo que el
    // usuario había elegido. Ya ha pasado la prueba: un blob escrito antes de M10 se sigue leyendo
    // entero y solo el campo nuevo cae a su valor de fábrica, que además es el correcto para quien
    // venía usando la app (`false` ⇒ se le vuelve a enseñar el intro una vez, no se le pierde nada).
    // Lo que **sí** es un error visible es que el blob no sea ni JSON: eso lo reporta `SettingsStore`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettings.default
        self.tlsInspectionEnabled =
            (try? container.decode(Bool.self, forKey: .tlsInspectionEnabled)) ?? fallback.tlsInspectionEnabled
        // Un blob escrito antes del ADR 0007 no trae este campo, y su valor de fábrica (`false`) es el
        // correcto para quien ya venía usando la app: nadie empieza a grabar contenido descifrado por
        // haber actualizado.
        self.plaintextPersistenceEnabled =
            (try? container.decode(Bool.self, forKey: .plaintextPersistenceEnabled))
            ?? fallback.plaintextPersistenceEnabled
        self.captureEnabled =
            (try? container.decode(Bool.self, forKey: .captureEnabled)) ?? fallback.captureEnabled
        self.captureDetail =
            (try? container.decode(CaptureDetail.self, forKey: .captureDetail)) ?? fallback.captureDetail
        self.retention =
            (try? container.decode(RetentionSettings.self, forKey: .retention)) ?? fallback.retention
        self.hasSeenIntro =
            (try? container.decode(Bool.self, forKey: .hasSeenIntro)) ?? fallback.hasSeenIntro
    }
}
