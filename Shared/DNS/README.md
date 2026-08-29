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

**Read by:** `TunnelVision/Models/DNSPresentation.swift` (what the packet screen shows of it) ·
**written by:** `Shared/Fixtures/DNSMessageFixture.swift` (the synthetic lookups a seeded run shows)

**Spec:** [`../../docs/spec/packet-parsing.md`](../../docs/spec/packet-parsing.md)
