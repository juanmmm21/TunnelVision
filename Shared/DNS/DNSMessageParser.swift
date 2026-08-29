import Foundation

/// Parser puro y síncrono de mensajes de DNS (RFC 1035 § 4), hermano de `PacketParser`: recibe el
/// payload de un datagrama UDP del puerto 53 y devuelve lo que dice.
///
/// **Está acotado por todos lados a propósito.** Un mensaje de DNS llega de la red, así que sus
/// campos de longitud son datos de un tercero: los nombres se comprimen con punteros que pueden
/// apuntar a cualquier sitio del propio mensaje, y un puntero a sí mismo es un bucle infinito escrito
/// en dos bytes. Aquí un puntero **solo puede ir hacia atrás** —lo que hace imposible el ciclo por
/// construcción, no por contador—, la cadena de saltos tiene tope, el nombre tiene los 255 bytes del
/// formato y cada lectura se comprueba contra el buffer real antes de tocarlo.
///
/// Se lee **hasta el final de la sección de respuestas y se para**: la de autoridad y la adicional no
/// las enseña nadie (`DNSMessage`), así que recorrerlas sería superficie de fallo a cambio de nada.
public enum DNSMessageParser {

    /// Los doce bytes de la cabecera.
    private static let headerLength = 12

    /// El máximo del formato para un nombre entero, contando el byte de longitud de cada etiqueta.
    private static let maxNameLength = 255

    /// Tope de saltos de compresión. Con la regla de "solo hacia atrás" ya no puede haber ciclos, así
    /// que esto solo acota el trabajo de un mensaje que encadene punteros para hacernos caminar.
    private static let maxPointerJumps = 32

    /// Lee un mensaje. `message` son los bytes del payload UDP, sin la cabecera de transporte.
    public static func parse(_ message: Data) throws -> DNSMessage {
        // Como en `PacketParser`: `withUnsafeBytes` normaliza a un buffer 0-based aunque llegue un
        // slice, así que todos los offsets de dentro —y los punteros de compresión, que son offsets
        // desde el principio del mensaje— son directos.
        try message.withUnsafeBytes { raw in
            try parse(raw)
        }
    }

    private static func parse(_ raw: UnsafeRawBufferPointer) throws -> DNSMessage {
        guard raw.count >= headerLength else {
            throw DNSParseError.tooShort(expected: headerLength, got: raw.count)
        }

        let flags = readU16BE(raw, 2)
        let questionCount = Int(readU16BE(raw, 4))
        let answerCount = Int(readU16BE(raw, 6))

        var cursor = headerLength
        var questions: [DNSQuestion] = []
        for _ in 0..<questionCount {
            let (question, next) = try readQuestion(raw, at: cursor)
            questions.append(question)
            cursor = next
        }

        var answers: [DNSResourceRecord] = []
        for _ in 0..<answerCount {
            let (record, next) = try readRecord(raw, at: cursor)
            answers.append(record)
            cursor = next
        }

        return DNSMessage(
            id: readU16BE(raw, 0),
            isResponse: flags & 0x8000 != 0,
            opcode: UInt8((flags >> 11) & 0x0f),
            isAuthoritative: flags & 0x0400 != 0,
            isTruncated: flags & 0x0200 != 0,
            recursionDesired: flags & 0x0100 != 0,
            recursionAvailable: flags & 0x0080 != 0,
            responseCode: DNSResponseCode(rawValue: UInt8(flags & 0x000f)),
            questions: questions,
            answers: answers
        )
    }

    // MARK: - Secciones

    private static func readQuestion(
        _ raw: UnsafeRawBufferPointer, at offset: Int
    ) throws -> (DNSQuestion, Int) {
        let (name, afterName) = try readName(raw, at: offset)
        guard afterName + 4 <= raw.count else { throw DNSParseError.truncated }

        let question = DNSQuestion(
            name: name,
            type: DNSRecordType(rawValue: readU16BE(raw, afterName)),
            recordClass: readU16BE(raw, afterName + 2)
        )
        return (question, afterName + 4)
    }

    private static func readRecord(
        _ raw: UnsafeRawBufferPointer, at offset: Int
    ) throws -> (DNSResourceRecord, Int) {
        let (name, afterName) = try readName(raw, at: offset)
        guard afterName + 10 <= raw.count else { throw DNSParseError.truncated }

        let type = DNSRecordType(rawValue: readU16BE(raw, afterName))
        let dataLength = Int(readU16BE(raw, afterName + 8))
        let dataStart = afterName + 10
        let dataEnd = dataStart + dataLength
        guard dataEnd <= raw.count else { throw DNSParseError.truncated }

        let record = DNSResourceRecord(
            name: name,
            type: type,
            recordClass: readU16BE(raw, afterName + 2),
            timeToLive: readU32BE(raw, afterName + 4),
            data: try recordData(raw, type: type, start: dataStart, length: dataLength)
        )
        // Se avanza por lo que **declara** el registro y no por lo que se haya leído de él: es lo que
        // permite saltarse entero un tipo que no se desmenuza y seguir leyendo el siguiente.
        return (record, dataEnd)
    }

    /// El contenido de un registro. Un tipo que no se conoce —o uno que se conoce con una longitud que
    /// no es la suya— se queda en `opaque` en vez de lanzar: no poder desmenuzar un registro no
    /// invalida el mensaje que lo trae.
    private static func recordData(
        _ raw: UnsafeRawBufferPointer, type: DNSRecordType, start: Int, length: Int
    ) throws -> DNSRecordData {
        switch type {
        case .a where length == 4:
            return .address(IPAddress(version: .v4, bytes: [UInt8](raw[start..<(start + 4)])))
        case .aaaa where length == 16:
            return .address(IPAddress(version: .v6, bytes: [UInt8](raw[start..<(start + 16)])))
        case .cname, .ptr, .ns:
            // El nombre de dentro se comprime contra el mensaje entero, así que puede apuntar fuera de
            // estos `length` bytes y sigue siendo legal. Lo que no se le consiente es salirse del
            // buffer, que es lo que `readName` ya comprueba.
            return .name(try readName(raw, at: start).name)
        default:
            return .opaque(byteCount: length)
        }
    }

    // MARK: - Nombres

    /// Lee un nombre desde `offset` y devuelve, además, **por dónde sigue el mensaje**, que no es lo
    /// mismo que dónde acabó de leer: al seguir un puntero de compresión el nombre continúa en otro
    /// sitio pero el flujo se reanuda justo detrás del puntero.
    private static func readName(
        _ raw: UnsafeRawBufferPointer, at offset: Int
    ) throws -> (name: String, next: Int) {
        var labels: [String] = []
        var cursor = offset
        var next: Int?
        var jumps = 0
        var nameLength = 0

        while true {
            guard cursor < raw.count else { throw DNSParseError.truncated }
            let marker = raw[cursor]

            switch marker & 0xc0 {
            case 0xc0:
                guard cursor + 2 <= raw.count else { throw DNSParseError.truncated }
                let target = Int(UInt16(marker & 0x3f) << 8 | UInt16(raw[cursor + 1]))
                // Solo hacia atrás. Es lo que hace imposible el ciclo: cada salto aterriza
                // estrictamente antes del anterior, así que la cadena no puede volver sobre sí misma.
                guard target < cursor else { throw DNSParseError.malformedName }
                jumps += 1
                guard jumps <= maxPointerJumps else { throw DNSParseError.malformedName }
                if next == nil { next = cursor + 2 }
                cursor = target

            case 0x00:
                let length = Int(marker)
                if length == 0 {
                    if next == nil { next = cursor + 1 }
                    // Un nombre sin etiquetas es la raíz, y se escribe como el punto que la nombra: un
                    // hueco en pantalla se leería como un dato que falta.
                    return (labels.isEmpty ? "." : labels.joined(separator: "."), next!)
                }
                let end = cursor + 1 + length
                guard end <= raw.count else { throw DNSParseError.truncated }
                nameLength += length + 1
                guard nameLength <= maxNameLength else { throw DNSParseError.malformedName }
                labels.append(presentable(raw, from: cursor + 1, count: length))
                cursor = end

            default:
                // 0x40 y 0x80 están reservados desde 1987 y no significan nada.
                throw DNSParseError.malformedName
            }
        }
    }

    /// Una etiqueta pasada a texto para enseñarla.
    ///
    /// **Los bytes de una etiqueta son bytes, no texto**: el formato no obliga a que sean ASCII
    /// imprimible, y un nombre viene de un tercero. Los que no lo son se escapan en decimal como
    /// manda RFC 1035 § 5.1, y con ellos el punto y la barra —que en pantalla se confundirían con el
    /// separador de etiquetas y con el propio escape—. Sin esto, un nombre con un byte de control
    /// podría borrar la línea en la que se pinta o hacerse pasar por otro.
    ///
    /// Lo que **no** se hace es traducir un nombre IDN (`xn--…`) a su forma Unicode: eso es
    /// exactamente lo que convierte dos dominios distintos en dos que se ven iguales, y esta pantalla
    /// existe para que el usuario sepa con quién habló su dispositivo.
    private static func presentable(_ raw: UnsafeRawBufferPointer, from start: Int, count: Int) -> String {
        var text = ""
        text.reserveCapacity(count)
        for index in start..<(start + count) {
            let byte = raw[index]
            let isPrintable = byte >= 0x21 && byte <= 0x7e
            if isPrintable && byte != UInt8(ascii: ".") && byte != UInt8(ascii: "\\") {
                text.append(Character(UnicodeScalar(byte)))
            } else {
                text += String(format: "\\%03d", Int(byte))
            }
        }
        return text
    }

    // MARK: - Utilidades

    @inline(__always)
    private static func readU16BE(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt16 {
        (UInt16(raw[offset]) << 8) | UInt16(raw[offset + 1])
    }

    @inline(__always)
    private static func readU32BE(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        (UInt32(raw[offset]) << 24)
            | (UInt32(raw[offset + 1]) << 16)
            | (UInt32(raw[offset + 2]) << 8)
            | UInt32(raw[offset + 3])
    }
}
