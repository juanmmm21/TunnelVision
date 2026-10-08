import Foundation

/// Lector ASN.1 DER mínimo, con control de límites: la contraparte de `DER` para **leer** lo que
/// manda un servidor.
///
/// Lee TLVs de etiqueta de un byte y longitud definida, que es todo lo que usa un certificado
/// X.509. Lo que no entiende —etiquetas de número alto, longitud indefinida, una longitud que
/// declara más de lo que hay— lo contesta con `nil` y no avanza a ciegas: los bytes los elige el
/// otro extremo.
struct DERReader {

    struct Element {
        let tag: UInt8
        let content: ArraySlice<UInt8>
        /// El TLV entero, con su etiqueta y su longitud.
        let raw: ArraySlice<UInt8>
    }

    enum Tag {
        static let integer: UInt8 = 0x02
        static let objectIdentifier: UInt8 = 0x06
        static let utf8String: UInt8 = 0x0C
        static let numericString: UInt8 = 0x12
        static let printableString: UInt8 = 0x13
        static let teletexString: UInt8 = 0x14
        static let ia5String: UInt8 = 0x16
        static let utcTime: UInt8 = 0x17
        static let generalizedTime: UInt8 = 0x18
        static let visibleString: UInt8 = 0x1A
        static let universalString: UInt8 = 0x1C
        static let bmpString: UInt8 = 0x1E
        static let sequence: UInt8 = 0x30
        static let set: UInt8 = 0x31
        /// `[0]` explícito: la versión de un TBSCertificate.
        static let explicitZero: UInt8 = 0xA0
    }

    /// Los cinco bits bajos a uno anuncian una etiqueta de varios bytes.
    private static let highTagNumberMask: UInt8 = 0x1F
    /// Una longitud en forma larga de más bytes que estos no cabe en nada que vayamos a leer.
    private static let maxLengthBytes = 4

    private let bytes: ArraySlice<UInt8>
    private var index: Int

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        self.index = bytes.startIndex
    }

    var isAtEnd: Bool { index >= bytes.endIndex }

    /// La etiqueta del siguiente elemento, sin consumirlo.
    var nextTag: UInt8? { isAtEnd ? nil : bytes[index] }

    /// Lee el siguiente TLV. `nil` deja el cursor donde estaba.
    mutating func element() -> Element? {
        var cursor = index
        guard cursor < bytes.endIndex else { return nil }
        let tag = bytes[cursor]
        guard tag & Self.highTagNumberMask != Self.highTagNumberMask else { return nil }
        cursor += 1

        guard cursor < bytes.endIndex else { return nil }
        let first = bytes[cursor]
        cursor += 1

        var length = 0
        if first & 0x80 == 0 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7F)
            // `count == 0` es la longitud indefinida de BER, que DER no admite.
            guard count > 0, count <= Self.maxLengthBytes, bytes.endIndex - cursor >= count else { return nil }
            for _ in 0..<count {
                length = length << 8 | Int(bytes[cursor])
                cursor += 1
            }
        }

        guard bytes.endIndex - cursor >= length else { return nil }
        let element = Element(
            tag: tag,
            content: bytes[cursor..<(cursor + length)],
            raw: bytes[index..<(cursor + length)]
        )
        index = cursor + length
        return element
    }

    /// Lee el siguiente TLV solo si lleva esa etiqueta, y devuelve su contenido.
    mutating func content(tag: UInt8) -> ArraySlice<UInt8>? {
        guard nextTag == tag else { return nil }
        return element()?.content
    }
}
