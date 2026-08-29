import Foundation
import Shared

/// Un trozo de contenido descifrado ya leído: los bytes de **un** registro tal y como quedaron en su
/// fichero `.tvpt`.
///
/// Es el gemelo de `CaptureRecord` y la diferencia entre los dos es la que hay entre los dos
/// artefactos: aquel guarda un datagrama IP tal y como viajó —cifrado— y este un trozo de un stream
/// ya reensamblado y descifrado. Por eso lleva **sentido** y **conversación**, que un paquete no
/// necesita (los suyos están en su cabecera IP), y por eso su sello es absoluto y no monotónico: el
/// fichero sobrevive a la sesión que lo escribió (`docs/spec/plaintext.md`).
///
/// `storedLength` y `originalLength` son cosas distintas por dos motivos a la vez —el tope por
/// registro y el presupuesto por flujo y sentido—, y la pantalla los cuenta igual: lo que necesita
/// decir es cuánto falta, no cuál de los dos topes lo cortó.
public struct PlaintextRecord: Sendable, Equatable {

    /// De dónde salió. Va dentro por lo mismo que en `CaptureRecord`: es la única prueba de que estos
    /// bytes son los de *este* trozo y no los del vecino.
    public let location: PlaintextLocation

    /// La conversación a la que pertenece el registro, según su propia cabecera. Ya está comprobada
    /// contra la que decía el índice: llega aquí para poder enseñarla, no para volver a validarla.
    public let stream: UInt64

    public let direction: Direction

    /// Cuándo se descifró, según la cabecera del registro. Es un instante **absoluto** —el fichero lo
    /// guarda ya convertido, con el ancla de la sesión que lo escribió—, al contrario que el sello
    /// monotónico de `CaptureRecord`, que solo sirve para comprobar que el registro es el que se pedía.
    public let date: Date

    /// Los bytes guardados del trozo: contenido de aplicación en claro, sin cabeceras de TLS ni de
    /// TCP — lo que la terminación leyó de una de sus dos patas.
    public let bytes: Data

    /// Lo que medía el trozo antes de recortarlo, según su cabecera de registro.
    public let originalLength: UInt32

    public init(
        location: PlaintextLocation,
        stream: UInt64,
        direction: Direction,
        date: Date,
        bytes: Data,
        originalLength: UInt32
    ) {
        self.location = location
        self.stream = stream
        self.direction = direction
        self.date = date
        self.bytes = bytes
        self.originalLength = originalLength
    }

    public var storedLength: UInt32 { UInt32(clamping: bytes.count) }

    /// Si algún tope se llevó parte del trozo.
    public var isTruncated: Bool { originalLength > storedLength }

    /// Bytes que se quedaron fuera.
    public var droppedLength: UInt32 { originalLength &- min(storedLength, originalLength) }
}

public enum PlaintextLibraryError: Error, Sendable, Equatable {
    /// El contenedor del App Group no se pudo resolver (falta el entitlement o el identificador no es
    /// el que se firmó). No es "no hay contenido descifrado": es que no se sabe dónde mirar.
    case containerUnavailable(String)

    /// Ese fichero ya no está en el directorio.
    ///
    /// **Es el caso normal, no una avería**, y aquí lo es mucho más que en las capturas: el contenido
    /// descifrado caduca por su cuenta y con un plazo corto (ADR 0007), así que una conexión de
    /// anteayer conserva su fila en el historial mientras sus bytes ya se barrieron. La pantalla tiene
    /// que saber decir eso sin parecer rota.
    case notFound(UInt32)

    /// El registro no se pudo decodificar en ese offset: el fichero se quedó a medias, la cabecera no
    /// es de las nuestras, o el offset apunta más allá del final. Lleva el detalle para el
    /// diagnóstico.
    case recordUnreadable(String)

    /// Hay un registro legible en esa posición, pero **no es el que la fila nombra**.
    ///
    /// Es el error que la `stream` del formato existe para poder dar: el índice y el fichero son dos
    /// escrituras distintas y una localización desfasada devolvería bytes de otra conversación
    /// interpretados como los de esta — enseñar el contenido descifrado de una conexión ajena bajo la
    /// cabecera de esta sería la peor avería posible de este producto, así que se dice en vez de
    /// enseñarlo.
    case recordMismatch(String)
}

/// El directorio de contenido descifrado visto desde la app: el camino de vuelta de una fila del
/// índice a los bytes que nombra (`docs/spec/plaintext.md` § *Still to build*).
///
/// Es el gemelo de `CaptureLibrary.record(at:)` y comparte su forma —un `actor` sin estado que
/// resuelve el directorio en cada operación, porque quien escribe ahí es **otro proceso**— pero no su
/// alcance: aquí **no se lista ni se borra**. Listar los ficheros ya lo hace `PlaintextDirectory` para
/// el barrido y para el almacenamiento, y borrarlos es cosa de la retención y no del usuario fichero a
/// fichero: el ADR 0007 le da un gesto para llevárselo **todo**, no una pantalla de ficheros que
/// nombrar. Lo único que la app hace aquí es leer.
///
/// La lectura es **por offset y sin recorrer el fichero**, como la del paquete: un `.tvpt` llega a 16
/// MB y enseñar un trozo de conversación no es motivo para leerlo entero. Son tres lecturas cortas —la
/// cabecera global (que da el `maxRecordBytes`), la del registro y sus bytes— y `storedLength` se acota
/// contra ese tope **antes** de reservar nada: un fichero corrupto no puede pedir memoria.
public actor PlaintextLibrary {

    /// El directorio se resuelve **en cada operación** y no se guarda, por lo mismo que en
    /// `CaptureLibrary`: la resolución del contenedor del App Group es lo que falla cuando el
    /// entitlement no está, y guardar el resultado del primer intento dejaría un fallo temprano
    /// pegado a la pantalla para siempre.
    private let resolveDirectory: @Sendable () throws -> URL

    /// Sobre un directorio concreto. Es lo que usan los tests, sobre un temporal.
    public init(directory: URL) {
        self.init(resolvingDirectory: { directory })
    }

    /// Sobre un directorio que se resuelve en cada operación. Es la costura: sin ella, el fallo de
    /// resolución del contenedor solo se podría ejercitar dentro de una app firmada con un App Group,
    /// que es justo donde no corren los tests.
    public init(resolvingDirectory: @escaping @Sendable () throws -> URL) {
        self.resolveDirectory = resolvingDirectory
    }

    /// Sobre el directorio de contenido descifrado del App Group, que es donde escribe la extensión.
    public init(appGroupID: String = AppGroup.identifier) {
        self.init(resolvingDirectory: {
            guard let url = PlaintextDirectory.url(inAppGroup: appGroupID) else {
                throw PlaintextLibraryError.containerUnavailable(appGroupID)
            }
            return url
        })
    }

    /// Los bytes de **un** trozo de contenido descifrado, los que la fila del índice nombra.
    ///
    /// Se entra por la fila y no por la localización suelta a propósito: validar que el registro es el
    /// que se pedía necesita la `stream` y las longitudes que la fila trae, y un método que aceptase
    /// solo la posición dejaría esa comprobación en manos de quien llama — que es exactamente como se
    /// acaba enseñando la conversación de otro.
    ///
    /// Un fichero que ya no está es `notFound` y no una avería: el barrido del ADR 0007 se lleva el
    /// contenido descifrado mucho antes que el historial, así que una conexión puede seguir en la
    /// Timeline con sus bytes ya borrados.
    public func record(for chunk: StoredPlaintextChunk) throws -> PlaintextRecord {
        let directory = try resolveDirectory()
        guard let url = PlaintextDirectory.url(forSequence: chunk.location.fileSequence, in: directory) else {
            throw PlaintextLibraryError.notFound(chunk.location.fileSequence)
        }
        // Un offset dentro de la cabecera global no puede ser el de ningún registro. Se comprueba
        // antes de abrir nada: es la propiedad que hace de `recordOffset == 0` un centinela seguro.
        guard chunk.location.recordOffset >= UInt64(PlaintextFormat.globalHeaderSize) else {
            throw PlaintextLibraryError.recordUnreadable(
                "Offset \(chunk.location.recordOffset) falls inside the file header."
            )
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw PlaintextLibraryError.recordUnreadable("The decrypted content file couldn't be opened.")
        }
        // El handle se cierra pase lo que pase: una conversación son muchos registros y cada uno es un
        // descriptor, así que dejarlos a merced del recolector agotaría el límite del proceso.
        defer { try? handle.close() }

        do {
            let global = try PlaintextFormat.globalHeader(
                parsing: try read(handle, count: PlaintextFormat.globalHeaderSize, from: 0)
            )
            let header = try PlaintextFormat.recordHeader(
                parsing: try read(
                    handle,
                    count: PlaintextFormat.recordHeaderSize,
                    from: chunk.location.recordOffset
                )
            )
            try verify(header, against: chunk)
            guard header.storedLength <= global.maxRecordBytes else {
                throw PlaintextLibraryError.recordUnreadable(
                    "Record claims \(header.storedLength) bytes, more than the file's \(global.maxRecordBytes)."
                )
            }

            let payloadOffset = chunk.location.recordOffset + UInt64(PlaintextFormat.recordHeaderSize)
            let bytes = try read(handle, count: Int(header.storedLength), from: payloadOffset)
            guard bytes.count == Int(header.storedLength) else {
                throw PlaintextLibraryError.recordUnreadable(
                    "Record is cut short: \(bytes.count) of \(header.storedLength) bytes are on disk."
                )
            }

            return PlaintextRecord(
                location: chunk.location,
                stream: header.stream,
                direction: header.direction,
                date: Date(timeIntervalSince1970: Double(header.timestamp) / 1_000_000_000),
                bytes: bytes,
                originalLength: header.originalLength
            )
        } catch let error as PlaintextFormat.FormatError {
            throw PlaintextLibraryError.recordUnreadable(String(describing: error))
        }
    }

    // MARK: - Interno

    /// Que el registro que hay en esa posición es el que la fila nombra.
    ///
    /// Se comprueban las tres cosas que el índice y el fichero guardan **por duplicado**, y se
    /// comprueban antes de leer un solo byte de contenido: la conversación (que es para lo que existe
    /// la `stream` del formato) y las dos longitudes, que juntas dicen que este es *este* trozo y no
    /// otro de la misma conversación. El sello no entra: la fila lo guarda pasado por el store y el
    /// fichero tal cual, y aunque hoy salgan de la misma ancla, hacerlos idénticos sería atar el
    /// lector a un detalle de cómo se escribieron.
    private func verify(_ header: PlaintextFormat.RecordHeader, against chunk: StoredPlaintextChunk) throws {
        guard header.stream == chunk.stream else {
            throw PlaintextLibraryError.recordMismatch(
                "Record at offset \(chunk.location.recordOffset) belongs to conversation "
                    + "\(header.stream), not \(chunk.stream)."
            )
        }
        guard header.storedLength == chunk.storedLength,
              header.originalLength == chunk.originalLength
        else {
            throw PlaintextLibraryError.recordMismatch(
                "Record at offset \(chunk.location.recordOffset) measures "
                    + "\(header.storedLength)/\(header.originalLength) bytes, not "
                    + "\(chunk.storedLength)/\(chunk.originalLength)."
            )
        }
    }

    /// Lee hasta `count` bytes desde un offset concreto. Devuelve lo que haya: quien llama decide si
    /// quedarse corto es un fallo (para el contenido lo es; para una cabecera lo dice el parser).
    private func read(_ handle: FileHandle, count: Int, from offset: UInt64) throws -> Data {
        guard count > 0 else { return Data() }
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count) ?? Data()
        } catch {
            throw PlaintextLibraryError.recordUnreadable(
                "Couldn't read \(count) bytes at offset \(offset): \(error.localizedDescription)"
            )
        }
    }
}
