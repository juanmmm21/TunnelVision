import Foundation

/// Cursor con control de límites sobre los bytes de un mensaje de handshake TLS.
///
/// TLS codifica casi todo como vectores con su longitud delante, así que sus parsers son
/// literalmente "salta un vector, lee el siguiente". Tenerlo en un tipo evita repetir el mismo
/// control de límites en cada campo, que es justo donde viven los desbordamientos de un parser
/// de red. Lo comparten los escáneres de handshake (`ClientHelloScanner`,
/// `ServerHelloScanner` y `ServerCertificateScanner`): dos copias del mismo control de límites serían dos sitios donde
/// equivocarse igual.
struct TLSByteReader {
    /// Anchura del prefijo de longitud de un vector TLS.
    enum LengthPrefix {
        case oneByte
        case twoBytes
        /// El de la lista de certificados de un mensaje `Certificate` y el de cada uno de ellos.
        case threeBytes
    }

    private let bytes: ArraySlice<UInt8>
    private var index: Int

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        self.index = bytes.startIndex
    }

    var isAtEnd: Bool { index >= bytes.endIndex }

    private var remaining: Int { bytes.endIndex - index }

    mutating func uint8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { index += 1 }
        return bytes[index]
    }

    mutating func uint16() -> UInt16? {
        guard let high = uint8(), let low = uint8() else { return nil }
        return UInt16(high) << 8 | UInt16(low)
    }

    mutating func uint24() -> Int? {
        guard let high = uint8(), let low = uint16() else { return nil }
        return Int(high) << 16 | Int(low)
    }

    /// Lee `count` bytes tal cual, para los campos de tamaño fijo (el `random` de un hello).
    mutating func take(_ count: Int) -> ArraySlice<UInt8>? {
        guard count >= 0, remaining >= count else { return nil }
        defer { index += count }
        return bytes[index..<(index + count)]
    }

    mutating func skip(_ count: Int) -> Bool {
        take(count) != nil
    }

    /// Lee un vector con su longitud delante y devuelve su contenido.
    mutating func vector(prefix: LengthPrefix) -> ArraySlice<UInt8>? {
        let length: Int
        switch prefix {
        case .oneByte:
            guard let value = uint8() else { return nil }
            length = Int(value)
        case .twoBytes:
            guard let value = uint16() else { return nil }
            length = Int(value)
        case .threeBytes:
            guard let value = uint24() else { return nil }
            length = value
        }
        return take(length)
    }

    mutating func skipVector(prefix: LengthPrefix) -> Bool {
        vector(prefix: prefix) != nil
    }
}
