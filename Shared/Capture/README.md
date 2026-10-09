# Shared/Capture

The libpcap side of the product, both halves of it: the wire format (`PcapFormat` — the constants,
the two header builders and the two header parsers) and the streaming writer (`PcapWriter` —
`LINKTYPE_RAW`, file rotation, never more than one record in memory).

The format moved out of `PacketTunnel/Capture` in M9, when the Flow Inspector gained the jump from a
packet to its bytes: the extension writes these files and the app opens one at a `CaptureLocation` to
decode a single record, so **formatting and parsing have to be one truth**.

The writer followed in M11, when it stopped having one consumer: the synthetic-capture seeder
([`../Fixtures`](../Fixtures)) writes its `.pcap` files with this same writer, from the app. Writing
them separately with `PcapFormat` would have duplicated the one rule the file+offset pair exists to
protect — that a packet's stored offset is that of its record header inside the file open at the time
— and a seeded capture whose offsets were computed elsewhere would validate itself while the packet
screen read someone else's bytes.

Both moves are the same one `CaptureFileName`, `TunnelAddressing`, `MonotonicAnchor`, the
control-channel codec and `PacketParser`/`PacketEmitter` made. The types that name a file and locate a
record (`CaptureFileName`, `CaptureDirectory`, `CaptureLocation`) live in [`../Models`](../Models),
next to the rest of the domain values.

`PcapFileReader` is the reading half: one file opened once and records read from it by offset,
with every way a record can be unreadable as its own case. It was the body of the app's
`CaptureLibrary.record(at:)` until the evidence bundle became a second reader.

`PcapngFormat` writes pcapng — a section header, one interface, enhanced packet blocks — and only
for the capture of an evidence bundle, which needs what classic pcap cannot carry: a comment and a
direction on each packet. The extension keeps writing classic pcap.

**Spec:** [`../../docs/spec/pcap.md`](../../docs/spec/pcap.md) · **Milestones:** M6, M9, M11
