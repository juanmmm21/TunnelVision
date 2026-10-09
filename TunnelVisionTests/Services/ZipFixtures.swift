import Foundation

/// Lector mínimo de zip para los tests: recorre el directorio central y saca cada fichero. El zip lo
/// escribe el sistema (`NSFileCoordinator`), así que lo que se comprueba no es su formato sino lo
/// que un evaluador encuentra al abrirlo: qué ficheros hay, con qué nombre y con qué bytes.
enum TestZipReader {

    struct Entry: Equatable {
        /// La ruta dentro del zip, con su carpeta.
        let path: String
        let data: Data

        var isDirectory: Bool { path.hasSuffix("/") }
    }

    enum ReaderError: Error, Equatable {
        case endOfCentralDirectoryNotFound
        case truncated
        case badSignature(at: Int)
        /// Zip64: no hace falta para lo que estos tests escriben.
        case unsupportedSize
        case unsupportedMethod(UInt16)
        case inflateFailed(path: String)
        case lengthMismatch(path: String)
    }

    private static let endOfCentralDirectory: UInt32 = 0x0605_4B50
    private static let centralHeader: UInt32 = 0x0201_4B50
    private static let localHeader: UInt32 = 0x0403_4B50

    static func read(_ url: URL) throws -> [Entry] {
        let bytes = [UInt8](try Data(contentsOf: url))
        guard bytes.count >= 22 else { throw ReaderError.truncated }

        // El registro de fin está al final, tras un comentario de longitud variable: se busca
        // hacia atrás.
        var end = bytes.count - 22
        while end >= 0, u32(bytes, end) != endOfCentralDirectory { end -= 1 }
        guard end >= 0 else { throw ReaderError.endOfCentralDirectoryNotFound }

        let count = Int(u16(bytes, end + 10))
        let directoryOffset = u32(bytes, end + 16)
        guard count != 0xFFFF, directoryOffset != 0xFFFF_FFFF else { throw ReaderError.unsupportedSize }

        var entries: [Entry] = []
        var cursor = Int(directoryOffset)
        for _ in 0..<count {
            guard cursor + 46 <= bytes.count else { throw ReaderError.truncated }
            guard u32(bytes, cursor) == centralHeader else { throw ReaderError.badSignature(at: cursor) }
            let method = u16(bytes, cursor + 10)
            let compressedSize = u32(bytes, cursor + 20)
            let size = u32(bytes, cursor + 24)
            let nameLength = Int(u16(bytes, cursor + 28))
            let extraLength = Int(u16(bytes, cursor + 30))
            let commentLength = Int(u16(bytes, cursor + 32))
            let localOffset = u32(bytes, cursor + 42)
            guard compressedSize != 0xFFFF_FFFF, size != 0xFFFF_FFFF, localOffset != 0xFFFF_FFFF else {
                throw ReaderError.unsupportedSize
            }
            guard cursor + 46 + nameLength <= bytes.count else { throw ReaderError.truncated }
            let path = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)

            // Los tamaños se leen del directorio central: la cabecera local puede llevarlos a cero
            // y darlos después de los datos.
            let local = Int(localOffset)
            guard local + 30 <= bytes.count else { throw ReaderError.truncated }
            guard u32(bytes, local) == localHeader else { throw ReaderError.badSignature(at: local) }
            let start = local + 30 + Int(u16(bytes, local + 26)) + Int(u16(bytes, local + 28))
            guard start + Int(compressedSize) <= bytes.count else { throw ReaderError.truncated }
            let stored = Data(bytes[start..<(start + Int(compressedSize))])

            let data: Data
            switch method {
            case 0:
                data = stored
            case 8:
                // `.zlib` en Foundation es DEFLATE sin cabecera (RFC 1951), que es lo que guarda un zip.
                guard let inflated = try? (stored as NSData).decompressed(using: .zlib) as Data else {
                    throw ReaderError.inflateFailed(path: path)
                }
                data = inflated
            default:
                throw ReaderError.unsupportedMethod(method)
            }
            guard data.count == Int(size) else { throw ReaderError.lengthMismatch(path: path) }

            entries.append(Entry(path: path, data: data))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(u16(bytes, offset)) | UInt32(u16(bytes, offset + 2)) << 16
    }
}
