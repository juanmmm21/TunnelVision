import Foundation
import Shared

/// Lo que un formulario de auditoría tiene mal, dicho de forma que la pantalla pueda señalar **dónde**.
///
/// Se valida aquí y no solo en el store por dos razones: el store rechaza con el patrón ya
/// normalizado y sin saber en qué línea estaba, y lo que el usuario necesita es que se le señale la
/// línea que escribió; y un borrador que el store va a rechazar no tiene por qué llegar a abrir la
/// base de datos. Es un `Error` porque es la mitad de fallo de un `Result`, no porque se lance.
public enum AuditFormIssue: Error, Sendable, Equatable {

    case emptyProjectName

    /// Una línea de la allowlist que no es un patrón. Lleva la línea para poder marcarla.
    case invalidPattern(line: UUID, reason: DomainPattern.ParseError)

    /// El mismo patrón en dos líneas, una vez normalizado. Lleva la **segunda**, que es la que sobra.
    case duplicatePattern(line: UUID, pattern: String)

    /// Una nota en una línea sin patrón: quien la escribió creía estar permitiendo algo.
    case noteWithoutPattern(line: UUID)

    /// Una sesión de auditoría sin versión o sin build. Las dos identifican el binario observado.
    case missingRelease

    /// La línea a la que se refiere, si se refiere a una.
    public var line: UUID? {
        switch self {
        case .invalidPattern(let line, _), .duplicatePattern(let line, _), .noteWithoutPattern(let line):
            line
        case .emptyProjectName, .missingRelease:
            nil
        }
    }
}

/// Una línea de la allowlist mientras se escribe: texto libre en los dos campos.
public struct AllowlistLine: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var pattern: String
    public var note: String

    public init(id: UUID = UUID(), pattern: String = "", note: String = "") {
        self.id = id
        self.pattern = pattern
        self.note = note
    }

    /// Una línea sin nada escrito no es un error: es la que el formulario deja lista para la
    /// siguiente entrada, y se ignora al guardar.
    var isBlank: Bool {
        pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// El formulario de un proyecto: lo que el usuario teclea, antes de ser un `AuditProjectDraft`.
public struct AuditProjectForm: Sendable, Equatable {

    public var name: String
    public var bundleIdentifier: String
    public var lines: [AllowlistLine]

    /// El catálogo de requisitos del proyecto. No se edita todavía —no hay ninguno que elegir—, pero
    /// viaja con el formulario para que editar un proyecto no se lo borre.
    public let catalogueVersion: String?

    /// Un formulario en blanco, con una línea lista para escribir.
    public init() {
        self.name = ""
        self.bundleIdentifier = ""
        self.lines = [AllowlistLine()]
        self.catalogueVersion = nil
    }

    /// El formulario de un proyecto que ya existe.
    public init(editing project: AuditProject) {
        self.name = project.name
        self.bundleIdentifier = project.bundleIdentifier ?? ""
        self.lines = project.allowlist.map {
            AllowlistLine(pattern: $0.pattern.text, note: $0.note ?? "")
        }
        self.catalogueVersion = project.catalogueVersion
    }

    /// El borrador que este formulario describe, o lo primero que tiene mal.
    ///
    /// Devuelve **un** problema y no la lista: el formulario se corrige de arriba abajo, y una
    /// pantalla con cuatro avisos a la vez no dice por dónde empezar.
    public func draft() -> Result<AuditProjectDraft, AuditFormIssue> {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return .failure(.emptyProjectName) }

        var entries: [AllowlistEntry] = []
        var seen: Set<DomainPattern> = []
        for line in lines where !line.isBlank {
            let text = line.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .failure(.noteWithoutPattern(line: line.id)) }

            let pattern: DomainPattern
            do {
                pattern = try DomainPattern(parsing: text)
            } catch let reason as DomainPattern.ParseError {
                return .failure(.invalidPattern(line: line.id, reason: reason))
            } catch {
                // `DomainPattern(parsing:)` solo lanza `ParseError`; esto existe porque el
                // compilador no lo sabe, y se cuenta como un patrón vacío antes que tragárselo.
                return .failure(.invalidPattern(line: line.id, reason: .empty))
            }
            guard seen.insert(pattern).inserted else {
                return .failure(.duplicatePattern(line: line.id, pattern: pattern.text))
            }

            let note = line.note.trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append(AllowlistEntry(pattern: pattern, note: note.isEmpty ? nil : note))
        }

        let bundle = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(
            AuditProjectDraft(
                name: trimmedName,
                bundleIdentifier: bundle.isEmpty ? nil : bundle,
                catalogueVersion: catalogueVersion,
                allowlist: entries
            )
        )
    }
}

/// Qué papel va a jugar la sesión que se abre. Es el `AuditSessionKind` sin su valor asociado, que
/// es lo que un selector puede enseñar: la versión y el build se escriben aparte.
public enum AuditSessionRole: Sendable, Equatable, CaseIterable {
    case audit
    case baseline
}

/// El formulario con el que se abre una sesión.
public struct AuditSessionForm: Sendable, Equatable {

    public var role: AuditSessionRole
    public var version: String
    public var build: String
    public var notes: String

    /// El papel con el que arranca el formulario lo decide quien lo abre, y no un valor por defecto:
    /// un proyecto sin baseline debería empezar por ella, y uno que ya la tiene, por una auditoría
    /// (`AuditSessionForm.suggestedRole`).
    public init(role: AuditSessionRole) {
        self.role = role
        self.version = ""
        self.build = ""
        self.notes = ""
    }

    /// Qué papel proponer para la siguiente sesión de un proyecto: la baseline mientras no haya
    /// ninguna —sin ella no hay contra qué leer el tráfico de la app (ADR 0008)—, y una auditoría
    /// después.
    public static func suggestedRole(existing sessions: [AuditSession]) -> AuditSessionRole {
        sessions.contains { $0.kind == .baseline } ? .audit : .baseline
    }

    /// El tipo de sesión que este formulario describe, o lo que le falta.
    public func kind() -> Result<AuditSessionKind, AuditFormIssue> {
        switch role {
        case .baseline:
            return .success(.baseline)
        case .audit:
            let version = version.trimmingCharacters(in: .whitespacesAndNewlines)
            let build = build.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !version.isEmpty, !build.isEmpty else { return .failure(.missingRelease) }
            return .success(.audit(AppRelease(version: version, build: build)))
        }
    }

    public var trimmedNotes: String {
        notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension AuditPresentation {

    // MARK: - El formulario de un proyecto

    public static var newProjectFormTitle: String {
        String(
            localized: "audit.projectForm.title.new",
            defaultValue: "New project",
            comment: "Title of the form that creates an audit project."
        )
    }

    public static var editProjectFormTitle: String {
        String(
            localized: "audit.projectForm.title.edit",
            defaultValue: "Edit project",
            comment: "Title of the form that changes an existing audit project."
        )
    }

    public static var projectNameFieldTitle: String {
        String(
            localized: "audit.projectForm.name",
            defaultValue: "Name",
            comment: """
                Label of the field for an audit project's name: usually the audited app's name. \
                It heads the report.
                """
        )
    }

    public static var projectNameFieldPrompt: String {
        String(
            localized: "audit.projectForm.name.prompt",
            defaultValue: "The app you are auditing",
            comment: "Placeholder of the audit project's name field."
        )
    }

    public static var projectBundleFieldPrompt: String {
        String(
            localized: "audit.projectForm.bundle.prompt",
            defaultValue: "com.example.app (optional)",
            comment: """
                Placeholder of the audited app's bundle identifier field. 'com.example.app' is a \
                literal example and is not translated; the field may be left empty.
                """
        )
    }

    public static var allowlistPatternFieldPrompt: String {
        String(
            localized: "audit.projectForm.allowlist.pattern.prompt",
            defaultValue: "api.example.com",
            comment: """
                Placeholder of an allowlist line's domain field. It is a literal example of a \
                domain name and is not translated.
                """
        )
    }

    public static var allowlistNoteFieldPrompt: String {
        String(
            localized: "audit.projectForm.allowlist.note.prompt",
            defaultValue: "What it is for (optional)",
            comment: """
                Placeholder of an allowlist line's note field: why the domain is expected, such \
                as 'backend' or 'crash reporting'. It goes into the report.
                """
        )
    }

    /// Los nombres de los campos, que solo se **oyen**: a la vista los explica su texto de muestra,
    /// pero un campo relleno ya no lo enseña y VoiceOver leería solo lo tecleado.
    public static var allowlistPatternFieldTitle: String {
        String(
            localized: "audit.projectForm.allowlist.pattern",
            defaultValue: "Domain",
            comment: "VoiceOver name of an allowlist line's domain field in the audit project form."
        )
    }

    public static var allowlistNoteFieldTitle: String {
        String(
            localized: "audit.projectForm.allowlist.note",
            defaultValue: "Note",
            comment: "VoiceOver name of an allowlist line's note field in the audit project form."
        )
    }

    public static var versionFieldTitle: String {
        String(
            localized: "audit.sessionForm.version",
            defaultValue: "Version",
            comment: "VoiceOver name of the audited app's version field in the audit session form."
        )
    }

    public static var buildFieldTitle: String {
        String(
            localized: "audit.sessionForm.build",
            defaultValue: "Build",
            comment: "VoiceOver name of the audited app's build number field in the audit session form."
        )
    }

    public static var addAllowlistLineActionTitle: String {
        String(
            localized: "audit.projectForm.allowlist.add",
            defaultValue: "Add domain",
            comment: "Button that adds an empty line to the allowlist in the audit project form."
        )
    }

    public static var removeAllowlistLineActionTitle: String {
        String(
            localized: "audit.projectForm.allowlist.remove",
            defaultValue: "Remove",
            comment: "Swipe action that removes one line from the allowlist in the audit project form."
        )
    }

    public static var saveActionTitle: String {
        String(
            localized: "audit.form.save",
            defaultValue: "Save",
            comment: "Button that saves the audit project form."
        )
    }

    // MARK: - El formulario de una sesión

    public static var startSessionFormTitle: String {
        String(
            localized: "audit.sessionForm.title",
            defaultValue: "Start session",
            comment: "Title of the form that starts recording an audit session."
        )
    }

    public static var sessionRolePickerTitle: String {
        String(
            localized: "audit.sessionForm.role",
            defaultValue: "Session type",
            comment: """
                Label of the control choosing between an audit session (the audited app in use) \
                and a baseline (recorded without it).
                """
        )
    }

    public static func label(for role: AuditSessionRole) -> String {
        switch role {
        case .audit:
            return String(
                localized: "audit.sessionForm.role.audit",
                defaultValue: "Audit",
                comment: "Session type: recorded while using a given version of the audited app."
            )
        case .baseline:
            return String(
                localized: "audit.sessionForm.role.baseline",
                defaultValue: "Baseline",
                comment: """
                    Session type: recorded without the audited app installed. Same word as the \
                    name such a session gets in the list.
                    """
            )
        }
    }

    /// Qué hacer antes de empezar, que no es lo mismo en las dos: es el método de atribución entero
    /// (ADR 0008) dicho en el único momento en que sirve de algo.
    public static func sessionRoleFooter(_ role: AuditSessionRole) -> String {
        switch role {
        case .audit:
            return String(
                localized: "audit.sessionForm.role.audit.footer",
                defaultValue: """
                    Use only the audited app while this records. Everything the device sends is \
                    tagged, so anything else you open ends up in the evidence too.
                    """,
                comment: """
                    Note under the session type control when 'Audit' is chosen. The tunnel cannot \
                    tell apps apart, so the method depends on the assessor using only the audited \
                    app.
                    """
            )
        case .baseline:
            return String(
                localized: "audit.sessionForm.role.baseline.footer",
                defaultValue: """
                    Record this before installing the audited app, and leave the device alone \
                    while it runs. It captures the traffic the device makes on its own.
                    """,
                comment: """
                    Note under the session type control when 'Baseline' is chosen. A baseline is \
                    the device's background traffic without the audited app.
                    """
            )
        }
    }

    public static var releaseSectionTitle: String {
        String(
            localized: "audit.sessionForm.release.section",
            defaultValue: "Audited release",
            comment: "Heading of the version and build fields in the audit session form."
        )
    }

    public static var versionFieldPrompt: String {
        String(
            localized: "audit.sessionForm.version.prompt",
            defaultValue: "Version, such as 2.4.0",
            comment: "Placeholder of the audited app's version field. '2.4.0' is a literal example."
        )
    }

    public static var buildFieldPrompt: String {
        String(
            localized: "audit.sessionForm.build.prompt",
            defaultValue: "Build, such as 187",
            comment: "Placeholder of the audited app's build number field. '187' is a literal example."
        )
    }

    public static var releaseFooter: String {
        String(
            localized: "audit.sessionForm.release.footer",
            defaultValue: "Both are needed: two builds of one version are different binaries.",
            comment: "Note under the version and build fields of the audit session form."
        )
    }

    public static var notesFieldPrompt: String {
        String(
            localized: "audit.sessionForm.notes.prompt",
            defaultValue: "Anything the report should say about this run (optional)",
            comment: "Placeholder of the free-text notes field in the audit session form."
        )
    }

    public static var conditionsSectionTitle: String {
        String(
            localized: "audit.sessionForm.conditions.section",
            defaultValue: "Certificate pinning",
            comment: """
                Heading of the section of the audit session form that says, before recording \
                starts, whether this session will be able to assess pinning. Same words as the \
                section on the session's own screen.
                """
        )
    }

    public static var startRecordingActionTitle: String {
        String(
            localized: "audit.sessionForm.start",
            defaultValue: "Start recording",
            comment: """
                Button that confirms the audit session form. Tagging starts the moment it is \
                tapped.
                """
        )
    }

    // MARK: - Lo que un formulario tiene mal

    public static func message(for issue: AuditFormIssue) -> String {
        switch issue {
        case .emptyProjectName:
            return String(
                localized: "audit.form.issue.emptyName",
                defaultValue: "Give the project a name.",
                comment: "Shown when the audit project form is saved without a name."
            )

        case .invalidPattern(_, let reason):
            return message(for: reason)

        case .duplicatePattern(_, let pattern):
            return String(
                localized: "audit.form.issue.duplicatePattern",
                defaultValue: "\(pattern) is already in the list.",
                comment: """
                    Shown when two allowlist lines are the same domain once normalised (case and \
                    a trailing dot do not count). The placeholder is the domain.
                    """
            )

        case .noteWithoutPattern:
            return String(
                localized: "audit.form.issue.noteWithoutPattern",
                defaultValue: "This line has a note but no domain.",
                comment: "Shown when an allowlist line has its note filled in and its domain empty."
            )

        case .missingRelease:
            return String(
                localized: "audit.form.issue.missingRelease",
                defaultValue: "Enter the version and the build of the app you are auditing.",
                comment: "Shown when an audit session is started without a version or a build number."
            )
        }
    }

    /// Por qué una línea no es un patrón. Cada rechazo de `DomainPattern` tiene su frase: «patrón
    /// inválido» a secas deja al usuario adivinando cuál de las siete reglas ha roto.
    private static func message(for reason: DomainPattern.ParseError) -> String {
        switch reason {
        case .empty:
            return String(
                localized: "audit.form.issue.pattern.empty",
                defaultValue: "Enter a domain name.",
                comment: "Shown when an allowlist line holds nothing but spaces or a lone wildcard."
            )
        case .misplacedWildcard:
            return String(
                localized: "audit.form.issue.pattern.wildcard",
                defaultValue: "A wildcard only works at the start, as in *.example.com.",
                comment: """
                    Shown when an allowlist line uses '*' anywhere but as the whole first label. \
                    '*.example.com' is a literal example.
                    """
            )
        case .nonASCII:
            return String(
                localized: "audit.form.issue.pattern.nonASCII",
                defaultValue: """
                    Write international names in their xn-- form: that is how they appear in \
                    the traffic.
                    """,
                comment: """
                    Shown when an allowlist line contains non-ASCII characters. Observed names \
                    arrive in punycode ('xn--…'), so a Unicode pattern would never match.
                    """
            )
        case .emptyLabel:
            return String(
                localized: "audit.form.issue.pattern.emptyLabel",
                defaultValue: "There is an empty part between two dots.",
                comment: "Shown when an allowlist line has two consecutive dots or starts with one."
            )
        case .labelTooLong(let label):
            return String(
                localized: "audit.form.issue.pattern.labelTooLong",
                defaultValue: "\(label) is longer than a domain name allows between two dots.",
                comment: """
                    Shown when one dot-separated part of an allowlist line exceeds 63 characters. \
                    The placeholder is that part.
                    """
            )
        case .nameTooLong:
            return String(
                localized: "audit.form.issue.pattern.nameTooLong",
                defaultValue: "This is longer than a domain name can be.",
                comment: "Shown when an allowlist line exceeds the 253-character limit of a domain name."
            )
        case .invalidCharacter(let character):
            return String(
                localized: "audit.form.issue.pattern.invalidCharacter",
                defaultValue: "\(String(character)) can't be part of a domain name.",
                comment: """
                    Shown when an allowlist line contains a character a domain name cannot hold, \
                    such as a slash or a colon — typically a pasted URL. The placeholder is the \
                    character.
                    """
            )
        }
    }
}
