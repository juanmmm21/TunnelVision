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

extension FlowDisplay {

    /// El servicio seguido de la **dirección** remota, para la fila de una conexión cuyo nombre se
    /// dedujo del DNS, o el servicio a secas en cualquier otro caso.
    ///
    /// Es lo que distingue en la lista un nombre deducido de uno anunciado, y lo hace diciendo un
    /// hecho en vez de poniendo una marca: un SNI es de la conexión y no necesita nada al lado; un
    /// nombre del DNS es de una **dirección**, así que la dirección va con él. Una insignia habría
    /// salido en casi todas las filas —QUIC es la mayor parte del tráfico de un teléfono—, y una
    /// marca que sale en todas no marca nada.
    public static func serviceLine(_ flow: HistoryFlow) -> String {
        let service = service(flow)
        guard flow.name?.origin == .dns, let address = flow.remoteAddress else { return service }
        return String(
            localized: "flow.service.withAddress",
            defaultValue: "\(service) · \(address)",
            comment: """
                Secondary line of a connection row whose name was inferred from a DNS lookup \
                rather than announced by the connection: what the connection was, then the \
                address it actually went to. First placeholder is the already-worded service \
                ('UDP · port 443'), second the IP address. Only the separator is ours to word.
                """
        )
    }

    /// De dónde sale el nombre de una conexión, dicho en lo que cabe en **una línea** de una celda de
    /// media pantalla: la primera redacción («Announced by the connection») se partía en dos y
    /// descuadraba su fila de la rejilla contra la de la dirección.
    public static func nameOrigin(_ flow: HistoryFlow) -> String {
        switch flow.name?.origin {
        case .sni:
            return String(
                localized: "flow.name.origin.announced",
                defaultValue: "Announced (SNI)",
                comment: """
                    Value of the 'Name' fact of a connection whose host name was read from its \
                    own TLS handshake (the SNI): the connection itself said who it was calling.
                    """
            )
        case .dns:
            return String(
                localized: "flow.name.origin.lookedUp",
                defaultValue: "Inferred from DNS",
                comment: """
                    Value of the 'Name' fact of a connection that did not say who it was calling: \
                    the name shown is the one the device had last looked up for the address the \
                    connection went to. It is an inference, and the wording must not read as a \
                    statement by the connection.
                    """
            )
        case nil:
            return String(
                localized: "flow.name.origin.none",
                defaultValue: "None seen",
                comment: """
                    Value of the 'Name' fact of a connection with no host name at all: it \
                    announced none and no DNS lookup seen by the tunnel led to its address. A \
                    statement of what is known, not an error.
                    """
            )
        }
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
