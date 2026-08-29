import Foundation
import Shared

/// Un registro de captura ya leído: los bytes de **un** paquete tal y como quedaron en el `.pcap`.
///
/// `capturedLength` y `originalLength` son cosas distintas y esa diferencia es justo lo que hay que
/// enseñar: el writer recorta cada paquete a `snaplen`, así que un paquete grande está guardado a
/// medias y callarlo dejaría al usuario leyendo unos bytes creyendo que son todos.
public struct CaptureRecord: Sendable, Equatable {

    /// De dónde salió. Va dentro porque la pantalla enseña el fichero y el offset como un dato más:
    /// es la única prueba de que estos bytes son los de *este* paquete y no los de otro.
    public let location: CaptureLocation

    /// Los bytes guardados del paquete: el datagrama IP desnudo, sin capa de enlace (`LINKTYPE_RAW`).
    public let bytes: Data

    /// Lo que medía el paquete antes de recortarlo, según su cabecera de registro.
    public let originalLength: UInt32

    /// Cuándo se capturó, según la cabecera del registro. Es un sello **monotónico** descompuesto en
    /// segundos y microsegundos, no una hora de pared: el writer corre en el hot path de la extensión,
    /// donde lo único que hay es `CLOCK_UPTIME_RAW`. La hora que enseña la pantalla sale del store,
    /// que es la frontera donde el tiempo se vuelve absoluto — esto solo sirve para comprobar que el
    /// registro es el que se pedía.
    public let timestampMicroseconds: UInt64

    public init(
        location: CaptureLocation,
        bytes: Data,
        originalLength: UInt32,
        timestampMicroseconds: UInt64
    ) {
        self.location = location
        self.bytes = bytes
        self.originalLength = originalLength
        self.timestampMicroseconds = timestampMicroseconds
    }

    public var capturedLength: UInt32 { UInt32(clamping: bytes.count) }

    /// Si el `snaplen` se llevó parte del paquete.
    public var isTruncated: Bool { originalLength > capturedLength }
}

public enum CaptureLibraryError: Error, Sendable, Equatable {
    /// El contenedor del App Group no se pudo resolver (falta el entitlement o el identificador no
    /// es el que se firmó). No es "no hay capturas": es que no se sabe dónde mirar.
    case containerUnavailable(String)
    /// El borrado falló, con el texto del sistema para poder enseñarlo.
    case deletionFailed(String)
    /// Esa secuencia ya no está en el directorio.
    ///
    /// Lo dicen dos operaciones que **no** significan lo mismo para el usuario, y por eso el caso es
    /// uno solo y la copia es de cada pantalla: borrar algo que ya no está es una carrera rara, pero
    /// pedir los bytes de un paquete cuyo fichero se borró es lo normal desde que la pantalla de
    /// capturas existe — ahí no hay avería que contar, solo unos bytes que ya no están.
    case notFound(UInt32)
    /// El registro no se pudo decodificar en ese offset: el fichero se quedó a medias, la cabecera no
    /// es de los nuestros, o el offset apunta más allá del final. Lleva el detalle para el diagnóstico.
    case recordUnreadable(String)
}

/// El directorio de capturas visto desde la app: listar lo que hay, borrar lo que el usuario decida
/// (`docs/ux/screens.md`, pantalla *Captures*) y abrir un fichero por el offset de un paquete para
/// enseñar sus bytes (el salto paquete→bytes del Flow Inspector).
///
/// Leer un registro vive aquí y no en un servicio nuevo porque es el **mismo directorio y la misma
/// costura**: quien sabe resolver el contenedor del App Group y traducir una secuencia a un fichero ya
/// es este actor, y partirlo en dos solo repetiría esa resolución en otro sitio.
///
/// Es un `actor` por lo mismo que `FlowStore` y `HistoryReader`: toca disco, y el disco no se toca
/// desde el hilo principal. No mantiene estado — cada llamada mira el directorio otra vez —, porque
/// quien escribe ahí es **otro proceso**: cachear la lista sería servir un directorio que la
/// extensión ya cambió al rotar.
///
/// Escribir sigue siendo cosa de la extensión (`PcapWriter`); lo único que la app escribe aquí es la
/// desaparición de un fichero que su dueño ha decidido borrar.
public actor CaptureLibrary {

    /// El directorio se resuelve **en cada operación** y no se guarda: la resolución del contenedor
    /// del App Group es lo que falla cuando el entitlement no está, y guardando el resultado del
    /// primer intento un fallo temprano se quedaría pegado a la pantalla para siempre.
    private let resolveDirectory: @Sendable () throws -> URL

    /// Sobre un directorio concreto. Es lo que usan los tests, sobre un temporal.
    public init(directory: URL) {
        self.init(resolvingDirectory: { directory })
    }

    /// Sobre un directorio que se resuelve en cada operación. Es la costura: sin ella, el fallo de
    /// resolución del contenedor —el único que esta clase puede tener— solo se podría ejercitar
    /// dentro de una app firmada con un App Group, que es justo donde no corren los tests.
    public init(resolvingDirectory: @escaping @Sendable () throws -> URL) {
        self.resolveDirectory = resolvingDirectory
    }

    /// Sobre el directorio de capturas del App Group, que es donde escribe la extensión.
    public init(appGroupID: String = AppGroup.identifier) {
        self.init(resolvingDirectory: {
            guard let url = CaptureDirectory.url(inAppGroup: appGroupID) else {
                throw CaptureLibraryError.containerUnavailable(appGroupID)
            }
            return url
        })
    }

    /// Las capturas presentes, de la más antigua a la más reciente (que es su orden de secuencia).
    ///
    /// Un directorio que todavía no existe **no** es un error: la extensión lo crea al abrir su
    /// primer fichero, así que antes de la primera sesión lo correcto es una lista vacía y no una
    /// avería (`CaptureDirectory.files(in:)` ya lo resuelve así).
    public func files() throws -> [CaptureFileInfo] {
        try CaptureDirectory.fileInfos(in: resolveDirectory())
    }

    /// Borra un fichero de captura.
    ///
    /// Lo que queda detrás es deliberado y la pantalla lo explica: las conexiones que se registraron
    /// mientras se escribía **siguen en el historial**; lo que se pierde son los bytes crudos. Las
    /// filas de `packets` que apuntaban aquí quedan con una localización que ya no resuelve, y eso es
    /// seguro porque el writer no reutiliza la secuencia de un fichero borrado
    /// (`FlowStore.highestCaptureFileSequence()`): ningún paquete acabará señalando los bytes de otro.
    public func delete(sequence: UInt32) throws {
        let directory = try resolveDirectory()
        guard let url = CaptureDirectory.url(forSequence: sequence, in: directory) else {
            throw CaptureLibraryError.notFound(sequence)
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw CaptureLibraryError.deletionFailed(error.localizedDescription)
        }
    }

    /// Los bytes de **un** paquete: abre el fichero que la localización señala y decodifica el
    /// registro que hay en su offset (`docs/ux/screens.md`, el salto paquete→bytes del Flow Inspector).
    ///
    /// Se lee **por offset, sin recorrer el fichero**: una captura puede pesar decenas de megas y
    /// enseñar un paquete no es motivo para leerla entera. Son tres lecturas cortas — la cabecera
    /// global (que da el `snaplen`), la cabecera del registro y sus bytes —, y el `inclLen` se acota
    /// contra ese `snaplen` **antes** de reservar nada: un fichero corrupto no puede pedir memoria.
    ///
    /// Un fichero que ya no está es `notFound`, no una avería: el usuario puede haberlo borrado y la
    /// conexión sigue registrada en el historial aunque sus bytes no estén.
    public func record(at location: CaptureLocation) throws -> CaptureRecord {
        let directory = try resolveDirectory()
        guard let url = CaptureDirectory.url(forSequence: location.fileSequence, in: directory) else {
            throw CaptureLibraryError.notFound(location.fileSequence)
        }
        // Un offset dentro de la cabecera global no puede ser el de ningún registro. Se comprueba
        // antes de abrir nada: es la propiedad que hace de `recordOffset == 0` un centinela seguro.
        guard location.recordOffset >= UInt64(PcapFormat.globalHeaderSize) else {
            throw CaptureLibraryError.recordUnreadable(
                "Offset \(location.recordOffset) falls inside the file header."
            )
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw CaptureLibraryError.recordUnreadable("The capture file couldn't be opened.")
        }
        // El handle se cierra pase lo que pase: cada registro que se abre en la pantalla es un
        // descriptor, y dejarlos a merced del recolector agotaría el límite del proceso.
        defer { try? handle.close() }

        do {
            let global = try PcapFormat.globalHeader(
                parsing: try read(handle, count: PcapFormat.globalHeaderSize, from: 0)
            )
            let header = try PcapFormat.recordHeader(
                parsing: try read(handle, count: PcapFormat.recordHeaderSize, from: location.recordOffset)
            )
            guard header.inclLen <= global.snaplen else {
                throw CaptureLibraryError.recordUnreadable(
                    "Record claims \(header.inclLen) bytes, more than the file's \(global.snaplen)."
                )
            }

            let payloadOffset = location.recordOffset + UInt64(PcapFormat.recordHeaderSize)
            let bytes = try read(handle, count: Int(header.inclLen), from: payloadOffset)
            guard bytes.count == Int(header.inclLen) else {
                throw CaptureLibraryError.recordUnreadable(
                    "Record is cut short: \(bytes.count) of \(header.inclLen) bytes are on disk."
                )
            }

            return CaptureRecord(
                location: location,
                bytes: bytes,
                originalLength: header.origLen,
                timestampMicroseconds: UInt64(header.tsSec) * 1_000_000 + UInt64(header.tsUsec)
            )
        } catch let error as PcapFormat.FormatError {
            throw CaptureLibraryError.recordUnreadable(String(describing: error))
        }
    }

    // MARK: - Interno

    /// Lee hasta `count` bytes desde un offset concreto. Devuelve lo que haya: quien llama decide si
    /// quedarse corto es un fallo (para el paquete lo es; para una cabecera lo dice el parser).
    private func read(_ handle: FileHandle, count: Int, from offset: UInt64) throws -> Data {
        guard count > 0 else { return Data() }
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count) ?? Data()
        } catch {
            throw CaptureLibraryError.recordUnreadable(
                "Couldn't read \(count) bytes at offset \(offset): \(error.localizedDescription)"
            )
        }
    }
}
