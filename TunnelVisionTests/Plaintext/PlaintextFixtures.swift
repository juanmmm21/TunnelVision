import Foundation

/// Lector mínimo de ficheros de contenido descifrado (`.tvpt`) para los tests. Decodifica en
/// little-endian la cabecera global y cada registro **sin usar `PlaintextFormat`**, para que el
/// round-trip afirme el formato de verdad y no la simetría de un parser consigo mismo — el mismo
/// papel que hace `TestPcapReader` con las capturas.
enum TestPlaintextReader {

    struct Decoded: Equatable {
        struct Record: Equatable {
            let magic: UInt32
            let stream: UInt64
            let timestamp: Int64
            let storedLength: UInt32
            let originalLength: UInt32
            let direction: UInt8
            let data: Data
        }

        let magic: UInt32
        let versionMajor: UInt16
        let versionMinor: UInt16
        let maxRecordBytes: UInt32
        let records: [Record]
    }

    enum ReaderError: Error, Equatable {
        case truncated
    }

    static func read(_ url: URL) throws -> Decoded {
        let bytes = [UInt8](try Data(contentsOf: url))
        guard bytes.count >= 16 else { throw ReaderError.truncated }

        var records: [Decoded.Record] = []
        var offset = 16
        while offset + 32 <= bytes.count {
            let storedLength = u32(bytes, offset + 20)
            let end = offset + 32 + Int(storedLength)
            guard end <= bytes.count else { throw ReaderError.truncated }
            records.append(
                .init(
                    magic: u32(bytes, offset),
                    stream: u64(bytes, offset + 4),
                    timestamp: Int64(bitPattern: u64(bytes, offset + 12)),
                    storedLength: storedLength,
                    originalLength: u32(bytes, offset + 24),
                    direction: bytes[offset + 28],
                    data: Data(bytes[(offset + 32)..<end])
                )
            )
            offset = end
        }

        return Decoded(
            magic: u32(bytes, 0),
            versionMajor: u16(bytes, 4),
            versionMinor: u16(bytes, 6),
            maxRecordBytes: u32(bytes, 8),
            records: records
        )
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(bytes[offset + index]) << UInt32(index * 8)
        }
        return value
    }

    private static func u64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(bytes[offset + index]) << UInt64(index * 8)
        }
        return value
    }
}
