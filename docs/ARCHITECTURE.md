# TunnelVision — Architecture

This document describes how TunnelVision captures and processes traffic on-device, the constraints imposed by iOS, and the security model that bounds what the tool will and will not do.

## Process model

TunnelVision ships as three build products in one Xcode project:

| Component | Kind | Role |
|-----------|------|------|
| `TunnelVision` | iOS app | SwiftUI UI, tunnel lifecycle control, history queries |
| `PacketTunnel` | App extension (`NEPacketTunnelProvider`) | packet capture, parsing, relay, optional TLS termination |
| `Shared` | Framework | data models, persistence, and IPC layout shared by both |

The app and the extension are **separate processes** that never share memory directly. They communicate only through a shared **App Group** container: a SQLite database for durable history and a memory-mapped ring buffer for the live feed.

## Data flow

1. **Tunnel establishment.** The app configures an `NETunnelProviderManager` and starts the tunnel. The extension's `startTunnel(options:)` sets `NEPacketTunnelNetworkSettings` — addresses, DNS, and the included routes that pull the device's traffic into the tunnel. iOS creates a `utun` virtual interface and begins delivering the device's outbound IP packets to the extension.
2. **Read loop.** The extension reads batches of raw IP datagrams from `packetFlow.readPackets(completionHandler:)`. Each datagram is a complete IP packet with no framing of our own.
3. **Parsing.** For every packet we read the IP version, then the L4 header:
   - IPv4/IPv6 header → protocol, source/destination address.
   - TCP/UDP header → source/destination port; TCP sequence/ack/flags.
   The 5-tuple (proto, src ip:port, dst ip:port) is the **flow key**.
4. **Flow table.** Packets are attached to a flow entry. UDP flows are stateless from our perspective. TCP flows carry reassembly state.
5. **Routing decision.** Based on flow classification (below) a packet is either relayed as-is (passthrough) or handed to the userspace TCP path for inspection.
6. **Relay.** Outbound data leaves the extension through `Network.framework` (`NWConnection`). Connections originated by the extension are **not** re-captured by the tunnel, so they reach the real internet directly. Response bytes are written back into the tunnel via `packetFlow.writePackets`.
7. **Record and surface.** Flow records go to SQLite; packet metadata is pushed into the ring buffer; full captures are streamed to `pcap`. The app renders from both.

## Flow classification

Not every packet deserves the same amount of work, and doing too much per packet is what wrecks both the memory budget and the battery. Flows are classified on first sight:

- **UDP / latency-sensitive (VoIP, QUIC, media streaming):** metadata-only. Logged as a flow with byte/packet counters and relayed without buffering payload. QUIC is treated as opaque UDP — it is not TLS-terminated.
- **TCP, not port 443:** reassembled and logged; payload captured to `pcap`. Plaintext protocols (HTTP, etc.) are decoded for the inspector.
- **TCP, port 443, TLS inspection off:** relayed as opaque bytes; logged as an encrypted flow with metadata (SNI when visible in the ClientHello, byte counts, timing).
- **TCP, port 443, TLS inspection on:** handed to the userspace TCP + TLS path. If the client trusts the local CA the flow is decrypted, logged, and re-encrypted to the real server. If the client rejects the CA (pinning), the flow is transparently relayed and marked *not inspectable* — see the security model.

## The userspace TCP path

The extension only ever receives raw IP packets, so to read or terminate a TCP byte stream we cannot lean on the kernel socket layer for the client side — we reconstruct it ourselves:

- **Reassembly.** Per TCP flow we track the initial sequence number and buffer segments into an ordered window, handling out-of-order arrival and retransmissions, exposing an in-order byte stream to the layer above. The reassembly buffer is bounded; a flow that exceeds it is downgraded to metadata-only rather than allowed to grow without limit.
- **Termination (inspection only).** When a port-443 flow is selected for inspection, a userspace TCP endpoint completes the handshake with the client, and a TLS server presents a **leaf certificate minted on the fly** for the destination host, signed by the app's local root CA. If the client accepts it, we now hold the plaintext. We then open a *separate* real `NWConnection` to the destination, speaking TLS as a normal client with standard system trust, and shuttle bytes between the two — logging the plaintext in the middle. TunnelVision is a client to the real server exactly like any other app; it earns no special trust and cannot see servers it can't legitimately reach.

Flows that are only relayed (the common case) never enter this path; their packets are forwarded with minimal per-packet work.

## Memory strategy

A `NEPacketTunnelProvider` runs in a memory-constrained extension process (historically ~15 MB; larger but still tight on current iOS, and the OS will terminate the extension if it exceeds its budget). Everything is designed around that:

- **Stream, don't accumulate.** Captures are written to `pcap` files incrementally as packets arrive; a multi-hour capture never needs to be resident.
- **Bounded buffers everywhere.** The flow table, per-flow reassembly windows, and the IPC ring buffer are all fixed-capacity. Pressure is handled by **dropping** (and counting drops for the UI) rather than allocating.
- **Release immediately.** Packet buffers are recycled as soon as they are parsed and forwarded. Payload is not retained beyond what a selected inspection flow needs in-flight.
- **Metadata over payload.** For the vast majority of flows we persist compact metadata rows, not bytes.

## Inter-process communication

Two channels, each with a single writer and single reader, both in the App Group container:

- **Durable history — SQLite (GRDB).** The extension appends flow and packet-metadata rows. The app reads for history views. SQLite in WAL mode tolerates the concurrent reader. GRDB is chosen over Core Data / SwiftData because the workload is a high rate of small append-only inserts, where a thin SQLite layer is markedly faster and more predictable under memory pressure. This is a deliberate deviation from the stack default.
- **Live feed — memory-mapped ring buffer.** A fixed-size file mapped into both processes holds a lock-free single-producer/single-consumer ring of packet-metadata records. The extension is the sole producer; the app is the sole consumer. A **Darwin notification** (`CFNotificationCenter` / `notify(3)`) is posted as a wakeup only — Darwin notifications carry no payload, so they signal "new data available" and the app then drains the ring. This corrects a common misconception that Darwin notifications can transport packet data; they cannot, and mmap is what actually moves the bytes.

## Data formats

### pcap

Standard libpcap format: a 24-byte global header followed by per-packet records (timestamp, captured length, original length, then the raw bytes). Written as an append stream. Files open directly in Wireshark and `tcpdump`.

### SQLite schema (conceptual)

- `flows` — `id`, `flow_key` (proto, src/dst addr+port), `first_seen`, `last_seen`, `bytes_out`, `bytes_in`, `packets`, `tls_status` (`plaintext` / `encrypted` / `inspected` / `not_inspectable`), `sni`.
- `packets` — `id`, `flow_id`, `ts`, `direction`, `length`, `tcp_flags`, `pcap_offset`.

Indexes on `flows.last_seen` and `packets.flow_id` back the timeline and inspector queries. Migrations are versioned through GRDB.

### Ring-buffer record

A fixed-width packed struct: monotonic timestamp, flow key, direction, length, and a compact flags field. Fixed width keeps the ring lock-free and lets the app compute slot offsets without parsing.

## Security model and non-goals

TunnelVision is a **first-party, consent-based analyzer of the device owner's own traffic**. The following are explicit non-goals, and building them would be out of scope:

- **No third-party SSL-pinning bypass.** A pinned app rejecting the local CA is the security control working as intended. TunnelVision detects the failed handshake, relays the flow untouched, and marks it *not inspectable*. It does not attempt certificate-pinning defeat, hooking, or any technique to strip another app's protections. Respecting other software's security posture is a firm boundary, not a limitation to be worked around.
- **No covert or third-party interception.** The tunnel is a visible, user-approved Personal VPN profile. TLS inspection additionally requires the user to generate a CA in-app and manually install and fully trust it in iOS Settings — friction Apple designed in on purpose, which TunnelVision surfaces rather than hides.
- **No tampering.** Inspected traffic is logged and forwarded unchanged. The firewall function is flow-level allow/block; there is no payload injection or rewriting.
- **No exfiltration.** All capture, storage, and analysis stay on-device in the sandbox and App Group. Nothing is transmitted to any TunnelVision-operated service.

These boundaries are what keep TunnelVision a legitimate engineering and auditing tool — comparable to Charles, Proxyman, or Wireshark, and squarely within the category Apple's NetworkExtension APIs are meant to serve.
