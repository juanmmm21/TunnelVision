import Foundation
import Shared

// Los tres sumideros del hot path, abstraídos en protocolos estrechos. El `PacketPipeline` los
// recibe inyectados en vez de instanciar `RingBufferProducer`/`PcapWriter`/`FlowStore` por su
// cuenta: así el pipeline —única lógica de M7 que no depende del dispositivo— se ejercita en
// Simulator contra dobles en memoria, sin App Group, sin fichero mmap y sin SQLite.
//
// Las conformidades de los tipos reales viven aparte, en `PipelineAdapters.swift`.

/// Feed en vivo hacia la app (ring buffer SPSC, `docs/spec/ipc.md`).
///
/// `push` es síncrono y no puede fallar por diseño: el ring nunca bloquea el read loop de la
/// extensión y, si está lleno, descarta y cuenta internamente (back-pressure, no error).
public protocol LiveFeedSink: Sendable {
    func push(_ meta: PackedPacketMeta)
}

/// Escritura de la captura en disco (`docs/spec/pcap.md`).
///
/// `write` devuelve dónde quedó el registro —fichero y offset—, que acaba en `PacketMeta.capture`.
/// Lanza si la escritura falla (disco lleno); el pipeline decide qué hacer con ese fallo, nunca lo
/// traga el sumidero.
///
/// El instante que recibe es **absoluto** (nanosegundos desde el epoch), igual que el del contenido
/// descifrado y por la misma razón: el fichero sobrevive a la sesión que lo escribió y se abre en
/// Wireshark, donde `ts_sec` es una hora de pared. Convertir el sello monotónico del hot path es de
/// quien tiene el ancla de la sesión, que es el pipeline.
public protocol CaptureSink: Sendable {
    func write(packet: Data, originalLength: Int, timestamp: Int64) async throws -> CaptureLocation
    func flush() async throws
}

/// Escritura del contenido descifrado en disco (`docs/spec/plaintext.md`).
///
/// Mismo contrato que la captura y por las mismas razones: `write` devuelve **dónde** quedó el
/// registro —que es lo que acaba en la fila del índice— y lanza si el disco falla, sin tragarse
/// nada. Las dos diferencias con `CaptureSink` son del formato y están decididas en su spec: el
/// instante que recibe es **absoluto** (estos ficheros sobreviven a la sesión que los escribió) y
/// hay que pedirle una conversación (`openStream`) por flujo, porque un fichero intercala varias.
///
/// `write` devuelve `nil` cuando no había nada que guardar; un trozo vacío no es un error y tampoco
/// merece un registro.
public protocol PlaintextSink: Sendable {
    func openStream() async -> UInt64
    func write(
        _ plaintext: Data,
        stream: UInt64,
        direction: Direction,
        timestamp: Int64
    ) async throws -> PlaintextLocation?
    func flush() async throws
}

/// Persistencia durable de flujos, paquetes y contenido descifrado (`docs/spec/persistence.md`).
///
/// Solo por lotes: `upsertFlow` devuelve el id con el que enlazar los `PacketMeta` del flujo, y los
/// `PlaintextChunkMeta` cuelgan de ese mismo id. Un insert por paquete —o por trozo— está prohibido
/// en el hot path.
public protocol FlowPersisting: Sendable {
    @discardableResult
    func upsertFlow(_ record: FlowRecord) async throws -> Int64
    func appendPackets(_ metas: [PacketMeta], flowID: Int64) async throws
    func appendPlaintext(_ chunks: [PlaintextChunkMeta], flowID: Int64) async throws
}
