import Foundation

/// Constantes y serialización del formato libpcap clásico, en los dos sentidos: escribirlo y leerlo.
///
/// La extensión lee **paquetes IP desnudos** (sin cabecera Ethernet), así que el link-layer es
/// `LINKTYPE_RAW` (DLT_RAW, 101): cada registro es un datagrama IP tal cual. Todos los campos se
/// escriben en little-endian de forma explícita — no dependemos del endianness del host —, lo que
/// hace la salida byte-a-byte determinista para los tests y coherente con la `magic` `0xa1b2c3d4`,
/// que a su vez le indica al lector que los timestamps son en microsegundos.
///
/// Vive en `Shared` y no en `PacketTunnel/Capture` desde M9: la extensión escribe estos ficheros y la
/// **app los parsea** para llegar a los bytes de un paquete concreto (`CaptureLocation`), así que el
/// formato de escritura y el de lectura tienen que ser una sola verdad. Es el mismo movimiento que
/// hicieron `CaptureFileName`, `TunnelAddressing`, `MonotonicAnchor` y el codec del canal de control.
public enum PcapFormat {

    public static let magic: UInt32 = 0xa1b2c3d4
    /// La misma `magic` vista desde el otro endianness. No se escribe nunca —el writer fija
    /// little-endian—, pero reconocerla permite decir "este fichero no lo escribimos nosotros" en vez
    /// de dar por corrupta una cabecera que está perfectamente bien.
    public static let swappedMagic: UInt32 = 0xd4c3b2a1
    public static let versionMajor: UInt16 = 2
    public static let versionMinor: UInt16 = 4
    public static let thiszone: Int32 = 0
    public static let sigfigs: UInt32 = 0
    /// DLT_RAW: cada registro es un paquete IP desnudo, sin capa de enlace.
    public static let linktypeRaw: UInt32 = 101

    public static let globalHeaderSize = 24
    public static let recordHeaderSize = 16

    // MARK: - Escritura

    /// Cabecera global (24 bytes), escrita una vez al abrir cada fichero.
    public static func globalHeader(snaplen: UInt32) -> Data {
        var data = Data(capacity: globalHeaderSize)
        data.appendLittleEndian(magic)
        data.appendLittleEndian(versionMajor)
        data.appendLittleEndian(versionMinor)
        data.appendLittleEndian(thiszone)
        data.appendLittleEndian(sigfigs)
        data.appendLittleEndian(snaplen)
        data.appendLittleEndian(linktypeRaw)
        return data
    }

    /// Cabecera de registro (16 bytes), antes de los `inclLen` bytes del paquete.
    public static func recordHeader(tsSec: UInt32, tsUsec: UInt32, inclLen: UInt32, origLen: UInt32) -> Data {
        var data = Data(capacity: recordHeaderSize)
        data.appendLittleEndian(tsSec)
        data.appendLittleEndian(tsUsec)
        data.appendLittleEndian(inclLen)
        data.appendLittleEndian(origLen)
        return data
    }

    // MARK: - Lectura

    /// Lo que hace falta de la cabecera global para leer un registro suelto: cuánto puede medir como
    /// mucho y de qué capa de enlace son los bytes que vienen detrás.
    ///
    /// No lleva la versión ni la zona horaria porque nadie decide nada con ellas. `snaplen` sí: es el
    /// tope con el que se acota una lectura **antes** de reservar memoria, y `linkType` es lo que dice
    /// cómo hay que interpretar el paquete.
    public struct GlobalHeader: Sendable, Equatable {
        public let snaplen: UInt32
        public let linkType: UInt32

        public init(snaplen: UInt32, linkType: UInt32) {
            self.snaplen = snaplen
            self.linkType = linkType
        }
    }

    /// La cabecera de un registro: cuándo se capturó, cuántos bytes hay guardados y cuántos medía el
    /// paquete de verdad. `inclLen < origLen` es exactamente lo que significa "recortado por snaplen".
    public struct RecordHeader: Sendable, Equatable {
        public let tsSec: UInt32
        public let tsUsec: UInt32
        public let inclLen: UInt32
        public let origLen: UInt32

        public init(tsSec: UInt32, tsUsec: UInt32, inclLen: UInt32, origLen: UInt32) {
            self.tsSec = tsSec
            self.tsUsec = tsUsec
            self.inclLen = inclLen
            self.origLen = origLen
        }
    }

    public enum FormatError: Error, Sendable, Equatable {
        /// Hay menos bytes de los que la cabecera necesita: el fichero se quedó a medias (la extensión
        /// pudo morir escribiendo) o el offset apunta más allá del final.
        case shortHeader(expected: Int, actual: Int)
        /// El fichero no empieza por nuestra `magic`. Si es `swappedMagic`, lo escribió otra
        /// herramienta en big-endian; cualquier otra cosa no es un `.pcap` clásico.
        case unknownMagic(UInt32)
        /// Un `.pcap` legible, pero de otra capa de enlace: sus registros no son datagramas IP
        /// desnudos, y enseñarlos como si lo fueran daría una lectura falsa de cada byte.
        case unsupportedLinkType(UInt32)
    }

    /// Parsea la cabecera global de un fichero de captura.
    ///
    /// Rechaza lo que no escribimos nosotros en vez de intentar adaptarse: el único productor de estos
    /// ficheros es `PcapWriter`, así que otra `magic` u otro link-type significan que el fichero no es
    /// el que se cree — y no que haya que interpretarlo con más cuidado.
    public static func globalHeader(parsing data: Data) throws -> GlobalHeader {
        guard data.count >= globalHeaderSize else {
            throw FormatError.shortHeader(expected: globalHeaderSize, actual: data.count)
        }
        let magicRead = data.littleEndianUInt32(atByte: 0)
        guard magicRead == magic else { throw FormatError.unknownMagic(magicRead) }

        let linkType = data.littleEndianUInt32(atByte: 20)
        guard linkType == linktypeRaw else { throw FormatError.unsupportedLinkType(linkType) }

        return GlobalHeader(snaplen: data.littleEndianUInt32(atByte: 16), linkType: linkType)
    }

    /// Parsea la cabecera de un registro. **No** valida `inclLen` contra el `snaplen`: eso lo decide
    /// quien lee el fichero, que es el único que lo conoce y el que va a reservar la memoria.
    public static func recordHeader(parsing data: Data) throws -> RecordHeader {
        guard data.count >= recordHeaderSize else {
            throw FormatError.shortHeader(expected: recordHeaderSize, actual: data.count)
        }
        return RecordHeader(
            tsSec: data.littleEndianUInt32(atByte: 0),
            tsUsec: data.littleEndianUInt32(atByte: 4),
            inclLen: data.littleEndianUInt32(atByte: 8),
            origLen: data.littleEndianUInt32(atByte: 12)
        )
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }

    mutating func appendLittleEndian(_ value: Int32) {
        appendLittleEndian(UInt32(bitPattern: value))
    }

    /// Lee un `UInt32` little-endian contando desde el **principio de la porción**, no desde el índice
    /// absoluto: un `Data` que sale de un `subdata`/`prefix` conserva los índices del original, así que
    /// indexar con enteros crudos aquí leería fuera de sitio (o reventaría) sin previo aviso.
    func littleEndianUInt32(atByte offset: Int) -> UInt32 {
        let base = startIndex + offset
        return UInt32(self[base])
            | UInt32(self[base + 1]) << 8
            | UInt32(self[base + 2]) << 16
            | UInt32(self[base + 3]) << 24
    }
}
