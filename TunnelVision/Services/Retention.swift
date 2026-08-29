import Foundation
import Shared

/// Lo que TunnelVision ocupa en el dispositivo, repartido en sus tres mitades.
///
/// Van separadas porque se recortan con políticas distintas y el usuario tiene que poder ver por qué:
/// las capturas son bytes crudos que se borran fichero a fichero, el historial son metadatos que solo
/// se pueden cortar por antigüedad (`RetentionSize` explica por qué un tope en bytes sobre SQLite no se
/// podría cumplir), y el contenido descifrado caduca **siempre** y con su propio plazo (ADR 0007).
///
/// Se queda en la app aunque el planificador de retención se haya mudado a `Shared`: esto es lo que
/// enseña Ajustes → *Storage*, y la extensión nunca tiene a quién contarle cuánto ocupa nada.
public struct StorageUsage: Sendable, Equatable {

    /// Lo que suman los `.pcap` del directorio de capturas, incluido el que se esté escribiendo: es
    /// espacio ocupado igual que el resto, y descontarlo haría que el total no cuadrase con el
    /// almacenamiento que enseña iOS.
    public let captureBytes: UInt64

    public let captureFileCount: Int

    /// Lo que ocupa la BD del historial, con sus ficheros auxiliares de WAL.
    public let historyBytes: UInt64

    /// Cuántas conexiones hay guardadas. Va con los bytes porque es lo que da sentido a la cifra: unos
    /// megas de BD no le dicen nada a nadie, "1 240 conexiones" sí.
    public let historyFlowCount: Int

    /// Lo que suman los ficheros de contenido descifrado (`.tvpt`).
    ///
    /// Entra en el total por lo mismo que las capturas: es espacio ocupado, y un total que se lo
    /// dejase fuera diría menos de lo que iOS enseña justo en el artefacto más sensible que este
    /// producto guarda.
    public let plaintextBytes: UInt64

    /// Cuántos trozos descifrados hay **indexados**.
    ///
    /// No se enseña —un "trozo" es una unidad que el usuario no tiene por qué conocer, y por eso el
    /// resultado de un barrido tampoco los cuenta— pero decide si hay algo que borrar: un índice con
    /// filas y ningún fichero sigue siendo contenido guardado a efectos de lo que se puede leer.
    public let plaintextChunkCount: Int

    public init(
        captureBytes: UInt64,
        captureFileCount: Int,
        historyBytes: UInt64,
        historyFlowCount: Int,
        plaintextBytes: UInt64 = 0,
        plaintextChunkCount: Int = 0
    ) {
        self.captureBytes = captureBytes
        self.captureFileCount = captureFileCount
        self.historyBytes = historyBytes
        self.historyFlowCount = historyFlowCount
        self.plaintextBytes = plaintextBytes
        self.plaintextChunkCount = plaintextChunkCount
    }

    public var totalBytes: UInt64 { captureBytes + historyBytes + plaintextBytes }

    /// Si hay contenido descifrado que borrar. Los bytes solos no bastan: unas filas que sobrevivan a
    /// sus ficheros siguen prometiendo un contenido que la pantalla de una conexión ofrecería abrir.
    public var hasPlaintext: Bool { plaintextBytes > 0 || plaintextChunkCount > 0 }
}

/// Qué se llevó el borrado del contenido descifrado (ADR 0007, punto 3).
///
/// Va aparte de `PlaintextSweepOutcome` porque **no es un barrido**: allí se decide qué ha caducado y
/// qué sobra, aquí no se decide nada — se va todo lo que se puede ir. Lo que comparten es el final,
/// porque vaciar el índice deja huérfano hasta el último fichero y quien sabe borrarlos del disco es
/// el barrido.
public struct PlaintextClearOutcome: Sendable, Equatable {

    /// Filas del índice que se fueron.
    public let clearedChunks: Int

    public let deletedFiles: [UInt32]

    public let bytesReclaimed: UInt64

    /// Contenido descifrado que **sigue** en el disco. Con el túnel vivo es el fichero que la
    /// extensión está escribiendo, que no se toca nunca; sin él, lo que no se dejó borrar.
    public let bytesKept: UInt64

    public let failures: [String]

    public init(
        clearedChunks: Int = 0,
        deletedFiles: [UInt32] = [],
        bytesReclaimed: UInt64 = 0,
        bytesKept: UInt64 = 0,
        failures: [String] = []
    ) {
        self.clearedChunks = clearedChunks
        self.deletedFiles = deletedFiles
        self.bytesReclaimed = bytesReclaimed
        self.bytesKept = bytesKept
        self.failures = failures
    }

    public var didChangeAnything: Bool { clearedChunks > 0 || !deletedFiles.isEmpty }
}
