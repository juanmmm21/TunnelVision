import Foundation
import Shared

/// Una sesión con la que la abierta en pantalla se puede comparar.
public struct ReleaseComparisonCandidate: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let title: String
    public let startedAt: Date

    public init(id: Int64, title: String, startedAt: Date) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
    }
}

/// Un dominio de la comparación: su nombre y lo que hay que decir de él.
public struct ReleaseComparisonRow: Sendable, Equatable, Identifiable {
    public var id: String { host }
    public let host: String
    public let detail: String
    /// `warning` es lo que la comparación existe para encontrar: un destino nuevo que la
    /// allowlist no cubre, o un suelo de TLS que bajó. Lo demás es `neutral`.
    public let role: StatusRole

    public init(host: String, detail: String, role: StatusRole) {
        self.host = host
        self.detail = detail
        self.role = role
    }
}

/// Lo que la pantalla de una comparación enseña, ya decidido.
public struct ReleaseComparisonDisplay: Sendable, Equatable {
    public let earlierTitle: String
    public let laterTitle: String
    /// Qué sesión es cuál, dicho en una frase: la posterior es la que **empezó** después, no la
    /// de número de versión mayor, y quien lee la lista tiene que saber contra qué se mide.
    public let direction: String
    public let counts: [AuditFact]
    public let newDomains: [ReleaseComparisonRow]
    public let goneDomains: [ReleaseComparisonRow]
    public let tlsChanges: [ReleaseComparisonRow]
    /// Lo que las listas no pueden decir: conexiones sin nombre y dominios que solo fueron
    /// candidatos de una dirección compartida. `nil` si no hay nada de eso.
    public let caveat: String?

    public init(
        earlierTitle: String,
        laterTitle: String,
        direction: String,
        counts: [AuditFact],
        newDomains: [ReleaseComparisonRow],
        goneDomains: [ReleaseComparisonRow],
        tlsChanges: [ReleaseComparisonRow],
        caveat: String?
    ) {
        self.earlierTitle = earlierTitle
        self.laterTitle = laterTitle
        self.direction = direction
        self.counts = counts
        self.newDomains = newDomains
        self.goneDomains = goneDomains
        self.tlsChanges = tlsChanges
        self.caveat = caveat
    }
}

public enum ReleaseComparisonState: Sendable, Equatable {
    case loading
    case loaded(ReleaseComparisonDisplay)
    case failed(AuditNotice)
}

/// Qué dice la app del diff entre dos releases (`ReleaseDiff`, en `Shared/Audit`).
///
/// El modelo ya decide qué es nuevo, qué desapareció y qué cambió de TLS; aquí se decide **cómo
/// se dice** sin afirmar más que él. Tres reglas lo sujetan:
///
/// - Un dominio nuevo no es una falta: es un destino que la versión anterior no contactó
///   *mientras se grababa*. Solo se marca el que la allowlist no cubre.
/// - Un cambio de TLS dice **quién** negoció cada versión, porque lo que negocia el túnel al
///   inspeccionar no es lo que negocia la app.
/// - Las conexiones sin nombre no están en ninguna lista, y se dice al lado de las listas: sin
///   esa frase, «ningún dominio nuevo» se leería como «ningún destino nuevo».
public enum ReleaseComparisonPresentation {

    /// Las sesiones con las que esta se puede comparar: las otras sesiones **de auditoría** y
    /// **cerradas** del mismo proyecto, de la más reciente a la más antigua. Una baseline no
    /// observa ninguna release y una sesión abierta aún puede ganar conexiones: el modelo las
    /// rechaza, y aquí no se ofrecen.
    public static func candidates(
        forSession id: Int64, in project: AuditProjectOverview
    ) -> [ReleaseComparisonCandidate] {
        guard let session = project.sessions.first(where: { $0.id == id }),
              session.kind.release != nil, !session.isOpen
        else {
            return []
        }
        return project.sessions
            .filter { $0.id != id && $0.kind.release != nil && !$0.isOpen }
            .sorted { ($0.startedAt, $0.id) > ($1.startedAt, $1.id) }
            .map {
                ReleaseComparisonCandidate(
                    id: $0.id,
                    title: AuditPresentation.sessionTitle($0.kind),
                    startedAt: $0.startedAt
                )
            }
    }

    public static func display(of diff: ReleaseDiff) -> ReleaseComparisonDisplay {
        let earlier = AuditPresentation.sessionTitle(diff.earlier.kind)
        let later = AuditPresentation.sessionTitle(diff.later.kind)
        return ReleaseComparisonDisplay(
            earlierTitle: earlier,
            laterTitle: later,
            direction: String(
                localized: "audit.comparison.direction",
                defaultValue: """
                    What \(later) contacted, against what \(earlier) contacted. The later one is \
                    the session that started later, whatever its version number.
                    """,
                comment: """
                    Sentence under the summary of a comparison between two audit sessions. First \
                    placeholder is the name of the later session ('Version 2.4.0 (187)'), second \
                    the earlier one.
                    """
            ),
            counts: [
                AuditFact(label: newDomainsTitle, value: .text(DisplayFormat.count(UInt64(diff.newDomains.count)))),
                AuditFact(label: goneDomainsTitle, value: .text(DisplayFormat.count(UInt64(diff.goneDomains.count)))),
                AuditFact(
                    label: String(
                        localized: "audit.comparison.count.inBoth",
                        defaultValue: "In both",
                        comment: "Label of how many domains two compared audit sessions both contacted, next to a number."
                    ),
                    value: .text(DisplayFormat.count(UInt64(diff.domainsInBoth.count)))
                ),
            ],
            newDomains: diff.newDomains.map { row($0.host, standing: $0.standing, flagsUnlisted: true) },
            goneDomains: diff.goneDomains.map { row($0.host, standing: $0.standing, flagsUnlisted: false) },
            tlsChanges: diff.domainsWithTLSChange.compactMap(tlsChange),
            caveat: caveat(of: diff)
        )
    }

    // MARK: - Títulos

    public static var screenTitle: String {
        String(
            localized: "audit.comparison.title",
            defaultValue: "Comparison",
            comment: "Navigation title of the screen that compares two audit sessions of the same app."
        )
    }

    public static var sectionTitle: String {
        String(
            localized: "audit.comparison.section",
            defaultValue: "Compare with",
            comment: """
                Heading, on an ended audit session's screen, of the list of the project's other \
                sessions it can be compared with. Each row below is a session name.
                """
        )
    }

    public static var sectionFooter: String {
        String(
            localized: "audit.comparison.section.footer",
            defaultValue: """
                Shows the domains one version contacted and the other did not, and where the TLS \
                version changed. A baseline is not compared: it observes no version.
                """,
            comment: "Footer under the list of sessions an audit session can be compared with."
        )
    }

    public static var laterLabel: String {
        String(
            localized: "audit.comparison.later",
            defaultValue: "Later session",
            comment: "Label of the later of two compared audit sessions, next to its name ('Version 2.4.0 (187)')."
        )
    }

    public static var earlierLabel: String {
        String(
            localized: "audit.comparison.earlier",
            defaultValue: "Earlier session",
            comment: "Label of the earlier of two compared audit sessions, next to its name."
        )
    }

    public static var newDomainsTitle: String {
        String(
            localized: "audit.comparison.new",
            defaultValue: "New domains",
            comment: "Heading and count label for the domains the later of two compared sessions contacted and the earlier did not."
        )
    }

    public static var goneDomainsTitle: String {
        String(
            localized: "audit.comparison.gone",
            defaultValue: "No longer contacted",
            comment: "Heading and count label for the domains the earlier of two compared sessions contacted and the later did not."
        )
    }

    public static var tlsChangesTitle: String {
        String(
            localized: "audit.comparison.tls",
            defaultValue: "TLS version changed",
            comment: "Heading for the domains both compared sessions contacted, with a different TLS version in each."
        )
    }

    public static var nothingNew: String {
        String(
            localized: "audit.comparison.new.none",
            defaultValue: "No named domain is new in the later session.",
            comment: """
                Shown instead of the list of new domains when there is none. 'Named' matters: \
                connections without a name are not in this comparison.
                """
        )
    }

    public static var newDomainsFooter: String {
        String(
            localized: "audit.comparison.new.footer",
            defaultValue: """
                A new domain is one the earlier session did not contact while it was recording. \
                It is not attributed to the app: the tunnel sees packets, not apps.
                """,
            comment: "Footer under the list of new domains in a comparison between two audit sessions."
        )
    }

    // MARK: - Filas

    private static func row(
        _ host: String, standing: AllowlistStanding, flagsUnlisted: Bool
    ) -> ReleaseComparisonRow {
        switch standing {
        case .listed:
            return ReleaseComparisonRow(
                host: host,
                detail: String(
                    localized: "audit.comparison.standing.listed",
                    defaultValue: "On the allowlist",
                    comment: "Second line of a domain in a comparison: the project's allowlist covers it."
                ),
                role: .neutral
            )
        case .unlisted:
            return ReleaseComparisonRow(
                host: host,
                detail: String(
                    localized: "audit.comparison.standing.unlisted",
                    defaultValue: "Not on the allowlist",
                    comment: "Second line of a domain in a comparison: the project's allowlist does not cover it."
                ),
                role: flagsUnlisted ? .warning : .neutral
            )
        case .allowlistEmpty:
            // Con la allowlist vacía ningún dominio está «fuera» de ella: no hay con qué medir, y
            // marcarlos todos sería llamar hallazgo a no haber escrito la lista.
            return ReleaseComparisonRow(
                host: host,
                detail: String(
                    localized: "audit.comparison.standing.empty",
                    defaultValue: "The project has no allowlist",
                    comment: "Second line of a domain in a comparison when the project lists no allowed domains at all."
                ),
                role: .neutral
            )
        }
    }

    /// Un dominio cuya versión de TLS cambió, con quién negoció cada una. Si cambió la de la app
    /// se dice esa, que es la que dice algo de la release; la del túnel solo cuando es la única.
    private static func tlsChange(_ comparison: DomainComparison) -> ReleaseComparisonRow? {
        guard case .inBoth(let app, let tunnel) = comparison.status else { return nil }
        if case .different(let earlier, let later, let floor) = app {
            return ReleaseComparisonRow(
                host: comparison.host,
                detail: String(
                    localized: "audit.comparison.tls.app",
                    defaultValue: "The app negotiated \(versions(later)); earlier, \(versions(earlier)).",
                    comment: """
                        Second line of a domain whose TLS version differs between two audit \
                        sessions, read from the app's own connections. First placeholder is the \
                        version(s) in the later session ('TLS 1.2'), second in the earlier.
                        """
                ),
                role: floor == .lowered ? .warning : .neutral
            )
        }
        if case .different(let earlier, let later, let floor) = tunnel {
            return ReleaseComparisonRow(
                host: comparison.host,
                detail: String(
                    localized: "audit.comparison.tls.tunnel",
                    defaultValue: """
                        The server gave TunnelVision's own connection \(versions(later)); earlier, \
                        \(versions(earlier)). This is not what the app negotiated.
                        """,
                    comment: """
                        Second line of a domain whose TLS version differs between two audit \
                        sessions, when the reading comes from the connection TunnelVision opened \
                        to inspect the traffic. Placeholders as in the app's variant.
                        """
                ),
                role: floor == .lowered ? .warning : .neutral
            )
        }
        return nil
    }

    private static func versions(_ versions: [TLSProtocolVersion]) -> String {
        versions.map(FlowHandshakePresentation.name(of:)).formatted(.list(type: .and))
    }

    // MARK: - Lo que las listas no dicen

    private static func caveat(of diff: ReleaseDiff) -> String? {
        var sentences: [String] = []
        let earlierUnnamed = diff.earlierUnnamedFlowIDs.count
        let laterUnnamed = diff.laterUnnamedFlowIDs.count
        if earlierUnnamed + laterUnnamed > 0 {
            sentences.append(
                String(
                    localized: "audit.comparison.caveat.unnamed",
                    defaultValue: """
                        Connections without a name are in none of these lists: \
                        \(DisplayFormat.count(UInt64(laterUnnamed))) in the later session and \
                        \(DisplayFormat.count(UInt64(earlierUnnamed))) in the earlier one. A new \
                        destination among them would not show here.
                        """,
                    comment: """
                        Caveat on a comparison between two audit sessions. Placeholders are \
                        already-formatted counts of connections that had no host name, later \
                        session first.
                        """
                )
            )
        }
        let undetermined = diff.undeterminedDomains.count
        if undetermined > 0 {
            sentences.append(
                String(
                    localized: "audit.comparison.caveat.undetermined",
                    defaultValue: """
                        Domains that appear in a session only as another name of a shared address \
                        are in neither list, because whether they were contacted is not known: \
                        \(DisplayFormat.count(UInt64(undetermined))).
                        """,
                    comment: """
                        Caveat on a comparison between two audit sessions. The placeholder is an \
                        already-formatted count of domains that were only candidates for an \
                        address several names share. Worded so that the count needs no plural.
                        """
                )
            )
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: "\n\n")
    }

    // MARK: - Fallo

    /// Por qué no se pudo comparar. Las negativas del modelo no se alcanzan desde la pantalla —la
    /// lista solo ofrece sesiones comparables—, pero una sesión puede borrarse entre que se
    /// ofrece y que se toca, y eso se dice en vez de dejar un indicador girando.
    public static func failed(_ error: any Error) -> AuditNotice {
        if error is ReleaseDiff.Refusal || error is ReleaseComparisonError {
            return AuditNotice(
                message: String(
                    localized: "audit.comparison.failed.notComparable",
                    defaultValue: "These two sessions can no longer be compared. One of them may have been deleted.",
                    comment: "Shown when a comparison between two audit sessions cannot be made."
                ),
                diagnostic: String(describing: error),
                role: .warning
            )
        }
        return AuditPresentation.refreshFailed(AuditLibraryError.classifying(error))
    }
}

/// Lo que puede faltar al ir a leer una comparación.
public enum ReleaseComparisonError: Error, Sendable, Equatable {
    case sessionNotFound(Int64)
    case projectNotFound(Int64)
}
