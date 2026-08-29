import Foundation

/// Qué DNS anunció el túnel, y qué dice el sistema **ahora**.
///
/// Vive en `Shared/IPC` por lo mismo que `RelayStats` y `PipelineStats`: cruza el canal de control
/// dentro de un `ControlResponse`, así que es un contrato entre los dos procesos.
///
/// # Por qué existe
///
/// Hasta ahora esto era **silencio absoluto**. `SystemResolvers.current()` podía no contestar, o
/// contestar solo cosas que `TunnelResolvers` no deja anunciar, y el túnel se declaraba interfaz
/// primario sin ofrecer resolución de nombres — que es exactamente el fallo que dejó al dispositivo
/// sin internet y tardó tres sesiones en encontrarse. Nadie lo contaba y ninguna pantalla lo decía.
///
/// # La medición que hizo posible, y que ya está contestada
///
/// `reportedNow` era el experimento del que dependía cómo arreglar que **un cambio de red dejara el
/// DNS apuntando a la anterior**. Contestado en el iPhone el 2026-08-16 y **no lo reabras**: con el
/// túnel puesto, `res_getservers` devuelve la configuración del interfaz primario —que somos
/// nosotros—, así que esa lista **repite lo anunciado** y releer en caliente no enseña nada. Lo que sí
/// funciona es apagar y encender el monitoreo, y lo único que el arranque hace distinto es leer
/// **antes** de aplicar los ajustes de red.
///
/// De ahí sale el arreglo (`ResolverRefresh` + `NetworkPathSignature`): al cambiar de red se quitan
/// los ajustes, se lee sin ser primario y se vuelven a poner. `reportedNow` se conserva porque sigue
/// siendo la evidencia de esa afirmación —el día que deje de repetir lo anunciado, este campo será lo
/// primero que lo diga— pero **ya no es de donde sale ningún veredicto**: esos salen de los contadores
/// de abajo y del par consultas/respuestas de DNS, que miden hechos y no una inferencia.
///
/// Las direcciones viajan como **texto** y no como `IPAddress` porque eso es literalmente lo que se
/// le pasó a `NEDNSSettings.servers`: el campo dice lo que se anunció, no lo que se podría haber
/// anunciado.
public struct ResolverStatus: Sendable, Equatable, Codable {

    /// Lo que el túnel anunció al arrancar la sesión, ya filtrado por `TunnelResolvers`. **Vacío
    /// significa que no se anunció ninguno**, que es el caso que hay que poder ver.
    public var announced: [String]

    /// Lo que el sistema contestó justo antes del anuncio que sigue en pie —el del arranque, o el del
    /// último cambio de red—, **sin filtrar**. `nil` es "no se pudo preguntar", que no es lo mismo que
    /// "no tenía ninguno": la primera es una avería nuestra y la segunda una red rara, y llevan a
    /// sitios distintos.
    ///
    /// Sin filtrar a propósito: es lo que separa "el sistema no tenía resolvers" de "los tenía y
    /// ninguno se podía anunciar" (una red que solo ofrezca un `fe80::`), y esa diferencia es la que
    /// justifica —o no— dejar que el usuario fije uno.
    public var reportedWhenAnnounced: [String]?

    /// Lo que el sistema contesta **ahora**, releído al contestar `.stats` con el túnel ya primario.
    /// `nil` = no se pudo preguntar.
    ///
    /// **Esta lectura nunca alimenta lo que se anuncia**, y la distinción no es formal: releer para
    /// reanunciar cerraría un lazo —anunciaríamos lo que acabamos de anunciar— que además no haría
    /// ruido al cerrarse. Aquí solo se enseña.
    public var reportedNow: [String]?

    /// Cambios de red a los que el túnel ha reaccionado volviendo a anunciar el DNS
    /// (`NetworkPathSignature` decide cuáles lo merecen).
    public var networkChanges: UInt64 = 0

    /// De esos, cuántas veces la relectura dio resolvers **distintos** de los que había anunciados.
    ///
    /// Es la medición viva de si el arreglo funciona: quitar los ajustes de red debería devolvernos la
    /// visión del interfaz físico, y si así fuera, un cambio de Wi-Fi a datos haría subir esto. Un
    /// dispositivo que acumule cambios de red con este contador clavado en cero está diciendo que
    /// **no basta**, y entonces la salida es que el usuario fije un resolver.
    public var resolversRelearned: UInt64 = 0

    /// Reanuncios que fallaron al aplicar los ajustes de red.
    ///
    /// Importa más de lo que su nombre sugiere: un fallo aquí deja al túnel **sin ajustes aplicados**,
    /// o sea capturando nada mientras el dispositivo sigue navegando por su interfaz de siempre. No es
    /// una caída de red, es una captura muerta, y sin este contador sería otro silencio.
    public var reannounceFailures: UInt64 = 0

    /// El texto del último de esos fallos, tal cual lo dio el sistema.
    public var lastReannounceError: String?

    public init(
        announced: [String] = [],
        reportedWhenAnnounced: [String]? = nil,
        reportedNow: [String]? = nil,
        networkChanges: UInt64 = 0,
        resolversRelearned: UInt64 = 0,
        reannounceFailures: UInt64 = 0,
        lastReannounceError: String? = nil
    ) {
        self.announced = announced
        self.reportedWhenAnnounced = reportedWhenAnnounced
        self.reportedNow = reportedNow
        self.networkChanges = networkChanges
        self.resolversRelearned = resolversRelearned
        self.reannounceFailures = reannounceFailures
        self.lastReannounceError = lastReannounceError
    }
}
