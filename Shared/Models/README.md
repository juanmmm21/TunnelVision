# Shared/Models

Domain value types shared everywhere: `FlowKey`, `IPEndpoint`, `IPAddress`, `FlowRecord`,
`PacketMeta`, header structs, and the `TLSInspectionStatus` / `Direction` / `IPVersion` enums.
All `Sendable`; Foundation-only.

`TunnelAddressing` also lives here (it moved out of the extension in M9): the tunnel's own IPs are
knowledge of *both* processes — the extension announces them to NetworkExtension and compares against
them to resolve direction, and the app needs them to tell which endpoint of a canonical `FlowKey` is
the device. Its milestone is M7; its spec is
[`../../docs/spec/tunnel-provider.md`](../../docs/spec/tunnel-provider.md).

`MonotonicAnchor` moved here in M9 for the same reason: the app needs it to date the live feed and the
extension needs it to date what it writes to the store. It pairs a `CLOCK_UPTIME_RAW` reading with the
wall clock at the same instant — taken once per session, so the relative spacing between packets stays
exact. `WallClock` next to it converts to and from the nanoseconds-since-epoch used on disk.

`CaptureLocation` and its neighbours (`CaptureFileName`, `CaptureFile`, `CaptureDirectory`) moved in
for the third time on the same argument: the extension writes capture files and the app resolves them.
A packet stores *where* its bytes are as a pair (file sequence + record offset), because the writer
rotates by size and every file restarts its offsets — an offset alone points into an unknown file. The
naming rules live next to the type so formatting a name and reading it back cannot drift apart. Their
milestone is M6/M9; their spec is [`../../docs/spec/pcap.md`](../../docs/spec/pcap.md).

`AppSettings` (with `CaptureDetail` and `RetentionSettings`) is here for the same reason as everything
above: it is what the user decided, and **both** processes read it — the app writes it when a setting is
touched, the extension reads it when it starts a session. What it means for the capture lives with it
(`CaptureDetail.snaplen`, `RetentionAge.maxAge`, `RetentionSize.maxBytes`) so no caller has to translate
a choice into a number twice. Where it is *stored* is `Shared/IPC/SettingsStore.swift`, next to the other
cross-process contracts. Its milestone is M9; its specs are
[`../../docs/spec/ipc.md`](../../docs/spec/ipc.md) and
[`../../docs/spec/app-services.md`](../../docs/spec/app-services.md).

**Spec:** [`../../docs/spec/data-model.md`](../../docs/spec/data-model.md) · **Milestone:** M1
