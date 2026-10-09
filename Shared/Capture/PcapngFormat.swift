import Foundation

/// Serialización del formato pcapng, solo en el sentido de escribirlo y solo los tres bloques que
/// hacen falta: la cabecera de sección, la descripción de **una** interfaz y el paquete.
///
/// Existe por una cosa que el pcap clásico no puede llevar: **opciones por paquete**. La captura
/// de un paquete de evidencia (`docs/spec/audit.md` § *The capture*) dice de cada paquete a qué
/// flujo pertenece y qué hallazgos prueba ese flujo, y lo dice en un comentario que Wireshark
/// enseña y deja filtrar (`frame.comment`), y en qué sentido viajó. Lo que escribe la extensión
/// mientras captura sigue siendo pcap clásico (`PcapFormat`): allí no hay nada que anotar todavía.
///
/// Todo va en little-endian, y lo dice la propia cabecera de sección con su marca de orden de
/// bytes. Cada bloque es `tipo · longitud · cuerpo · longitud`, con el cuerpo alineado a 32 bits.
public enum PcapngFormat {

    public static let sectionHeaderType: UInt32 = 0x0A0D_0D0A
    public static let interfaceDescriptionType: UInt32 = 0x0000_0001
    public static let enhancedPacketType: UInt32 = 0x0000_0006
    public static let byteOrderMagic: UInt32 = 0x1A2B_3C4D
    public static let versionMajor: UInt16 = 1
    public static let versionMinor: UInt16 = 0

    /// Los timestamps de los paquetes van en microsegundos (10⁻⁶), que es lo que guarda el pcap
    /// clásico del que salen: escribir más resolución sería inventarla.
    public static let timestampResolutionExponent: UInt8 = 6

    /// Códigos de opción. `comment` vale en cualquier bloque; los demás son de su bloque.
    enum OptionCode {
        static let endOfOptions: UInt16 = 0
        static let comment: UInt16 = 1
        static let userApplication: UInt16 = 4      // shb_userappl
        static let timestampResolution: UInt16 = 9  // if_tsresol
        static let packetFlags: UInt16 = 2          // epb_flags
    }

    public enum FormatError: Error, Sendable, Equatable {
        /// El valor de una opción no cabe en los 16 bits de su longitud.
        case optionTooLong(code: UInt16, byteCount: Int)
        /// El paquete no cabe en los 32 bits de la longitud de su bloque.
        case packetTooLong(byteCount: Int)
    }

    /// Cabecera de sección: lo primero del fichero.
    ///
    /// - Parameter application: quién escribió el fichero (`shb_userappl`), o `nil` para no decirlo.
    public static func sectionHeader(application: String?) throws -> Data {
        var body = Data()
        body.appendLittleEndian(byteOrderMagic)
        body.appendLittleEndian(versionMajor)
        body.appendLittleEndian(versionMinor)
        // Longitud de la sección «sin especificar» (-1): se escribe en streaming y no se vuelve
        // atrás a rellenarla.
        body.appendLittleEndian(UInt64.max)

        var options = Data()
        if let application {
            try options.appendOption(OptionCode.userApplication, Data(application.utf8))
        }
        body.appendOptions(options)
        return block(sectionHeaderType, body: body)
    }

    /// Descripción de la interfaz a la que pertenecen todos los paquetes: datagramas IP desnudos
    /// (`LINKTYPE_RAW`), como en `PcapFormat`.
    ///
    /// - Parameter snaplen: el mayor número de bytes guardado por paquete; 0 es «sin límite».
    public static func interfaceDescription(snaplen: UInt32) throws -> Data {
        var body = Data()
        body.appendLittleEndian(UInt16(PcapFormat.linktypeRaw))
        body.appendLittleEndian(UInt16(0))
        body.appendLittleEndian(snaplen)

        var options = Data()
        try options.appendOption(OptionCode.timestampResolution, Data([timestampResolutionExponent]))
        body.appendOptions(options)
        return block(interfaceDescriptionType, body: body)
    }

    /// Un paquete de la interfaz 0, con su sentido y su comentario si los hay.
    ///
    /// - Parameter timestampMicroseconds: microsegundos desde el epoch.
    /// - Parameter originalLength: lo que medía el paquete antes de recortarlo a `snaplen`.
    /// - Parameter direction: `nil` deja el paquete sin `epb_flags`: no se sabe.
    public static func enhancedPacket(
        timestampMicroseconds: UInt64,
        originalLength: UInt32,
        bytes: Data,
        direction: Direction?,
        comment: String?
    ) throws -> Data {
        guard let capturedLength = UInt32(exactly: bytes.count) else {
            throw FormatError.packetTooLong(byteCount: bytes.count)
        }
        var body = Data(capacity: 20 + bytes.count + 16 + (comment?.utf8.count ?? 0))
        body.appendLittleEndian(UInt32(0))
        body.appendLittleEndian(UInt32(truncatingIfNeeded: timestampMicroseconds >> 32))
        body.appendLittleEndian(UInt32(truncatingIfNeeded: timestampMicroseconds))
        body.appendLittleEndian(capturedLength)
        body.appendLittleEndian(originalLength)
        body.append(bytes)
        body.padToFourBytes()

        var options = Data()
        if let comment {
            try options.appendOption(OptionCode.comment, Data(comment.utf8))
        }
        if let direction {
            var flags = Data()
            flags.appendLittleEndian(packetFlags(for: direction))
            try options.appendOption(OptionCode.packetFlags, flags)
        }
        body.appendOptions(options)
        return block(enhancedPacketType, body: body)
    }

    /// Los dos bits bajos de `epb_flags`: 01 es entrante y 10 saliente, vistos desde la interfaz
    /// que capturó — aquí, el dispositivo.
    static func packetFlags(for direction: Direction) -> UInt32 {
        switch direction {
        case .inbound: return 0b01
        case .outbound: return 0b10
        }
    }

    private static func block(_ type: UInt32, body: Data) -> Data {
        // Tipo, longitud y longitud otra vez: doce bytes alrededor de un cuerpo ya alineado.
        let totalLength = UInt32(body.count + 12)
        var data = Data(capacity: Int(totalLength))
        data.appendLittleEndian(type)
        data.appendLittleEndian(totalLength)
        data.append(body)
        data.appendLittleEndian(totalLength)
        return data
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        appendLittleEndian(UInt16(truncatingIfNeeded: value))
        appendLittleEndian(UInt16(truncatingIfNeeded: value >> 16))
    }

    mutating func appendLittleEndian(_ value: UInt64) {
        appendLittleEndian(UInt32(truncatingIfNeeded: value))
        appendLittleEndian(UInt32(truncatingIfNeeded: value >> 32))
    }

    mutating func padToFourBytes() {
        let remainder = count % 4
        if remainder != 0 {
            append(contentsOf: [UInt8](repeating: 0, count: 4 - remainder))
        }
    }

    /// Una opción: código, longitud **sin** el relleno y valor alineado a 32 bits.
    mutating func appendOption(_ code: UInt16, _ value: Data) throws {
        guard let length = UInt16(exactly: value.count) else {
            throw PcapngFormat.FormatError.optionTooLong(code: code, byteCount: value.count)
        }
        appendLittleEndian(code)
        appendLittleEndian(length)
        append(value)
        padToFourBytes()
    }

    /// Cierra una lista de opciones con `opt_endofopt`. Sin opciones no se escribe nada: la lista
    /// es opcional entera, y un final sin principio solo ocuparía cuatro bytes en cada paquete.
    mutating func appendOptions(_ options: Data) {
        guard !options.isEmpty else { return }
        append(options)
        appendLittleEndian(PcapngFormat.OptionCode.endOfOptions)
        appendLittleEndian(UInt16(0))
    }
}
