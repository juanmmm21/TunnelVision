import Foundation

/// Lector mínimo de ficheros libpcap clásicos para los tests de M6. Decodifica en little-endian la
/// cabecera global y cada registro, para hacer round-trip contra `PcapWriter` sin depender de
/// herramientas externas (en CI se complementa con `tcpdump -r` cuando está disponible).
enum TestPcapReader {

    struct Decoded: Equatable {
        struct Record: Equatable {
            let tsSec: UInt32
            let tsUsec: UInt32
            let inclLen: UInt32
            let origLen: UInt32
            let data: Data
        }

        let magic: UInt32
        let versionMajor: UInt16
        let versionMinor: UInt16
        let thiszone: Int32
        let sigfigs: UInt32
        let snaplen: UInt32
        let network: UInt32
        let records: [Record]
    }

    enum ReaderError: Error, Equatable {
        case truncated
    }

    static func read(_ url: URL) throws -> Decoded {
        let bytes = [UInt8](try Data(contentsOf: url))
        guard bytes.count >= 24 else { throw ReaderError.truncated }

        let magic = u32(bytes, 0)
        let versionMajor = u16(bytes, 4)
        let versionMinor = u16(bytes, 6)
        let thiszone = Int32(bitPattern: u32(bytes, 8))
        let sigfigs = u32(bytes, 12)
        let snaplen = u32(bytes, 16)
        let network = u32(bytes, 20)

        var records: [Decoded.Record] = []
        var offset = 24
        while offset + 16 <= bytes.count {
            let tsSec = u32(bytes, offset)
            let tsUsec = u32(bytes, offset + 4)
            let inclLen = u32(bytes, offset + 8)
            let origLen = u32(bytes, offset + 12)
            offset += 16

            let end = offset + Int(inclLen)
            guard end <= bytes.count else { throw ReaderError.truncated }
            let data = Data(bytes[offset..<end])
            records.append(.init(tsSec: tsSec, tsUsec: tsUsec, inclLen: inclLen, origLen: origLen, data: data))
            offset = end
        }
        return Decoded(
            magic: magic,
            versionMajor: versionMajor,
            versionMinor: versionMinor,
            thiszone: thiszone,
            sigfigs: sigfigs,
            snaplen: snaplen,
            network: network,
            records: records
        )
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
