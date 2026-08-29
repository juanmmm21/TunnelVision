# Spec — App services (`TunnelVision/Services`)

The app-side half of the two-process design (M9). Seven services sit between the SwiftUI view
models and the world:

| Service | Talks to | Status |
|---------|----------|--------|
| **Tunnel control** | `NETunnelProviderManager` + the control channel | specified below, implemented |
| **Live-feed reader** | the mmap ring buffer + the Darwin wakeup ([`ipc.md`](ipc.md)) | specified below, implemented |
| **History reader** | `FlowStore` ([`persistence.md`](persistence.md)) | specified below, implemented |
| **Capture library** | the capture directory in the App Group container | specified below, implemented |
| **Storage manager** | *both* of the above at once, for retention | specified below, implemented |
| **Flow export** | the history reader + a file of the app's own | specified below, implemented |
| **Certificate status** (M10) | the shared Keychain (`LocalCA`) + `SecTrust` | specified below, implemented |

The same house split as the extension: a **pure core** that holds every decision and is tested on
the Simulator, and a thin **injected shell** over the Apple framework that only does I/O and is
validated by compilation. On the extension side that pairing is `PacketPipeline`→
`PacketTunnelProvider`, `TCPRelayFlow`→`Relay`, `CertificateAuthority`→`LocalCA`,
`TLSInterceptionPolicy`→`TLSTerminationEngine`. Here it is `TunnelStatePolicy`→
`TunnelProviderManaging`, and `ThroughputWindow`/`LiveFeedAddressing`→`LiveFeedWakeup`. The history
reader is the exception that proves the rule: it has **no shell at all**, because the only thing under
it is `FlowStore`, which already runs on the Simulator; the capture library has only a sliver of one,
the closure that resolves the App Group directory.

## Tunnel control

### What the user sees

The Dashboard's monitoring control and the VPN-permission moment of
[`../ux/onboarding-and-consent.md`](../ux/onboarding-and-consent.md): priming sheet → system prompt
→ result, *never* a dead end. A denial is a state the UI must be able to render and retry from, so
it is a value in `TunnelState`, not an exception that disappears into a log.

### The pure core

`NEVPNStatus` is mirrored into a Foundation-only enum so the decision layer never imports
NetworkExtension (which would drag a device-only framework into every test):

```swift
public enum TunnelStatus: Sendable, Equatable {
    case notInstalled     // NEVPNStatus.invalid: no hay perfil guardado todavía
    case disconnected
    case connecting
    case connected
    case reasserting
    case disconnecting
}
```

`TunnelState` is what a view renders. It is deliberately *not* the same enum: it collapses the
transport detail the user does not care about and adds the outcomes NetworkExtension reports as
thrown errors rather than as status:

```swift
public enum TunnelState: Sendable, Equatable {
    case notInstalled              // invita a instalar el perfil (primer arranque)
    case off                       // instalado y parado
    case starting                  // connecting o reasserting
    case live                      // connected
    case stopping
    case failed(TunnelControlError)   // accionable: la vista ofrece reintentar
}

public enum TunnelControlError: Error, Sendable, Equatable {
    case permissionDenied            // el usuario dijo "Don't Allow" al diálogo del sistema
    case configurationFailed(String)
    case startFailed(String)
    case notInstalled                // se pidió arrancar sin perfil guardado
    case notRunning                  // canal de control sin sesión viva al otro lado
    case controlChannelFailed(String)
    case malformedResponse           // la extensión contestó algo que no es un ControlResponse
}
```

Two pure functions carry every decision:

```swift
public enum TunnelStatePolicy {
    /// Estado inicial a partir de un status recién cargado.
    public static func state(for status: TunnelStatus) -> TunnelState

    /// Estado siguiente ante un cambio de status, **conservando** un fallo visible hasta que el
    /// usuario actúe: un `.failed` no lo borra un `disconnected` (el mismo status que lo acompañó),
    /// solo un status activo o un reintento explícito.
    public static func next(from current: TunnelState, status: TunnelStatus) -> TunnelState
}

extension TunnelControlError {
    /// Clasifica un `NSError` de NetworkExtension sin importarla: la cáscara pasa dominio, código y
    /// texto. `NEVPNErrorDomain` + `configurationReadWriteFailed` (5) es lo que devuelve
    /// `saveToPreferences` cuando el usuario deniega el diálogo del sistema.
    public static func classifying(domain: String, code: Int, message: String) -> TunnelControlError
}
```

`reasserting` maps to `.starting`, not `.live`: while the tunnel re-establishes it is not carrying
traffic, and claiming "monitoring on" then would be a lie the user can catch.

### The configuration

```swift
public struct TunnelConfiguration: Sendable, Equatable {
    public var providerBundleIdentifier: String   // debe coincidir con project.yml
    public var serverAddress: String              // lo que iOS enseña en Ajustes → VPN
    public var localizedDescription: String       // el nombre del perfil en Ajustes
    public static let `default`: TunnelConfiguration
    public func validate() throws                 // TunnelControlError.configurationFailed
}
```

`serverAddress` is user-facing text, not a host: the tunnel terminates on the device, so it says so
(UX principle: no jargon, no implication that traffic leaves the device).

### The injected shell

```swift
public protocol TunnelProviderManaging: Sendable {
    func loadStatus() async throws -> TunnelStatus
    func install(_ configuration: TunnelConfiguration) async throws   // aquí pregunta iOS
    func start() async throws
    func stop() async throws
    func sendControl(_ payload: Data) async throws -> Data?
    func statusUpdates() -> AsyncStream<TunnelStatus>
}
```

Every `throws` is a `TunnelControlError` — mapping `NSError` is the shell's job, so nothing above it
ever sees an untyped error. The production conformer is `NETunnelProviderManagerAdapter`
(`loadAllFromPreferences` → `NETunnelProviderProtocol` → `saveToPreferences` →
`session.startVPNTunnel()`, plus a `NEVPNStatusDidChange` observer bridged to the stream). Like
`NetworkRelayConnection` and `PacketTunnelProvider.swift`, it is **validated by compilation only**:
a VPN profile cannot be installed from a Simulator test.

### The controller

```swift
@MainActor @Observable public final class TunnelController {
    public private(set) var state: TunnelState

    public init(manager: any TunnelProviderManaging, configuration: TunnelConfiguration = .default)

    public func refresh() async                 // estado inicial
    public func startObservingStatus()          // consume statusUpdates() hasta stopObserving
    public func stopObservingStatus()
    public func install() async                 // priming → diálogo del sistema
    public func startMonitoring() async         // install si hace falta, luego start
    public func stopMonitoring() async
    @discardableResult
    public func send(_ command: ControlCommand) async throws -> ControlResponse
}
```

The controller does **not** hold the counters. It used to (`stats` + `refreshStats()`), and since the
diagnostics screen exists (M11) they live in `DiagnosticsViewModel` instead, next to the only thing
that reads them: they are that screen's state, not the tunnel's, and keeping them here meant two
places interpreting the same reply.

The toggle actions do **not** throw: a failure becomes `state = .failed(...)` so the screen can
render it with a retry, which is exactly what the onboarding spec asks for. `send` *does* throw,
because its callers (Settings) need to react to a specific command failing.

`send` encodes with the shared codec ([`ipc.md`](ipc.md)), and a `nil` reply is reported as
`.notRunning` — a normal race between the UI and `stopTunnel`, not an error to alarm the user with.

### Tests

The controller runs on the Simulator against a scripted double of `TunnelProviderManaging`: the
mapping table exhaustively, the failure-survives-a-disconnect rule, install/start ordering, denial
and start failure, the status stream driving the state, the control round-trip through the real
codec and a malformed reply.

## Live-feed reader

### What the user sees

The Dashboard's real-time half ([`../ux/screens.md`](../ux/screens.md)): the throughput chart, the
at-a-glance counters, and the honest, subtle dropped-records indicator when the extension is shedding
records under back-pressure.

### What the ring does not carry

`PackedPacketMeta` ([`ipc.md`](ipc.md)) is deliberately minimal, so three things have to be added
before a view can render a row, and all three are pure decisions:

1. **When it happened.** `timestamp` is `CLOCK_UPTIME_RAW` nanoseconds, not an epoch. `CLOCK_UPTIME_RAW`
   measures machine uptime, so it is the *same* clock in both processes and the app can convert by
   reading it once next to the wall clock.
2. **Who the host is.** `FlowKey` is canonical (`endpointA <= endpointB`), so it cannot say which end
   is the device. The tunnel's own IPs answer it — which is why `TunnelAddressing` moved to
   `Shared/Models` and grew `localAddresses`.
3. **What the chart plots.** A rolling window of per-interval byte counts, by sense.

```swift
public struct MonotonicAnchor: Sendable, Equatable {
    public let uptimeNanoseconds: UInt64
    public let wallClock: Date
    public static func now() -> MonotonicAnchor
    public func date(forUptime nanoseconds: UInt64) -> Date
}

public struct FlowEndpoints: Sendable, Hashable { public let local: IPEndpoint; public let remote: IPEndpoint }

public enum LiveFeedAddressing {
    /// `nil` si ninguno de los dos endpoints es local: no se adivina.
    public static func endpoints(of key: FlowKey, localAddresses: Set<IPAddress>) -> FlowEndpoints?
}

public struct LivePacket: Sendable, Hashable, Identifiable {
    public let id: UInt64            // secuencia del lector; el sello no vale, se repite
    public let date: Date
    public let flowKey: FlowKey
    public let direction: Direction
    public let length: UInt32
    public let tcpFlags: TCPFlags
    public let capture: CaptureLocation?   // fichero + offset del registro, o nil si no se capturó
    public let endpoints: FlowEndpoints?
    public init(_ packed: PackedPacketMeta, sequence: UInt64, anchor: MonotonicAnchor, localAddresses: Set<IPAddress>)
}
```

The anchor is taken **once per session**, not per batch: that keeps the relative spacing between
packets exact, which is what makes the chart's shape trustworthy. The cost is that it ages when the
device sleeps (`CLOCK_UPTIME_RAW` stops while the wall clock does not), so the reader takes a fresh
one on every `start()` — the moment a tunnel session begins.

### The throughput window

```swift
public struct ThroughputSample: Sendable, Hashable, Identifiable {
    public let start: Date
    public let duration: TimeInterval
    public let bytesIn: UInt64
    public let bytesOut: UInt64
    public var bytesInPerSecond: Double { get }
    public var bytesOutPerSecond: Double { get }
}

public struct ThroughputWindow: Sendable, Equatable {
    public init(bucketDuration: TimeInterval = 1, windowDuration: TimeInterval = 60)
    public private(set) var lateRecords: UInt64
    public mutating func add(date: Date, direction: Direction, length: UInt32)
    public func samples(asOf now: Date) -> [ThroughputSample]
    public mutating func reset()
}
```

A ring of fixed-width buckets indexed by `floor(t / bucketDuration)` since the epoch: O(1) per packet,
fixed memory, and an alignment that does not depend on when the window was created (so the axis is
deterministic). Two rules carry the honesty of the chart:

- `samples(asOf:)` always returns the full width with **empty intervals zero-filled**. Without them
  Swift Charts would join two spikes with a straight line and assert traffic that never happened.
- A packet older than the window is **discarded and counted** (`lateRecords`). The test is its distance
  to the newest interval seen, not a slot collision: two indices less than one lap apart land in
  different slots, so collision alone would let half the late records through into a bucket outside
  the axis, where nobody would ever see them.

### The policy and the snapshot

```swift
public struct LiveFeedPolicy: Sendable, Equatable {
    public var recordsPerDrain: Int          // 512 — acota la copia de una pasada
    public var maxDrainsPerBurst: Int        // 8 — techo del bucle de vaciado
    public var recentPacketCapacity: Int     // 500 — el histórico es del store
    public var idlePollInterval: Duration?   // 1 s — latido; nil lo desactiva
    public var bucketDuration: TimeInterval  // 1 s
    public var windowDuration: TimeInterval  // 60 s
    public static let `default`: LiveFeedPolicy
}

public struct LiveFeedSnapshot: Sendable, Equatable {
    public var recent: [LivePacket]          // orden de llegada; invertir es de la vista
    public var throughput: [ThroughputSample]
    public var droppedRecords: UInt64        // los que descartó la extensión (back-pressure)
    public var bytesIn: UInt64
    public var bytesOut: UInt64
    public var packetCount: UInt64
    public var lateRecords: UInt64
    public var isAttached: Bool              // ¿hay ring abierto?
    public var lastAttachError: IPCError?
}
```

Every bound exists for the same reason: the ring belongs to the extension and can fill at thousands
of records per second, so the reader is bounded by construction and never grows with traffic.

### The injected shell and the reader

```swift
public protocol LiveFeedWakeup: Sendable {
    func start(onWake: @escaping @Sendable () -> Void)
    func stop()
}

public actor LiveFeedReader {
    public init(appGroupID: String = AppGroup.identifier, policy: LiveFeedPolicy = .default,
                wakeup: any LiveFeedWakeup = DarwinNotificationWakeup(), …)
    public init(fileURL: URL, policy: LiveFeedPolicy = .default, wakeup: any LiveFeedWakeup, …)

    public var snapshot: LiveFeedSnapshot { get }
    public func snapshots() -> AsyncStream<LiveFeedSnapshot>
    public func start()          // re-ancla, vacía la sesión, engancha, drena y lanza el latido
    public func stop()           // suelta el despertador y cierra el ring
    public func reattach()       // reabre tras una sesión nueva de la extensión
    @discardableResult public func drain() -> Int
}
```

It is an `actor`, not `@MainActor` like `TunnelController`: the ring's SPSC contract requires a single
consuming context — which actor isolation *is* — and [`ipc.md`](ipc.md) asks for the drain to happen
off the main thread. The `@MainActor` layer is the view model consuming `snapshots()`.

Four decisions:

- **The ring is opened lazily and retried.** The file does not exist until the extension has run once,
  which on a freshly installed app is normal, not a failure: `isAttached == false` and the UI says it
  is waiting for the tunnel. `reattach()` exists because the extension *recreates* the file on each
  session, and a mapping left over from the previous one would stay silently alive and never see a
  new record.
- **Draining loops until empty**, capped by `maxDrainsPerBurst`. The Darwin signal is coalesced and
  carries no data, so one wakeup can mean thousands of records; assuming one record per signal would
  stall the feed permanently behind the backlog.
- **`snapshots()` buffers only the newest value.** If the view falls behind the feed, the right
  behaviour is to skip intermediate snapshots and draw the last one, not to queue frames nobody will
  look at. Snapshots are published only when something actually changed.
- **The wakeup is the only seam.** `CFNotificationCenter` needs a second process to be exercised
  usefully, so `DarwinNotificationWakeup` is validated by compilation like
  `NETunnelProviderManagerAdapter`. Everything else runs against a real temp-file-backed ring.

### Tests

The core is tested directly (anchor in both directions and its spacing, the local/remote split down
both branches of the canonical order and in v6, the refusal to guess, the window's zero-fill, roll,
alignment and late-record accounting). The reader runs against a **real** `RingBufferProducer` over a
temp file — not a double — because what matters is the coupling between the extension's producer and
the app's consumer: attach/detach, wakeups, burst caps, the heartbeat, capped recents, the producer's
drops, session reset, a late signal after `stop()`, the stream, and 5 000 records without loss or
duplication.

## History reader

### What the user sees

The Timeline and the Flow Inspector ([`../ux/screens.md`](../ux/screens.md)): the reverse-chronological
list of connections with its filters and its `empty` / `loading older` / `populated` states, and the
per-flow packet list. The live feed shows *what is happening*; this shows *what happened*.

### The pure core

```swift
public struct HistoryFlow: Sendable, Hashable, Identifiable {
    public let stored: StoredFlow
    public let endpoints: FlowEndpoints?
    public init(_ stored: StoredFlow, localAddresses: Set<IPAddress>)
    public var id: Int64 { get }              // el rowid del flujo
    public var displayHost: String? { get }   // SNI si lo hay, si no la IP remota, nil si no se sabe
    public var remotePort: UInt16? { get }
}

public struct HistoryFilter: Sendable, Equatable {
    public var searchText: String                     // contra el host visible
    public var protocols: Set<IPProtocolNumber>       // vacío = todos
    public var tlsStatuses: Set<TLSInspectionStatus>  // vacío = todos
    public var dateRange: ClosedRange<Date>?          // por solape, no por contención
    public static let none: HistoryFilter
    public var isActive: Bool { get }
    public func matches(_ flow: HistoryFlow) -> Bool
}

public struct HistoryPolicy: Sendable, Equatable {
    public var pageSize: Int          // 100 — filas por consulta, y coincidencias por carga
    public var maxPagesPerLoad: Int   // 8 — techo de consultas encadenadas
    public var packetsPerFlow: Int    // 500 — lo que trae el Flow Inspector
    public var axisBars: Int          // 48 — barras del eje temporal de la Timeline
    public static let `default`: HistoryPolicy
}

// El eje temporal de la barra de scrub (M9). Puro: la consulta la hace el lector.
public struct ActivityBar: Sendable, Hashable, Identifiable {
    public let start: Date
    public let duration: TimeInterval
    public let packetCount: Int
    public var end: Date { get }
    public var range: ClosedRange<Date> { get }   // el intervalo **absoluto** que se filtra al tocarla
    public var isQuiet: Bool { get }
}

public struct ActivityAxis: Sendable, Equatable {
    public let bars: [ActivityBar]
    public static let empty: ActivityAxis
    public var isEmpty: Bool { get }
    public var span: ClosedRange<Date>? { get }   // derivado de las barras, no guardado aparte
    public var busiest: Int { get }
    public var totalPackets: Int { get }
    public func bar(containing date: Date) -> ActivityBar?
    // El tramo que elige un arrastre: de barra entera a barra entera, con los extremos acotados al eje.
    public func sweep(from: Date, to: Date) -> ClosedRange<Date>?
}

public enum TimelineActivity {
    public static let bucketLadder: [TimeInterval]   // 1 s, 5 s, 15 s, 1 min … 1 día, 1 semana
    public static func bucketDuration(forSpan seconds: TimeInterval, maxBars: Int) -> TimeInterval
    public static func barCount(forSpan seconds: TimeInterval, bucketDuration: TimeInterval) -> Int
    public static func canZoom(into bar: ActivityBar, maxBars: Int) -> Bool
    public static func axis(
        counts: [PacketBucket], span: ClosedRange<Date>,
        bucketDuration: TimeInterval, maxBars: Int
    ) -> ActivityAxis
}

// El camino de acercamientos del eje (M9). Los niveles van del más ancho al más estrecho.
public struct ScrubZoom: Sendable, Equatable {
    public private(set) var levels: [ClosedRange<Date>]
    public static let wholeHistory: ScrubZoom
    public var current: ClosedRange<Date>? { get }   // lo que el eje enseña; nil = todo el historial
    public var depth: Int { get }
    public var isZoomed: Bool { get }
    public var offersFullReset: Bool { get }         // solo pasado el primer nivel
    public mutating func zoom(into range: ClosedRange<Date>)
    @discardableResult public mutating func zoomOut() -> ClosedRange<Date>?
    public mutating func reset()
}

public enum HistoryPaging {
    public static func appending(_ page: [HistoryFlow], to existing: [HistoryFlow]) -> [HistoryFlow]
}
```

`HistoryFlow` reuses `LiveFeedAddressing` rather than repeating the local/remote split: if the Timeline
and the Dashboard each decided it on their own, the same flow could show a different host on each
screen. Like there, it returns `nil` instead of guessing, and the copy for that case belongs to the
view.

Two decisions carry the honesty of the list:

- **The filter runs in memory, not in SQL.** The text is searched against the host the user actually
  sees, and that host is either the `sni` column or the *formatted* IP of the remote endpoint — which
  on disk is a canonical blob that does not know which end is the device. Pushing the search into SQL
  could only cover half the cases while claiming to cover all of them. The cost (reading rows that get
  discarded) is what `maxPagesPerLoad` bounds.
- **A page is merged without duplicates.** The history is not frozen while it is paginated: the
  extension keeps writing, and a flow already on the list can update its `last_seen` and show up again
  in a later page.

### The reader

```swift
public actor HistoryReader {
    public init(store: FlowStore, policy: HistoryPolicy = .default,
                localAddresses: Set<IPAddress> = TunnelAddressing.localAddresses)

    public var snapshot: HistorySnapshot { get }
    public func snapshots() -> AsyncStream<HistorySnapshot>
    public func refresh() async                 // reconstruye desde la primera página
    public func loadMore() async                // página siguiente hacia atrás
    public func apply(_ filter: HistoryFilter) async
    public func packets(forFlow id: Int64) async throws -> [StoredPacket]
    public func plaintext(forFlow id: Int64) async throws -> [StoredPlaintextChunk]
    public func activity(in range: ClosedRange<Date>? = nil) async throws -> ActivityAxis
    public func canZoom(into bar: ActivityBar) -> Bool          // la regla, contra la política
    public func canZoomFurther(in axis: ActivityAxis) -> Bool
}

public struct HistorySnapshot: Sendable, Equatable {
    public var flows: [HistoryFlow]
    public var filter: HistoryFilter
    public var state: HistoryState              // idle / loading / loadingOlder / loaded / failed
    public var hasMore: Bool
    public var scannedInLastLoad: Int           // filas leídas, coincidiesen o no
    public var isEmpty: Bool { get }            // vacío **y** cargado
}
```

It is an `actor` for the same reason as `LiveFeedReader`: pagination is mutable state — the cursor, the
accumulated list — that several UI actions can touch at once, and actor isolation serialises that
without locks.

- **The read cursor advances by the last row *read*, not the last one matched.** They are different
  things once a filter is on: if the cursor followed the matches, a filtered load would walk again over
  the rows it just discarded.
- **A load chains queries** until it has `pageSize` matches, the store runs out, or it hits
  `maxPagesPerLoad`. On the cap it returns what it has and leaves `hasMore` true: a short list already
  drawn beats a load that walks half the database.
- **`refresh()` rebuilds instead of merging.** Between two refreshes the extension can have updated
  flows sitting in the middle of the list, and those jump to the top by `last_seen`; stitching that
  would leave rows repeated or in an order that is no longer the store's.
- **`refresh`/`loadMore`/`apply` do not throw** — a failure becomes `state = .failed(...)` the screen
  can render — while `packets(forFlow:)` does, because its caller opened a screen *to* show them. Same
  split as `TunnelController`'s toggle actions versus `send`.
- **Refreshing is explicit.** There is no live observation of the database: the writer is another
  process and SQLite does not notify across processes. The Timeline reloads on appear and on pull to
  refresh; what is continuous is the live feed, which exists for that.
- **`scannedInLastLoad` is exposed, not swallowed.** If it dwarfs the rows on screen, the filter forced
  a long walk and the load probably hit its cap — the same habit as `droppedRecords` and `lateRecords`.

`empty` and `populated` from the UX spec are derived (`isEmpty` plus `filter.isActive`) rather than
duplicated as states, so the view can tell "no traffic yet" (teach) from "no matches" (offer to clear
the filter).

### The time axis (M9)

`activity(in:)` is the scrub bar's half of the reader, and it is deliberately **not** part of the
snapshot: it is another query (an aggregation, not a window of rows) with another life cycle — the
list is rebuilt whenever a filter changes and the axis is not, precisely because it does not depend on
any filter. It throws for the same reason `packets(forFlow:)` does: the caller asked for it in order
to draw it.

Passed a range, it draws the same aggregate **inside** that stretch, which is what lets the bar zoom
in. The range is used as given and is **not clamped** against what is stored: if retention took the
stretch, what comes back is an axis at zero, and deciding what that means belongs to the screen — it
is the only one that knows the user picked that stretch and can say so. A store with no packets at all
still yields `.empty` (no bar at all), which is a different statement from an empty stretch inside a
history that does exist.

Three decisions live above the store's query ([`persistence.md`](persistence.md)):

- **A round bucket beats an even split.** `bucketDuration(forSpan:maxBars:)` walks a ladder (second,
  5 s, 15 s, minute, 5 min, 15 min, hour, 6 h, day, week) and takes the finest rung that fits, because
  the bar is *selectable*: tapping it turns its interval into the list's filter, and "the 15 minutes
  starting here" is something a person can read. Only when even the coarsest rung overflows `maxBars`
  (years of history) is the span shared out across the bars — no longer round, but still covering it
  whole, which is the part that cannot be given up.
- **Empty intervals are zero-filled**, the same rule as `ThroughputWindow` and for the same reason:
  without them the drawing would join two peaks and claim a continuous activity that never happened.
- **The last bar absorbs the closing instant.** The newest packet in the history is also the upper
  bound of the queried range, so it lands one index past the axis; leaving it out would make the axis
  fail to count the very packet that defines its end.

The axis is derived from its bars (`span`, `busiest`, `totalPackets`) rather than carried alongside
them: an axis with its own span could contradict its bars, and the contradiction would get drawn.

**Zooming** adds one rule and one type. The rule, `canZoom(into:)`, says a bar can be entered while
there is resolution left below it — never a **quiet** bar (the gaps are zero-filled, so its zero is a
statement and not a gap, and an axis flat at zero is exactly what gets said when retention takes a
stretch) and never one already at the **finest rung** (the axis inside would have bars as wide as the
one that was tapped, so the gesture would spend a query to change nothing). It is asked against
`HistoryPolicy.axisBars` and therefore lives on the reader: with few bars a rung may not fit, so the
floor follows the policy and not the ladder. The type, `ScrubZoom`, is a **stack** of stretches: the
way out has to mirror the way in, since one enters by tapping ever finer stretches, and a single range
would make "the whole history" the only exit — from three levels down, that is losing the place you
had reached. The stack does not check that each level is inside the previous one; the view model only
ever offers the gesture on bars of the axis being drawn.

**Sweeping** is the second gesture on the axis and the one a tap cannot do: bounding the list to a
stretch of *several* bars without tapping them one by one. `sweep(from:to:)` turns the two instants a
drag produced into the stretch it picks, and it makes two decisions. It **rounds to whole bars** —a
stretch starting mid-bar would leave that bar highlighted whole (highlighting is by overlap) while the
list hides part of what it counts, and the bar's foot would date something that matches nothing drawn.
And it **clamps both ends to the axis** instead of discarding them: a finger entering or leaving through
the edge of the chart yields an instant no bar covers, and throwing the whole gesture away for that
would punish exactly the person sweeping end to end. That is the difference from the tap, which *is*
ignored outside the axis: there is no edge a tap was heading for. The order of the ends does not
matter. On the view-model side the gesture is `selectRange(_:)`, which bounds the list and
**never zooms**: a swept stretch is not a bar, so entering it would push a level matching nothing
drawn, and *Back* would then return to a place the user never picked. Tapping picks **where the axis
looks**; sweeping picks **how much the list shows**. Two consequences follow: sweeping the same stretch
again does **not** release it (repeating an exact range with a finger is not something one does by
accident, and reading it as "clear the filter" would undo the gesture just made — the exit is the foot
of the bar), and the list is filtered **on release**, not while dragging, since a query per frame would
be a history read per pixel travelled. What the bar shows meanwhile is the in-flight stretch, which is
the only thing the view keeps state for.

### Tests

The core is tested directly: the endpoint split in v4 and v6 and its refusal to guess, SNI over address
and the empty-SNI fallback, every filter dimension alone and combined, range overlap on all four sides,
and the duplicate-free merge. The reader runs against a **real** `FlowStore` over a temp database — not
a double — because what matters is the coupling with the store's cursor pagination: empty states,
pagination without loss or repetition (including flows sharing a timestamp), a selective filter chaining
queries to fill a page, the burst cap winning when it comes first, continuing without re-reading,
refresh after new traffic, dates coming from the store, rows without a host, the per-flow packets
(ordered, capped, and an unknown flow), and the snapshot stream.

The axis core is tested directly (which rung is chosen for each span, the fallback for a history the
ladder cannot cover, the zero fill, the closing instant, counts before the span discarded rather than
moved, and what the axis derives), and `activity()` against the same real store: no packets means no
axis, the axis covers the whole history with zeroes in between, it never exceeds `axisBars`, a single
packet is one bar, and a filter applied to the list leaves the counts untouched.

Zooming is tested on both halves: the rule (the finest rung as the floor, a quiet bar never entered,
the floor following the policy rather than the ladder, and the non-round fallback still enterable), the
stack (what is current, walking back level by level, resetting, and when the direct exit is offered),
and `activity(in:)` against the store — a stretch drawn finer than the whole history and counting only
what is inside it, a stretch with nothing left coming back at zero rather than empty, and an empty
store yielding no axis even for a stretch.

Sweeping is tested the same way: the rounding to whole bars, both directions reading alike, ends past
either edge clamped (including end to end, which yields the axis span), a sweep inside a single bar
picking that bar, and an empty axis having nothing to sweep; then the view model against the real
store — the list bounded to the whole swept stretch, the axis staying put while the stretch is
highlighted inside it, a sweep inside a zoomed axis keeping the zoom (and `clearInterval` returning
the list to what the axis shows), sweeping the same stretch again keeping it, and a new gesture
clearing the expired-stretch notice.

---

## Capture library

### What the user sees

The Captures screen of [`../ux/screens.md`](../ux/screens.md): the `.pcap` files the extension has
written, what they weigh, and the three things that can be done with them — share one through the
system sheet, delete one, and close the one being written so it can be exported without stopping
monitoring. And, from the Flow Inspector, the bytes of one packet: the same directory, opened at the
offset that packet stored.

### The service

```swift
public struct CaptureFileInfo: Sendable, Equatable, Identifiable {
    public var id: UInt32 { sequence }
    public let sequence: UInt32          // la del nombre; la que llevan sus paquetes guardados
    public let url: URL
    public let byteCount: UInt64
    public let createdAt: Date?          // del sistema de ficheros, no del nombre
}

/// Un registro ya leído: los bytes de **un** paquete tal y como quedaron en el `.pcap`.
public struct CaptureRecord: Sendable, Equatable {
    public let location: CaptureLocation
    public let bytes: Data               // el datagrama IP desnudo (LINKTYPE_RAW)
    public let originalLength: UInt32    // lo que medía antes del snaplen
    public let timestampMicroseconds: UInt64
    public var capturedLength: UInt32 { get }
    public var isTruncated: Bool { get } // originalLength > capturedLength
}

public enum CaptureLibraryError: Error, Sendable, Equatable {
    case containerUnavailable(String)
    case deletionFailed(String)
    case notFound(UInt32)
    case recordUnreadable(String)
}

public actor CaptureLibrary {
    public init(directory: URL)
    public init(appGroupID: String = AppGroup.identifier)
    public init(resolvingDirectory: @escaping @Sendable () throws -> URL)

    public func files() throws -> [CaptureFileInfo]
    public func delete(sequence: UInt32) throws
    public func record(at location: CaptureLocation) throws -> CaptureRecord
}
```

Reading a record lives here rather than in a fifth service because it is the **same directory and the
same seam**: resolving the App Group container and turning a sequence into a file is already this
actor's job. The read itself is specified in [`pcap.md`](pcap.md) — three short seeks, `incl_len`
bounded against the file's `snaplen` before anything is allocated.

`notFound` is deliberately shared with `delete`: the fact is identical — that sequence is not in the
directory — and what differs is only the copy each screen puts on it. For Captures it is a rare race;
for a packet it is the normal consequence of the user having deleted a capture, so the packet screen
reads it as "those bytes are gone", never as a breakage.

It is an `actor` for the same reason as `FlowStore` and `HistoryReader` — it touches disk, and disk
does not get touched from the main thread — and it is the fourth service of the app, the one that
reads what `PcapWriter` writes. Four decisions:

- **It keeps no state.** Every call looks at the directory again, because the writer is *another
  process*: caching the listing would serve a directory the extension already changed by rotating.
- **The directory is resolved per operation, not stored.** Resolving the App Group container is the
  only thing here that can fail, and holding the first attempt's result would pin an early failure to
  the screen forever. `resolvingDirectory:` is the seam that makes that failure testable: on the
  Simulator `containerURL(forSecurityApplicationGroupIdentifier:)` answers with a path for *any*
  identifier, so the real case — an app without the entitlement — cannot be provoked there.
- **A missing directory is an empty list, not a failure.** It does not exist until the extension opens
  its first file, so before the first session the honest answer is "no captures yet".
- **A file listed but no longer `stat`-able is dropped from the listing.** That race is real now that
  the app deletes; showing it with an invented size would be worse than not showing it.

Deleting leaves rows in `packets` pointing at a file that is gone. That is safe — the writer never
reuses a deleted file's sequence (`FlowStore.highestCaptureFileSequence()`), so no packet can end up
pointing at another connection's bytes — and it is what the screen says out loud: the connections stay
in the history, the raw bytes do not.

### The presentation core

`CapturesPresentation` (in `TunnelVision/Models`) holds the decisions the screen cannot improvise:

- **Which file is open right now.** It is *derived*, not asked: the writer always writes the **highest**
  sequence in the directory, and there is only a writer while the tunnel is `live`. With the tunnel
  stopped nothing is open, however recent the last file — assuming otherwise would take away the very
  file the user most likely wants to export.
- **The open file is neither shared nor deleted.** Its last bytes can be a half-written record, and
  deleting it would leave the extension writing into an unlinked inode without a single error. The way
  out is offered instead of the refusal alone: `ControlCommand.rotateCapture` exists precisely to close
  a file so it can be exported without stopping the tunnel.
- **A drawn list is never covered**, the same rule as the Timeline: a failed refresh becomes a
  `CapturesNotice` over the list, and only a failure with nothing on screen becomes the body.
- **Rotating with the tunnel off is explained, not blamed.** `notRunning` — whether it arrives as a
  reply or as a thrown `TunnelControlError` — is a normal race between the UI and the tunnel, so it
  reads as neutral copy, while a rejected rotation keeps the system's message aside as a diagnostic.

`PacketBytesPresentation` (also in `TunnelVision/Models`) holds the packet screen's decisions:

- **The bytes are shown only if they are *this* packet's.** The pipeline writes `orig_len` with the
  same `packet.count` it stores in `PacketMeta.length`, so comparing them is the one check available,
  and it is worth making: showing the wrong record would attribute another connection's traffic to this
  one, which is precisely what `CaptureLocation` exists to prevent. A `snaplen`-truncated record still
  matches — `orig_len` is the real size.
- **Four reasons for having no bytes, and only one of them is a failure.** Never captured, file
  deleted, record mismatched, read failed. Only the last offers a retry: repeating a read of a file the
  user deleted would just teach them to distrust the button.
- **A dump that shows less says so, twice over.** The `snaplen` cut happened *when capturing* and is
  permanent; the screen's own cap (`HexDump.maxBytesShown`) only affects what is drawn. Merging the two
  would let a 9 KB packet read as a 2 KB one.

### Tests

`CaptureLibrary` runs against files written by a **real** `PcapWriter` over a temp directory, since
what matters is that the extension's name and the app's parse of it are one truth: listing in sequence
order with the sizes on disk, each URL opening its own records, foreign files excluded, an absent
directory reading as empty, deletion removing exactly one file, and the typed failures. Reading a
record is tested the same way and for the same reason — every location the writer returned resolving to
its own bytes, the *same offset* in two files resolving to different bytes, `snaplen` truncation
reported, a deleted capture reading as `notFound`, and the four corrupt cases (an offset inside the
global header, an offset past the end, a record cut short by a dying writer, and an `incl_len` larger
than the file's `snaplen`). The presentation core is asserted directly (which file is open, ordering,
copy, the three empties; and for the packet screen the dump's columns and offsets, the mismatch rule,
and which reasons offer a retry), and the view models against a real library over a temp directory with
only rotation scripted — and, for the packet screen, with the read scripted, because a healthy library
over a temp directory cannot produce a deleted file or a corrupt record on demand.

---

## Plaintext library

### What the user sees

The decrypted half of the Flow Inspector: for a connection that was inspected while recording was on,
what actually travelled inside it. Nothing else in the app reaches these files — the user's controls
over them are a switch, an expiry and a delete-everything gesture, all in Settings.

### The service

```swift
/// Un trozo de contenido descifrado ya leído: los bytes de **un** registro de un `.tvpt`.
public struct PlaintextRecord: Sendable, Equatable {
    public let location: PlaintextLocation
    public let stream: UInt64            // la conversación, según la cabecera del registro
    public let direction: Direction
    public let date: Date                // absoluta: el fichero sobrevive a su sesión
    public let bytes: Data               // contenido de aplicación en claro
    public let originalLength: UInt32
    public var storedLength: UInt32 { get }
    public var isTruncated: Bool { get }
    public var droppedLength: UInt32 { get }
}

public enum PlaintextLibraryError: Error, Sendable, Equatable {
    case containerUnavailable(String)
    case notFound(UInt32)                // el barrido ya se llevó el fichero: el caso normal
    case recordUnreadable(String)
    case recordMismatch(String)          // hay un registro ahí, pero no es el que la fila nombra
}

public actor PlaintextLibrary {
    public init(directory: URL)
    public init(appGroupID: String = AppGroup.identifier)
    public init(resolvingDirectory: @escaping @Sendable () throws -> URL)

    public func record(for chunk: StoredPlaintextChunk) throws -> PlaintextRecord
}
```

The mirror of `CaptureLibrary.record(at:)` — same shape (a stateless `actor`, the App Group directory
resolved per call because the writer is another process, that resolution being the seam that makes its
only untestable failure testable) and same read: global header, record header, `stored_length` bytes,
with the length bounded against the file's `max_record_bytes` **before** any memory is reserved.

Three things differ, and all three come from what these files hold
([`plaintext.md`](plaintext.md#reading-it-back)):

- **It only reads.** No listing, no deletion: `PlaintextDirectory` already lists for the sweep and the
  storage figure, and what the user gets over these files is retention plus one gesture that takes
  everything ([ADR 0007](../decisions/0007-decrypted-content-retention.md)), not a screen of files to
  name one by one.
- **The entry point is the index row**, not a bare location, because the check that the record found is
  the record wanted needs the `stream` and both lengths the row carries — and a mismatch is refused
  (`recordMismatch`) rather than returned. Showing one connection's decrypted content under another's
  header would be the worst failure this product can have.
- **`notFound` is the ordinary answer**, not a fault: this content expires on a much shorter schedule
  than the history that names it.

### Tests

Against files written by a **real** `PlaintextWriter` over a temp directory, for the same reason as the
capture library's: the coupling between the half that writes (extension) and the half that reads (app)
is where a format has to mean one thing. Hand-built files appear only where the file has to be
*impossible* to write — a foreign magic, a record claiming more than its file allows, one cut short by a
dying writer. The rest are the way back (a location leading to its own bytes among interleaved
conversations, the file sequence separating two records at the same offset, truncation reported by both
lengths, an absolute date), what is gone (`notFound`, `containerUnavailable`) and what is refused (an
offset inside the file header, an offset that is not a record start, another conversation's record,
lengths that disagree with the row).

---

## Storage manager

### What the user sees

Settings → *Storage* of [`../ux/screens.md`](../ux/screens.md): how much of the device TunnelVision is
using, the two retention caps, and the two ways to cut it down — apply the caps now, or delete
everything. It is also what stops the loose end that had been open since captures existed: nothing
capped the capture directory, so it grew for as long as monitoring ran.

### Why it is its own service

Because **retention crosses both halves and neither half can do it alone.** `FlowStore.prune(before:)`
and `clearAll()` delete *rows, not files*: a cleanup that only touched the database would leave the
`.pcap` files occupying the disk, and one that only deleted files would leave the history pointing at
bytes that are gone. `StorageManager` is the only place in the project that knows about both at once.
It is the app's job and not the extension's because deleting is the user's decision and the extension
has nobody to ask.

### The settings that drive it

The caps live in `AppSettings` ([`ipc.md`](ipc.md)), the durable truth both processes read. They are
closed sets of choices rather than free numbers, so there is nothing to validate and a Settings picker
maps onto them directly:

```swift
public enum RetentionAge: String, Codable, Sendable, CaseIterable {   // oneDay … unlimited
    public var maxAge: TimeInterval?                                  // nil = sin tope
}

public enum RetentionSize: String, Codable, Sendable, CaseIterable {   // megabytes256 … unlimited
    public var maxBytes: UInt64?
}

public struct RetentionSettings: Codable, Sendable, Equatable {
    public var maxAge: RetentionAge
    public var maxCaptureSize: RetentionSize
    public static let `default`: RetentionSettings                     // oneWeek + 1 GB
    public var isUnlimited: Bool { get }
}
```

Two of those choices are decisions worth naming. **The size cap governs the captures and not the
database:** the history is metadata (tens of bytes per packet against the hundreds or thousands of the
datagram), and above all SQLite does not *return* space when rows are deleted — it reuses its pages —
so a byte cap on the database could not be honoured even by deleting everything. A cap that cannot be
enforced would be a lie; the history is bounded by age, which can. And **the factory default is a cap,
not "unlimited"**: an uncapped local capture fills the device, which is exactly what happened while
this did not exist. The screen says both caps in plain words and either can be turned off.

### The pure core

```swift
public struct StorageUsage: Sendable, Equatable {
    public let captureBytes: UInt64        // incluido el fichero que se está escribiendo
    public let captureFileCount: Int
    public let historyBytes: UInt64        // la BD y sus sidecars de WAL
    public let historyFlowCount: Int
    public var totalBytes: UInt64 { get }
}

public struct RetentionPlan: Sendable, Equatable {
    public let historyCutoff: Date?        // para FlowStore.prune(before:)
    public let filesToDelete: [UInt32]     // de la más antigua a la más reciente
    public let bytesReclaimed: UInt64
    public let captureBytesAfter: UInt64
    public let sizeCapUnreachable: Bool
    public var hasWork: Bool { get }
}

public enum RetentionPlanner {
    public static func plan(files: [CaptureFileInfo], settings: RetentionSettings,
                            now: Date, recordingSequence: UInt32?) -> RetentionPlan
}
```

Deciding *who* goes is separated from *deleting* them so the whole policy can be asserted over made-up
listings — gigabyte-sized files without writing a byte — and so the screen can say what will happen
before it happens, which is what an irreversible action requires. Four decisions live in the planner:

- **A file is aged out by its successor's date, not its own.** The writer only ever writes to the
  highest sequence and never returns to an earlier one, so a file stops being written the moment the
  next one appears. Its own creation date says when it *started*, and deleting on that would take
  traffic newer than the cutoff with it. The newest file has no successor and is therefore never aged
  out — it may be the one being written right now, however old its name.
- **A file whose successor has no creation date is left alone.** Without it there is no way to know
  when the earlier one stopped growing, and deleting on an age nobody knows is deleting blind.
- **The file being recorded is never in the plan**, for the same reason the Captures screen refuses to
  delete it. When that makes the size cap impossible to meet — the recording alone weighs more than the
  cap — the plan says so (`sizeCapUnreachable`) instead of leaving the user with a cap silently
  unenforced.
- **Age is applied first and size measures what age already freed**, so the size pass never asks for
  one deletion more than needed. Both cut oldest-first, which is the property that actually matters:
  there is no way to lose a recent capture while an older one survives.

### The service

```swift
public enum StorageError: Error, Sendable, Equatable { case capturesUnavailable(String) }

public struct RetentionOutcome: Sendable, Equatable {
    public let deletedFiles: [UInt32]
    public let bytesReclaimed: UInt64
    public let prunedFlows: Int
    public let failures: [String]
    public let sizeCapUnreachable: Bool
    public var didChangeAnything: Bool { get }
}

public actor StorageManager {
    public init(library: CaptureLibrary, openingStore: @escaping @Sendable () throws -> FlowStore)
    public init(appGroupID: String = AppGroup.identifier)

    public func usage() async throws -> StorageUsage
    @discardableResult
    public func enforce(_ settings: RetentionSettings, recordingSequence: UInt32?,
                        now: Date = Date()) async throws -> RetentionOutcome
    public func clearEverything(recordingSequence: UInt32?) async throws -> RetentionOutcome
}
```

- **Files first, history second.** If the second step fails, connections are left pointing at bytes that
  are gone — a state the app already explains ("those bytes are gone, the connection stays in your
  history"). The other order would leave files nobody references occupying exactly the space the user
  asked to reclaim.
- **It throws only when it could not even start.** No listing means no plan and nothing touched;
  everything else — including a history that would not open, and a file that would not delete — comes
  back inside the `RetentionOutcome`, because losing the count of what *was* freed is worse than not
  reporting the part that failed. Same split as `HistoryReader`'s state-versus-throw rule.
- **One deletion that fails does not abort the rest.** A locked file is no reason to leave the cap
  unenforced everywhere else.
- **It keeps no state, and opens the store per operation.** The captures are written by another process,
  so a cached listing would be a directory rotation already changed; and holding a second GRDB
  connection open for the app's whole life, for operations born of a user gesture, buys nothing —
  besides pinning an early failure to the screen forever.
- **`clearEverything` counts before it clears**, because `clearAll()` does not report how many rows it
  removed and the screen has to be able to say what went. That count is `FlowStore.flowCount()`.

### Who enforces it, and when (M9)

Nobody, until somebody calls it — the manager is the app's and the writer is the extension's. The
Settings screen is that caller: it enforces the caps **when it appears** and **whenever a cap is
changed**, not only from its *Apply limits now* button, because a cap that waits for a button is not a
cap. An automatic pass that deleted nothing says nothing; a pass the user asked for always answers.
That still leaves the directory able to overrun its cap while the app is closed and the tunnel is
capturing — closing that would mean the extension enforcing on rotation, which is the only moment it is
already touching the directory.

Two constraints the caller has to respect. `recordingSequence` comes from
`CapturesPresentation.recordingSequence(files:isMonitoring:)` and from nowhere else: a second way to
guess which file is open would eventually disagree with the first, and the consequence of being wrong
is deleting the file the extension is writing into. And **if the listing cannot be read while
monitoring is running, nothing is deleted at all** — passing `nil` would mean "no file is open", which
is exactly the claim that cannot be made without a listing.

### Tests

The planner is asserted directly over made-up listings (both caps alone and together, the successor-date
rule, the newest file's exemption, a successor with no date, the recording file's immunity and the
unreachable cap, oldest-first order whatever the listing order, and reclaimed + remaining adding up to
the directory). The service runs against a **real** `PcapWriter` over a temp directory and a **real**
`FlowStore` over a temp database, since the point is that retention crosses both halves: usage adding
up, a history that will not open still yielding the capture figure, the aged files deleted and the
history pruned, the recording file surviving, the typed throw when the directory cannot be resolved,
`clearEverything` in both variants, and — with the directory made read-only, so the failure is real
rather than faked — one deletion failing per file without leaving the history uncleared. The size cap is
exercised in the planner rather than here: reaching the smallest choice a user can pick (256 MB) would
mean writing hundreds of megabytes to disk, and what the service adds is the *execution* of a plan,
which is the same whichever cap produced it.

---

## Flow export

### What the user sees

The *Export all connections (JSON)* action of the Captures screen
([`../ux/screens.md`](../ux/screens.md)): the history written out as a JSON file, shown with what it
holds and then handed to the system share sheet.

### What travels, and what does not

The five-tuple in human terms (host/SNI, ports, protocol), the times, the bytes per direction, the
packet count and the encryption status. **Never payloads.** Nothing persists them today — the store
keeps packet metadata, not bytes — so an export that promised content would be lying about what the
product does, and the file says so about itself in a `contents` field rather than leaving it to be
inferred from an absent key. The raw bytes already have their format and their place: the `.pcap`,
shared from the same screen.

Endpoints go out **twice on purpose**. `peers` is the canonical pair exactly as it is stored (the
`FlowKey` does not know which end is the device); `local`/`remote` is that same pair already split, and
they are `null` when the split could not be made. Without `peers` a connection whose endpoints could
not be split would be exported with no addresses at all — losing the fact because it could not be
ordered is worse than giving it unordered.

Protocol and TLS-status names are **stable identifiers, not screen copy** (`tcp`, `notInspectable`…):
one is read by a script and must not move when the other gets reworded.

### Which slice, and how much

The Captures screen carries no history filter, so what comes out is the whole history and the button
says so. The cap (`FlowExport.defaultLimit`, 20,000 connections) exists for the same reason as the
history reader's bounds: the extension writes without a ceiling, so an unbounded export would grow with
accumulated traffic. Reaching it exports the **most recent** connections and both the file and the
screen say `truncated` — and `truncated` is not derived from the count, because a history that ends
exactly at the cap is not a truncated one; it is asked for, with a one-row page past the last cursor.

### The reader's half

```swift
extension HistoryReader {
    public func flowPage(limit: Int, after cursor: FlowCursor?) async throws -> [HistoryFlow]
}
```

A page read that carries its cursor **in and out**, so it touches none of the screen's paging state:
`loadMore()` advances the Timeline's cursor and publishes a snapshot, and an export must not move the
list the user is looking at. It applies **no filter** — what is exported from the Captures screen is
the history, not what another screen has typed into its search box; an export honouring a filter
invisible from where it was asked for would be an incomplete file with no way to tell.

### The service

```swift
public struct FlowExportResult: Sendable, Equatable {
    public let url: URL
    public let connectionCount: Int
    public let byteCount: UInt64
    public let truncated: Bool
}

public enum FlowExportError: Error, Sendable, Equatable {
    case historyUnreadable(HistoryError)
    case writeFailed(String)
}

public actor FlowExporter {
    public typealias PageProvider = @Sendable (Int, FlowCursor?) async throws -> [HistoryFlow]

    public init(directory: URL, limit: Int, pageSize: Int)
    public init(resolvingDirectory: @escaping @Sendable () throws -> URL, limit: Int, pageSize: Int)
    public init(limit: Int, pageSize: Int)   // el temporal de la app

    public func export(now: Date, pages: PageProvider) async throws -> FlowExportResult
}
```

An `actor` for the same reason as `CaptureLibrary`: it writes to disk, and disk is not touched from the
main thread. The history enters as a **page closure** rather than as a `HistoryReader` so the writer is
not coupled to who hands it the rows — and because the seam is what lets the tests provoke a history
that fails halfway, which a healthy store cannot do.

Four decisions:

- **It is the first file the app itself generates.** Everything shared so far already existed because
  the extension wrote it. This one lives in the app's **temporary directory**, not in the App Group
  container: it is not a capture, and leaving it among them would put it in the Captures listing and in
  the retention plans, which count capture bytes.
- **Each export clears the previous one**, so at most one copy of the history sits in the temporary
  directory. Accumulating them would turn it into a silent store of history copies, which is exactly
  what a product that promises data stays on the device must not have. Only files matching the export
  name are removed — deleting blind in a directory one did not fully create is an expensive habit.
- **The document is written in pieces** (prologue, one entry per connection, epilogue), so a history of
  tens of thousands of rows never exists in memory as a single blob. The counts travel in the
  **epilogue** precisely because that is what streaming allows: they are only known at the end, and in
  a JSON object key order means nothing.
- **A failure halfway takes the file with it.** What would be left on disk is unterminated JSON, and
  sharing an invalid file is worse than having none: whoever opened it would not see an error, they
  would see a history that ends early.

### Tests

The pure core is asserted **against the JSON it produces**, decoded back with `JSONSerialization`:
the empty export (the case that breaks any hand-rolled framing, since the separating comma is never
written), the header's UTC instant, the counts in the trailer, the entry's fields, the address fallback
when there was no SNI, the split endpoints, a connection that could not be split still carrying both
addresses, and the stable protocol/TLS names.

The service runs against **real files** over a temp directory with a scripted history — the seam is
what makes the interesting cases reachable: pages chained without repeating or skipping, the cap
cutting the export and the file saying so, a history that ends exactly at the cap **not** reported as
truncated, the history never asked for more rows than the cap allows, a failure halfway leaving no
file behind, an unreachable directory as a write failure, the previous export cleared and a stranger
file left alone. One last test runs the whole thing against a **real** `HistoryReader` over a **real**
`FlowStore`, which is the only one that shows the two halves fit.

## Certificate status (M10)

### What the user sees

Settings → *Look inside secure traffic*, and behind it the guided CA install of
[`../ux/onboarding-and-consent.md`](../ux/onboarding-and-consent.md). Until M10 the screen's
availability closure answered `certificateNotReady` unconditionally — true by accident, since nothing
generated a CA, but a hardcoded answer nonetheless. This service is what makes it a measured fact.

### Where the CA lives, and why there is no IPC here

Turning inspection on needs two independent facts, and they are known in two different places:

- **Does a CA exist?** That is a root key in the Keychain, written by `LocalCA`. App and extension
  declare the **same keychain access group** in their entitlements (they always have, see
  `TunnelVision.entitlements` / `PacketTunnel.entitlements`), and neither passes an explicit
  `kSecAttrAccessGroup`, so both default to that first shared group and look at the very same items.
  The only thing that was missing was the code: `LocalCA` and its pure core lived in the extension
  target, so the app could not name them. Hence the M10 move to
  [`Shared/TLS`](../../Shared/TLS) — the same move `TunnelAddressing`, the control-channel codec and
  the `.pcap` format made before it, and for the same reason: it is knowledge both processes need.
- **Does the system trust its root?** That is `SecTrust`, and *any* process can ask, because the
  trust store belongs to the device. So the app asks it directly, in the present tense.

The alternative on the table (PROGRESS, M10 planning) was for the **extension to publish** what it
knew about the CA into the App Group container next to `SettingsStore`. It was rejected once the
Keychain sharing was traced: a published status is a copy, and a copy of a fact the user can change
from iOS Settings at any moment has to carry *when* it was learned and can never be asserted in the
present — and the publisher only runs while the tunnel is up, which is precisely not when someone
installs a certificate. Reading the Keychain and evaluating trust on demand has no such copy.

### The pure core

`TunnelVision/Models/CertificatePresentation.swift`:

```swift
public struct CertificateStatus: Sendable, Equatable {
    public enum Authority: Sendable, Equatable {
        case notGenerated
        case generated(SystemTrust)
        case unknown(String)          // el llavero no se dejó mirar
    }
    public enum SystemTrust: Sendable, Equatable {
        case trusted
        case notTrusted
        case cannotEvaluate(String)
    }
    public let authority: Authority
}

public enum CertificateStatusPolicy {
    public static func availability(_ status: CertificateStatus) -> TLSInspectionAvailability
    public static func canGenerate(_ status: CertificateStatus) -> Bool
}
```

Four decisions:

- **Trust hangs off `generated`, not beside it.** A flat `(exists, trusted)` pair would admit "no CA
  but trusted", a state nobody could interpret and someone would eventually have to handle.
- **No timestamp, deliberately.** The value is never published, cached or stored, so it only ever
  exists freshly asked. A field saying when it was learned would invite keeping it, and a kept CA
  status is exactly what cannot be asserted: the user can withdraw trust in iOS Settings between two
  questions.
- **Doubt closes.** `cannotEvaluate` is not read as trust, and `unknown` is not read as absence.
  Turning inspection on against a root the device does not anchor would break every 443 handshake —
  worse than the default of not looking; and offering to *generate* when the Keychain could not be
  read would replace the root key of a user who has already installed and trusted theirs
  (`LocalCA.generate` deletes the previous key with the same tag), silently invalidating the
  certificate sitting in their iOS Settings.
- **`notTrusted` cannot tell "not installed" from "installed without full trust".** iOS exposes no
  way to enumerate installed certificates, and both cases evaluate identically. The guided flow must
  therefore show steps 2 and 3 together rather than claim to know which one is missing — the honest
  reading of the UX spec's "detect and guide to the exact missing step". An expired root also lands
  here, which is the right answer to "can inspection be turned on" even though the missing step is a
  different one.

### The service

```swift
public actor CertificateStatusReader {
    public typealias RootCertificateSource = @Sendable () async throws -> Data?
    public typealias TrustEvaluator = @Sendable (Data) -> CertificateStatus.SystemTrust

    public init(trustProbe: @escaping TrustProbeSource,
                evaluatingTrust: @escaping TrustEvaluator = SystemCertificateTrust.evaluate)
    public init(keychain: LocalCA.KeychainConfiguration = LocalCA.KeychainConfiguration())

    public func status() async -> CertificateStatus
    public func availability() async -> TLSInspectionAvailability
}

public enum SystemCertificateTrust {
    public static func evaluate(_ probe: TrustProbe) -> CertificateStatus.SystemTrust
}
```

An `actor`, like `CaptureLibrary`: both of its questions touch the Keychain and the trust store, and
awaiting it from a `@MainActor` view model leaves the main thread by construction. It holds nothing
between calls — the CA is loaded from scratch every time, which is what makes a withdrawn trust
noticeable without restarting anything. Trust is evaluated **only when a CA exists**: asking the system
about a certificate that is not there has no answer to interpret, and it keeps the expensive half off
today's normal path.

**How trust is evaluated changed on 2026-08-15, and the old way was wrong.** It used to evaluate the
**root alone** with `SecPolicyCreateBasicX509`, reasoning that this is not a connection being validated
but a "did the user install *this* certificate". It is a **false positive**: on iOS, installing a
profile puts the root in the anchor store, but enabling it *for TLS* is a second gesture — the switch
under *Settings › General › About › Certificate Trust Settings*. Under the basic policy a root that is
installed without that switch evaluates as valid; under the server policy it does not. The app read the
first, said "trusted", let inspection be turned on, and every TLS connection on the device then died
because the system rejected our leaves. It took a device and a `.pcap` to find: 66 of 90 connections
closed by the client right after the certificate arrived.

What it does now is ask **the question that matters**, through `TrustProbe` (`Shared/TLS`): mint a
throwaway leaf from the CA for a reserved `.invalid` host, and evaluate the chain *leaf + root* with
`SecPolicyCreateSSL` and **no explicit anchors** — passing the root as an anchor would make the answer
always yes, since a root anchors itself. Only if that says no is the old question asked as a **second**
one, and there it stops lying and starts informing: a root that anchors for basic X.509 but not for TLS
is installed and missing its switch, which is a thing the user can be told in those words instead of
being sent to redo an installation they already did (`SystemTrust.installedWithoutFullTrust`). Network
fetching stays off in both — the chain travels whole and its issuer is local, and leaving it on would
turn a local question into one that can hang on a bad network.

`AppEnvironment` is where it plugs in, as the `availability` closure `SettingsViewModel` re-reads on
every refresh — and, since 2026-08-15, on **every return to the foreground**, from the app's root view.
That is `SettingsViewModel.revalidateTLSTrust()`, and it is the other half of the switch: turning
inspection *on* checks trust, but the setting is durable and trust is not. Between two launches the user
can withdraw it from iOS Settings, and inspection would keep terminating every 443 with a certificate
nobody accepts — the device with no browsing, and nothing on screen explaining it. So the rule is
deliberately asymmetric with `availability`: turning on needs a yes, turning off only needs the yes to
stop being there, and a "don't know" turns it off. The costs are not symmetric either — turning off too
eagerly costs some inspection for a while; not turning off when it was needed costs the device's
internet connection.

### Tests

The pure core covers both rules over every state, with the fail-closed cases named on purpose
(`cannotEvaluate` is not trust, `unknown` is not absence). The reader runs against scripted seams: no
CA ⇒ `notGenerated` **and** the trust evaluator never called, the certificate handed to the evaluator
being the one the Keychain returned, a throwing Keychain ⇒ `unknown` (and generation not offered), and
two consecutive questions seeing two different worlds, which is the test that would fail if anything
were cached. `SystemCertificateTrust` is asserted against **real** `Security`: a freshly generated root
is a perfectly valid certificate nobody installed, so the system does not anchor it (`notTrusted`) —
without that test, an evaluator that always answered `notTrusted` would pass — and bytes that are not
a certificate come back as `cannotEvaluate`, not as distrust. The affirmative path (installed +
trusted) needs a device with the profile installed and is part of M10's device DoD.

## Certificate setup (M10)

### What the user sees

Settings → *Look inside secure traffic* → the guided flow of steps 0–4 in
[`../ux/onboarding-and-consent.md`](../ux/onboarding-and-consent.md): the trade-off, one tap to create
the CA, the hand-over to iOS, the two things the user does in iOS Settings, and the confirmation. The
same screen is where it is undone. This increment lands everything under the screen — the profile, the
pure step core and the view model; the SwiftUI walk (share sheet, screenshots) is what remains.

### How the certificate is handed to iOS

The only genuine technical unknown of the flow, and it settles the number of steps. iOS offers no API
to install a trust anchor — deliberately, and [ADR 0003](../decisions/0003-no-third-party-pinning-bypass.md)
is why that is right — so the certificate has to leave the app as a file the user opens. Of the two
possible shapes, a bare `.cer` and a **configuration profile**, the profile wins:

- **The flow the UX spec describes *is* the profile flow.** "Profile Downloaded" and *Settings →
  General → VPN & Device Management* are the profile UI; with a loose `.cer`, steps 2 and 3 would be
  describing a screen the user does not have in front of them.
- **A profile introduces itself.** `PayloadDisplayName` / `PayloadDescription` mean the thing iOS asks
  the user to trust says *TunnelVision* and what it is for, instead of an X.509 subject and a
  fingerprint that mean nothing outside this repo.
- **A profile is what the user removes.** `LocalCA.removeFromKeychain()` takes the key; the installed
  anchor is removed by the user, and the profile is the object iOS shows them to do it.

```swift
public struct ConfigurationProfile: Sendable, Equatable { let fileName: String; let data: Data }

public enum CertificateProfile {
    public static func make(rootCertificateDER: Data) throws -> ConfigurationProfile
}

public actor CertificateProfileExporter {
    public func write(_ profile: ConfigurationProfile) throws -> URL
    public func discard()
}
```

Three decisions inside the builder:

- **The identifier and both UUIDs are fixed constants.** iOS keys a profile by them: installing one
  with the same identity **replaces** what was there, a different one **adds beside it**. Deriving a
  UUID per root would look tidier and do the opposite — after remaking the CA the old root would stay
  installed and trusted next to the new one, with two near-identical profiles the user has no way to
  tell apart. Fixed, remaking the CA replaces the anchor, which is what the user thinks they are doing.
  It also makes `make` **deterministic**, so the file can be asserted byte for byte.
- **`PayloadRemovalDisallowed: false`, written out rather than left absent.** Reversibility is
  non-negotiable, and a profile that refuses to be removed would turn an opt-in feature into a
  one-way door from inside the file itself.
- **Unsigned, and said so in advance.** Signing would need a certificate the device already trusts, and
  the only one the app has is the one not installed yet — signing with it would be circular. iOS marks
  the profile *Not Signed*, so the install guidance names that **before** it appears (the same rule as
  the VPN priming sheet): a red warning on a certificate is exactly what teaches people to back out.

The exporter mirrors `FlowExporter`: the app's **temporary directory** and not the App Group container
(it is not a capture, and among them it would land in the Captures listing and in retention plans), one
file at a time under a fixed name, and `discard()` for when the CA changes — sharing the profile of a
root that no longer signs anything would install a useless anchor the user would believe in.

### The pure step core

`TunnelVision/Models/CertificateSetupPresentation.swift`:

```swift
public enum CertificateSetupStage: Sendable, Equatable {
    case explainTradeOff          // paso 0
    case generate                 // paso 1
    case installAndTrust          // pasos 2 y 3, juntos
    case ready                    // paso 4
    case unavailable(String)      // el llavero no se dejó mirar
}

public enum CertificateSetupPolicy {
    public static func stage(for: CertificateStatus, tradeOffAcknowledged: Bool) -> CertificateSetupStage
    public static func canRegenerate(_ status: CertificateStatus) -> Bool
    public static func canRemove(_ status: CertificateStatus) -> Bool
}
```

- **The stage is derived from the system, not counted.** Every part of this flow happens *outside* the
  app, so a step counter of our own would desynchronise the first time the user did what the flow asks.
  Deriving it means installing the profile with the app in the background and coming back lands the
  user where the system says they are.
- **Steps 2 and 3 are one stage**, because `notTrusted` cannot tell "not installed" from "installed
  without full trust". The stage shows both and **says why**; claiming would be worse than showing both,
  since "it's installed, just enable trust" told to someone who never installed it is a dead end.
- **Step 0 stands only in front of creating.** A CA that already exists was created by someone who read
  the explanation — there is no other way to get there — so demanding it again would be nagging. Each
  *visit* re-explains, though: the explanation is the gate in front of a decision, not a formality
  discharged once and for all.
- **Nothing destructive is offered over a CA that is not known to exist** (`canRegenerate` /
  `canRemove` are false for `unknown`, exactly like `canGenerate`), and remaking is a separate action
  from creating, with a confirmation that names what is lost.

### The view model

`CertificateSetupViewModel` (`@MainActor`, `@Observable`) against five seams — status, root certificate,
create, remove (the three Keychain ones are `LocalCA`, device-only and validated by compilation), the
exporter, plus `SettingsStore` and the control channel. Its two non-obvious rules:

- **Inspection is turned off before the CA is touched, and if it cannot be turned off the CA is left
  alone.** The saved setting is the extension's only gate: leaving it on with a root that just stopped
  being valid does not leave the user where they were, it leaves them worse — the extension would
  terminate handshakes with a leaf the device no longer anchors and traffic that works today would stop.
  A change that does not reach the **live session** is tolerated: with no root key the extension cannot
  sign anything, so inspection falls away by itself.
- **The setting is read from disk on every write, never from a copy held in memory.** This screen does
  not own the settings blob; writing one it has been holding since earlier would clobber whatever the
  user changed in Settings meanwhile. An unreadable blob is repaired by writing over it, like the other
  two writers in the product.

Turning inspection **on** lives here too (step 4 asks for a clear *Inspection on* state) and is gated on
`stage == .ready`, which is the only stage that can assert the system trusts the root. The Settings
switch is unaffected: both do read-modify-write on the same blob, and `SettingsViewModel` keeps its own
availability closure.

### Tests

The profile is asserted against what iOS will read: the payload is a **trust anchor**
(`com.apple.security.root`) and not a plain certificate payload, the DER travels verbatim, removal is
declared, the profile explains itself where the app cannot, two different roots share the profile
identity (the test that would fail if anchors could stack), and an empty certificate is refused rather
than wrapped. The exporter runs against a real temp directory: one file after two writes, `discard`
removing it, and an unresolvable directory arriving typed.

The pure core covers the stage rule over every status × acknowledgement, both fail-closed cases, that
**only one stage offers to create**, that every stage offers a way out that does nothing, that the
install guidance names *Not Signed* before it happens and numbers its steps in one run, and that no copy
in the flow claims anything leaves the device.

The view model runs against scripted Keychain and control channel, a real `SettingsStore` seam and a
**real** exporter: the explanation gating creation and returning on every visit, nothing created over an
unreadable Keychain, a failed generation changing nothing, the profile carrying the current root, a CA
that vanished between two turns, the profile dropped when the CA is remade, re-checking without trust
**not** being a failure, turning inspection on saving it and telling the live session (with the refusal
and the stopped-tunnel cases apart), and — the one that matters most — the **order**: the setting is
saved off *before* the CA is touched, and when it cannot be saved the CA is not touched at all.

## Session diagnostics

### What the user sees

A screen at the bottom of Settings that answers one question in a sentence — **is looking inside
secure traffic actually working?** — and then shows the counters it read that from. It exists because
until M11 the relay's counters never left the extension, so the only way to answer that question was
to attach a debugger to a network extension on a real device; that is what made the one remaining
device check (may a network extension bind a loopback listener?) expensive to run.

### The verdict

`DiagnosticsPresentation.verdict(for:isMonitoring:)` is pure and is where the whole screen earns its
place. The order of its checks **is** the decision, because in a long session several counters are
non-zero at once and only one conclusion can head the screen:

| Condition (in order) | Verdict | What it means |
|---|---|---|
| tunnel not live | `.notMonitoring` | nothing to diagnose; the counters are per session |
| reply without `relay` | `.unavailable` | the tunnel was stopping; absence, never zeroes |
| `inspectionCandidates == 0` | `.idle` | inspection is off, or no TLS-over-TCP has happened |
| `terminationsOpened == 0`, `sniObserved > 0` | `.neverTerminates(named: true)` | **the symptom**: a name was read and nothing was taken over — the CA may be missing inside the extension, or the system may be refusing the loopback listener |
| `terminationsOpened == 0`, no names | `.neverTerminates(named: false)` | those 443 flows were not TLS; normal, not a fault |
| `flowsInspected > 0` | `.working` | decryption is happening |
| `flowsPinned > 0` | `.pinnedOnly` | ADR 0003 seen from the counters: pinned apps are left alone |
| `terminationsFailed > 0` | `.failing` | terminations open and break; those connections are lost |
| otherwise | `.starting` | taken over, no outcome yet — outcomes arrive when the flow closes |

`pinnedHostSkips` cannot precede a termination (a host is only remembered after it refused one), so it
never separates the two `.neverTerminates` cases.

### The other verdict: name resolution

`DiagnosticsPresentation.resolverVerdict(for:isMonitoring:)` reads `TunnelStats.resolvers`
([`tunnel-provider.md`](tunnel-provider.md) § *`ResolverStatus`*) and is a **separate** verdict rather
than a branch of the one above, because it answers a different question at a different severity:
inspection is optional and degrades silently, and this is whether the device can look up names at all.

| Condition (in order) | Verdict | What it means |
|---|---|---|
| tunnel not live, or no `resolvers` in the reply | `.unknown` | nothing to affirm; absence, never "announced none" |
| nothing announced, system could not be asked | `.unreadable` | our own failure, and the device has no DNS |
| nothing announced, system reported none | `.noneReported` | the network offered none |
| nothing announced, system reported some | `.noneUsable` | none could be passed on through a tunnel — the case the spec called reachable, happening |
| ≥4 lookups, no replies, network changed and nothing was ever relearned | `.stale` | **the confirmed bug**: the servers being announced belong to the previous network |
| ≥4 lookups, no replies | `.notAnswering` | the announced server is not replying, cause unknown |
| otherwise | `.announcing` | normal |

`resolverNotice(for:)` returns `nil` for `.unknown` and `.announcing`: a notice that appears when
everything is fine teaches the reader to ignore it. Everything else is a warning, and it goes **above**
the inspection headline in the view — when both have something to say, this is the one explaining what
the user is noticing.

**Rewritten on 2026-08-16, and the reason is a measurement.** The first version of this verdict
compared what was announced with what the system reports now, and that comparison **can never fire on
a device**: with the tunnel up, `res_getservers` answers for the primary interface, which is the
tunnel, so the second reading repeats the first. What holds the conclusion up now are counted facts —
network changes that produced no new resolvers, and lookups that got no reply.

Three things that keep it honest. `.stale` needs **cause and symptom together**: with only the cause
it would warn someone who moved to a network with identical resolvers, and with only the symptom it
could not say what to do. A network change that *was* learned can never end in `.stale`, because the
tunnel has already proved it can catch up. And below four unanswered lookups nothing is claimed: one is
in flight and two are a retry. Partial loss is deliberately not judged — a failure rate needs a time
window, and these counters span the session.

### The view model

```swift
@MainActor @Observable public final class DiagnosticsViewModel {
    public private(set) var stats: TunnelStats?
    public private(set) var failure: String?
    public private(set) var isRefreshing: Bool
    public private(set) var isMonitoring: Bool

    public var headline: DiagnosticsHeadline
    public var resolverNotice: DiagnosticsHeadline?   // nil cuando el DNS no tiene nada que decir
    public var sections: [DiagnosticsSection]

    public init(send: @escaping @Sendable (ControlCommand) async throws -> ControlResponse)
    public convenience init(controller: TunnelController)

    public func tunnelStateDidChange(to state: TunnelState)
    public func refresh() async
}
```

Three rules, all of them consequences of the counters being **per session**:

1. **Nothing is asked when the tunnel is not live.** Sending the command anyway made the screen show
   the channel's failure ("no session") instead of the only true thing, which is that there is no
   session to diagnose. Found by looking at it in the Simulator, where there is never a tunnel.
2. **A failed query does not clear the last known counters**, it adds why there are no newer ones.
   The reason is the system's message where there is one, never the error's case name.
3. **Stopping the tunnel does clear them.** They belonged to that session, and keeping them under a
   headline that says there is nothing to diagnose shows two contradicting things at once.

### Tests

The verdict table exhaustively, including that a missing relay is not read as idle and that the
pinned-only copy states it is by design; that the seven inspection counters are all on screen; that
the relay's sections are absent rather than zeroed when the relay did not answer; that the errors
section only exists when there is an error; that row keys are unique; and that volumes are formatted
as volumes. The view model runs against a scripted channel: the three rules above, an unexpected
reply, and that a failure reason is never a case name.

The DNS half: every verdict of the second table, that a reply without the resolver half is not read as
"announced none", that the normal case says nothing at all, that a learned network change is never
blamed for broken lookups, that a handful of lookups in flight is not called a failure, that no DNS
failure is claimed without the relay's counters, and that the lists are always shown with words — not
blanks — where one is empty or unreadable. Stopping the tunnel takes the notice away with the
counters, for the same reason and with its own test.
