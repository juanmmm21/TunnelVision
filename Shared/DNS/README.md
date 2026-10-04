# Shared/DNS

The DNS message parser: the project's first dissector above L4 (`docs/development/03-roadmap.md`,
step 10). `DNSMessageParser.parse` takes the payload of a UDP datagram on port 53 and returns a
`DNSMessage` — header bits, the questions and the answer section — or a typed `DNSParseError`.

It reads only what something shows. The authority and additional sections are deliberately not
walked, and a record type it does not break down keeps its byte count (`DNSRecordData.opaque`)
instead of failing the message that carries it.

Everything about it is bounded, because a DNS message is a stranger's data: name compression
pointers may only point **backwards**, which makes a loop impossible by construction rather than by
counter; the chain of jumps has a ceiling; a name stops at the format's 255 bytes; and label bytes
that are not printable ASCII are escaped the way RFC 1035 § 5.1 escapes them, so a control byte in a
hostile name cannot rewrite the line it is drawn on. An IDN label is left as `xn--…` on purpose:
decoding it to Unicode is exactly what makes two different domains look like one.

It reads what the device's owner sent and what came back, in the clear. Nothing here touches another
app's security (ADR 0003), and nothing here needs inspection to be turned on — which is why DNS goes
first among the dissectors: it is the only layer a 2026 iPhone still sends in the clear.

## The address → name map

`ResolvedNameMap` turns those messages into an answer to *which name had the device asked for when
it was given this address?* — the name of a flow that announces none (QUIC, anything that is not
TLS). It is a pure value: every instant is passed in, on the clock that stamps packets.

- **In:** only the addresses a reply gives for the name it was asked about, following its own
  `CNAME` chain. The name kept is the one asked for, and only if it could be an allowlist entry.
- **Expiry:** the shortest TTL on the path from name to address, clamped by `ResolvedNameLimits`
  (which has no defaults; the tunnel's are `.tunnel`). An expired pair names nothing.
- **Shared addresses:** the most recently resolved live name wins, and the others travel with it
  in `ResolvedName.otherNames` instead of being hidden.
- **Size:** never more than its capacity; expired pairs go first, then the least recently resolved.

A resolved name is an inference, not an announced SNI, which is why it has a type of its own.

The map is owned and fed by `PacketPipeline` (`PacketTunnel/Pipeline`): every UDP datagram arriving
from port 53 goes in, and a flow is named from it when it is created. The name reaches the store in
`FlowRecord.resolvedName`, and what the map did with each reply is counted in `DNSNameStats`.

**Read by:** `TunnelVision/Models/DNSPresentation.swift` (what the packet screen shows of it) ·
**written by:** `Shared/Fixtures/DNSMessageFixture.swift` (the synthetic lookups a seeded run shows)

**Spec:** [`../../docs/spec/packet-parsing.md`](../../docs/spec/packet-parsing.md)
