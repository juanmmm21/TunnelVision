import Foundation

/// Un patrón de la allowlist de dominios de un proyecto de auditoría: un nombre exacto o `*.sufijo`.
///
/// El texto se **normaliza al construir** (minúsculas, sin el punto final de un FQDN), así que dos
/// patrones que nombran lo mismo son iguales y la unicidad en disco no depende de cómo lo tecleó
/// nadie. Y se **valida**: un patrón que nunca podría coincidir con un nombre observado —un comodín
/// en medio, una etiqueta vacía— es un hueco silencioso en una allowlist, que es justo el documento
/// contra el que se decide qué conexión es inesperada.
public struct DomainPattern: Sendable, Hashable {

    public enum Scope: Sendable, Hashable {
        /// Solo ese nombre.
        case exact
        /// Cualquier nombre por debajo, a cualquier profundidad — y **no** el propio sufijo.
        case subdomains
    }

    public enum ParseError: Error, Sendable, Equatable {
        case empty
        /// Un `*` que no es el prefijo `*.` completo: `a.*.com`, `*example.com`, `*`.
        case misplacedWildcard
        /// Los nombres observados salen del DNS y del SNI en ASCII (un IDN llega como `xn--`), así
        /// que un patrón con otros caracteres no coincidiría nunca: se escribe en punycode.
        case nonASCII
        case emptyLabel
        case labelTooLong(String)
        case nameTooLong
        case invalidCharacter(Character)
    }

    /// Límites de RFC 1035 § 2.3.4.
    public static let maximumLabelLength = 63
    public static let maximumNameLength = 253

    public let scope: Scope

    /// El nombre normalizado, sin el prefijo `*.`.
    public let name: String

    public init(parsing text: String) throws {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !candidate.isEmpty else { throw ParseError.empty }
        guard candidate.allSatisfy(\.isASCII) else { throw ParseError.nonASCII }

        let scope: Scope
        if candidate.hasPrefix("*.") {
            scope = .subdomains
            candidate.removeFirst(2)
        } else {
            scope = .exact
        }
        guard !candidate.contains("*") else { throw ParseError.misplacedWildcard }
        if candidate.hasSuffix(".") { candidate.removeLast() }
        guard !candidate.isEmpty else { throw ParseError.empty }
        guard candidate.count <= Self.maximumNameLength else { throw ParseError.nameTooLong }

        for label in candidate.split(separator: ".", omittingEmptySubsequences: false) {
            guard !label.isEmpty else { throw ParseError.emptyLabel }
            guard label.count <= Self.maximumLabelLength else {
                throw ParseError.labelTooLong(String(label))
            }
            // El guion bajo no es válido en un hostname pero sí aparece en nombres de DNS reales
            // (`_dmarc`, registros SRV), y la allowlist se compara contra lo observado.
            if let invalid = label.first(where: { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) {
                throw ParseError.invalidCharacter(invalid)
            }
        }

        self.scope = scope
        self.name = candidate
    }

    /// La forma canónica: lo que se guarda y lo que se enseña.
    public var text: String {
        switch scope {
        case .exact: return name
        case .subdomains: return "*.\(name)"
        }
    }

    /// Si un nombre observado cae dentro del patrón. El nombre se normaliza igual que el patrón.
    ///
    /// `*.example.com` **no** coincide con `example.com`: es la convención de los comodines de
    /// certificado, y la contraria haría que autorizar los subdominios de un tercero autorizase sin
    /// decirlo también su dominio raíz. Quien quiera los dos escribe las dos entradas.
    public func matches(_ host: String) -> Bool {
        let candidate = Self.normalised(host: host)
        switch scope {
        case .exact:
            return candidate == name
        case .subdomains:
            return candidate.hasSuffix(".\(name)") && candidate.count > name.count + 1
        }
    }

    /// Un nombre observado tal como se compara: en minúsculas y sin el punto final de un FQDN. Es
    /// también la forma en la que un hallazgo cita un host, para que `Example.com.` y `example.com`
    /// no sean dos.
    public static func normalised(host: String) -> String {
        var candidate = host.lowercased()
        if candidate.hasSuffix(".") { candidate.removeLast() }
        return candidate
    }
}

/// Una entrada de la allowlist: el patrón y, si se quiso, para qué es («backend», «crash reporting»).
/// La nota viaja al informe: es lo que le explica al evaluador por qué esa conexión es esperada.
public struct AllowlistEntry: Sendable, Hashable {
    public let pattern: DomainPattern
    public let note: String?

    public init(pattern: DomainPattern, note: String?) {
        self.pattern = pattern
        self.note = note
    }
}
