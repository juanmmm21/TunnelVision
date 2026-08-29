# Spec — Persistence (`Shared/Persistence`)

Durable history in SQLite via GRDB, in the App Group container so both processes reach it. The
extension writes (batched); the app reads. WAL mode makes concurrent read-while-write safe.
Rationale for GRDB over SwiftData/Core Data:
[`../decisions/0002-grdb-over-swiftdata.md`](../decisions/0002-grdb-over-swiftdata.md).

## Location

The DB lives at `<AppGroupContainer>/TunnelVision.sqlite`. The App Group ID constant lives in
`Shared/IPC` (see [`ipc.md`](ipc.md)); resolve the container with
`FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`.

## Time is absolute on disk

The store is the boundary where time stops being relative. `FlowRecord`/`PacketMeta` carry
`CLOCK_UPTIME_RAW` nanoseconds because that is the only clock the hot path has; the columns hold
**nanoseconds since the epoch**, converted on write with the `MonotonicAnchor` the store takes when it
opens (one per capture session). Storing the raw monotonic stamp would leave a history that cannot be
dated or ordered across a reboot — the uptime restarts, the wall clock does not — and would make
age-based retention plainly wrong.

Each flow also records its **session** (the store's open instant, in epoch ns), and that column is part
of the flows' unique index. Ephemeral ports get recycled, so without it the same 5-tuple seen on two
different days would collapse into one row spanning both, with a duration nobody ever observed.

## Schema (via `DatabaseMigrator`)

```swift
public enum Schema {
    public static func migrator() -> DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "flows") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("proto", .integer).notNull()
                t.column("addr_a", .blob).notNull()
                t.column("port_a", .integer).notNull()
                t.column("addr_b", .blob).notNull()
                t.column("port_b", .integer).notNull()
                t.column("first_seen", .integer).notNull()
                t.column("last_seen", .integer).notNull()
                t.column("bytes_out", .integer).notNull().defaults(to: 0)
                t.column("bytes_in", .integer).notNull().defaults(to: 0)
                t.column("packet_count", .integer).notNull().defaults(to: 0)
                t.column("tls_status", .integer).notNull()
                t.column("sni", .text)
            }
            try db.create(index: "flows_last_seen", on: "flows", columns: ["last_seen"])
            // Índice único sobre la 5-tupla canónica: habilita el UPSERT por flujo (`ON CONFLICT`)
            // y las búsquedas `flow(matching:)` sin escaneo. No estaba en el esquema original;
            // se añadió al implementar M2 porque la API de upsert lo requiere.
            try db.create(
                index: "flows_tuple",
                on: "flows",
                columns: ["proto", "addr_a", "port_a", "addr_b", "port_b"],
                options: [.unique]
            )

            try db.create(table: "packets") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("flow_id", .integer).notNull()
                    .references("flows", onDelete: .cascade)
                t.column("ts", .integer).notNull()
                t.column("direction", .integer).notNull()
                t.column("length", .integer).notNull()
                t.column("tcp_flags", .integer).notNull().defaults(to: 0)
                t.column("pcap_offset", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "packets_flow_id", on: "packets", columns: ["flow_id"])
        }

        // v2 (M9) — los instantes pasan a ser absolutos y el flujo recuerda su sesión de captura.
        m.registerMigration("v2") { db in
            // Las filas de v1 llevan sellos monotónicos que ya no se pueden fechar (no existe el
            // ancla de la sesión que las escribió). Se descartan en vez de reinterpretarlas como
            // epoch, que las situaría en 1970 y mentiría en la Timeline.
            try db.execute(sql: "DELETE FROM flows")
            try db.alter(table: "flows") { t in
                t.add(column: "session", .integer).notNull().defaults(to: 0)
            }
            try db.drop(index: "flows_tuple")
            try db.create(
                index: "flows_session_tuple",
                on: "flows",
                columns: ["session", "proto", "addr_a", "port_a", "addr_b", "port_b"],
                options: [.unique]
            )
        }

        // v3 (M9) — cada paquete recuerda **en qué fichero** de captura están sus bytes.
        m.registerMigration("v3") { db in
            try db.alter(table: "packets") { t in
                t.add(column: "pcap_file", .integer).notNull().defaults(to: 0)
            }
            // Las filas anteriores llevan offset pero no fichero, así que su offset no señala nada:
            // se anula (que es como se representa "sin captura") en vez de dejarlo apuntando al
            // fichero 0, que sería inventarles unos bytes. Sus metadatos se conservan.
            try db.execute(sql: "UPDATE packets SET pcap_offset = 0")
        }

        // v4 (M9) — índice por instante en `packets`, para el eje temporal de la Timeline.
        m.registerMigration("v4") { db in
            try db.create(index: "packets_ts", on: "packets", columns: ["ts"])
        }

        // v5 (M8) — el índice del **contenido descifrado**: qué trozo de qué conversación está en
        // qué fichero y en qué posición. Los bytes no están aquí (ver `plaintext.md`).
        m.registerMigration("v5") { db in
            try db.create(table: "plaintext") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("flow_id", .integer).notNull().references("flows", onDelete: .cascade)
                t.column("ts", .integer).notNull()
                t.column("direction", .integer).notNull()
                t.column("stream", .integer).notNull()        // la conversación dentro del fichero
                t.column("file_seq", .integer).notNull()
                t.column("record_offset", .integer).notNull() // `offset` es palabra reservada
                t.column("stored_length", .integer).notNull()
                t.column("original_length", .integer).notNull()
            }
            try db.create(index: "plaintext_flow_id", on: "plaintext", columns: ["flow_id", "ts"])
            try db.create(index: "plaintext_ts", on: "plaintext", columns: ["ts"])
        }
        return m
    }
}
```

Addresses are stored as raw `blob` (4 or 16 bytes) so both IPv4/IPv6 fit one column and sort
sensibly; the length disambiguates version.

## Store API

```swift
public actor FlowStore {
    public enum StoreError: Error, Sendable, Equatable {
        case appGroupUnavailable   // no se pudo resolver el contenedor del App Group
        case openFailed            // el DatabasePool no abrió
        case migrationFailed       // fallaron las migraciones
        case corruptRow(String)    // una fila no reconstruye a un tipo de dominio
    }

    // El ancla convierte los sellos monotónicos a instantes absolutos al escribir, e identifica la
    // sesión de captura. Se inyecta para fechar de forma determinista en los tests.
    public init(appGroupID: String, anchor: MonotonicAnchor = .now()) throws
    public init(databaseURL: URL, anchor: MonotonicAnchor = .now()) throws

    // Escritura (extensión) — por lotes desde el read loop.
    @discardableResult
    public func upsertFlow(_ record: FlowRecord) throws -> Int64     // devuelve rowid
    public func appendPackets(_ metas: [PacketMeta], flowID: Int64) throws
    /// Igual de por lotes, y por lo mismo: esto ocurre en el camino de un paquete.
    public func appendPlaintext(_ chunks: [PlaintextChunkMeta], flowID: Int64) throws

    // Lectura (app) — devuelve tipos ya fechados, no los del hot path.
    public func recentFlows(limit: Int, before cursor: FlowCursor? = nil) throws -> [StoredFlow]
    public func packets(forFlow id: Int64, limit: Int) throws -> [StoredPacket]
    public func flow(matching key: FlowKey) throws -> StoredFlow?    // el más reciente
    /// Mayor secuencia de fichero que el historial referencia; la consulta `PcapWriter` al
    /// arrancar para no reutilizar la de un fichero borrado cuyos paquetes siguen guardados.
    public func highestCaptureFileSequence() throws -> UInt32?

    // Contenido descifrado (M8, ADR 0007). Los bytes viven en ficheros propios; esto es su índice.
    public func plaintext(forFlow id: Int64, limit: Int) throws -> [StoredPlaintextChunk]
    /// Lo que el escritor pregunta al arrancar para no reutilizar un número que el índice señala.
    public func highestPlaintextFileSequence() throws -> UInt32?
    public func highestPlaintextStream() throws -> UInt64?
    /// Qué ficheros siguen sirviendo. Se pregunta **después** de podar: los que ya no aparecen son
    /// huérfanos y son exactamente lo que el barrido tiene que borrar del disco.
    public func referencedPlaintextFileSequences() throws -> Set<UInt32>
    public func plaintextChunkCount() throws -> Int

    // Actividad (M9) — lo que dibuja la barra de scrub de la Timeline. No es paginación: es una
    // agregación acotada por rango, y por eso `packets` está indexada por `ts` desde v4.
    public func packetTimeBounds() throws -> ClosedRange<Date>?
    public func packetCounts(
        in range: ClosedRange<Date>, bucketDuration: TimeInterval
    ) throws -> [PacketBucket]

    // Mantenimiento.
    @discardableResult
    public func prune(before cutoff: Date) throws -> Int             // filas borradas
    /// Poda **propia** del contenido descifrado, que caduca antes que el historial que lo contiene
    /// (ADR 0007): el flujo se queda con sus paquetes y sus contadores, y lo que dijo por dentro no.
    @discardableResult
    public func prunePlaintext(before cutoff: Date) throws -> Int
    /// Borrar solo el contenido descifrado. Existe porque arrepentirse de haberlo grabado no puede
    /// costar el historial entero (ADR 0007).
    @discardableResult
    public func clearPlaintext() throws -> Int
    public func totalBytesOnDisk() throws -> Int64
    public func clearAll() throws                                    // el cascade se lleva el plaintext
}

public struct StoredFlow: Sendable, Hashable, Identifiable {
    public let id: Int64                 // rowid: con él se piden los paquetes del flujo
    public let key: FlowKey
    public let firstSeen: Date
    public let lastSeen: Date
    public let bytesOut: UInt64
    public let bytesIn: UInt64
    public let packetCount: UInt64
    public let tlsStatus: TLSInspectionStatus
    public let sni: String?
    public var duration: TimeInterval { get }
    public var totalBytes: UInt64 { get }
}

public struct StoredPacket: Sendable, Hashable, Identifiable {
    public let id: Int64                 // rowid: identidad estable para las listas de la UI
    public let date: Date
    public let flowKey: FlowKey
    public let direction: Direction
    public let length: UInt32
    public let tcpFlags: TCPFlags
    /// Fichero + offset, o `nil` si no se capturó. El centinela en disco es el offset: `pcap_offset
    /// = 0` no puede ser un registro (todo `.pcap` empieza por su cabecera global), y entonces
    /// `pcap_file` vale 0 sin significar nada.
    public let capture: CaptureLocation?
}

/// Cuántos paquetes cayeron en un intervalo. Solo existen los intervalos **con** paquetes: rellenar
/// los huecos a cero es de quien pinta, que es el único que sabe cuántas barras caben.
public struct PacketBucket: Sendable, Hashable {
    public let start: Date
    public let packetCount: Int
}

/// Lleva el `id` además del instante porque `last_seen` no es único: sin el desempate, una página
/// podría repetir o saltarse filas justo en el corte.
public struct FlowCursor: Sendable, Hashable {
    public let lastSeen: Date
    public let id: Int64
    public init(after flow: StoredFlow)
}
```

Los tipos de lectura son propios y no `FlowRecord`/`PacketMeta` para que un `UInt64` no signifique
una cosa viniendo de la tabla de flujos en memoria y otra viniendo de disco: si sale del store, es
una `Date`.

El `init(appGroupID:)` recibe el ID del App Group como parámetro (la constante única
`AppGroup.identifier` vive en `Shared/IPC`, pendiente de M5) y resuelve la ruta
`<container>/TunnelVision.sqlite`. El spec original preveía un `clock: MonotonicClock` en el
init; se omitió en M2 porque el store no lo usa (los timestamps de dominio viajan dentro de
`PacketMeta`/`FlowRecord`) y un parámetro muerto contradice la regla de "cero placeholders". Se
introducirá un reloj monotónico cuando lo necesite el código productor (parseo/túnel, M3/M7).

- **WAL:** set `journal_mode=WAL` at open so the app reads while the extension writes.
- **Batched writes:** the extension accumulates `PacketMeta` and flushes with `appendPackets`
  in a single transaction; per-packet inserts are forbidden on the hot path.
- **Upsert flows:** `upsertFlow` inserts a new flow or, keyed by the canonical 5-tuple, updates
  an existing one. `FlowRecord` is the flow's **full aggregate state** (the in-memory flow table
  keeps the running totals and flushes them), so the upsert *sets* `last_seen`/counters/
  `tls_status`/`sni` to the record's values; `first_seen` keeps the minimum seen. It returns the
  flow's `rowid` for linking its packets.
- **Retention:** `prune(before:)` enforces the user's storage cap; the app exposes it in Settings →
  Storage. The cutoff is a `Date` precisely because retention is about *real* age, which a monotonic
  stamp cannot express across a reboot. `ON DELETE CASCADE` removes a flow's packets automatically.
  `flowCount()` goes with it (M9): it is the figure Settings shows next to the bytes, because a database
  size means nothing to a user and a number of connections does, and what `clearAll()` is about to remove
  can only be counted *before* it runs. Deleting rows never deletes capture files — that half belongs to
  `StorageManager` ([`app-services.md`](app-services.md)), which is what makes a cleanup honest.
- **Activity (M9):** `packetTimeBounds()` and `packetCounts(in:bucketDuration:)` are what the
  Timeline's scrub bar is drawn from, and the store's first **aggregate** read — everything else here
  returns rows. Three decisions. **(1) It counts packets, not flows alive per interval.** A packet has
  its own stamp and an indexed column, so the counts are a `GROUP BY` over a range; a flow spans
  intervals, and counting those would mean matching every row against every bucket (the same overlap
  `HistoryFilter` does in memory). **(2) The buckets are aligned to the range's start**, not to the
  epoch, so `ts - start` is never negative and SQLite's integer division — which truncates toward zero
  rather than down — is the floor for every row that qualifies. What the user reads off a bar is its
  real interval, so the alignment never lies to them. **(3) It honours no filter at all.** The counts
  cover everything stored, including the connections the list is hiding: the host filter is resolved
  in memory over the *displayed* host, so honouring some criteria and not others would leave an axis
  that looks filtered without being it. Saying so belongs to the screen.

## Concurrency

`FlowStore` is an `actor`; GRDB's `DatabasePool` provides a writer queue and multiple readers
underneath. Never share a raw `Database` handle across actors — go through the store API.

## Tests (M2, extended in M9)

- Migrations apply cleanly on a fresh temp DB; re-opening is idempotent; v2 discards the rows written
  under v1 (checked against a database deliberately stopped at that migration).
- Stamps come back as wall-clock dates, and those dates do **not** depend on the anchor of whoever
  reads them — if the raw monotonic stamp were on disk, a second session would read a different date.
- The same 5-tuple written in two sessions is two flows, and `flow(matching:)` returns the newer.
- The cursor breaks ties by rowid.
- Upsert increments counters correctly across many packets of one flow.
- `recentFlows`/`packets` pagination and ordering.
- `prune` deletes the right rows and cascades to `packets`; `totalBytesOnDisk` is sane.
- `flowCount` counts what is stored, does not count an upsert onto an existing row as a new connection,
  and follows both `prune` and `clearAll`.
- Concurrent write (simulated extension) + read (simulated app) under WAL do not error.
- `packetTimeBounds` is `nil` without packets (a flow alone is not enough) and spans every flow;
  `packetCounts` groups across flows, omits the empty intervals, aligns to the range's start, honours
  both ends of the range, ignores protocol and TLS status, and follows `prune`.
