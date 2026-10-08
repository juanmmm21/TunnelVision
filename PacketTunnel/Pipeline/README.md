# PacketTunnel/Pipeline

The hot path without `NEPacketTunnelProvider`: `PacketPipeline` parses a datagram, aggregates it
into its flow, decides its route (`passthrough` vs `inspect`), writes it to the capture, publishes
it to the live feed and batches it to the store. Pure and injected, so it is tested on the
Simulator — the device-only provider just feeds it `packetFlow` packets and acts on the returned
`PacketDisposition`.

It also owns the address → name map (`Shared/DNS/ResolvedNameMap`): replies arriving from port 53
feed it, and a flow is named from it when it is created — the name of everything the ClientHello
scanner cannot reach, QUIC first. Spec:
[`../../docs/spec/packet-parsing.md`](../../docs/spec/packet-parsing.md) § *Naming flows*.

And it reads the QUIC version from the long header of UDP datagrams to remote port 443
(`Shared/QUIC`), handing it to the flow table with the packet: it is what marks a QUIC flow
`encrypted` instead of leaving it as every UDP flow is born. Same spec, § *Above L4: the QUIC long
header*.

**Spec:** [`../../docs/spec/tunnel-provider.md`](../../docs/spec/tunnel-provider.md) · **Milestone:** M7
