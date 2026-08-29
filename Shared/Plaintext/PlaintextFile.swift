import Foundation

/// Nombre de un fichero de contenido descifrado: `plaintext-<secuencia>-<yyyyMMdd-HHmmss>.tvpt`.
///
/// Mismo reparto que `CaptureFileName`, y por el mismo motivo: el nombre es el **único** sitio donde
/// vive la identidad del fichero, así que formatearlo y leerlo tienen que ser la misma verdad — la
/// extensión lo escribe y la app resuelve con él la `PlaintextLocation` que el índice guarda.
///
/// La secuencia va delante y con relleno de ceros para que el orden alfabético coincida con el
/// cronológico. El componente de fecha es legibilidad y nunca se parsea.
///
/// La extensión es propia (`.tvpt`) y no `.pcap` a conciencia: estos ficheros **no** son capturas y no
/// se pueden abrir con Wireshark, y una extensión prestada invitaría a intentarlo. Que además sean
/// imposibles de confundir en un listado es lo que se quiere: uno guarda lo que viajó cifrado y el
/// otro lo que había dentro.
public enum PlaintextFileName {

    public static let prefix = "plaintext-"
    public static let fileExtension = "tvpt"

    /// Dígitos mínimos de la secuencia. Es relleno, no tope.
    public static let sequenceDigits = 6

    public static func make(sequence: UInt32, date: Date) -> String {
        "\(prefix)\(String(format: "%0\(sequenceDigits)u", sequence))-\(timestampComponent(date)).\(fileExtension)"
    }

    /// Secuencia codificada en el nombre, o `nil` si el fichero no es nuestro. Estricto a propósito:
    /// cualquier otra cosa que aparezca en el directorio debe quedar fuera, no colarse con una
    /// secuencia inventada.
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

    /// Se construye un formateador por llamada (una por rotación, no en el hot path): `DateFormatter`
    /// no es `Sendable`, así que un `static let` compartido no compila bajo concurrencia estricta.
    private static func timestampComponent(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

/// Dónde quedó un trozo de contenido descifrado: en qué fichero y en qué posición de ese fichero.
///
/// Existe por lo mismo que `CaptureLocation`: el escritor rota, y cada fichero reinicia sus offsets
/// detrás de la cabecera global, así que un offset por sí solo no identifica nada. La pareja es lo que
/// permite que el Flow Inspector llegue al contenido de **esa** conversación y no al de otra.
public struct PlaintextLocation: Sendable, Hashable, Codable {

    /// Secuencia del fichero: el número que `PlaintextFileName` pone en su nombre. Nunca se reutiliza
    /// mientras el índice la referencie (`PlaintextWriter.Config.highestReferencedSequence`).
    public let fileSequence: UInt32

    /// Offset de la cabecera del registro dentro de ese fichero. Nunca vale 0 —todo fichero empieza
    /// por su cabecera global—, y esa propiedad es la que permite representar "sin contenido" con un 0
    /// en una columna que no admite opcionales, igual que en la captura.
    public let recordOffset: UInt64

    public init(fileSequence: UInt32, recordOffset: UInt64) {
        self.fileSequence = fileSequence
        self.recordOffset = recordOffset
    }
}

/// Un fichero de contenido descifrado ya localizado en disco.
public struct PlaintextFile: Sendable, Hashable, Identifiable {
    public var id: UInt32 { sequence }
    public let sequence: UInt32
    public let url: URL

    public init(sequence: UInt32, url: URL) {
        self.sequence = sequence
        self.url = url
    }
}

/// Un fichero de contenido descifrado con lo que el sistema de ficheros dice de él.
///
/// Va aparte de `PlaintextFile` por lo mismo que `CaptureFileInfo` va aparte de `CaptureFile`: cuesta
/// un `stat` por fichero, y quien solo resuelve una `PlaintextLocation` no tiene por qué pagarlo.
///
/// **No lleva fecha, y esa ausencia es la diferencia con la captura.** Un `.pcap` se borra por lo
/// viejo que es el fichero (por la fecha de su sucesor, que es cuando dejó de crecer), pero aquí la
/// antigüedad es **del contenido**: la deciden los sellos de las filas del índice, que caducan una a
/// una aunque estén en el mismo fichero. Lo único que el disco tiene que aportar al barrido es cuánto
/// ocupa cada uno, para el techo.
public struct PlaintextFileInfo: Sendable, Equatable, Identifiable {

    public var id: UInt32 { sequence }

    public let sequence: UInt32

    public let url: URL

    public let byteCount: UInt64

    public init(sequence: UInt32, url: URL, byteCount: UInt64) {
        self.sequence = sequence
        self.url = url
        self.byteCount = byteCount
    }
}

/// El directorio del contenido descifrado dentro del contenedor del App Group, y las consultas que
/// los dos procesos le hacen.
///
/// Va **aparte** del de capturas y no mezclado con ellas: son dos cosas con dos retenciones posibles
/// —una guarda lo que viajó por el cable, la otra lo que había dentro—, y tenerlas en directorios
/// distintos es lo que permite que un día se borre una sin tocar la otra. Mezcladas, cualquier regla
/// sobre el contenido descifrado tendría que empezar por distinguirlo fichero a fichero.
public enum PlaintextDirectory {

    public static let directoryName = "Plaintext"

    /// Ruta del directorio, o `nil` si el contenedor del App Group no se puede resolver (falta el
    /// entitlement o el identificador es incorrecto). No lo crea: eso es de quien escribe.
    public static func url(inAppGroup appGroupID: String) -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Ficheros presentes, ordenados por secuencia (que es también su orden cronológico). Un
    /// directorio ausente o ilegible no es un error: significa que no se ha descifrado nada todavía,
    /// que es el estado normal del producto.
    public static func files(in directory: URL) -> [PlaintextFile] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return items
            .compactMap { url in
                PlaintextFileName.sequence(fromFileName: url.lastPathComponent)
                    .map { PlaintextFile(sequence: $0, url: url) }
            }
            .sorted { $0.sequence < $1.sequence }
    }

    /// Fichero al que apunta una `PlaintextLocation`, o `nil` si ya no está (lo pudo borrar la
    /// retención).
    public static func url(forSequence sequence: UInt32, in directory: URL) -> URL? {
        files(in: directory).first { $0.sequence == sequence }?.url
    }

    /// Mayor secuencia presente, o `nil` si no hay ninguno. Es un hecho, no una decisión: por encima
    /// de qué secuencia arranca un escritor nuevo lo decide `PlaintextWriter`.
    public static func highestSequence(in directory: URL) -> UInt32? {
        files(in: directory).map(\.sequence).max()
    }

    /// Los ficheros presentes con lo que pesan, en el mismo orden que `files(in:)`.
    ///
    /// Un fichero que desaparece entre el listado y su `stat` se cae de la lista en vez de aparecer
    /// con un tamaño inventado: la carrera es real —la app barre mientras la extensión rota— y el
    /// siguiente listado ya no lo traerá.
    public static func fileInfos(in directory: URL) -> [PlaintextFileInfo] {
        files(in: directory).compactMap { file in
            guard let values = try? file.url.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize
            else {
                return nil
            }
            return PlaintextFileInfo(sequence: file.sequence, url: file.url, byteCount: UInt64(max(0, size)))
        }
    }
}
