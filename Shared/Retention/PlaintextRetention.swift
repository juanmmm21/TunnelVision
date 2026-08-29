import Foundation

/// Qué ficheros de contenido descifrado sobran, decidido **después** de podar el índice por
/// antigüedad y **antes** de tocar el disco.
///
/// Es un valor puro por lo mismo que `RetentionPlan`: quién se va y por qué es lo que hay que poder
/// afirmar sin borrar ficheros de verdad. Lo que no tiene, a diferencia de aquél, es un corte de
/// antigüedad: aquí la antigüedad ya se aplicó —sobre las filas, que es donde vive el instante de un
/// trozo— y lo que queda por decidir es qué ficheros dejaron de servir.
public struct PlaintextSweepPlan: Sendable, Equatable {

    /// Ficheros a borrar, del más antiguo al más reciente. Son de dos clases y la distinción está en
    /// `sequencesToUnindex`: huérfanos (ninguna fila los nombra ya) y víctimas del techo.
    public let filesToDelete: [UInt32]

    /// De los anteriores, los que **todavía** tenían filas apuntándolos: los que se lleva el techo.
    /// Sus filas se van con ellos, porque contarían como contenido guardado sin bytes que leer.
    public let sequencesToUnindex: [UInt32]

    public let bytesReclaimed: UInt64

    /// Lo que seguiría ocupando el contenido descifrado tras ejecutar el plan.
    public let bytesAfter: UInt64

    /// El techo no se puede cumplir sin borrar el fichero que se está escribiendo, que no se toca
    /// nunca. Se dice en vez de callarse, igual que `sizeCapUnreachable` en las capturas.
    public let ceilingUnreachable: Bool

    public init(
        filesToDelete: [UInt32],
        sequencesToUnindex: [UInt32],
        bytesReclaimed: UInt64,
        bytesAfter: UInt64,
        ceilingUnreachable: Bool
    ) {
        self.filesToDelete = filesToDelete
        self.sequencesToUnindex = sequencesToUnindex
        self.bytesReclaimed = bytesReclaimed
        self.bytesAfter = bytesAfter
        self.ceilingUnreachable = ceilingUnreachable
    }

    public var hasWork: Bool { !filesToDelete.isEmpty }
}

/// Quién se va del contenido descifrado cuando la retención aprieta (ADR 0007).
///
/// Va aparte de `RetentionPlanner` y no dentro porque **lo que decide es otra cosa**. Allí la
/// antigüedad se mide sobre ficheros, aquí sobre filas; allí el tope de tamaño es del usuario y puede
/// no existir, aquí el techo es fijo y no se puede quitar; y allí un fichero borrado deja filas que
/// siguen valiendo —el paquete existió, sus cabeceras están en el historial— mientras que aquí la
/// fila **es** un puntero a unos bytes y sin ellos no dice nada.
public enum PlaintextRetentionPlanner {

    /// El plan para un directorio ya listado y un índice ya podado.
    ///
    /// - Parameters:
    ///   - files: el listado del directorio, en cualquier orden (se ordena por secuencia, que es
    ///     también su orden cronológico).
    ///   - referenced: las secuencias que el índice todavía nombra, preguntadas **después** de podar
    ///     por antigüedad. Esa es la definición de huérfano: preguntarlo antes conservaría justo lo
    ///     que la poda acaba de dejar sin dueño.
    ///   - openSequence: el fichero que la extensión puede tener abierto (`openSequence(files:isMonitoring:)`).
    ///     Nunca entra en el plan.
    ///   - ceiling: el techo fijo de disco. Es parámetro y no la constante para poder afirmarlo en un
    ///     test sin escribir medio giga.
    public static func plan(
        files: [PlaintextFileInfo],
        referenced: Set<UInt32>,
        openSequence: UInt32?,
        ceiling: UInt64 = RetentionSettings.plaintextByteCeiling
    ) -> PlaintextSweepPlan {
        let ordered = files.sorted { $0.sequence < $1.sequence }
        let totalBytes = ordered.reduce(UInt64(0)) { $0 + $1.byteCount }

        var doomed: Set<UInt32> = []
        var unindex: Set<UInt32> = []
        var reclaimed: UInt64 = 0

        // Primero los huérfanos: bytes que ya no puede leer nadie porque ninguna fila los nombra. No
        // es una elección entre conservar y borrar —no hay nada que conservar—, así que van fuera del
        // reparto del techo y se llevan por delante lo que ocupen.
        for file in ordered where file.sequence != openSequence && !referenced.contains(file.sequence) {
            doomed.insert(file.sequence)
            reclaimed += file.byteCount
        }

        // Y después el techo, midiendo sobre lo que los huérfanos ya han liberado: a menudo con eso
        // basta, y cada fichero que el techo se lleva de más es contenido que la caducidad del usuario
        // habría conservado. Del más antiguo al más reciente, que es la propiedad que importa: no hay
        // forma de perder una conversación de hace un rato conservando otra de anteayer.
        var remaining = totalBytes - reclaimed
        for file in ordered where !doomed.contains(file.sequence) && file.sequence != openSequence {
            guard remaining > ceiling else { break }
            doomed.insert(file.sequence)
            // Sus filas se van con él: aquí sí había contenido vivo, y una fila sin fichero no se
            // puede leer ni la vuelve a barrer nadie.
            unindex.insert(file.sequence)
            reclaimed += file.byteCount
            remaining -= file.byteCount
        }

        return PlaintextSweepPlan(
            filesToDelete: ordered.map(\.sequence).filter { doomed.contains($0) },
            sequencesToUnindex: ordered.map(\.sequence).filter { unindex.contains($0) },
            bytesReclaimed: reclaimed,
            bytesAfter: remaining,
            ceilingUnreachable: remaining > ceiling
        )
    }

    /// Qué fichero puede estar escribiendo la extensión ahora mismo.
    ///
    /// Se **deduce** del listado, y los dos procesos usan esta misma deducción aunque la extensión
    /// sepa la respuesta exacta (`PlaintextWriter.currentFileSequence`). No es descuido: el escritor
    /// suelta su fichero al rotar y no abre el siguiente hasta que haya algo que meter en él, así que
    /// justo después de rotar "no hay ninguno abierto" es cierto **y** el fichero recién cerrado es el
    /// que más probabilidades tiene de llevar trozos que el pipeline todavía no ha indexado. La
    /// deducción los protege a los dos; el dato exacto solo al primero.
    ///
    /// Con el túnel parado no hay ninguno abierto, por reciente que sea el último fichero — y darlo
    /// entonces por abierto dejaría contenido descifrado imposible de barrer.
    public static func openSequence(files: [PlaintextFileInfo], isMonitoring: Bool) -> UInt32? {
        guard isMonitoring else { return nil }
        return files.map(\.sequence).max()
    }
}

/// Qué hizo de verdad un barrido de contenido descifrado.
///
/// Va aparte de `RetentionOutcome` porque el barrido corre aunque la retención de capturas no tenga
/// nada que hacer: el contenido descifrado **siempre** caduca (ADR 0007), así que los dos resultados
/// no pueden compartir el atajo de "sin topes no hay nada que aplicar".
public struct PlaintextSweepOutcome: Sendable, Equatable {

    /// Trozos que caducaron por antigüedad (`maxPlaintextAge`).
    public let prunedChunks: Int

    /// Trozos cuyo índice se fue con el fichero que el techo se llevó. Se cuentan aparte de los
    /// caducados porque son la parte que el usuario **no** pidió olvidar todavía.
    public let unindexedChunks: Int

    public let deletedFiles: [UInt32]

    public let bytesReclaimed: UInt64

    /// Que el techo se haya llevado contenido que la caducidad del usuario habría conservado. Es lo
    /// que el ADR 0007 pide decir en pantalla en vez de dejar que parezca un fallo.
    ///
    /// Es un dato propio y no `unindexedChunks > 0`: el techo se lleva **ficheros**, y que sus filas
    /// se dejaran borrar o no es otra cosa — con el índice fallando, el contenido se ha ido igual y
    /// hay que decirlo.
    public let ceilingEnforced: Bool

    /// Que el techo siga incumplido porque lo que se está escribiendo ya pesa más que él.
    public let ceilingUnreachable: Bool

    /// Lo que no salió, con el texto del sistema. Vacío es el barrido limpio.
    public let failures: [String]

    public init(
        prunedChunks: Int = 0,
        unindexedChunks: Int = 0,
        deletedFiles: [UInt32] = [],
        bytesReclaimed: UInt64 = 0,
        ceilingEnforced: Bool = false,
        ceilingUnreachable: Bool = false,
        failures: [String] = []
    ) {
        self.prunedChunks = prunedChunks
        self.unindexedChunks = unindexedChunks
        self.deletedFiles = deletedFiles
        self.bytesReclaimed = bytesReclaimed
        self.ceilingEnforced = ceilingEnforced
        self.ceilingUnreachable = ceilingUnreachable
        self.failures = failures
    }

    public var didChangeAnything: Bool {
        prunedChunks > 0 || unindexedChunks > 0 || !deletedFiles.isEmpty
    }
}

/// El barrido del contenido descifrado: lo que hace que la decisión del ADR 0007 sea real y no una
/// preferencia guardada.
///
/// Son tres pasos y **el orden es la parte que no se puede cambiar**:
///
/// 1. **Podar el índice por antigüedad.** El instante de un trozo vive en su fila, así que la
///    caducidad se aplica ahí y no sobre el fichero — un fichero de 16 MB mezcla conversaciones de
///    horas distintas y borrarlo entero por su fecha se llevaría lo de hace un minuto.
/// 2. **Preguntar qué ficheros siguen referenciados.** Después de podar, y solo después: un fichero
///    huérfano es exactamente el que la poda acaba de dejar sin filas.
/// 3. **Borrar los huérfanos y, si aún no se cabe, aplicar el techo.**
///
/// Nunca lanza, por lo mismo que `CaptureRetention.execute`: un barrido a medias es un resultado y
/// no una avería, y lo que sí se liberó hay que poder contarlo. Lo único que lo detiene entero es no
/// poder abrir el índice, y ahí parar es la respuesta correcta: sin él no se distingue un huérfano de
/// un fichero vivo, y borrar a ciegas se llevaría contenido que el usuario todavía puede leer.
public enum PlaintextRetention {

    /// Ejecuta el barrido sobre un directorio.
    ///
    /// - Parameters:
    ///   - directory: el directorio del contenido descifrado. Que no exista no es un error: significa
    ///     que nunca se ha descifrado nada, que es el estado normal del producto.
    ///   - openSequence: el fichero que no se toca (`PlaintextRetentionPlanner.openSequence`).
    ///   - openingHistory: cómo llegar al índice. Cada llamante conserva su propia forma de abrirlo —la
    ///     app en diferido por operación, la extensión con el de la sesión—, igual que en la retención
    ///     de capturas.
    public static func sweep(
        _ settings: RetentionSettings,
        directory: URL,
        openSequence: UInt32?,
        now: Date = Date(),
        ceiling: UInt64 = RetentionSettings.plaintextByteCeiling,
        openingHistory: @Sendable () throws -> FlowStore
    ) async -> PlaintextSweepOutcome {
        let store: FlowStore
        do {
            store = try openingHistory()
        } catch {
            return PlaintextSweepOutcome(
                failures: ["The decrypted content index couldn't be opened: \(String(describing: error))"]
            )
        }

        var failures: [String] = []
        var prunedChunks = 0
        do {
            prunedChunks = try await store.prunePlaintext(before: now.addingTimeInterval(-settings.maxPlaintextAge.maxAge))
        } catch {
            // Sin la poda no hay huérfanos que detectar, pero el techo sí se puede seguir aplicando
            // sobre lo que ya hubiera: es la mitad que protege el disco, y renunciar a ella por no
            // haber podido caducar dejaría el barrido entero sin efecto.
            failures.append("Expired decrypted content couldn't be deleted: \(String(describing: error))")
        }

        let referenced: Set<UInt32>
        do {
            referenced = try await store.referencedPlaintextFileSequences()
        } catch {
            return PlaintextSweepOutcome(
                prunedChunks: prunedChunks,
                failures: failures + ["The decrypted content index couldn't be read: \(String(describing: error))"]
            )
        }

        let files = PlaintextDirectory.fileInfos(in: directory)
        let plan = PlaintextRetentionPlanner.plan(
            files: files,
            referenced: referenced,
            openSequence: openSequence,
            ceiling: ceiling
        )
        guard plan.hasWork else {
            return PlaintextSweepOutcome(
                prunedChunks: prunedChunks,
                ceilingUnreachable: plan.ceilingUnreachable,
                failures: failures
            )
        }

        let filesBySequence = Dictionary(files.map { ($0.sequence, $0) }, uniquingKeysWith: { first, _ in first })
        var deleted: [UInt32] = []
        var reclaimed: UInt64 = 0
        for sequence in plan.filesToDelete {
            guard let file = filesBySequence[sequence] else { continue }
            do {
                try FileManager.default.removeItem(at: file.url)
                deleted.append(sequence)
                reclaimed += file.byteCount
            } catch {
                // Un fichero que no se deja borrar no aborta los demás, igual que en las capturas.
                failures.append("Decrypted content file \(sequence) couldn't be deleted: \(error.localizedDescription)")
            }
        }

        // El índice se suelta **después** y solo de lo que se borró de verdad: un fichero que sigue
        // en disco sigue siendo legible, y quitarle sus filas lo convertiría en un huérfano que el
        // barrido siguiente borraría sin que nadie lo haya decidido.
        var unindexedChunks = 0
        let toUnindex = plan.sequencesToUnindex.filter(deleted.contains)
        if !toUnindex.isEmpty {
            do {
                unindexedChunks = try await store.prunePlaintext(inFileSequences: toUnindex)
            } catch {
                failures.append("The index of the deleted decrypted content couldn't be cleared: \(String(describing: error))")
            }
        }

        return PlaintextSweepOutcome(
            prunedChunks: prunedChunks,
            unindexedChunks: unindexedChunks,
            deletedFiles: deleted,
            bytesReclaimed: reclaimed,
            ceilingEnforced: !toUnindex.isEmpty,
            ceilingUnreachable: plan.ceilingUnreachable,
            failures: failures
        )
    }
}
