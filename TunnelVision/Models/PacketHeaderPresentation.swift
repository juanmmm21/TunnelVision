import Foundation
import Shared

/// Lo que las cabeceras del datagrama dicen, leídas para quien no sabe leer hexadecimal
/// (`docs/ux/screens.md`, *Packet detail*).
///
/// Es lo que le faltaba a esta pantalla desde que existe: el volcado enseña el datagrama IP crudo, y
/// quien no sepa dónde empieza el puerto de destino solo ve pares hexadecimales. Interpretarlos no
/// necesita ni un parser nuevo ni una consulta más — el de M3 vive en `Shared/IP` desde que dejó de ser
/// solo de la extensión, y los bytes ya están leídos en la pantalla—, así que lo único que hace falta
/// decidir es **qué se enseña y qué se calla**, que es lo que hay aquí.
///
/// Lo que se calla, y por qué: el tamaño del paquete y sus flags ya los dicen los datos guardados
/// (`PacketBytesPresentation.packetFacts`), y repetirlos leídos del cable invitaría a compararlos como
/// si pudieran discrepar. El **payload** tampoco sale: los rangos que devuelve el parser están acotados
/// al buffer, así que en un registro recortado por el `snaplen` contarían lo que se guardó y no lo que
/// viajó, y una cifra que a veces miente es peor que ninguna.

/// Las cabeceras de un paquete, ya leídas, o la razón por la que no se pudieron leer.
public enum PacketHeaderContent: Sendable, Equatable {

    /// Lo leído y, cuando **una capa** de las que se sabían leer se quedó sin leer, por qué.
    ///
    /// El aviso existe desde que hay un disector por encima de L4 (paso 10 del roadmap): un datagrama
    /// del puerto 53 cuyo mensaje de DNS no se puede leer tiene sus cabeceras IP y UDP perfectamente
    /// leídas, así que no cae en `.undecodable` y sin esto desaparecería del todo. Es la misma regla
    /// de ahí abajo aplicada una capa más arriba — se dice, no se calla.
    case facts([FlowFact], unread: String?)

    /// No hay interpretación posible, con el motivo ya en palabras. Se dice en vez de esconder la
    /// sección: una pantalla que interpreta unos paquetes y otros no, sin explicarlo, se lee como una
    /// avería intermitente.
    case undecodable(String)
}

public enum PacketHeaderPresentation {

    /// Lo que se puede leer de los bytes guardados de un paquete.
    ///
    /// El registro entero y no solo sus bytes, porque el recorte del `snaplen` es justo lo que separa
    /// los dos motivos de no poder leerlos: unos bytes que se cortaron antes de la cabecera son lo
    /// normal en una captura de solo metadatos, y unos bytes completos que no parsean son otra cosa.
    public static func content(for record: CaptureRecord) -> PacketHeaderContent {
        do {
            // La familia de protocolo es solo una pista y **gana el nibble de versión del contenido**
            // (`PacketParser.parse`). Aquí no hay pista que dar: un `.pcap` de `LINKTYPE_RAW` no guarda
            // ninguna, que es precisamente por lo que el nibble tiene que mandar.
            let parsed = try PacketParser.parse(record.bytes, protocolFamily: AF_INET)
            let headers = facts(for: parsed)

            guard let udp = parsed.udp, DNSPresentation.carriesDNS(udp) else {
                return .facts(headers, unread: nil)
            }
            do {
                let message = try DNSMessageParser.parse(payload(of: record, in: udp.payloadRange))
                return .facts(headers + DNSPresentation.facts(for: message), unread: nil)
            } catch {
                // Las cabeceras leídas se quedan: que el mensaje de DNS no se pueda leer no invalida
                // el datagrama que lo traía, y el motivo va debajo en palabras.
                return .facts(headers, unread: DNSPresentation.unreadNote(for: record))
            }
        } catch {
            return .undecodable(undecodableNote(for: record))
        }
    }

    /// Los bytes del payload de transporte.
    ///
    /// Se recorta por **cuenta** y no por índices porque el rango que devuelve el parser es 0-based
    /// sobre el datagrama, y un `Data` puede llegar como slice con su propio `startIndex`: indexar con
    /// esos offsets leería el sitio equivocado o se saldría. El rango ya viene acotado al buffer real
    /// (`PacketParser`), así que un paquete recortado por el `snaplen` entrega aquí lo que se guardó de
    /// él y el disector de arriba se encarga de decir que no llega.
    private static func payload(of record: CaptureRecord, in range: Range<Int>) -> Data {
        record.bytes.dropFirst(range.lowerBound).prefix(range.count)
    }

    // MARK: - Los datos

    /// **Van en parejas**, porque la rejilla los reparte en dos columnas leyendo por filas: las dos
    /// capas juntas, los dos extremos juntos y las dos posiciones del flujo juntas.
    ///
    /// El orden era otro y tenía el mismo defecto que la cabecera del Flow Inspector acababa de
    /// perder: con la versión primero y el protocolo el cuarto, **`From` y `To` caían en distinta
    /// fila y en distinta columna** —arriba a la derecha de dónde venía, abajo a la izquierda a dónde
    /// iba—, o sea los dos extremos de un mismo viaje leídos en diagonal.
    ///
    /// La cola **puede quedar impar y se queda**: cuántos datos hay aquí lo decide el protocolo del
    /// paquete y no el diseño (cuatro sin transporte, cinco en UDP, seis o siete en TCP según lleve
    /// acuse), así que emparejarlos por construcción exigiría inventarse uno o callarse otro. Lo que
    /// sobra al final es siempre lo que no tiene pareja conceptual —la ventana, el tamaño del
    /// datagrama—, no la mitad de algo.
    private static func facts(for parsed: ParsedPacket) -> [FlowFact] {
        var facts = [versionFact(parsed.ip.version), protocolFact(parsed.ip.proto)]
        facts.append(contentsOf: endpointFacts(parsed))

        if let tcp = parsed.tcp {
            facts.append(contentsOf: tcpFacts(tcp))
        }
        if let udp = parsed.udp {
            facts.append(udpLengthFact(udp))
        }
        return facts
    }

    private static func versionFact(_ version: IPVersion) -> FlowFact {
        FlowFact(
            id: "headerVersion",
            label: String(
                localized: "packetDetail.header.version",
                defaultValue: "IP version",
                comment: """
                    Label of which version of the Internet Protocol this packet used, next to \
                    'IPv4' or 'IPv6'. Those two are the protocols' own names and are never \
                    translated.
                    """
            ),
            // No pasan por el catálogo por lo mismo que TCP y UDP: son el nombre del protocolo.
            value: .text(version == .v4 ? "IPv4" : "IPv6")
        )
    }

    /// De dónde a dónde iba **según el propio paquete**, que no es lo mismo que los extremos de la
    /// conexión: la cabecera de la Timeline dice quién habló con quién, y esto dice quién mandó *este*
    /// datagrama, que en el sentido de vuelta son los mismos dos al revés.
    ///
    /// Sin capa de transporte —ICMP, o un fragmento que no es el primero— se enseñan las direcciones
    /// desnudas y no los extremos: `IPEndpoint` traería un puerto 0 que nadie ha puesto en el cable, y
    /// un `:0` en pantalla es un dato inventado.
    private static func endpointFacts(_ parsed: ParsedPacket) -> [FlowFact] {
        let hasPorts = parsed.tcp != nil || parsed.udp != nil
        let from = hasPorts ? parsed.source.description : parsed.ip.source.description
        let to = hasPorts ? parsed.destination.description : parsed.ip.destination.description

        return [
            FlowFact(
                id: "headerFrom",
                label: String(
                    localized: "packetDetail.header.from",
                    defaultValue: "From",
                    comment: """
                        Label of the address this packet was sent from, as written in its own \
                        header, next to an address (with a port when the packet has one). It is \
                        about this single packet and not about the connection.
                        """
                ),
                value: .text(from)
            ),
            FlowFact(
                id: "headerTo",
                label: String(
                    localized: "packetDetail.header.to",
                    defaultValue: "To",
                    comment: """
                        Label of the address this packet was sent to, as written in its own \
                        header, next to an address (with a port when the packet has one). Sibling \
                        of the 'From' key above.
                        """
                ),
                value: .text(to)
            ),
        ]
    }

    private static func protocolFact(_ proto: IPProtocolNumber) -> FlowFact {
        FlowFact(
            id: "headerProtocol",
            label: String(
                localized: "packetDetail.header.protocol",
                defaultValue: "Protocol",
                comment: """
                    Label of which transport protocol the packet carried, next to a protocol name \
                    (TCP, UDP, ICMP, ICMPv6, or the translatable 'Other'). Read from the packet's \
                    own header.
                    """
            ),
            value: .text(proto.displayName)
        )
    }

    private static func tcpFacts(_ tcp: TCPHeader) -> [FlowFact] {
        var facts = [
            FlowFact(
                id: "tcpSequence",
                label: String(
                    localized: "packetDetail.header.sequence",
                    defaultValue: "Sequence",
                    comment: """
                        Label of the TCP sequence number, next to a plain number. It names a \
                        position in the connection's byte stream, so it is never grouped with \
                        thousands separators. 'Sequence' is the protocol's own term.
                        """
                ),
                // Un número que **identifica** —una posición en el flujo de bytes, no una cantidad—, así
                // que va como `String` y sin agrupar: `1.284.005.201` no es un número de secuencia.
                value: .text(String(tcp.sequence))
            )
        ]

        // El campo de acuse existe en todo segmento pero **solo significa algo con el flag ACK puesto**:
        // sin él son 32 bits sin usar, y enseñarlos como un dato invitaría a leer un acuse donde no lo
        // hay. Es la misma regla por la que un flujo sin host se queda sin host en vez de adivinarlo.
        if tcp.flags.contains(.ack) {
            facts.append(
                FlowFact(
                    id: "tcpAcknowledgment",
                    label: String(
                        localized: "packetDetail.header.acknowledgment",
                        defaultValue: "Acknowledged",
                        comment: """
                            Label of the TCP acknowledgment number, next to a plain number. Like \
                            the sequence number it names a position in the byte stream and is \
                            never grouped. It is only shown on packets that carry the ACK flag, \
                            where the field means something.
                            """
                    ),
                    value: .text(String(tcp.acknowledgment))
                )
            )
        }

        facts.append(
            FlowFact(
                id: "tcpWindow",
                label: String(
                    localized: "packetDetail.header.window",
                    defaultValue: "Window",
                    comment: """
                        Label of the TCP receive window, next to a formatted byte amount: how much \
                        more the sender said it could accept right then. This one is an amount and \
                        not a position, so unlike the sequence number it is formatted as bytes. \
                        'Window' is the protocol's own term.
                        """
                ),
                // Esta sí es una cantidad —cuántos bytes más aceptaba el emisor—, así que se formatea
                // como tal, al revés que la secuencia.
                value: .text(DisplayFormat.bytes(UInt64(tcp.windowSize)))
            )
        )
        return facts
    }

    /// El único dato de UDP que no está ya en otro sitio, y **se lee del campo declarado**, no de los
    /// bytes presentes: eso lo hace la longitud real del datagrama aunque la captura lo recortase.
    private static func udpLengthFact(_ udp: UDPHeader) -> FlowFact {
        FlowFact(
            id: "udpLength",
            label: String(
                localized: "packetDetail.header.datagramLength",
                defaultValue: "Datagram length",
                comment: """
                    Label of the length UDP declares for itself, next to a formatted byte amount: \
                    its header plus its data. It is read from the header, so it is the real length \
                    even when the capture kept only the beginning of the packet.
                    """
            ),
            value: .text(DisplayFormat.bytes(UInt64(udp.length)))
        )
    }

    // MARK: - Cuando no se puede leer

    /// Por qué no hay interpretación. Son dos motivos distintos y el usuario puede hacer algo con el
    /// primero y nada con el segundo, así que no se colapsan: unos bytes cortados antes de la cabecera
    /// son la consecuencia normal de capturar solo metadatos —se arregla en Ajustes—, y unos bytes
    /// enteros que no parsean son un paquete que esta app no sabe leer.
    private static func undecodableNote(for record: CaptureRecord) -> String {
        guard record.isTruncated else {
            return String(
                localized: "packetDetail.headers.undecodable.unreadable",
                defaultValue: "These bytes don't read as an IP packet, so there's nothing to break down.",
                comment: """
                    Note replacing the decoded headers when the saved bytes are complete but do \
                    not parse as an IP datagram. Nothing is broken: the raw bytes are still shown \
                    below, this app just cannot name their parts.
                    """
            )
        }
        return String(
            localized: "packetDetail.headers.undecodable.truncated",
            defaultValue: """
                Only \(DisplayFormat.bytes(UInt64(record.capturedLength))) of this packet were \
                saved — not enough to read its headers. Capture detail is in Settings.
                """,
            comment: """
                Note replacing the decoded headers when the capture kept too little of the packet \
                to reach the end of its headers. The placeholder is how much was saved. The last \
                sentence points at the setting that decides it, because this one the user can \
                change; 'Settings' is this app's own screen, named by its tab.
                """
        )
    }

    /// El encabezado de la sección.
    public static var headersSectionTitle: String {
        String(
            localized: "packetDetail.section.headers",
            defaultValue: "Headers",
            comment: """
                Heading of the decoded header fields on a packet's screen, above the raw hex dump. \
                It is the interpretation of the first bytes of the packet, which is what tells it \
                apart from the 'Raw bytes' heading below it.
                """
        )
    }
}
