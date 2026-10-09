import Foundation

/// `session.json`: qué se auditó, en qué grabación y en qué condiciones.
///
/// Es lo que hace reproducible el resto del paquete: una evidencia sin el dispositivo, el sistema,
/// la versión de la herramienta y la allowlist contra la que se juzgó no se puede volver a obtener.
public struct EvidenceSessionDocument: Encodable, Sendable, Hashable {

    /// Lo que el paquete dice de sí mismo, para que quien lo abra sepa qué **no** hay dentro sin
    /// deducirlo de la ausencia de un fichero.
    public static let contentsNote =
        "Connection metadata and what it shows against a requirement catalogue. "
        + "Decrypted content is not part of this bundle."

    /// El método de atribución, que el informe está obligado a decir (ADR 0008): el túnel ve
    /// paquetes, no procesos.
    public static let attributionNote =
        "The tunnel sees packets, not processes: every flow that carried traffic while the session "
        + "was open is listed, whichever app sent it. Attribution to the audited app is procedural: "
        + "a controlled device, compared against a baseline session recorded without the app."

    public struct Project: Encodable, Sendable, Hashable {
        public let id: Int64
        public let name: String
        public let bundleIdentifier: String?
        public let allowlist: [AllowlistItem]
    }

    public struct AllowlistItem: Encodable, Sendable, Hashable {
        public let pattern: String
        public let note: String?
    }

    public struct Release: Encodable, Sendable, Hashable {
        public let version: String
        public let build: String
    }

    public struct Environment: Encodable, Sendable, Hashable {
        public let deviceModel: String
        public let osVersion: String

        /// La versión de la herramienta que **grabó** la sesión; la que exportó es `exportedWith`.
        public let toolVersion: String
    }

    public struct Inspection: Encodable, Sendable, Hashable {
        public let inspectionEnabled: Bool
        public let caTrusted: Bool

        /// Si de esta sesión se puede leer algo sobre pinning. Va escrito, aunque se deduce de los
        /// otros dos, porque es la condición que un lector tiene que comprobar antes de citar un
        /// hallazgo de pinning y no debería tener que conocer la regla.
        public let supportsPinningEvidence: Bool
    }

    public struct Session: Encodable, Sendable, Hashable {
        public let id: Int64

        /// `baseline` o `audit`.
        public let kind: String

        /// Solo en una sesión `audit`: una `baseline` se graba sin la app.
        public let release: Release?

        public let startedAt: Date
        public let endedAt: Date
        public let notes: String
        public let environment: Environment
        public let inspection: Inspection
    }

    public struct Marker: Encodable, Sendable, Hashable {
        public let id: Int64
        public let date: Date

        /// `consentGiven`, `loggedIn`, `loggedOut` o `custom`.
        public let kind: String

        /// Solo en un marcador `custom`: lo que escribió el evaluador.
        public let label: String?
    }

    public let format: String
    public let formatVersion: Int
    public let exportedAt: Date

    /// La versión de la herramienta que escribió el paquete.
    public let exportedWith: String

    public let contents: String
    public let attribution: String
    public let project: Project
    public let session: Session

    /// Los marcadores de la sesión, por instante.
    public let markers: [Marker]

    /// - Parameter endedAt: cuándo se cerró la sesión. Entra aparte porque aquí no es opcional:
    ///   una sesión abierta no se exporta, y quien lo comprueba es `EvidenceBundle`.
    init(
        project: AuditProject,
        session: AuditSession,
        endedAt: Date,
        markers: [SessionMarker],
        exportedWith: String,
        exportedAt: Date
    ) {
        self.format = EvidenceBundleFormat.sessionIdentifier
        self.formatVersion = EvidenceBundleFormat.version
        self.exportedAt = exportedAt
        self.exportedWith = exportedWith
        self.contents = Self.contentsNote
        self.attribution = Self.attributionNote
        self.project = Project(
            id: project.id,
            name: project.name,
            bundleIdentifier: project.bundleIdentifier,
            allowlist: project.allowlist.map { AllowlistItem(pattern: $0.pattern.text, note: $0.note) }
        )
        self.session = Session(
            id: session.id,
            kind: Self.name(of: session.kind),
            release: session.kind.release.map { Release(version: $0.version, build: $0.build) },
            startedAt: session.startedAt,
            endedAt: endedAt,
            notes: session.notes,
            environment: Environment(
                deviceModel: session.environment.deviceModel,
                osVersion: session.environment.osVersion,
                toolVersion: session.environment.toolVersion
            ),
            inspection: Inspection(
                inspectionEnabled: session.inspection.inspectionEnabled,
                caTrusted: session.inspection.caTrusted,
                supportsPinningEvidence: session.inspection.supportsPinningEvidence
            )
        )
        // Dos marcadores pueden compartir instante: el id desempata para que el orden no dependa
        // de cómo llegaron.
        self.markers = markers
            .sorted { ($0.date, $0.id) < ($1.date, $1.id) }
            .map(Marker.init)
    }

    static func name(of kind: AuditSessionKind) -> String {
        switch kind {
        case .baseline: return "baseline"
        case .audit: return "audit"
        }
    }
}

extension EvidenceSessionDocument.Marker {

    init(_ marker: SessionMarker) {
        self.id = marker.id
        self.date = marker.date
        switch marker.kind {
        case .consentGiven:
            self.kind = "consentGiven"
            self.label = nil
        case .loggedIn:
            self.kind = "loggedIn"
            self.label = nil
        case .loggedOut:
            self.kind = "loggedOut"
            self.label = nil
        case .custom(let label):
            self.kind = "custom"
            self.label = label
        }
    }
}
