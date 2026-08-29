import Foundation

/// Qué anunciar cuando el dispositivo ha cambiado de red y se ha vuelto a leer la configuración.
///
/// # El descubrimiento que hace falta para entender esto
///
/// Medido en el iPhone el 2026-08-16: **con el túnel puesto, releer no enseña nada**. `res_getservers`
/// devuelve la configuración del interfaz primario, que somos nosotros, así que la relectura contesta
/// lo que acabamos de anunciar. Lo que **sí** funciona es apagar y encender el monitoreo, y lo único
/// que `startTunnel` hace distinto es leer **antes** de aplicar los ajustes de red — o sea, antes de
/// ser primario. De ahí sale la forma del arreglo: quitar los ajustes, leer, y volver a ponerlos.
///
/// # Por qué la decisión vive aquí y no en el provider
///
/// Porque la parte que puede hacer daño es una elección, no una llamada al sistema: en el momento en
/// que esto decide, **el túnel ya no tiene ajustes aplicados**. Devolver una lista vacía sería dejar
/// al dispositivo sin resolución de nombres, que es exactamente el fallo que todo esto viene a cerrar.
public enum ResolverRefresh {

    /// Lo que hay que anunciar, y si la relectura sirvió de algo.
    public struct Decision: Sendable, Equatable {

        /// Los resolvers a anunciar. **Nunca queda vacío si antes había algo**: si la relectura no da
        /// nada utilizable se conserva lo anterior, porque un resolver de la red de antes todavía
        /// puede servir —dos redes domésticas comparten `192.168.1.1` más veces de las que parece— y
        /// ninguno no sirve nunca.
        public let announce: [IPAddress]

        /// Si lo releído difería de lo que estaba anunciado.
        ///
        /// **Es la medición**, y por eso viaja hasta la pantalla: mientras esto sea siempre `false`,
        /// quitar los ajustes no basta para volver a ver el interfaz físico y el arreglo de verdad es
        /// que el usuario fije un resolver. La primera vez que sea `true` en un cambio de red real, el
        /// túnel se está curando solo.
        public let learnedSomethingNew: Bool

        public init(announce: [IPAddress], learnedSomethingNew: Bool) {
            self.announce = announce
            self.learnedSomethingNew = learnedSomethingNew
        }
    }

    /// - Parameters:
    ///   - reported: lo que el sistema contesta ahora, sin filtrar. `nil` = no se pudo preguntar.
    ///   - currentlyAnnounced: lo que el túnel tenía anunciado hasta este momento.
    ///
    /// El filtro es el de siempre (`TunnelResolvers`), y la comparación es **ordenada** porque el
    /// orden es la preferencia del sistema: una red que ofrece los mismos resolvers en otro orden ha
    /// cambiado de preferencia, y anunciarla como viene es lo que respeta esa elección.
    public static func decide(reported: [String]?, currentlyAnnounced: [IPAddress]) -> Decision {
        let announceable = TunnelResolvers.announceable(from: reported ?? [])
        guard !announceable.isEmpty else {
            return Decision(announce: currentlyAnnounced, learnedSomethingNew: false)
        }
        return Decision(announce: announceable, learnedSomethingNew: announceable != currentlyAnnounced)
    }
}
