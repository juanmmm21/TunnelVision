import Foundation

/// Con qué red está hablando el dispositivo, reducido a lo que distingue una red de otra.
///
/// Existe para una sola decisión: **cuándo vuelve el túnel a anunciar el DNS**. Los resolvers se leen
/// una vez, al arrancar, y ahí se quedan; salir de casa —pasar de Wi-Fi a datos— deja al dispositivo
/// mandando sus consultas a la puerta de enlace de la red anterior, que desde la nueva no existe. El
/// síntoma es una página cargando para siempre, y está confirmado en el iPhone.
///
/// Es un tipo puro a propósito: quien lo construye es el provider a partir de un `NWPath`
/// (device-only), pero **la regla de cuándo un cambio merece reaccionar** se prueba en Simulator,
/// porque es donde está el riesgo — reanunciar de más cuesta una ventana sin ajustes de red, o sea un
/// hueco en la captura, y reanunciar de menos deja el fallo donde estaba.
public struct NetworkPathSignature: Sendable, Equatable, Codable {

    /// Si el camino sirve para mandar tráfico. Un camino que no lo está no tiene DNS que aprender, y
    /// tocar los ajustes de red en ese momento es el peor instante posible.
    public let isSatisfied: Bool

    /// Los interfaces físicos por los que se puede salir, ordenados. **Sin los nuestros**: el `utun`
    /// del propio túnel aparece en el camino en cuanto se aplican los ajustes, y compararse contra uno
    /// mismo haría que cada reanuncio provocara el siguiente.
    public let interfaces: [String]

    /// Las direcciones de los routers del camino, ordenadas. Van con los interfaces porque cambiar de
    /// Wi-Fi a Wi-Fi **no cambia el interfaz** (`en0` sigue siendo `en0`) y sí suele cambiar el
    /// router, así que sin esto el caso "me voy de casa a la oficina" no se vería.
    public let gateways: [String]

    public init(isSatisfied: Bool, interfaces: [String], gateways: [String]) {
        self.isSatisfied = isSatisfied
        // Se ordenan **aquí** y no en quien construye: el orden en que el sistema enumera interfaces y
        // routers no es un dato, y dos listas iguales en otro orden describen la misma red. Ordenar en
        // el borde es lo que impide que un reanuncio dependa de ese detalle.
        self.interfaces = interfaces.sorted()
        self.gateways = gateways.sorted()
    }

    /// Si pasar de la red por la que se anunció a esta justifica volver a anunciar.
    ///
    /// - Parameter announced: la firma de la red por la que se anunció lo que hay puesto ahora, o
    ///   `nil` si todavía no se ha visto ninguna.
    ///
    /// Tres reglas, y cada una evita un daño concreto:
    ///
    /// 1. **Un camino que no sirve no dispara nada.** Reanunciar exige quitar los ajustes de red un
    ///    instante, y hacerlo mientras no hay red deja el túnel sin ajustes justo cuando no puede
    ///    volver a poner unos buenos.
    /// 2. **La primera red que se ve no dispara nada**, solo se apunta: es la red sobre la que
    ///    `startTunnel` ya leyó y anunció, así que reaccionar a ella sería repetir el arranque.
    /// 3. **Y solo dispara lo que describe una red distinta.** Un corte y una vuelta a la misma Wi-Fi
    ///    dan la misma firma, y sus resolvers son los mismos: reanunciar ahí es pagar el hueco de
    ///    captura a cambio de nada.
    ///
    /// Lo que esta regla **no** ve, y hay que saberlo: dos redes con el mismo interfaz y el mismo
    /// router —dos Wi-Fi domésticas en `192.168.1.1`— son indistinguibles desde aquí. Ese caso lo
    /// recoge el otro extremo del problema: el par *consultas de DNS enviadas / respuestas recibidas*,
    /// que mide el síntoma en vez de la causa.
    public static func warrantsReannouncement(
        from announced: NetworkPathSignature?,
        to current: NetworkPathSignature
    ) -> Bool {
        guard current.isSatisfied else { return false }
        guard let announced else { return false }
        return announced.interfaces != current.interfaces || announced.gateways != current.gateways
    }
}
