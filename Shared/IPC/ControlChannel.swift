import Foundation

/// Canal de control app ⇄ extensión (`NETunnelProviderSession.sendProviderMessage`), tal como lo
/// fija `docs/spec/tunnel-provider.md`.
///
/// Es **de baja frecuencia** a propósito: ajustes y consultas puntuales que nacen de un gesto del
/// usuario. Los datos por paquete viajan por el ring buffer (`docs/spec/ipc.md`) y **nunca** por
/// aquí; un `sendProviderMessage` por paquete sería un round-trip XPC en el hot path.
///
/// El codec vive en `Shared/IPC` —no en la extensión— porque es un **contrato entre los dos
/// procesos**, igual que el layout del ring: la app tiene que poder codificar comandos y decodificar
/// respuestas sin enlazar la extensión (que además no se puede enlazar: es un app-extension). Es
/// puro, así que lo que hay que verificar —que ambos lados hablan el mismo idioma— se prueba en
/// Simulator.
public enum ControlCommand: Codable, Sendable, Equatable {
    /// Enciende o apaga la inspección TLS en caliente. Encenderla exige que el usuario ya haya
    /// instalado y confiado la CA local; esa comprobación es de la app, no de la extensión.
    case setTLSInspectionEnabled(Bool)
    /// Enciende o apaga la escritura del `.pcap`. Encenderla rearma además el corte automático que
    /// dispara un fallo de escritura, para poder reintentar tras liberar espacio.
    case setCaptureEnabled(Bool)
    /// Cambia cuánto se guarda de cada paquete sobre la sesión viva. **Rota** el fichero de captura:
    /// el `snaplen` vive en su cabecera global, así que el detalle nuevo solo puede empezar en un
    /// fichero nuevo (`PcapWriter.setSnaplen`). La app lo dice al usuario, porque le aparece una
    /// captura más en su lista.
    case setCaptureDetail(CaptureDetail)
    /// Enciende o apaga que el contenido descifrado **se guarde** (ADR 0007). Es un interruptor
    /// distinto del de inspeccionar y no lo implica: inspeccionar deja ver lo que pasa mientras pasa,
    /// esto lo convierte en un registro duradero.
    ///
    /// Los dos sentidos no son simétricos, y es a propósito: **apagarlo vale en el acto** —incluso
    /// para las conexiones que ya están descifrando—, mientras que encenderlo empieza a valer en el
    /// flujo siguiente, porque el sumidero se le da a una terminación cuando se abre.
    case setPlaintextPersistenceEnabled(Bool)
    /// Cierra el fichero de captura actual y abre uno nuevo, para poder exportar lo capturado
    /// hasta ahora sin parar el túnel.
    case rotateCapture
    /// Pide los contadores de la sesión: los del pipeline (salud de la captura y del store) y los del
    /// relay (salud del reenvío, y si la inspección está haciendo algo).
    case stats
}

/// Respuesta de la extensión a un `ControlCommand`.
public enum ControlResponse: Codable, Sendable, Equatable {
    /// El comando se aplicó.
    case ok
    /// Contadores acumulados de las dos mitades de la extensión, en respuesta a `.stats`.
    case stats(TunnelStats)
    /// El comando no se pudo aplicar. Lleva el motivo como texto para que la app lo muestre: la
    /// app no puede reaccionar programáticamente a un disco lleno, solo contárselo al usuario.
    case failed(String)
    /// El túnel no está corriendo, así que no hay pipeline al que dirigir el comando. Se distingue
    /// de `.failed` porque no es un error: es una carrera normal entre la UI y `stopTunnel`.
    case notRunning
}

/// Contadores acumulados del pipeline de la extensión. La app los pide por el canal de control
/// (`ControlCommand.stats`) para mostrar salud de la captura; nunca por el feed en vivo. Viajan
/// emparejados con los del relay dentro de un `TunnelStats` (`RelayStats.swift`).
///
/// Viven aquí, y no en `PacketTunnel/Pipeline`, porque cruzan el canal dentro de un
/// `ControlResponse`: son parte del contrato entre procesos y la app tiene que poder decodificarlos.
public struct PipelineStats: Sendable, Equatable, Codable {
    /// Paquetes parseados y registrados correctamente (los `dropped` no cuentan aquí).
    public var packetsHandled: UInt64 = 0
    /// Paquetes descartados por cualquier `DropReason`.
    public var packetsDropped: UInt64 = 0
    /// Bytes IP registrados (suma de `PacketMeta.length` de los `packetsHandled`).
    public var bytesHandled: UInt64 = 0
    /// Upserts de flujo confirmados por el store.
    public var flowsPersisted: UInt64 = 0
    /// `PacketMeta` confirmados por el store.
    public var packetsPersisted: UInt64 = 0
    /// Lotes perdidos por un fallo del store (el tráfico siguió fluyendo).
    public var storeFailures: UInt64 = 0
    /// Fallos de escritura de la captura. Al primero, la captura queda desactivada.
    public var captureFailures: UInt64 = 0
    /// Capturas que la retención de la extensión borró al rotar. Es lo que la app no puede saber
    /// mirando el directorio: cuando vuelve a abrirse, los ficheros ya no están y no hay forma de
    /// distinguir "nunca existieron" de "los recortó el tope mientras no mirabas".
    public var capturesReclaimed: UInt64 = 0
    /// Borrados o cortes de historial que la retención no pudo hacer. Se cuentan por lo mismo que los
    /// del store: sin nadie delante a quien contárselo, la alternativa sería tragárselos.
    public var retentionFailures: UInt64 = 0
    /// Último fallo de la retención, como texto. Explica por qué el directorio sigue por encima del tope.
    public var lastRetentionError: String?
    /// Respuestas reinyectadas que llegaron al dispositivo pero **no se pudieron registrar**, porque la
    /// cola del registrador estaba llena. El paquete no se pierde —ya se entregó—; lo que se pierde es
    /// su fila en el historial y su registro en la captura. Se cuenta por lo mismo que los descartes del
    /// ring: un hueco en los datos que nadie explica es peor que un contador.
    public var reinjectedRecordsDropped: UInt64 = 0
    /// Trozos de contenido descifrado escritos en su fichero (`docs/spec/plaintext.md`). Con la
    /// persistencia apagada —que es lo de fábrica, ADR 0007— se queda en 0 para siempre, así que es
    /// también la forma de ver desde la app si el interruptor está haciendo algo.
    public var plaintextChunksStored: UInt64 = 0
    /// Bytes descifrados guardados de verdad.
    public var plaintextBytesStored: UInt64 = 0
    /// Bytes descifrados que **no** se guardaron porque el flujo ya había gastado su presupuesto (o
    /// porque su flujo ya no estaba en la tabla). Es el tamaño de lo que la pantalla no va a poder
    /// enseñar, y por eso se cuenta en vez de callarse: un contenido recortado sin cifra se lee como
    /// una conversación que terminó ahí.
    public var plaintextBytesDropped: UInt64 = 0
    /// Trozos de contenido descifrado que el barrido borró por caducados (ADR 0007). Se cuentan
    /// aparte de las capturas recuperadas por lo mismo que el barrido va aparte de la retención: el
    /// contenido descifrado caduca **siempre**, también con los topes de captura quitados, así que un
    /// cero aquí con la persistencia encendida es un síntoma y no un descanso.
    public var plaintextChunksExpired: UInt64 = 0
    /// Ficheros de contenido descifrado que el barrido borró del disco: los que se quedaron sin
    /// ninguna fila que los nombrase, más los que el techo fijo se llevó.
    public var plaintextFilesReclaimed: UInt64 = 0
    /// Fallos de escritura del contenido descifrado. Al primero deja de escribirse en esta sesión.
    public var plaintextFailures: UInt64 = 0
    /// Último fallo de escritura del contenido descifrado, como texto.
    public var lastPlaintextError: String?
    /// Último error del store, como texto, para diagnóstico en la UI.
    public var lastStoreError: String?
    /// Último error de captura, como texto. Su presencia explica por qué dejó de crecer el `.pcap`.
    public var lastCaptureError: String?

    public init() {}
}

/// Errores del codec del canal de control.
public enum ControlMessageError: Error, Sendable, Equatable {
    /// Los bytes recibidos no son un mensaje válido de este canal (versión distinta de la app,
    /// o un emisor que no es la app).
    case malformed
}

// El transporte es JSON: el canal es de baja frecuencia, así que la compacidad no importa, y a
// cambio un mensaje de una versión desconocida falla al decodificar en vez de reinterpretar bytes
// ajenos como un comando válido.
extension ControlCommand {
    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public init(decoding data: Data) throws {
        do {
            self = try JSONDecoder().decode(ControlCommand.self, from: data)
        } catch {
            throw ControlMessageError.malformed
        }
    }
}

extension ControlResponse {
    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public init(decoding data: Data) throws {
        do {
            self = try JSONDecoder().decode(ControlResponse.self, from: data)
        } catch {
            throw ControlMessageError.malformed
        }
    }
}
