import Foundation

/// Nombre de un fichero de captura: `tunnelvision-<secuencia>-<yyyyMMdd-HHmmss>.pcap`.
///
/// El nombre es el **único** sitio donde vive la identidad del fichero, así que formatearlo y
/// leerlo tienen que ser la misma verdad: la extensión lo escribe y la app lo resuelve para llegar
/// a los bytes que `CaptureLocation.fileSequence` señala. Por eso están juntos y aquí, en `Shared`.
///
/// La secuencia va delante y con relleno de ceros para que el orden alfabético del nombre coincida
/// con el cronológico; el componente de fecha es solo legibilidad para el usuario que exporta el
/// fichero, nunca se parsea.
public enum CaptureFileName {

    public static let prefix = "tunnelvision-"
    public static let fileExtension = "pcap"

    /// Dígitos mínimos de la secuencia. Es relleno, no tope: una secuencia mayor de 999.999 escribe
    /// los dígitos que necesite y se sigue leyendo bien.
    public static let sequenceDigits = 6

    public static func make(sequence: UInt32, date: Date) -> String {
        "\(prefix)\(String(format: "%0\(sequenceDigits)u", sequence))-\(timestampComponent(date)).\(fileExtension)"
    }

    /// Secuencia codificada en el nombre, o `nil` si el fichero no es una captura nuestra.
    ///
    /// Es estricto a propósito: el directorio de capturas es compartido y cualquier otro fichero que
    /// aparezca ahí debe quedar fuera, no colarse con una secuencia inventada.
    public static func sequence(fromFileName name: String) -> UInt32? {
        guard name.hasSuffix(".\(fileExtension)"), name.hasPrefix(prefix) else { return nil }
        let afterPrefix = name.dropFirst(prefix.count)
        let digits = afterPrefix.prefix { $0.isASCII && $0.isNumber }
        guard digits.count >= sequenceDigits,
              afterPrefix.dropFirst(digits.count).first == "-",
              let sequence = UInt32(digits)
        else {
            return nil
        }
        return sequence
    }

    /// Se construye un formateador por llamada (una por rotación de fichero, no en el hot path):
    /// `DateFormatter` no es `Sendable`, así que un `static let` compartido no compila bajo
    /// concurrencia estricta.
    private static func timestampComponent(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

/// Un fichero de captura ya localizado en disco: su secuencia y dónde está.
public struct CaptureFile: Sendable, Hashable, Identifiable {
    public var id: UInt32 { sequence }
    public let sequence: UInt32
    public let url: URL

    public init(sequence: UInt32, url: URL) {
        self.sequence = sequence
        self.url = url
    }
}

/// Un fichero de captura con lo que el sistema de ficheros dice de él: cuánto pesa y cuándo se abrió.
///
/// Va aparte de `CaptureFile` y no dentro porque cuesta un `stat` por fichero, y quien solo necesita
/// resolver una `CaptureLocation` no tiene por qué pagarlo: la identidad la da el nombre, el resto lo
/// da el disco.
///
/// Vive en `Shared` —y no en la app, donde nació con la pantalla de capturas— desde que la retención
/// dejó de tener un solo dueño: la extensión aplica los mismos topes al rotar, que es cuando ya está
/// tocando el directorio y cuando puede no haber nadie delante. Planificar allí con otro tipo habría
/// sido mantener dos veces la misma regla. Es el mismo movimiento que hicieron `PcapWriter`,
/// `PacketParser` y `CaptureFileName`.
public struct CaptureFileInfo: Sendable, Equatable, Identifiable {

    public var id: UInt32 { sequence }

    /// La secuencia que el nombre del fichero codifica: la misma que llevan guardada los paquetes
    /// cuyos bytes están dentro (`CaptureLocation.fileSequence`).
    public let sequence: UInt32

    public let url: URL

    public let byteCount: UInt64

    /// Cuándo se abrió el fichero, que es cuando la captura rotó a él. Es opcional porque lo da el
    /// sistema de ficheros y no el nombre: el componente de fecha del nombre existe para que un
    /// fichero exportado se reconozca fuera de la app, y `CaptureFileName` no lo parsea nunca.
    public let createdAt: Date?

    public init(sequence: UInt32, url: URL, byteCount: UInt64, createdAt: Date?) {
        self.sequence = sequence
        self.url = url
        self.byteCount = byteCount
        self.createdAt = createdAt
    }
}

/// El directorio de capturas dentro del contenedor del App Group, y las consultas que ambos
/// procesos le hacen: la extensión para saber por qué secuencia empezar, la app para resolver la
/// `CaptureLocation` de un paquete en un fichero concreto.
public enum CaptureDirectory {

    public static let directoryName = "Captures"

    /// Ruta del directorio de capturas, o `nil` si el contenedor del App Group no se puede resolver
    /// (falta el entitlement o el identificador es incorrecto). No lo crea: eso es de quien escribe.
    public static func url(inAppGroup appGroupID: String) -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Capturas presentes, ordenadas por secuencia (que es también su orden cronológico). Un
    /// directorio ausente o ilegible no es un error: no hay capturas todavía.
    public static func files(in directory: URL) -> [CaptureFile] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return items
            .compactMap { url in
                CaptureFileName.sequence(fromFileName: url.lastPathComponent)
                    .map { CaptureFile(sequence: $0, url: url) }
            }
            .sorted { $0.sequence < $1.sequence }
    }

    /// Fichero al que apunta una `CaptureLocation`, o `nil` si ya no está (el usuario pudo borrarlo).
    public static func url(forSequence sequence: UInt32, in directory: URL) -> URL? {
        files(in: directory).first { $0.sequence == sequence }?.url
    }

    /// Las capturas presentes con sus atributos de disco, en el mismo orden que `files(in:)`.
    ///
    /// Un fichero que desaparece entre el listado y su `stat` se cae de la lista en vez de aparecer
    /// con un tamaño inventado: la carrera es real —la app borra, la extensión recorta al rotar— y el
    /// siguiente listado ya no lo traerá.
    public static func fileInfos(in directory: URL) -> [CaptureFileInfo] {
        files(in: directory).compactMap(info(for:))
    }

    /// Mayor secuencia presente en el directorio, o `nil` si todavía no hay capturas.
    ///
    /// Es un hecho, no una decisión: por encima de qué secuencia debe arrancar un writer nuevo —y
    /// qué más hay que tener en cuenta para decidirlo— es cosa de `PcapWriter`.
    public static func highestSequence(in directory: URL) -> UInt32? {
        files(in: directory).map(\.sequence).max()
    }

    /// Los atributos de un fichero ya listado, o `nil` si dejó de existir entre el listado y el `stat`.
    private static func info(for file: CaptureFile) -> CaptureFileInfo? {
        guard let values = try? file.url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey]),
              let size = values.fileSize
        else {
            return nil
        }
        return CaptureFileInfo(
            sequence: file.sequence,
            url: file.url,
            byteCount: UInt64(max(0, size)),
            createdAt: values.creationDate
        )
    }
}
