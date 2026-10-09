import CryptoKit
import Foundation

/// Por qué una lista de ficheros no puede ser un manifiesto.
public enum EvidenceManifestError: Error, Sendable, Hashable {
    case noFiles
    /// No es un nombre de fichero suelto: vacío, con una barra, `.` o `..`. El manifiesto lista lo
    /// que hay **en** la carpeta del paquete, y un nombre que saliera de ella no lo sería.
    case invalidFileName(String)
    case duplicateFileName(String)
    /// El manifiesto no puede llevar su propio digest: cambiaría al escribirlo.
    case listsItself
    /// No son 64 dígitos hexadecimales en minúscula.
    case invalidDigest(fileName: String)
}

/// `manifest.json`: el SHA-256 de cada fichero del paquete, para que la evidencia se pueda
/// demostrar inalterada después de exportarla. Lista todos los demás ficheros y no a sí mismo.
public struct EvidenceManifest: Encodable, Sendable, Hashable {

    /// Un fichero del paquete: su nombre, su tamaño y su digest.
    public struct Entry: Encodable, Sendable, Hashable {
        public let name: String
        public let byteCount: Int

        /// En hexadecimal y en minúscula, como lo escribe `shasum -a 256`.
        public let sha256: String

        /// Para un fichero que no está en memoria —la captura—: quien lo escribe calcula el digest
        /// según lo va escribiendo y lo trae aquí.
        public init(name: String, byteCount: Int, sha256: String) {
            self.name = name
            self.byteCount = byteCount
            self.sha256 = sha256
        }

        public init(_ file: EvidenceFile) {
            self.init(name: file.name, byteCount: file.data.count, sha256: EvidenceManifest.sha256(of: file.data))
        }
    }

    public static let algorithm = "SHA-256"

    public let format: String
    public let formatVersion: Int
    public let sessionID: Int64
    public let exportedAt: Date
    public let algorithm: String

    /// Por nombre, para que el manifiesto no dependa del orden en que se escribieron los ficheros.
    public let files: [Entry]

    public init(sessionID: Int64, exportedAt: Date, entries: [Entry]) throws {
        guard !entries.isEmpty else { throw EvidenceManifestError.noFiles }
        var seen: Set<String> = []
        for entry in entries {
            let name = entry.name
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
                throw EvidenceManifestError.invalidFileName(name)
            }
            guard name != EvidenceBundleFormat.manifestFileName else {
                throw EvidenceManifestError.listsItself
            }
            guard seen.insert(name).inserted else {
                throw EvidenceManifestError.duplicateFileName(name)
            }
            let isDigest = entry.sha256.utf8.count == 64
                && entry.sha256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            guard isDigest else { throw EvidenceManifestError.invalidDigest(fileName: name) }
        }
        self.format = EvidenceBundleFormat.manifestIdentifier
        self.formatVersion = EvidenceBundleFormat.version
        self.sessionID = sessionID
        self.exportedAt = exportedAt
        self.algorithm = Self.algorithm
        self.files = entries.sorted { $0.name < $1.name }
    }

    /// El manifiesto como fichero del paquete.
    public func file() throws -> EvidenceFile {
        EvidenceFile(name: EvidenceBundleFormat.manifestFileName, data: try EvidenceBundleFormat.encode(self))
    }

    public static func sha256(of data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    /// El digest de un hash que se fue alimentando a trozos, en la forma en que lo guarda una
    /// entrada.
    public static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { byte in
            let text = String(byte, radix: 16)
            return byte < 16 ? "0" + text : text
        }.joined()
    }
}
