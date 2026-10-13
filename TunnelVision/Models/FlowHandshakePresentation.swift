import Foundation
import Shared

/// Lo que la ficha de una conexión dice de **cómo se cifró**: qué versión eligió el servidor y de
/// dónde sale esa lectura, qué ofreció la app, y el certificado cuando viajó en claro.
///
/// Son los mismos campos que el paquete de evidencia escribe en `flows.json`, y hasta aquí solo se
/// veían exportando una sesión: quien mira una conexión en la Timeline no tenía dónde leerlos.
///
/// Va en su propia sección y no en la rejilla de la cabecera por dos motivos. La cabecera la tiene
/// toda conexión y esto no —un ping no negocia nada—, así que dentro de ella habría que elegir
/// entre huecos y una rejilla de largo variable. Y cada dato de aquí lleva una salvedad que la
/// rejilla no encaja: de quién es la lectura, que el certificado no se validó.
public struct FlowHandshakeSection: Sendable, Equatable {

    /// En pares, como la cabecera: la rejilla los reparte en dos columnas leyendo por filas.
    public let facts: [FlowFact]

    /// Las salvedades sobre esos datos, en el orden de los datos a los que se refieren. Van fuera
    /// de la rejilla por lo mismo que `sharedAddressNote`: son frases, no cifras.
    public let notes: [String]

    public init(facts: [FlowFact], notes: [String]) {
        precondition(facts.count.isMultiple(of: 2), "la rejilla es de dos columnas: los datos entran de dos en dos")
        self.facts = facts
        self.notes = notes
    }
}

public enum FlowHandshakePresentation {

    /// La sección, o `nil` si de la conexión no se leyó nada de esto: lo que no es TLS ni QUIC, y
    /// un flujo cuyo arranque no se llegó a ver.
    public static func section(for flow: HistoryFlow) -> FlowHandshakeSection? {
        let stored = flow.stored
        var facts: [FlowFact] = []
        var notes: [String] = []

        if let quic = stored.quic {
            facts += quicFacts(quic)
            notes.append(quicNote(quic))
        } else if let answer = stored.serverTLS {
            facts += answerFacts(answer)
            if case .negotiated(let negotiated) = answer, negotiated.source == .upstreamConnection {
                notes.append(upstreamNote)
            }
        }

        if let offer = stored.clientTLS {
            facts += offerFacts(offer)
            if offer.hasEncryptedClientHello { notes.append(encryptedClientHelloNote) }
            // Sin respuesta del servidor y sin ser QUIC, la oferta sola se leería como lo que se
            // negoció: se dice que la otra mitad falta.
            if stored.serverTLS == nil, stored.quic == nil { notes.append(answerNotReadNote) }
        }

        guard !facts.isEmpty else { return nil }

        // El certificado es de TLS sobre TCP: en QUIC va siempre cifrado y la frase de QUIC ya lo
        // cubre, así que ahí no se dice dos veces.
        if stored.quic == nil {
            switch stored.certificateVisibility {
            case .presented(let chain):
                if let leaf = chain.certificates.first {
                    facts += certificateFacts(leaf)
                    notes.append(certificateNote(leaf))
                }
            case .notSent(let absence):
                notes.append(certificateNotSentNote(absence))
            case .encryptedInHandshake:
                notes.append(certificateEncryptedNote)
            case .replacedByInspection:
                notes.append(certificateReplacedNote)
            case .noNegotiation, .notRead:
                // Lo primero ya lo dice la fila de la versión («Refused»); lo segundo no es un hecho
                // sobre la conexión sino la ausencia de uno, y una frase por cada cosa que no se
                // leyó convertiría la sección en una lista de lagunas.
                break
            }
        }
        return FlowHandshakeSection(facts: facts, notes: notes)
    }

    public static var sectionTitle: String {
        String(
            localized: "flowInspector.handshake.title",
            defaultValue: "How it was encrypted",
            comment: """
                Heading of the section of a connection's screen that lists what was read from its \
                TLS or QUIC handshake: the version, what the app offered, the certificate.
                """
        )
    }

    // MARK: - Versiones

    /// El nombre de una versión de TLS, o su número tal como viajó si no es una de las publicadas:
    /// un borrador o un valor inventado son evidencia y se enseñan como llegaron.
    public static func name(of version: TLSProtocolVersion) -> String {
        switch version {
        case .ssl30: return "SSL 3.0"
        case .tls10: return "TLS 1.0"
        case .tls11: return "TLS 1.1"
        case .tls12: return "TLS 1.2"
        case .tls13: return "TLS 1.3"
        default: return String(format: "0x%04X", version.rawValue)
        }
    }

    /// Una versión de QUIC: las dos del IETF por su número de versión y cualquier otra por el
    /// valor de su cabecera.
    public static func name(of version: QUICVersion) -> String {
        switch version {
        case .v1:
            return String(
                localized: "flowInspector.handshake.quic.v1",
                defaultValue: "Version 1",
                comment: "Value of a connection's 'QUIC version' fact: QUIC version 1 (RFC 9000)."
            )
        case .v2:
            return String(
                localized: "flowInspector.handshake.quic.v2",
                defaultValue: "Version 2",
                comment: "Value of a connection's 'QUIC version' fact: QUIC version 2 (RFC 9369)."
            )
        default:
            return String(format: "0x%08X", version.rawValue)
        }
    }

    // MARK: - Los datos

    private static func answerFacts(_ answer: ServerTLSAnswer) -> [FlowFact] {
        let version: String
        let source: String
        switch answer {
        case .negotiated(let negotiated):
            version = name(of: negotiated.version)
            switch negotiated.source {
            case .serverHello: source = sourceServerAnswer
            case .upstreamConnection:
                source = String(
                    localized: "flowInspector.handshake.source.tunnel",
                    defaultValue: "Tunnel's connection",
                    comment: """
                        Value of a connection's 'Read from' fact when the TLS version shown is the \
                        one the server negotiated with the connection TunnelVision itself opened \
                        to inspect the traffic, not with the app. Must fit half a screen's width.
                        """
                )
            }
        case .refused(let alert):
            version = String(
                localized: "flowInspector.handshake.version.refused",
                defaultValue: "Refused (alert \(String(alert)))",
                comment: """
                    Value of a connection's 'TLS version' fact when the server answered the \
                    handshake with an alert instead of negotiating. The placeholder is the TLS \
                    alert code, a number from 0 to 255.
                    """
            )
            source = sourceServerAnswer
        }
        return [
            FlowFact(
                id: "tlsVersion",
                label: String(
                    localized: "flowInspector.handshake.fact.tlsVersion",
                    defaultValue: "TLS version",
                    comment: "Label of the TLS version the server chose for a connection, next to a value like 'TLS 1.3'."
                ),
                value: .text(version)
            ),
            FlowFact(id: "tlsSource", label: readFromLabel, value: .text(source)),
        ]
    }

    private static func quicFacts(_ quic: QUICVersionReading) -> [FlowFact] {
        let source: String
        switch quic.source {
        case .server:
            source = String(
                localized: "flowInspector.handshake.source.quicServer",
                defaultValue: "Server's packets",
                comment: """
                    Value of a connection's 'Read from' fact when its QUIC version was read from \
                    a packet the server sent: it is the version in use.
                    """
            )
        case .client:
            source = String(
                localized: "flowInspector.handshake.source.quicClient",
                defaultValue: "App's packets",
                comment: """
                    Value of a connection's 'Read from' fact when its QUIC version was read only \
                    from packets the app sent: it is the version proposed, and the server may not \
                    have accepted it.
                    """
            )
        }
        return [
            FlowFact(
                id: "quicVersion",
                label: String(
                    localized: "flowInspector.handshake.fact.quicVersion",
                    defaultValue: "QUIC version",
                    comment: "Label of the QUIC version of a connection, next to a value like 'Version 1'."
                ),
                value: .text(name(of: quic.version))
            ),
            FlowFact(id: "quicSource", label: readFromLabel, value: .text(source)),
        ]
    }

    private static func offerFacts(_ offer: ClientTLSOffer) -> [FlowFact] {
        let versions: String
        switch offer.versions {
        case .listed(let listed) where listed.isEmpty:
            versions = nothingOffered
        case .listed(let listed):
            versions = listed.map(name(of:)).formatted(.list(type: .and, width: .narrow))
        case .upTo(let ceiling):
            // Un techo no es una lista: el ClientHello dice hasta dónde llega el cliente y calla
            // lo que acepta por debajo, y redactarlo como lista afirmaría un suelo que no viajó.
            versions = String(
                localized: "flowInspector.handshake.offer.upTo",
                defaultValue: "Up to \(name(of: ceiling))",
                comment: """
                    Value of a connection's 'App offered' fact when the app's handshake named \
                    only the highest TLS version it accepts. The placeholder is that version, \
                    like 'TLS 1.2'. It must read as a ceiling, never as a list of one.
                    """
            )
        }
        return [
            FlowFact(
                id: "offeredVersions",
                label: String(
                    localized: "flowInspector.handshake.fact.offered",
                    defaultValue: "App offered",
                    comment: """
                        Label of the TLS versions the app said it would accept when it opened a \
                        connection, next to a value like 'TLS 1.3, TLS 1.2'.
                        """
                ),
                value: .text(versions)
            ),
            FlowFact(
                id: "offeredProtocols",
                label: String(
                    localized: "flowInspector.handshake.fact.protocols",
                    defaultValue: "Protocols offered",
                    comment: """
                        Label of the application protocols (ALPN) the app offered when it opened \
                        a connection, next to a value like 'h2, http/1.1'.
                        """
                ),
                value: .text(
                    offer.applicationProtocols.isEmpty
                        ? nothingOffered
                        : offer.applicationProtocols.formatted(.list(type: .and, width: .narrow))
                )
            ),
        ]
    }

    private static func certificateFacts(_ leaf: ServerCertificate) -> [FlowFact] {
        [
            FlowFact(
                id: "certificateSubject",
                label: String(
                    localized: "flowInspector.handshake.fact.certificate",
                    defaultValue: "Certificate",
                    comment: """
                        Label of the subject of the certificate a server presented for a \
                        connection, next to a value like 'CN=www.example.com'.
                        """
                ),
                value: .text(leaf.subject.text)
            ),
            FlowFact(
                id: "certificateExpiry",
                label: String(
                    localized: "flowInspector.handshake.fact.expires",
                    defaultValue: "Expires",
                    comment: "Label of the date a server's certificate stops being valid, next to that date."
                ),
                value: .text(leaf.notAfter.formatted(date: .abbreviated, time: .omitted))
            ),
        ]
    }

    // MARK: - Rótulos y valores compartidos

    private static var readFromLabel: String {
        String(
            localized: "flowInspector.handshake.fact.readFrom",
            defaultValue: "Read from",
            comment: """
                Label, in a connection's encryption facts, of where the version beside it was \
                read: the server's own answer, the tunnel's connection, or one side's packets.
                """
        )
    }

    private static var sourceServerAnswer: String {
        String(
            localized: "flowInspector.handshake.source.server",
            defaultValue: "Server's answer",
            comment: """
                Value of a connection's 'Read from' fact when the TLS version shown was read from \
                the server's own reply to the app's handshake.
                """
        )
    }

    private static var nothingOffered: String {
        String(
            localized: "flowInspector.handshake.offer.none",
            defaultValue: "None",
            comment: """
                Value of 'App offered' or 'Protocols offered' when the app's handshake carried \
                none: a statement of what was read, not a missing reading.
                """
        )
    }

    // MARK: - Las salvedades

    private static var upstreamNote: String {
        String(
            localized: "flowInspector.handshake.note.upstream",
            defaultValue: """
                The version is what the server negotiated with the connection TunnelVision opened \
                to it, not with the app. What the app would have negotiated on its own was not seen.
                """,
            comment: """
                Caveat under a connection's encryption facts when TunnelVision terminated the \
                connection (to inspect it, or the app refused its certificate): the TLS version \
                shown belongs to the tunnel's own connection to the server.
                """
        )
    }

    private static var answerNotReadNote: String {
        String(
            localized: "flowInspector.handshake.note.answerNotRead",
            defaultValue: "The server's answer was not read, so the version the two agreed on is not known.",
            comment: """
                Caveat under a connection's encryption facts when only the app's offer was read \
                and the server's reply was not.
                """
        )
    }

    private static var encryptedClientHelloNote: String {
        String(
            localized: "flowInspector.handshake.note.encryptedClientHello",
            defaultValue: """
                The app's handshake carried an encrypted part. What is shown is the outer offer; \
                the real one may be inside it and differ.
                """,
            comment: """
                Caveat under a connection's encryption facts when the app's ClientHello carried \
                the Encrypted Client Hello extension: the offer read may not be the real one.
                """
        )
    }

    private static func quicNote(_ quic: QUICVersionReading) -> String {
        guard quic.version.hasKnownPacketProtection else {
            return String(
                localized: "flowInspector.handshake.note.quicUnknown",
                defaultValue: "TunnelVision does not know this QUIC version, so it states nothing about how it encrypts.",
                comment: """
                    Caveat under a connection's encryption facts when its QUIC version is not one \
                    of the two standard ones: nothing is claimed about its encryption.
                    """
            )
        }
        switch quic.source {
        case .server:
            return String(
                localized: "flowInspector.handshake.note.quic",
                defaultValue: """
                    This QUIC version encrypts every packet with TLS 1.3. Its server's answer and \
                    certificate travel encrypted and are never read.
                    """,
                comment: """
                    Caveat under a connection's encryption facts for a QUIC connection whose \
                    version the server confirmed: QUIC versions 1 and 2 always use TLS 1.3.
                    """
            )
        case .client:
            return String(
                localized: "flowInspector.handshake.note.quicProposed",
                defaultValue: """
                    This is the version the app proposed. No packet from the server was read, so \
                    the version actually in use is not known.
                    """,
                comment: """
                    Caveat under a connection's encryption facts for a QUIC connection whose \
                    version was read only from the app's packets.
                    """
            )
        }
    }

    private static func certificateNote(_ leaf: ServerCertificate) -> String {
        String(
            localized: "flowInspector.handshake.note.certificate",
            defaultValue: """
                Issued by \(leaf.issuer.text). Shown as the server presented it; nothing about it \
                was validated.
                """,
            comment: """
                Caveat under a connection's encryption facts when the server's certificate was \
                read. The placeholder is the issuer's name as written in the certificate \
                ('CN=Example CA').
                """
        )
    }

    private static func certificateNotSentNote(_ absence: ServerCertificateAbsence) -> String {
        switch absence {
        case .resumedSession:
            return String(
                localized: "flowInspector.handshake.note.certificateResumed",
                defaultValue: "The server sent no certificate: the connection resumed an earlier session.",
                comment: "Caveat under a connection's encryption facts when TLS session resumption meant no certificate was sent."
            )
        case .noCertificateMessage:
            return String(
                localized: "flowInspector.handshake.note.certificateAbsent",
                defaultValue: "The server's handshake carried no certificate.",
                comment: "Caveat under a connection's encryption facts when the handshake was read and had no certificate message."
            )
        }
    }

    private static var certificateEncryptedNote: String {
        String(
            localized: "flowInspector.handshake.note.certificateEncrypted",
            defaultValue: "TLS 1.3 sends the server's certificate encrypted, so it was not seen.",
            comment: "Caveat under a connection's encryption facts for a TLS 1.3 connection: its certificate is never visible on the wire."
        )
    }

    private static var certificateReplacedNote: String {
        String(
            localized: "flowInspector.handshake.note.certificateReplaced",
            defaultValue: "The certificate the app received was TunnelVision's own; the server's is not recorded.",
            comment: """
                Caveat under a connection's encryption facts when TunnelVision terminated the \
                connection: the app was shown the local inspection certificate.
                """
        )
    }
}
