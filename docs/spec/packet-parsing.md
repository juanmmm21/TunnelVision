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

## Names from DNS: the address → name map

The ClientHello scanner names a flow only when it is TLS over TCP. QUIC carries its ClientHello
inside an encrypted Initial packet, and plenty of traffic is not TLS at all, so most flows of a
present-day phone have an address and nothing else. `ResolvedNameMap` (`Shared/DNS`) is what gives
them a name: it is handed the DNS messages the dissector has already read and answers *which name
had the device asked for when it was given this address?*

```swift
public struct ResolvedNameLimits: Sendable, Hashable {
    public let capacity: Int                 // address–name pairs held in total
    public let namesPerAddress: Int          // names remembered for one address
    public let minimumLifetime: UInt32       // seconds an answer is believed, whatever its TTL
    public let maximumLifetime: UInt32
    public init(capacity: Int, namesPerAddress: Int, minimumLifetime: UInt32, maximumLifetime: UInt32)
    public static let tunnel: ResolvedNameLimits   // 2048 pairs, 4 names, 60 s … 1 day
}

public struct ResolvedName: Sendable, Hashable {
    public let name: String                  // the name that was asked for, normalised
    public let resolvedAt: UInt64            // when the answer went by, on the packet clock
    public let otherNames: [String]          // other live names of the address, most recent first
}

public enum DNSNameIngestion: Sendable, Hashable {
    case recorded(addresses: Int)
    case ignored(Reason)
    public enum Reason: Sendable, Hashable {
        case notAResponse, unsupportedOpcode, errorResponse
        case unsupportedQuestion, unusableName, noAddresses
    }
}

public struct ResolvedNameMap: Sendable {
    public let limits: ResolvedNameLimits
    public private(set) var count: Int
    public init(limits: ResolvedNameLimits)
    public mutating func ingest(_ message: DNSMessage, at instant: UInt64) -> DNSNameIngestion
    public mutating func removeExpired(at instant: UInt64) -> Int
    public func name(for address: IPAddress, at instant: UInt64) -> ResolvedName?
}
```

It is a pure value: it reads no clock (every instant is passed in, in the nanoseconds that stamp
packets, `PacketMeta.timestamp`), touches no disk and knows nothing about flows. `ResolvedNameLimits`
has no default values — each of its four numbers decides something — and the ones the tunnel uses
are `ResolvedNameLimits.tunnel`, each with its reason written next to it.

**A resolved name is not an announced SNI.** An SNI is stated by the connection itself; this is an
inference from an earlier lookup. That is why the result carries when it was resolved and which
other names the same address had, and why it is a type of its own rather than a string that could
be mistaken for an SNI.

### What goes in

Only a reply (`QR` set, standard opcode, `NOERROR`) to exactly one question of class `IN`, and from
it only the addresses (`A`, `AAAA`) **reachable from the question's name** by following the reply's
own `CNAME` records.

- **The name stored is the one that was asked for**, not the end of the alias chain. An allowlist
  authorises what the app requested, not the CDN host its provider happens to serve it from.
- **An address record owned by any other name is not recorded.** It does not answer the question,
  and recording it would let one message name addresses that are not its own.
- **The chain is walked from the question**, not trusted to arrive in order: `CNAME`-before-address
  is a resolver habit, not a guarantee of the format. The walk stops at a loop and has a ceiling.
- **Names are compared without case.** DNS is case-insensitive and a resolver may echo the question
  with its letters' case deliberately scrambled (0x20 randomisation).
- **A name is stored only if it could be written as an exact allowlist entry**: `DomainPattern` is
  the yardstick ([`audit.md`](audit.md)). That leaves out the root, a name the dissector had to
  escape, and a literal wildcard, with no second rule set here — and guarantees that whatever the
  map returns can be compared against an allowlist.

Everything else is reported, not dropped in silence: `ingest` returns why a message recorded
nothing. *There was nothing to read* is a result that has to be countable — with encrypted DNS no
reply crosses port 53 at all, and an unnamed flow needs its reason.

### When it expires

A pair lives for the **shortest TTL on the path** from the name to the address — the address
record's and every `CNAME`'s in between — clamped to the limits. Seeing the same answer again
renews it. An address listed twice in one reply takes the shorter of its two TTLs.

- **The floor** exists because replies with a TTL of zero or one second are real (load balancers
  that want no caching), and the connection the lookup was for comes *after* it. Without a floor
  exactly those flows would go unnamed.
- **The ceiling** exists because a TTL is a 32-bit integer and nothing stops it from saying 136
  years, while an address does not belong tomorrow to whoever had it today.
- **An expired pair names nothing**, and is not listed among `otherNames` either. CDN addresses are
  recycled; attributing one to its previous holder is worse than saying it is not known.
- The expiry instant itself is already outside the lifetime, and an expiry past the end of the
  clock saturates instead of wrapping.

The clock is the monotonic one that stamps packets, which stops while the device sleeps: a pair can
outlive its TTL by however long the device was asleep. That errs towards keeping a name the device
itself may still be using from its own cache, and it keeps the map free of wall-clock jumps.

### The tie-break on a shared address

One address can have several live names at once — that is what a CDN is. The rule:

1. **The most recently resolved live name wins.** A device looks a name up immediately before it
   connects, so the latest lookup that returned this address is the likeliest reason for the flow.
2. At the same instant, the lexicographically smaller name wins — so the answer never depends on
   which message was ingested first or on dictionary order.
3. **The losers are not hidden**: they are `otherNames`, most recent first. An empty list means the
   attribution is uncontested; a non-empty one means `name` is the best candidate, not the only one,
   and whoever judges the flow against an allowlist can see every name it might have been.

Resolving an older name again makes it the most recent. An address remembers at most
`namesPerAddress` names and forgets the least recently resolved beyond that.

### How much it holds

Never more than `capacity` pairs. A full map makes room by dropping what has expired first and,
if nothing has, the single least recently resolved pair (ties broken by address, again so that two
runs over the same messages end in the same map). Renewing a pair that is already there evicts
nothing. With the tunnel's limits the worst case — 2048 names of 253 bytes — is under 1 MB.

### Tests

`ResolvedNameMapTests` builds `DNSMessage` values directly, since the map reads what the dissector
read and several cases need records `DNSMessageFixture` cannot write (an address owned by a name
that is not the question). They cover: what is recorded and each of the six reasons for recording
nothing; the alias chain in order, out of order, looping, and with scrambled case; an unrelated
address left out; the lifetime at its exact edge, through a chain, floored, capped, renewed and
saturated; the tie-break in both arrival orders, an expired winner giving way, and the per-address
limit; and the capacity — expired first, then least recent, never exceeded under a flood, and the
same victim whatever the dictionary order. One case goes from bytes through the parser to a name.

### Naming flows: where the map lives

The map is owned by the `PacketPipeline` (`PacketTunnel/Pipeline`), for the reason the flow table is:
every datagram goes through it, in both directions, and it is where a flow is born.

```swift
public struct ResolvedFlowName: Sendable, Hashable, Codable {   // Shared/Models/FlowName.swift
    public let name: String
    public let otherNames: [String]
    public init(_ resolved: ResolvedName)
}
```

- **What is fed to it**: the payload of every datagram that **arrives** at the device over UDP from
  source port 53 — replies reach the pipeline through `record(reinjected:)`. What the device *sends*
  is never read, whatever port it leaves from. DNS over TCP is not read: it would need a reassembled
  stream the pipeline does not have. Encrypted DNS (DoT, DoH, Private Relay) is not attempted.
- **The reply is ingested before the flow table is touched**, so the answer is in the map when the
  first packet of the flow it was looked up for arrives.
- **A flow is named when it is created**, with the stamp of its first packet, from the map's answer
  for its remote address. `FlowTable.observe` takes the name on every packet and uses it only for a
  new flow: the caller cannot know whether the flow exists without an extra actor hop per packet.
- **A named flow never changes name**, and a flow born without one never acquires one: a reply that
  goes by later says nothing about what an already-open connection was looked up as. This is the
  same idea as the audit tag.
- **`otherNames` travel with the name all the way to the store.** The allowlist check has to see
  every name a shared address might have been.
- **Nothing here can stop a packet.** A datagram from port 53 that does not parse is counted and
  goes on to the history like any other.

The name goes into **its own field, `FlowRecord.resolvedName`, never into `sni`** — see
[`data-model.md`](data-model.md) for `FlowName`, which is how a reader gets *the* name of a flow
together with where it came from, and [`persistence.md`](persistence.md) for the `v7` columns.

**Everything is counted** (`DNSNameStats`, inside `PipelineStats`, `Shared/IPC`): replies recorded
and the addresses they gave, datagrams that could not be read, one counter per
`DNSNameIngestion.Reason`, and the flows that were born with a name. All of them at zero while
traffic flows is the statement *the device's DNS is encrypted and there was nothing to read* — the
reason a whole session can be unnamed. Settings › *Session diagnostics* is where that statement is
made in words: `DiagnosticsPresentation.dnsNamingVerdict` ([`app-services.md`](app-services.md)
§ *The third verdict*).

`PipelineResolvedNameTests` covers the hookup: a reply followed by a UDP/443 flow to that address
comes out named with origin `dns` and an empty `sni`; the reinjected path; TCP, where a later SNI
wins without erasing the resolved name; IPv6; a flow that predates the reply; a named flow keeping
its name; the other names of a shared address reaching the store; an expired answer; the configured
limits; outbound datagrams and other ports left unread; and each counter, including the all-zero
case.
