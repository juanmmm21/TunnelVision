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

A ClientHello names a flow only when the tunnel sees one: TLS over TCP, or a QUIC connection whose
first packets passed through it ([*Naming a QUIC flow*](#above-l4-naming-a-quic-flow)). Plenty of
traffic is not TLS at all, and a connection already open when the tunnel started announces nothing
again, so many flows of a present-day phone have an address and nothing else. `ResolvedNameMap` (`Shared/DNS`) is what gives
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

## Above L4: the QUIC long header

`Shared/QUIC/QUICLongHeader.swift`, types in `Shared/Models/QUICVersion.swift`. It answers one
question about a UDP datagram — *which QUIC version does this packet say it speaks?* — and through it
a second one the flow table could not answer before: *is this UDP flow encrypted?*

```swift
public struct QUICVersion: RawRepresentable, Sendable, Hashable, Codable {   // the four wire bytes
    public static let v1: QUICVersion        // 0x00000001, RFC 9000
    public static let v2: QUICVersion        // 0x6b3343cf, RFC 9369
    public var hasKnownPacketProtection: Bool { get }   // v1 and v2, nothing else
}

public enum QUICVersionSource: String, Sendable, Hashable, Codable { case client, server }

public struct QUICVersionReading: Sendable, Hashable, Codable {
    public let version: QUICVersion
    public let source: QUICVersionSource
    public func replaces(_ current: QUICVersionReading?) -> Bool
}

public enum QUICLongHeader {
    public static func version(in payload: Data) -> QUICVersion?
}
```

### What is read

Only what RFC 8999 fixes for every version: the first byte, the four bytes of version, and the two
connection IDs with their length bytes — far enough to know they fit. Nothing is decrypted and the
ClientHello inside the Initial is not touched; that is [*Opening a QUIC Initial*](#above-l4-opening-a-quic-initial).

The long header travels only on the first packets of a connection (Initial, 0-RTT, Handshake, Retry).
Everything after uses the short header, which carries no version. **A flow whose start the tunnel did
not see therefore has no reading, and that is not the same as not being QUIC.**

### What counts as a long header

More than its top bit, because half the internet starts a datagram with a byte above `0x80` (RTP
does):

- the long-header bit **and** the fixed bit (`0x40`) set. A packet that clears the fixed bit under
  RFC 9287 is not read; that extension can only be used after the peer advertises it, so the first
  packet of a connection always has the bit;
- a version other than `0`. A Version Negotiation packet says which versions a server *would* speak,
  not which one anyone is speaking, and its other seven bits are arbitrary;
- both connection IDs inside the datagram, and — for the versions whose limit is known — no longer
  than 20 bytes (RFC 9000 § 17.2: a receiver must drop such a packet).

The version is kept as its **raw value**, like a TLS version: a draft, a vendor version or a number
made up to force a negotiation (RFC 9000 § 15) is evidence. The two named values were checked
against the IANA *QUIC Versions* registry, not written from memory.

### Encrypted is said only of what is known to be

`hasKnownPacketProtection` is true for versions 1 and 2, which protect every packet with TLS 1.3
(RFC 9001, RFC 9369), and for nothing else. A long-header shape with an unknown version is recorded
on the flow and **does not** mark it encrypted: unknown bytes that look like a header do not prove
anything, and a tool that produces evidence must not hide a possible cleartext flow behind a guess.
When the registry gains a version, it is added in that one property.

### Where it is read, and what a flow keeps

In `PacketPipeline.observe`, on every UDP datagram whose **remote** port is 443, in both directions
(what the server sends reaches the pipeline through `record(reinjected:)`). The relay reads the TLS
handshake because that needs a reassembled stream; a datagram needs nothing reassembled, and the
pipeline is where both directions pass. The reading goes to the flow table **with the packet**
(`FlowTable.observe(…, quic:)`), not through a second call: no extra actor hop, and the record
enqueued for that very packet already carries it.

- **Remote port 443 only.** That is where the device is the client, which is what lets the direction
  of the packet say which end a reading comes from. QUIC on another port exists — `Alt-Svc` may
  announce any — and is not read.
- **Which reading a flow keeps** (`QUICVersionReading.replaces`): the server's replaces anything —
  it is the version in use —; the client's replaces only an earlier client reading (its retry after
  a Version Negotiation) and never what the server said. A flow that only ever shows a `client`
  reading has a version that was *proposed*, and a reader citing it says so.
- **`tlsStatus`**: a UDP flow is born `plaintext`, port 443 or not — the port does not say it is
  QUIC. A reading with a version known to encrypt raises it to `encrypted`, and nothing lowers it
  again. So `plaintext` on a UDP/443 flow means *no QUIC start was recognised*, which covers real
  cleartext, a protocol that is not QUIC, a version this tool does not know, and a connection that
  was already open when the tunnel started. A classifier must not read it as proof of cleartext
  without looking at `quic`.
- **QUIC is never inspected** ([ADR 0006](../decisions/0006-udp-quic-passthrough.md)): recognising it
  changes a label and a column, not the route.
- **One counter**, `PipelineStats.quicVersionsObserved`: datagrams a version was read from. It
  counts readings, not flows — a connection start carries several.

The store keeps the reading in `quic_version` / `quic_from_server` (schema `v12`,
[`persistence.md`](persistence.md)).

### Tests

`QUICLongHeaderTests`: versions 1 and 2, every long packet type, an unknown version kept by value,
connection IDs at their limit and empty, a slice that does not start at index zero; and what is
*not* a long header — a short header, a Version Negotiation, a cleared fixed bit, a payload too
short, IDs that do not fit, an oversized ID on a known version (and the same length accepted on an
unknown one). `QUICVersionReadingTests`: the registry values, which versions are known to encrypt,
and the four cases of `replaces`. `FlowTableTests` (*Versión de QUIC*) and `PacketPipelineTests`
(*Versión de QUIC de un flujo*) cover the hookup: a flow born or raised to `encrypted`, short
headers leaving it alone, the server's version arriving through the reinjected path and winning, an
unknown version recorded without the mark, a non-QUIC payload and another port left `plaintext`, the
local port being 443 not counting, and the route staying passthrough with inspection on.

## Above L4: opening a QUIC Initial

`Shared/QUIC/QUICInitialKeys.swift`, `QUICInitialPacket.swift`, `QUICPacketNumber.swift` and
`QUICVarint.swift`. The long header says which version a flow speaks; the name the client asks for
is one layer down, in the ClientHello that the client's first packets carry. This section is the
part that gets to those bytes: **a client Initial in, its frames out.** It is pure — no flow, no
pipeline, no state. Reading the frames and naming the flow are separate pieces of work, described
in the two sections after this one; the pipeline calls all three since 2026-10-12.

```swift
public struct QUICInitialKeys: Sendable, Equatable {          // the client's, never the server's
    public let version: QUICVersion
    public let key: Data                    // AEAD_AES_128_GCM, 16 bytes
    public let iv: Data                     // 12 bytes
    public let headerProtectionKey: Data    // AES-128-ECB, 16 bytes
    public init?(version: QUICVersion, clientDestinationConnectionID: Data)   // nil: unknown version
}

public enum QUICHeaderProtection {
    public static func mask(key: Data, sample: Data) throws -> Data           // 5 bytes
}

public struct QUICInitialHeader: Sendable, Equatable {        // what travels in the clear
    public let version: QUICVersion
    public let destinationConnectionID: Data
    public let sourceConnectionID: Data
    public let tokenLength: Int
    public let packetNumberOffset: Int
    public let packetLength: Int            // shorter than the datagram: another packet follows
    public init(datagram: Data) throws
}

public struct QUICInitialPacket: Sendable, Equatable {
    public let header: QUICInitialHeader
    public let packetNumber: UInt64
    public let frames: Data                 // decrypted payload, padding included
    public init(datagram: Data, header: QUICInitialHeader,
                keys: QUICInitialKeys, largestPacketNumber: UInt64?) throws
}

public enum QUICPacketNumber {
    public static func decode(truncated: UInt64, byteCount: Int, largestProcessed: UInt64?) -> UInt64?
}

public enum QUICVarint {
    public static func read(from data: Data, at index: inout Data.Index) -> UInt64?
}

public enum QUICInitialError: Error, Equatable, Sendable {
    case notALongHeader, unsupportedVersion(QUICVersion), notAnInitial, connectionIDTooLong
    case truncated, tooShortToSample, keysOfAnotherVersion, headerProtectionFailed
    case authenticationFailed
}
```

### Why this is not decryption of anything private

Initial keys are not a secret. RFC 9001 § 5.2 derives them from a salt printed in the RFC and the
Destination Connection ID of the client's first Initial, which travels in the clear; RFC 9000
§ 17.2.2 says in so many words that this protection gives no confidentiality against anyone who can
see the packets — it exists so that a middlebox that does not know the version cannot rewrite them.
Any on-path observer can do what this code does, and Wireshark does it by default.
[ADR 0003](../decisions/0003-no-third-party-pinning-bypass.md) is untouched, and
[ADR 0006](../decisions/0006-udp-quic-passthrough.md) already counted the SNI of a QUIC Initial as
metadata.

The boundary is drawn in the types:

- **Only the client's keys are derived.** The server's come from the same derivation with another
  label, and nothing here wants the ServerHello.
- **Only Initial packets are read.** The long packet type is not protected, so 0-RTT, Handshake and
  Retry are refused (`notAnInitial`) before a key is touched. Handshake and 1-RTT packets use keys
  from the TLS key exchange, which the tunnel does not have and must not have.

### Two steps, because the keys depend on the header

`QUICInitialHeader(datagram:)` needs no key and gives the version and the Destination Connection ID;
the caller derives `QUICInitialKeys` from them and then opens the packet. They are separate so the
keys can be derived once per connection and kept, and because **the keys are those of the client's
first Initial, not of the packet in hand**: once the server answers, the client addresses its
packets to the connection ID the server chose and keeps protecting them with the original keys
(§ 5.2). Only a Retry changes them — the next Initial then derives from the connection ID the
server put in the Retry, which is the one that packet carries. A caller that gets
`authenticationFailed` with a connection's keys has that case to consider.

### What the header read accepts

- the long-header bit and the fixed bit, as `QUICLongHeader` does;
- **version 1 or 2**, the two whose salt and labels are known. Anything else is
  `unsupportedVersion` — a Version Negotiation (version `0`) included. The salt of another version
  is never tried;
- the Initial type **of that version**: `00` in version 1, `01` in version 2, which renumbered all
  four (RFC 9369 § 3.2). The same first byte is an Initial in one and a Retry in the other;
- connection IDs of at most 20 bytes;
- a token and a length that fit in the datagram (`truncated` otherwise), and a length of at least 20
  bytes — the packet number, the 16-byte sample and room to take it four bytes after the packet
  number starts (RFC 9001 § 5.4.2 has such a packet discarded; here `tooShortToSample`).

`packetLength` is what the Length field says, not the size of the datagram: a datagram may carry a
second packet behind the first (RFC 9000 § 12.2), and the rest of the datagram is then a packet to
read on its own.

### Opening

1. **Header protection** (§ 5.4): sixteen bytes of ciphertext, taken four bytes after the start of
   the packet number, are encrypted with AES-128-ECB under the header-protection key. The first five
   bytes are a mask: the low **four** bits of the first byte (five in a short header, which is not
   read here) and the packet number. CryptoKit has no bare block cipher, so this one block goes
   through CommonCrypto.
2. **The packet number** (RFC 9000 § 17.1) travels truncated to one to four bytes and is completed
   against the largest one already opened, with the algorithm of RFC 9000 Appendix A.3. With none
   opened the expected number is 0, where every packet number space starts. It matters because it is
   part of the nonce: a wrong guess does not open the packet.
3. **The AEAD** (§ 5.3): AES-128-GCM, nonce = IV XOR packet number, associated data = the header as
   it was before protection, first byte through packet number. A tag that does not verify is
   `authenticationFailed` and no bytes come out — an altered packet, a packet of another connection
   and keys from the wrong connection ID are indistinguishable, and need not be told apart.

The reserved bits are not checked: the endpoint that receives the packet is the one to treat them
as a protocol violation, and an observer that dropped the packet would only know less.

### What is not here

- **Frames.** `frames` is the payload as decrypted: CRYPTO frames, PADDING, sometimes PING or ACK.
  Walking them and reassembling CRYPTO by offset, across several Initial packets, into a
  ClientHello is the next section.
- **The hookup.** Where the pipeline calls this and what a flow gains from it is
  [*Naming a QUIC flow*](#above-l4-naming-a-quic-flow).
- **Other versions.** A version gets keys when its RFC's salt and labels are added to
  `QUICInitialKeys`, with that RFC's sample packet as the test.

### Tests

The expected values are the ones the RFCs print, **copied from the documents, not computed**:

- `QUICInitialKeysTests`: the client key, IV and header-protection key of RFC 9001 § A.1 and
  RFC 9369 § A.1; no keys for an unknown version; an empty connection ID; the header-protection
  mask of both § A.2; a key or sample of another size.
- `QUICInitialPacketTests`: **the client Initial of RFC 9001 § A.2 and of RFC 9369 § A.2 open to
  packet number 2 and the CRYPTO frame the RFC prints, followed by padding to 1162 bytes**
  (`QUICRFCVectors`, whose hex was extracted from the RFC text by a script). What the RFCs do not
  bring is written by a test fixture that really protects a packet: every packet-number length in
  both versions, the shortest packet that can be sampled, a token and a source connection ID, keys
  from a connection ID other than the one the packet carries, a second packet in the datagram, a
  truncated packet number that only the largest seen completes. And what does not open: a byte
  altered in the cleartext header, the ciphertext or the tag; keys of another connection or another
  version; a datagram shorter than its header says. And what is not an Initial: no long header, a
  version without known protection, the other three packet types of each version, an oversized
  connection ID, a packet cut at every byte of its header, a token that does not fit, a packet too
  short to sample.
- `QUICVarintTests` and `QUICPacketNumberTests`: the samples of RFC 9000 Appendices A.1 and A.3,
  both ends of the window, and what is refused.

## Above L4: from CRYPTO frames to a ClientHello

`Shared/QUIC/QUICInitialFrames.swift` and `QUICCryptoStream.swift`, both pure, and
`PacketTunnel/TLS/QUICClientHelloScanner.swift`, which joins them to the ClientHello reader that
TCP flows already use. **The decrypted payloads of a client's Initial packets in, the name it
announced out.** Which Initials of a flow are opened, with which keys, and where the name goes are
the hookup's decisions ([*Naming a QUIC flow*](#above-l4-naming-a-quic-flow)).

```swift
public struct QUICCryptoFrame: Sendable, Equatable {           // Shared/QUIC
    public let offset: UInt64
    public let data: Data
}

public struct QUICInitialFrames: Sendable, Equatable {         // Shared/QUIC
    public enum Stop: Error, Sendable, Equatable {
        case unexpectedFrameType(UInt64), truncated, cryptoBeyondStreamLimit
    }
    public let crypto: [QUICCryptoFrame]    // in wire order
    public let stop: Stop?                  // nil: the whole payload was walked
    public init(payload: Data)
}

public struct QUICCryptoStream: Sendable, Equatable {          // Shared/QUIC
    public struct Limits: Sendable, Equatable {
        public init(maxStreamBytes: Int, maxPendingFragments: Int)   // no defaults
    }
    public enum Exceeded: Sendable, Equatable { case streamBytes, pendingFragments }
    public enum Delivery: Sendable, Equatable {
        case delivered(Data)                // the bytes now in order; may be empty
        case exceeded(Exceeded)             // terminal
    }
    public init(limits: Limits)
    public private(set) var deliveredByteCount: Int
    public private(set) var exceeded: Exceeded?
    public var pendingFragmentCount: Int { get }
    public mutating func insert(_ frame: QUICCryptoFrame) -> Delivery
}

struct QUICClientHelloScanner: Sendable {                      // PacketTunnel/TLS
    enum Outcome: Sendable, Equatable {
        case needMoreFrames, found(String), unavailable(Reason)
    }
    enum Reason: Sendable, Equatable {
        case clientHello(ClientHelloScanner.Reason)
        case cryptoStream(QUICCryptoStream.Exceeded)
    }
    var offer: ClientTLSOffer? { get }
    init(streamLimits: QUICCryptoStream.Limits, maxHandshakeBytes: Int)
    mutating func scan(initialPayload: Data) -> Outcome
}
```

### Walking the frames

An Initial packet can carry five kinds of frame (RFC 9000 § 12.4, Table 3), and the walker knows the
length of each, because the CRYPTO frame may sit behind any of them — clients put padding first, and
the Initial that retransmits a ClientHello usually opens with the ACK of the server's Initial:

| Type | Frame | What is skipped (RFC 9000 § 19) |
|---|---|---|
| `0x00` | PADDING | the byte |
| `0x01` | PING | the byte |
| `0x02`, `0x03` | ACK | four varints, two more per range, and for `0x03` three ECN counts |
| `0x06` | CRYPTO | **kept**: offset, length, data |
| `0x1c` | CONNECTION_CLOSE | error code, frame type, and the reason phrase by its length |

What had to be decided:

- **Anything else stops the walk of that packet** (`unexpectedFrameType`): the frames an Initial may
  not carry — streams, flow control, `0x1d`, HANDSHAKE_DONE — and any type not defined. Without
  knowing a frame's length there is no finding the next one.
- **What was read before the stop is kept, and the stop ends the packet, not the connection.** It is
  the recipient that closes a connection over a frame that does not belong; what the client had
  already said in the frames before it, it said all the same.
- **A frame type in a longer encoding than necessary is accepted.** RFC 9000 § 12.4 requires the
  shortest one and lets the recipient treat anything else as a violation — a MAY, and an observer
  that refused the packet would only know less. Same reasoning as `QUICVarint`.
- **No count or length chosen by the peer is walked or allocated before it is checked against the
  payload.** An ACK's range count is refused if the bytes left cannot hold two varints per range; a
  CRYPTO length or a reason phrase longer than what is left is `truncated`.
- **A CRYPTO frame ending past 2^62 − 1 stops the walk** (`cryptoBeyondStreamLimit`, § 19.6).
- **What an ACK acknowledges is not validated**, and the contents of a CONNECTION_CLOSE are not
  kept: neither is the observer's business.

### Reassembling the stream

A ClientHello with a post-quantum key share does not fit in one Initial, so its CRYPTO frames arrive
in two or three packets, and not tidily: packets overtake each other, a retransmission repeats what
was seen, and some clients cut the ClientHello into pieces and shuffle them inside a single packet.
`QUICCryptoStream` takes frames in arrival order and hands back the stream's bytes **in order and
exactly once**.

- **It does not keep what it has delivered.** The caller feeds the bytes to an incremental reader
  that has its own ceiling; the stream holds only what arrived ahead of a gap, as fragments that
  never overlap or touch — two that would are merged into one.
- **Where two frames disagree about the same byte, the one that arrived first wins**, and they are
  not compared: treating it as an error is the recipient's MAY (RFC 9000 § 2.2), and here it is
  enough that a later frame cannot rewrite what was already read.
- **Two limits, neither with a default.** `maxStreamBytes` is how far into the stream a byte is
  accepted, and — since what is held does not overlap — also the most the stream can retain.
  `maxPendingFragments` is how many separate fragments may wait at once, counted after merging and
  after delivering, so a frame that arrives in order never counts. The frames are written by the
  other end and this runs in the extension: how much memory a flow's name is worth is for the
  hookup to say.
- **Past either limit the stream is given up for good**: it drops what it held and every later
  insert answers `exceeded`. A ClientHello that does not fit is not going to be read later.

### Handing it to the ClientHello reader

QUIC carries the TLS handshake message **without the record layer**: the content of a handshake
record goes into CRYPTO frames, not the record (RFC 9001 § 4.1.3). So `ClientHelloScanner` gained a
`Framing` — `.tlsRecords`, what it always read, and `.handshakeMessages`, the message as it is — and
everything past the record layer is the same code: the name, the offer, the validation of the host
name, the ceiling ([`relay-and-tls.md`](relay-and-tls.md) § *SNI without decryption*). A QUIC flow's
name and offer therefore follow the same rules as a TCP flow's, Encrypted Client Hello included:
the name read is the outer one and the offer says so.

`QUICClientHelloScanner` is the join: per payload, the frames are walked, each CRYPTO frame goes
into the stream, and whatever comes out in order goes to the reader. Like the reader, **it settles
and stays put** — after a definitive outcome it drops what it held and looks at no further frame.
Its `Reason` keeps apart a message that was read and gave no name (`clientHello`) from a stream
that was given up (`cryptoStream`).

It opens no packet and holds no key. The boundary of the previous section stands: the client's
Initial packets, the ClientHello, and nothing else.

### What is not here

The per-flow state the opening needs (the keys of the first connection ID, the largest packet
number opened), the values of the limits and how many Initials of a flow are looked at: all of
that is the hookup, [*Naming a QUIC flow*](#above-l4-naming-a-quic-flow).

### Tests

- `QUICInitialFramesTests`: **the payload of the RFC 9001 § A.2 sample — as printed, and as opened
  from the protected packets of both versions — is one CRYPTO frame at offset 0 with the 241 bytes
  of the ClientHello.** CRYPTO found behind padding, PING, an ACK without ranges, with ranges and
  with ECN counts, and a CONNECTION_CLOSE with and without a reason; several CRYPTO frames in wire
  order; a longer encoding of the type; an eight-byte offset; a payload that is a slice of a larger
  buffer. What stops the walk: every type from `0x00` to `0x3f` that an Initial cannot carry, a
  multi-byte unknown type, each kind of frame cut at every byte, a range count, a CRYPTO length and
  a reason length larger than the payload, and a CRYPTO frame one byte past the stream limit.
- `QUICCryptoStreamTests`: in order; split at every point and delivered backwards; three pieces in
  all six orders; delivery only up to the first gap; retransmissions; a frame straddling what was
  delivered; fragments that overlap or touch becoming one; first bytes winning, also against what
  was delivered; **a thousand seeded cuts of one message — shuffled, repeated, overlapping — each
  giving the message back**; and both limits at their edge, one past it, and at zero, including an
  offset no buffer could hold.
- `QUICClientHelloScannerTests`: **`example.com` and the offer out of the RFC's ClientHello, from
  the printed frame and from the protected packets of both versions**; the ClientHello spread over
  three really protected Initials arriving out of order; split in two at every point in both
  arrival orders; larger than one Initial; shuffled inside one packet; a retransmitted Initial; a
  packet stopped by an unexpected frame; no server name, ECH, not a ClientHello, malformed; the
  three limits; and the outcome staying put.
- `ClientHelloScannerTests`: the message without records read whole and split at every byte, what
  follows it ignored, each framing refusing the bytes of the other, and the ceiling.

## Above L4: naming a QUIC flow

`PacketTunnel/TLS/QUICClientHelloReader.swift`, `PacketTunnel/Pipeline/QUICNameReadLimits.swift`,
the hookup in `PacketPipeline`, and the counters in `Shared/IPC/QUICNameStats.swift`. **The UDP
datagrams a device sends to port 443 in, the name its QUIC client announced on the flow.** This is
what the two previous sections were built for.

```swift
public struct QUICClientHelloReader: Sendable {                // PacketTunnel/TLS
    public struct Limits: Sendable, Equatable {
        public let maxInitialPackets: Int
        public let stream: QUICCryptoStream.Limits
        public let maxHandshakeBytes: Int
        public init(maxInitialPackets: Int, stream: QUICCryptoStream.Limits, maxHandshakeBytes: Int)
        public static let tunnel: Limits     // 8 Initials, 8 192 + 8 192 bytes, 32 fragments
    }
    enum Outcome: Sendable, Equatable {
        case needMoreInitials, found(String), unavailable(Reason)
    }
    enum Reason: Sendable, Equatable {
        case clientHello(ClientHelloScanner.Reason)
        case cryptoStream(QUICCryptoStream.Exceeded)
        case initialsExhausted
    }
    struct Reading: Sendable, Equatable {
        var outcome: Outcome
        var offer: ClientTLSOffer?           // only on the reading that settles the outcome
        var opened: Int                      // Initial packets of this datagram that opened
        var notOpened: Int
        var restarted: Bool                  // started over with another connection ID's keys
        var attemptedAnInitial: Bool { get }
    }
    init(limits: Limits)
    mutating func read(datagram: Data) -> Reading     // the UDP payload, whole
}

public struct QUICNameReadLimits: Sendable, Equatable {        // PacketTunnel/Pipeline
    public let perFlow: QUICClientHelloReader.Limits
    public let maxConcurrentReads: Int
    public init(perFlow: QUICClientHelloReader.Limits, maxConcurrentReads: Int)
    public static let tunnel: QUICNameReadLimits      // .tunnel per flow, 64 reads at once
}

public struct QUICNameStats: Sendable, Equatable, Codable {    // Shared/IPC, in PipelineStats.quicNames
    public var initialsOpened, initialsNotOpened, readsRestarted, initialsSkippedAtCapacity: UInt64
    public var flowsNamed: UInt64
    public var withoutServerName, unreadableClientHello, cryptoStreamAbandoned, initialsExhausted: UInt64
    public var flowsLeftUnnamed: UInt64 { get }
}
```

### The state one flow needs

`QUICClientHelloReader` is what a flow keeps between its first Initial and the moment its name is
known: the client's Initial keys, the largest packet number opened, and a `QUICClientHelloScanner`.
It is given the UDP payloads the client sends, whole and in arrival order.

- **A datagram is walked packet by packet** (RFC 9000 § 12.2) for as long as they are Initial
  packets of a known version, each skipped by the length its header declares. The first thing that
  is not one — a 0-RTT or Handshake packet, padding — ends the walk: nothing behind it is this
  reader's.
- **Keys are derived from the first Initial seen and kept**, because that is how the client uses
  them: after the server answers, its packets are addressed to another connection ID and still
  protected with the first one's keys.
- **A packet the kept keys do not open is tried once with the keys of its own connection ID.** That
  is what follows a Retry — the client starts over with the ID the server gave it — and what a new
  connection on the same pair of ports looks like. If they open it, **the read starts over**: new
  keys, no largest packet number, an empty CRYPTO stream. After a Retry the ClientHello is sent
  again from offset zero, so nothing is lost; and if it was another connection, what had been
  reassembled was not its own. A packet whose own ID is the one the keys came from is not tried
  twice.
- **It settles and stays put**, and on settling it drops keys and scanner. The offer is handed over
  on the reading that settles and not again.
- **The budget of Initials is spent by every packet an opening is attempted on, opened or not** —
  otherwise a flow of packets that never authenticate would have the tunnel deriving keys and
  running the AEAD without end — and the read is given up **on the packet that spends the last
  one**, not on the next, which may never come. A datagram that carries no Initial spends nothing.

### The limits, and where their values come from

Until this step every limit was a parameter without a default. Their values were set against
**what two real clients send**, captured on 2026-10-11 against a local UDP socket that never
answers (`QUICClientCaptures` in the tests; names under `.test`):

| | ClientHello | Initials | CRYPTO frames per packet |
|---|---|---|---|
| Apple's QUIC stack (`NWProtocolQUIC`, macOS 27) | 1 506 bytes | 2 | 1, in order |
| Chrome 155 | 1 951 bytes | 2 | 10 and 9, shuffled; 7, 3 and 11 in its retransmissions |

| Limit | Value | Why |
|---|---|---|
| `maxInitialPackets` | 8 | Four times the two that are needed: room for a Retry (everything is sent twice) and for a couple of retransmissions or a packet that does not open |
| `stream.maxStreamBytes`, `maxHandshakeBytes` | 8 192 | Four times the largest ClientHello measured. A flow being read cannot hold more than this twice over |
| `stream.maxPendingFragments` | 32 | Nearly three times the eleven frames of the most shredded packet captured, which is what would wait if none of them touched another. The captures peak at 3 |
| `maxConcurrentReads` | 64 | A read lasts the first two datagrams of a connection, so the reads open at once are the connections being opened at that instant. 64 × 16 384 bytes is 1 MB in a worst case that only traffic written to fill it reaches |

`QUICClientHelloReaderTests` asserts the measurements against the captures, so a capture replaced
by a larger one fails the test that justifies the values.

**Cost, measured:** deriving the keys, opening Chrome's two Initials and reassembling its
ClientHello takes about **80 µs per flow** (Debug build, Simulator on an Apple-silicon Mac;
`testCostOfReadingTheNameOfAChromeFlow`). It is paid once per QUIC connection. Every other
datagram of the flow costs one bit test — the long-header bit — or, for the long-header packets
that follow the Initials, one dictionary lookup.

### Where it is read, and where the name goes

In `PacketPipeline.observe`, **after** the flow table has seen the packet, on UDP datagrams the
device **sends** to remote port 443 — the same port rule as the version. Not in the relay, where
the TCP ClientHello is read: that choice was made for the reassembled stream, and QUIC brings its
own reassembly inside the packets.

- **Outbound only.** The ClientHello is the client's, and only the client's keys are derived. An
  Initial arriving from the server is counted as a version reading and nothing more.
- **The name goes in `sni`.** It is what the connection announced about itself, read from its own
  ClientHello by the same reader and the same rules as a TCP flow's — not an inference. The rule
  that keeps the DNS name out of that column is about *deduced* names
  ([`data-model.md`](data-model.md)); this one is announced. `FlowName` therefore gives it the
  origin `sni` and lets it win over the resolved name, which stays in its own field.
- **The offer goes in `clientTLS`**, also when there is no name: it is what tells *announced no
  name* (`serverNameNotAnnounced`) from *no ClientHello was read* (`noClientHelloRead`), and what
  carries the Encrypted Client Hello mark. With ECH the name read is the outer one, as on TCP.
- **One call to the table, with an answer** (`FlowTable.setQUICClientHello`): the record that the
  completing packet sends to the store already carries the name, without waiting for another packet
  of the flow.
- **`tlsStatus`, the route and the QUIC version do not change.** QUIC is relayed untouched
  ([ADR 0006](../decisions/0006-udp-quic-passthrough.md)); pinning on a QUIC flow is still not
  assessed.
- **What the pipeline keeps per flow** is `reading` (the reader) until the outcome is known and then
  `settled`, a marker with nothing in it whose job is to keep a late retransmission of the Initial
  from opening a second read. Both carry the `firstSeen` of the flow they belong to: a flow key is
  recycled, and the closing record of one life can reach the flush after the next life has sent its
  Initial. What was noted for another life is dropped on sight, and a closing record only takes
  away what was its own.
- **The quota counts reads in progress**, not settled flows. With it full, the Initial of a new flow
  is not opened — no key is derived — and is counted (`initialsSkippedAtCapacity`, only datagrams
  that start with an Initial); the flow keeps whatever name DNS gave it, and a retransmission that
  finds room is read.
- **Everything is counted** (`PipelineStats.quicNames`, over the control channel): packets opened
  and not, restarts, skips, flows named, and one counter per way of ending without a name.

The boundary of *Opening a QUIC Initial* stands, and the hookup adds nothing to it: the client's
Initial packets, its ClientHello, and nothing else.

### What is not here

- **A capture from an iPhone.** The two clients were captured on a Mac. Apple's stack is the same
  one iOS uses; Safari and Chrome for iOS have not gone through this.
- **Connection migration and QUIC on other ports**, for the reasons the version reading gives.

### Tests

- `QUICClientHelloReaderTests`: **the datagrams of both real clients give their name and offer
  with the tunnel's limits** — in order, with the first flight swapped, from retransmissions alone,
  and the whole capture settling on its second datagram and opening nothing afterwards; the RFC
  sample packets of both versions; a later Initial addressed to the server's ID opening with the
  first keys; a Retry restarting the read without mixing what came before; a packet that does not
  authenticate, also as the first of a flow; the packet number completed against the largest
  opened; two Initials coalesced, a 0-RTT packet behind an Initial, a payload that is a slice; six
  kinds of datagram that are not a client Initial spending nothing; no server name, ECH, not a
  ClientHello; the budget of Initials at its edge, spent by packets that do not open and counted
  per packet; the stream and handshake limits reaching the scanner; staying put; the tunnel's
  values against the measurements; and the cost.
- `PipelineQUICNameTests`: **both real captures through the pipeline leave the flow with `sni`,
  the offer, `encrypted` and its version, two Initials opened and nothing left open**; the name
  travelling with the packet that completes the ClientHello; the announced name winning over the
  resolved one with both kept; every way of ending without a name on its counter; unopened packets
  and restarts counted; inbound Initials, another port and non-Initial datagrams not read; the
  quota skipping a new flow until there is room and not counting settled ones; a flow closed
  mid-read releasing it; a flow born later under the same key read again; and the late closing
  record of an earlier life leaving the new one's read alone.
- `QUICNameStatsTests` and `ControlChannelTests`: the sum of the unnamed counters, and every
  counter surviving the control channel.
