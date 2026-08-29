import Foundation
import Shared

public enum StorageError: Error, Sendable, Equatable {
    /// El directorio de capturas no se pudo leer (el contenedor del App Group no se resuelve). Sin el
    /// listado no hay plan que hacer, así que no se ha tocado nada.
    case capturesUnavailable(String)
}

/// El almacenamiento visto desde Ajustes → *Storage* (`docs/ux/screens.md`): cuánto se ocupa, y las dos
/// formas de recortarlo — aplicar los topes ahora, o borrarlo todo.
///
/// Existe porque **la retención cruza las dos mitades y ninguna de las dos se basta**: `prune(before:)`
/// y `clearAll()` borran filas y no ficheros, así que una limpieza que solo tocase la BD dejaría los
/// `.pcap` ocupando el disco, y una que solo borrase ficheros dejaría el historial señalando bytes que
/// ya no están.
///
/// Es de la app porque lo que hay aquí es lo que **el usuario** pide desde Ajustes: ver cuánto ocupa
/// (`usage`) y borrarlo todo (`clearEverything`), dos cosas que la extensión no tiene a quién contar.
/// Aplicar los topes, en cambio, ya no es solo suyo: desde M11 lo hace también la extensión al rotar,
/// para que un tope siga valiendo con la app cerrada, y por eso `enforce` decide con `RetentionPlanner`
/// y ejecuta con `CaptureRetention`, ambos en `Shared`. Lo que queda aquí de esa operación es la costura
/// de la app —el listado que puede no resolverse y el historial que se abre en diferido—, no la regla.
///
/// Es un `actor` por lo mismo que `CaptureLibrary` y `FlowStore`: toca disco. Y **no guarda estado**, ni
/// el listado ni el store: quien escribe las capturas es otro proceso, y una lista cacheada sería un
/// directorio que la rotación ya cambió.
public actor StorageManager {

    private let library: CaptureLibrary

    /// El historial se abre **en cada operación** y se suelta al terminar, igual que la Timeline lo abre
    /// en diferido: mantener una segunda conexión GRDB viva toda la vida de la app para operaciones que
    /// nacen de un gesto del usuario es pagar por nada, y quedarse con una apertura fallida pegaría ese
    /// fallo a la pantalla para siempre.
    private let openStore: @Sendable () throws -> FlowStore

    /// El directorio del contenido descifrado, o `nil` si el contenedor del App Group no se resuelve.
    /// Se guarda resuelto porque no hay nada que listar hasta que la extensión lo crea, y no existir
    /// **no** es un fallo: es el estado normal de un producto cuya persistencia viene apagada.
    private let plaintextDirectory: URL?

    public init(
        library: CaptureLibrary,
        openingStore: @escaping @Sendable () throws -> FlowStore,
        plaintextDirectory: URL?
    ) {
        self.library = library
        self.openStore = openingStore
        self.plaintextDirectory = plaintextDirectory
    }

    /// Sobre el App Group: el directorio donde escribe la extensión y la BD que comparten los dos
    /// procesos.
    public init(appGroupID: String = AppGroup.identifier) {
        self.init(
            library: CaptureLibrary(appGroupID: appGroupID),
            openingStore: { try FlowStore(appGroupID: appGroupID) },
            plaintextDirectory: PlaintextDirectory.url(inAppGroup: appGroupID)
        )
    }

    /// Lo que se ocupa ahora mismo.
    ///
    /// Un historial que no se puede abrir cuenta como **vacío** y no como un fallo: el volumen está en
    /// las capturas, y negarle al usuario la cifra entera porque falte la mitad pequeña sería peor que
    /// darle la que sí se sabe. Que la BD no se abra ya se lo cuenta la Timeline, que es quien la
    /// necesita para funcionar.
    public func usage() async throws -> StorageUsage {
        let files = try await listFiles()
        var historyBytes: UInt64 = 0
        var historyFlowCount = 0
        var plaintextChunkCount = 0
        if let store = try? openStore() {
            historyBytes = UInt64(max(0, (try? await store.totalBytesOnDisk()) ?? 0))
            historyFlowCount = (try? await store.flowCount()) ?? 0
            plaintextChunkCount = (try? await store.plaintextChunkCount()) ?? 0
        }
        return StorageUsage(
            captureBytes: files.reduce(UInt64(0)) { $0 + $1.byteCount },
            captureFileCount: files.count,
            historyBytes: historyBytes,
            historyFlowCount: historyFlowCount,
            plaintextBytes: plaintextBytesOnDisk(),
            plaintextChunkCount: plaintextChunkCount
        )
    }

    /// Aplica los topes de retención ahora.
    ///
    /// Lanza **solo** si no se pudo ni empezar (sin listado no hay plan que hacer); todo lo demás vuelve
    /// dentro del `RetentionOutcome`, incluido que el historial no se dejase abrir. Es el mismo reparto
    /// que en `HistoryReader`: lo que la pantalla tiene que poder pintar es un resultado, no una
    /// excepción.
    @discardableResult
    public func enforce(
        _ settings: RetentionSettings,
        recordingSequence: UInt32?,
        now: Date = Date()
    ) async throws -> RetentionOutcome {
        let files = try await listFiles()
        let plan = RetentionPlanner.plan(
            files: files,
            settings: settings,
            now: now,
            recordingSequence: recordingSequence
        )
        guard plan.hasWork else {
            return RetentionOutcome(sizeCapUnreachable: plan.sizeCapUnreachable)
        }
        return await CaptureRetention.execute(plan, files: files, openingHistory: openStore)
    }

    /// Aplica la retención del **contenido descifrado** ahora (ADR 0007).
    ///
    /// Es una operación aparte de `enforce` y no un trozo suyo, por la misma razón que en la
    /// extensión: los topes de captura son del usuario y puede quitarlos, mientras que lo descifrado
    /// **siempre** caduca. Compartir método las habría atado al mismo atajo de "sin topes no hay nada
    /// que hacer", que es justo el que aquí no vale.
    ///
    /// No lanza: sin directorio no hay nada que barrer (nadie ha descifrado nunca nada) y lo demás
    /// vuelve dentro del resultado, igual que en la retención de capturas.
    @discardableResult
    public func sweepPlaintext(
        _ settings: RetentionSettings,
        isMonitoring: Bool,
        now: Date = Date()
    ) async -> PlaintextSweepOutcome {
        guard let plaintextDirectory else { return PlaintextSweepOutcome() }
        let files = PlaintextDirectory.fileInfos(in: plaintextDirectory)
        return await PlaintextRetention.sweep(
            settings,
            directory: plaintextDirectory,
            // Con el túnel vivo, el fichero más nuevo puede ser el que la extensión está escribiendo
            // —o el que acaba de cerrar con trozos aún sin indexar—, y ninguno de los dos se toca.
            openSequence: PlaintextRetentionPlanner.openSequence(files: files, isMonitoring: isMonitoring),
            now: now,
            openingHistory: openStore
        )
    }

    /// Borra el **contenido descifrado** y nada más: ni el historial ni las capturas (ADR 0007, punto 3).
    ///
    /// Son dos mitades encadenadas y ninguna se basta. `FlowStore.clearPlaintext` vacía el índice y no
    /// toca un solo fichero, así que sola dejaría en disco justo los bytes que el usuario quiere fuera
    /// —ilegibles, pero ahí—; y el barrido solo borra lo que ya no está referenciado, así que solo
    /// después de vaciar el índice ve huérfano todo lo que hay. El orden es el mismo que usa "borrarlo
    /// todo" y por la misma razón.
    ///
    /// No lanza: lo que no salió vuelve dentro del resultado, igual que en los dos barridos.
    public func clearPlaintext(
        _ settings: RetentionSettings,
        isMonitoring: Bool,
        now: Date = Date()
    ) async -> PlaintextClearOutcome {
        let clearedChunks: Int
        do {
            clearedChunks = try await openStore().clearPlaintext()
        } catch {
            // Sin vaciar el índice no hay huérfanos, así que el barrido conservaría todos los ficheros
            // y el gesto no habría borrado nada. Se para y se dice, en vez de barrer y quedarse con la
            // mitad que no se pidió.
            return PlaintextClearOutcome(
                bytesKept: plaintextBytesOnDisk(),
                failures: ["The decrypted content index couldn't be cleared: \(String(describing: error))"]
            )
        }

        let sweep = await sweepPlaintext(settings, isMonitoring: isMonitoring, now: now)
        return PlaintextClearOutcome(
            clearedChunks: clearedChunks,
            deletedFiles: sweep.deletedFiles,
            bytesReclaimed: sweep.bytesReclaimed,
            // Se mide **después** del barrido y sobre el disco, no restando: lo que queda es el fichero
            // abierto o el que no se dejó borrar, y en los dos casos el dato honesto es el que hay.
            bytesKept: plaintextBytesOnDisk(),
            failures: sweep.failures
        )
    }

    /// Borra todo lo que se puede borrar: el historial entero y todas las capturas menos la que se está
    /// escribiendo, que sigue siendo intocable por lo mismo que en la pantalla de capturas — dejar a la
    /// extensión escribiendo en un fichero sin nombre no daría un solo error y no dejaría nada que
    /// exportar. Con el túnel parado no hay ninguna abierta y se van todas.
    public func clearEverything(recordingSequence: UInt32?) async throws -> RetentionOutcome {
        let files = try await listFiles()
        let deletion = await delete(
            sequences: files.map(\.sequence).filter { $0 != recordingSequence },
            sizes: files
        )
        var failures = deletion.failures

        var prunedFlows = 0
        do {
            let store = try openStore()
            // El recuento se toma **antes** de vaciar: `clearAll` no dice cuántas filas se llevó, y sin
            // el número la pantalla no podría contar qué se borró.
            prunedFlows = try await store.flowCount()
            try await store.clearAll()
        } catch {
            failures.append("The history couldn't be cleared: \(String(describing: error))")
            prunedFlows = 0
        }

        return RetentionOutcome(
            deletedFiles: deletion.deleted,
            bytesReclaimed: deletion.bytesReclaimed,
            prunedFlows: prunedFlows,
            failures: failures
        )
    }

    // MARK: - Interno

    /// Lo que ocupan los `.tvpt` ahora mismo. Sin directorio son cero bytes y no un fallo: significa
    /// que no se ha descifrado nunca nada, que es el estado de fábrica del producto.
    private func plaintextBytesOnDisk() -> UInt64 {
        guard let plaintextDirectory else { return 0 }
        return PlaintextDirectory.fileInfos(in: plaintextDirectory).reduce(UInt64(0)) { $0 + $1.byteCount }
    }

    private func listFiles() async throws -> [CaptureFileInfo] {
        do {
            return try await library.files()
        } catch {
            throw StorageError.capturesUnavailable(String(describing: error))
        }
    }

    /// Borra las capturas de un vaciado completo. Un fallo **no aborta el resto**: un fichero que no se
    /// deja borrar no es motivo para conservar los demás, y lo que no salió se cuenta.
    ///
    /// No pasa por `CaptureRetention` porque un vaciado no tiene plan: no hay tope que medir ni corte
    /// que calcular, se va todo lo que no se esté escribiendo y el historial se vacía entero
    /// (`clearAll`, no `prune`).
    private func delete(
        sequences: [UInt32],
        sizes: [CaptureFileInfo]
    ) async -> (deleted: [UInt32], bytesReclaimed: UInt64, failures: [String]) {
        var deleted: [UInt32] = []
        var reclaimed: UInt64 = 0
        var failures: [String] = []
        for sequence in sequences {
            do {
                try await library.delete(sequence: sequence)
                deleted.append(sequence)
                reclaimed += sizes.first { $0.sequence == sequence }?.byteCount ?? 0
            } catch {
                failures.append("Capture \(sequence) couldn't be deleted: \(String(describing: error))")
            }
        }
        return (deleted, reclaimed, failures)
    }
}
