# Spec — Packet parsing (`Shared/IP`)

Turns a raw IP datagram (`Data`) into typed headers and a `FlowKey`. Pure, synchronous, and
allocation-frugal: parsing must not copy the payload, only read fields and return ranges into
the original buffer.

> The same module also holds the **mirror** direction — `PacketEmitter`, which serializes a datagram
> so the relay can reinject a reply. It arrives with M8 and is specced in
> [`relay-and-tls.md`](relay-and-tls.md#reinjection-the-packet-emitter-packettunnelip).

## Contract

```swift
public enum PacketParseError: Error, Sendable {
    case tooShort(expected: Int, got: Int)
    case unsupportedVersion(UInt8)
    case badHeaderLength
    case truncatedL4
    case unsupportedProtocol(UInt8)   // no es error fatal: el caller lo cuenta y hace passthrough
}

/// Resultado de parsear un datagrama IP completo.
public struct ParsedPacket: Sendable {
    public let ip: IPHeader
    public let tcp: TCPHeader?
    public let udp: UDPHeader?
    public let flowKey: FlowKey
    public let source: IPEndpoint       // origen tal cual viene en el paquete
    public let destination: IPEndpoint
}

public enum PacketParser {
    /// Parsea un datagrama IP. `protocolFamily` es el AF_INET/AF_INET6 que da `packetFlow`,
    /// usado como pista; si no coincide con el nibble de versión, gana el contenido.
    public static func parse(_ packet: Data, protocolFamily: Int32) throws -> ParsedPacket
}
```

`Data` is accessed via `withUnsafeBytes`; all offsets are computed against a base pointer. No
intermediate `Data` copies are created.

## IPv4 (RFC 791)

- Byte 0: high nibble = version (must be 4), low nibble = IHL (header length in 32-bit words).
  Header length = `IHL * 4`; reject if `< 20` or `> packet.count`.
- Byte 9: protocol.
- Bytes 12–15: source address; 16–19: destination.
- Total length at bytes 2–3 (big-endian). Fragmentation flags/offset at bytes 6–7 — a
  fragmented packet without the first fragment has no L4 header; mark L4 absent and let the
  caller treat it as metadata/passthrough.
- L4 payload starts at `IHL*4`.

## IPv6 (RFC 8200)

- Byte 0 high nibble = version (6). Payload length at bytes 4–5. Next header at byte 6.
- Bytes 8–23: source; 24–39: destination. Fixed 40-byte base header.
- **Extension headers:** walk the next-header chain (hop-by-hop, routing, fragment,
  destination options) until a transport protocol (TCP/UDP) or an unknown one is reached,
  advancing by each header's length. Bound the walk (reject absurd chains) to avoid loops.

## TCP (RFC 9293)

- Ports at bytes 0–1 / 2–3. Sequence 4–7, ack 8–11 (big-endian).
- Data offset = high nibble of byte 12, in 32-bit words ⇒ header length in bytes; reject if
  `< 20` or beyond the segment. Flags in byte 13 (map to `TCPFlags`). Window at 14–15.
- Payload = after the TCP header to end of the IP payload.

## UDP (RFC 768)

- Ports 0–1 / 2–3, length 4–5, payload after 8 bytes.

## Endianness helpers

Provide small inlined big-endian readers (`readU16BE`, `readU32BE`) over the raw pointer.
Network byte order is big-endian; convert once at read time, store host-order in the typed
headers.

## Error handling policy

- **Structural corruption** (too short, bad header length) ⇒ throw; the read loop counts a
  `malformedPacket` and drops it.
- **Unsupported protocol** (not TCP/UDP) ⇒ not a throw on the hot path: return `ParsedPacket`
  with `proto == .other`, `tcp == nil`, `udp == nil`; the caller logs metadata and passes it
  through. ICMP is common and must not spam errors.

## Performance

- Zero payload copies; only field reads and range math.
- No heap allocation per packet beyond the small `ParsedPacket`/header structs (value types).
- Target: sustain well above typical Wi-Fi line rate; covered by a `measure {}` benchmark.

## Tests (M3)

- Golden vectors, one concern each — IPv4 TCP SYN, IPv4 UDP DNS, IPv6 TCP, IPv6 UDP, IPv6 with
  a hop-by-hop extension header, and an IPv4 non-first fragment → assert every extracted field
  (addresses, ports, seq/ack, flags, window, `payloadRange`, `totalLength`) and the canonical
  `FlowKey`. The vectors are built as raw IP datagrams in `PacketFixtures` (each equivalent to a
  `LINKTYPE_RAW` record), so the "golden" bytes are reviewable in the diff and deterministic;
  loading captured `.pcap` files uses the pcap reader that lands with M6 (`pcap.md`).
- Truncated variants of each must throw the right `PacketParseError` (`tooShort`, `badHeaderLength`,
  `truncatedL4`).
- ICMP/ICMPv6 and other unsupported transports → `proto == .icmp`/`.icmpv6`/`.other`, `tcp == nil`,
  `udp == nil`, no throw; `rawProtocol` preserves the wire value.
- Fuzz: random byte buffers of random lengths (and random `protocolFamily` hints) must never crash
  and must only throw `PacketParseError`.
- A `measure {}` benchmark over the IPv4 hot path.

## Above L4: the DNS dissector (roadmap step 10)

The parser above stops at the transport header. `Shared/DNS` is the first thing that reads what
comes after it: `DNSMessageParser.parse` takes the payload of a UDP datagram on port 53 and returns
the message (`DNSMessage`) — the header bits, the questions and the answer section — or a typed
`DNSParseError`. It is the same shape of component as `PacketParser`: pure, synchronous, no state,
bounded, and 0-based over whatever `Data` it is handed (`withUnsafeBytes` normalizes a slice, which
matters here because a compression pointer is an offset from the start of the *message*).

DNS goes first among the dissectors, ahead of HTTP, TLS records and QUIC frames, for a reason that
is not aesthetic: it is the only layer a 2026 iPhone still sends in the clear, so it is the only one
readable on hardware without inspection turned on, and it is what most changes a packet screen —
*Looked up: api.example.com · Record type: A · Answer: 203.0.113.10* where there used to be only
*UDP · Datagram length: 73 B*.

**Where the limits are, and why each one is there.** A DNS message is a stranger's data, and its
name compression makes that sharp: a two-byte pointer can name any offset in the message, and a
pointer to itself is an infinite loop.

- A pointer may only point **backwards**. Each jump lands strictly before the one before it, so a
  cycle is impossible by construction rather than by counter. The chain still has a ceiling (32),
  which bounds the work a message can make us do.
- A name stops at the format's 255 bytes, counting each label's own length byte.
- The reserved label bits (`0x40`, `0x80`) are refused rather than guessed at.
- Every read is checked against the buffer that is really there, so a length field that lies
  produces `.truncated` and never a read past the end.
- Label bytes that are not printable ASCII — and `.` and `\` — are escaped in decimal the way
  RFC 1035 § 5.1 escapes them. Without it a control byte inside a hostile name is drawn on the
  packet screen as a control byte. An IDN label is deliberately left as `xn--…`: decoding it to
  Unicode is what makes two different domains look like one, and this screen exists to say who the
  device talked to.

**What it does not do**, each on purpose: it does not walk the authority and additional sections
(nothing shows them, so walking them would be failure surface for nothing); it does not pair a query
with its reply by `id` (that needs state across packets, and the screen that reads this describes
one packet); it does not read DNS over TCP (a two-byte length prefix this parser does not expect, so
reading it would be reading it wrong); and it does not read mDNS on 5353, which uses the same format
and is the obvious next port — one dissector per increment.

A record type it does not break down is **not** an error: its content becomes
`DNSRecordData.opaque(byteCount:)`, and so does a known type whose length is not its own (an `A`
that does not measure four bytes is not an address however its type is labelled).

What the screen makes of all this — which four readings a reply can have, and what is said when a
port-53 datagram cannot be read at all — is in `TunnelVision/Models/DNSPresentation.swift`.

### Tests

- The ordinary messages are written with `Shared/Fixtures/DNSMessageFixture`, which is an encoder
  and therefore independent of the parser; it compresses answer names with a pointer to the
  question, the way a real resolver does, so the pointer path is exercised every time.
- The hostile ones are written byte by byte in `DNSMessageParserTests`, because the fixture cannot
  — and must not — encode an illegal message: a self-pointer, a forward pointer, the reserved label
  bits, a name over 255 bytes, a label that runs off the end, an `rdlength` that lies, and a header
  that promises more answers than it carries (which is what a `snaplen` leaves behind).
- Escaping, the root name, an unknown type's `TYPE64` name, and a slice whose `startIndex` is not
  zero each have their own case.
