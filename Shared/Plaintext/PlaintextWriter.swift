import Foundation

/// Escritor en streaming del **contenido descifrado** de los flujos inspeccionados.
///
/// Es la mitad que faltaba de la inspección TLS: la terminación descifra y hasta ahora no se guardaba
/// nada, así que no había qué enseñar. Su forma es deliberadamente la de `PcapWriter` —un fichero
/// abierto, rotación por tamaño, un registro en vuelo, una localización devuelta por escritura— porque
/// el problema es el mismo: escribir mucho desde un proceso con presupuesto de memoria y poder volver
/// después a un byte concreto desde el otro proceso.
///
/// ## Tres diferencias con el escritor de capturas, y las tres son a propósito
///
/// 1. **El fichero se abre en la primera escritura, no al construirlo.** Un túnel que nunca descifra
///    nada no deja ni un fichero en el disco: sin contenido no hay artefacto que borrar, que explicar
///    ni que exportar por error. El de capturas puede abrir de entrada porque capturar es lo normal;
///    descifrar es la excepción que el usuario enciende.
/// 2. **Cada registro dice de qué conversación es** (`stream`), porque un fichero intercala flujos.
///    El escritor reparte esos identificadores (`openStream`) y arranca por encima de los que el
///    índice ya referencia, por lo mismo que la secuencia de fichero: si volviera a empezar en cada
///    sesión, el contenido de una conversación de ayer se leería como el de otra de hoy.
/// 3. **Lo que se guarda está acotado dos veces.** Aquí, por registro (`maxRecordBytes`, que es el
///    `snaplen` de este formato); y antes de llegar aquí, por flujo y sentido (`PlaintextBudget`).
///    El contenido descifrado es la vida del usuario en claro: crece más rápido que cualquier otra
///    cosa que este producto escriba y es lo más sensible que guarda.
///
/// Vive en `Shared` y no en la extensión porque el formato lo lee la app (`PlaintextFormat`), y
/// escribir un fichero cuyo offset guardado hay que poder resolver es exactamente lo que el escritor
/// de capturas aprendió a no duplicar.
public actor PlaintextWriter {

    public struct Config: Sendable {
        /// Directorio donde se crean los ficheros.
        public var directory: URL

        /// Máximo de bytes guardados por registro; recorta el trozo (`storedLength < originalLength`
        /// es lo que la pantalla lee como "no está entero"). Va en la cabecera global, así que
        /// cambiarlo obligaría a rotar — hoy no se cambia en caliente y por eso no hay un `set`.
        public var maxRecordBytes: UInt32

        /// Umbral de rotación: al superarlo, el fichero actual se cierra y se abre uno nuevo. Es lo
        /// que permite que la retención borre contenido descifrado viejo sin tocar el que se está
        /// escribiendo.
        public var maxFileBytes: UInt64

        /// Mayor secuencia que el índice ya referencia, si el llamante la sabe. El escritor arranca
        /// por encima de ella aunque su fichero ya no esté en el directorio: un fichero borrado
        /// desaparece del disco, pero las filas que lo apuntaban siguen en la BD, y reutilizar su
        /// número les daría el contenido de otra conversación.
        public var highestReferencedSequence: UInt32?

        /// Mayor identificador de conversación que el índice ya referencia, por lo mismo.
        public var highestReferencedStream: UInt64?

        public init(
            directory: URL,
            maxRecordBytes: UInt32 = 64 * 1024,
            maxFileBytes: UInt64 = 16 * 1024 * 1024,
            highestReferencedSequence: UInt32? = nil,
            highestReferencedStream: UInt64? = nil
        ) {
            self.directory = directory
            self.maxRecordBytes = maxRecordBytes
            self.maxFileBytes = maxFileBytes
            self.highestReferencedSequence = highestReferencedSequence
            self.highestReferencedStream = highestReferencedStream
        }
    }

    public enum PlaintextWriteError: Error, Sendable, Equatable {
        /// No se pudo crear o abrir el fichero (p. ej. directorio no escribible).
        case openFailed
        /// Falló una escritura en disco (p. ej. disco lleno). Se propaga siempre: el llamante decide
        /// si deja de descifrar, y nunca se traga en silencio.
        case writeFailed
        /// No queda secuencia de fichero disponible (`UInt32.max`). Inalcanzable en la práctica, pero
        /// se modela porque la alternativa sería reutilizar un número y que una fila guardada
        /// apuntase al contenido de otro fichero. (Los identificadores de conversación son `UInt64` y
        /// por eso no tienen su propio error: agotarlos exige 1,8·10¹⁹ flujos inspeccionados.)
        case sequenceExhausted
        /// Se escribió después de `close()`. Es un error del llamante, no del disco.
        case closed
    }

    private let config: Config
    private var handle: FileHandle?
    /// Offset dentro del fichero actual = su tamaño en bytes. Es también el offset del próximo
    /// registro (apunta a su cabecera), que es lo que devuelve `write`.
    private var bytesWritten: UInt64 = 0
    /// Secuencia del fichero abierto. `nil` hasta la primera escritura, porque hasta entonces no hay
    /// fichero: la reserva de secuencia se hace al abrir, no al construir.
    private var sequence: UInt32?
    /// Próximo identificador de conversación a repartir.
    private var nextStream: UInt64
    private var isClosed = false

    /// No abre nada ni toca el disco: el primer fichero se crea con el primer byte descifrado.
    public init(config: Config) {
        self.config = config
        // El primero libre, no el último usado: un `nil` significa que el índice no referencia
        // ninguno y entonces se empieza por 0.
        self.nextStream = config.highestReferencedStream.map { $0 &+ 1 } ?? 0
    }

    /// Reparte el identificador de una conversación nueva. Uno por flujo inspeccionado, nunca por
    /// trozo: es lo que empareja los registros dispersos de un mismo flujo dentro de los ficheros.
    public func openStream() -> UInt64 {
        defer { nextStream &+= 1 }
        return nextStream
    }

    /// Escribe un trozo de contenido descifrado y devuelve dónde quedó.
    ///
    /// - Parameters:
    ///   - plaintext: el trozo tal y como salió de la terminación. Se recorta a `maxRecordBytes`.
    ///   - stream: el identificador que `openStream` dio para ese flujo.
    ///   - direction: quién lo mandó.
    ///   - timestamp: nanosegundos **desde el epoch** (`MonotonicAnchor.nanosecondsSince1970`), no el
    ///     sello monotónico crudo: estos ficheros sobreviven a la sesión que los escribió y un
    ///     instante que no se puede fechar después no sirve para ordenar nada.
    /// - Returns: la localización del registro, o `nil` si no había nada que guardar (un trozo vacío
    ///   no es un error y tampoco merece un registro).
    @discardableResult
    public func write(
        _ plaintext: Data,
        stream: UInt64,
        direction: Direction,
        timestamp: Int64
    ) throws -> PlaintextLocation? {
        guard !isClosed else { throw PlaintextWriteError.closed }
        guard !plaintext.isEmpty else { return nil }

        let handle = try openIfNeeded()
        guard let sequence else { throw PlaintextWriteError.openFailed }

        let storedLength = min(UInt32(clamping: plaintext.count), config.maxRecordBytes)
        let originalLength = UInt32(clamping: plaintext.count)
        // Se compone antes de escribir, y por tanto antes de la posible rotación: el registro
        // pertenece al fichero abierto ahora, no al que abra la rotación de después.
        let location = PlaintextLocation(fileSequence: sequence, recordOffset: bytesWritten)

        var record = PlaintextFormat.recordHeader(
            stream: stream,
            timestamp: timestamp,
            storedLength: storedLength,
            originalLength: originalLength,
            direction: direction
        )
        record.append(plaintext.prefix(Int(storedLength)))

        do {
            try handle.write(contentsOf: record)
        } catch {
            throw PlaintextWriteError.writeFailed
        }
        bytesWritten += UInt64(record.count)

        if bytesWritten >= config.maxFileBytes {
            try rotate()
        }
        return location
    }

    /// Cierra el fichero actual y abre uno nuevo en la siguiente escritura. Rotación manual o
    /// disparada por tamaño desde `write`.
    ///
    /// No abre el fichero siguiente en el acto, a diferencia del escritor de capturas: seguiría
    /// valiendo la regla de que un fichero solo existe cuando hay contenido que meter en él, y rotar
    /// sin escribir después dejaría un fichero vacío en el disco.
    public func rotate() throws {
        guard let current = sequence else { return }
        guard current < .max else { throw PlaintextWriteError.sequenceExhausted }
        closeHandle()
        sequence = nil
        bytesWritten = 0
        // La siguiente apertura calcula su secuencia mirando el directorio, así que basta con soltar
        // la actual: el fichero que se acaba de cerrar ya está ahí y su número será el de partida.
    }

    /// Fuerza el vaciado a disco sin cerrar, para que un crash no pierda lo ya escrito. No hace nada
    /// si todavía no se ha abierto ningún fichero: no haber descifrado nada no es un fallo.
    public func flush() throws {
        guard let handle else { return }
        do {
            try handle.synchronize()
        } catch {
            throw PlaintextWriteError.writeFailed
        }
    }

    /// Vacía a disco y cierra. Idempotente; tras esto, `write` falla con `.closed` en vez de abrir un
    /// fichero nuevo — cerrar el escritor es el final de la sesión, no una pausa.
    public func close() {
        closeHandle()
        isClosed = true
    }

    /// Ficheros existentes en el directorio, ordenados cronológicamente (por secuencia).
    public func files() -> [URL] {
        PlaintextDirectory.files(in: config.directory).map(\.url)
    }

    /// Secuencia del fichero que se está escribiendo, o `nil` si no hay ninguno abierto. La retención
    /// la necesita para no borrar aquello sobre lo que se está escribiendo.
    public var currentFileSequence: UInt32? { sequence }

    // MARK: - Interno

    /// Abre el fichero si hace falta y devuelve su handle. Es el único sitio donde se reserva una
    /// secuencia, así que la identidad de un fichero y su existencia en el disco nacen juntas.
    private func openIfNeeded() throws -> FileHandle {
        if let handle { return handle }

        let next = try firstSequence()
        let url = config.directory.appendingPathComponent(
            PlaintextFileName.make(sequence: next, date: Date())
        )
        let opened = try Self.openFile(at: url, maxRecordBytes: config.maxRecordBytes)
        handle = opened
        sequence = next
        bytesWritten = UInt64(PlaintextFormat.globalHeaderSize)
        return opened
    }

    /// Primera secuencia utilizable: una por encima de la mayor que ya existe, mirando **tanto** el
    /// directorio como lo que el índice referencia. Sin ficheros ni referencias, empieza en 0.
    private func firstSequence() throws -> UInt32 {
        let candidates = [
            PlaintextDirectory.highestSequence(in: config.directory),
            config.highestReferencedSequence,
        ].compactMap { $0 }
        guard let highest = candidates.max() else { return 0 }
        guard highest < .max else { throw PlaintextWriteError.sequenceExhausted }
        return highest + 1
    }

    /// Crea el fichero, escribe su cabecera global y devuelve el handle listo para append.
    private static func openFile(at url: URL, maxRecordBytes: UInt32) throws -> FileHandle {
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        guard manager.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            throw PlaintextWriteError.openFailed
        }

        do {
            try handle.write(contentsOf: PlaintextFormat.globalHeader(maxRecordBytes: maxRecordBytes))
        } catch {
            try? handle.close()
            throw PlaintextWriteError.writeFailed
        }
        return handle
    }

    /// Sincroniza y cierra el handle en modo best-effort. El cierre no propaga errores: es teardown.
    private func closeHandle() {
        guard let handle else { return }
        try? handle.synchronize()
        try? handle.close()
        self.handle = nil
    }
}
