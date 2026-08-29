import Foundation

/// Codificador ASN.1 DER mínimo: lo justo para serializar un certificado X.509 v3 a mano.
///
/// No se usa una librería de terceros (política de dependencias: solo GRDB) y `Security`/`CryptoKit`
/// **no** exponen en iOS ningún constructor de certificados — solo saben *leerlos*. Así que el TBS
/// del certificado se serializa aquí, byte a byte, y luego se firma. Cada helper devuelve un TLV
/// (tag + longitud + contenido) completo y ya anidable, para que el constructor de arriba componga
/// SEQUENCE/SET sin preocuparse de longitudes.
///
/// DER (no BER): longitud siempre en forma mínima, SET/SEQUENCE con longitud definida, sin
/// indefinidas. Solo cubre los tipos que el X.509 de este proyecto necesita; no pretende ser general.
enum DER {

    // MARK: - Etiquetas (tags) universales y de contexto

    private enum Tag {
        static let boolean: UInt8 = 0x01
        static let integer: UInt8 = 0x02
        static let bitString: UInt8 = 0x03
        static let octetString: UInt8 = 0x04
        static let null: UInt8 = 0x05
        static let objectIdentifier: UInt8 = 0x06
        static let utf8String: UInt8 = 0x0c
        static let printableString: UInt8 = 0x13
        static let ia5String: UInt8 = 0x16
        static let utcTime: UInt8 = 0x17
        static let generalizedTime: UInt8 = 0x18
        static let sequence: UInt8 = 0x30   // constructed
        static let set: UInt8 = 0x31        // constructed
    }

    /// Etiqueta de contexto `[n]`. `constructed` distingue un contenedor (SEQUENCE explícito envuelto)
    /// de un valor primitivo (p. ej. un `dNSName` en un SubjectAltName, que va sin tag interno).
    static func contextTag(_ number: UInt8, constructed: Bool) -> UInt8 {
        0x80 | (constructed ? 0x20 : 0x00) | (number & 0x1f)
    }

    // MARK: - TLV y longitud

    /// Envuelve `content` en un TLV con la etiqueta dada. Es la primitiva sobre la que se construye
    /// todo lo demás.
    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + length(content.count) + content
    }

    /// Longitud en codificación DER: forma corta (<128) en un byte; forma larga en `0x80 | n` seguido
    /// de los `n` bytes big-endian de la longitud, sin ceros a la izquierda.
    static func length(_ count: Int) -> [UInt8] {
        if count < 0x80 {
            return [UInt8(count)]
        }
        var value = count
        var bytes = [UInt8]()
        while value > 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    // MARK: - Tipos primitivos

    /// INTEGER a partir de la magnitud big-endian de un entero **no negativo**. Aplica las dos reglas
    /// de DER: se quitan los ceros a la izquierda redundantes (dejando al menos un byte) y, si el bit
    /// más alto del primer byte queda a uno, se antepone un `0x00` para que no se lea como negativo.
    static func integer(magnitude: [UInt8]) -> [UInt8] {
        var bytes = magnitude
        while bytes.count > 1 && bytes.first == 0x00 {
            bytes.removeFirst()
        }
        if bytes.isEmpty {
            bytes = [0x00]
        }
        if bytes[0] & 0x80 != 0 {
            bytes.insert(0x00, at: 0)
        }
        return tlv(Tag.integer, bytes)
    }

    /// INTEGER a partir de un valor pequeño no negativo (versión del certificado, pathLen...).
    static func integer(_ value: Int) -> [UInt8] {
        precondition(value >= 0, "DER.integer(_:) solo emite enteros no negativos")
        var magnitude = [UInt8]()
        var remaining = value
        repeat {
            magnitude.insert(UInt8(remaining & 0xff), at: 0)
            remaining >>= 8
        } while remaining > 0
        return integer(magnitude: magnitude)
    }

    static func boolean(_ value: Bool) -> [UInt8] {
        // DER fija el "true" como 0xFF (todos los bits a uno), no cualquier valor distinto de cero.
        tlv(Tag.boolean, [value ? 0xff : 0x00])
    }

    static func null() -> [UInt8] {
        tlv(Tag.null, [])
    }

    /// BIT STRING con cero bits sin usar (el caso de las claves y firmas: bytes enteros).
    static func bitString(_ content: [UInt8]) -> [UInt8] {
        tlv(Tag.bitString, [0x00] + content)
    }

    /// BIT STRING de banderas con codificación mínima (KeyUsage): se numeran los bits de más
    /// significativo a menos dentro de cada byte (bit 0 = 0x80 del primer byte), se recortan los
    /// bytes finales que queden a cero y se declara el número de bits sin usar del último byte.
    static func namedBitString(setBits: [Int]) -> [UInt8] {
        guard let highest = setBits.max() else {
            return tlv(Tag.bitString, [0x00])   // ninguna bandera: cadena vacía, 0 bits sin usar
        }
        var bytes = [UInt8](repeating: 0, count: highest / 8 + 1)
        for bit in setBits {
            bytes[bit / 8] |= 0x80 >> (bit % 8)
        }
        let unusedBits = 7 - (highest % 8)
        return tlv(Tag.bitString, [UInt8(unusedBits)] + bytes)
    }

    static func octetString(_ content: [UInt8]) -> [UInt8] {
        tlv(Tag.octetString, content)
    }

    static func utf8String(_ string: String) -> [UInt8] {
        tlv(Tag.utf8String, Array(string.utf8))
    }

    static func ia5String(_ string: String) -> [UInt8] {
        tlv(Tag.ia5String, Array(string.utf8))
    }

    static func printableString(_ string: String) -> [UInt8] {
        tlv(Tag.printableString, Array(string.utf8))
    }

    /// OBJECT IDENTIFIER a partir de su forma con puntos. Los dos primeros arcos se combinan en un
    /// byte (`40 * arco0 + arco1`); el resto se codifica en base 128 big-endian con el bit de
    /// continuación (0x80) en todos los bytes menos el último de cada arco.
    static func objectIdentifier(_ dotted: String) -> [UInt8] {
        let arcs = dotted.split(separator: ".").compactMap { UInt64($0) }
        precondition(arcs.count >= 2, "un OID tiene al menos dos arcos: \(dotted)")

        var content: [UInt8] = [UInt8(arcs[0] * 40 + arcs[1])]
        for arc in arcs.dropFirst(2) {
            content += base128(arc)
        }
        return tlv(Tag.objectIdentifier, content)
    }

    private static func base128(_ value: UInt64) -> [UInt8] {
        if value == 0 { return [0x00] }
        var groups = [UInt8]()
        var remaining = value
        while remaining > 0 {
            groups.insert(UInt8(remaining & 0x7f), at: 0)
            remaining >>= 7
        }
        // El bit de continuación va a uno en todos los grupos menos el último.
        for index in 0..<(groups.count - 1) {
            groups[index] |= 0x80
        }
        return groups
    }

    // MARK: - Tiempo (validez del certificado)

    /// Codifica un instante como `UTCTime` si el año cae en 1950–2049 (RFC 5280 obliga a esa forma en
    /// ese rango) y como `GeneralizedTime` en caso contrario. Siempre en UTC (`Z`), sin fracciones.
    static func time(_ date: Date) -> [UInt8] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = parts.year!

        func pad(_ value: Int, _ width: Int) -> String {
            String(format: "%0\(width)d", value)
        }
        let mmddhhmmss =
            pad(parts.month!, 2) + pad(parts.day!, 2)
            + pad(parts.hour!, 2) + pad(parts.minute!, 2) + pad(parts.second!, 2)

        if (1950...2049).contains(year) {
            let text = pad(year % 100, 2) + mmddhhmmss + "Z"
            return tlv(Tag.utcTime, Array(text.utf8))
        }
        let text = pad(year, 4) + mmddhhmmss + "Z"
        return tlv(Tag.generalizedTime, Array(text.utf8))
    }

    // MARK: - Contenedores

    static func sequence(_ items: [[UInt8]]) -> [UInt8] {
        tlv(Tag.sequence, items.flatMap { $0 })
    }

    static func set(_ items: [[UInt8]]) -> [UInt8] {
        tlv(Tag.set, items.flatMap { $0 })
    }

    /// Etiqueta explícita `[number]` (constructed): envuelve un TLV ya formado dentro de otro TLV de
    /// contexto. Es lo que pide X.509 para `version [0]` y `extensions [3]`.
    static func explicit(_ number: UInt8, _ content: [UInt8]) -> [UInt8] {
        tlv(contextTag(number, constructed: true), content)
    }

    /// Valor primitivo con etiqueta de contexto `[number]`: el contenido va crudo, sin tag interno.
    /// Lo usan el `keyIdentifier` de AuthorityKeyIdentifier `[0]` y los `GeneralName` del SAN.
    static func implicit(_ number: UInt8, _ content: [UInt8]) -> [UInt8] {
        tlv(contextTag(number, constructed: false), content)
    }
}
