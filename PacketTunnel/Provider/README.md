# PacketTunnel/Provider

The extension's entry point. `PacketTunnelProvider` owns the device-only lifecycle: it applies the
`NEPacketTunnelNetworkSettings`, runs the sequential `packetFlow` read loop that feeds
[`../Pipeline`](../Pipeline), posts the per-batch Darwin wakeup, and tears everything down on
`stopTunnel`. `TunnelRuntime` (same file) holds the mutable state and owns the real collaborators —
`FlowStore`, `RingBufferProducer`, `PcapWriter` — which the pipeline only ever receives injected.

Everything left in this folder is device-only. Two pure pieces used to live here and both moved to
`Shared` once the app needed them too: the codec for `handleAppMessage`, now in
[`../../Shared/IPC/ControlChannel.swift`](../../Shared/IPC/ControlChannel.swift) (M9), and
`TunnelAddressing` — the tunnel's own IPs, whose byte form feeds the pipeline, whose text form feeds
NetworkExtension, and whose `localAddresses` let the app tell the device apart from the remote host
in a canonical `FlowKey` — now in
[`../../Shared/Models/TunnelAddressing.swift`](../../Shared/Models/TunnelAddressing.swift). New logic
that can be tested belongs in `Pipeline` or `Shared`, not here.

**Spec:** [`../../docs/spec/tunnel-provider.md`](../../docs/spec/tunnel-provider.md) · **Milestone:** M7
