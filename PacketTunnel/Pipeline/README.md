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

And it names QUIC flows from what their client announces: the Initial packets the device sends to
port 443 are opened (`QUICClientHelloReader`, in `../TLS`), and once the ClientHello they carry is
whole its name goes to `sni` and its offer to `clientTLS`, as a TCP flow's do. How much of a flow
is looked at and how many flows at once is `QUICNameReadLimits`; what happened to each is counted
in `PipelineStats.quicNames`. Same spec, § *Above L4: naming a QUIC flow*.

**Spec:** [`../../docs/spec/tunnel-provider.md`](../../docs/spec/tunnel-provider.md) · **Milestone:** M7
