import Foundation

/// Lo que hay que borrar para cumplir los topes, decidido **antes** de tocar nada.
///
/// Es un valor puro a propósito: quién se va y por qué es la parte que hay que poder afirmar sin borrar
/// ficheros de verdad, y también lo que la pantalla necesita para decir qué va a pasar antes de que
/// pase (borrar es irreversible, `docs/ux/00-ux-principles.md`).
public struct RetentionPlan: Sendable, Equatable {

    /// Corte para `FlowStore.prune(before:)`, o `nil` si no hay tope de antigüedad.
    public let historyCutoff: Date?

    /// Capturas a borrar, de la más antigua a la más reciente.
    public let filesToDelete: [UInt32]

    public let bytesReclaimed: UInt64

    /// Lo que seguirían pesando las capturas después de ejecutar el plan.
    public let captureBytesAfter: UInt64

    /// El tope de tamaño no se puede cumplir sin borrar el fichero que se está escribiendo, que no se
    /// toca nunca. Ocurre cuando la grabación en curso ya pesa por sí sola más que el tope. Se dice en
    /// vez de callarse: si no, el usuario vería su tope incumplido sin explicación y creería que la
    /// limpieza no funciona.
    public let sizeCapUnreachable: Bool

    public init(
        historyCutoff: Date?,
        filesToDelete: [UInt32],
        bytesReclaimed: UInt64,
        captureBytesAfter: UInt64,
        sizeCapUnreachable: Bool
    ) {
        self.historyCutoff = historyCutoff
        self.filesToDelete = filesToDelete
        self.bytesReclaimed = bytesReclaimed
        self.captureBytesAfter = captureBytesAfter
        self.sizeCapUnreachable = sizeCapUnreachable
    }

    /// Si el plan pide algo. Un corte de historial cuenta como trabajo aunque no haya ninguna fila
    /// suficientemente vieja: eso no se sabe hasta consultar el store.
    public var hasWork: Bool { historyCutoff != nil || !filesToDelete.isEmpty }
}

/// Quién se va cuando la retención aprieta. Todas las decisiones de la retención están aquí, en una
/// función pura sobre el listado del directorio.
///
/// Vive en `Shared` —nació en la app, con la pantalla de Ajustes— desde que la retención dejó de
/// aplicarse solo cuando alguien la mira: la extensión la aplica también al rotar, que es el único
/// momento en que ya está tocando el directorio y el único que existe con la app cerrada. Los dos
/// lados planifican con esta misma función, así que un tope no puede significar una cosa delante del
/// usuario y otra a sus espaldas.
public enum RetentionPlanner {

    /// El plan para un directorio y unos topes.
    ///
    /// - Parameters:
    ///   - files: el listado del directorio, en cualquier orden (se ordena por secuencia, que es su
    ///     orden cronológico).
    ///   - recordingSequence: el fichero que la extensión está escribiendo ahora mismo, si hay alguno
    ///     (`CapturesPresentation.recordingSequence`). Nunca entra en el plan.
    public static func plan(
        files: [CaptureFileInfo],
        settings: RetentionSettings,
        now: Date,
        recordingSequence: UInt32?
    ) -> RetentionPlan {
        let ordered = files.sorted { $0.sequence < $1.sequence }
        let totalBytes = ordered.reduce(UInt64(0)) { $0 + $1.byteCount }
        let cutoff = settings.maxAge.maxAge.map { now.addingTimeInterval(-$0) }

        var doomed: Set<UInt32> = []
        var reclaimed: UInt64 = 0

        // Los dos topes se aplican **en secuencia y en este orden**: el de tamaño mide sobre lo que la
        // antigüedad ya ha liberado, así que no pide ni un borrado de más — la antigüedad es lo que el
        // usuario ha pedido olvidar, y a menudo con eso ya se cabe. Los dos recortan de lo más antiguo a
        // lo más reciente, que es la propiedad que de verdad importa: no hay forma de perder una captura
        // reciente conservando otra más vieja.
        if let cutoff {
            for (index, file) in ordered.enumerated() where file.sequence != recordingSequence {
                // Un fichero se deja de escribir cuando aparece el siguiente: el writer solo escribe en
                // la secuencia más alta y nunca vuelve a una anterior. Así que lo que decide si un
                // fichero es entero más viejo que el corte es la fecha de **su sucesor**, no la suya:
                // por la propia no se sabe hasta cuándo se le estuvo añadiendo, y borrarlo por ella se
                // llevaría tráfico más reciente que el corte.
                guard index + 1 < ordered.count, let closedAt = ordered[index + 1].createdAt else { continue }
                guard closedAt < cutoff else { continue }
                doomed.insert(file.sequence)
                reclaimed += file.byteCount
            }
        }

        var unreachable = false
        if let maxBytes = settings.maxCaptureSize.maxBytes {
            var remaining = totalBytes - reclaimed
            // De la más antigua a la más reciente: si hay que perder capturas para caber, se pierden las
            // que menos falta hacen.
            for file in ordered where !doomed.contains(file.sequence) && file.sequence != recordingSequence {
                guard remaining > maxBytes else { break }
                doomed.insert(file.sequence)
                reclaimed += file.byteCount
                remaining -= file.byteCount
            }
            unreachable = remaining > maxBytes
        }

        return RetentionPlan(
            historyCutoff: cutoff,
            filesToDelete: ordered.map(\.sequence).filter { doomed.contains($0) },
            bytesReclaimed: reclaimed,
            captureBytesAfter: totalBytes - reclaimed,
            sizeCapUnreachable: unreachable
        )
    }
}
