import Foundation

/// Por qué un paquete que el historial guarda no está en la captura del paquete de evidencia.
public enum EvidencePacketLoss: Sendable, Hashable, CaseIterable {
    /// Nunca se escribió en un fichero de captura: la captura estaba apagada, o su escritor falló.
    case notCaptured
    /// Estaba en un fichero de captura que ya no está en el dispositivo. La retención no se lleva
    /// la evidencia de una sesión (§ *Retention*); el borrado a mano sí.
    case captureFileMissing
    /// Su fichero está, pero el registro no se pudo leer: el fichero no es legible, o se quedó a
    /// medias justo ahí.
    case recordUnreadable
}

/// Cuántos paquetes hay en el historial, cuántos llegaron a la captura y cuántos no, por motivo.
///
/// `recorded` no se da: es la suma de lo demás. Un paquete del historial o está escrito o tiene
/// un motivo para no estarlo, y un recuento que admitiera otra cosa dejaría paquetes sin explicar.
public struct EvidencePacketTally: Encodable, Sendable, Hashable {

    public struct WithoutBytes: Encodable, Sendable, Hashable {
        public let notCaptured: Int
        public let captureFileMissing: Int
        public let recordUnreadable: Int

        public var total: Int { notCaptured + captureFileMissing + recordUnreadable }
    }

    /// Los paquetes que el historial guarda.
    public let recorded: Int

    /// Los que están en la captura, con sus bytes.
    public let written: Int

    public let withoutBytes: WithoutBytes

    public init(written: Int = 0, lost: [EvidencePacketLoss: Int] = [:]) {
        let withoutBytes = WithoutBytes(
            notCaptured: lost[.notCaptured] ?? 0,
            captureFileMissing: lost[.captureFileMissing] ?? 0,
            recordUnreadable: lost[.recordUnreadable] ?? 0
        )
        self.written = written
        self.withoutBytes = withoutBytes
        self.recorded = written + withoutBytes.total
    }

    static func sum(_ tallies: [EvidencePacketTally]) -> EvidencePacketTally {
        EvidencePacketTally(
            written: tallies.reduce(0) { $0 + $1.written },
            lost: [
                .notCaptured: tallies.reduce(0) { $0 + $1.withoutBytes.notCaptured },
                .captureFileMissing: tallies.reduce(0) { $0 + $1.withoutBytes.captureFileMissing },
                .recordUnreadable: tallies.reduce(0) { $0 + $1.withoutBytes.recordUnreadable },
            ]
        )
    }
}

/// `capture.json`: qué hay en `capture.pcapng` y, sobre todo, qué **no** hay.
///
/// La captura sola no puede decir lo que le falta: un paquete sin bytes es un paquete que no
/// está. Este documento lo cuenta, por flujo y por motivo, para que una conexión con pocos
/// paquetes en la captura no se lea como una conexión con poco tráfico.
public struct EvidenceCaptureDocument: Encodable, Sendable, Hashable {

    public static let fileFormat = "pcapng"

    /// Un flujo de la sesión y lo que la captura lleva de él.
    public struct Flow: Encodable, Sendable, Hashable {
        public let id: Int64
        public let packets: EvidencePacketTally

        public init(id: Int64, packets: EvidencePacketTally) {
            self.id = id
            self.packets = packets
        }
    }

    /// Un fichero de captura del dispositivo del que la sesión tenía paquetes.
    public struct SourceFile: Encodable, Sendable, Hashable {

        public enum State: String, Encodable, Sendable, Hashable {
            /// Se abrió y se leyeron sus registros (puede que no todos: `packetsWritten`).
            case read
            /// Ya no está en el dispositivo.
            case missing
            /// Está, pero no se pudo abrir como una captura de las nuestras.
            case unreadable
        }

        /// La secuencia del fichero: la que lleva su nombre en el dispositivo.
        public let sequence: UInt32
        public let state: State

        /// Cuántos paquetes de la sesión señalaban a este fichero.
        public let packetsReferenced: Int
        public let packetsWritten: Int

        public init(sequence: UInt32, state: State, packetsReferenced: Int, packetsWritten: Int) {
            self.sequence = sequence
            self.state = state
            self.packetsReferenced = packetsReferenced
            self.packetsWritten = packetsWritten
        }
    }

    /// Paquetes escritos cuyo instante cae fuera de la sesión. No son un error: un flujo pertenece
    /// a la sesión si llevó tráfico mientras estuvo abierta (§ *Which session a flow belongs to*),
    /// y pudo empezar antes o seguir después.
    public struct OutsideSession: Encodable, Sendable, Hashable {
        public let beforeStart: Int
        public let afterEnd: Int

        public init(beforeStart: Int, afterEnd: Int) {
            self.beforeStart = beforeStart
            self.afterEnd = afterEnd
        }
    }

    public let format: String
    public let formatVersion: Int
    public let sessionID: Int64

    public let contents: String
    public let packetComments: String

    /// El nombre del fichero de la captura dentro del paquete.
    public let file: String
    public let fileFormat: String

    /// La capa de enlace de la captura: `LINKTYPE_RAW`, datagramas IP sin cabecera de enlace.
    public let linkType: UInt32

    /// El mayor número de bytes guardado por paquete, entre los ficheros que se leyeron. Ausente
    /// si no se leyó ninguno.
    public let snaplen: UInt32?

    /// La suma de `flows`.
    public let packets: EvidencePacketTally
    public let writtenOutsideSession: OutsideSession

    /// Por secuencia.
    public let sourceFiles: [SourceFile]

    /// Todos los flujos de la sesión, en el orden de `flows.json`, también los que no tienen
    /// ningún paquete en la captura.
    public let flows: [Flow]

    public init(
        sessionID: Int64,
        snaplen: UInt32?,
        flows: [Flow],
        sourceFiles: [SourceFile],
        writtenOutsideSession: OutsideSession
    ) {
        self.format = EvidenceBundleFormat.captureIdentifier
        self.formatVersion = EvidenceBundleFormat.version
        self.sessionID = sessionID
        self.contents = EvidenceWording.captureContentsNote
        self.packetComments = EvidenceWording.capturePacketCommentsNote
        self.file = EvidenceBundleFormat.captureFileName
        self.fileFormat = Self.fileFormat
        self.linkType = PcapFormat.linktypeRaw
        self.snaplen = snaplen
        self.packets = EvidencePacketTally.sum(flows.map(\.packets))
        self.writtenOutsideSession = writtenOutsideSession
        self.sourceFiles = sourceFiles.sorted { $0.sequence < $1.sequence }
        self.flows = flows
    }
}

/// El comentario que lleva cada paquete de la captura: su flujo y los hallazgos que ese flujo
/// prueba.
///
/// Es la respuesta a «cómo se va de un hallazgo a sus paquetes»: `findings.json` cita flujos, y un
/// offset solo existe dentro de un fichero que alguien puede volver a guardar. El comentario viaja
/// con el paquete, Wireshark lo enseña y deja filtrar por él.
public enum EvidenceCaptureComment {

    /// `flow=12`, o `flow=12 findings=F1,F3`.
    ///
    /// El id del flujo acaba siempre en un espacio o en el final del comentario, y el de un
    /// hallazgo en una coma o en el final: `flow=1` no se confunde con `flow=12` al filtrar.
    public static func text(flowID: Int64, findingIDs: [String]) -> String {
        guard !findingIDs.isEmpty else { return "flow=\(flowID)" }
        return "flow=\(flowID) findings=\(findingIDs.joined(separator: ","))"
    }
}
