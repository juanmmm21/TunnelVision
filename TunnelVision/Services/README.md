# TunnelVision/Services

App-side services: tunnel control via `NETunnelProviderManager` (install/start/stop, send
control messages), the ring-buffer live-feed reader, read access to the `FlowStore`, the capture
directory the extension writes its `.pcap` files into, and the retention that cuts both of those down.

**Tunnel control (M9, done).** Same pure-core/injected-shell split as the extension:
`TunnelState.swift` holds the decisions (`TunnelStatus` — a Foundation-only mirror of `NEVPNStatus` —
plus `TunnelState`, `TunnelControlError` and `TunnelStatePolicy`), `TunnelConfiguration` describes the
VPN profile, `TunnelProviderManaging` is the seam, and `TunnelController` (`@MainActor`,
`@Observable`) is what a view talks to. `NETunnelProviderManagerAdapter` is the production conformer —
the only file here that imports NetworkExtension, excluded from the test target and validated by
compilation.

**Live-feed reader (M9, done).** The app's side of the ring buffer. `LiveFeed.swift` and
`ThroughputWindow.swift` are the pure core — they add the three things `PackedPacketMeta` deliberately
does not carry: wall-clock time (`MonotonicAnchor`), which endpoint is the device
(`LiveFeedAddressing`, against `TunnelAddressing.localAddresses`), and the rolling window the chart
plots. `LiveFeedReader` is an `actor` (the ring's SPSC contract wants a single consuming context, and
the drain must stay off the main thread) that opens the ring lazily, drains in bounded bursts and
publishes `LiveFeedSnapshot` over an `AsyncStream`. `LiveFeedWakeup` is the seam;
`DarwinNotificationWakeup` is the production conformer, validated by compilation like the adapter.

**History reader (M9, done).** The app's side of the `FlowStore`, feeding the Timeline and the Flow
Inspector. `History.swift` is the pure core: `HistoryFlow` composes a stored row with the local/remote
split (reusing `LiveFeedAddressing`, so a flow cannot show a different host in the Timeline than in the
Dashboard), `HistoryFilter` carries the screen's four filters, `HistoryPolicy` the bounds and
`HistoryPaging` the duplicate-free page merge. `HistoryReader` is an `actor` that paginates by cursor
and chains queries until it has a full page of *matches*, capped by `maxPagesPerLoad`. There is no new
seam: `FlowStore` is already Simulator-testable, so the reader is tested against a real store over a
temp database. Refreshing is explicit — the writer is another process and SQLite does not notify
across processes.

**Timeline activity (M9, done).** `TimelineActivity.swift` is the pure core behind the Timeline's
scrub bar, and it is to the history what `ThroughputWindow` is to the live feed: fixed-width bars with
the gaps zero-filled. What differs is where the numbers come from (an aggregate query —
`FlowStore.packetCounts` — instead of an in-memory ring) and what they measure: packets, because what
the axis answers is *when there was activity*. `ActivityBar` carries its own duration and its absolute
`range`, which is exactly what gets filtered when the user taps it; `ActivityAxis` derives its span,
its busiest bar and its total rather than storing them beside the bars, so it cannot contradict them.
The bar widths come off a ladder of round durations (second to week, finest rung that fits within the
bar cap) because a selectable interval has to be readable — and the ladder carries its intermediate
rungs (30 s, 30 min, 2 h, 4 h, 12 h) because the cap is small now and a ladder that jumps from an hour
to six answers a six-hour history with two bars. **The cap is no longer `HistoryPolicy.axisBars`**: that
is only its ceiling. How many intervals the axis really offers is a question of the screen's *width*,
because an interval is picked with a finger and owes the HIG's 44 pt (`ScrubCapacity`), so the screen
measures itself and tells the reader (`setAxisCapacity`) — which keeps `canZoom` and `activity` reading
one number, as they always did.
`HistoryReader.activity(in:)` is the query half; it throws, like `packets(forFlow:)`, and it honours
**no** filter — the counts cover everything recorded, which the screen says out loud. Given a range it
draws the same aggregate inside that stretch, which is what lets the bar **zoom in**; the range is not
clamped against what is stored, so a stretch retention took comes back at zero and the screen decides
what that means. `canZoom(into:)` says whether a bar can be entered — never a quiet one, never one
already at the finest rung — and lives on the reader because the floor follows `axisBars`.

**Capture library (M9, done).** `CaptureLibrary` is the app's side of `PcapWriter`: it lists the
capture files with their size and time (`CaptureFileInfo`) and deletes the ones the user decides to
remove. It keeps no state — the writer is another process, so a cached listing would be a directory the
extension already changed by rotating — and it resolves the App Group directory on every call rather
than storing it, which is also the seam (`init(resolvingDirectory:)`) that makes the only failure it can
have testable: on the Simulator the container resolves for any identifier, so the real "no entitlement"
case cannot be provoked there. A missing directory is an empty list, not a failure. Decisions about what
the screen shows — which file is open, what a deletion costs — live in `CapturesPresentation`
(`../Models`). It also **reads** a single record back (`record(at:)`), which is what the Flow
Inspector's packet→bytes jump needed: same directory, same seam, so it did not deserve a service of its
own. The read is three short seeks — global header, record header, `incl_len` bytes — with `incl_len`
bounded against the file's `snaplen` before any memory is reserved, so a 64 MB capture never gets
loaded to show one packet. A file the user has deleted comes back as `notFound`, which the packet
screen reads as "those bytes are gone", not as a breakage.


**Plaintext library (M8, done).** The app's side of `PlaintextWriter`, and the first half of the Flow
Inspector's decrypted content: `PlaintextLibrary` turns an index row into the bytes it names. It is the
mirror of `CaptureLibrary.record(at:)` — a stateless `actor`, the App Group directory resolved per call,
three short reads with `stored_length` bounded against the file's `max_record_bytes` before any memory
is reserved — but it **only reads**: listing is `PlaintextDirectory`'s job for the sweep and the storage
figure, and deleting belongs to retention (ADR 0007), not to a file-by-file screen. It is entered
through the row and never through a bare location, because checking that the record found is the record
wanted needs the `stream` and both lengths the row carries; a record from another conversation is
refused (`recordMismatch`) rather than shown. A file the sweep already took is `notFound`, which is the
ordinary answer here — decrypted content expires long before the history that names it.

**Storage manager (M9, done; the caps left in M11).** `Retention.swift` now holds only `StorageUsage`,
the figure Settings shows. The rule itself moved to [`Shared/Retention`](../../Shared/Retention):
`RetentionPlanner` decides *who* goes given a listing, the caps and `now`, and `CaptureRetention`
executes that plan. The move is M11's, and its reason is that until then the caps only applied with this
screen in front of the user — with the app closed and the tunnel capturing, nobody enforced them, which
is precisely when the directory grows. The extension applies them on rotation now, with **this same**
planner and executor.

`StorageManager` stays here because what is left of it is the user's: how much is used (`usage`),
clearing everything (`clearEverything`), and the app's own seams for the shared path — the listing that
may not resolve and the history that opens lazily. It exists because retention crosses both halves and
neither can do it alone: `prune(before:)`/`clearAll()` delete rows, not files, so a cleanup that only touched the
database would leave the `.pcap` files on disk and one that only deleted files would leave the history
pointing at bytes that are gone. Four decisions worth remembering: a capture is aged out by **its
successor's** creation date (a file stops being written when the next one appears, so its own date only
says when it *started*, and the newest file therefore is never aged out); the file being recorded is never
in the plan, and when that makes the size cap impossible the plan says so rather than leaving it silently
unenforced; files are deleted **before** the history is pruned, because the failure mode of that order is
one the app already explains; and it throws only when it could not even list the directory — everything
partial, including a history that would not open, comes back inside the `RetentionOutcome`.

**Flow export (M9, done).** `FlowExporter` writes the connection list as JSON for the Captures
screen's share sheet, over `HistoryReader.flowPage(limit:after:)` — a page read that carries its own
cursor and touches none of the Timeline's paging state, so exporting cannot move the list the user has
loaded. It is the first file the **app itself** generates: everything shared until now (the `.pcap`s)
already existed because the extension wrote it. That file lives in the app's temporary directory and
not in the App Group container — it is not a capture, and leaving it among them would put it in the
screen's listing and in the retention plans — and each export clears the previous one, so at most one
copy of the history sits there at a time. The document is written **in pieces** (prologue, one entry
per connection, epilogue) so a history of tens of thousands of rows never exists in memory as one
blob; the counts travel in the epilogue precisely because that is what streaming allows. A failure
halfway takes the half-written file with it: an unterminated JSON would not read as an error, it would
read as a history that ends early. The shape of an entry and the framing are `FlowExport.swift`
(`../Models`); what the screen says before sharing is `CapturesPresentation`.

**Fixture seeding (M11, Debug-only).** `FixtureSeeding` is the launch-time decision behind
`-TVSeedFixture`: whether this start seeds the synthetic capture (`Shared/Fixtures`) into the shared
container. It answers with three cases and not a `Bool`, because "not asked for" and "asked for and
refused" are different things to whoever launched the app — the second has to be said on the console.
It is refused off the Simulator: the seeder **replaces** what is there, and on a device that is its
owner's real capture, which seeding would overwrite with invented traffic for no gain (there the
extension is the writer). The whole file is behind `#if DEBUG`, so the decision does not exist in
Release at all.

**Refs:** [`../../docs/spec/app-services.md`](../../docs/spec/app-services.md),
[`../../docs/spec/tunnel-provider.md`](../../docs/spec/tunnel-provider.md),
[`../../docs/spec/ipc.md`](../../docs/spec/ipc.md)
