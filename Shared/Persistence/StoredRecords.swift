import Foundation

/// Los tipos que devuelve la **lectura** del store, separados de los que recibe la escritura.
///
/// `FlowRecord`/`PacketMeta` son los tipos del hot path de la extensión y sus instantes son sellos
/// monotónicos (`CLOCK_UPTIME_RAW`), porque ahí es lo único que existe. Al cruzar el store esos
/// sellos se vuelven absolutos, así que devolver los mismos tipos obligaría a que un `UInt64` de
/// `FlowRecord` significase una cosa viniendo de la tabla de flujos y otra viniendo de disco. Estos
/// tipos existen para que esa ambigüedad no exista: si sale del store, es una `Date`.

/// Un flujo tal y como está guardado: la 5-tupla canónica, sus totales y sus instantes ya fechados.
public struct StoredFlow: Sendable, Hashable, Identifiable {

    /// `rowid` del flujo. Es con lo que se piden sus paquetes y lo que identifica la fila en la UI.
    public let id: Int64

    public let key: FlowKey

    /// Primer y último paquete vistos del flujo, en hora de pared.
    public let firstSeen: Date
    public let lastSeen: Date

    public let bytesOut: UInt64
    public let bytesIn: UInt64
    public let packetCount: UInt64
    public let tlsStatus: TLSInspectionStatus
    public let sni: String?

    public init(
        id: Int64,
        key: FlowKey,
        firstSeen: Date,
        lastSeen: Date,
        bytesOut: UInt64,
        bytesIn: UInt64,
        packetCount: UInt64,
        tlsStatus: TLSInspectionStatus,
        sni: String?
    ) {
        self.id = id
        self.key = key
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.bytesOut = bytesOut
        self.bytesIn = bytesIn
        self.packetCount = packetCount
        self.tlsStatus = tlsStatus
        self.sni = sni
    }

    /// Cuánto duró el flujo. Nunca negativa: `first_seen` guarda el mínimo visto.
    public var duration: TimeInterval { lastSeen.timeIntervalSince(firstSeen) }

    public var totalBytes: UInt64 { bytesOut &+ bytesIn }
}

/// Un paquete guardado, con su instante ya fechado y su fila identificada.
public struct StoredPacket: Sendable, Hashable, Identifiable {

    /// `rowid` del paquete: identidad estable para las listas de la UI, que el sello no da (dos
    /// paquetes pueden compartirlo).
    public let id: Int64

    public let date: Date
    public let flowKey: FlowKey
    public let direction: Direction
    public let length: UInt32
    public let tcpFlags: TCPFlags

    /// Fichero y offset donde están sus bytes, o `nil` si no se capturó (o si la fila viene de antes
    /// de que se guardara el fichero: entonces el offset no era resoluble y la migración lo anuló).
    public let capture: CaptureLocation?

    public init(
        id: Int64,
        date: Date,
        flowKey: FlowKey,
        direction: Direction,
        length: UInt32,
        tcpFlags: TCPFlags,
        capture: CaptureLocation?
    ) {
        self.id = id
        self.date = date
        self.flowKey = flowKey
        self.direction = direction
        self.length = length
        self.tcpFlags = tcpFlags
        self.capture = capture
    }
}

/// Un trozo de contenido descifrado guardado, con su instante ya fechado y su fila identificada.
///
/// Lleva **dónde** están los bytes, no los bytes: leerlos es abrir el fichero que señala y validar
/// que el registro que hay ahí es este (`docs/spec/plaintext.md`). La pantalla que los enseña puede
/// así pedir la conversación entera —que son metadatos— y traerse el contenido solo de lo que se ve.
public struct StoredPlaintextChunk: Sendable, Hashable, Identifiable {

    /// `rowid`: identidad estable para las listas, que ni el sello ni la posición dan por sí solos.
    public let id: Int64

    public let date: Date
    public let direction: Direction

    /// La conversación dentro de los ficheros. Se guarda para poder comprobar que el registro que hay
    /// en esa posición es el de este flujo y no el de otro.
    public let stream: UInt64

    public let location: PlaintextLocation

    public let storedLength: UInt32
    public let originalLength: UInt32

    public init(
        id: Int64,
        date: Date,
        direction: Direction,
        stream: UInt64,
        location: PlaintextLocation,
        storedLength: UInt32,
        originalLength: UInt32
    ) {
        self.id = id
        self.date = date
        self.direction = direction
        self.stream = stream
        self.location = location
        self.storedLength = storedLength
        self.originalLength = originalLength
    }

    /// Que no se guardó entero: el tope por registro o el presupuesto del flujo lo cortaron.
    public var isTruncated: Bool { storedLength < originalLength }

    /// Bytes que se quedaron fuera.
    public var droppedLength: UInt32 { originalLength &- min(storedLength, originalLength) }
}

/// Cuántos paquetes cayeron dentro de un intervalo del historial.
///
/// Es lo que devuelve la consulta de actividad (`FlowStore.packetCounts`), la que dibuja el eje
/// temporal de la Timeline. Solo existen los intervalos **con** paquetes: rellenar los huecos a cero
/// es cosa de quien pinta, que es el único que sabe cuántas barras caben.
public struct PacketBucket: Sendable, Hashable {

    /// Instante en que empieza el intervalo. Los intervalos no se solapan, así que identifica la fila.
    public let start: Date

    /// Paquetes guardados con sello dentro de `[start, start + bucketDuration)`.
    public let packetCount: Int

    public init(start: Date, packetCount: Int) {
        self.start = start
        self.packetCount = packetCount
    }
}

/// Posición desde la que continuar paginando hacia atrás en el tiempo.
///
/// Lleva el `id` además del instante porque `last_seen` no es único: varios flujos pueden compartir
/// el milisegundo. Sin el desempate, una página podría repetir o saltarse filas justo en el corte.
public struct FlowCursor: Sendable, Hashable {
    public let lastSeen: Date
    public let id: Int64

    public init(lastSeen: Date, id: Int64) {
        self.lastSeen = lastSeen
        self.id = id
    }

    /// Cursor que continúa después de un flujo dado.
    public init(after flow: StoredFlow) {
        self.init(lastSeen: flow.lastSeen, id: flow.id)
    }
}
