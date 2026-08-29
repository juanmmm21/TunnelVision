# Shared/TLS

The local certificate authority behind opt-in HTTPS inspection: the pure X.509/ECDSA core and the
Keychain shell over it.

It lives in `Shared` (since M10) rather than in the extension because **the CA is the user's, not the
tunnel's**, and both halves of the product need it — the extension to sign leaves during a handshake,
the app to generate it, hand its root certificate to the guided install flow, and ask the system
whether it is trusted ([`../../docs/ux/onboarding-and-consent.md`](../../docs/ux/onboarding-and-consent.md)).
No IPC is involved: app and extension declare the same shared **keychain access group** in their
entitlements, so both look at the very same items and there is no published copy that can go stale.

- `DERWriter.swift` — minimal ASN.1 DER encoder (neither `Security` nor `CryptoKit` serializes
  certificates on iOS, so the TBS is built by hand and signed). Internal to the framework.
- `X509Certificate.swift` — builds + signs an X.509 v3 certificate given a signing closure
  (ECDSA-SHA256, EC P-256, minimal extension set incl. SAN with `dNSName`/`iPAddress`). Internal.
- `CertificateAuthority.swift` — the pure, Simulator-testable core: a P-256 root + self-signed root
  cert, minting ephemeral leaves (`MintedCertificate` = cert DER + PKCS#8 key) cached per host.
  Verified end-to-end against `Security`'s `SecTrustEvaluateWithError`.
- `LocalCA.swift` — the Keychain/`SecIdentity` shell over that core (persist the root key; vend a
  `SecIdentity` from a `MintedCertificate`; remove it all again). Validated by compilation: the
  Keychain needs device entitlements.

Who consumes it: `PacketTunnel/TLS` (leaf minting for the userspace handshake) and
`TunnelVision/Services/CertificateStatusReader.swift` (does a CA exist, and does the system trust it).

**Specs:** [`../../docs/spec/relay-and-tls.md`](../../docs/spec/relay-and-tls.md),
[`../../docs/decisions/0003-no-third-party-pinning-bypass.md`](../../docs/decisions/0003-no-third-party-pinning-bypass.md) · **Milestones:** M8, M10
