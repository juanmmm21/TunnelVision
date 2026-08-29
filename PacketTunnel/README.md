# PacketTunnel (NEPacketTunnelProvider extension)

Runs in a separate, memory-constrained process; **device-only**. `Provider/PacketTunnelProvider.swift`
orchestrates the `packetFlow` read/write loop; the real work lives in the submodules and in
`Shared`. Keep the provider thin.

- `Flow/` table+reassembly · `Pipeline/` hot path · `Provider/` lifecycle+control ·
  `Relay/` passthrough · `TLS/` inspection

IP parsing and emission (M3/M8) used to be `IP/` here, and the pcap writer (M6) used to be
`Capture/`; they live in [`../Shared/IP`](../Shared/IP/README.md) and
[`../Shared/Capture`](../Shared/Capture/README.md) since M11, because the app needs them too.

**Spec:** [`../docs/spec/tunnel-provider.md`](../docs/spec/tunnel-provider.md) · **Milestones:** M3–M8
