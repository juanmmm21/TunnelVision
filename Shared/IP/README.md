# Shared/IP

IPv4/IPv6 + TCP/UDP header parsing. Pure, zero-copy over `Data` slices; produces `ParsedPacket`
and the canonical `FlowKey`. Typed `PacketParseError`.

Also the mirror image: `PacketEmitter` serializes an IP datagram (headers + RFC 1071 checksums via
`InternetChecksum`) so the relay can reinject a server's reply through `packetFlow.writePackets`.
It lives beside the parser rather than in `PacketTunnel/Relay/` because serializing IP is the same
layer as parsing it, and the round-trip tests only make sense together.

It moved here from `PacketTunnel/IP` in M11, for the same reason `PcapFormat`, `CaptureFileName`,
`TunnelAddressing` and `MonotonicAnchor` moved: it stopped having a single consumer. The extension
parses what the tunnel hands it and emits what the relay reinjects, and the app now needs the
emitter too — `Shared/Fixtures` builds the datagrams of a synthetic capture with it, so that the
bytes a Simulator run shows are real IP packets and not plausible-looking noise. Nothing here
touches NetworkExtension, so the framework stays extension-safe.

**Spec:** [`../../docs/spec/packet-parsing.md`](../../docs/spec/packet-parsing.md) (parser, M3) ·
[`../../docs/spec/relay-and-tls.md`](../../docs/spec/relay-and-tls.md) (emitter, M8)
