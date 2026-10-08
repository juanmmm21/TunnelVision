import Foundation

/// Cómo queda un dominio frente a la allowlist del proyecto.
public enum AllowlistStanding: Sendable, Hashable {
    /// Lo cubre esta entrada, la primera que coincide: su nota es el porqué de que se esperase.
    case listed(AllowlistEntry)
    /// Ninguna entrada lo cubre.
    case unlisted
    /// El proyecto no tiene allowlist escrita, así que no hay contra qué juzgarlo. No es lo mismo
    /// que `unlisted`: nadie ha dicho qué se espera (`HostGap.allowlistEmpty`).
    case allowlistEmpty

    public init(of host: String, in project: AuditProject) {
        guard !project.allowlist.isEmpty else {
            self = .allowlistEmpty
            return
        }
        if let entry = project.allowlistEntry(matching: host) {
            self = .listed(entry)
        } else {
            self = .unlisted
        }
    }
}

/// De quién era el ClientHello al que contestó una versión de TLS.
///
/// Es lo que separa las cifras que se pueden comparar entre sí de las que no: lo que el servidor
/// le dio al túnel no dice qué le dio a la app, y ponerlas en la misma lista haría pasar por un
/// cambio de la app lo que solo es que una sesión se grabó inspeccionando y la otra no.
public enum TLSNegotiator: Sendable, Hashable, CaseIterable {
    /// La conexión de la app: su ServerHello leído del stream, o QUIC, que lleva TLS 1.3.
    case app
    /// La conexión que el túnel abrió contra el servidor para inspeccionar el flujo.
    case tunnel
}

extension TLSVersionBasis {
    public var negotiator: TLSNegotiator {
        switch self {
        case .serverHello, .quic: return .app
        case .upstreamConnection: return .tunnel
        }
    }
}

/// Qué le pasó a la versión **más baja** que un dominio negoció, de una sesión a la siguiente.
/// Es la que mira un requisito de versión mínima, y por eso es la que se compara.
public enum TLSFloorShift: Sendable, Hashable {
    /// La más baja de la sesión posterior está por debajo de la más baja de la anterior.
    case lowered
    case raised
    /// Las versiones vistas cambiaron, pero la más baja es la misma.
    case held
    /// Alguna de las versiones no es una publicada, y no se puede decir cuál es la más baja.
    case notOrdered
}

/// Por qué no se compararon las versiones de TLS de un dominio que está en las dos sesiones.
public enum TLSComparisonGap: Sendable, Hashable {
    case notReadInEarlierSession
    case notReadInLaterSession
    case notReadInEitherSession
}

/// Las versiones de TLS de un dominio en dos sesiones, para **un** negociador.
public enum TLSVersionComparison: Sendable, Hashable {

    /// Las dos sesiones vieron exactamente las mismas versiones.
    case same([TLSProtocolVersion])

    case different(earlier: [TLSProtocolVersion], later: [TLSProtocolVersion], floor: TLSFloorShift)

    /// En al menos una de las dos sesiones no hay ninguna lectura de este negociador. No se
    /// compara con las del otro: no contestan al mismo ClientHello.
    case notCompared(TLSComparisonGap)

    /// Las listas van por valor de cable ascendente, que entre las versiones publicadas es de la
    /// más baja a la más alta. De un valor sin publicar el sitio que ocupa no dice nada.
    public init(earlier: [TLSVersionSighting], later: [TLSVersionSighting], negotiator: TLSNegotiator) {
        let before = Self.versions(in: earlier, negotiator: negotiator)
        let after = Self.versions(in: later, negotiator: negotiator)
        switch (before.isEmpty, after.isEmpty) {
        case (true, true):
            self = .notCompared(.notReadInEitherSession)
        case (true, false):
            self = .notCompared(.notReadInEarlierSession)
        case (false, true):
            self = .notCompared(.notReadInLaterSession)
        case (false, false):
            self = before == after
                ? .same(after)
                : .different(earlier: before, later: after, floor: Self.floorShift(from: before, to: after))
        }
    }

    private static func versions(
        in sightings: [TLSVersionSighting],
        negotiator: TLSNegotiator
    ) -> [TLSProtocolVersion] {
        let versions = sightings
            .filter { $0.observation.basis.negotiator == negotiator }
            .map(\.observation.version)
        return Set(versions).sorted { $0.rawValue < $1.rawValue }
    }

    /// Las dos listas llegan ordenadas y sin vaciar.
    private static func floorShift(from before: [TLSProtocolVersion], to after: [TLSProtocolVersion]) -> TLSFloorShift {
        guard (before + after).allSatisfy(\.isPublished), let was = before.first, let now = after.first else {
            return .notOrdered
        }
        if now.rawValue < was.rawValue { return .lowered }
        if now.rawValue > was.rawValue { return .raised }
        return .held
    }
}

/// Cómo figura un dominio en una sesión.
public enum DomainPresence: Sendable, Hashable {
    /// Ningún flujo de la sesión lo lleva de nombre, ni atribuido ni de candidato.
    case absent
    /// Solo aparece como uno de varios nombres de una dirección compartida.
    case candidateOnly
    /// Algún flujo fue a él sin alternativa.
    case seen

    public init(_ observation: DomainObservation?) {
        guard let observation else {
            self = .absent
            return
        }
        self = observation.isSeen ? .seen : .candidateOnly
    }
}

/// Lo que el diff afirma de un dominio.
public enum DomainStatus: Sendable, Hashable {
    /// Visto en la sesión posterior y ausente de la anterior.
    case new
    /// Visto en la anterior y ausente de la posterior.
    case gone
    /// Visto en las dos, con lo que cambió de sus versiones de TLS por cada negociador.
    case inBoth(app: TLSVersionComparison, tunnel: TLSVersionComparison)
    /// En alguna de las dos sesiones solo figura como candidato: allí pudo contactarse o no, así
    /// que no es ni nuevo, ni desaparecido, ni sin cambio. Lleva cómo figura en cada lado.
    case undetermined(earlier: DomainPresence, later: DomainPresence)
}

/// Un dominio frente a dos sesiones del mismo proyecto.
public struct DomainComparison: Sendable, Hashable {

    /// Normalizado, como lo cita un hallazgo.
    public let host: String

    public let standing: AllowlistStanding

    /// Lo que cada sesión dice del dominio, o `nil` si no figura en ella. Nunca las dos `nil`.
    public let earlier: DomainObservation?
    public let later: DomainObservation?

    /// `nil` si el dominio no figura en ninguna de las dos: no habría nada que comparar.
    public init?(
        host: String,
        standing: AllowlistStanding,
        earlier: DomainObservation?,
        later: DomainObservation?
    ) {
        guard earlier != nil || later != nil else { return nil }
        self.host = host
        self.standing = standing
        self.earlier = earlier
        self.later = later
    }

    /// Se deriva de las dos observaciones: guardarlo aparte sería un segundo sitio donde decirlo.
    public var status: DomainStatus {
        let before = DomainPresence(earlier)
        let after = DomainPresence(later)
        switch (before, after) {
        case (.absent, .seen):
            return .new
        case (.seen, .absent):
            return .gone
        case (.seen, .seen):
            let was = earlier?.tlsSightings ?? []
            let now = later?.tlsSightings ?? []
            return .inBoth(
                app: TLSVersionComparison(earlier: was, later: now, negotiator: .app),
                tunnel: TLSVersionComparison(earlier: was, later: now, negotiator: .tunnel)
            )
        case (.candidateOnly, _), (_, .candidateOnly), (.absent, .absent):
            return .undetermined(earlier: before, later: after)
        }
    }

    /// Si alguna de sus dos comparaciones de TLS encontró versiones distintas.
    public var hasTLSChange: Bool {
        guard case .inBoth(let app, let tunnel) = status else { return false }
        return [app, tunnel].contains {
            if case .different = $0 { return true }
            return false
        }
    }
}

/// El diff entre dos releases: qué dominios contactó una sesión de auditoría que la anterior del
/// mismo proyecto no, cuáles dejó de contactar, y qué cambió del TLS de los que siguen.
///
/// Es puro —no lee el historial ni el reloj— y, como el clasificador, no decide veredictos. Lo
/// que afirma son **nombres observados**: `gone` es que ningún flujo de la sesión posterior llevó
/// ese nombre, y un flujo sin nombre de ese lado pudo ir justo ahí. Por eso los flujos sin nombre
/// de cada sesión viajan con el diff en vez de quedarse fuera.
public struct ReleaseDiff: Sendable, Hashable {

    /// Por qué dos sesiones no se comparan. Se da el primero que falla, en este orden.
    public enum Refusal: Error, Sendable, Hashable {
        case sameSession
        case differentProjects
        /// El proyecto que se dio no es el de las sesiones: la allowlist sería la de otro.
        case notTheSessionsProject
        /// Una baseline se graba sin la app y no tiene release. Leer una sesión contra su
        /// baseline es otra pregunta —de quién es el tráfico, no qué cambió— y no se contesta
        /// con este tipo.
        case baseline(sessionID: Int64)
        /// La sesión sigue grabando: lo que todavía no ha contactado saldría como desaparecido.
        case stillOpen(sessionID: Int64)
    }

    /// La que empezó antes, y la que empezó después.
    public let earlier: AuditSession
    public let later: AuditSession

    /// Primero los dominios de la sesión posterior, en el orden en que aparecieron en ella;
    /// después los que solo figuran en la anterior, en el orden en que aparecieron allí.
    public let domains: [DomainComparison]

    public let earlierUnnamedFlowIDs: [Int64]
    public let laterUnnamedFlowIDs: [Int64]

    /// Las dos sesiones se dan en cualquier orden: **la posterior es la que empezó después**
    /// (`startedAt`; si coinciden, la de `id` mayor). No se ordenan por versión ni por build
    /// porque son texto libre y no hay regla que ordene `2.4.0 (118)` y `2.4.0-rc1 (2024.3)`;
    /// lo que sí se sabe de dos sesiones es cuál se grabó antes. Las dos releases van en el
    /// resultado, y dos sesiones del mismo build se comparan como cualquier otras.
    ///
    /// - Parameter firstFlows: **todos** los flujos de la sesión, en el orden del historial.
    /// - Parameter project: el proyecto de las dos sesiones. De él solo se lee la allowlist.
    public init(
        between first: AuditSession,
        flows firstFlows: [StoredFlow],
        and second: AuditSession,
        flows secondFlows: [StoredFlow],
        project: AuditProject
    ) throws {
        guard first.id != second.id else { throw Refusal.sameSession }
        guard first.projectID == second.projectID else { throw Refusal.differentProjects }
        guard first.projectID == project.id else { throw Refusal.notTheSessionsProject }
        for session in [first, second] where session.kind.release == nil {
            throw Refusal.baseline(sessionID: session.id)
        }
        for session in [first, second] where session.isOpen {
            throw Refusal.stillOpen(sessionID: session.id)
        }

        let firstIsEarlier = (first.startedAt, first.id) < (second.startedAt, second.id)
        let earlier = SessionDomains(flows: firstIsEarlier ? firstFlows : secondFlows)
        let later = SessionDomains(flows: firstIsEarlier ? secondFlows : firstFlows)
        let earlierByHost = Dictionary(uniqueKeysWithValues: earlier.domains.map { ($0.host, $0) })
        let laterHosts = Set(later.domains.map(\.host))

        let inLater = later.domains.compactMap { observation in
            DomainComparison(
                host: observation.host,
                standing: AllowlistStanding(of: observation.host, in: project),
                earlier: earlierByHost[observation.host],
                later: observation
            )
        }
        let onlyInEarlier = earlier.domains
            .filter { !laterHosts.contains($0.host) }
            .compactMap { observation in
                DomainComparison(
                    host: observation.host,
                    standing: AllowlistStanding(of: observation.host, in: project),
                    earlier: observation,
                    later: nil
                )
            }

        self.earlier = firstIsEarlier ? first : second
        self.later = firstIsEarlier ? second : first
        self.domains = inLater + onlyInEarlier
        self.earlierUnnamedFlowIDs = earlier.unnamedFlowIDs
        self.laterUnnamedFlowIDs = later.unnamedFlowIDs
    }

    public var newDomains: [DomainComparison] {
        domains.filter { $0.status == .new }
    }

    public var goneDomains: [DomainComparison] {
        domains.filter { $0.status == .gone }
    }

    /// Los que las dos sesiones vieron, cambiase o no su TLS.
    public var domainsInBoth: [DomainComparison] {
        domains.filter {
            if case .inBoth = $0.status { return true }
            return false
        }
    }

    public var undeterminedDomains: [DomainComparison] {
        domains.filter {
            if case .undetermined = $0.status { return true }
            return false
        }
    }

    /// El titular del informe: los dominios nuevos que la allowlist no cubre. Con la allowlist
    /// vacía no hay ninguno —nadie ha dicho qué se espera—, y un dominio que solo es candidato
    /// tampoco entra: no se afirma que sea nuevo.
    public var unexpectedNewDomains: [DomainComparison] {
        newDomains.filter { $0.standing == .unlisted }
    }

    /// Los dominios vistos en las dos sesiones cuyas versiones de TLS no son las mismas.
    public var domainsWithTLSChange: [DomainComparison] {
        domains.filter(\.hasTLSChange)
    }
}
