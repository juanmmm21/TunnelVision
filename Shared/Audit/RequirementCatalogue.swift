import Foundation

/// Una de las cinco comprobaciones del clasificador. Cada clase de hallazgo es de una sola.
public enum FindingsCheck: String, Sendable, Hashable, CaseIterable {
    case encryption
    case tlsVersion
    case host
    case pinning
    case consent
}

extension FindingKind {

    /// La comprobación que levanta esta clase, y por tanto la que dice cuánto se miró cuando no
    /// hay ningún hallazgo suyo.
    public var check: FindingsCheck {
        switch self {
        case .cleartextTraffic: return .encryption
        case .weakTLSVersion: return .tlsVersion
        case .hostNotInAllowlist, .unnamedFlow: return .host
        case .pinningAbsent, .pinningObserved: return .pinning
        case .activityBeforeConsent: return .consent
        }
    }
}

/// La profundidad con la que el documento manda probar un requisito (TR-03161-1, tabla 2).
public enum TestDepth: String, Sendable, Hashable, CaseIterable {
    case check = "CHECK"
    case examine = "EXAMINE"
}

/// Cómo se llega de los hallazgos de una sesión a lo que se dice de un requisito. Son tres y no
/// hay más: una regla nueva es código nuevo, no una cadena nueva en el JSON.
public enum RequirementRule: Sendable, Hashable {

    /// Nada de lo que la herramienta observa habla de este requisito. Está en el catálogo para
    /// que el informe lo liste como «no evaluado» en vez de callarlo.
    case outsideToolScope

    /// Un hallazgo de estas clases contradice el requisito. Sin ninguno, solo se dice que se
    /// observó sin contradicción si la comprobación tiene flujos en los que pudo mirar.
    case contraryFindings([FindingKind])

    /// Para una comprobación cuyo desenlace favorable también es un hallazgo (la de pinning):
    /// unas clases contradicen el requisito y otras lo apoyan.
    case contraryAndSupportingFindings(contrary: [FindingKind], supporting: [FindingKind])

    /// La comprobación que respalda la regla, o `nil` si no lee ninguna. Una regla no mezcla
    /// comprobaciones: se rechaza al cargar el catálogo.
    public var check: FindingsCheck? {
        switch self {
        case .outsideToolScope: return nil
        case .contraryFindings(let kinds): return kinds.first?.check
        case .contraryAndSupportingFindings(let contrary, _): return contrary.first?.check
        }
    }
}

/// El «Prüfaspekt» al que pertenece un requisito: su número y su nombre en el documento.
public struct RequirementAspect: Sendable, Hashable {
    public let number: Int
    public let name: String

    public init(number: Int, name: String) {
        self.number = number
        self.name = name
    }
}

/// Un requisito del documento, y lo que la herramienta puede decir de él.
public struct Requirement: Sendable, Hashable, Identifiable {

    /// El identificador del documento (`O.Ntwk_1`), tal cual.
    public let id: String

    public let aspect: RequirementAspect

    /// La «Kurzfassung des Prüfaspekts» del documento, en su idioma y sin retocar.
    public let title: String

    public let testDepth: TestDepth

    public let rule: RequirementRule

    /// Qué mira la herramienta de este requisito y qué no. Es texto del catálogo, no del
    /// documento, y va siempre que la regla lee hallazgos: sin él, «observado sin contradicción»
    /// se leería como si se hubiera probado el requisito entero.
    public let toolCoverage: String?

    public init(
        id: String,
        aspect: RequirementAspect,
        title: String,
        testDepth: TestDepth,
        rule: RequirementRule,
        toolCoverage: String?
    ) {
        self.id = id
        self.aspect = aspect
        self.title = title
        self.testDepth = testDepth
        self.rule = rule
        self.toolCoverage = toolCoverage
    }
}

/// El documento del que sale una parte del catálogo, con lo que hace falta para volver a él.
public struct CatalogueSource: Sendable, Hashable {
    public let document: String
    public let title: String
    public let version: String

    /// La fecha de esa versión, `yyyy-MM-dd`.
    public let date: String

    /// El SHA-256 del PDF con el que se verificó el catálogo, en hexadecimal.
    public let sha256: String

    public init(document: String, title: String, version: String, date: String, sha256: String) {
        self.document = document
        self.title = title
        self.version = version
        self.date = date
        self.sha256 = sha256
    }
}

/// Por qué un catálogo no se puede usar. Todo se detecta al cargarlo: un catálogo mal escrito no
/// llega a producir un informe.
public enum RequirementCatalogueError: Error, Sendable, Hashable {
    /// No es el JSON que se espera: falta un campo o tiene otro tipo.
    case malformed(String)
    case unsupportedFormatVersion(Int)
    case emptyField(String)
    case invalidDate(String)
    case invalidDigest(String)
    /// El mínimo de TLS no es una de las versiones que el formato nombra.
    case unknownTLSVersion(String)
    case noRequirements
    case duplicateRequirement(String)
    case unknownTestDepth(requirement: String, value: String)
    case unknownRule(requirement: String, value: String)
    case unknownFindingKind(requirement: String, value: String)
    case ruleShape(requirement: String, problem: RuleShapeProblem)
    case missingToolCoverage(requirement: String)
}

/// En qué no casan la regla de un requisito y las clases de hallazgo que trae.
public enum RuleShapeProblem: Sendable, Hashable {
    case missingContraryKinds
    case unexpectedContraryKinds
    case missingSupportingKinds
    case unexpectedSupportingKinds
    case repeatedKind(FindingKind)
    /// Las clases son de comprobaciones distintas, y entonces no habría una sola cobertura que
    /// dijera cuánto se miró.
    case kindsOfSeveralChecks
}

/// Un catálogo de requisitos: una versión de un documento, lo que la herramienta puede decir de
/// cada requisito suyo y los umbrales con los que se clasifica.
public struct RequirementCatalogue: Sendable, Hashable {

    /// La única versión del formato que este código lee.
    public static let formatVersion = 1

    /// El nombre del recurso, sin extensión: lo que guarda `AuditProject.catalogueVersion`.
    public let identifier: String

    public let source: CatalogueSource

    /// De dónde sale el mínimo de TLS, que es de otro documento que los requisitos.
    public let tlsSource: CatalogueSource

    public let policy: FindingsPolicy

    /// En el orden del catálogo, que es el del documento.
    public let requirements: [Requirement]

    public init(data: Data) throws {
        let file: CatalogueFile
        do {
            file = try JSONDecoder().decode(CatalogueFile.self, from: data)
        } catch {
            throw RequirementCatalogueError.malformed(String(describing: error))
        }
        guard file.formatVersion == Self.formatVersion else {
            throw RequirementCatalogueError.unsupportedFormatVersion(file.formatVersion)
        }

        self.identifier = try Self.nonEmpty(file.identifier, "identifier")
        self.source = try Self.source(file.source, field: "source")
        self.tlsSource = try Self.source(file.tls.source, field: "tls.source")

        guard let minimum = Self.tlsVersions[file.tls.minimumVersion],
              let policy = FindingsPolicy(minimumTLSVersion: minimum) else {
            throw RequirementCatalogueError.unknownTLSVersion(file.tls.minimumVersion)
        }
        self.policy = policy

        guard !file.requirements.isEmpty else { throw RequirementCatalogueError.noRequirements }
        var seen: Set<String> = []
        var requirements: [Requirement] = []
        for entry in file.requirements {
            let requirement = try Self.requirement(entry)
            guard seen.insert(requirement.id).inserted else {
                throw RequirementCatalogueError.duplicateRequirement(requirement.id)
            }
            requirements.append(requirement)
        }
        self.requirements = requirements
    }

    // El mínimo se escribe como lo escribe el documento («1.2») y no como su valor en el cable:
    // un catálogo lo corrige quien evalúa contra la TR, no quien conoce el registro de TLS.
    private static let tlsVersions: [String: TLSProtocolVersion] = [
        "1.0": .tls10, "1.1": .tls11, "1.2": .tls12, "1.3": .tls13,
    ]

    private static func nonEmpty(_ value: String, _ field: String) throws -> String {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RequirementCatalogueError.emptyField(field)
        }
        return value
    }

    private static func source(_ file: CatalogueFile.Source, field: String) throws -> CatalogueSource {
        let date = try nonEmpty(file.date, "\(field).date")
        guard (try? Date(date, strategy: .iso8601.year().month().day())) != nil, date.count == 10 else {
            throw RequirementCatalogueError.invalidDate(date)
        }
        let isDigest = file.sha256.count == 64
            && file.sha256.allSatisfy { $0.isASCII && $0.isHexDigit && !$0.isUppercase }
        guard isDigest else { throw RequirementCatalogueError.invalidDigest(file.sha256) }
        return CatalogueSource(
            document: try nonEmpty(file.document, "\(field).document"),
            title: try nonEmpty(file.title, "\(field).title"),
            version: try nonEmpty(file.version, "\(field).version"),
            date: date,
            sha256: file.sha256
        )
    }

    private static func requirement(_ file: CatalogueFile.Requirement) throws -> Requirement {
        let id = try nonEmpty(file.id, "requirements.id")
        guard let depth = TestDepth(rawValue: file.testDepth) else {
            throw RequirementCatalogueError.unknownTestDepth(requirement: id, value: file.testDepth)
        }
        let contrary = try kinds(file.contraryKinds, requirement: id)
        let supporting = try kinds(file.supportingKinds, requirement: id)
        let rule = try rule(named: file.rule, contrary: contrary, supporting: supporting, requirement: id)

        let coverage = file.toolCoverage?.trimmingCharacters(in: .whitespacesAndNewlines)
        if rule.check != nil, coverage?.isEmpty ?? true {
            throw RequirementCatalogueError.missingToolCoverage(requirement: id)
        }
        return Requirement(
            id: id,
            aspect: RequirementAspect(
                number: file.aspect.number,
                name: try nonEmpty(file.aspect.name, "\(id).aspect.name")
            ),
            title: try nonEmpty(file.title, "\(id).title"),
            testDepth: depth,
            rule: rule,
            toolCoverage: (coverage?.isEmpty ?? true) ? nil : coverage
        )
    }

    private static func kinds(_ names: [String]?, requirement: String) throws -> [FindingKind] {
        try (names ?? []).map { name in
            guard let kind = FindingKind(rawValue: name) else {
                throw RequirementCatalogueError.unknownFindingKind(requirement: requirement, value: name)
            }
            return kind
        }
    }

    private static func rule(
        named name: String,
        contrary: [FindingKind],
        supporting: [FindingKind],
        requirement: String
    ) throws -> RequirementRule {
        func refuse(_ problem: RuleShapeProblem) -> RequirementCatalogueError {
            .ruleShape(requirement: requirement, problem: problem)
        }
        var seen: Set<FindingKind> = []
        for kind in contrary + supporting where !seen.insert(kind).inserted {
            throw refuse(.repeatedKind(kind))
        }
        guard Set(seen.map(\.check)).count <= 1 else { throw refuse(.kindsOfSeveralChecks) }

        switch name {
        case "outsideToolScope":
            guard contrary.isEmpty else { throw refuse(.unexpectedContraryKinds) }
            guard supporting.isEmpty else { throw refuse(.unexpectedSupportingKinds) }
            return .outsideToolScope
        case "contraryFindings":
            guard !contrary.isEmpty else { throw refuse(.missingContraryKinds) }
            guard supporting.isEmpty else { throw refuse(.unexpectedSupportingKinds) }
            return .contraryFindings(contrary)
        case "contraryAndSupportingFindings":
            guard !contrary.isEmpty else { throw refuse(.missingContraryKinds) }
            guard !supporting.isEmpty else { throw refuse(.missingSupportingKinds) }
            return .contraryAndSupportingFindings(contrary: contrary, supporting: supporting)
        default:
            throw RequirementCatalogueError.unknownRule(requirement: requirement, value: name)
        }
    }
}

/// El JSON tal cual está escrito. Todo son cadenas hasta que `RequirementCatalogue` las valida,
/// para que un valor desconocido se rechace diciendo en qué requisito está.
private struct CatalogueFile: Decodable {
    let formatVersion: Int
    let identifier: String
    let source: Source
    let tls: TLS
    let requirements: [Requirement]

    struct Source: Decodable {
        let document: String
        let title: String
        let version: String
        let date: String
        let sha256: String
    }

    struct TLS: Decodable {
        let minimumVersion: String
        let source: Source
    }

    struct Aspect: Decodable {
        let number: Int
        let name: String
    }

    struct Requirement: Decodable {
        let id: String
        let aspect: Aspect
        let title: String
        let testDepth: String
        let rule: String
        let contraryKinds: [String]?
        let supportingKinds: [String]?
        let toolCoverage: String?
    }
}
