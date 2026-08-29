import Foundation

/// Qué hizo de verdad una limpieza.
///
/// Lleva los fallos dentro en vez de lanzarlos porque una limpieza es **parcialmente** exitosa a
/// menudo: un fichero que no se deja borrar no es motivo para dejar el tope sin aplicar en los otros,
/// ni para perder el recuento de lo que sí se liberó.
public struct RetentionOutcome: Sendable, Equatable {

    /// Las capturas que se borraron, de la más antigua a la más reciente.
    public let deletedFiles: [UInt32]

    /// Bytes liberados por esos borrados.
    public let bytesReclaimed: UInt64

    /// Conexiones borradas del historial (sus paquetes se van con ellas, por el `ON DELETE CASCADE`).
    public let prunedFlows: Int

    /// Lo que no salió, con el texto del sistema para poder enseñarlo. Vacío es la limpieza limpia.
    public let failures: [String]

    /// Que el tope de tamaño siga incumplido porque la grabación en curso pesa más que él.
    public let sizeCapUnreachable: Bool

    public init(
        deletedFiles: [UInt32] = [],
        bytesReclaimed: UInt64 = 0,
        prunedFlows: Int = 0,
        failures: [String] = [],
        sizeCapUnreachable: Bool = false
    ) {
        self.deletedFiles = deletedFiles
        self.bytesReclaimed = bytesReclaimed
        self.prunedFlows = prunedFlows
        self.failures = failures
        self.sizeCapUnreachable = sizeCapUnreachable
    }

    /// Si algo cambió en el dispositivo. Que no cambiase nada y que fallase todo se distinguen por
    /// `failures`.
    public var didChangeAnything: Bool { !deletedFiles.isEmpty || prunedFlows > 0 }
}

/// La mitad que **ejecuta** el plan que `RetentionPlanner` decide: borra las capturas señaladas y
/// corta el historial por la fecha del plan.
///
/// Vive en `Shared` y no en la app por la misma razón que el planificador: hasta M11 la retención solo
/// se aplicaba con la pantalla de Ajustes delante, así que con la app cerrada y el túnel capturando el
/// directorio podía pasarse del tope hasta la siguiente visita. Quien cierra ese hueco es la extensión,
/// **al rotar** —el único momento en que ya está tocando el directorio, y el único que existe sin
/// nadie mirando—, y tenía que hacerlo con este mismo código: un tope no puede significar una cosa
/// delante del usuario y otra a sus espaldas.
///
/// No es un actor y no guarda nada: recibe el listado que su llamante ya tenía y devuelve lo que pasó.
/// Cada lado conserva así su propia costura para resolver el directorio y abrir el historial —la app
/// las necesita para poder fallar con explicación, la extensión ya las tiene resueltas de la sesión—,
/// y aquí solo queda lo que sí es una sola verdad.
public enum CaptureRetention {

    /// Ejecuta un plan sobre los ficheros con los que se planificó.
    ///
    /// - Parameters:
    ///   - files: el mismo listado que se le pasó al planificador. De ahí salen las URLs a borrar y los
    ///     bytes que se recuperan, así que no se vuelve a mirar el directorio: hacerlo abriría una
    ///     ventana en la que se borra un fichero que ya no es el que se planificó.
    ///   - openingHistory: cómo llegar al historial. Se invoca **solo** si el plan pide un corte, y su
    ///     fallo se cuenta como un fallo parcial: los ficheros ya borrados siguen contando.
    ///
    /// Nunca lanza. Todo lo que sale mal viaja dentro del `RetentionOutcome`, porque una limpieza a
    /// medias es un resultado y no una avería: hay que poder contar lo que sí se liberó.
    public static func execute(
        _ plan: RetentionPlan,
        files: [CaptureFileInfo],
        openingHistory: @Sendable () throws -> FlowStore
    ) async -> RetentionOutcome {
        // Los ficheros primero y el historial después. Si falla el segundo paso quedan conexiones
        // apuntando a bytes que ya no están, que es un estado que la app ya explica ("esos bytes ya no
        // están, la conexión sigue en tu historial"); al revés quedarían ficheros que nadie referencia
        // ocupando justo el espacio que la retención existe para recuperar.
        let filesBySequence = Dictionary(files.map { ($0.sequence, $0) }, uniquingKeysWith: { first, _ in first })

        var deleted: [UInt32] = []
        var reclaimed: UInt64 = 0
        var failures: [String] = []

        for sequence in plan.filesToDelete {
            guard let file = filesBySequence[sequence] else { continue }
            do {
                try FileManager.default.removeItem(at: file.url)
                deleted.append(sequence)
                reclaimed += file.byteCount
            } catch {
                // Un fichero que no se deja borrar no aborta los demás: el tope se aplica en todo lo
                // que sí se pueda, y lo que no salió se cuenta.
                failures.append("Capture \(sequence) couldn't be deleted: \(error.localizedDescription)")
            }
        }

        var prunedFlows = 0
        if let cutoff = plan.historyCutoff {
            do {
                prunedFlows = try await openingHistory().prune(before: cutoff)
            } catch {
                failures.append("The history couldn't be pruned: \(String(describing: error))")
            }
        }

        return RetentionOutcome(
            deletedFiles: deleted,
            bytesReclaimed: reclaimed,
            prunedFlows: prunedFlows,
            failures: failures,
            sizeCapUnreachable: plan.sizeCapUnreachable
        )
    }
}
