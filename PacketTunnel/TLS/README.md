# PacketTunnel/TLS

Opt-in TLS inspection: userspace TCP + TLS termination and the **pinning-passthrough** invariant
(rejected handshake ⇒ `notInspectable` + relay untouched — never bypassed).

The certificate authority itself (`DERWriter`, `X509Certificate`, `CertificateAuthority`, `LocalCA`)
moved to [`../../Shared/TLS`](../../Shared/TLS) in M10: the app needs it too, to generate the CA and to
check whether the system trusts it. Both processes reach the same Keychain items through the shared
access group, so nothing here changed except where the files live.

**Implemented (M8, second half — TLS interceptor decision core):**

- `TLSInterception.swift` — the pure, Simulator-testable policy: residual preconditions
  (`gate`: CA ready + SNI present) and the outcome mapping (`decide`), including the
  **pinning-passthrough** invariant (a pinned client ⇒ `notInspectable`, never retried).
- `TLSInterceptor.swift` — the `actor` orchestrating that policy against an injectable
  `TLSTerminationEngine` (the userspace handshake I/O). Tested against a scripted engine double.

**Implemented (2026-08-12 — the memory-fed TLS server, the project's last feasibility unknown):**

- `TLSServerSession.swift` — the seam: a TLS server fed from bytes already held in memory rather
  than from a socket, shaped like `RelayConnection` (start with handlers, push bytes, close, cancel)
  because it is the same problem seen from the other side.
- `LoopbackTLSServerSession.swift` — the production conformer. Network.framework only speaks TLS
  *server* through an `NWListener`, and a listener is only fed by a socket, so the session raises one
  bound to `127.0.0.1` carrying the host's leaf and dials its own plain-TCP connection to it: tunnel
  records go in and out through that bridge, plaintext through the accepted connection. Loopback is
  handled by `lo0`, so it never re-enters our own tunnel; the listener stops listening as soon as it
  accepts its one legitimate client.

Proven in the Simulator against a **real** BoringSSL client (`LoopbackTLSServerSessionTests`, 5
tests) — full handshake with plaintext both ways, a pinning client reported as a permanent rejection
rather than a failure (ADR 0003), a leaf for the wrong host, clean close and idempotent cancel.
`SecureTransport` (`SSLSetIOFuncs`) was measured as the alternative: still alive on iOS 26 and it does
start memory-fed, but deprecated since iOS 13, no TLS 1.3, and Apple's own header says to use
Network.framework. The seam is what would make that swap cheap if it is ever needed.

**Implemented (2026-08-12 — the termination engine):**

- `TLSTerminationConnection.swift` — the pair: the server session (client side) against the upstream
  leg (real server, system trust), shuttling plaintext between them. It **is** a `RelayConnection`,
  because from the relay a termination is indistinguishable from an outbound connection — which is
  what makes the hookup a change of which connection gets created rather than a second path. The
  outcome leaves through its own channel, and its mapping is where ADR 0003 lives: a client that
  rejects our leaf is `pinned`, permanent and never retried.
- `NetworkTLSTerminationEngine.swift` — the production conformer. Mints the leaf first (seam
  `LeafMinting`, satisfied by `LocalCA`) and dials only then, to the address the device chose,
  announcing the name it announced. Its upstream leg carries **no verify block of its own** on
  purpose: the system evaluates it, so we stay an ordinary client to the real server.
- `TLSInterceptor.swift`/`TLSTerminationEngine` — the engine is now a **factory**: the reassembled
  stream belongs to the relay, so the engine builds the termination and the outcome arrives when the
  flow ends. The policy is untouched.

**Implemented — reading the two hellos, which travel in the clear (no CA, no decryption):**

- `ClientHelloScanner.swift` — the host a client announces (SNI), read incrementally from the
  outbound stream. It is what names a flow. From the same message it reads what the client
  **offered** (`offer`): the TLS versions it accepts — an exact list from `supported_versions`, or
  only a ceiling from `legacy_version` — and its ALPN, with GREASE dropped and Encrypted Client
  Hello marked.
- `ServerHelloScanner.swift` — the TLS version and cipher suite a server chose, read incrementally
  from the inbound stream: the version from `supported_versions` when present (that is how TLS 1.3
  announces itself), an alert reported as the server refusing, a HelloRetryRequest read and marked.
- `ServerCertificateScanner.swift` — the certificate chain a TLS ≤ 1.2 server presents, which
  travels in the clear right behind its ServerHello. It takes over the stream where
  `ServerHelloScanner` left it (`remainder`), tells a chain from a resumed session and from a
  handshake without a certificate, and keeps a bounded prefix of the chain, saying when it is not
  all of it. Never created for TLS 1.3, where the certificate is encrypted.
- `TLSByteReader.swift` — the bounds-checked cursor the three share.
- `TLSRecordHeader.swift` — the record header the two inbound scanners both cut the stream by.

**Still pending here:** the relay hookup that routes an `.inspect` flow into a termination instead of
straight through. **Device-only unknown:** whether a network extension may bind a loopback listener
under iOS's sandbox — the Simulator cannot answer that.

**Specs:** [`../../docs/spec/relay-and-tls.md`](../../docs/spec/relay-and-tls.md),
[`../../docs/decisions/0003-no-third-party-pinning-bypass.md`](../../docs/decisions/0003-no-third-party-pinning-bypass.md) · **Milestone:** M8
