import CryptoKit
import Foundation

/// Por qué no se pudo escribir la captura de un paquete de evidencia.
public enum EvidenceCaptureError: Error, Sendable, Hashable {
    /// El historial tiene paquetes de la sesión en un flujo que el paquete no lista: a
    /// `EvidenceBundle` no se le dieron todos los flujos, y una captura con paquetes de un flujo
    /// que `flows.json` no nombra sería evidencia que nadie evaluó.
    case flowNotInBundle(id: Int64)
    /// No se pudo crear el fichero de la captura.
    case destinationUnavailable(String)
    /// Falló una escritura (p. ej. disco lleno). Lo que hubiera escrito se borra.
    case writeFailed(String)
}

/// La captura ya escrita: lo que el paquete dice de ella y su entrada del manifiesto.
public struct EvidenceCapture: Sendable, Hashable {

    /// `capture.json`.
    public let document: EvidenceCaptureDocument

    /// El nombre, el tamaño y el SHA-256 de `capture.pcapng`, calculado según se escribía.
    public let entry: EvidenceManifest.Entry

    public func documentFile() throws -> EvidenceFile {
        EvidenceFile(
            name: EvidenceBundleFormat.captureDocumentFileName,
            data: try EvidenceBundleFormat.encode(document)
        )
    }
}

/// Recorta los ficheros de captura del dispositivo a los paquetes de una sesión de auditoría y los
/// escribe como `capture.pcapng` (`docs/spec/audit.md` § *The capture*).
///
/// Es la parte del paquete de evidencia que toca disco: lee el historial y el directorio de
/// capturas, y escribe **un** fichero. No cabe en memoria, así que va registro a registro; lo
/// único que crece con la sesión es la lista de offsets de un fichero de origen (acotada por los
/// 64 MB a los que rota) y un contador por flujo.
public enum EvidenceCaptureWriter {

    /// - Parameter bundle: el paquete de la sesión: da los flujos, sus hallazgos y la ventana.
    /// - Parameter store: el historial del que salió `bundle`.
    /// - Parameter captureDirectory: donde la extensión escribe sus `.pcap`.
    /// - Parameter folder: la carpeta del paquete, que ya existe. Un `capture.pcapng` anterior
    ///   se sobrescribe.
    public static func write(
        for bundle: EvidenceBundle,
        from store: FlowStore,
        captureDirectory: URL,
        into folder: URL
    ) async throws -> EvidenceCapture {
        let session = bundle.session.session
        var ledger = Ledger(bundle: bundle)

        let counts = try await store.packetCounts(inAuditSession: session.id)
        for count in counts {
            try ledger.require(flowID: count.flowID)
        }

        // Los ficheros se miran dos veces: ahora, para saber el `snaplen` antes de escribir la
        // interfaz, y al recortar cada uno. No se dejan abiertos entre medias porque una sesión
        // larga señala a decenas de ficheros y cada lector es un descriptor.
        let present = Dictionary(
            CaptureDirectory.files(in: captureDirectory).map { ($0.sequence, $0.url) },
            uniquingKeysWith: { first, _ in first }
        )
        let sequences = Set(counts.compactMap(\.fileSequence)).sorted()
        let snaplen = sequences
            .compactMap { present[$0] }
            .compactMap { url -> UInt32? in
                guard let reader = try? PcapFileReader(url: url) else { return nil }
                defer { reader.close() }
                return reader.header.snaplen
            }
            .max()

        let destination = folder.appendingPathComponent(EvidenceBundleFormat.captureFileName)
        var output = try HashingFileWriter(url: destination)
        do {
            try output.append(
                try PcapngFormat.sectionHeader(application: "TunnelVision \(bundle.session.exportedWith)")
            )
            // Sin ningún fichero leído no hay tope que declarar: 0 es «sin límite» en pcapng.
            try output.append(try PcapngFormat.interfaceDescription(snaplen: snaplen ?? 0))

            for sequence in sequences {
                let referenced = counts.filter { $0.fileSequence == sequence }
                guard let url = present[sequence], let reader = try? PcapFileReader(url: url) else {
                    let state: EvidenceCaptureDocument.SourceFile.State =
                        present[sequence] == nil ? .missing : .unreadable
                    for count in referenced {
                        ledger.lose(
                            count.packetCount,
                            of: count.flowID,
                            because: state == .missing ? .captureFileMissing : .recordUnreadable
                        )
                    }
                    ledger.sourceFiles.append(.init(
                        sequence: sequence,
                        state: state,
                        packetsReferenced: referenced.reduce(0) { $0 + $1.packetCount },
                        packetsWritten: 0
                    ))
                    continue
                }
                defer { reader.close() }

                // Las filas se vuelven a pedir en vez de fiarse del recuento: un flujo etiquetado
                // puede seguir vivo después de cerrar la sesión, y lo que se cuenta tiene que ser
                // lo que se recorre.
                let packets = try await store.capturedPackets(inAuditSession: session.id, fileSequence: sequence)
                var written = 0
                for packet in packets {
                    let comment = try ledger.comment(of: packet.flowID)
                    let record: PcapRecord
                    do {
                        record = try reader.record(at: packet.recordOffset)
                    } catch is PcapFileReader.ReadError {
                        ledger.lose(1, of: packet.flowID, because: .recordUnreadable)
                        continue
                    }
                    try output.append(
                        try PcapngFormat.enhancedPacket(
                            timestampMicroseconds: record.timestampMicroseconds,
                            originalLength: record.header.origLen,
                            bytes: record.bytes,
                            direction: packet.direction,
                            comment: comment
                        )
                    )
                    ledger.wrote(packetOf: packet.flowID, atMicroseconds: record.timestampMicroseconds)
                    written += 1
                }
                ledger.sourceFiles.append(.init(
                    sequence: sequence,
                    state: .read,
                    packetsReferenced: packets.count,
                    packetsWritten: written
                ))
            }

            for count in counts where count.fileSequence == nil {
                ledger.lose(count.packetCount, of: count.flowID, because: .notCaptured)
            }

            let (byteCount, sha256) = try output.finish()
            return EvidenceCapture(
                document: ledger.document(sessionID: session.id, snaplen: snaplen),
                entry: EvidenceManifest.Entry(
                    name: EvidenceBundleFormat.captureFileName,
                    byteCount: byteCount,
                    sha256: sha256
                )
            )
        } catch {
            // Media captura con el nombre de la entera es peor que ninguna.
            output.abandon()
            try? FileManager.default.removeItem(at: destination)
            if let error = error as? PcapngFormat.FormatError {
                throw EvidenceCaptureError.writeFailed(String(describing: error))
            }
            throw error
        }
    }
}

/// Lo que se va sabiendo de cada flujo mientras se recorta: cuántos paquetes se escribieron y
/// cuántos no, y por qué.
private struct Ledger {

    private let flowIDs: [Int64]
    private let comments: [Int64: String]
    private let startMicroseconds: UInt64
    private let endMicroseconds: UInt64

    private var written: [Int64: Int] = [:]
    private var lost: [Int64: [EvidencePacketLoss: Int]] = [:]
    private var beforeStart = 0
    private var afterEnd = 0
    var sourceFiles: [EvidenceCaptureDocument.SourceFile] = []

    init(bundle: EvidenceBundle) {
        let flows = bundle.flows.flows
        self.flowIDs = flows.map(\.id)
        self.comments = Dictionary(
            flows.map { ($0.id, EvidenceCaptureComment.text(flowID: $0.id, findingIDs: $0.findingIDs)) },
            uniquingKeysWith: { first, _ in first }
        )
        // A microsegundos, que es la resolución de un registro: comparar con más cifras pondría
        // fuera de la sesión un paquete de su primer microsegundo.
        self.startMicroseconds = Self.microseconds(bundle.session.session.startedAt)
        self.endMicroseconds = Self.microseconds(bundle.session.session.endedAt)
    }

    func require(flowID: Int64) throws {
        guard comments[flowID] != nil else { throw EvidenceCaptureError.flowNotInBundle(id: flowID) }
    }

    func comment(of flowID: Int64) throws -> String {
        guard let comment = comments[flowID] else { throw EvidenceCaptureError.flowNotInBundle(id: flowID) }
        return comment
    }

    mutating func wrote(packetOf flowID: Int64, atMicroseconds instant: UInt64) {
        written[flowID, default: 0] += 1
        if instant < startMicroseconds {
            beforeStart += 1
        } else if instant > endMicroseconds {
            afterEnd += 1
        }
    }

    mutating func lose(_ count: Int, of flowID: Int64, because loss: EvidencePacketLoss) {
        lost[flowID, default: [:]][loss, default: 0] += count
    }

    func document(sessionID: Int64, snaplen: UInt32?) -> EvidenceCaptureDocument {
        EvidenceCaptureDocument(
            sessionID: sessionID,
            snaplen: snaplen,
            flows: flowIDs.map { id in
                .init(id: id, packets: EvidencePacketTally(written: written[id] ?? 0, lost: lost[id] ?? [:]))
            },
            sourceFiles: sourceFiles,
            writtenOutsideSession: .init(beforeStart: beforeStart, afterEnd: afterEnd)
        )
    }

    private static func microseconds(_ date: Date) -> UInt64 {
        let value = (date.timeIntervalSince1970 * 1_000_000).rounded(.down)
        return value > 0 ? UInt64(value) : 0
    }
}

/// Un fichero que se escribe a trozos mientras se calcula su SHA-256: el digest es el de los bytes
/// que fueron al disco, no el de una segunda lectura.
private struct HashingFileWriter {

    /// Cuánto se acumula antes de escribir. Un paquete por llamada al sistema haría del recorte de
    /// una sesión grande millones de escrituras.
    private static let flushThreshold = 256 * 1024

    private let handle: FileHandle
    private var hasher = SHA256()
    private var pending = Data()
    private var byteCount = 0

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url)
        else {
            throw EvidenceCaptureError.destinationUnavailable(url.lastPathComponent)
        }
        self.handle = handle
    }

    mutating func append(_ data: Data) throws {
        pending.append(data)
        if pending.count >= Self.flushThreshold {
            try flush()
        }
    }

    /// Escribe lo que quede, lo lleva a disco y cierra. Devuelve el tamaño y el digest.
    mutating func finish() throws -> (byteCount: Int, sha256: String) {
        try flush()
        do {
            try handle.synchronize()
            try handle.close()
        } catch {
            throw EvidenceCaptureError.writeFailed(error.localizedDescription)
        }
        return (byteCount, EvidenceManifest.hex(hasher.finalize()))
    }

    /// Cierra sin más: lo llama quien va a borrar el fichero.
    func abandon() {
        try? handle.close()
    }

    private mutating func flush() throws {
        guard !pending.isEmpty else { return }
        do {
            try handle.write(contentsOf: pending)
        } catch {
            throw EvidenceCaptureError.writeFailed(error.localizedDescription)
        }
        hasher.update(data: pending)
        byteCount += pending.count
        pending.removeAll(keepingCapacity: true)
    }
}
