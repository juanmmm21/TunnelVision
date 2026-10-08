# Spec — Relay and opt-in TLS inspection (`PacketTunnel/Relay`, `PacketTunnel/TLS`)

Two responsibilities that share a module boundary: (1) forward every flow to the real internet
(the default), and (2) for flows the user opted to inspect, terminate TLS locally, log
plaintext, and re-originate to the true server. The security invariants here are the heart of
the project — read [`../decisions/0003-no-third-party-pinning-bypass.md`](../decisions/0003-no-third-party-pinning-bypass.md).

## Relay (always on)

```swift
public actor Relay {
    public init(reinject: @escaping ([Data], [NSNumber]) -> Void)   // packetFlow.writePackets

    /// Passthrough de un flujo: abre/usa una NWConnection saliente y reinyecta las respuestas.
    public func passthrough(_ packet: ParsedPacket, raw: Data) async

    /// Cierra y libera un flujo.
    public func close(_ key: FlowKey)
}
```

- Outbound connections use `Network.framework` (`NWConnection`). Connections **originated by
  the extension** are not routed back into the tunnel by iOS, so they reach the real internet
  directly; responses are converted to IP packets and reinjected via `writePackets`.
- **UDP and QUIC** are always passthrough (never terminated). VoIP/streaming stays low-latency.
- Passthrough keeps only what it needs in flight; it does not buffer whole flows.

### Implemented so far (M8, first half) — UDP passthrough ✅

The `Relay` actor exists and does the **stateless** half: UDP/QUIC passthrough. Two deviations from the
sketch above, both deliberate:

- **`init` also takes a `connectionFactory`** (`RelayConnectionFactory`, defaulting to the production
  `NetworkConnectionFactory`). `NWConnection` can't be exercised usefully on the Simulator, so it is
  hidden behind injected `RelayConnection`/`RelayConnectionFactory` protocols — the same move M7 made
  with its sinks — and the relay's logic is tested against a double. `NetworkRelayConnection` /
  `NetworkConnectionFactory` are the production conformers (`Network.framework`), validated by
  compilation under strict concurrency.
- **`passthrough` handles UDP only for now.** TCP passthrough is not stateless — it needs the userspace
  TCP state machine (below), which is the next increment. A non-UDP packet reaching `passthrough` is
  counted (`RelayStats.unsupportedPackets`) and not forwarded, so a mis-route is visible, not silent.
  Contract: every packet handed to `passthrough` is **outbound** (from the device); the relay does not
  know the tunnel IP (the pipeline resolves direction), so it relies on the provider only routing
  device-originated packets here.

`close(_:)` cancels and forgets a flow's connection (called when `FlowTable` closes it); `closeAll()`
tears down every connection on `stopTunnel`. Bounded failures: an oversize reply that won't fit a
datagram is counted (`RelayStats.emitterFailures`) and dropped, never fatal. **Known loose end:** the
reinjected replies are not (yet) recorded back through the pipeline, so inbound bytes are delivered to
the device but do not appear in the flow history/live feed — the pipeline records what the *device*
sends; recording relayed replies is a later concern.

### Implemented so far (M8, first half, cont.) — TCP passthrough state machine ✅

TCP passthrough is **state, not serialization**: the device believes it opened a TCP connection to the
real server, but the extension intercepts its datagrams. So the extension has to **terminate that TCP in
userspace** — play the server toward the device (SYN-ACK, cumulative ACKs, close) to extract the
application byte stream — and re-originate that stream over its own `NWConnection` (which runs its own
TCP against the real server). The two directions are two independent 32-bit sequence spaces that wrap
(serial arithmetic, RFC 1982).

`TCPRelayFlow` (`PacketTunnel/Relay/TCPRelayFlow.swift`) is that state machine, and it is **pure and
synchronous** — it knows nothing of `NWConnection`, the `PacketEmitter`, or the reinjector. It takes
events (`receiveFromDevice`, `receiveFromServer`, `serverDidConnect/Close/Fail`) and returns a list of
`TCPRelayAction` values (`connectToServer`, `sendToServer(Data)`, `closeServerSend`,
`segmentToDevice(OutboundSegment)`, `teardown`) that the `Relay` actor will execute. This is the same
pure-core/injected-shell split M7's pipeline and the UDP relay use: the logic runs on the Simulator
against direct assertions, and the device-only surface (the TCP `NWConnection` and the emitter call) is a
thin shell. Design decisions:

- **SYN-ACK is deferred until the server connection is up** (`serverDidConnect`), not spoofed on the
  device's SYN. This makes the handshake faithful: if the real server would refuse (`serverDidFail`
  before we sent SYN-ACK), the device sees a connection-refused `RST`/`ACK` (seq 0, ack = clientISN+1),
  exactly as the server would send — we never fake an established connection we'd have to reset.
- **The device's outbound stream is reassembled** with M4's `TCPReassembler` (per-flow, in-order,
  bounded). Delivered bytes go to the server as `sendToServer`; every accepted segment triggers a
  cumulative ACK back to the device. A FIN is only consumed in order (the reassembler's
  `expectedSequence` gauges this); out-of-order FINs are deferred for the device to retransmit.
- **The server's inbound stream is re-segmented** by our MSS and paced to the **device's advertised
  window** (never more than `window` bytes unacknowledged in flight); excess is buffered until the device
  ACKs open the window. We advertise our own constant window (we drain the device's stream immediately),
  and we do **not** implement retransmission toward the device — the device↔extension path is local and
  lossless, and a device retransmit is absorbed idempotently by the reassembler.
- **Close is modeled with two half-close flags** rather than the full RFC 9293 state set: a device FIN
  half-closes the server's send side (`closeServerSend`); a server EOF flushes then emits our FIN; once
  both FINs are exchanged and ours is ACKed, `teardown`. A device `RST` tears down immediately with no
  reply.
- **Bounded degradations, never unbounded growth** (same philosophy as M4/M7): a reassembler downgrade
  (a huge gap) or an overflow of the bounded device-facing buffer aborts the flow with a `RST` to the
  device. The `serverISN` is **caller-provided** (the `Relay` supplies an unpredictable value from the
  system RNG — a TCP security requirement — while tests pass a known value for deterministic sequence
  round-trips).

**Tests (21):** the full handshake (SYN → deferred connect → SYN-ACK → established), device→server data
with cumulative ACK (in order, out of order buffering then splicing, retransmit not double-forwarded),
server→device data (single, MSS-split, window-limited then drained), graceful close in both orderings,
data+FIN in one segment, device `RST`, server refusal and mid-connection failure, the two bounded
degradations, `UInt32` sequence wraparound in both spaces, and an `OutboundSegment` round-tripped through
`PacketEmitter.tcp` + `PacketParser` (proving the chosen seq/ack/flags land correctly on the wire).
**196 total.**

### Implemented so far (M8, first half, cont.) — TCP passthrough wiring ✅

`TCPRelayFlow` is now driven by the `Relay` actor, so TCP passthrough is complete in code (only the
device-only provider hookup remains, part of M7's DoD). `passthrough` routes a TCP packet to a
per-`FlowKey` `TCPRelayFlow`, builds an `InboundSegment` from the parsed header + payload, and executes
the returned `TCPRelayAction`s against an injected connection:

- **`RelayConnection` is unified for UDP and TCP** with two additions. `start` gained an `onReady`
  callback — TCP **defers its SYN-ACK** until the outbound connection is established (`NWConnection`'s
  `.ready`); UDP ignores it. `closeSend` half-closes the send side (production maps it to
  `send(content: nil, isComplete: true)`; a default no-op means UDP conformers need not implement it).
  The factory gained `makeTCPConnection(to:)`, whose production connection uses `receive` (stream), not
  `receiveMessage`, with `isComplete` ⇒ clean close (server FIN) and `.failed` ⇒ failure.
- **The `serverISN` is supplied by the `Relay`**, not `TCPRelayFlow`: unpredictable in production
  (`UInt32.random`, a TCP security requirement), injected (`serverISNProvider`) for deterministic tests.
- **The action executor lives in the actor.** `connectToServer` opens and starts the connection (its
  `onReady`/`onReceive`/`onClose` re-enter the actor as `serverDidConnect`/`receiveFromServer`/
  `serverDidClose`|`serverDidFail`, each returning more actions); `sendToServer` ⇒ `connection.send`;
  `closeServerSend` ⇒ `connection.closeSend`; `segmentToDevice` ⇒ `PacketEmitter.tcp` with endpoints
  swapped (source = server, destination = device) + reinject; `teardown` ⇒ cancel and forget the flow.
  Within one batch a `segmentToDevice` (e.g. a RST) always precedes its `teardown`, so emitting while the
  flow is still present and removing it afterward is correct.
- **`close(key)` covers both protocols** (the `FlowTable`-decided close, not the one the TCP state
  machine already resolves itself by emitting `teardown`); `closeAll` cancels UDP + TCP.
- **`RelayStats` gained TCP counters** (`tcpFlowsOpened`, `tcpFlowsClosed`, `tcpSegmentsReinjected`,
  `tcpBytesToServer`, `tcpResetsToDevice`). The "unsupported" case is now ICMP-and-the-like — anything
  neither UDP nor TCP.

**Tests (9 wiring, 205 total):** SYN opens the connection + defers the SYN-ACK, SYN-ACK on `ready` with
the right seq/ack, device data forwarded to the server + cumulative ACK to the device, server data
re-segmented to the device, graceful close (device FIN half-closes the server, server EOF emits our FIN,
device ACK tears down), server refusal before SYN-ACK ⇒ connection-refused RST, device RST ⇒ silent
teardown, `close` from the flow table cancels the connection, and `closeAll` across both protocols.
### Implemented so far (M8, first half, cont.) — the provider hookup ✅

El relay ya está **enchufado**, que era lo único que separaba al proyecto de tener conectividad con el
túnel encendido: `TunnelRuntime` lo crea en `start` con `packetFlow.writePackets` inyectado como
`reinject`, el bucle de lectura le pasa todo datagrama que el pipeline no descarte, cada `tick` le
cierra los flujos que la tabla dio por terminados (`PacketPipeline.drainClosedFlowKeys`) y `stop` le
llama a `closeAll()` antes que a nadie. Detalle y decisiones en
[`tunnel-provider.md`](tunnel-provider.md). Lo device-only aquí es la *comprobación*, no el código:
el cableado se valida por compilación bajo concurrencia estricta y lo que el pipeline le da al bucle
se prueba en Simulator.

**Comprobado en hardware** (iPhone 17, 2026-08-12): con el túnel monitorizando el dispositivo conserva
internet y le llega tráfico real. Y **lo reinyectado ya se registra**: el closure de reinyección
entrega al dispositivo y encola el datagrama para `PacketPipeline.record(reinjected:protocolFamily:)`
por una cola serial y con tope, así que las respuestas entran en el historial, en el feed en vivo y en
el `.pcap` — hasta entonces `bytesIn` era siempre cero y la captura llevaba media conversación.
Detalle y decisiones en [`tunnel-provider.md`](tunnel-provider.md).

**Still pending:** la **segunda mitad** (terminación TLS opt-in), abajo. El cabo que había aquí
—`RelayStats` sin viajar por el canal de control— **está cerrado** (M11): los contadores salen ya
emparejados con los del pipeline dentro de un `TunnelStats` y se leen desde Ajustes › *Session
diagnostics* ([`tunnel-provider.md`](tunnel-provider.md), [`app-services.md`](app-services.md)). El
tipo vive desde entonces en `Shared/IPC/RelayStats.swift`, porque cruza el canal.

### Reinjection: the packet emitter (`Shared/IP`) ✅

`NWConnection` hands back **transport bytes**, not datagrams. To return them to the device via
`packetFlow.writePackets` the whole IP datagram has to be rebuilt — IP + TCP/UDP headers, checksums,
directions swapped. That is `PacketEmitter`, the mirror of M3's `PacketParser`:

```swift
public enum PacketEmitter {
    public static func tcp(
        source: IPEndpoint, destination: IPEndpoint,
        sequence: UInt32, acknowledgment: UInt32,
        flags: TCPFlags, windowSize: UInt16, payload: Data = Data()
    ) throws -> Data

    public static func udp(source: IPEndpoint, destination: IPEndpoint, payload: Data) throws -> Data
}

public enum PacketEmitError: Error, Sendable, Equatable {
    case addressFamilyMismatch(source: IPVersion, destination: IPVersion)
    case datagramTooLarge(byteCount: Int, limit: Int)
}
```

It lives in `Shared/IP`, **not** in `Relay/`: serializing IP is the same layer as parsing it,
the round-trip tests belong next to each other, and a future caller that just needs to inject a
datagram (a RST, say) should not have to depend on the whole relay. Design decisions:

- **Output is a raw `LINKTYPE_RAW` datagram** — exactly what `writePackets` expects.
- **It never fragments and emits no options.** Headers are always 20 B (IPv4), 40 B (IPv6), 20 B
  (TCP). Anything that overflows a 16-bit length field throws `datagramTooLarge`; segmenting to the
  MTU is the caller's job, since only it knows the flow.
- IPv4 sets **DF with identification 0**: the ID field only exists to reassemble fragments we never
  emit.
- Checksums use an `InternetChecksum` accumulator (RFC 1071) rather than a function over a buffer,
  because the transport checksum spans a pseudo-header plus the segment — concatenating them just to
  sum them would copy the payload on every emitted packet.
- **UDP's zero-checksum rule** (RFC 768): a computed checksum of 0 is transmitted as `0xffff`, since
  0 is reserved for "no checksum". Both are the same number in one's complement, and IPv6
  (RFC 8200 §8.1) forbids the 0 form outright, so the rule holds for both families.
- Flags are masked to the six bits `TCPFlags` models; ECE/CWR are never emitted.

**Tests (19):** golden vectors for IPv4/TCP, IPv4/UDP, IPv6/TCP and IPv6/UDP-with-odd-payload,
**hand-computed byte by byte including the checksums** — a golden captured from a run of the emitter
would only prove it has not changed, not that it is right. On top of that: round-trips through M3's
`PacketParser` (two independent implementations that must agree), `FlowKey` canonicity across
direction inversion, the UDP zero-checksum rule, flag masking, typed errors, and a sweep over payload
lengths 0–64 (odd ones exercise the checksum's zero padding) validated by a verifier written
separately from `InternetChecksum`. `InternetChecksum` itself is anchored to external vectors
(RFC 1071 §3 and the RFC 1624 §3 IPv4 header) so the emitter's tests cannot confirm themselves. The
emitted goldens were additionally fed to `tcpdump -vv`, which reports every checksum as `correct` /
`udp sum ok`.

## TLS inspection (opt-in, port-443 TCP only)

### Preconditions (all must hold, else passthrough)

1. The user turned inspection **on**.
2. The flow is TCP to port 443.
3. The user generated a local CA and installed+trusted it (the app knows this; if not, don't
   even try).
4. The flow is not already marked `notInspectable`.

### Local certificate authority

```swift
public struct LocalCA: Sendable {
    /// Genera una CA raíz nueva; la clave privada se guarda en el llavero (Secure Enclave si hay).
    public static func generate() throws -> LocalCA
    /// Exporta el certificado raíz (DER) para que el usuario lo instale.
    public func exportRootCertificateDER() -> Data
    /// Emite un certificado leaf efímero para `host`, firmado por la CA. Cacheado por host.
    public func mintLeaf(forHost host: String, sans: [String]) throws -> SecIdentity
}
```

- Use `CryptoKit`/`Security`. The CA **private key never leaves the device** and lives in the
  Keychain (Secure Enclave-backed where available), in the app's keychain access group.
- Leaf certs are short-lived and cached per host to avoid re-minting on every connection.

#### Implemented so far (M8, second half) — the certificate authority core ✅

`LocalCA` is split into a **pure, Simulator-testable core** and a thin **Keychain/`SecIdentity`
shell**, the same pure-core/injected-shell rhythm as `PacketPipeline`→`PacketTunnelProvider` and
`TCPRelayFlow`→`Relay`. The core is done; the shell is the remaining device-only piece.

`CertificateAuthority` (`PacketTunnel/TLS`) is that core — an `actor` holding a P-256 root key and its
self-signed root certificate, minting ephemeral leaves cached per host:

```swift
public actor CertificateAuthority {
    public struct Configuration: Sendable { /* root/leaf names, validity, backdating */ }

    public static func generate(configuration: Configuration = .init(),
                                now: @escaping @Sendable () -> Date = Date.init) throws -> CertificateAuthority
    public func exportRootCertificateDER() -> Data
    public func mintLeaf(forHost host: String, sans: [String] = []) throws -> MintedCertificate
    public func clearLeafCache()
}

public struct MintedCertificate: Sendable, Equatable {
    public let host: String
    public let certificateDER: Data   // firmado por la CA raíz
    public let privateKeyDER: Data    // PKCS#8, para importar al Keychain y armar el SecIdentity
}
```

Why the split, and why `MintedCertificate` instead of `SecIdentity` here: iOS's `Security` framework
can only **read** certificates, not build or sign them, and it has no public `SecIdentity` constructor —
a `SecIdentity` only exists once its private key sits in the Keychain. So the whole cryptographic heart
(X.509 assembly + ECDSA-P256/SHA-256 signing) is pure and testable, and turning a `MintedCertificate`
into a Keychain-backed `SecIdentity` (plus persisting the root key, Secure Enclave where available) is
the device/Keychain shell — which is exactly the surface that cannot be unit-tested cleanly off-device.

The core is built on two pure helpers in the same module, since neither `Security` nor `CryptoKit`
serializes certificates:

- **`DER`** — a minimal ASN.1 DER encoder (INTEGER with the leading-zero rules, OID base-128, BIT STRING
  incl. minimal `KeyUsage` bit strings, UTCTime/GeneralizedTime chosen by year, context tags).
- **`X509`** — builds and signs an X.509 v3 certificate given a signing closure: v3, ECDSA-SHA256,
  EC P-256 SPKI, and the minimal extension set (BasicConstraints, KeyUsage, ExtendedKeyUsage=serverAuth,
  SubjectAltName with `dNSName`/`iPAddress`, Subject/Authority Key Identifier). The root is CA:TRUE +
  keyCertSign; leaves are CA:FALSE + digitalSignature/keyEncipherment, SAN = host (+ extras), 90-day
  validity (well under iOS's 398-day server-cert cap), AKI pointing at the root. The `serverISN`-style
  unpredictable input here is the 16-byte random serial; `now` is injectable for deterministic validity.

**Tests (29):** 18 for `DER` (golden vectors hand-computed or taken from well-known public OIDs — length
short/long form, INTEGER rules, OID encoding, `KeyUsage` bit strings, UTC/Generalized time, context
tags) and 11 for the CA. The certificates are **not** checked against this implementation: they are fed
to `Security` — `SecCertificateCreateWithData` only accepts well-formed DER X.509, and
`SecTrustEvaluateWithError` under an SSL policy validates the whole chain (signature, anchoring, validity,
host-by-SAN, EKU). Covered: root is a well-formed self-signed CA; a leaf chains to its root for its host;
it is rejected for a different host, under a different root, and after expiry (injected clock + verify
date); extra `dNSName` and `iPAddress` SANs validate; minting is cached per host and cleared on demand;
distinct hosts get distinct keys and serials; an empty host is rejected. **234 total.**

#### Implemented so far (M8, second half, cont.) — the CA Keychain shell ✅

`LocalCA` (`Shared/TLS/LocalCA.swift` — see the M10 note below; it was written in
`PacketTunnel/TLS`) is the **device-only shell** over that core, matching the
spec sketch above (`Sendable` struct). It adds the two things the core deliberately can't do off-device:
persisting the root key in the Keychain and turning a `MintedCertificate` into a presentable
`SecIdentity`. Like `NetworkRelayConnection` and `PacketTunnelProvider.swift`, it is validated **by
compilation only** under strict concurrency — the Keychain needs device entitlements, so its live
correctness is a device smoke test.

```swift
public struct LocalCA: Sendable {
    public struct KeychainConfiguration: Sendable { /* accessGroup, rootKeyTag, leafLabelPrefix */ }

    public static func generate(keychain:configuration:) throws -> LocalCA        // new root key → persist → core
    public static func load(keychain:configuration:) throws -> LocalCA?           // restore from persisted key, nil if none
    public func exportRootCertificateDER() async -> Data
    public func mintLeaf(forHost host: String, sans: [String]) async throws -> SecIdentity
    public func clearLeafCache() async
    public func removeFromKeychain() throws                                       // reversibility
}
public enum LocalCAError: Error, Sendable, Equatable { case keychain(OSStatus), invalidStoredKey, identityUnavailable }
```

Design, and deviations from the sketch (all deliberate):

- **The core gained one seam:** `CertificateAuthority.make(rootKey:configuration:now:)`, the body of
  `generate()` lifted out to accept an existing key. `generate()` now calls it with a fresh key
  (behaviour unchanged, its tests untouched), and the shell calls it to rebuild the CA from the persisted
  key. `LocalCA.generate/mintLeaf/exportRootCertificateDER` are **`async`** because the core is an actor —
  the spec's non-`async`, `SecIdentity`-returning `mintLeaf` was a sketch.
- **Root key persistence is key-only.** `generate()` stores just the P-256 private key (as an
  `kSecClassKey` EC key, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, non-syncable, optionally in a
  shared `accessGroup`); `load()` recomputes the root certificate from it. The recomputed cert is **not**
  byte-identical to the one the user installed (random serial, clock-dependent validity), but that is
  harmless: leaves are signed by the same key and the client anchors the chain on the **installed trusted
  root** — matched by subject + public key, not serial — so a leaf from a reloaded CA still validates
  against the installed root. This invariant is covered by a Simulator test on the seam (below).
- **`mintLeaf` returns a `SecIdentity`** by importing the leaf's key + certificate into the Keychain and
  re-querying `kSecClassIdentity` (iOS has no public `SecIdentity` constructor; the pair forms only inside
  the Keychain, matched by public key). Duplicate imports (the cache re-mints the same leaf) are treated
  as success.
- **Secure Enclave is a documented, bounded deferral.** SE-backing would make the root key non-exportable
  by design, so the core could no longer reconstruct itself via `make(rootKey:)` — it would need to sign
  through an injected signer rather than hold the key. That refinement is a later increment; today the
  root key still never leaves the device (device-only, non-syncable Keychain item).

**Tests (2 new, Simulator, on the seam — the Keychain shell itself is compile-only):** a CA rebuilt from
an existing key with `make(rootKey:)` mints leaves that validate under `Security`; and a leaf minted by a
CA **reloaded** from the same key validates against the **originally-exported** root cert (same subject,
different serial) — proving the key-only persistence design. **236 total.**

**Still pending:** the `TLSInterceptor` below.

#### Implemented so far (M8, second half, cont.) — the TLS interceptor decision core ✅

`TLSInterceptor` is split into a **pure, Simulator-testable decision core** and a thin **device-only
termination shell**, the same rhythm as everything else in M8. The core is done; the live handshake
shell is the remaining device-only piece.

`TLSInterception.swift` (`PacketTunnel/TLS`) is that core — no network, no Keychain, no `SecIdentity`:

```swift
public enum TLSInterceptionPolicy {
    public enum Gate: Sendable, Equatable { case attempt(sni: String), abort(TLSInterceptError) }
    public static func gate(caReady: Bool, clientHelloSNI: String?) -> Gate

    public enum Decision: Sendable, Equatable { case inspected, notInspectable, fail(TLSInterceptError) }
    public static func decide(_ outcome: TLSTerminationOutcome) -> Decision
}

public enum TLSTerminationOutcome: Sendable, Equatable {
    case inspected, pinned, serverHandshakeFailed, userspaceStackError
}
public enum TLSInterceptError: Error, Sendable, Equatable {
    case noCA, noSNI, handshakeWithServerFailed, userspaceStackError
}
```

`gate` verifies only the interceptor's **residual** preconditions (CA ready + SNI present); the other
three preconditions above (inspection on, TCP-to-443, not already `notInspectable`) are the pipeline's
contract — `PacketPipeline.route` enforces them and only routes eligible flows to `.inspect`, and its
21 tests already cover them, so re-checking them here would duplicate that contract. `decide` maps the
handshake outcome to the final action and is where the **pinning-passthrough invariant** lives: a
`pinned` outcome resolves to `notInspectable`, never to an error that might invite a retry (ADR 0003).

`TLSInterceptor.swift` is the `actor` that orchestrates the policy against an injectable shell:

```swift
public protocol TLSTerminationEngine: Sendable {
    func terminate(flow: LiveFlow, sni: String) async -> TLSTerminationOutcome
}

public actor TLSInterceptor {
    public enum Result: Sendable, Equatable { case inspected, notInspectable }
    public init(engine: TLSTerminationEngine, caReady: @escaping @Sendable () -> Bool)
    public func intercept(_ flow: LiveFlow, clientHelloSNI: String?) async throws -> Result
}
```

Deviations from the sketch below, all deliberate:

- **`init(engine:caReady:)` instead of `init(ca:reinject:)`.** The CA, the reinjector and all the
  handshake I/O move **into** the `TLSTerminationEngine` (its production conformer will hold them), and
  the actor takes the engine already built — the same move `Relay.init` made when it gained
  `connectionFactory`. This keeps the actor pure enough to run in the Simulator against a scripted
  engine double; the production `init(ca:reinject:)` convenience that builds the device-only engine
  lands with that conformer.
- **`caReady` is a closure read per call**, because "CA generated + installed + trusted" is app state
  (the user installs the profile in Settings) that can flip while the tunnel runs — reversibility (§
  "Security invariants") requires honoring a mid-run removal on the very next flow.
- **`noSNI` added to `TLSInterceptError`.** Without the ClientHello host there is no host to mint the
  leaf for (`LocalCA.mintLeaf(forHost:)`), so it is a real residual precondition; making it a distinct
  transient error is clearer than folding it into `userspaceStackError`. All thrown errors mean the
  same thing to the caller: relay untouched, **without** marking the flow `notInspectable` (the cause
  may pass), unlike `pinned` which is permanent.

**Tests (16, 252 total):** `gate` forcing passthrough (no CA → `.noCA`, absent/empty SNI → `.noSNI`,
CA-before-SNI ordering, both present → `.attempt`); `decide` for every outcome incl. `pinned` →
`notInspectable`; and the actor against a scripted engine — no-CA/no-SNI throw without touching the
engine, a trusting client → `.inspected` (engine received the right flow + SNI), a **pinning** client →
`.notInspectable` with the engine called exactly once (no retry, ADR 0003), server/stack failures →
typed throws, and `caReady` re-read per call (a mid-run CA removal stops the next termination). The
live userspace handshake is a device smoke test; this layer is the Simulator-testable decision.

**Still pending:** the production `TLSTerminationEngine` conformer (the userspace TLS server presenting
the SNI leaf + the upstream `NWConnection` under system trust), device-only.

#### Implemented so far (2026-08-12) — the memory-fed TLS server ✅

This is the piece the roadmap had flagged as **the only one in the project whose feasibility was
unknown**: a TLS *server* that has to be fed from a byte stream we already hold in memory, because the
extension receives IP packets and not sockets. **iOS allows it.** The answer is not a deduction from
reading headers — it is a Simulator test in which a real BoringSSL client, with its own trust
evaluation, completes a handshake against a leaf we minted and exchanges plaintext both ways.

```swift
public protocol TLSServerSession: Sendable {            // PacketTunnel/TLS
    func start(
        onReady: @escaping @Sendable () -> Void,          // handshake done: plaintext exists
        onPlaintext: @escaping @Sendable (Data) -> Void,  // what the client sent, in the clear
        onEncrypted: @escaping @Sendable (Data) -> Void,  // TLS records to hand back to the client
        onClose: @escaping @Sendable (TLSServerSessionClosure) -> Void
    )
    func deliver(_ data: Data)      // TLS records arriving from the client (reassembled, in order)
    func deliverEnd()               // the client half-closed (FIN)
    func send(_ plaintext: Data)    // plaintext towards the client; the session encrypts it
    func closeSend()
    func cancel()
}

public enum TLSServerSessionClosure: Sendable, Equatable {
    case closed, rejectedByClient, failed(TLSServerSessionError)
}
```

**The mechanism, and why it is a bridge.** Network.framework — the only maintained TLS stack iOS
exposes — only plays TLS *server* through an `NWListener`, and a listener is only ever fed by a
socket. So `LoopbackTLSServerSession` raises a listener bound to `127.0.0.1` carrying the host's leaf
and dials **its own** plain-TCP connection to it. Records that came off the tunnel are written into
that bridge and the records the stack produces are read back out of it (those are what gets reinjected
towards the device); the connection the listener *accepts* is the TLS server side, so plaintext goes
in and out of it. Apple's stack does the TLS; what we add is a one-metre cable.

- **It never leaves the device and cannot recurse.** Loopback is resolved by `lo0` and is not routed
  into the tunnel, so our own `NEPacketTunnelProvider` never sees this traffic. The listener binds
  `127.0.0.1` (never `0.0.0.0`) and **stops listening the moment it accepts its first connection**, so
  no port stays open to anyone else for the life of the flow.
- **It is bounded.** Records that arrive before the bridge is up — and plaintext handed over before
  the handshake finished — are held up to 64 KiB per direction and then the session fails, rather than
  growing without limit inside an extension with a memory budget.
- **`rejectedByClient` is the ADR 0003 signal, and it is distinguishable.** A client that refuses our
  leaf makes the server side fail with a peer TLS alert (`errSSLPeer*`, observed: `-9825`
  *misc. bad certificate*). Those statuses — plus the generic `errSSLPeerHandshakeFail`, which a
  pinning client may send instead — map to `rejectedByClient`, which is **permanent** for the flow
  (mark `notInspectable`, relay untouched, never retry). Everything else is `failed`, which is
  transient and is *not* marked.

**The alternative, measured rather than assumed.** `SecureTransport` (`SSLCreateContext` +
`SSLSetIOFuncs`) is memory-fed by design and needs no socket at all; it **still exists on iOS 26 and
still starts** (`SSLSetIOFuncs`/`SSLSetCertificate` return `errSecSuccess`, `SSLHandshake` returns
`errSSLWouldBlock`, i.e. the stack came up and is asking for bytes). It was rejected anyway: deprecated
since iOS 13, no TLS 1.3, and its own header says *"No longer supported. Use Network.framework."*
Building v1's inspection on an API that can vanish with the next system release is a worse risk than
the cost of the bridge. The seam above is exactly what would make that swap cheap.

**What the Simulator cannot answer**, and is therefore a device check: whether a network extension may
bind a loopback listener under iOS's sandbox.

#### The CA moves to `Shared/TLS` (M10) ✅

The certificate authority — `DERWriter`, `X509Certificate`, `CertificateAuthority`, `LocalCA` — now
lives in [`../../Shared/TLS`](../../Shared/TLS). Nothing about it changed; only where it is compiled.

**Why:** the CA is the **user's**, not the tunnel's, and both processes need it. The extension signs
leaves with it during a handshake; the app has to generate it, hand its root certificate to the guided
install flow, and check whether the system trusts it ([`../ux/onboarding-and-consent.md`](../ux/onboarding-and-consent.md)).
This is the same move `TunnelAddressing`, the control-channel codec and the `.pcap` format made, and
for the same reason: it is knowledge shared by both sides, so the only place both can see the same
type is the shared framework.

**There is no IPC under it.** `TunnelVision.entitlements` and `PacketTunnel.entitlements` have always
declared the same `keychain-access-groups` entry, and neither side passes an explicit
`kSecAttrAccessGroup`, so both default to that first shared group and read the very same Keychain
items. The app-side reader that uses this (`CertificateStatusReader`) and the alternative that was
rejected — the extension *publishing* what it knew about the CA into the App Group container — are
specified in [`app-services.md`](app-services.md#certificate-status-m10). The short version: a
published status is a copy of a fact the user can change from iOS Settings whenever they want, and it
would be written by a process that only runs while the tunnel is up, which is not when someone
installs a certificate.

One consequence worth writing down: `DER` and `X509` are **internal** to `Shared` (nobody outside the
framework hand-serializes ASN.1), so their tests import the framework with `@testable` and the Shared
target enables `ENABLE_TESTABILITY` in Debug. Making them public just to test them would have let the
tests decide the product's API.

### Userspace termination flow

```
client (iPhone app) ──TLS(our leaf)──▶ userspace TCP+TLS server (us)
                                             │  plaintext logged here
                                             ▼
                             NWConnection ──TLS(system trust)──▶ real server
```

1. A userspace TCP endpoint completes the client handshake (client presents to *us*; we present
   the minted leaf for the SNI host).
2. **If the client rejects our certificate** (it pins), the handshake fails → set the flow's
   status to `notInspectable`, tear down the userspace side, and **relay the original flow
   untouched**. This is the pinning-passthrough invariant; never retry to force it.
3. If the client accepts, we hold plaintext. Open a separate `NWConnection` to the real server
   using **normal system trust** (we are an ordinary TLS client to it; no special privilege).
4. Shuttle bytes both ways, logging plaintext to the inspector/pcap according to the capture
   detail level. Re-encrypt to the real server on the outbound side.

```swift
public enum TLSInterceptError: Error, Sendable {
    case noCA, noSNI, handshakeWithServerFailed, userspaceStackError
}
```

#### Implemented so far (2026-08-12) — the termination engine ✅

The other half of the engine, and with the feasibility question already answered it was ordinary
construction: pairing the server session with the upstream leg and shuttling plaintext between them.

```swift
public protocol TLSTerminationEngine: Sendable {                    // PacketTunnel/TLS
    /// Builds (does not start) the termination of one flow towards `endpoint`, presenting `host`'s leaf.
    func makeTermination(
        host: String,
        to endpoint: IPEndpoint,
        plaintext: (@Sendable (Data, Direction) -> Void)?,
        onUpstreamTLS: (@Sendable (NegotiatedTLS) -> Void)?,   // see "What an inspected flow's server chose"
        onOutcome: @escaping @Sendable (TLSTerminationOutcome) -> Void
    ) async throws -> any RelayConnection
}

public actor TLSInterceptor {
    public init(engine: any TLSTerminationEngine, caReady: @escaping @Sendable () -> Bool)

    public func open(
        to endpoint: IPEndpoint,
        clientHelloSNI: String?,
        plaintext: (@Sendable (Data, Direction) -> Void)?,
        onUpstreamTLS: (@Sendable (NegotiatedTLS) -> Void)?,
        onResolve: @escaping @Sendable (TLSInterceptionPolicy.Decision) -> Void
    ) async throws -> any RelayConnection
}
```

**The engine is a factory, not an operation.** The sketch above (`terminate(flow:sni:) async ->
TLSTerminationOutcome`) assumed the engine could get hold of the flow's bytes by itself. It cannot:
the reassembled stream belongs to the relay, which runs the TCP state machine towards the device. So
the engine *builds* the termination and hands it back, and the outcome — which is known when the flow
ends, not when it opens — arrives through a callback. `TLSInterceptor` keeps its policy intact: gate
before anything is touched, `decide` afterwards.

**`TLSTerminationConnection` is shaped like a `RelayConnection`**, because from the relay a
termination is indistinguishable from an outbound connection: it takes the reassembled stream
(`send`), returns bytes to re-segment towards the device (`onReceive`), has a moment when the way out
is established (`onReady`) and an end (`onClose`). That is what makes the hookup *a change of which
connection gets created* for an `.inspect` flow rather than a second path through the relay. What a
termination adds over a plain connection — how the attempt to inspect went — leaves through a
separate channel, because it is not transport information.

- **Which leg carries what.** Records from the device go to `session.deliver`; the stack returns
  plaintext, which is written to the upstream leg, which **re-encrypts** under system trust. What the
  upstream leg delivers is already decrypted by Network and goes to `session.send`, which encrypts it
  with the keys the client accepted. Plaintext in both directions is offered to an optional sink
  before being forwarded — the seam where persisting it (the next piece) will plug in. No observer,
  not a byte copied.
- **`onReady` waits for the upstream leg**, exactly like a passthrough connection: the promise is
  "the way out exists", and for a TLS connection that includes its handshake against the real server.
  Plaintext produced before that is held, bounded (64 KiB, the same ceiling and the same reason as the
  session's own queues) and flushed in order.
- **The outcome mapping is where ADR 0003 lives.** `rejectedByClient` ⇒ `.pinned` (permanent, marked
  `notInspectable`, never retried); a clean close after the handshake ⇒ `.inspected`; a clean close
  *before* it inspected nothing, so it goes to the transient bucket; an upstream failure before ready
  ⇒ `.serverHandshakeFailed`; anything else ⇒ `.userspaceStackError`. A server half-close is passed on
  by closing our send side towards the client and nothing else — the session's close is the only event
  that has seen both directions. Cancelling reports **no** outcome: the caller who cancels already
  knows how it ended.
- **The production conformer** (`NetworkTLSTerminationEngine`) mints the leaf first and dials only
  then — no traffic to the real server for a flow that was never going to be inspectable — through a
  `LeafMinting` seam that `LocalCA` satisfies. Its upstream leg dials **the address the device chose**
  (no DNS re-resolution: inspecting cannot change who you talk to) announcing the same name the device
  announced, which is what the server's certificate is validated against. It carries **no verify block
  of its own**, deliberately: the system evaluates it, which is what keeps us an ordinary client.

**Tests (24, 1213 total):** the pairing against doubles for both legs — which byte leaves through
which door and in what order, plaintext held and flushed once the way out exists, the bounded ceiling,
both directions observed, and every ending mapped (pinning, clean close before and after the
handshake, session failure, upstream failure before and after ready, server half-close, caller cancel,
outcome reported exactly once, traffic after the end dropped) — plus the interceptor against a
scripted engine and the engine's mint-before-dial ordering.

#### Implemented so far (2026-08-13) — the relay hookup ✅

The last piece of the engine, and the one that had to answer *when*. Three questions, and the shape
of the answer to the first decided the other two.

```swift
public protocol FlowInspecting: Sendable {                    // PacketTunnel/Relay
    func open(
        to endpoint: IPEndpoint,
        clientHelloSNI: String?,
        plaintext: (@Sendable (Data, Direction) -> Void)?,
        onUpstreamTLS: (@Sendable (NegotiatedTLS) -> Void)?,
        onResolve: @escaping @Sendable (TLSInterceptionPolicy.Decision) -> Void
    ) async throws -> any RelayConnection
}
extension TLSInterceptor: FlowInspecting {}                   // the seam is its own shape

public protocol TLSStatusObserving: Sendable {                // PacketTunnel/Relay
    func observe(tlsStatus: TLSInspectionStatus, for key: FlowKey) async
}

public actor Relay {
    public func passthrough(_ packet: ParsedPacket, raw: Data) async
    public func inspect(_ packet: ParsedPacket, raw: Data) async    // opens the flow as a candidate
}
```

- **The SYN-ACK comes before the name, and that cannot be inverted** — the ClientHello only arrives
  after it. So a candidate opens its plain outbound connection like any other flow (which keeps the
  handshake faithful: a server that refuses still refuses, to the device), and what changes is that
  it **holds** what the device sends instead of forwarding it. Once the name is known the termination
  is built, the plain connection — which never sent a byte — is cancelled, the termination takes its
  place and receives the held stream. This is the variant that touches `TCPRelayFlow` least: its
  `serverDidConnect` outside `connecting` was already a no-op, so the termination's own `onReady`
  costs nothing and no SYN-ACK is sent twice.
- **A 443 flow that is not TLS goes back to passthrough without losing a byte.** WhatsApp's messaging
  connection speaks Noise over 443 and is everyday traffic; the same road out serves a CA that is not
  ready yet, inspection switched off mid-handshake, and the 64 KiB ceiling on what may be held (the
  same number and the same reason as `TLSTerminationConnection`'s). None of those mark the flow:
  they are transient, and marking would accuse of pinning someone who does not pin.
- **And so does a termination that dies before the device has seen a byte of it** (2026-08-15). The
  bullet above only ever covered failures *before* the swap — the ones that make `open` throw. Once
  installed, any failure tore the flow down with a reset, and the failure this is most likely to be is
  systematic: if the userspace stack does not come up on the device (the sandbox refusing the loopback
  listener, say), that is **every** 443 connection killed and not one web page opening, which is the
  opposite of the silent degradation this design promises. So the rollback window stays open until the
  first byte produced by the termination reaches the device: until then nothing of ours has arrived at
  the other end, the flow keeps everything the device sent, and a close of any kind hands it back to a
  fresh plain connection with the whole stream in order and the FIN behind it. Once that byte lands the
  client's TLS is committed to our leaf, the window shuts, and a failure does cost the connection — which
  is why a pinning rejection is unaffected: a client can only refuse a certificate it has received.
  Counted in `RelayStats.terminationsRolledBack`, whose pairing with `terminationsFailed` is what tells
  "inspection is not working" apart from "the phone has no internet".
- **The pinned client's retry arrives under a different `FlowKey`**, so the memory is by host:
  `PinnedHostMemory` (`PacketTunnel/TLS`), bounded and session-lived. The flow is marked and the host
  is remembered, and the second attempt is relayed intact instead of broken again. This is the half
  of ADR 0003 the user actually notices.
- **A per-flow generation counter** is what makes the swap safe: cancelling a connection fires its
  close handler, and without the counter that echo would be indistinguishable from the live
  connection's close and would tear down the very flow being inspected.
- **The device's FIN during the hold is deferred**, not forwarded: the EOF goes *behind* the held
  bytes, whichever leg ends up releasing them.
- `RelayStats` gained the inspection counters (candidates, terminations opened, abandonments, pinned
  host skips, inspected/pinned flows, late failures), and `PacketPipeline` conforms to
  `TLSStatusObserving`, which is what finally gives `FlowTable.setTLSStatus` a caller.

**Tests (25, 1238 total):** the relay half against doubles for the interceptor and both connections —
the ClientHello held, the candidate's plain connection opened and its SYN-ACK faithful, the swap with
the held stream delivered, the stream after the swap, the cancelled connection unable to tear down
the flow or re-send the SYN-ACK, replies re-segmented to the device, non-TLS and transient failures
falling back with every byte intact, inspection turned off mid-handshake, a non-candidate never
terminated, the FIN ordered behind the hold, the ceiling, and each outcome reported — plus the
pinned-host retry end to end, the memory's own bounds, and the pipeline half (status reaching the
store without touching the name, and a `notInspectable` flow no longer routed to inspection).

#### Implemented so far (2026-08-13) — where the plaintext goes (piece 2, store half) ✅

The sink above now has somewhere to write to: `Shared/Plaintext` — a format, a streaming writer and a
per-flow budget, specified in [`plaintext.md`](plaintext.md). Same architecture as the capture (bytes
in rotating files, metadata in SQLite) and a **separate** directory, format and file extension,
because a `.pcap` record is a bare IP datagram and this is a slice of an already-decrypted stream —
and because the two deserve separate retention: one holds what travelled, the other what was inside.
What bounds it is bounded twice: per record by the writer, and per flow **and direction** before the
bytes reach it (a response of megabytes must not leave the following requests without room). It is
the beginning that is kept, and what did not fit is counted rather than dropped silently. 44 tests,
**1282 total**.

#### Implemented so far (2026-08-13) — the wiring (piece 2, done) ✅

The sink is no longer `nil`. A chunk now travels: termination → relay → pipeline → its file and its
index row.

```swift
public protocol PlaintextObserving: Sendable {                // PacketTunnel/Relay
    func observe(plaintext: Data, direction: Direction, for key: FlowKey) async
}
extension PacketPipeline: PlaintextObserving {}

public protocol PlaintextSink: Sendable {                     // PacketTunnel/Pipeline
    func openStream() async -> UInt64
    func write(_ plaintext: Data, stream: UInt64, direction: Direction, timestamp: Int64)
        async throws -> PlaintextLocation?
    func flush() async throws
}
extension PlaintextWriter: PlaintextSink {}
```

- **The switch is the relay's, and it is applied by *not copying*.** `Relay.finishTermination` hands
  the termination a sink only when `plaintextPersistenceEnabled` — otherwise the termination never
  touches the plaintext it shuttles. The two directions of that switch are deliberately asymmetric:
  turning it **on** starts with the next flow (the sink is given at open), turning it **off** stops
  recording **immediately**, including chunks already queued. Revoking permission to record what you
  say cannot wait for your connections to end.
- **A serial, bounded queue carries the chunks into the actor**, for the same two reasons as the
  provider's reinjected-record queue, and here the first weighs more: the chunks *are* the
  conversation, and the termination emits them from its two legs' own queues, so a `Task` per chunk
  would deliver them shuffled and what was stored would say something nobody wrote. Full, it drops
  the **newest** (keep the beginning, the same rule as the per-flow budget) and counts it.
- **The pipeline is where a chunk becomes a row**, because the flow's row id only exists at flush and
  the flow table is its own. It refuses to write a chunk whose flow it cannot name — bytes no row
  points at are the worst of both worlds: unreachable and invisible to retention — applies the
  per-direction budget before touching the disk, and appends `appendPlaintext` inside the same
  `writePending` that upserts the flow. The live budget dies through `merge(closed:)`, the one funnel
  every flow ends through.
- **Dated twice with one anchor**: absolute into the file (it outlives the session), monotonic into
  the row (the store converts it). The provider now takes one `MonotonicAnchor` and gives it to both.
- `PipelineStats` gained the plaintext counters (chunks and bytes stored, bytes dropped, write
  failures with the last error) and `RelayStats` gained chunks observed and chunks dropped by the
  queue. A write failure switches decrypted content off for the session, exactly like a capture
  failure, and touches nothing else.

**Tests (19, 1323 total):** the pipeline half against doubles — the chunk written and indexed against
its flow with its location intact, one conversation per flow, dating in both units from the same
anchor, the budget keeping the beginning and telling the truncation, an exhausted budget not touching
the disk at all, each direction with its own budget, a closed flow releasing its budget, a chunk
without a flow refused, a write failure stopping only plaintext, batching at flush — plus the relay
half: no sink without permission, chunks tagged with their `FlowKey`, order preserved across 40
chunks, turning persistence off stopping recording immediately, and `closeAll()` draining the queue.

**What is left of TLS inspection** is the sweep that enforces the ADR 0007 expiry, the screen that
exposes its switch, and piece 4 (the decoded half of the Flow Inspector), plus the one device-only
unknown that has been open since the server session was built: whether a network extension may bind a
loopback listener under iOS's sandbox.

## Security invariants (do not violate)

- **No pinning bypass.** A rejected client handshake ends inspection for that flow; we pass it
  through. We never hook the client, never strip pinning, never fake server trust to the client
  beyond our own installed CA, and never MITM a flow whose app didn't consent via that CA.
- **We earn no special server trust.** To the real server we are a normal client under standard
  system trust. We cannot see servers we couldn't legitimately reach.
- **Plaintext retention is bounded.** Decoded content is written per the retention/detail
  settings and pruned; it is never uploaded (there is nowhere to upload to).
- **Reversible.** Turning inspection off stops all termination immediately; removing the CA in
  iOS Settings makes every flow `encrypted`/`notInspectable` again.

## SNI without decryption ✅

Even for non-inspected 443 flows, the SNI in the ClientHello is readable and is logged as
`FlowRecord.sni` — useful metadata that requires no decryption and no CA. **Implemented on
2026-08-12**, and it is what earns the app its headline claim: the Timeline names *who* the device
talked to instead of listing addresses.

```swift
public struct ClientHelloScanner: Sendable {          // PacketTunnel/TLS
    public private(set) var offer: ClientTLSOffer?    // § What the client offered, below
    public enum Outcome: Sendable, Equatable {
        case needMoreBytes
        case found(String)
        case unavailable(Reason)
    }
    public enum Reason: Sendable, Equatable {
        case notTLSHandshake, notClientHello, malformed, noServerName, tooLarge
    }
    public mutating func scan(_ bytes: Data) -> Outcome
}

public protocol SNIObserving: Sendable {              // PacketTunnel/Relay
    func observe(sni: String, for key: FlowKey) async
}
```

Three decisions worth keeping:

- **The scanner is incremental, and that is not a convenience.** A modern ClientHello — with hybrid
  post-quantum key shares — exceeds the tunnel's 1500-byte MTU, so most of the time it arrives
  **split across two TCP segments**. A one-shot parser would miss the name in the common case. It
  also stitches a handshake message fragmented across several TLS records, and it is bounded
  (`maxHandshakeBytes`, 16 KiB) so a stream that starts like a handshake and continues as anything
  else cannot grow the extension's memory. Once it settles on an outcome it drops its buffers and
  never looks at another byte — the rest of a TLS flow is ciphertext.
- **It is fed from the relay, not from the pipeline.** `Relay.readHandshake` receives the
  **reassembled, in-order** stream that `TCPRelayFlow` delivers to the server, so a split ClientHello
  — or a retransmitted or out-of-order segment — reads the same. Reading raw per-segment payloads in
  the pipeline would have needed a second reassembler in the hot path. The price is one narrow seam
  (`SNIObserving`, injected like the pipeline's own sinks), and `PacketPipeline` is the conformer
  because it owns the flow table. Scanning is only armed for TCP against 443 — the same rule that
  makes `FlowTable.initialTLSStatus` mark a flow `encrypted` — and only when an observer exists
  (this one, or `ClientTLSObserving`).
- **A name is not an inspection.** `FlowTable.setSNI` deliberately does *not* touch `tlsStatus`: a
  named flow stays `encrypted` until termination says otherwise. Host bytes are validated before
  they reach the UI and SQLite (RFC 6066 ASCII, no trailing dot, ≤ 253 chars, lowercased so the same
  host is one row and not two); an unusable name counts as "no name", never as a malformed handshake.
  `RelayStats.sniObserved` / `.sniUnavailable` count both halves.

**Reach, measured on a device (2026-08-12):** this names TCP/443 flows carrying a real TLS
ClientHello, and on a live iPhone that turned out to be **a small share of the traffic** — one named
host in a whole Timeline. It is not a defect of the parser: QUIC carries its ClientHello inside the
QUIC Initial packet, and some protocols on port 443 are not TLS at all (WhatsApp's messaging
connection speaks Noise). The live feed cannot show names at all by construction — the IPC ring
carries `PackedPacketMeta`, which has no SNI, so the Dashboard's top talkers are addresses on
purpose. Widening the reach (DNS-derived names and/or QUIC Initial parsing) remains an open decision.

**Tests (43, 1184 total):** the parser against hand-written golden vectors — every chunk boundary,
byte-by-byte feeding, fragmentation across records, no-SNI/no-extensions/empty-list, non-TLS streams,
a ServerHello, lying vectors, the size ceiling, host validation and sticky outcomes — plus the relay
wiring (single segment, split across two segments, **segments arriving out of order**, reported once
per flow, non-443 flows never scanned, forwarded stream untouched) and the pipeline half (the name
reaches the store, on the closing record too, without changing `tlsStatus`).

## What the client offered, without decryption ✅

The same ClientHello that names a flow also says what the client was **willing to negotiate**: the
TLS versions it accepts and its application protocols (ALPN). It is read by the same scanner, in the
same pass, and needs no CA either.

```swift
public enum OfferedTLSVersions: Sendable, Hashable, Codable {              // Shared/Models
    case listed([TLSProtocolVersion])
    case upTo(TLSProtocolVersion)
}
public struct ClientTLSOffer: Sendable, Hashable, Codable {                // Shared/Models
    public let versions: OfferedTLSVersions
    public let applicationProtocols: [String]
    public let omittedApplicationProtocols: Int
    public let hasEncryptedClientHello: Bool
}

public struct ClientHelloScanner: Sendable {                               // PacketTunnel/TLS
    public private(set) var offer: ClientTLSOffer?
}

public protocol ClientTLSObserving: Sendable {                             // PacketTunnel/Relay
    func observe(clientTLS: ClientTLSOffer, for key: FlowKey) async
}
```

Why it matters more than it looks: on an inspected flow the server's answer is an answer to the
**tunnel's** ClientHello (§ *What an inspected flow's server chose*), so what the app offered is the
only thing that says whether the app itself would have accepted less. What had to be decided:

- **The versions are two cases, because the ClientHello states them in two ways that do not mean
  the same.** With `supported_versions` (the **list** shape of the extension, RFC 8446 § 4.2.1) the
  client enumerates every version it accepts: `.listed`, exact, in the client's order of preference.
  Without it there is only `legacy_version`, which is a **ceiling**: `.upTo`. From the first a report
  can state that the client would not have accepted TLS 1.0; from the second it cannot, and a list of
  one version would have let it.
- **GREASE values are not kept** (RFC 8701: `0x0A0A`, `0x1A1A` … `0xFAFA`). They are not versions —
  they are filler a client adds so servers do not ossify — and keeping them would break any "lowest
  version offered", since `0x0A0A` sorts below SSL 3.0. A list of nothing but GREASE is `.listed([])`,
  not a fall back to the ceiling: the extension was sent. Anything else the client sent — a draft, a
  number that does not exist — is kept raw, as for the server.
- **ALPN is bounded and validated, and what is dropped is counted.** The identifiers are opaque bytes
  on the wire and they end up in a column and in a report, so only printable ASCII without spaces is
  kept (every registered identifier is), at most 16 of them, each at most 64 bytes. The rest are
  counted in `omittedApplicationProtocols` so that a trimmed list is not read as the whole list.
  ALPN GREASE (two-byte identifiers of the same pattern) is neither kept nor counted. Unlike a host
  name, an identifier is **not** lowercased: it is compared byte for byte.
- **Encrypted Client Hello is said, and it cannot be said precisely.** A ClientHello carrying the
  `encrypted_client_hello` extension (RFC 9849) is the **outer** one: the real offer, and the real
  name, may be encrypted inside it. `hasEncryptedClientHello` marks that. It cannot say more, because
  a client with no ECH configuration for that server sends the extension anyway, filled with random
  bytes, and it is indistinguishable from a real one by design. A reader citing a marked offer has to
  say that it may not be the one the server answered.
- **The offer does not live in `Outcome`, and neither reading costs the other.** `Outcome` is about
  the name. A ClientHello with no SNI — a connection to a bare IP — ends `unavailable(.noServerName)`
  and has still offered its versions; that is the flow a report has nothing else to cite for. And the
  other way round: the scanner used to stop at the server name, and it now walks the whole
  extensions block, so a block that breaks **after** the name still yields the name it yielded
  before. It yields no offer.
- **An offer read halfway is no offer.** If the extensions block cannot be walked to its end, or the
  version list or the protocol list declares more than it holds (or a version list has an odd
  length), `offer` is `nil` — not `.upTo(legacy_version)`, which would assert that the extension was
  not there, and not the half that did parse.
- **Only the first of each extension counts.** A ClientHello may not repeat one; if it does, the
  second does not get to choose what is recorded.
- **Its own seam, not a wider `SNIObserving`**, for the same reason as above: one exists without the
  other. `PacketPipeline` is the conformer (`FlowTable.setClientTLS`), and the flow carries it to the
  store as `FlowRecord.clientTLS` (schema `v11`, [`persistence.md`](persistence.md)). The scanner is
  armed when either observer exists (or the flow is an inspection candidate); the offer leaves once
  per flow, on its own task like the name, before the outcome is acted on.
- **It is the app's offer on every flow, inspected or not.** The relay reads the ClientHello the
  device sent before deciding anything about termination.
- **One counter**, `RelayStats.clientOfferObserved`. Against `sniObserved + sniUnavailable` it says
  how many 443 flows left with an offer. No screen reads it yet.

The four extension codes (`server_name` 0, ALPN 16, `supported_versions` 43,
`encrypted_client_hello` 65037) were checked against the IANA TLS ExtensionType registry.

**Not read:** the cipher suites the client offered (the list is long and nothing planned needs it),
and QUIC, whose ClientHello travels inside the Initial packet.

**Tests (58):** `ClientHelloOfferTests` (31) — the list in order, the ceiling, the extension winning
over `legacy_version`, GREASE dropped and all sixteen values recognised, a GREASE-only list, a draft
kept raw, a hello without extensions, a repeated extension; ALPN in order, absent, GREASE, unprintable,
overlong, beyond the cap, empty, not lowercased; ECH flagged and not; an offer without a name,
extensions after the name, four ways a malformed list costs the offer and not the name, a block that
breaks after and before the name; no offer while bytes are missing or for a non-TLS stream, the same
offer at every chunk boundary, sticky once read. `RelayClientOfferTests` (11) — the offer leaves with
the name, **and without one**, from a hello split across two segments, once per flow; none for a
non-TLS stream, an unreadable offer does not cost the name, flows outside 443 never scanned; the
offer observer alone arms the scanner, without it the offer is still counted, with neither nothing is
scanned; the forwarded stream is untouched. Plus the pipeline (2), the store (14) and the
`FlowRecord` round-trip.

## What the server chose, without decryption

The ServerHello is in the clear for the same reason the ClientHello is: it precedes every key. So the
TLS version and cipher suite a server picked can be read for flows that are **not** inspected — which
is nearly all of them, and all of the ones that pin. Like the SNI, it needs no CA and does not touch
ADR 0003.

```swift
public struct TLSProtocolVersion: RawRepresentable, Sendable, Hashable {   // Shared/Models
    public let rawValue: UInt16
    public static let ssl30, tls10, tls11, tls12, tls13: TLSProtocolVersion
}
public struct TLSCipherSuite: RawRepresentable, Sendable, Hashable {       // Shared/Models
    public let rawValue: UInt16
}
public enum TLSAnswerSource: String, Sendable, Hashable {                  // Shared/Models
    case serverHello, upstreamConnection
}
public struct NegotiatedTLS: Sendable, Hashable {                          // Shared/Models
    public let version: TLSProtocolVersion
    public let cipherSuite: TLSCipherSuite
    public let fromHelloRetryRequest: Bool
    public let source: TLSAnswerSource
}

public struct ServerHelloScanner: Sendable {                               // PacketTunnel/TLS
    public enum Outcome: Sendable, Equatable {
        case needMoreBytes
        case found(NegotiatedTLS)
        case unavailable(Reason)
    }
    public enum Reason: Sendable, Equatable {
        case notTLSHandshake, alert(description: UInt8), notServerHello, malformed, tooLarge
    }
    public mutating func scan(_ bytes: Data) -> Outcome
}
```

It is the `ClientHelloScanner`'s twin for the inbound stream — incremental, bounded by the same
16 KiB ceiling, sticky once it settles — and the two share their bounds-checked cursor
(`TLSByteReader`). It is a pure value: it is given the inbound bytes and says what they hold. What is
specific to this direction:

- **The version is read from where it actually is.** TLS 1.3 announces itself in the
  `supported_versions` extension and leaves `legacy_version` saying 1.2 so middleboxes do not cut
  the connection; reading the old field would report every 1.3 connection as 1.2. The extension wins
  when present, `legacy_version` is used when it is not (a ServerHello with no extensions block is
  legal up to TLS 1.2). In a ServerHello the extension carries **one** version; the list shape a
  ClientHello uses is `malformed` here, because accepting it would mean choosing on the server's
  behalf.
- **Versions and suites are raw values, not closed enums.** The other end chooses them. A draft
  version or an unassigned suite is evidence to keep as sent, not to collapse into "unknown". The
  suite is its IANA code; its name is a presentation table, kept apart from what was observed.
- **A HelloRetryRequest is read, and marked.** It is a ServerHello with a fixed `random` (RFC 8446
  § 4.1.3) and already carries the version and the suite; the ServerHello that follows must repeat
  both or the client aborts (§ 4.1.4). So the reading holds for any handshake that completes, and
  `fromHelloRetryRequest` says it did not come from the final message.
- **An alert is an answer.** A server that refuses the handshake replies with an alert record
  instead of a ServerHello — `protocol_version` (70) when it accepts none of the offered versions.
  That is `alert(description:)`, distinct from `notTLSHandshake`: "this was not TLS" says nothing
  about TLS, "the server refused" does.
- **Why incremental, when a ServerHello is small.** In TLS 1.2 the server usually puts its
  certificate in the same record, right behind the ServerHello, and that record does not fit a
  segment. A record's declared length is judged against the ceiling **from its header**, before its
  bytes arrive, so a record claiming 64 KiB is refused rather than buffered.

### The hookup: a flow leaves the tunnel with the server's answer ✅

The relay feeds one `ServerHelloScanner` per flow from the **inbound** stream, the mirror image of
what `Relay.readHandshake` does for the ClientHello, and the answer leaves through a seam of the same
cut as `SNIObserving`:

```swift
public enum ServerTLSAnswer: Sendable, Hashable, Codable {                 // Shared/Models
    case negotiated(NegotiatedTLS)
    case refused(alert: UInt8)
}

public protocol ServerTLSObserving: Sendable {                             // PacketTunnel/Relay
    func observe(serverTLS: ServerTLSAnswer, for key: FlowKey) async
}
```

`PacketPipeline` is the conformer and writes it to the flow table (`FlowTable.setServerTLS`), so the
flow's next record — or its closing one — carries it to the store as `FlowRecord.serverTLS`
(schema `v8`, [`persistence.md`](persistence.md)). What had to be decided:

- **It is read where the stream is in order.** `Relay.handleServerData` receives what the outbound
  connection delivers, before it is re-segmented towards the device. The bytes are handed to the
  device first and read afterwards: a reading is metadata and never gets ahead of traffic.
- **Only the real server is read.** On an inspected flow the ServerHello the device receives is the
  one our own termination produced, signed with our leaf; reading it would report *our* choice of
  version and suite as the server's. So a flow's scanner exists only while its connection is the real
  server's: `install` drops it when a termination takes the connection over, and
  `rollbackTermination` creates a fresh one, because the plain connection that replaces a dead
  termination receives the whole ClientHello and answers with a ServerHello of its own. A candidate
  that falls back to passthrough before anything is installed keeps the scanner it was born with.
  The figure for an inspected flow is the one the upstream connection negotiates; it does not come
  from a stream (§ *What an inspected flow's server chose*, below).
- **A flow carries an answer, not an outcome.** `negotiated` and `refused(alert:)` say something
  about the server's TLS and are stored. The other four reasons a scanner gives up — not TLS, not a
  ServerHello, malformed, too large — say nothing about it: the flow is left with no answer and the
  session counts it. Storing "this was not TLS" next to a version would make an absence look like a
  finding.
- **Armed by the same rule as the SNI:** TCP against 443, and only when an observer exists.
- **Three counters in `RelayStats`**, next to the SNI pair: `serverHelloObserved`,
  `serverHelloRefused` and `serverHelloUnavailable`. A flow that closes before the server says
  anything is in none of them. No screen reads them yet.

### What an inspected flow's server chose ✅

An inspected flow has two TLS connections, and the ServerHello the device receives belongs to the
wrong one. The real server answers on the **upstream leg** — the `NWConnection` the termination
opens — which Network.framework encrypts, so there is no stream to read. There is its result:

```swift
enum UpstreamTLSReading {                                                  // PacketTunnel/TLS
    static func negotiated(version: tls_protocol_version_t, cipherSuite: tls_ciphersuite_t) -> NegotiatedTLS?
    static func negotiated(by connection: NWConnection) -> NegotiatedTLS?
}
```

`NetworkRelayConnection` takes an optional `onTLSNegotiated` and calls it when the connection
becomes ready, **before** `onReady`. `NetworkTLSTerminationEngine` builds the upstream leg with it,
and the reading travels up the same way the outcome does — `makeTermination(onUpstreamTLS:)`,
`TLSInterceptor.open(onUpstreamTLS:)`, `FlowInspecting` — to the relay, which hands it to the
**same** `ServerTLSObserving` seam as `ServerTLSAnswer.negotiated`. Nothing downstream of the seam
changed shape. This asks our own connection what it negotiated, which any TLS client may do of its
own; ADR 0003 is not involved. What had to be decided:

- **A second callback, not a wider `onResolve`.** The upstream leg negotiates when it opens; the
  decision arrives when the flow ends. And one can exist without the other: a client that rejects
  our leaf ends as `notInspectable` after the upstream leg has already completed its handshake.
- **No conversion table.** `tls_protocol_version_t` and `tls_ciphersuite_t` are `uint16_t` whose
  values are the wire's (`0x0304`, the IANA codes) — checked in `SecProtocolTypes.h` and held by a
  test, so that an SDK that changed them would fail a test rather than store something else. A
  version of `0` is no reading.
- **The source is stored, because it cannot be derived and because it changes what the figure
  means** (`TLSAnswerSource`, column `tls_upstream`, schema `v10`). It cannot be derived from
  `tlsStatus`: a flow whose client pins ends `notInspectable`, and one whose termination fails
  midway stays `encrypted`, and either may carry an upstream reading. And the two sources answer
  **different ClientHellos**: a ServerHello read off the stream answers the app's, so it is what
  that connection really negotiated; the upstream figure answers the tunnel's, which offers what
  the system offers. It says what the server accepts, not what the app offered — a server that
  negotiates 1.3 with us may be talking 1.2 to an app that offers nothing newer. A report has to
  be able to say which of the two it is citing.
- **`fromHelloRetryRequest` is `false` for an upstream reading.** The system reports a finished
  handshake: the figure is the final one whether or not a retry happened, and it does not say.
- **The upstream leg offers the system's defaults**, with no minimum or maximum version and no
  suite list of our own. That is part of what the reading means.
- **A reading is taken only while the flow's connection is still that termination.** It reaches the
  relay through a task, so it can arrive late — after the flow is gone, or after
  `rollbackTermination` returned it to passthrough. In the second case nothing is lost: the plain
  connection that takes over receives the device's ClientHello and its ServerHello is read off the
  stream. Recording the late one could overwrite that reading, which is the better of the two.
- **Requested only when someone is listening**, like the plaintext sink: without a
  `ServerTLSObserving` the termination is opened with no callback.
- **One counter**, `RelayStats.upstreamTLSObserved`. Against `terminationsOpened` it says how many
  terminations completed their upstream TLS; it is not `flowsInspected`, for the pinning reason
  above.

**Unproven until a device runs it:** that the system trust evaluation the production upstream leg
uses (no verify block, by design) leaves the metadata readable at `.ready` exactly as the test
anchor does. Nothing suggests otherwise; the tests exercise the same `NetworkRelayConnection`.

**Tests (34):** hand-written vectors, as for the ClientHello — the version from the extension and
from `legacy_version`, with and without an extensions block, an unpublished version kept raw; the
HelloRetryRequest and a `random` one bit away from it; every chunk boundary, byte-by-byte feeding,
fragmentation across records and the TLS 1.2 record that carries the certificate too; alerts (whole,
split, wrong size, cutting a partial hello); non-TLS streams; a ClientHello; truncated bodies and
lying vectors; the three ways of exceeding the ceiling; sticky outcomes.

**Tests of the hookup (11, `RelayServerHelloTests`):** the answer from one chunk and from two, a
HelloRetryRequest marked, reported once per flow, an alert as a refusal, a non-TLS stream counted and
not reported, flows outside 443 and a relay without an observer never scanned — and the three that
only the relay can answer: the ServerHello of our own termination is never read, a candidate that
falls back to passthrough is, and after a rollback the real server is read from the start.

**Tests of the upstream reading (16):** `UpstreamTLSReadingTests` — the system's versions and
suites against their wire values, a value the SDK does not name kept as given, no version is no
reading; and, against a **real TLS server on loopback** through the production
`NetworkRelayConnection`: a TLS 1.3 server read as 1.3 with one of its three suites, a server
capped at 1.2 read as 1.2, the reading delivered before `onReady`, and a plain TCP connection
reporting nothing. `RelayServerHelloTests` — an inspected flow carries the upstream reading and no
stream is scanned for it, a pinned flow keeps it, no observer means no callback, and a reading that
arrives after a rollback or after the flow is gone is dropped. `TLSInterceptorTests` and
`NetworkTLSTerminationEngineTests` — the callback reaches the caller untouched and the upstream leg
is built with it.

### The certificate chain of TLS ≤ 1.2 ✅

Up to TLS 1.2 the server's `Certificate` message travels **in the clear**, right behind its
ServerHello and before any key exists. Reading it decrypts nothing, needs no local CA and does not
touch ADR 0003 — it is the same kind of read as the two hellos. TLS 1.3 encrypts it, so there the
tool reads nothing **and says so** rather than leaving an empty field.

```swift
public struct ServerCertificateScanner: Sendable {                         // PacketTunnel/TLS
    public struct Config { maxChainBytes = 32768; maxCertificates = 8; maxNameLength = 256 }
    public enum Outcome { case needMoreBytes, found(ServerCertificateReading), unavailable(Reason) }
    public enum Reason { case notTLSHandshake, alert(description: UInt8), unexpectedMessage(type: UInt8), malformed }
    public init(resuming: ServerHelloScanner.Remainder, config: Config = Config())
    public mutating func scan(_ bytes: Data) -> Outcome
}

public enum ServerCertificateReader {                                      // Shared/TLS
    public static func certificate(fromDER: ArraySlice<UInt8>, maxNameLength: Int) -> ServerCertificate?
}

public struct ServerCertificate { subject: CertificateName; issuer: CertificateName; notAfter: Date }   // Shared/Models
public struct ServerCertificateChain { certificates: [ServerCertificate]; isComplete: Bool }
public enum ServerCertificateReading { case chain(ServerCertificateChain), notSent(ServerCertificateAbsence) }
public enum ServerCertificateVisibility {
    case presented(ServerCertificateChain), notSent(ServerCertificateAbsence)
    case encryptedInHandshake, replacedByInspection, noNegotiation, notRead
    public init(answer: ServerTLSAnswer?, reading: ServerCertificateReading?)
}
```

What had to be decided:

- **A relay of scanners, not one more state.** `ServerHelloScanner` still settles on the hello and
  lets go; what it keeps is `remainder` — the handshake bytes and the stream bytes that had already
  arrived *behind* the ServerHello — and `ServerCertificateScanner` starts from there. They answer
  different things at different times: the version is reported the moment it is read, and the chain
  arrives several segments later, or never (a resumed session sends none). One scanner would have
  to hold the first until it knew about the second. In TLS 1.2 the certificate usually shares the
  ServerHello's record, so the first `scan` of the second scanner is called with no new bytes and
  often already has its answer.
- **Only for a version known to send it in the clear** — `TLSProtocolVersion.sendsCertificateInClear`,
  SSL 3.0 to TLS 1.2, one tested property. For 1.3, and for a value that is no published version,
  no scanner is created: it would only see opaque records.
- **What follows the ServerHello says which handshake this is.** `Certificate` (11) is the chain.
  A ChangeCipherSpec record, or a `NewSessionTicket` (4), is the **abbreviated handshake**: the
  session was resumed and the server does not present itself again —
  `.notSent(.resumedSession)`. A `ServerKeyExchange` (12) or `ServerHelloDone` (14) is a full
  handshake without a certificate, an anonymous or pre-shared-key suite —
  `.notSent(.noCertificateMessage)`. Both are readings, and the flow carries them: "no certificate
  was sent" is a fact about the connection. Message and content types were checked against IANA's
  *TLS HandshakeType* and *TLS ContentType* registries.
- **What does not fit is said, and the leaf is not lost with it.** A chain is normally 3–6 KiB. The
  scanner accumulates at most `maxChainBytes` of the message and **decides when it has that much**,
  without waiting for a message that declares 16 MiB to finish arriving; it keeps at most
  `maxCertificates`; and reading **stops at the first certificate that cannot be read** instead of
  skipping it. So what is kept is always a *prefix* of what was sent — its first element, if there
  is one, is the server's own — and `isComplete` says whether it is all of it. An empty, incomplete
  chain means "certificates were sent and none could be read".
- **A flight that cannot be read is counted, not stored**: an alert after the hello, a message that
  has no business there, a record or a list whose lengths disagree. The flow keeps its version and
  gets no certificate reading, the same rule as an unreadable ServerHello.
- **Three fields, and no validation.** Subject, issuer and `notAfter`, read from the start of the
  TBSCertificate; the key, the extensions and the signature are not looked at. Nothing checks the
  signature, the dates, that the chain reaches a root or that the name is the host's. It says "the
  server presented this", which is all a passive observer can say.
- **Its own reader, not `SecCertificate`.** On iOS `Security` exposes neither the issuer nor the
  validity of a certificate, and this runs in the extension on bytes the other end chooses.
  `DERReader` (single-byte tags, definite lengths, every length checked against what is there) and
  `ServerCertificateReader` are pure and tested byte by byte, including every truncation of a
  certificate. The date is computed with integer arithmetic, not `Calendar`.
- **A name is text the server picks, so it is escaped and bounded.** It is written as RFC 4514
  (`CN=…,O=…,C=…`, most specific first, the short names of its § 3 table and the dotted OID for
  anything else). The special characters of § 2.4 get a backslash — a value containing
  `,O=Trusted Bank` cannot pass for a second attribute — and every character that is not visible
  (controls, **format characters such as the direction overrides**, line separators, private use,
  unassigned) is written as `\XX` per UTF-8 byte, so a name cannot break a report's row or read
  backwards. A value that is not a string, or does not decode, is `#` and the hex of its TLV. Over
  `maxNameLength` it is cut and **marked** (`CertificateName.isTruncated`), not ended in an ellipsis
  a reader would have to guess at.
- **The same seam, a second method** — `ServerTLSObserving.observe(serverCertificates:for:)` —
  rather than a seam of its own like the client's offer: the same end says it, in the same flight,
  and it cannot exist without a ServerHello. It is a **separate field** of the flow
  (`FlowRecord.serverCertificates`) set by its own task, so neither reading waits for the other
  and the order in which they reach the flow table does not matter.
- **Never our own termination's certificate.** The scanner lives exactly as long as the ServerHello
  one would: it is dropped when a termination replaces the flow's connection, and after a rollback
  the new plain connection is read from its ServerHello on.
- **Why there is no chain is derived, not stored** — `ServerCertificateVisibility`, which is what a
  report reads instead of the bare field. A reading, when there is one, wins. Without one: a
  refusal is `noNegotiation`; an upstream reading is `replacedByInspection` (the certificate the
  app received was the local CA's leaf); TLS 1.3 from a ServerHello is `encryptedInHandshake`;
  anything else is `notRead`, including TLS ≤ 1.2 whose flight was cut and a version no one
  published, which is not assumed to encrypt.
- **Three counters**, `RelayStats.serverCertificatesObserved`, `…NotSent` and `…Unavailable`.
  Against `serverHelloObserved` they do **not** say how many are missing: TLS 1.3 flows are never
  attempted.

**Not read, on purpose:** the upstream leg of an inspected flow. There the tunnel is the TLS
client and the system would hand over the peer's chain (in 1.3 too), but that is a different
source answering a different client, as with the version, and it is not part of this increment.
Nor `notBefore`, the SANs, or a `CertificateStatus`.

**Unproven until a device runs it:** that real TLS 1.2 servers' flights are read (the vectors are
built with the local CA's own DER writer and by hand, not captured).

**Tests (81 + 8):** `DERReaderTests` (10) — short and long form, a slice inside a larger buffer,
lengths that declare more than there is, indefinite length, more than four length bytes, high tag
numbers, truncated headers. `ServerCertificateReaderTests` (27) — the three fields; certificates
the local CA really issues; a v1 certificate; attribute order, short names and OIDs, multi-valued
RDNs; five string types; **a value that tries to forge an attribute**, the special characters,
control and format characters; values that are not text; the name limit; OIDs including a first
subidentifier of two bytes; both time forms, both centuries of the short one, leap days, what the
writer writes, nine malformed times; and every truncation of a certificate.
`ServerCertificateScannerTests` (33) — the chain in the ServerHello's record, in its own, arriving
later, split across records and at seven chunk sizes; what follows it ignored; the two shapes of a
resumed session and the certificate-less handshake; alerts, unexpected messages, non-handshake
records, a ChangeCipherSpec mid-message, lying lengths; an unreadable certificate stopping the
reading; the count limit, the byte limit, a message that declares 16 MiB; and the hand-over from
`ServerHelloScanner`. `ServerCertificateVisibilityTests` (11). And in `RelayServerHelloTests` (8):
the chain from the shared record, the version reported before the chain arrives, nothing read
after a TLS 1.3 hello, a resumed session, an unreadable flight counted and not reported, once per
flow, our own termination's certificate never read, and the real server's read after a rollback.

## How a stream opened ✅

Everything above reads a handshake **on port 443**. Off that port nothing was looked at, and a
flow's `TLSInspectionStatus` was whatever its port said — which made "this connection went in the
clear" something no flow could prove. `StreamOpeningScanner` (`PacketTunnel/Relay`) closes that: it
reads the first bytes the device sends on **every** TCP flow and says which of three things they
are (`StreamOpening`, [`data-model.md`](data-model.md)).

```swift
public struct StreamOpeningScanner: Sendable {
    public struct Config: Sendable { public var maxRequestLineBytes: Int }   // 8192
    public enum Outcome: Sendable, Equatable { case needMoreBytes, decided(StreamOpening) }
    public init(config: Config = Config())
    public mutating func scan(_ data: Data) -> Outcome
}

public protocol StreamOpeningObserving: Sendable {
    func observe(streamOpening: StreamOpening, for key: FlowKey) async
}
```

- **A TLS handshake** is a record header of type 22, major version 3, minor ≤ 4, a length between
  4 and 2^14, and a first handshake message of type 1 (ClientHello). Decided on the sixth byte.
- **An HTTP request is a whole request line, not a prefix.** This is the only statement of "sent
  unencrypted" the tool makes, so starting with `GET ` is not enough: the stream has to carry
  RFC 9112 § 3's `method SP request-target SP HTTP-version` and the end of the line (CRLF, or a
  bare LF as § 2.2 allows a recipient to accept). The method is any RFC 9110 token rather than a
  table of known ones, and the version is `HTTP/` digit `.` digit — which also takes the
  cleartext HTTP/2 preface (`PRI * HTTP/2.0`). A line that reaches 8192 bytes without ending —
  RFC 9112 recommends supporting at least 8000 — is left unrecognised.
- **Anything else is `unrecognised`**, which claims nothing: SSH, SMTP, Noise on 443.
- **It keeps no bytes.** It is a state machine that advances one byte at a time; one exists per
  TCP flow inside an extension with a memory budget. Once decided it stays decided and looks at
  nothing more.

The hookup. The relay creates one scanner per TCP flow when it has someone to tell, and feeds it
where the state machine hands over the device's bytes (`.sendToServer`) — the one point every
byte passes exactly once, whether it is then sent to the server, held for an inspection
candidate or handed to a termination. It is separate from `readHandshake` on purpose: that one
exists only on 443 and decides whether a flow is inspected; this one runs on every port and only
records. The reading leaves through `StreamOpeningObserving`, once per flow, and the flow table
stores it and raises a `plaintext` flow to `encrypted` when it is a TLS handshake
(`FlowTable.setStreamOpening`). Schema `v14` ([`persistence.md`](persistence.md)).

Three counters in `RelayStats`: `streamOpeningsTLS`, `streamOpeningsHTTP`,
`streamOpeningsUnrecognised`. Against `tcpFlowsOpened` they say how many flows closed before
sending enough to decide.

It decrypts nothing and reads only what the owner's device sent in the clear; ADR 0003 is not
involved.

**What it does not read:** the server's side (a protocol where the server speaks first is
`unrecognised` or has no reading), a connection upgraded later (`STARTTLS`), and UDP — a datagram
that is not QUIC is not looked at.

`StreamOpeningScannerTests` (15) — the ClientHello record on every minor version and at its
length limits; what is a record but not a ClientHello; the request line in its forms, including
absolute-form, `CONNECT`, `OPTIONS *` and the HTTP/2 preface; nothing decided before the end of
the line; nine things that only look like a request line; other protocols; the ceiling; every
split of three streams; and that it stays decided. `RelayStreamOpeningTests` (9) — HTTP on 80,
TLS on 5223, 8443, 993 and 443, the unrecognised on any port, a line split across segments read
once, the stream to the server unchanged, a flow that sends nothing, no scanner without an
observer, and a candidate for inspection whose bytes are held.

## Tests

- Leaf minting produces a valid chain under the local CA (verify with `Security`).
- A simulated client that rejects the CA yields `.notInspectable` and triggers passthrough.
- A simulated client that trusts the CA yields decoded plaintext, and the outbound side uses
  system trust. (Full live handshake is a device smoke test; cert logic is Simulator-testable.)
