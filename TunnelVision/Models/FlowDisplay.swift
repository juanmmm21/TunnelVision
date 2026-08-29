import Foundation
import Shared

/// Cómo se nombra una conexión en pantalla: el host que la encabeza y el servicio al que fue.
///
/// Vive aparte de las dos pantallas que lo enseñan —la fila de la Timeline y la cabecera del Flow
/// Inspector— porque son la misma conexión vista dos veces: si cada una lo compusiera por su cuenta,
/// abrir una fila podría cambiarle el host al usuario bajo el dedo.
public enum FlowDisplay {

    /// Lo que se lee cuando no se pudo repartir los extremos. `LiveFeedAddressing` devuelve `nil` a
    /// propósito en vez de adivinar, y una conexión sin host hace menos daño que una que señala al
    /// propio dispositivo como si fuera el otro lado.
    ///
    /// `var` calculada y no `static let`: una constante estática se resuelve la primera vez que
    /// alguien la lee y dejaría el idioma congelado en el que hubiera entonces.
    public static var unknownHost: String {
        String(
            localized: "flow.host.unknown",
            defaultValue: "Unknown host",
            comment: """
                Stands in for the host of a connection whose two endpoints could not be told \
                apart. It is a statement about what is known, not an error: the connection was \
                recorded, its far side could not be named.
                """
        )
    }

    public static func host(_ flow: HistoryFlow) -> String { flow.displayHost ?? unknownHost }

    /// El protocolo y, si se sabe, el puerto remoto: es lo que distingue "web" (443) de cualquier
    /// otro servicio.
    ///
    /// El nombre del protocolo no es copia (lo pone `IPProtocolNumber.displayName`), pero **la frase
    /// sí**: el separador, el orden y la palabra "port" son de un idioma, así que se componen por el
    /// catálogo y no concatenando aquí.
    ///
    /// El puerto se envuelve en `String(...)` porque es un identificador y no una cantidad: un entero
    /// interpolado en un `String(localized:)` lo agrupa con el locale del proceso, y `port 65.535` no
    /// es un puerto que se pueda pegar en ninguna parte.
    public static func service(_ flow: HistoryFlow) -> String {
        let proto = flow.proto.displayName
        guard let port = flow.remotePort else { return proto }
        return String(
            localized: "flow.service.protocolAndPort",
            defaultValue: "\(proto) · port \(String(port))",
            comment: """
                Secondary line naming what a connection was: its protocol and the port on the far \
                side. First placeholder is the protocol name (TCP, UDP, …), second the port \
                number. Only the separator and the word 'port' are ours to word.
                """
        )
    }
}

/// Cómo se nombra cada sentido del tráfico, en un solo sitio: el gráfico, las fichas de la Dashboard,
/// la fila de un host y la lista de paquetes tienen que llamarlo igual, o el usuario no puede leer
/// dos pantallas seguidas. El color y el símbolo de cada sentido los pone `TrafficDirectionStyle`,
/// que es la mitad que sabe de SwiftUI.
public enum DirectionLabel {

    /// Son `var` calculadas y no constantes: una `static let` se resuelve la primera vez que alguien
    /// la lee y dejaría el idioma congelado en el que hubiera entonces.
    public static var inbound: String {
        String(
            localized: "traffic.direction.inbound",
            defaultValue: "Received",
            comment: """
                Name of traffic coming into the device. It is a past participle because it labels an \
                amount already measured ('Received 1.2 MB'), not an ongoing action. The same word \
                labels the chart series, the counter tile, the host rows and the packet list, so it \
                must read well both as a heading and next to a number.
                """
        )
    }

    public static var outbound: String {
        String(
            localized: "traffic.direction.outbound",
            defaultValue: "Sent",
            comment: """
                Name of traffic leaving the device, the counterpart of the inbound label. Same \
                constraint: it labels an amount already measured and is reused across four screens.
                """
        )
    }

    public static func of(_ direction: Direction) -> String {
        switch direction {
        case .inbound: return inbound
        case .outbound: return outbound
        }
    }
}
