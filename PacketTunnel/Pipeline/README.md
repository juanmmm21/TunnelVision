# PacketTunnel/Pipeline

The hot path without `NEPacketTunnelProvider`: `PacketPipeline` parses a datagram, aggregates it
into its flow, decides its route (`passthrough` vs `inspect`), writes it to the capture, publishes
it to the live feed and batches it to the store. Pure and injected, so it is tested on the
Simulator — the device-only provider just feeds it `packetFlow` packets and acts on the returned
`PacketDisposition`.

**Spec:** [`../../docs/spec/tunnel-provider.md`](../../docs/spec/tunnel-provider.md) · **Milestone:** M7
