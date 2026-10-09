import XCTest
import Shared

/// Tests del lector de registros por offset, contra ficheros escritos por un `PcapWriter` real.
/// Las mismas reglas las ejercita `CaptureLibraryTests` por encima; aquí se afirma lo que el
/// recorte de una sesión añade: un fichero abierto una vez y muchos registros leídos de él, y
/// cada fallo con su caso.
final class PcapFileReaderTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pcap-file-reader-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func fileURL() throws -> URL {
        try XCTUnwrap(CaptureDirectory.url(forSequence: 0, in: tempDir))
    }

    private func assertThrows<T>(
        _ expression: @autoclosure () throws -> T,
        _ expected: PcapFileReader.ReadError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual(error as? PcapFileReader.ReadError, expected, file: file, line: line)
        }
    }

    func testOneOpenFileGivesEveryRecordByItsOffsetInAnyOrder() async throws {
        let writer = try PcapWriter(config: .init(directory: tempDir, snaplen: 64))
        var locations: [CaptureLocation] = []
        for index in 0..<4 {
            locations.append(try await writer.write(
                packet: Data(repeating: UInt8(index + 1), count: 10 + index),
                originalLength: 100 + index,
                timestamp: Int64(1_700_000_000 + index) * 1_000_000_000 + 250_000_000
            ))
        }
        await writer.close()

        let reader = try PcapFileReader(url: try fileURL())
        defer { reader.close() }

        XCTAssertEqual(reader.header, .init(snaplen: 64, linkType: 101))
        for index in [3, 0, 2, 1] {
            let record = try reader.record(at: locations[index].recordOffset)
            XCTAssertEqual(record.bytes, Data(repeating: UInt8(index + 1), count: 10 + index))
            XCTAssertEqual(record.header.origLen, UInt32(100 + index))
            XCTAssertEqual(record.timestampMicroseconds, UInt64(1_700_000_000 + index) * 1_000_000 + 250_000)
        }
    }

    func testAFileThatIsNotThereOrIsNotOursDoesNotOpen() throws {
        assertThrows(try PcapFileReader(url: tempDir.appendingPathComponent("absent.pcap")), .openFailed)

        let garbage = tempDir.appendingPathComponent("garbage.pcap")
        try Data(repeating: 0, count: 512).write(to: garbage)
        assertThrows(try PcapFileReader(url: garbage), .format(.unknownMagic(0)))

        let stub = tempDir.appendingPathComponent("stub.pcap")
        try Data(repeating: 0, count: 10).write(to: stub)
        assertThrows(try PcapFileReader(url: stub), .format(.shortHeader(expected: 24, actual: 10)))
    }

    func testEveryWayARecordCannotBeRead() async throws {
        let writer = try PcapWriter(config: .init(directory: tempDir, snaplen: 64))
        let first = try await writer.write(packet: Data(repeating: 1, count: 32), originalLength: 32, timestamp: 1)
        let last = try await writer.write(packet: Data(repeating: 2, count: 32), originalLength: 32, timestamp: 2)
        await writer.close()
        let url = try fileURL()

        // Se falsea el `incl_len` del primero y se corta el último a medio payload.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: first.recordOffset + 8)
        try handle.write(contentsOf: Data([0xFF, 0xFF, 0xFF, 0xFF]))
        try handle.truncate(atOffset: last.recordOffset + 16 + 5)
        try handle.close()

        let reader = try PcapFileReader(url: url)
        defer { reader.close() }

        assertThrows(try reader.record(at: 0), .offsetInsideFileHeader(0))
        assertThrows(try reader.record(at: 23), .offsetInsideFileHeader(23))
        assertThrows(try reader.record(at: first.recordOffset), .recordExceedsSnaplen(inclLen: .max, snaplen: 64))
        assertThrows(try reader.record(at: last.recordOffset), .recordCutShort(expected: 32, actual: 5))
        assertThrows(try reader.record(at: 4_096), .format(.shortHeader(expected: 16, actual: 0)))
    }
}
