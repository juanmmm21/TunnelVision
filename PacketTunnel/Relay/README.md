# PacketTunnel/Relay

Outbound relay via `NWConnection` and reinjection of responses; UDP/QUIC and non-inspected
passthrough. The default path for most traffic.

Because the bytes pass through it in order, the relay also reads the two halves of a TLS handshake
that travel in the clear, without decrypting anything: the name in the ClientHello (`SNIObserving`),
the TLS versions and ALPN that same ClientHello offered (`ClientTLSObserving`), and the version and
cipher suite in the ServerHello (`ServerTLSObserving`) — followed, when that version is TLS ≤ 1.2,
by the certificate chain the server presents behind it, through the same seam. What the server says
is only ever read from the real server — never from a termination of our own.

**Spec:** [`../../docs/spec/relay-and-tls.md`](../../docs/spec/relay-and-tls.md) · **Milestone:** M8
