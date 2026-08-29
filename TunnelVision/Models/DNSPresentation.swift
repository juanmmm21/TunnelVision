import Foundation
import Shared

/// Lo que un mensaje de DNS dice, leído para la rejilla de cabeceras de la pantalla de un paquete
/// (`docs/development/03-roadmap.md`, paso 10).
///
/// Es el primer disector por encima de L4 que llega a la pantalla, y llega **sin pantalla propia**:
/// entra en la misma rejilla que ya nombra IP y UDP, que la segunda pasada estética dejó a propósito
/// capaz de crecer. Lo que cambia es lo que se lee ahí — *Looked up: api.example.com · Record type: A
/// · Answer: 192.0.2.7* donde antes solo ponía *UDP · Datagram length: 76 B*.
///
/// Lo que se calla, y por qué: el identificador de la transacción (esta pantalla describe **un**
/// paquete, así que no puede emparejar la consulta con su respuesta y el número no lleva a ningún
/// sitio), la clase del registro (siempre `IN`), el opcode (siempre consulta estándar en el puerto 53
/// de un teléfono) y el TTL de cada registro (es por registro, y aquí la respuesta se lee como una).

/// Lo que contestó una respuesta, que **no** es la lista de sus registros.
///
/// Es la decisión de esta pantalla y por eso es un valor puro y probado, sin caso por defecto: una
/// respuesta de DNS puede traer un alias, su dirección y de propina un registro que nadie sabe leer,
/// y volcarlos en fila sería un dump, no una lectura. Los cuatro casos son excluyentes y ninguno
/// miente: se dice lo que resolvió, o se dice que no resolvió.
public enum DNSAnswerReading: Sendable, Equatable {

    /// Resolvió a direcciones: lo que el dispositivo iba a marcar a continuación. Es lo que se enseña
    /// **aunque en la respuesta vengan además CNAMEs**, porque el alias es el camino y la dirección es
    /// el destino.
    case addresses([IPAddress])

    /// Resolvió a otro nombre y a nada más: un CNAME sin su dirección detrás, o el PTR de una búsqueda
    /// inversa.
    case name(String)

    /// Contestó con registros que no son ni una dirección ni un nombre —TXT, MX, SOA…—, así que se
    /// dice cuántos y de qué clase en vez de fingir que caben en una línea.
    case records(DNSRecordType, count: Int)

    /// No contestó ningún registro, y el código del servidor dice si es que el nombre no existe, si es
    /// que existe y no tiene registros de ese tipo, o si es un fallo suyo. **Los tres son desenlaces
    /// distintos** y colapsarlos en un "sin respuesta" los haría indistinguibles.
    case nothing(DNSResponseCode)
}

public enum DNSPresentation {

    /// El puerto que hace que un datagrama se lea como DNS.
    ///
    /// Solo el 53, y solo UDP. mDNS (5353) usa el mismo formato y sería el siguiente candidato, pero
    /// **un disector por incremento**: el roadmap lo dice con esas palabras y ampliarlo aquí sería
    /// justo lo que pide no hacer. DNS sobre TCP tampoco entra: lleva delante dos bytes de longitud
    /// que este parser no espera, así que leerlo sería leerlo mal.
    public static let port: UInt16 = 53

    /// Si los bytes de este datagrama hay que intentar leerlos como DNS.
    public static func carriesDNS(_ udp: UDPHeader) -> Bool {
        udp.sourcePort == port || udp.destinationPort == port
    }

    // MARK: - La lectura

    /// Lo que contestó el mensaje, o `nil` si es una consulta: una pregunta no tiene respuesta que
    /// leer, igual que un segmento sin ACK no tiene acuse que enseñar.
    public static func reading(of message: DNSMessage) -> DNSAnswerReading? {
        guard message.isResponse else { return nil }

        let addresses = message.answers.compactMap { record -> IPAddress? in
            guard case .address(let address) = record.data else { return nil }
            return address
        }
        if !addresses.isEmpty { return .addresses(addresses) }

        for record in message.answers {
            if case .name(let name) = record.data { return .name(name) }
        }

        guard let first = message.answers.first else { return .nothing(message.responseCode) }
        return .records(first.type, count: message.answers.count)
    }

    // MARK: - Los datos

    /// Lo que el DNS añade a la rejilla de cabeceras, en el orden en que se lee: de qué clase de
    /// mensaje se trata, qué nombre se buscó, de qué tipo, y qué se contestó.
    ///
    /// **El orden decide las parejas, y por eso es éste.** La rejilla reparte en dos columnas leyendo
    /// por filas, y delante van siempre los cinco datos de un datagrama UDP (versión, protocolo,
    /// origen, destino y longitud), o sea un número impar: con este orden, *Looked up* y *Record
    /// type* —que son las dos mitades de una misma pregunta— caen uno al lado del otro, y la
    /// respuesta queda de cola impar, que es donde tiene que estar lo que no tiene pareja. Es la
    /// misma regla que puso vecinos a *From* y *To*, y como aquélla tiene test.
    public static func facts(for message: DNSMessage) -> [FlowFact] {
        var facts = [kindFact(isResponse: message.isResponse)]

        // La primera y en la práctica la única: el formato admite varias pero ningún resolutor las
        // manda, y enseñar solo la primera de dos sin decirlo sería peor que enseñar una.
        if let question = message.questions.first {
            facts.append(nameFact(question.name))
            facts.append(typeFact(question.type))
        }
        if let reading = reading(of: message) {
            facts.append(answerFact(reading))
        }
        return facts
    }

    private static func kindFact(isResponse: Bool) -> FlowFact {
        FlowFact(
            id: "dnsKind",
            label: String(
                localized: "packetDetail.dns.kind",
                defaultValue: "DNS message",
                comment: """
                    Label of what kind of DNS message this packet carried, next to the \
                    translatable 'Question' or 'Reply' below. It is also what names the protocol \
                    in the grid: without it nothing there says these fields are DNS.
                    """
            ),
            value: .text(
                isResponse
                    ? String(
                        localized: "packetDetail.dns.kind.response",
                        defaultValue: "Reply",
                        comment: """
                            Value shown when the packet is a DNS reply: the device asked a name \
                            server something and this is what came back. It deliberately avoids \
                            the word used by the 'Answer' key below, which labels what the reply \
                            actually carried.
                            """
                    )
                    : String(
                        localized: "packetDetail.dns.kind.query",
                        defaultValue: "Question",
                        comment: """
                            Value shown when the packet is a DNS query: the device asking a name \
                            server about a name. Sibling of the reply value above.
                            """
                    )
            )
        )
    }

    /// El nombre que se buscó. Vale igual para la consulta y para la respuesta, porque una respuesta
    /// de DNS repite dentro la pregunta que contesta.
    private static func nameFact(_ name: String) -> FlowFact {
        FlowFact(
            id: "dnsName",
            label: String(
                localized: "packetDetail.dns.lookedUp",
                defaultValue: "Looked up",
                comment: """
                    Label of the domain name this DNS packet is about, next to a name like \
                    'api.example.com'. The same label serves questions and answers, because a DNS \
                    answer repeats the question it answers.
                    """
            ),
            value: .text(name)
        )
    }

    private static func typeFact(_ type: DNSRecordType) -> FlowFact {
        FlowFact(
            id: "dnsRecordType",
            label: String(
                localized: "packetDetail.dns.recordType",
                defaultValue: "Record type",
                comment: """
                    Label of which kind of DNS record was asked for, next to its name — 'A' for an \
                    IPv4 address, 'AAAA' for IPv6, 'PTR' for a reverse lookup, and so on. Those \
                    names are the protocol's own and are never translated.
                    """
            ),
            value: .text(type.displayName)
        )
    }

    private static func answerFact(_ reading: DNSAnswerReading) -> FlowFact {
        FlowFact(
            id: "dnsAnswer",
            label: String(
                localized: "packetDetail.dns.answer",
                defaultValue: "Answer",
                comment: """
                    Label of what the name server replied with, next to one or more addresses, a \
                    name, or a short phrase saying it replied with nothing. Only present on \
                    replies: a question has no answer to show.
                    """
            ),
            value: .text(answerText(reading))
        )
    }

    private static func answerText(_ reading: DNSAnswerReading) -> String {
        switch reading {
        case .addresses(let addresses):
            // Coma y espacio, no `ListFormatter`, por lo mismo que la lista de resolutores del
            // diagnóstico: son direcciones y no una enumeración que se lea en voz alta, y el "and"
            // final de un formateador de listas las haría parecer prosa.
            return addresses.map(\.description).joined(separator: ", ")

        case .name(let name):
            return name

        case .records(let type, let count):
            return recordsText(type: type, count: count)

        case .nothing(let code):
            return nothingText(code)
        }
    }

    /// Cuántos registros contestó, cuando no son ni direcciones ni nombres.
    ///
    /// Plural con **dos claves hermanas** y jamás el marcado `inflect:`
    /// (`docs/development/02-coding-standards.md`): sin catálogo —y el bundle de tests no lleva
    /// ninguno— ese marcado no se resuelve y saldría crudo.
    private static func recordsText(type: DNSRecordType, count: Int) -> String {
        let name = type.displayName

        guard count != 1 else {
            return String(
                localized: "packetDetail.dns.records.one",
                defaultValue: "1 \(name) record",
                comment: """
                    Value shown where a DNS answer would be when the reply carried exactly one \
                    record this app does not break down (TXT, MX, SOA…). The placeholder is the \
                    record type's own name, never translated. See the plural form in the sibling \
                    key; a language with more plural forms needs both merged into one key with \
                    catalog variations.
                    """
            )
        }

        return String(
            localized: "packetDetail.dns.records.other",
            defaultValue: "\(DisplayFormat.count(UInt64(max(count, 0)))) \(name) records",
            comment: """
                Value shown where a DNS answer would be for any number of records other than one \
                that this app does not break down. The placeholders are how many there are, \
                already grouped, and the record type's own name.
                """
        )
    }

    /// Por qué no hay registros. **No se colapsan**: que un nombre no exista, que exista sin registros
    /// de ese tipo y que el servidor se haya caído son tres cosas distintas, y la primera es la única
    /// que dice algo sobre lo que el dispositivo pidió.
    private static func nothingText(_ code: DNSResponseCode) -> String {
        switch code {
        case .noError:
            return String(
                localized: "packetDetail.dns.empty.noRecords",
                defaultValue: "No records of that type",
                comment: """
                    Value shown where a DNS answer would be when the server replied successfully \
                    but with nothing in it. It is not an error: the name exists, it just has no \
                    record of the kind that was asked for.
                    """
            )
        case .nonExistentDomain:
            return String(
                localized: "packetDetail.dns.empty.noSuchName",
                defaultValue: "No such name",
                comment: """
                    Value shown where a DNS answer would be when the server said the name does \
                    not exist at all (NXDOMAIN). Different from having no records of the type \
                    that was asked for, which is the sibling key above.
                    """
            )
        case .serverFailure:
            return String(
                localized: "packetDetail.dns.empty.serverFailure",
                defaultValue: "Server failure",
                comment: """
                    Value shown where a DNS answer would be when the name server said it failed. \
                    The failure is the server's, not this device's and not this app's.
                    """
            )
        case .refused:
            return String(
                localized: "packetDetail.dns.empty.refused",
                defaultValue: "Refused",
                comment: """
                    Value shown where a DNS answer would be when the name server refused to \
                    answer the question — usually because it does not serve this device.
                    """
            )
        case .formatError:
            return String(
                localized: "packetDetail.dns.empty.formatError",
                defaultValue: "Question not understood",
                comment: """
                    Value shown where a DNS answer would be when the name server said it could \
                    not read the question it was sent (FORMERR).
                    """
            )
        case .notImplemented:
            return String(
                localized: "packetDetail.dns.empty.notImplemented",
                defaultValue: "Not supported by that server",
                comment: """
                    Value shown where a DNS answer would be when the name server said it does not \
                    implement the kind of question it was sent.
                    """
            )
        default:
            // Los códigos que no se conocen se dicen por su número, que es lo único que se sabe de
            // ellos: inventarles una frase sería afirmar algo que nadie ha leído.
            return String(
                localized: "packetDetail.dns.empty.otherCode",
                defaultValue: "Answered with code \(Int(code.rawValue))",
                comment: """
                    Value shown where a DNS answer would be when the server answered with an \
                    error code this app has no name for. The placeholder is the numeric code from \
                    the packet, which is all that is known about it.
                    """
            )
        }
    }

    // MARK: - Cuando no se puede leer

    /// Por qué la rejilla no dice nada del DNS de un datagrama que va por el puerto 53.
    ///
    /// Se dice en vez de callarse, por lo mismo que las cabeceras que no parsean
    /// (`PacketHeaderPresentation`): una pantalla que desmenuza unos paquetes y otros no, sin
    /// explicarlo, se lee como una avería intermitente. Y son dos motivos distintos con dos
    /// desenlaces distintos: el primero lo arregla el usuario en Ajustes y el segundo no lo arregla
    /// nadie.
    public static func unreadNote(for record: CaptureRecord) -> String {
        guard record.isTruncated else {
            return String(
                localized: "packetDetail.dns.unread.unreadable",
                defaultValue: "This went to port 53, but its bytes don't read as a DNS message.",
                comment: """
                    Note under the decoded headers when a UDP datagram on the DNS port carries \
                    something that is not a DNS message. Nothing is broken: the IP and UDP fields \
                    above are still read, and the raw bytes are still shown below.
                    """
            )
        }
        return String(
            localized: "packetDetail.dns.unread.truncated",
            defaultValue: """
                Only \(DisplayFormat.bytes(UInt64(record.capturedLength))) of this packet were \
                saved, which stops short of the whole DNS message. Capture detail is in Settings.
                """,
            comment: """
                Note under the decoded headers when the capture kept too little of a DNS packet to \
                read its message. The placeholder is how much was saved. The last sentence points \
                at the setting that decides it, because this one the user can change; 'Settings' \
                is this app's own screen, named by its tab.
                """
        )
    }
}
