import Foundation

/// Un registro leído de un `.pcap`: su cabecera y los bytes guardados del paquete.
public struct PcapRecord: Sendable, Equatable {
    public let header: PcapFormat.RecordHeader

    /// El datagrama IP desnudo, hasta `snaplen`: `header.inclLen` bytes exactos.
    public let bytes: Data

    public init(header: PcapFormat.RecordHeader, bytes: Data) {
        self.header = header
        self.bytes = bytes
    }

    /// Microsegundos desde el epoch, que es lo que escribe `PcapWriter`.
    public var timestampMicroseconds: UInt64 {
        UInt64(header.tsSec) * 1_000_000 + UInt64(header.tsUsec)
    }
}

/// Un fichero de captura abierto para leer registros **por su offset**, sin recorrerlo.
///
/// Es la lectura que hacía `CaptureLibrary` para enseñar un paquete, sacada a `Shared` cuando
/// ganó un segundo lector: la captura de un paquete de evidencia recorta los `.pcap` rotados a
/// los paquetes de una sesión, y validar un registro —que el offset no caiga en la cabecera, que
/// no pida más memoria que el `snaplen` de su fichero, que esté entero— tiene que ser una sola
/// regla. Abrir el fichero una vez y leer muchos registros es además lo que el recorte necesita.
///
/// No es `Sendable`: lleva un descriptor abierto y vive dentro de una sola función, que lo cierra.
public final class PcapFileReader {

    public enum ReadError: Error, Sendable, Equatable {
        case openFailed
        /// Un offset dentro de la cabecera global no puede ser el de ningún registro: es la
        /// propiedad que hace de `recordOffset == 0` un centinela seguro.
        case offsetInsideFileHeader(UInt64)
        /// La cabecera global no es de las nuestras, o falta sitio para una cabecera.
        case format(PcapFormat.FormatError)
        /// El registro dice medir más que el `snaplen` del fichero. Se comprueba **antes** de
        /// reservar nada: un fichero corrupto no puede pedir memoria.
        case recordExceedsSnaplen(inclLen: UInt32, snaplen: UInt32)
        /// El fichero se acaba antes que el registro (la extensión pudo morir escribiéndolo).
        case recordCutShort(expected: UInt32, actual: Int)
        case readFailed(byteCount: Int, offset: UInt64, reason: String)
    }

    /// El `snaplen` y la capa de enlace del fichero, ya validados.
    public let header: PcapFormat.GlobalHeader

    private let handle: FileHandle

    /// Abre el fichero y lee su cabecera global. Si no es un `.pcap` de los nuestros, no se abre.
    public init(url: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ReadError.openFailed
        }
        do {
            let bytes = try Self.read(handle, count: PcapFormat.globalHeaderSize, from: 0)
            self.header = try Self.parsing { try PcapFormat.globalHeader(parsing: bytes) }
        } catch {
            try? handle.close()
            throw error
        }
        self.handle = handle
    }

    /// El registro cuya cabecera está en `offset`.
    public func record(at offset: UInt64) throws -> PcapRecord {
        guard offset >= UInt64(PcapFormat.globalHeaderSize) else {
            throw ReadError.offsetInsideFileHeader(offset)
        }
        let headerBytes = try Self.read(handle, count: PcapFormat.recordHeaderSize, from: offset)
        let recordHeader = try Self.parsing { try PcapFormat.recordHeader(parsing: headerBytes) }
        guard recordHeader.inclLen <= header.snaplen else {
            throw ReadError.recordExceedsSnaplen(inclLen: recordHeader.inclLen, snaplen: header.snaplen)
        }
        let bytes = try Self.read(
            handle,
            count: Int(recordHeader.inclLen),
            from: offset + UInt64(PcapFormat.recordHeaderSize)
        )
        guard bytes.count == Int(recordHeader.inclLen) else {
            throw ReadError.recordCutShort(expected: recordHeader.inclLen, actual: bytes.count)
        }
        return PcapRecord(header: recordHeader, bytes: bytes)
    }

    /// Cierra el descriptor. Quien abre un lector lo cierra: cada uno es un descriptor del proceso.
    public func close() {
        try? handle.close()
    }

    /// Lee hasta `count` bytes desde un offset. Devuelve lo que haya: si quedarse corto es un
    /// fallo lo decide quien llama (para un paquete lo es; para una cabecera lo dice su parser).
    private static func read(_ handle: FileHandle, count: Int, from offset: UInt64) throws -> Data {
        guard count > 0 else { return Data() }
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count) ?? Data()
        } catch {
            throw ReadError.readFailed(byteCount: count, offset: offset, reason: error.localizedDescription)
        }
    }

    private static func parsing<Value>(_ body: () throws -> Value) throws -> Value {
        do {
            return try body()
        } catch let error as PcapFormat.FormatError {
            throw ReadError.format(error)
        }
    }
}
