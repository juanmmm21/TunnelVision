import Foundation

/// Constantes y serialización del formato en el que se guarda el **contenido descifrado** de un flujo
/// inspeccionado, en los dos sentidos: escribirlo y leerlo.
///
/// Es un formato propio y no un `.pcap`: lo que sale de una terminación TLS no son datagramas IP sino
/// trozos de un stream ya reensamblado y descifrado, así que meterlos en un fichero cuyo link-layer
/// dice `LINKTYPE_RAW` sería mentir sobre cada byte (`docs/spec/pcap.md` acota `incl_len` contra el
/// `snaplen` y lee cada registro como un paquete). Los `.pcap` siguen guardando lo que viajó por el
/// cable —cifrado— y estos ficheros guardan lo que había dentro.
///
/// ## Un fichero, muchas conversaciones
///
/// Los registros de distintos flujos se **intercalan**, porque el escritor es uno solo y va en
/// streaming (el presupuesto de memoria de la extensión prohíbe agrupar por flujo en RAM). Por eso
/// cada registro lleva su `stream`: es lo único que dice a qué conversación pertenece cuando se lee el
/// fichero de corrido, sin la base de datos delante. No es la fila del historial —esa no existe
/// todavía cuando se escribe el byte, la asigna el volcado por lotes—, sino un identificador de sesión
/// que el índice guarda al lado de la localización.
///
/// ## Todo little-endian y explícito
///
/// Como en `PcapFormat`: nada depende del endianness del host, así que la salida es determinista
/// byte a byte y afirmable en un test. Y por lo mismo que aquel, el formato vive en `Shared` y no en
/// la extensión: lo escribe la extensión y lo **lee la app** para enseñar la mitad descifrada del Flow
/// Inspector, así que escribir y leer tienen que ser una sola verdad.
public enum PlaintextFormat {

    /// `TVPT` en ASCII: TunnelVision PlainText.
    public static let magic: UInt32 = 0x5456_5054
    /// `TVPR` en ASCII: la cabecera de un registro. Existe para que un offset guardado se pueda
    /// **validar** antes de leer nada: sin él, un offset desfasado daría bytes de otra conversación
    /// interpretados como los de esta, que es justo lo que la pareja fichero+offset existe para
    /// impedir (la misma lección que la pantalla de un paquete aprendió con `orig_len`).
    public static let recordMagic: UInt32 = 0x5456_5052

    public static let versionMajor: UInt16 = 1
    public static let versionMinor: UInt16 = 0

    public static let globalHeaderSize = 16
    public static let recordHeaderSize = 32

    // MARK: - Escritura

    /// Cabecera global (16 bytes), escrita una vez al abrir cada fichero.
    ///
    /// `maxRecordBytes` es el equivalente del `snaplen` del `.pcap` y está aquí por la misma razón:
    /// es el tope con el que un lector acota una lectura **antes** de reservar memoria. Va en el
    /// fichero y no en el registro, así que cambiarlo obliga a rotar.
    public static func globalHeader(maxRecordBytes: UInt32) -> Data {
        var data = Data(capacity: globalHeaderSize)
        data.appendLE(magic)
        data.appendLE(versionMajor)
        data.appendLE(versionMinor)
        data.appendLE(maxRecordBytes)
        data.appendLE(UInt32(0))   // reservado: crecer sin mover los campos que ya existen
        return data
    }

    /// Cabecera de registro (32 bytes), antes de los `storedLength` bytes de contenido.
    ///
    /// - Parameters:
    ///   - stream: la conversación a la que pertenece el trozo.
    ///   - timestamp: nanosegundos **desde el epoch**, no el sello monotónico crudo. Es la lección de
    ///     la migración v2 del store: un instante que no se puede fechar tras reiniciar el
    ///     dispositivo no vale para nada, y estos ficheros sobreviven a su sesión.
    ///   - storedLength: lo que se guarda de verdad detrás de la cabecera.
    ///   - originalLength: lo que medía el trozo. `storedLength < originalLength` es exactamente
    ///     "recortado", y es la única forma que tiene la pantalla de decir que no lo enseña entero.
    public static func recordHeader(
        stream: UInt64,
        timestamp: Int64,
        storedLength: UInt32,
        originalLength: UInt32,
        direction: Direction
    ) -> Data {
        var data = Data(capacity: recordHeaderSize)
        data.appendLE(recordMagic)
        data.appendLE(stream)
        data.appendLE(timestamp)
        data.appendLE(storedLength)
        data.appendLE(originalLength)
        data.append(direction.rawValue)
        data.append(contentsOf: [0, 0, 0])   // relleno hasta 32: la cabecera queda alineada a 8
        return data
    }

    // MARK: - Lectura

    /// Lo que hace falta de la cabecera global para leer un registro suelto. No lleva la versión
    /// porque quien la comprueba es el parser, que rechaza lo que no sabe leer en vez de devolverlo.
    public struct GlobalHeader: Sendable, Equatable {
        public let maxRecordBytes: UInt32

        public init(maxRecordBytes: UInt32) {
            self.maxRecordBytes = maxRecordBytes
        }
    }

    /// La cabecera de un registro: de qué conversación es, cuándo pasó, en qué sentido, cuántos bytes
    /// hay guardados y cuántos había.
    public struct RecordHeader: Sendable, Equatable {
        public let stream: UInt64
        public let timestamp: Int64
        public let storedLength: UInt32
        public let originalLength: UInt32
        public let direction: Direction

        public init(
            stream: UInt64,
            timestamp: Int64,
            storedLength: UInt32,
            originalLength: UInt32,
            direction: Direction
        ) {
            self.stream = stream
            self.timestamp = timestamp
            self.storedLength = storedLength
            self.originalLength = originalLength
            self.direction = direction
        }

        /// Que el trozo no se guardó entero (tope por registro o presupuesto del flujo agotado).
        public var isTruncated: Bool { storedLength < originalLength }
    }

    public enum FormatError: Error, Sendable, Equatable {
        /// Hay menos bytes de los que la cabecera necesita: el fichero se quedó a medias (la extensión
        /// pudo morir escribiendo) o el offset apunta más allá del final.
        case shortHeader(expected: Int, actual: Int)
        /// El fichero no empieza por nuestra `magic`: no lo escribimos nosotros.
        case unknownMagic(UInt32)
        /// Un fichero nuestro, pero de una versión que este código no sabe leer. Se dice en vez de
        /// interpretarlo a medias: un formato que crece solo puede hacerlo si el que no lo entiende
        /// se aparta.
        case unsupportedVersion(major: UInt16, minor: UInt16)
        /// El offset no señala el principio de un registro. Es el fallo que la `recordMagic` existe
        /// para convertir en una respuesta clara en vez de en bytes de otra conversación.
        case notARecord(UInt32)
        /// El sentido guardado no es ninguno de los dos. Un fichero corrupto, o de otro productor.
        case unknownDirection(UInt8)
    }

    /// Parsea la cabecera global de un fichero de contenido descifrado.
    ///
    /// Rechaza lo que no escribimos nosotros en vez de intentar adaptarse, igual que `PcapFormat`: el
    /// único productor es `PlaintextWriter`.
    public static func globalHeader(parsing data: Data) throws -> GlobalHeader {
        guard data.count >= globalHeaderSize else {
            throw FormatError.shortHeader(expected: globalHeaderSize, actual: data.count)
        }
        let magicRead = data.leUInt32(atByte: 0)
        guard magicRead == magic else { throw FormatError.unknownMagic(magicRead) }

        let major = data.leUInt16(atByte: 4)
        let minor = data.leUInt16(atByte: 6)
        // Solo el mayor decide: un menor distinto es, por definición, un cambio que no rompe la
        // lectura de lo que ya existía.
        guard major == versionMajor else {
            throw FormatError.unsupportedVersion(major: major, minor: minor)
        }

        return GlobalHeader(maxRecordBytes: data.leUInt32(atByte: 8))
    }

    /// Parsea la cabecera de un registro. **No** valida `storedLength` contra el `maxRecordBytes` del
    /// fichero: eso lo decide quien lee, que es el único que conoce la cabecera global y el que va a
    /// reservar la memoria (la misma división que en `PcapFormat`).
    public static func recordHeader(parsing data: Data) throws -> RecordHeader {
        guard data.count >= recordHeaderSize else {
            throw FormatError.shortHeader(expected: recordHeaderSize, actual: data.count)
        }
        let magicRead = data.leUInt32(atByte: 0)
        guard magicRead == recordMagic else { throw FormatError.notARecord(magicRead) }

        let rawDirection = data[data.startIndex + 28]
        guard let direction = Direction(rawValue: rawDirection) else {
            throw FormatError.unknownDirection(rawDirection)
        }

        return RecordHeader(
            stream: data.leUInt64(atByte: 4),
            timestamp: data.leInt64(atByte: 12),
            storedLength: data.leUInt32(atByte: 20),
            originalLength: data.leUInt32(atByte: 24),
            direction: direction
        )
    }
}

// Helpers little-endian propios (nombres distintos de los de `PcapFormat`, que son privados de su
// fichero): un formato serializa sus enteros y no se los pide prestados a otro.
private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendLE(_ value: UInt32) {
        for shift in stride(from: 0, through: 24, by: 8) {
            append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    mutating func appendLE(_ value: UInt64) {
        for shift in stride(from: 0, through: 56, by: 8) {
            append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    mutating func appendLE(_ value: Int64) {
        appendLE(UInt64(bitPattern: value))
    }

    /// Lee contando desde el **principio de la porción**, no desde el índice absoluto: un `Data` que
    /// sale de un `subdata`/`prefix` conserva los índices del original.
    func leUInt16(atByte offset: Int) -> UInt16 {
        let base = startIndex + offset
        return UInt16(self[base]) | UInt16(self[base + 1]) << 8
    }

    func leUInt32(atByte offset: Int) -> UInt32 {
        let base = startIndex + offset
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(self[base + index]) << UInt32(index * 8)
        }
        return value
    }

    func leUInt64(atByte offset: Int) -> UInt64 {
        let base = startIndex + offset
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(self[base + index]) << UInt64(index * 8)
        }
        return value
    }

    func leInt64(atByte offset: Int) -> Int64 {
        Int64(bitPattern: leUInt64(atByte: offset))
    }
}
