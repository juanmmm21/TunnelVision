# Spec — Inter-process communication (`Shared/IPC`)

Two channels between the extension (producer) and the app (consumer), both in the App Group
container:

- **Durable history:** the SQLite store (see [`persistence.md`](persistence.md)).
- **Live feed:** a fixed-size memory-mapped ring buffer, described here.

Plus a payload-less **Darwin notification** used only to wake the consumer. Rationale:
[`../decisions/0004-ipc-mmap-ringbuffer-plus-darwin.md`](../decisions/0004-ipc-mmap-ringbuffer-plus-darwin.md).

And a third, **low-frequency control channel** that does not go through the container at all: the
app calls `NETunnelProviderSession.sendProviderMessage` and the extension answers in
`handleAppMessage`. Its `Codable` codec (`ControlCommand`/`ControlResponse`/`TunnelStats`, which pairs
`PipelineStats` with `RelayStats`) lives in
`Shared/IPC/ControlChannel.swift` because both processes must see the same types and the app cannot
link an app-extension. It is specified in [`tunnel-provider.md`](tunnel-provider.md) (the receiving
end) and [`app-services.md`](app-services.md) (the sending end). Per-packet data never travels here.

## Shared identifiers (single source of truth)

```swift
public enum AppGroup {
    public static let identifier = "group.com.juanmmm21.tunnelvision"
}

public enum DarwinSignal {
    /// Posted by the extension when new records are available in the ring.
    /// Stored as `String` (Sendable). It is bridged to `CFString` (`name as CFString`) at the call
    /// site where `CFNotificationCenter` requires it — a global `CFString` is not concurrency-safe
    /// under Swift 6 strict concurrency.
    public static let liveDataAvailable = "com.juanmmm21.tunnelvision.live-data"
}
```

`AppGroup.identifier` is the one place this string is defined; persistence and IPC both read it
from here.

## Why mmap, not Darwin payloads

Darwin notifications **carry no data** — they are a bare cross-process signal. They cannot
transport packets. The ring buffer (a file `mmap`'d into both processes) is what actually moves
bytes; the notification only tells the app "there is something new, come drain." A common
misconception is that Darwin notifications can pass packet data; they cannot.

## Ring buffer layout

A single App Group file, mapped `MAP_SHARED` into both processes. Fixed-width records so the
consumer computes slot offsets without parsing and reads are never torn.

The header is a C struct (`CTVAtomics`), fixed at a **64-byte** reserved region (cache-line
aligned) before the slots. `magic` is `0x54565231` (`"TVR1"`), `version` is `1`.

```
┌────────────── header (64 B reserved, cache-line aligned) ──────────────┐
│ magic: UInt32            (0x54565231 "TVR1" — validate + versioning)    │
│ version: UInt32          (1)                                            │
│ slotSize: UInt32         (bytes per slot; ≥ PackedPacketMeta 64 B)      │
│ slotCount: UInt32        (power of two)                                 │
│ head: _Atomic UInt64     (producer writes release; next write index)   │
│ tail: _Atomic UInt64     (consumer writes release; next read index)    │
│ dropped: _Atomic UInt64  (producer increments on overflow)             │
└────────────────────────────────────────────────────────────────────────┘
┌──────── slots[slotCount] : fixed-size PackedPacketMeta (64 B) ──────────┐
```

`head`/`tail` are **monotonic** UInt64 indices (never wrapped modulo `slotCount`); the slot index
is `index & (slotCount - 1)`. **Full** = `head - tail == slotCount`.

```swift
/// Representación empaquetada de ancho fijo de `PacketMeta` para el ring (little-endian explícito).
/// `packedByteCount` = 64. El proto se guarda como código de 4 bits (0=tcp,1=udp,2=icmp,3=icmpv6,
/// 4=other); el valor de cable (17, 58…) no cabe en un nibble, pero `PacketMeta` ya porta el proto
/// colapsado, así que no se pierde nada. `ipVersion` (4/6) desambigua las direcciones de 16 bytes.
public struct PackedPacketMeta: Sendable, Hashable {
    public var timestamp: UInt64            // @0  (8)  ns monotónicos
    public var protoAndDirection: UInt8     // @8  (1)  código proto (nibble alto) + dirección (bajo)
    public var ipVersion: UInt8             // @9  (1)  4 o 6
    public var tcpFlags: UInt8              // @10 (1)
    // @11 (1) reservado (padding, siempre 0)
    public var portA: UInt16                // @12 (2)  endpoint canónico A (menor)
    public var portB: UInt16                // @14 (2)  endpoint canónico B (mayor)
    public var addrA: [UInt8]               // @16 (16) v4 usa los primeros 4, resto 0
    public var addrB: [UInt8]               // @32 (16)
    public var length: UInt32               // @48 (4)
    /// Dónde quedaron sus bytes: @52 (8) offset del registro, @60 (4) secuencia del fichero.
    /// Sobre el cable, `recordOffset == 0` es el centinela de "sin captura" — ningún registro
    /// puede vivir ahí, porque todo `.pcap` empieza por su cabecera global —, y entonces la
    /// secuencia se ignora en vez de fabricar una localización que apuntaría al fichero 0.
    public var capture: CaptureLocation?    // @52 (8) + @60 (4)
}
```

El estado TLS es por-flujo (vive en el store, no en este feed por-paquete), por eso no está aquí.

El registro lleva el **fichero** además del offset porque el writer rota por tamaño y cada fichero
reinicia sus offsets: sin él, un offset guardado apunta a una posición de un fichero desconocido.

## Protocol (single-producer / single-consumer)

Both sides also expose a `init(fileURL:…)` (used by the tests, over a temp-file-backed ring) that
the App-Group initializer delegates to — mirroring `FlowStore(databaseURL:)`. `slotSize` defaults to
`PackedPacketMeta.packedByteCount`.

```swift
public final class RingBufferProducer: @unchecked Sendable {   // used in the extension
    public init(appGroupID: String, slotCount: Int, slotSize: Int = PackedPacketMeta.packedByteCount) throws
    public init(fileURL: URL, slotCount: Int, slotSize: Int = PackedPacketMeta.packedByteCount) throws
    /// Escribe un registro. Si el ring está lleno, incrementa `dropped` y descarta (back-pressure).
    public func push(_ meta: PackedPacketMeta)
    public func close()
}

public final class RingBufferConsumer: @unchecked Sendable {   // used in the app
    public init(appGroupID: String) throws
    public init(fileURL: URL) throws              // lee slotSize/slotCount de la cabecera existente
    /// Drena hasta `max` registros disponibles; avanza `tail`. No bloquea.
    public func drain(max: Int) -> [PackedPacketMeta]
    public func droppedCount() -> UInt64
    public func close()
}

public enum IPCError: Error, Sendable, Equatable { case appGroupUnavailable, mapFailed, badHeader }
```

`@unchecked Sendable`: cada instancia la usa un único hilo (contrato SPSC); se marca así solo para
poder confinarla a una `Task`/`Thread`. La coordinación real es vía los atómicos de la memoria
compartida, no vía el estado de la clase.

### Memory ordering

- Producer: write the slot payload, then publish with a **release** store to `head`.
- Consumer: **acquire** load of `head`, read slots up to it, then **release** store to `tail`.
- `head`/`tail`/`dropped` live in the mapped memory and are accessed through a tiny C shim
  (`CTVAtomics`) that wraps C11 `<stdatomic.h>` with explicit memory orders. A C shim is used
  because a cross-process atomic must sit *in* the shared mmap: `Synchronization.Atomic` can't be
  overlaid on mapped memory and requires iOS 18 (the project targets iOS 17). Because there is
  exactly one producer and one consumer, no locks are needed.
- **Full** = `head - tail == slotCount`. On full, the producer drops (increments `dropped`);
  it never overwrites unread slots and never blocks the packet loop. The release/acquire pair on
  `head`/`tail` establishes the happens-before that makes slot reads tear-free (verified clean
  under ThreadSanitizer).

## Wakeup

After a batch of `push`es, the extension posts `DarwinSignal.liveDataAvailable`. The app
registers a `CFNotificationCenter` Darwin observer that schedules a `drain` on a background
task and then hands parsed records to the `@MainActor` view models. The notification is
coalesced — many pushes, one wakeup — so it never becomes a per-packet cost.

The consuming side of all this is the **live-feed reader**, specified in
[`app-services.md`](app-services.md): `LiveFeedReader` (an `actor`, so the SPSC contract holds by
isolation), the `LiveFeedWakeup` seam over the observer above, and the pure core that turns a
`PackedPacketMeta` into something a view can draw. Note that because the producer **recreates** the
ring file on every session, a consumer mapped against the previous one stays silently alive: the
reader exposes `reattach()` for that, and closing the hole properly (not truncating, or a generation
counter in the header) belongs here, in `Shared/IPC`.

## The durable contract: user settings (M9)

The ring carries what is happening and the control channel carries a gesture; **`AppSettings` carries
what the user decided.** It is the third cross-process contract in `Shared` and the only durable one: the
app writes it when a setting is touched and the extension reads it in `startTunnel`, so a choice survives
the extension dying and the device being switched off. The control channel is the other half and does
not replace it — it applies a change to a session already running, and a command lost to a race with
`stopTunnel` must not leave the setting unsaved.

```swift
public enum CaptureDetail: String, Codable, Sendable, CaseIterable {
    case metadataOnly, fullPayload
    public var snaplen: UInt32          // 128 / 262 144
}

public struct AppSettings: Codable, Sendable, Equatable {
    public var tlsInspectionEnabled: Bool          // false: opt-in (ADR 0003)
    public var captureEnabled: Bool                // true
    public var captureDetail: CaptureDetail        // fullPayload
    public var retention: RetentionSettings        // app-services.md
    public static let `default`: AppSettings
}

public struct SettingsStore: Sendable {
    public init(appGroupID: String = AppGroup.identifier)
    public init(reading: @escaping @Sendable () throws -> Data?,
                writing: @escaping @Sendable (Data) throws -> Void)   // la costura
    public func load() throws -> AppSettings
    public func save(_ settings: AppSettings) throws
}
```

The backing store is the App Group's `UserDefaults`, which is the mechanism Apple documents for exactly
this. Four decisions:

- **One value, not a key per setting.** The whole `AppSettings` goes in as one JSON blob, so a reader can
  never see half a write — the new setting next to the old one — and the format has a single version.
- **Decoding is tolerant field by field.** A field that is missing or unrecognised falls back to its
  factory value and the others are kept. These settings will grow (M10 brings the CA flow), and with
  `Codable`'s strict decoding adding one would leave the stored blob undecodable, wiping every choice the
  user had made. What *is* a visible error is a blob that is not even JSON: `load()` throws
  `corruptData`, and "nothing stored" stays distinct from "I cannot tell where to look"
  (`containerUnavailable`) — the first is a fresh install, the second is a missing entitlement.
- **The extension falls back to the factory settings and still starts.** Refusing the user a tunnel over
  a corrupt preferences blob would be a punishment out of all proportion. That is not swallowed in
  silence, and the reason is structural: the app reads the *same* store, gets the same `corruptData`, and
  reports it on the Settings screen — where there is somebody to tell, and where the next write repairs it.
- **The extension reads it once per session.** `snaplen` in particular *has* to work that way: it lives
  in the `.pcap` global header, so it belongs to the file and not to the record, and changing it means
  opening a new file — a record longer than its own file's header declares reads as corrupt
  ([`pcap.md`](pcap.md)). Applying capture detail to a live session therefore has to rotate.

## Lifecycle and safety

- The **producer** creates and sizes the file and (re)initializes the header on start — a fresh
  tunnel session begins with `head`/`tail`/`dropped` at 0. The **consumer** opens the existing file
  and reads its geometry from the header, rejecting an incompatible layout with `.badHeader`
  (`magic`/`version`/size guarded). Init is serialized with `flock` against a concurrent open.
- Both sides `munmap` and close on teardown (`stopTunnel` / app background) — no reliance on
  process death.
- The ring holds only compact metadata, never payload; payload lives in pcap on disk.

## Tests (M5)

- Producer→consumer round-trip over a temp-file-backed ring; N pushed, N−dropped drained, in
  order.
- Overflow: fill the ring, confirm `dropped` increments and no unread slot is clobbered.
- Header validation: a bad `magic`/`version` is rejected/recreated.
- Stress loop (tight push/drain on two queues) shows no torn `PackedPacketMeta`.
