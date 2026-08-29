# Spec — decrypted-content store (`Shared/Plaintext`)

Where the plaintext that TLS inspection produces is kept. It is the second piece of TLS
inspection: the termination built in the first piece decrypts and, until this existed, threw every
byte away — so inspection had nothing to show. The seam it plugs into is `TLSTerminationConnection`'s optional `plaintext` sink
([`relay-and-tls.md`](relay-and-tls.md#the-termination-engine)).

**Status (2026-08-13):** piece 2 is **done**, and so is everything around it. The store half (format,
writer, per-flow budget), the **index** (schema `v5` + `FlowStore`'s plaintext half), the settings the
decision needs (ADR 0007), the **wiring** — with persistence switched on, a decrypted chunk travels
from the termination to its file and its index row —, the retention that takes it away again (expired
rows pruned, orphaned files deleted, the fixed ceiling enforced), the **Settings section** that makes
the switch reachable, the **way back** (`PlaintextLibrary`) and the **screen** that reads it
([`../ux/screens.md`](../ux/screens.md), *Decrypted content*). All four pieces of inspection are
complete.

## Why not a `.pcap`

Because what comes out of a termination is not a datagram. It is a slice of an already-reassembled,
already-decrypted byte stream, and a `.pcap` file declares `LINKTYPE_RAW` — every record in it is
read as a bare IP packet ([`pcap.md`](pcap.md)). Putting plaintext there would make every reader,
including this app's own packet screen, lie about what it is showing. The two artifacts also have
opposite privacy weights and belong under separate retention: the capture holds what travelled
(encrypted, as it travelled), and this holds what was inside.

So: a directory of its own (`Plaintext/` in the App Group container), a format of its own (`.tvpt`),
and the same architecture as everything else that stores bytes here — **bytes in rotating files,
metadata in SQLite**.

## Format

Little-endian everywhere and explicit, like `PcapFormat`: nothing depends on host endianness, so the
output is byte-deterministic and assertable in a test. Writing and reading are one truth
(`PlaintextFormat`), and it lives in `Shared` because the extension writes and the **app reads**.

### Global header (16 bytes, once per file)

| Offset | Size | Field | Value |
|--------|------|-------|-------|
| 0 | 4 | `magic` | `0x54565054` — `TVPT` |
| 4 | 2 | `version_major` | 1 |
| 6 | 2 | `version_minor` | 0 |
| 8 | 4 | `max_record_bytes` | the per-record ceiling of this file |
| 12 | 4 | reserved | 0 |

`max_record_bytes` is this format's `snaplen`, and it is here for the same reason: it bounds a read
**before** anything is allocated. Being a property of the file, changing it would mean rotating.

### Record header (32 bytes, before each chunk)

| Offset | Size | Field | Notes |
|--------|------|-------|-------|
| 0 | 4 | `magic` | `0x54565052` — `TVPR` |
| 4 | 8 | `stream` | which conversation this chunk belongs to |
| 12 | 8 | `timestamp` | ns **since the epoch**, signed |
| 20 | 4 | `stored_length` | bytes actually kept |
| 24 | 4 | `original_length` | bytes the chunk carried |
| 28 | 1 | `direction` | `Direction.rawValue` (0 outbound, 1 inbound) |
| 29 | 3 | padding | 0 |

Then `stored_length` bytes of content.

Three fields carry decisions:

- **`stream`, because one file interleaves many conversations.** The writer is one and it streams
  (the extension's memory budget forbids grouping by flow in RAM), so records from different flows
  land next to each other. `stream` is the only thing that says which is which when the file is read
  straight through, without the database. It is *not* the history row id — that does not exist yet
  when the byte is written; it is assigned by the batched flush.
- **`timestamp` is absolute, not the raw monotonic stamp.** That is the lesson of the store's v2
  migration ([`persistence.md`](persistence.md)): these files outlive the session that wrote them,
  and an instant that cannot be dated after a reboot orders nothing.
- **`stored_length < original_length` is exactly "truncated"**, the same convention as
  `incl_len < orig_len` in a `.pcap`, and the only way the screen can say it is not showing
  everything.

The **record magic** exists so that a stored offset can be *validated* before anything is read. Without
it a stale offset would hand back another conversation's bytes interpreted as this one's — precisely
what the file+offset pair exists to prevent (the lesson the packet screen learned with `orig_len`).

### File identity

`plaintext-<sequence>-<yyyyMMdd-HHmmss>.tvpt`, six zero-padded digits so alphabetical order is
chronological. The sequence is the file's identity — what `PlaintextLocation.fileSequence` stores —
and it **does not restart per session**: a new writer starts one above the highest in the directory
*and* the highest the index already references. The extension is deliberately not `.pcap`: these
files are not captures and cannot be opened with Wireshark, and a borrowed extension would invite
trying.

## Interface

```swift
public actor PlaintextWriter {                                   // Shared/Plaintext
    public struct Config: Sendable {
        public var directory: URL
        public var maxRecordBytes: UInt32          // per-record ceiling (this format's snaplen)
        public var maxFileBytes: UInt64            // rotation threshold
        public var highestReferencedSequence: UInt32?
        public var highestReferencedStream: UInt64?
    }

    public enum PlaintextWriteError: Error, Sendable, Equatable {
        case openFailed, writeFailed, sequenceExhausted, closed
    }

    public init(config: Config)                    // touches no disk

    /// One per inspected flow, never per chunk: it is what pairs a flow's scattered records.
    public func openStream() -> UInt64

    /// Writes a chunk and returns where it landed; `nil` when there was nothing to store.
    @discardableResult
    public func write(_ plaintext: Data, stream: UInt64, direction: Direction, timestamp: Int64)
        throws -> PlaintextLocation?

    public func rotate() throws
    public func flush() throws
    public func close()
    public func files() -> [URL]
    public var currentFileSequence: UInt32? { get }
}

public struct PlaintextLocation: Sendable, Hashable, Codable {
    public let fileSequence: UInt32
    public let recordOffset: UInt64                // never 0: the global header comes first
}
```

Three differences from `PcapWriter`, all deliberate:

1. **No file exists until something is decrypted.** The writer opens lazily, so a tunnel that never
   inspects leaves no artifact on disk — nothing to delete, explain or export by accident. Capturing
   is the normal case and may open eagerly; decrypting is the exception the user switches on.
2. **`rotate()` does not open the next file**, for the same reason: rotating without writing after it
   would leave an empty file behind.
3. **`currentFileSequence` is optional**, because "nothing open" is a real state — retention needs it
   to know what it must not delete.

## What bounds it

Decrypted content is the fastest-growing and most sensitive thing this product can write, so it is
bounded twice, in two different places:

- **Per record**, by the writer (`maxRecordBytes`, default 64 KiB). A file-level property, in the
  header, so a reader can bound its allocation.
- **Per flow and per direction**, before the bytes ever reach the writer (`PlaintextBudget`, default
  64 KiB per direction). Two budgets and not one because the split is asymmetric: a request is
  hundreds of bytes and its response can be megabytes, so a single budget would be eaten by the
  response and the following requests — what actually explains the connection — would get no room.

**It is the beginning that is kept.** When the budget runs out, storing stops; nothing old is dropped
to make room. The start of a conversation is what identifies it (method, path, headers, status), and a
sliding window would leave the tail of a download with nothing to explain it. What did not fit is
counted (`PlaintextTruncation`), so the screen can say "the first 64 KB of 3.2 MB" instead of a
vague "there is more".

A budget of 0 is valid and means "keep nothing", which is what lets persistence be switched off
without touching the path the bytes travel.

## The index

The rows that say which flow a record belongs to. Schema `v5` ([`persistence.md`](persistence.md)),
one row per chunk: `flow_id`, `ts`, `direction`, `stream`, and the `PlaintextLocation` split into
`file_seq` + `record_offset`, plus both lengths.

Three things about it are decisions and not layout:

- **It is a table, not a column on `packets`.** A plaintext chunk is not a packet: it comes off an
  already-reassembled, already-decrypted stream, so it has no 1:1 correspondence with any datagram —
  one record can span several segments, and a retransmitted segment produces none. Hanging it off a
  packet row would mean picking one arbitrarily.
- **It is written batched, at flush.** An insert per chunk on the hot path is forbidden for the same
  reason it is for packets — and besides, the flow's row id *only exists* at flush (`upsertFlow`
  returns it). That is what fixes where the resolution happens: `PacketPipeline`, which already owns
  both the flow table and the store, and already accumulates per `FlowKey` exactly this way.
- **Its expiry is its own.** `prunePlaintext(before:)` deletes decrypted content without touching
  flows or packets, because it expires *sooner* than the history containing it (ADR 0007): a flow
  from three days ago stays in the Timeline with its byte counts while what it said inside is gone.
  The cascade is the cheap half of the same rule — deleting a flow takes its plaintext with it — and
  `clearPlaintext()` is the standalone deletion the ADR asks for.

Files outlive rows, so after pruning, `referencedPlaintextFileSequences()` says which files still
serve a purpose; the rest are orphans and are exactly what the sweep deletes from disk.

## What the user decides (ADR 0007)

- **`AppSettings.plaintextPersistenceEnabled`**, off by default *even when inspection is on*:
  inspecting and recording what was inspected are two acts, and only the first is implied by turning
  inspection on.
- **`RetentionSettings.maxPlaintextAge`** — `oneHour` / `oneDay` / `oneWeek`, defaulting to one day
  against the captures' week. There is deliberately **no `unlimited`**.
- **`RetentionSettings.plaintextByteCeiling`** — a fixed ceiling the user cannot raise, applied by
  the same sweep. Not a setting: the per-flow budget already bounds the rate, so a second knob would
  mostly be a number to understand in order to ignore.

## The wiring

How a chunk gets from the termination to the two places it lives ([`relay-and-tls.md`](relay-and-tls.md#implemented-so-far-2026-08-13--the-wiring-piece-2-done-)):

```swift
public protocol PlaintextObserving: Sendable {     // PacketTunnel/Relay — the relay knows the FlowKey
    func observe(plaintext: Data, direction: Direction, for key: FlowKey) async
}

public protocol PlaintextSink: Sendable {          // PacketTunnel/Pipeline — where the bytes are written
    func openStream() async -> UInt64
    func write(_ plaintext: Data, stream: UInt64, direction: Direction, timestamp: Int64)
        async throws -> PlaintextLocation?
    func flush() async throws
}
```

Four things about it are decisions:

- **The switch is applied by not copying.** The relay hands a termination its sink only when
  persistence is on, so with it off nothing is copied — not "copied and dropped". Turning it off
  applies immediately (the queue re-checks), turning it on applies to the next flow.
- **A serial bounded queue** carries chunks into the pipeline's actor, because the chunks *are* the
  conversation and unordered delivery would store something nobody wrote. Full, it drops the newest
  and counts it.
- **The pipeline refuses to write a chunk it cannot index.** A chunk whose flow the table no longer
  holds is dropped *before* touching the disk: bytes no row points at cannot be read back and cannot
  be swept.
- **One anchor, two datings.** The file gets the absolute instant, the row the monotonic one, both
  converted with the session anchor the provider now shares with the store.

## The sweep

What makes ADR 0007 a behaviour rather than a stored preference. It lives in
[`Shared/Retention`](../../Shared/Retention) beside the capture one, and it is **separate from it**
on purpose: capture caps are the user's and can be removed, decrypted content always expires, so
sharing a method would have tied the sweep to the `isUnlimited` shortcut that must never apply here.

```swift
public enum PlaintextRetentionPlanner {                 // who goes, before anything is touched
    public static func plan(files: [PlaintextFileInfo], referenced: Set<UInt32>,
                            openSequence: UInt32?, ceiling: UInt64) -> PlaintextSweepPlan
    public static func openSequence(files: [PlaintextFileInfo], isMonitoring: Bool) -> UInt32?
}

public enum PlaintextRetention {                        // and what actually happened
    public static func sweep(_ settings: RetentionSettings, directory: URL, openSequence: UInt32?,
                             now: Date, ceiling: UInt64,
                             openingHistory: @Sendable () throws -> FlowStore) async
        -> PlaintextSweepOutcome
}
```

Three steps, and **the order is the load-bearing part**:

1. **Prune the index by age.** A chunk's instant lives in its row, so expiry is applied there and not
   to the file: one 16 MB file mixes conversations hours apart, and deleting it by its own date would
   take content from a minute ago with it.
2. **Ask which sequences are still referenced** — *after* pruning, because an orphan is precisely the
   file the prune just left without rows. Asking first would preserve exactly what expired.
3. **Delete the orphans, then apply the ceiling** if what remains still exceeds it, oldest first. A
   ceiling victim still had live rows, so **its rows go with it**: bytes no longer on disk must not
   keep counting as stored content, and a row pointing at a missing file would offer to open nothing.

Four more decisions:

- **The open file is never deleted**, and which one it is gets **deduced** from the listing (the
  newest, while monitoring) even in the extension, which knows the exact answer. Not an oversight:
  the writer releases its file on rotation and opens the next only when there is something to put in
  it, so right after rotating "nothing is open" is true *and* the just-closed file is the one most
  likely to hold chunks the pipeline has not indexed yet.
- **An index that cannot be opened stops the sweep entirely.** Without it an orphan cannot be told
  from a live file, and deleting on a hunch would take content the user can still read.
- **A file that will not delete keeps its index.** It is still readable, and dropping its rows would
  turn it into space nobody knows how to sweep.
- **It never throws.** A half-done sweep is a result, like the capture retention's: what *was* freed
  still has to be counted (`PlaintextSweepOutcome`, and `PipelineStats.plaintextChunksExpired` /
  `plaintextFilesReclaimed` for the side with nobody watching).

Where it runs: the extension on every change of the open file — **including the change to "none"**,
which is a whole file having just closed — and **once when the session starts**, because what was
written yesterday expires even if today decrypts nothing; and the app whenever Settings applies the
caps, plus after *delete everything*, which without it would leave on disk the most sensitive thing
this product ever stores.

## The screen (2026-08-13)

Where those three decisions are made: a *Decrypted content* section in Settings, directly under
*Secure traffic* ([`../ux/screens.md`](../ux/screens.md#settings)). It adds no policy — the switch,
the ages and the ceiling are the ADR's — and one behaviour of its own: **deleting on demand is
`FlowStore.clearPlaintext` followed by a sweep**, because the first empties the index without
touching a file and the second only removes what nothing references, so either half alone would
leave the bytes on disk or leave rows pointing at nothing. `StorageManager.clearPlaintext` is that
pair, and what survives it — the file the extension is writing — is **measured** rather than assumed,
so the screen can say it instead of implying everything went. The storage block counts the `.tvpt`
files as a third row and inside its total.

## Reading it back (2026-08-13)

The first half of piece 4, and the only half that is about bytes: `PlaintextLibrary`
([`app-services.md`](app-services.md#plaintext-library)) resolves `fileSequence` → URL, seeks to
`recordOffset`, and decodes — three short reads, `stored_length` bounded against the file's
`max_record_bytes` before any memory is reserved, so a 16 MB file never gets loaded to show one turn
of a conversation. It is the mirror of `CaptureLibrary.record(at:)` and shares its shape (a stateless
`actor`, the directory resolved per call because the writer is another process), but **not its
scope**: it only reads. Listing the files is already `PlaintextDirectory`'s job for the sweep and for
the storage figure, and deleting them belongs to retention — the ADR gives the user a gesture that
takes *everything*, not a screen of files to name.

Two things are its own, and both come from what this file holds:

- **It is entered through the index row, never through a bare location.** Validating that the record
  found is the record wanted needs the `stream` and the two lengths the row carries, and an API that
  took only a position would leave that check to the caller — which is exactly how one connection's
  decrypted content ends up under another's header. That is the `stream` field of the format finally
  earning its place: a stale location resolves to a legible record belonging to *someone else*, and
  `recordMismatch` says so instead of returning it. The timestamp is deliberately **not** compared:
  the row's is stored through the store and the file's is written raw, and although both come from one
  anchor today, requiring them to be identical would tie the reader to how they were written.
- **A missing file is `notFound`, not a breakage** — and here that matters far more than it does for
  captures: decrypted content expires on its own short schedule (ADR 0007), so a connection from the
  day before yesterday keeps its history row long after its bytes were swept. The screen has to be
  able to say that without looking broken.

The rows themselves come from `HistoryReader.plaintext(forFlow:)`, capped by its own
`HistoryPolicy.plaintextChunksPerFlow` (separate from the packet cap: two lists on one screen should
not move together), and they arrive **in conversation order** — the index orders by timestamp, which
is the only place the two directions share a rule, because on disk they are interleaved with each
other and with other flows. An empty list means two things at once, "never inspected" and "already
expired", and telling them apart is the screen's job: it has the flow's `tlsStatus` in front of it.

## Built on top of this (2026-08-13) — the screen

The rest of piece 4 is done: `ConversationPresentation` and friends read these files back
([`../ux/screens.md`](../ux/screens.md), *Decrypted content*). Two things it decided that this format's
readers should know:

- **A turn is a maximal run of consecutive records in the same direction.** A record is not a turn —
  they come off the termination's two legs as they arrive — so the screen groups them and the only
  boundary is the change of side.
- **Nothing is ever claimed about the whole connection's size.** "The first 64 KB of 3.2 MB" would need
  a per-flow figure `v5` has no column for: once the budget is exhausted the remaining chunks leave no
  row at all, so the only derivable figure is a lower bound. What is said instead is per record (both
  lengths are exact) plus the fact that follows from the budget cutting before the write: **a truncated
  record is the last one of its direction**, so from it onward that side stopped being recorded. If the
  real figure is ever wanted, it is a `v6` with a per-flow-and-direction counter written by
  `PlaintextBudget`, not a cleverer query.

## Still to build

Nothing of this spec. The one open question is device-only and belongs to the engine above it: whether
a network extension may bind the loopback listener `LoopbackTLSServerSession` needs.

## Tests (115)

`PlaintextFormatTests` — both headers byte-exact, round-trips, truncation told by the two lengths, a
negative timestamp surviving the trip, and the five rejections (short data, foreign magic, another
major version, an offset that is not a record start, an unknown direction), plus file-name identity and
the foreign names that must not get in (a `.pcap` among them).

`PlaintextWriterTests` — no file until there is content, an empty chunk storing nothing, the location
each write returns, a location leading back to **its own** record among interleaved conversations, the
per-record cut, stream ids handed out once each and starting above what the index references, rotation
by size losing and duplicating nothing, manual rotation leaving no empty file, sequences starting above
both the disk and the index, the typed errors, and the streaming invariant asserted by exact file size.

`PlaintextBudgetTests` — a chunk that fits and one that fits in part, each direction with its own
budget, exhaustion needing both, the zero budget, the beginning being what is kept, and what did not
fit being counted.

`PipelinePlaintextTests` and `RelayPlaintextTests` — the wiring: the chunk written and indexed against
its flow with its location intact, one conversation per flow, the two datings from one anchor, the
budget keeping the beginning and telling the truncation, an exhausted budget not touching the disk, a
direction not eating the other's room, a closed flow releasing its budget, a chunk without a flow
refused, a write failure stopping only this, batching at flush — and on the relay side no sink without
permission, chunks tagged with their flow, order preserved, switching off stopping recording at once,
and the queue drained on close.

`PlaintextIndexTests` — chunks coming back dated and in order with their location, timestamps stored
absolute, the limit, chunks belonging to their flow, what the writer asks at startup, the referenced
sequences, and the retention promises: pruning plaintext leaving the flow and its packets alone,
dropping the rows of the files the ceiling deleted, clearing it keeping the history and the capture
links, the cascade, and an older database gaining the index without losing anything.

`PlaintextLibraryTests` — the way back, against files a **real** writer wrote: a location leading to
its own bytes with its direction and its absolute date, one leading to its own record among
interleaved conversations, the file sequence separating two records at the same offset, a truncated
record coming back as its beginning plus both lengths, a swept file being `notFound` rather than a
fault, an unresolvable container being its own failure, and the five refusals — an offset inside the
file header, an offset that is not a record start, a record belonging to **another** conversation, a
record whose lengths disagree with the row, and (on files no writer could produce) a foreign magic, a
record claiming more than the file allows, and one cut short on disk. `HistoryReaderTests` adds the
index half: conversation order with the locations intact, its own cap, and an empty list for a flow
that has none.

`PlaintextRetentionPlannerTests` and `PlaintextRetentionTests` — the plan (orphans, the ceiling
oldest-first and what its rows cost, the ceiling measured over what the orphans already freed, the
open file spared, the ceiling that cannot be met, the deduction of which file is open) and the sweep
against real files and a real store (an expired chunk orphaning its file, half a file expiring not
deleting it, a live file surviving, a missing directory being quiet, an unreachable index deleting
nothing, and a file that will not delete keeping its index). `StorageManagerTests` and
`SettingsViewModelTests` add the trap they exist for: decrypted content expiring **with both capture
caps removed**. `AppSettingsTests` adds the ADR's own: the switch off by default even
with inspection on, decrypted content expiring sooner, `unlimited` being absent, the fixed ceiling,
and a blob written before the decision not starting to record.
