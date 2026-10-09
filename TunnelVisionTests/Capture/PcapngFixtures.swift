import Foundation

/// Lector mínimo de pcapng para los tests: recorre los bloques y decodifica los tres que escribe
/// `PcapngFormat`. No comparte código con él a propósito — si lo hiciera, un error de formato se
/// validaría a sí mismo —, y comprueba lo que un lector de verdad exige: que cada bloque esté
/// alineado a 32 bits y que su longitud final repita la inicial.
enum TestPcapngReader {

    struct Option: Equatable {
        let code: UInt16
        let value: Data
    }

    struct Section: Equatable {
        let byteOrderMagic: UInt32
        let versionMajor: UInt16
        let versionMinor: UInt16
        let sectionLength: UInt64
        let options: [Option]
    }

    struct Interface: Equatable {
        let linkType: UInt16
        let snaplen: UInt32
        let options: [Option]
    }

    struct Packet: Equatable {
        let interfaceID: UInt32
        let timestamp: UInt64
        let capturedLength: UInt32
        let originalLength: UInt32
        let data: Data
        let options: [Option]

        var comment: String? {
            options.first { $0.code == 1 }.flatMap { String(data: $0.value, encoding: .utf8) }
        }

        /// Los dos bits bajos de `epb_flags`: 1 entrante, 2 saliente.
        var directionBits: UInt32? {
            options.first { $0.code == 2 }.map { TestPcapngReader.u32([UInt8]($0.value), 0) & 0b11 }
        }
    }

    struct Decoded: Equatable {
        /// Los tipos de bloque en el orden del fichero.
        let blockTypes: [UInt32]
        let sections: [Section]
        let interfaces: [Interface]
        let packets: [Packet]
    }

    enum ReaderError: Error, Equatable {
        case truncated
        case misaligned(blockAt: Int)
        case trailingLengthMismatch(blockAt: Int)
        case unknownBlock(UInt32)
        case optionsNotTerminated(blockAt: Int)
    }

    static func read(_ url: URL) throws -> Decoded {
        try read(try Data(contentsOf: url))
    }

    static func read(_ data: Data) throws -> Decoded {
        let bytes = [UInt8](data)
        var types: [UInt32] = []
        var sections: [Section] = []
        var interfaces: [Interface] = []
        var packets: [Packet] = []

        var offset = 0
        while offset < bytes.count {
            guard offset + 12 <= bytes.count else { throw ReaderError.truncated }
            let type = u32(bytes, offset)
            let length = Int(u32(bytes, offset + 4))
            guard length % 4 == 0, length >= 12 else { throw ReaderError.misaligned(blockAt: offset) }
            guard offset + length <= bytes.count else { throw ReaderError.truncated }
            guard Int(u32(bytes, offset + length - 4)) == length else {
                throw ReaderError.trailingLengthMismatch(blockAt: offset)
            }
            let body = Array(bytes[(offset + 8)..<(offset + length - 4)])
            types.append(type)

            switch type {
            case 0x0A0D_0D0A:
                sections.append(Section(
                    byteOrderMagic: u32(body, 0),
                    versionMajor: u16(body, 4),
                    versionMinor: u16(body, 6),
                    sectionLength: UInt64(u32(body, 8)) | (UInt64(u32(body, 12)) << 32),
                    options: try options(body, from: 16, blockAt: offset)
                ))
            case 1:
                interfaces.append(Interface(
                    linkType: u16(body, 0),
                    snaplen: u32(body, 4),
                    options: try options(body, from: 8, blockAt: offset)
                ))
            case 6:
                let captured = Int(u32(body, 12))
                let padded = (captured + 3) / 4 * 4
                guard 20 + padded <= body.count else { throw ReaderError.truncated }
                packets.append(Packet(
                    interfaceID: u32(body, 0),
                    timestamp: (UInt64(u32(body, 4)) << 32) | UInt64(u32(body, 8)),
                    capturedLength: u32(body, 12),
                    originalLength: u32(body, 16),
                    data: Data(body[20..<(20 + captured)]),
                    options: try options(body, from: 20 + padded, blockAt: offset)
                ))
            default:
                throw ReaderError.unknownBlock(type)
            }
            offset += length
        }
        return Decoded(blockTypes: types, sections: sections, interfaces: interfaces, packets: packets)
    }

    /// Las opciones desde `start` hasta el final del cuerpo. Una lista, si existe, tiene que
    /// acabar en `opt_endofopt` justo donde acaba el cuerpo.
    private static func options(_ body: [UInt8], from start: Int, blockAt: Int) throws -> [Option] {
        var result: [Option] = []
        var offset = start
        guard offset < body.count else { return result }
        while offset + 4 <= body.count {
            let code = u16(body, offset)
            let length = Int(u16(body, offset + 2))
            offset += 4
            if code == 0 {
                guard length == 0, offset == body.count else {
                    throw ReaderError.optionsNotTerminated(blockAt: blockAt)
                }
                return result
            }
            guard offset + length <= body.count else { throw ReaderError.truncated }
            result.append(Option(code: code, value: Data(body[offset..<(offset + length)])))
            offset += (length + 3) / 4 * 4
        }
        throw ReaderError.optionsNotTerminated(blockAt: blockAt)
    }

    static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
