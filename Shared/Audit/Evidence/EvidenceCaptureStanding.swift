import Foundation

/// Paquetes del historial que no están en la captura, por un motivo.
public struct EvidenceMissingPackets: Sendable, Equatable {
    public let reason: EvidencePacketLoss
    public let count: Int

    public init(reason: EvidencePacketLoss, count: Int) {
        self.reason = reason
        self.count = count
    }
}

/// Lo que la captura de un paquete lleva de lo que el historial guarda.
///
/// Son tres casos y no un recuento con tres ceros: que no falte nada se dice en una frase, y que la
/// sesión no grabara ningún paquete es otra cosa que tenerlos todos.
public enum EvidenceCaptureStanding: Sendable, Equatable {

    /// El historial no guarda ningún paquete de la sesión: la captura abre y está vacía.
    case nothingRecorded

    /// Todos los paquetes del historial están en la captura, con sus bytes.
    case complete(packets: Int)

    /// Faltan paquetes. `missing` lleva solo los motivos que tienen alguno, en el orden en que
    /// `capture.json` los escribe.
    case incomplete(written: Int, recorded: Int, missing: [EvidenceMissingPackets])

    public init(_ tally: EvidencePacketTally) {
        guard tally.recorded > 0 else {
            self = .nothingRecorded
            return
        }
        let missing = [
            EvidenceMissingPackets(reason: .notCaptured, count: tally.withoutBytes.notCaptured),
            EvidenceMissingPackets(reason: .captureFileMissing, count: tally.withoutBytes.captureFileMissing),
            EvidenceMissingPackets(reason: .recordUnreadable, count: tally.withoutBytes.recordUnreadable),
        ].filter { $0.count > 0 }

        if missing.isEmpty {
            self = .complete(packets: tally.recorded)
        } else {
            self = .incomplete(written: tally.written, recorded: tally.recorded, missing: missing)
        }
    }
}
