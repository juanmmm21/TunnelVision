# Shared/Models

Domain value types shared everywhere: `FlowKey`, `IPEndpoint`, `IPAddress`, `FlowRecord`,
`PacketMeta`, header structs, and the `TLSInspectionStatus` / `Direction` / `IPVersion` enums.
All `Sendable`; Foundation-only.

`FlowName.swift` is the name of a flow together with where it came from: the SNI the connection
announced, or the name the DNS had given its address (`ResolvedFlowName`). Two fields, never one.

`NegotiatedTLS.swift` is what a server chose for a TLS connection: `TLSProtocolVersion` and
`TLSCipherSuite`, both structs over the raw wire value rather than closed enums, because the other end
picks the value and whatever it sent is kept as sent. `ServerTLSAnswer` is what a flow carries of it:
a negotiation, or the alert the server refused with. Spec:
[`../../docs/spec/relay-and-tls.md`](../../docs/spec/relay-and-tls.md) § *What the server chose*.

`ServerCertificate.swift` is what a TLS ≤ 1.2 server presented behind that answer: a
`ServerCertificateChain` of subject, issuer and expiry (a prefix of what was sent, with `isComplete`),
or the reason the handshake carried none. `ServerCertificateVisibility` is what a report reads — it
adds the reason when there is nothing to show, so that "TLS 1.3 encrypts it" is said instead of left
blank. Spec: same file, § *The certificate chain of TLS ≤ 1.2*.

`ClientTLSOffer.swift` is the other half: what the **client** offered in its ClientHello — the TLS
versions it accepts and its ALPN. `OfferedTLSVersions` is an enum because a list from
`supported_versions` is exact and a bare `legacy_version` is only a ceiling, and a report must not
confuse the two. Spec: same file, § *What the client offered*.

`QUICVersion.swift` is the QUIC counterpart: the version from a long header as its raw four bytes,
and `QUICVersionReading`, which adds the end it was read from — a client's version is a proposal, a
server's is the one in use. `hasKnownPacketProtection` is the only place that says which versions
are known to encrypt, and it is what lets a UDP flow be called `encrypted`. Spec:
[`../../docs/spec/packet-parsing.md`](../../docs/spec/packet-parsing.md) § *Above L4: the QUIC long
header*.

`StreamOpening.swift` is what a TCP stream opened with — a TLS handshake, an HTTP request in the
clear, or neither — on any port. It exists because `TLSInspectionStatus` on TCP comes from the
port. Spec: [`../../docs/spec/relay-and-tls.md`](../../docs/spec/relay-and-tls.md) § *How a stream
opened*.

`TunnelAddressing` also lives here (it moved out of the extension in M9): the tunnel's own IPs are
knowledge of *both* processes — the extension announces them to NetworkExtension and compares against
them to resolve direction, and the app needs them to tell which endpoint of a canonical `FlowKey` is
the device. Its milestone is M7; its spec is
[`../../docs/spec/tunnel-provider.md`](../../docs/spec/tunnel-provider.md).

`MonotonicAnchor` moved here in M9 for the same reason: the app needs it to date the live feed and the
extension needs it to date what it writes to the store. It pairs a `CLOCK_UPTIME_RAW` reading with the
wall clock at the same instant — taken once per session, so the relative spacing between packets stays
exact. `WallClock` next to it converts to and from the nanoseconds-since-epoch used on disk.

`CaptureLocation` and its neighbours (`CaptureFileName`, `CaptureFile`, `CaptureDirectory`) moved in
for the third time on the same argument: the extension writes capture files and the app resolves them.
A packet stores *where* its bytes are as a pair (file sequence + record offset), because the writer
rotates by size and every file restarts its offsets — an offset alone points into an unknown file. The
naming rules live next to the type so formatting a name and reading it back cannot drift apart. Their
milestone is M6/M9; their spec is [`../../docs/spec/pcap.md`](../../docs/spec/pcap.md).

`AppSettings` (with `CaptureDetail` and `RetentionSettings`) is here for the same reason as everything
above: it is what the user decided, and **both** processes read it — the app writes it when a setting is
touched, the extension reads it when it starts a session. What it means for the capture lives with it
(`CaptureDetail.snaplen`, `RetentionAge.maxAge`, `RetentionSize.maxBytes`) so no caller has to translate
a choice into a number twice. Where it is *stored* is `Shared/IPC/SettingsStore.swift`, next to the other
cross-process contracts. Its milestone is M9; its specs are
[`../../docs/spec/ipc.md`](../../docs/spec/ipc.md) and
[`../../docs/spec/app-services.md`](../../docs/spec/app-services.md).

**Spec:** [`../../docs/spec/data-model.md`](../../docs/spec/data-model.md) · **Milestone:** M1
