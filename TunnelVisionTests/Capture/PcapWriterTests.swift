import Foundation
import XCTest
import Shared

/// Tests del escritor `pcap` en streaming (M6). Cubren: cabecera global y de registro byte-a-byte,
/// la localización que devuelve `write` (para `PacketMeta.capture`), round-trip de muchos
/// paquetes en orden, truncado por `snaplen` (con `orig_len` intacto), rotación por tamaño y manual
/// produciendo ficheros independientes válidos, una captura larga sintética que crece linealmente
/// (invariante de streaming: solo un registro en vuelo), el orden cronológico de `captureFiles`, y
/// los errores tipados de apertura y de escritura-tras-cierre.
final class PcapWriterTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pcap-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeWriter(
        snaplen: UInt32 = 262_144,
        maxFileBytes: UInt64 = 64 * 1024 * 1024
    ) throws -> PcapWriter {
        try PcapWriter(config: .init(directory: tempDir, snaplen: snaplen, maxFileBytes: maxFileBytes))
    }

    // MARK: - Cabeceras byte-a-byte

    func testGlobalHeaderIsByteExact() async throws {
        let writer = try makeWriter(snaplen: 262_144)
        await writer.close()

        let files = await writer.captureFiles()
        XCTAssertEqual(files.count, 1)

        let bytes = [UInt8](try Data(contentsOf: files[0]))
        XCTAssertEqual(bytes.count, 24)
        XCTAssertEqual(Array(bytes[0..<4]), [0xd4, 0xc3, 0xb2, 0xa1])   // magic a1b2c3d4 en LE
        XCTAssertEqual(Array(bytes[4..<6]), [0x02, 0x00])               // version_major 2
        XCTAssertEqual(Array(bytes[6..<8]), [0x04, 0x00])               // version_minor 4
        XCTAssertEqual(Array(bytes[8..<12]), [0, 0, 0, 0])             // thiszone
        XCTAssertEqual(Array(bytes[12..<16]), [0, 0, 0, 0])           // sigfigs
        XCTAssertEqual(Array(bytes[16..<20]), [0x00, 0x00, 0x04, 0x00]) // snaplen 262144 en LE
        XCTAssertEqual(Array(bytes[20..<24]), [0x65, 0x00, 0x00, 0x00]) // network 101 (LINKTYPE_RAW)

        let decoded = try TestPcapReader.read(files[0])
        XCTAssertEqual(decoded.magic, 0xa1b2c3d4)
        XCTAssertEqual(decoded.versionMajor, 2)
        XCTAssertEqual(decoded.versionMinor, 4)
        XCTAssertEqual(decoded.snaplen, 262_144)
        XCTAssertEqual(decoded.network, 101)
        XCTAssertTrue(decoded.records.isEmpty)
    }

    func testWriteReturnsRecordLocationsAndEncodesHeaderFields() async throws {
        let writer = try makeWriter()
        let packet = Data([0x45, 0x00, 0xDE, 0xAD])

        // 3_000_000_500_000 ns desde el epoch ⇒ 3000 s + 500 µs.
        let first = try await writer.write(packet: packet, originalLength: packet.count, timestamp: 3_000_000_500_000)
        let second = try await writer.write(packet: packet, originalLength: packet.count, timestamp: 0)
        await writer.close()

        // Ambos en el mismo fichero: el primero justo tras la cabecera global, el segundo detrás.
        XCTAssertEqual(first, CaptureLocation(fileSequence: 0, recordOffset: 24))
        XCTAssertEqual(second, CaptureLocation(fileSequence: 0, recordOffset: 24 + 16 + UInt64(packet.count)))

        let files = await writer.captureFiles()
        let decoded = try TestPcapReader.read(files[0])
        XCTAssertEqual(decoded.records.count, 2)
        XCTAssertEqual(decoded.records[0].tsSec, 3000)
        XCTAssertEqual(decoded.records[0].tsUsec, 500)
        XCTAssertEqual(decoded.records[0].inclLen, UInt32(packet.count))
        XCTAssertEqual(decoded.records[0].origLen, UInt32(packet.count))
        XCTAssertEqual(decoded.records[0].data, packet)
        XCTAssertEqual(decoded.records[1].tsSec, 0)
        XCTAssertEqual(decoded.records[1].tsUsec, 0)
        XCTAssertEqual(decoded.records[1].data, packet)
    }

    // MARK: - Round-trip

    func testRoundTripPreservesAllPacketsInOrder() async throws {
        let writer = try makeWriter()
        var expected: [Data] = []
        for i in 0..<64 {
            let length = 20 + i * 3
            let packet = Data((0..<length).map { UInt8(($0 + i) & 0xff) })
            expected.append(packet)
            _ = try await writer.write(packet: packet, originalLength: packet.count, timestamp: Int64(i) * 1_000_000)
        }
        try await writer.flush()   // flush no cierra: la escritura siguiente aún funcionaría
        await writer.close()

        let files = await writer.captureFiles()
        let decoded = try TestPcapReader.read(files[0])
        XCTAssertEqual(decoded.records.map(\.data), expected)
        for (index, record) in decoded.records.enumerated() {
            XCTAssertEqual(record.inclLen, UInt32(expected[index].count))
            XCTAssertEqual(record.origLen, UInt32(expected[index].count))
        }
    }

    /// Un instante real —el de hoy— cabe en `ts_sec` y se lee de vuelta tal cual: es lo que hace que
    /// una captura exportada se abra en Wireshark con su fecha y no en 1970.
    func testCurrentWallClockInstantSurvivesTheRoundTrip() async throws {
        let writer = try makeWriter()
        let now = Date(timeIntervalSince1970: 1_800_000_123.000_456)
        let nanoseconds = WallClock.nanosecondsSince1970(from: now)

        _ = try await writer.write(packet: Data([0x45]), originalLength: 1, timestamp: nanoseconds)
        await writer.close()

        let files = await writer.captureFiles()
        let decoded = try TestPcapReader.read(files[0])
        XCTAssertEqual(decoded.records[0].tsSec, 1_800_000_123)
        XCTAssertEqual(decoded.records[0].tsUsec, 456)
    }

    /// Un ancla con la hora del dispositivo mal puesta puede dar un instante anterior al epoch, y los
    /// dos campos del formato son sin signo: se escribe el epoch en vez de envolver hasta 2106, que
    /// es la fecha que más mentiría de las dos.
    func testInstantBeforeTheEpochIsClampedInsteadOfWrappingAround() async throws {
        let writer = try makeWriter()

        _ = try await writer.write(packet: Data([0x45]), originalLength: 1, timestamp: -5_000_000_000)
        await writer.close()

        let files = await writer.captureFiles()
        let decoded = try TestPcapReader.read(files[0])
        XCTAssertEqual(decoded.records[0].tsSec, 0)
        XCTAssertEqual(decoded.records[0].tsUsec, 0)
    }

    // MARK: - snaplen

    func testSnaplenTruncatesInclLenButKeepsOrigLen() async throws {
        let snaplen: UInt32 = 16
        let writer = try makeWriter(snaplen: snaplen)
        let full = Data((0..<100).map { UInt8($0) })
        _ = try await writer.write(packet: full, originalLength: full.count, timestamp: 0)
        await writer.close()

        let files = await writer.captureFiles()
        let decoded = try TestPcapReader.read(files[0])
        XCTAssertEqual(decoded.snaplen, snaplen)
        XCTAssertEqual(decoded.records[0].inclLen, snaplen)
        XCTAssertEqual(decoded.records[0].origLen, 100)
        XCTAssertEqual(decoded.records[0].data, full.prefix(Int(snaplen)))
    }

    func testOriginalLengthLargerThanCapturedBytesIsRecorded() async throws {
        let writer = try makeWriter()
        let captured = Data((0..<10).map { UInt8($0) })
        // El paquete llegó ya recortado aguas arriba; orig_len refleja el tamaño real del datagrama.
        _ = try await writer.write(packet: captured, originalLength: 1500, timestamp: 0)
        await writer.close()

        let files = await writer.captureFiles()
        let decoded = try TestPcapReader.read(files[0])
        XCTAssertEqual(decoded.records[0].inclLen, 10)
        XCTAssertEqual(decoded.records[0].origLen, 1500)
        XCTAssertEqual(decoded.records[0].data, captured)
    }

    /// Cambiar el detalle de captura en caliente **tiene** que rotar: el `snaplen` va en la cabecera
    /// global, así que aplicarlo sobre el fichero abierto dejaría registros que miden más de lo que su
    /// propia cabecera declara, y el lector los rechazaría como corruptos.
    func testChangingTheSnaplenStartsANewFileThatDeclaresIt() async throws {
        let writer = try makeWriter(snaplen: 262_144)
        let full = Data((0..<100).map { UInt8($0) })
        _ = try await writer.write(packet: full, originalLength: full.count, timestamp: 0)

        try await writer.setSnaplen(16)
        _ = try await writer.write(packet: full, originalLength: full.count, timestamp: 1_000)
        await writer.close()

        let files = await writer.captureFiles()
        XCTAssertEqual(files.count, 2, "el detalle nuevo solo puede empezar en un fichero nuevo")

        let before = try TestPcapReader.read(files[0])
        XCTAssertEqual(before.snaplen, 262_144)
        XCTAssertEqual(before.records[0].inclLen, 100, "lo ya escrito se queda como se escribió")

        let after = try TestPcapReader.read(files[1])
        XCTAssertEqual(after.snaplen, 16)
        XCTAssertEqual(after.records[0].inclLen, 16)
        XCTAssertEqual(after.records[0].origLen, 100)
    }

    /// Reelegir el mismo detalle no puede costar un fichero: la pantalla de capturas se llenaría de
    /// ficheros de unos pocos kilobytes por tocar un selector.
    func testSettingTheSameSnaplenDoesNotRotate() async throws {
        let writer = try makeWriter(snaplen: 1_024)
        _ = try await writer.write(packet: Data([0x01]), originalLength: 1, timestamp: 0)

        try await writer.setSnaplen(1_024)
        await writer.close()

        let files = await writer.captureFiles()
        XCTAssertEqual(files.count, 1)
    }

    // MARK: - Rotación

    func testRotationBySizeProducesIndependentValidFiles() async throws {
        let packet = Data(repeating: 0xAB, count: 100)
        let recordSize: UInt64 = 16 + 100
        let maxFileBytes: UInt64 = 24 + recordSize * 2   // ~2 registros por fichero antes de rotar
        let writer = try makeWriter(snaplen: 262_144, maxFileBytes: maxFileBytes)

        let total = 10
        var locations: [CaptureLocation] = []
        for i in 0..<total {
            let location = try await writer.write(packet: packet, originalLength: packet.count, timestamp: Int64(i))
            locations.append(location)
        }
        await writer.close()

        let files = await writer.captureFiles()
        XCTAssertGreaterThan(files.count, 1)

        var totalRecords = 0
        var filesWithRecords = 0
        for file in files {
            let decoded = try TestPcapReader.read(file)   // cada fichero abre limpio por sí solo
            XCTAssertEqual(decoded.magic, 0xa1b2c3d4)
            XCTAssertEqual(decoded.network, 101)
            for record in decoded.records { XCTAssertEqual(record.data, packet) }
            totalRecords += decoded.records.count
            if !decoded.records.isEmpty { filesWithRecords += 1 }
        }
        XCTAssertEqual(totalRecords, total)

        // Tras cada rotación el offset vuelve a 24, así que hay offsets repetidos —uno por fichero
        // con registros—: lo que los distingue, y lo que hace resoluble un offset guardado, es la
        // secuencia del fichero.
        let firstRecords = locations.filter { $0.recordOffset == 24 }
        XCTAssertEqual(firstRecords.count, filesWithRecords)
        XCTAssertEqual(Set(firstRecords.map(\.fileSequence)).count, filesWithRecords)
        XCTAssertEqual(Set(locations).count, total, "cada registro tiene una localización única")
    }

    func testManualRotateStartsNewFile() async throws {
        let writer = try makeWriter()
        _ = try await writer.write(packet: Data([1, 2, 3, 4]), originalLength: 4, timestamp: 0)
        try await writer.rotate()
        let afterRotate = try await writer.write(packet: Data([5, 6, 7, 8]), originalLength: 4, timestamp: 0)
        await writer.close()

        // Primer registro del fichero nuevo: mismo offset que el del anterior, otra secuencia.
        XCTAssertEqual(afterRotate, CaptureLocation(fileSequence: 1, recordOffset: 24))

        let files = await writer.captureFiles()
        XCTAssertEqual(files.count, 2)
        let first = try TestPcapReader.read(files[0])
        let second = try TestPcapReader.read(files[1])
        XCTAssertEqual(first.records.map(\.data), [Data([1, 2, 3, 4])])
        XCTAssertEqual(second.records.map(\.data), [Data([5, 6, 7, 8])])
    }

    func testCaptureFilesAreSortedChronologically() async throws {
        let writer = try makeWriter()
        for _ in 0..<3 {
            _ = try await writer.write(packet: Data([1]), originalLength: 1, timestamp: 0)
            try await writer.rotate()
        }
        await writer.close()

        let files = await writer.captureFiles()
        XCTAssertEqual(files.count, 4)   // 3 rotaciones ⇒ 3 ficheros con datos + 1 nuevo vacío
        let names = files.map(\.lastPathComponent)
        XCTAssertEqual(names, names.sorted())
    }

    // MARK: - Streaming a escala

    func testLongSyntheticCaptureGrowsLinearly() async throws {
        let writer = try makeWriter(snaplen: 262_144, maxFileBytes: 64 * 1024 * 1024)
        let payload = Data(repeating: 0x5A, count: 1_000)
        let count = 5_000
        // El writer solo retiene un registro en vuelo (16 B + payload); el tamaño final debe ser
        // exactamente la suma de la cabecera global y de todos los registros, sin sobrecoste.
        for i in 0..<count {
            _ = try await writer.write(packet: payload, originalLength: payload.count, timestamp: Int64(i) * 1_000)
        }
        await writer.close()

        let files = await writer.captureFiles()
        XCTAssertEqual(files.count, 1)   // ~5 MiB, por debajo del umbral de 64 MiB

        let expectedSize = 24 + (16 + payload.count) * count
        let actualSize = try Data(contentsOf: files[0]).count
        XCTAssertEqual(actualSize, expectedSize)

        let decoded = try TestPcapReader.read(files[0])
        XCTAssertEqual(decoded.records.count, count)
        XCTAssertEqual(decoded.records.first?.data, payload)
        XCTAssertEqual(decoded.records.last?.data, payload)
    }

    // MARK: - Identidad del fichero

    /// La secuencia no se reinicia por sesión: si lo hiciera, el offset guardado de un paquete de
    /// ayer señalaría los bytes del fichero de hoy, que es el fallo que la localización repara.
    func testASecondWriterContinuesTheSequenceInsteadOfRestarting() async throws {
        let first = try makeWriter()
        _ = try await first.write(packet: Data([1, 2, 3, 4]), originalLength: 4, timestamp: 0)
        try await first.rotate()
        _ = try await first.write(packet: Data([5, 6, 7, 8]), originalLength: 4, timestamp: 0)
        await first.close()

        let second = try makeWriter()
        let location = try await second.write(packet: Data([9]), originalLength: 1, timestamp: 0)
        await second.close()

        XCTAssertEqual(location, CaptureLocation(fileSequence: 2, recordOffset: 24))
    }

    /// Un fichero borrado desaparece del directorio, pero sus paquetes siguen en el historial
    /// apuntándolo: el writer arranca por encima de lo que el historial referencia, no solo por
    /// encima de lo que queda en disco.
    func testTheWriterStartsAboveWhatTheHistoryReferencesEvenIfTheFileIsGone() async throws {
        let writer = try PcapWriter(
            config: .init(directory: tempDir, highestReferencedSequence: 9)
        )
        let location = try await writer.write(packet: Data([1]), originalLength: 1, timestamp: 0)
        await writer.close()

        XCTAssertEqual(location.fileSequence, 10)
    }

    /// El contrato completo: lo que devuelve `write` resuelve a un fichero que existe, y en ese
    /// offset están los bytes de *ese* paquete.
    func testEveryReturnedLocationResolvesToTheBytesItDescribes() async throws {
        let writer = try makeWriter(snaplen: 262_144, maxFileBytes: 24 + (16 + 4) * 2)
        var locations: [CaptureLocation] = []
        var packets: [Data] = []
        for i in 0..<6 {
            let packet = Data([UInt8(i), 0xAA, 0xBB, 0xCC])
            packets.append(packet)
            locations.append(
                try await writer.write(packet: packet, originalLength: packet.count, timestamp: Int64(i))
            )
        }
        await writer.close()

        for (index, location) in locations.enumerated() {
            // El 0 es el centinela de "sin captura", así que un registro real nunca puede vivir ahí.
            XCTAssertNotEqual(location.recordOffset, 0)

            let url = try XCTUnwrap(
                CaptureDirectory.url(forSequence: location.fileSequence, in: tempDir),
                "la secuencia \(location.fileSequence) debía resolver a un fichero existente"
            )
            let bytes = try Data(contentsOf: url)
            let start = Int(location.recordOffset) + 16   // tras la cabecera de registro
            XCTAssertEqual(bytes[start..<(start + 4)], packets[index])
        }
    }

    // MARK: - Errores

    func testWriteAfterCloseThrowsWriteFailed() async throws {
        let writer = try makeWriter()
        await writer.close()
        do {
            _ = try await writer.write(packet: Data([1]), originalLength: 1, timestamp: 0)
            XCTFail("write tras close debía lanzar")
        } catch let error as PcapWriter.PcapError {
            XCTAssertEqual(error, .writeFailed)
        }
    }

    func testInitOnNonDirectoryPathThrowsOpenFailed() throws {
        // Un fichero regular donde se espera un directorio ⇒ no se puede crear la captura.
        let blocker = tempDir.appendingPathComponent("blocker")
        try Data([0]).write(to: blocker)
        do {
            _ = try PcapWriter(config: .init(directory: blocker, snaplen: 1024, maxFileBytes: 1024))
            XCTFail("init sobre una ruta no-directorio debía lanzar")
        } catch let error as PcapWriter.PcapError {
            XCTAssertEqual(error, .openFailed)
        }
    }
}
