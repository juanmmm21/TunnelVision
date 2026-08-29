import Foundation

/// Un certificado de mentira, emitido por la CA local, con el que preguntarle al sistema **la única
/// pregunta que importa**: ¿aceptaría este dispositivo un certificado emitido por esta CA en una
/// conexión TLS?
///
/// # Por qué no basta con evaluar la raíz
///
/// Hasta el 2026-08-15 esa pregunta se hacía evaluando el certificado raíz solo, con
/// `SecPolicyCreateBasicX509`. **Da un falso positivo**, y costó una sesión de dispositivo
/// descubrirlo: en iOS, instalar un perfil mete la raíz en el almacén de anclas, pero habilitarla
/// **para TLS** es un segundo gesto —el interruptor de *Ajustes › General › Información › Ajustes de
/// confianza de certificados*—. Con la política básica, una raíz instalada y sin ese interruptor
/// evalúa como válida; con la política de servidor TLS, no. La app leía la primera, decía «confiada»,
/// dejaba encender la inspección, y entonces **todas** las conexiones del dispositivo morían porque
/// el sistema rechazaba nuestros leaves. Se vio en un `.pcap`: 66 de 90 conexiones cerradas por el
/// cliente justo después de recibir el certificado.
///
/// La lección que deja el tipo: para saber si algo servirá en un handshake TLS, hay que preguntarlo
/// **con la política del handshake TLS**, y sobre lo que se va a presentar de verdad — una cadena
/// leaf + raíz—, no sobre la raíz suelta.
///
/// # Por qué un host inventado
///
/// El leaf necesita un nombre para que la política de servidor pueda verificarlo, y ese nombre no
/// debe poder existir: `.invalid` es el TLD que la RFC 2606 reserva justo para esto, así que la sonda
/// no puede coincidir nunca con un host real ni acabar sirviendo tráfico de nadie.
public struct TrustProbe: Sendable, Equatable {

    /// El nombre del certificado de prueba. Fijo, para que el leaf se emita una vez y salga de la
    /// cache en las siguientes preguntas: lo que caduca es la respuesta del sistema, no el leaf.
    public static let host = "trust-probe.tunnelvision.invalid"

    /// El host que la política de servidor tiene que verificar (siempre `TrustProbe.host`).
    public let host: String

    /// El leaf emitido por la CA local, en DER. Es lo que la extensión presentaría en un handshake.
    public let leafDER: Data

    /// El certificado raíz de la CA, en DER. Va en la cadena para que el sistema pueda emparejarlo
    /// con el ancla instalada; **no** se pasa como ancla explícita, que es lo que convertiría la
    /// pregunta en una tautología (una raíz siempre se ancla a sí misma).
    public let rootDER: Data

    public init(host: String = TrustProbe.host, leafDER: Data, rootDER: Data) {
        self.host = host
        self.leafDER = leafDER
        self.rootDER = rootDER
    }

    /// La cadena que se le da a `SecTrustCreateWithCertificates`, del leaf hacia la raíz.
    public var chainDER: [Data] { [leafDER, rootDER] }
}
