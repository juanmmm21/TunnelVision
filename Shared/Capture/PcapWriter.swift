import Foundation

/// Escritor de capturas en formato libpcap clásico (`LINKTYPE_RAW`), en streaming.
///
/// Vive en `Shared/Capture` y no en `PacketTunnel/Capture` desde M11, cuando dejó de tener un solo
/// consumidor: el sembrador de capturas sintéticas (`Shared/Fixtures`) escribe sus `.pcap` con **este
/// mismo** writer, y tenía que poder hacerlo desde la app. Escribirlos por su cuenta con `PcapFormat`
/// habría duplicado la única regla que la pareja fichero+offset existe para proteger —que el offset
/// que se guarda es el de la cabecera del registro dentro del fichero abierto en ese momento—, y una
/// captura sembrada con offsets calculados aparte se validaría a sí misma mientras la pantalla de un
/// paquete leería otros bytes. Es el mismo movimiento que hicieron `PcapFormat`, `CaptureFileName`,
/// `TunnelAddressing`, `MonotonicAnchor`, el codec del canal de control y `PacketParser`/`PacketEmitter`.
///
/// Streaming es obligatorio: el presupuesto de memoria de la extensión prohíbe retener la captura.
/// El writer solo mantiene un buffer del tamaño de **un** registro (cabecera de 16 bytes + hasta
/// `snaplen` bytes del paquete); lo append-ea al fichero y lo descarta. Nunca guarda registros
/// pasados en memoria: el estado residente es O(1) sin importar cuánto dure la captura.
///
/// Cuando el fichero actual supera `maxFileBytes`, `write` rota automáticamente a un fichero nuevo
/// con nombre único y ordenable, de modo que cada fichero es independiente y compartible por sí solo.
///
/// Timestamps: `write` recibe el instante en **nanosegundos desde el epoch** y lo descompone en los
/// `ts_sec`/`ts_usec` que exige el formato, que son absolutos por definición. La conversión desde el
/// sello monotónico del hot path (`PacketMeta.timestamp`) la hace **quien tiene el ancla de la
/// sesión** —el pipeline y el sembrador—, igual que con el contenido descifrado: pasarle aquí el
/// reloj monotónico dejaba toda captura exportada fechada en 1970 (uptime leído como epoch), con los
/// deltas entre paquetes correctos pero la hora de cada uno falsa en Wireshark.
public actor PcapWriter {

    public struct Config: Sendable {
        /// Directorio donde se crean los ficheros de captura.
        public var directory: URL
        /// Máximo de bytes capturados por paquete; recorta el payload (Wireshark lo marca como
        /// truncado vía `incl_len < orig_len`).
        public var snaplen: UInt32
        /// Umbral de rotación: al superarlo, el fichero actual se cierra y se abre uno nuevo.
        public var maxFileBytes: UInt64

        /// Mayor secuencia que el historial ya referencia, si el llamante la sabe
        /// (`FlowStore.highestCaptureFileSequence()`). El writer arranca por encima de ella aunque
        /// su fichero ya no esté en el directorio: un fichero borrado desaparece del disco, pero
        /// los paquetes que lo apuntaban siguen en la BD, y reutilizar su número les daría los
        /// bytes de otra conexión — justo lo que la localización existe para impedir.
        public var highestReferencedSequence: UInt32?

        public init(
            directory: URL,
            snaplen: UInt32 = 262_144,
            maxFileBytes: UInt64 = 64 * 1024 * 1024,
            highestReferencedSequence: UInt32? = nil
        ) {
            self.directory = directory
            self.snaplen = snaplen
            self.maxFileBytes = maxFileBytes
            self.highestReferencedSequence = highestReferencedSequence
        }
    }

    public enum PcapError: Error, Sendable, Equatable {
        /// No se pudo crear o abrir el fichero de captura (p. ej. directorio no escribible).
        case openFailed
        /// Falló una escritura en disco (p. ej. disco lleno). Se propaga siempre al caller para
        /// que detenga la captura y avise al usuario; nunca se traga en silencio.
        case writeFailed
        /// No queda secuencia de fichero disponible (`UInt32.max`). Inalcanzable en la práctica
        /// —4·10⁹ ficheros—, pero se modela porque la alternativa sería reutilizar un número y
        /// dejar que un paquete guardado apuntase a los bytes de otro fichero.
        case sequenceExhausted
    }

    /// `var` por un solo campo: el `snaplen` se puede cambiar en caliente (`setSnaplen`). Todo lo demás
    /// —el directorio, el umbral de rotación— se fija al abrir la sesión.
    private var config: Config
    private var handle: FileHandle?
    /// Fichero abierto ahora mismo.
    private var currentURL: URL
    /// Offset dentro del fichero actual = su tamaño en bytes. Es también el offset que devuelve
    /// `write` para el próximo registro (apunta a su cabecera), usado por `PacketMeta.capture`.
    private var bytesWritten: UInt64
    /// Secuencia del fichero abierto: su identidad, la que se guarda con cada paquete y la que
    /// prefija el nombre. **No arranca en 0 por sesión**, sino por encima de la mayor que ya haya
    /// en el directorio: si volviera a empezar, el offset guardado de un paquete de ayer señalaría
    /// los bytes del fichero de hoy.
    private var sequence: UInt32

    /// Abre el primer fichero y escribe su cabecera global.
    public init(config: Config) throws {
        self.config = config
        self.sequence = try Self.firstSequence(for: config)
        let url = Self.makeFileURL(directory: config.directory, sequence: sequence)
        self.currentURL = url
        self.handle = try Self.openFile(at: url, snaplen: config.snaplen)
        self.bytesWritten = UInt64(PcapFormat.globalHeaderSize)
    }

    /// Escribe un paquete y devuelve dónde quedó: el fichero actual y el offset de su registro.
    ///
    /// - Parameter timestamp: instante del paquete en **nanosegundos desde el epoch**
    ///   (`MonotonicAnchor.nanosecondsSince1970(forUptime:)`), no el sello monotónico crudo.
    @discardableResult
    public func write(packet: Data, originalLength: Int, timestamp: Int64) throws -> CaptureLocation {
        guard let handle else { throw PcapError.writeFailed }

        let inclLen = min(UInt32(clamping: packet.count), config.snaplen)
        let origLen = UInt32(clamping: originalLength)
        let (tsSec, tsUsec) = Self.split(nanosecondsSince1970: timestamp)
        // Se compone antes de escribir, y por tanto antes de la posible rotación: el registro
        // pertenece al fichero abierto ahora, no al que abra la rotación de después.
        let location = CaptureLocation(fileSequence: sequence, recordOffset: bytesWritten)

        var record = PcapFormat.recordHeader(tsSec: tsSec, tsUsec: tsUsec, inclLen: inclLen, origLen: origLen)
        if inclLen > 0 {
            record.append(packet.prefix(Int(inclLen)))
        }

        do {
            try handle.write(contentsOf: record)
        } catch {
            throw PcapError.writeFailed
        }
        bytesWritten += UInt64(record.count)

        if bytesWritten >= config.maxFileBytes {
            try rotate()
        }
        return location
    }

    /// Cierra el fichero actual y abre uno nuevo. Rotación manual o disparada por tamaño desde `write`.
    public func rotate() throws {
        guard sequence < .max else { throw PcapError.sequenceExhausted }
        closeHandle()
        sequence += 1
        let url = Self.makeFileURL(directory: config.directory, sequence: sequence)
        currentURL = url
        handle = try Self.openFile(at: url, snaplen: config.snaplen)
        bytesWritten = UInt64(PcapFormat.globalHeaderSize)
    }

    /// Cambia cuánto se guarda de cada paquete, **rotando** a un fichero nuevo.
    ///
    /// La rotación no es un efecto secundario, es el mecanismo: el `snaplen` va en la cabecera global
    /// del `.pcap`, así que es del fichero y no del registro. Aplicarlo sobre el fichero abierto dejaría
    /// registros que miden más de lo que su propia cabecera declara, y el lector acota `incl_len` contra
    /// ese `snaplen` antes de reservar memoria (`docs/spec/pcap.md`): el fichero se leería como corrupto,
    /// incluida la pantalla de un paquete de esta misma app.
    ///
    /// No hace nada si ya es el que hay. Un ajuste que se reelige igual no puede costar un fichero: la
    /// pantalla de capturas se llenaría de ficheros de unos pocos kilobytes por tocar un selector.
    public func setSnaplen(_ snaplen: UInt32) throws {
        guard snaplen != config.snaplen else { return }
        config.snaplen = snaplen
        try rotate()
    }

    /// Fuerza el vaciado a disco del fichero actual **sin** cerrarlo, para que un crash no pierda lo
    /// ya capturado. No cierra el handle a propósito: un writer en streaming necesita seguir
    /// escribiendo tras un flush periódico; el cierre definitivo lo hacen `rotate()`/`close()`.
    public func flush() throws {
        guard let handle else { throw PcapError.writeFailed }
        do {
            try handle.synchronize()
        } catch {
            throw PcapError.writeFailed
        }
    }

    /// Vacía a disco y cierra el handle actual. Idempotente; tras esto, `write` falla.
    public func close() {
        closeHandle()
    }

    /// Ficheros de captura existentes en el directorio, ordenados cronológicamente (por secuencia).
    public func captureFiles() -> [URL] {
        CaptureDirectory.files(in: config.directory).map(\.url)
    }

    /// Secuencia del fichero que se está escribiendo: la identidad que llevan los paquetes de ahora.
    public var currentFileSequence: UInt32 { sequence }

    // MARK: - Interno

    /// Crea el fichero, escribe su cabecera global y devuelve el handle abierto listo para append.
    /// Es `static` (nonisolated) a propósito para poder invocarse desde `init` bajo concurrencia
    /// estricta, donde `self` aún no está aislado.
    private static func openFile(at url: URL, snaplen: UInt32) throws -> FileHandle {
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        guard manager.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            throw PcapError.openFailed
        }

        do {
            try handle.write(contentsOf: PcapFormat.globalHeader(snaplen: snaplen))
        } catch {
            try? handle.close()
            throw PcapError.writeFailed
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

    /// Descompone nanosegundos desde el epoch en (segundos, microsegundos) para la cabecera de
    /// registro.
    ///
    /// Un instante anterior al epoch se escribe como el epoch en vez de envolver: los dos campos del
    /// formato son `UInt32` sin signo, así que una resta negativa —solo alcanzable con el reloj del
    /// dispositivo mal puesto— daría una fecha del año 2106 en Wireshark, que miente más que 1970.
    private static func split(nanosecondsSince1970: Int64) -> (sec: UInt32, usec: UInt32) {
        guard nanosecondsSince1970 > 0 else { return (0, 0) }
        let sec = nanosecondsSince1970 / 1_000_000_000
        let usec = (nanosecondsSince1970 % 1_000_000_000) / 1_000
        return (UInt32(clamping: sec), UInt32(clamping: usec))
    }

    /// Primera secuencia utilizable: una por encima de la mayor que ya existe, mirando **tanto** el
    /// directorio como lo que el historial referencia. Sin ficheros ni referencias, empieza en 0.
    ///
    /// Es la decisión que hace que la secuencia identifique un fichero y no solo su posición dentro
    /// de una sesión: si cada sesión reiniciara en 0, el offset guardado de un paquete de ayer
    /// señalaría los bytes del fichero de hoy.
    private static func firstSequence(for config: Config) throws -> UInt32 {
        let candidates = [
            CaptureDirectory.highestSequence(in: config.directory),
            config.highestReferencedSequence,
        ].compactMap { $0 }
        guard let highest = candidates.max() else { return 0 }
        guard highest < .max else { throw PcapError.sequenceExhausted }
        return highest + 1
    }

    /// El nombre lo compone `CaptureFileName` (en `Shared`) y no el writer: la app tiene que poder
    /// leer la secuencia de vuelta para resolver la `CaptureLocation` de un paquete, así que
    /// formatearlo y parsearlo son la misma verdad y viven en un solo sitio.
    private static func makeFileURL(directory: URL, sequence: UInt32) -> URL {
        directory.appendingPathComponent(CaptureFileName.make(sequence: sequence, date: Date()))
    }
}
