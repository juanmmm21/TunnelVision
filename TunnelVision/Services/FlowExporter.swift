import Foundation
import Shared

/// Lo que queda de un export: el fichero listo para compartir y qué hay dentro.
public struct FlowExportResult: Sendable, Equatable {

    public let url: URL

    /// Conexiones escritas. La pantalla lo dice antes de compartir: un export no es una copia del
    /// historial, y ofrecerlo como si lo fuera es la única forma de que decepcione.
    public let connectionCount: Int

    public let byteCount: UInt64

    /// Si el historial tenía más conexiones de las que cabían en el tope.
    public let truncated: Bool

    public init(url: URL, connectionCount: Int, byteCount: UInt64, truncated: Bool) {
        self.url = url
        self.connectionCount = connectionCount
        self.byteCount = byteCount
        self.truncated = truncated
    }
}

public enum FlowExportError: Error, Sendable, Equatable {
    /// El historial no se dejó leer a mitad del recorrido. Llega tipado desde el lector para que la
    /// pantalla pueda decir lo mismo que diría la Timeline ante el mismo fallo.
    case historyUnreadable(HistoryError)
    /// El fichero no se pudo crear o no se pudo escribir entero.
    case writeFailed(String)
}

/// El export del listado de conexiones en JSON (`docs/ux/screens.md`, pantalla *Captures*): recorre
/// el historial hacia atrás en el tiempo y lo escribe en un fichero temporal listo para el share
/// sheet.
///
/// **Es la primera vez que la app genera un fichero suyo.** Todo lo que se ha compartido hasta ahora
/// (los `.pcap`) ya existía en disco porque lo escribió la extensión; esto hay que crearlo, así que
/// hace falta decidir dónde vive y quién lo borra. Vive en el **directorio temporal de la app** y no
/// en el contenedor del App Group, por dos motivos: no es una captura (dejarlo entre ellas lo metería
/// en el listado de la pantalla y en los planes de retención, que cuentan bytes de capturas) y no
/// tiene por qué sobrevivir a nada — quien lo quiera guardado ya lo ha compartido.
///
/// **Del anterior no queda rastro:** cada export limpia el directorio antes de escribir, así que hay
/// como mucho un fichero a la vez. Acumularlos convertiría el temporal en un almacén silencioso de
/// copias del historial, que es justo lo que un producto que promete no sacar datos del dispositivo
/// no debe tener.
///
/// Es un `actor` como `CaptureLibrary` y por lo mismo: escribe en disco, y el disco no se toca desde
/// el hilo principal. El historial entra como **closure de páginas** en vez de como `HistoryReader`
/// para no acoplar el escritor a quién le da las filas — y porque el estado de paginación de la
/// Timeline es de la Timeline: este recorrido lleva el suyo y no mueve el de nadie.
public actor FlowExporter {

    /// Pide una página de conexiones: `(cuántas, desde dónde)`. Devolver menos de las pedidas
    /// significa que el historial se acabó, el mismo contrato que usa el `HistoryReader` por dentro.
    public typealias PageProvider = @Sendable (Int, FlowCursor?) async throws -> [HistoryFlow]

    private let resolveDirectory: @Sendable () throws -> URL
    private let limit: Int
    private let pageSize: Int

    /// Sobre un directorio concreto. Es lo que usan los tests, sobre un temporal.
    public init(
        directory: URL,
        limit: Int = FlowExport.defaultLimit,
        pageSize: Int = FlowExport.defaultPageSize
    ) {
        self.init(resolvingDirectory: { directory }, limit: limit, pageSize: pageSize)
    }

    /// Sobre un directorio que se resuelve en cada export, igual que en `CaptureLibrary`: guardar la
    /// primera resolución pegaría un fallo temprano a la pantalla para siempre.
    public init(
        resolvingDirectory: @escaping @Sendable () throws -> URL,
        limit: Int = FlowExport.defaultLimit,
        pageSize: Int = FlowExport.defaultPageSize
    ) {
        precondition(limit > 0, "limit debe ser positivo")
        precondition(pageSize > 0, "pageSize debe ser positivo")
        self.resolveDirectory = resolvingDirectory
        self.limit = limit
        self.pageSize = pageSize
    }

    /// Sobre el directorio de exports de la app, dentro de su temporal.
    public init(
        limit: Int = FlowExport.defaultLimit,
        pageSize: Int = FlowExport.defaultPageSize
    ) {
        self.init(
            resolvingDirectory: {
                FileManager.default.temporaryDirectory
                    .appendingPathComponent("Exports", isDirectory: true)
            },
            limit: limit,
            pageSize: pageSize
        )
    }

    /// Escribe el listado y devuelve el fichero.
    ///
    /// Se escribe **a trozos**: una página del historial cabe en memoria, el documento entero no
    /// tiene por qué. El tope (`FlowExport.defaultLimit`) acota además cuánto tarda y cuánto ocupa, y
    /// si se alcanza, tanto el fichero como el resultado lo dicen.
    ///
    /// Un fallo a mitad **se lleva el fichero por delante**: lo que quedaría en disco es un JSON sin
    /// cerrar, y compartir un fichero inválido es peor que no tener ninguno — quien lo abriese no
    /// vería un error, vería un historial que se acaba antes de tiempo.
    public func export(now: Date = Date(), pages: PageProvider) async throws -> FlowExportResult {
        let directory = try prepareDirectory()
        let url = directory.appendingPathComponent(FlowExport.fileName(exportedAt: now))

        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw FlowExportError.writeFailed("Couldn't create \(url.lastPathComponent).")
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? FileManager.default.removeItem(at: url)
            throw FlowExportError.writeFailed("Couldn't open \(url.lastPathComponent) for writing.")
        }

        var serializer = FlowExportSerializer(exportedAt: now)
        var cursor: FlowCursor?
        var truncated = false

        do {
            try write(serializer.start(), to: handle)

            pagination: while serializer.writtenCount < limit {
                let wanted = min(pageSize, limit - serializer.writtenCount)
                let page: [HistoryFlow]
                do {
                    page = try await pages(wanted, cursor)
                } catch {
                    throw FlowExportError.historyUnreadable(HistoryError.classifying(error))
                }

                for flow in page {
                    // El cursor avanza con **cada** fila leída y no solo con las escritas: es lo que
                    // permite continuar exactamente donde se dejó cuando el tope corta una página por
                    // la mitad.
                    cursor = FlowCursor(after: flow.stored)
                    guard serializer.writtenCount < limit else {
                        truncated = true
                        break pagination
                    }
                    try write(try serializer.append(flow), to: handle)
                }

                // Una página incompleta significa que el historial se acabó. Es el único final que
                // **no** es un recorte: el fichero lleva todo lo que había.
                if page.count < wanted { break }
            }

            // Se llegó al tope justo con la última página: solo hay recorte si el historial sigue
            // teniendo filas por detrás, y eso hay que preguntarlo en vez de suponerlo.
            if !truncated, serializer.writtenCount >= limit {
                let next = try? await pages(1, cursor)
                truncated = !(next?.isEmpty ?? true)
            }

            try write(serializer.finish(truncated: truncated), to: handle)
            try handle.close()
        } catch {
            // El handle se cierra y el fichero a medias se borra pase lo que pase.
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw error as? FlowExportError ?? .writeFailed(error.localizedDescription)
        }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return FlowExportResult(
            url: url,
            connectionCount: serializer.writtenCount,
            byteCount: UInt64(max(0, size)),
            truncated: truncated
        )
    }

    // MARK: - Interno

    /// Crea el directorio si hace falta y se lleva por delante el export anterior.
    ///
    /// Solo borra ficheros con **nuestro** nombre: el temporal de la app es de la app, pero borrar a
    /// ciegas todo lo que haya en un directorio que uno no ha creado del todo es un hábito caro de
    /// tener, y el prefijo ya identifica lo que este actor escribió.
    private func prepareDirectory() throws -> URL {
        let directory: URL
        do {
            directory = try resolveDirectory()
        } catch {
            throw FlowExportError.writeFailed(error.localizedDescription)
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw FlowExportError.writeFailed(error.localizedDescription)
        }

        let existing = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        for file in existing where FlowExport.isExportFileName(file.lastPathComponent) {
            // Que un borrado falle no impide escribir el export nuevo: lo que se pierde es espacio
            // temporal, y negarle el export al usuario por eso sería desproporcionado.
            try? FileManager.default.removeItem(at: file)
        }
        return directory
    }

    private func write(_ data: Data, to handle: FileHandle) throws {
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw FlowExportError.writeFailed(error.localizedDescription)
        }
    }
}
