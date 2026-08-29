# Spec — pcap capture writer (`Shared/Capture`)

Streams captured packets to standard libpcap files on disk so they open directly in Wireshark
and `tcpdump`. Streaming is mandatory: a long capture must never be held in memory (the
extension budget forbids it).

Both halves live in [`../../Shared/Capture`](../../Shared/Capture). The **format** (`PcapFormat`)
moved there in M9: the app parses these files back to show a packet's bytes, so writing a header and
reading it are one truth. The **writer** (`PcapWriter`) followed in M11, when the synthetic-capture
seeder ([`../../Shared/Fixtures`](../../Shared/Fixtures)) had to write `.pcap` files from the app —
and had to write them with *this* writer, so that the offset stored with a seeded packet is produced
by the same code that produces a real one's.

## Format (classic libpcap)

Because the extension reads **raw IP packets** (no Ethernet), the link-layer type is
`LINKTYPE_RAW` (DLT_RAW, value `101`): each record is a bare IP packet.

### Global header (24 bytes, written once per file)

| Field | Size | Value |
|-------|------|-------|
| magic_number | u32 | `0xa1b2c3d4` (microsecond ts) |
| version_major | u16 | 2 |
| version_minor | u16 | 4 |
| thiszone | i32 | 0 |
| sigfigs | u32 | 0 |
| snaplen | u32 | e.g. 262144 |
| network | u32 | `101` (LINKTYPE_RAW) |

### Per-packet record header (16 bytes, before each packet)

| Field | Size | Value |
|-------|------|-------|
| ts_sec | u32 | capture time, seconds |
| ts_usec | u32 | microseconds |
| incl_len | u32 | bytes captured (≤ snaplen) |
| orig_len | u32 | original packet length |

Then `incl_len` bytes of the raw IP packet.

> Endianness is fixed by the magic number; write native little-endian on-device and set the
> standard magic accordingly.

## Interface

```swift
public actor PcapWriter {
    public struct Config: Sendable {
        public var directory: URL
        public var snaplen: UInt32          // bytes captured per packet
        public var maxFileBytes: UInt64     // rotation threshold
        /// Mayor secuencia que el historial ya referencia (`FlowStore.highestCaptureFileSequence()`).
        public var highestReferencedSequence: UInt32?
    }

    public enum PcapError: Error, Sendable { case openFailed, writeFailed, sequenceExhausted }

    public init(config: Config) throws       // opens the first file, writes global header

    /// Escribe un paquete y devuelve dónde quedó su registro (para `PacketMeta.capture`).
    /// `timestamp` es **nanosegundos desde el epoch** (`MonotonicAnchor.nanosecondsSince1970`).
    @discardableResult
    public func write(packet: Data, originalLength: Int, timestamp: Int64) throws -> CaptureLocation

    /// Cierra el fichero actual y abre uno nuevo (rotación manual o por tamaño).
    public func rotate() throws

    /// Cambia cuánto se guarda de cada paquete, **rotando**: el `snaplen` vive en la cabecera global,
    /// así que el detalle nuevo solo puede empezar en un fichero nuevo. No hace nada si ya es el que hay.
    public func setSnaplen(_ snaplen: UInt32) throws

    /// Fuerza el vaciado a disco (fsync) del fichero actual **sin** cerrarlo: un writer en
    /// streaming necesita seguir escribiendo tras un flush periódico. El cierre definitivo lo
    /// hacen `rotate()` y `close()`.
    public func flush() throws
    public func close()

    /// Ficheros de captura existentes, para exportar/compartir/borrar desde la app.
    public func captureFiles() -> [URL]

    /// Secuencia del fichero que se está escribiendo ahora mismo.
    public var currentFileSequence: UInt32 { get }
}
```

## File identity

Files are named `tunnelvision-<sequence>-<yyyyMMdd-HHmmss>.pcap`. The sequence is zero-padded to six
digits so alphabetical order is chronological order, and it is the file's **identity**: it is what
`CaptureLocation.fileSequence` stores next to every packet, and what the app resolves back to a URL.
Formatting and parsing it live together in `Shared/Models` (`CaptureFileName`, `CaptureDirectory`)
because the extension writes the name and the app reads it.

The sequence **does not restart per session**. A new writer starts one above the highest it can see —
the highest in the directory *and* the highest the history already references (`Config.highestReferencedSequence`,
from `FlowStore.highestCaptureFileSequence()`). Restarting at 0 would make yesterday's stored offset
point into today's file; ignoring the history would let a deleted file's number be handed to a new
file while its packets are still stored. `sequenceExhausted` models the (unreachable, 4·10⁹ files)
end of the `UInt32` space instead of wrapping around and lying.

## Behaviour

- **Streaming:** hold only a small write buffer; append each record and let the OS flush. Never
  keep past records resident.
- **Rotation:** when the current file passes `maxFileBytes`, `rotate()` closes it and starts a
  new one (timestamped filename). Keeps individual files shareable and bounds a single file.
- **snaplen:** for metadata-heavy use, capturing full payload may be unnecessary; `snaplen`
  caps per-packet bytes (Wireshark shows truncation correctly via `incl_len < orig_len`). It is a
  property of the **file**, not of a record, so changing it mid-session (`setSnaplen`, M11) rotates:
  applying it to the open file would leave records longer than their own header declares, and a reader
  that bounds `incl_len` against that `snaplen` — including this app's own packet screen — would read
  the file as corrupt.
- **CaptureLocation:** the returned (file, offset) pair lets the inspector jump from a
  `PacketMeta`/flow row to the exact bytes when the user opens a packet. The offset alone would not:
  rotation restarts offsets, so the same number means a different record in every file.
- **Errors:** typed `PcapError`; a write failure is surfaced (disk full → stop capturing and
  tell the user), never silently swallowed. The file handle is closed explicitly on teardown.

## Reading one record back (M9)

The app never reads a capture whole — a 64 MB file must not be loaded to show one packet. `PcapFormat`
therefore parses as well as it writes, and the app's side of it is one method on `CaptureLibrary`
([`app-services.md`](app-services.md)):

```swift
public enum PcapFormat {
    public struct GlobalHeader: Sendable, Equatable { public let snaplen: UInt32; public let linkType: UInt32 }
    public struct RecordHeader: Sendable, Equatable {
        public let tsSec: UInt32; public let tsUsec: UInt32
        public let inclLen: UInt32; public let origLen: UInt32
    }
    public enum FormatError: Error, Sendable, Equatable {
        case shortHeader(expected: Int, actual: Int)
        case unknownMagic(UInt32)
        case unsupportedLinkType(UInt32)
    }
    public static func globalHeader(parsing data: Data) throws -> GlobalHeader
    public static func recordHeader(parsing data: Data) throws -> RecordHeader
}
```

- **Three short seeks, never a scan:** the global header (which yields `snaplen`), the record header at
  `CaptureLocation.recordOffset`, and `incl_len` bytes after it.
- **`incl_len` is bounded against that `snaplen` before any allocation.** A corrupt or foreign file
  must not be able to ask for memory.
- **The parsers reject rather than adapt.** The only producer of these files is `PcapWriter`, so
  another magic (including the byte-swapped one, which a big-endian writer would leave) or another
  link type means the file is not what the caller thinks it is. Reading Ethernet records as bare IP
  datagrams would give a false reading of every byte on screen.
- **A record header does not judge its own length**; only the reader knows the file's `snaplen`.
- **`ts_sec`/`ts_usec` are wall clock**, decomposed from nanoseconds since the epoch. They used to
  decompose the *monotonic* stamp of the hot path, which put every exported capture in **1970** when
  opened in Wireshark (the numbers were device uptime): the deltas between packets were right and
  every absolute date was wrong. The conversion is the caller's, not the writer's — the pipeline and
  the seeder hold the session's `MonotonicAnchor`, exactly as they already did for decrypted content.
  The app still dates a packet from the **store**, which is the row it navigates by; the record's
  timestamp exists so the exported file stands on its own outside this app.

## Export

The app shares capture files via the share sheet as `.pcap`. Provide a per-flow export too
(filter records by flow) and a JSON flow-list export. Exports never leave the device except
through the user's explicit share action.

## Tests (M6)

- Byte-exact global + record headers for a known packet; magic and `LINKTYPE_RAW` correct.
- Round-trip: write packets, read the file back with a minimal reader (and `tcpdump -r` in CI
  when available) — packets match.
- Rotation at the size threshold produces valid independent files.
- A long synthetic capture keeps peak memory flat (one record in flight).
- `snaplen` truncation sets `incl_len`/`orig_len` correctly.
- Every returned location resolves to an existing file and to the bytes it describes; a second
  writer over the same directory continues the sequence instead of restarting (M9).
- Parsing undoes writing for both headers, including from a slice that does not start at index 0
  (a record read by offset is exactly that); a short header, a foreign magic and another link type are
  each rejected with their own case; the same offset in two files resolves to different bytes (M9).
- A present-day instant survives the round trip into `ts_sec`/`ts_usec`, and an instant *before* the
  epoch is clamped to it instead of wrapping into 2106 (both fields are unsigned). Upstream, the
  pipeline stamps the capture in wall clock and keeps the spacing between packets exact, and a seeded
  capture is dated by the fixture's anchor — the three of them are what keeps an exported file out
  of 1970.
