import Foundation
import XCTest
import Shared

/// Afirma que la disposición reenvía por la ruta por defecto, sin nombrar el `ParsedPacket` que
/// lleva dentro: un test de routing afirma la **decisión**, y que el parseado que la acompaña es el
/// del datagrama se verifica en su propio test.
func XCTAssertPassthrough(
    _ disposition: PacketDisposition,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .passthrough = disposition else {
        return XCTFail("Se esperaba .passthrough, no \(disposition)", file: file, line: line)
    }
}

/// La hermana de `XCTAssertPassthrough` para la ruta de inspección.
func XCTAssertInspect(
    _ disposition: PacketDisposition,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .inspect = disposition else {
        return XCTFail("Se esperaba .inspect, no \(disposition)", file: file, line: line)
    }
}

/// Dobles en memoria de los tres sumideros del pipeline, más constructores de datagramas para
/// M7. Los dobles registran lo recibido y saben fallar a demanda, para poder verificar que un
/// disco lleno o una DB rota no tumban el hot path.
enum PipelineFixtures {

    static let localV4Bytes: [UInt8] = [10, 7, 0, 2]
    static let remoteV4Bytes: [UInt8] = [93, 184, 216, 34]
    static let localV6Bytes: [UInt8] = [0xfd, 0, 0, 0, 0, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x02]
    static let remoteV6Bytes: [UInt8] = [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x02]

    static let localV4 = IPAddress(version: .v4, bytes: localV4Bytes)
    static let localV6 = IPAddress(version: .v6, bytes: localV6Bytes)

    /// Datagrama IPv4/TCP con el sentido y los puertos que pida el test. `payloadBytes` solo
    /// engorda el datagrama para verificar los contadores de bytes.
    static func tcpV4(
        outbound: Bool = true,
        localPort: UInt16 = 51000,
        remotePort: UInt16 = 443,
        flagsByte: UInt8 = 0x10,
        payloadBytes: Int = 0
    ) -> Data {
        let tcp = PacketFixtures.tcpHeader(
            sourcePort: outbound ? localPort : remotePort,
            destinationPort: outbound ? remotePort : localPort,
            sequence: 1,
            acknowledgment: 1,
            flagsByte: flagsByte,
            window: 65535,
            payload: [UInt8](repeating: 0x41, count: payloadBytes)
        )
        return PacketFixtures.ipv4(
            proto: 6,
            source: outbound ? localV4Bytes : remoteV4Bytes,
            destination: outbound ? remoteV4Bytes : localV4Bytes,
            payload: tcp
        )
    }

    static func udpV4(localPort: UInt16 = 53535, remotePort: UInt16 = 53) -> Data {
        PacketFixtures.ipv4(
            proto: 17,
            source: localV4Bytes,
            destination: remoteV4Bytes,
            payload: PacketFixtures.udpDatagram(
                sourcePort: localPort,
                destinationPort: remotePort,
                payload: [0xAA, 0xBB]
            )
        )
    }

    static func tcpV6(remotePort: UInt16 = 443) -> Data {
        PacketFixtures.ipv6(
            nextHeader: 6,
            source: localV6Bytes,
            destination: remoteV6Bytes,
            payload: PacketFixtures.tcpHeader(
                sourcePort: 50000,
                destinationPort: remotePort,
                sequence: 1,
                acknowledgment: 1,
                flagsByte: 0x10,
                window: 65535
            )
        )
    }

    /// Clave canónica del flujo UDP que produce `udpV4`.
    static func udpV4Key(localPort: UInt16 = 53535, remotePort: UInt16 = 53) -> FlowKey {
        FlowKey(
            proto: .udp,
            source: IPEndpoint(address: localV4, port: localPort),
            destination: IPEndpoint(address: IPAddress(version: .v4, bytes: remoteV4Bytes), port: remotePort)
        )
    }

    /// Clave canónica del flujo IPv4 que produce `tcpV4`, para consultar el store doble.
    static func tcpV4Key(localPort: UInt16 = 51000, remotePort: UInt16 = 443) -> FlowKey {
        FlowKey(
            proto: .tcp,
            source: IPEndpoint(address: localV4, port: localPort),
            destination: IPEndpoint(address: IPAddress(version: .v4, bytes: remoteV4Bytes), port: remotePort)
        )
    }
}

/// Feed en vivo doble. `LiveFeedSink.push` es síncrono, así que no puede ser un actor: el lock
/// justifica el `@unchecked Sendable`, igual que en el productor real del ring.
final class RecordingLiveFeed: LiveFeedSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PackedPacketMeta] = []

    func push(_ meta: PackedPacketMeta) {
        lock.lock()
        storage.append(meta)
        lock.unlock()
    }

    var pushed: [PackedPacketMeta] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// Los metadatos ya desempaquetados, que es como los verá la app tras drenar el ring.
    var metas: [PacketMeta] { pushed.map { $0.toPacketMeta() } }
}

/// Captura doble: no escribe a disco, pero simula los offsets crecientes de un fichero `.pcap`
/// real (cabecera global de 24 bytes + 16 por registro) para verificar que viajan al `PacketMeta`.
actor RecordingCapture: CaptureSink {
    struct Written: Equatable {
        let length: Int
        let originalLength: Int
        /// Nanosegundos desde el epoch: lo que el pipeline convierte con el ancla antes de escribir.
        let timestamp: Int64
        let location: CaptureLocation
    }

    private(set) var written: [Written] = []
    private(set) var flushCount = 0
    private var fileSequence: UInt32 = 0
    private var nextOffset: UInt64 = 24
    private var failWrites = false
    private var failFlush = false

    enum Failure: Error, Equatable {
        case diskFull
    }

    func failNextWrites(_ shouldFail: Bool) {
        failWrites = shouldFail
    }

    func failFlushes(_ shouldFail: Bool) {
        failFlush = shouldFail
    }

    /// Simula la rotación del writer real: fichero nuevo, offsets otra vez tras la cabecera global.
    func rotate() {
        fileSequence += 1
        nextOffset = 24
    }

    func write(packet: Data, originalLength: Int, timestamp: Int64) async throws -> CaptureLocation {
        if failWrites { throw Failure.diskFull }
        let location = CaptureLocation(fileSequence: fileSequence, recordOffset: nextOffset)
        written.append(
            Written(length: packet.count, originalLength: originalLength, timestamp: timestamp, location: location)
        )
        nextOffset += UInt64(16 + packet.count)
        return location
    }

    func flush() async throws {
        if failFlush { throw Failure.diskFull }
        flushCount += 1
    }
}

/// Escritor doble del contenido descifrado: no toca el disco, pero reparte conversaciones y simula
/// los offsets crecientes de un fichero real (cabecera global de 16 bytes + 32 por registro), que es
/// lo que permite verificar que la localización viaja hasta la fila del índice.
actor RecordingPlaintext: PlaintextSink {
    struct Written: Equatable {
        let bytes: Data
        let stream: UInt64
        let direction: Direction
        let timestamp: Int64
        let location: PlaintextLocation
    }

    private(set) var written: [Written] = []
    private(set) var flushCount = 0
    private(set) var streamsOpened = 0
    private var fileSequence: UInt32 = 0
    private var nextOffset: UInt64 = 16
    private var nextStream: UInt64 = 0
    private var failWrites = false

    enum Failure: Error, Equatable {
        case diskFull
    }

    func failNextWrites(_ shouldFail: Bool) {
        failWrites = shouldFail
    }

    /// Simula la rotación del escritor real: fichero nuevo, offsets otra vez tras la cabecera global.
    func rotate() {
        fileSequence += 1
        nextOffset = 16
    }

    func openStream() async -> UInt64 {
        defer { nextStream += 1; streamsOpened += 1 }
        return nextStream
    }

    func write(
        _ plaintext: Data,
        stream: UInt64,
        direction: Direction,
        timestamp: Int64
    ) async throws -> PlaintextLocation? {
        if failWrites { throw Failure.diskFull }
        guard !plaintext.isEmpty else { return nil }
        let location = PlaintextLocation(fileSequence: fileSequence, recordOffset: nextOffset)
        written.append(
            Written(
                bytes: plaintext,
                stream: stream,
                direction: direction,
                timestamp: timestamp,
                location: location
            )
        )
        nextOffset += UInt64(32 + plaintext.count)
        return location
    }

    func flush() async throws {
        flushCount += 1
    }

    /// Todo lo escrito de un sentido, concatenado: los trozos no tienen fronteras propias.
    func stream(_ direction: Direction) -> Data {
        written.filter { $0.direction == direction }.reduce(into: Data()) { $0.append($1.bytes) }
    }
}

/// Store doble: asigna ids estables por 5-tupla como el UPSERT real y conserva el último record
/// y todos los paquetes de cada flujo.
actor RecordingStore: FlowPersisting {
    private(set) var flows: [FlowKey: FlowRecord] = [:]
    private(set) var packets: [Int64: [PacketMeta]] = [:]
    private(set) var plaintext: [Int64: [PlaintextChunkMeta]] = [:]
    private(set) var upsertCount = 0
    private var ids: [FlowKey: Int64] = [:]
    private var nextID: Int64 = 1
    private var failing = false

    enum Failure: Error, Equatable {
        case databaseUnavailable
    }

    func fail(_ shouldFail: Bool) {
        failing = shouldFail
    }

    @discardableResult
    func upsertFlow(_ record: FlowRecord) async throws -> Int64 {
        if failing { throw Failure.databaseUnavailable }
        upsertCount += 1
        flows[record.key] = record
        if let id = ids[record.key] { return id }
        let id = nextID
        nextID += 1
        ids[record.key] = id
        return id
    }

    func appendPackets(_ metas: [PacketMeta], flowID: Int64) async throws {
        if failing { throw Failure.databaseUnavailable }
        packets[flowID, default: []].append(contentsOf: metas)
    }

    func appendPlaintext(_ chunks: [PlaintextChunkMeta], flowID: Int64) async throws {
        if failing { throw Failure.databaseUnavailable }
        plaintext[flowID, default: []].append(contentsOf: chunks)
    }

    func id(for key: FlowKey) -> Int64? { ids[key] }

    func packets(for key: FlowKey) -> [PacketMeta] {
        guard let id = ids[key] else { return [] }
        return packets[id] ?? []
    }

    func plaintext(for key: FlowKey) -> [PlaintextChunkMeta] {
        guard let id = ids[key] else { return [] }
        return plaintext[id] ?? []
    }

    var totalPackets: Int { packets.values.reduce(0) { $0 + $1.count } }
}
