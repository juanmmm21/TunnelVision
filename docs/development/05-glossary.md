# 05 — Glossary

Domain vocabulary used across the specs and code. Terms are English; keep code identifiers
consistent with these.

| Term | Meaning |
|------|---------|
| **NetworkExtension (NE)** | Apple framework for VPNs, content filters, and DNS proxies. TunnelVision uses its packet-tunnel flavour. |
| **`NEPacketTunnelProvider`** | The subclass, running in the extension process, that receives raw IP packets from the system and can reinject them. |
| **`NETunnelProviderManager`** | The app-side API used to install, configure, start, and stop the tunnel profile. |
| **utun** | The virtual network interface iOS creates for the tunnel; the OS routes device traffic to it. |
| **packet flow** | `provider.packetFlow`, the object you `readPackets`/`writePackets` on. Delivers `[Data]` (IP packets) with `[NSNumber]` protocol families (`AF_INET`/`AF_INET6`). |
| **Raw IP packet** | A complete IP datagram with no link-layer framing — what the extension reads. pcap link type is `LINKTYPE_RAW`. |
| **5-tuple** | (protocol, source IP, source port, destination IP, destination port). Our `FlowKey`. |
| **Flow** | All packets sharing a 5-tuple (in both directions), tracked as one logical connection. |
| **Flow table** | Bounded map from `FlowKey` to flow state, with LRU eviction. |
| **TCP reassembly** | Reconstructing an ordered byte stream from TCP segments using sequence numbers, handling out-of-order arrival and retransmissions. |
| **Userspace TCP stack** | A TCP implementation in the extension (not the kernel socket layer) used to *terminate* a client connection so its bytes can be read for inspection. |
| **Relay / passthrough** | Forwarding a flow's packets to the real internet without terminating or decrypting it. The default for most traffic. |
| **TLS termination** | Completing the TLS handshake with the client ourselves (presenting a minted leaf cert) so we hold plaintext, then opening a separate real TLS connection to the true server. |
| **Local CA** | A root certificate authority generated inside the app, whose private key stays on device; the user installs and trusts it to enable inspection. |
| **Leaf certificate** | A short-lived certificate minted on the fly for a destination host, signed by the local CA. |
| **Certificate pinning** | An app hardcoding which certificate/CA it will accept. Pinned apps reject our CA; we pass them through and mark them `notInspectable`. |
| **SNI** | Server Name Indication — the hostname sent in the TLS ClientHello; visible even without decryption and logged as flow metadata. |
| **QUIC** | HTTP/3's UDP-based transport. Treated as opaque UDP and passed through; not TLS-terminated. |
| **App Group** | A shared container both the app and the extension can access; hosts the SQLite DB and the mmap ring buffer. |
| **mmap ring buffer** | A fixed-size memory-mapped file used as a lock-free single-producer/single-consumer queue for the live packet feed. |
| **SPSC** | Single-producer, single-consumer — the concurrency model of the ring buffer (extension produces, app consumes). |
| **Darwin notification** | A lightweight, payload-less cross-process signal (`notify(3)` / `CFNotificationCenter`) used only to wake the consumer; the data itself travels via mmap. |
| **Back-pressure** | When a bounded buffer is full, the producer drops (and counts) rather than growing memory. |
| **GRDB** | The SQLite library used for durable history. |
| **WAL** | SQLite Write-Ahead Logging mode, allowing the app to read while the extension writes. |
| **DLT_RAW / LINKTYPE_RAW (101)** | The pcap link-layer type for files that contain raw IP packets with no Ethernet/loopback header. |
| **Definition of Done (DoD)** | The completion criteria for a roadmap milestone. |
| **ADR** | Architecture Decision Record — a short document capturing one decision and its rationale, under `docs/decisions/`. |
