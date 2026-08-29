# Spec — Module overview

This directory specifies each module with concrete Swift interfaces. Design the types and
signatures exactly as written here before implementing bodies; if you must change a contract,
change the spec in the same commit.

## Module map and ownership

```
Shared (framework, linked into both targets)
├── Models        value types: FlowKey, FlowRecord, PacketMeta, headers, enums   → data-model.md
├── Persistence   GRDB store (FlowStore actor), schema, migrations               → persistence.md
├── Capture       streaming pcap writer (moved here in M11)                      → pcap.md
├── Plaintext     decrypted-content writer, format and per-flow budget           → plaintext.md
└── IPC           ring buffer + Darwin signal + control-channel codec            → ipc.md

PacketTunnel (NEPacketTunnelProvider extension)
├── PacketTunnelProvider   lifecycle, network settings, read/write loop          → tunnel-provider.md
├── Pipeline               the hot path minus packetFlow (pure, testable)        → tunnel-provider.md
├── IP                     IPv4/IPv6/TCP/UDP parsing                             → packet-parsing.md
├── Flow                   FlowTable + TCPReassembler                            → flow-and-reassembly.md
├── Relay                  outbound NWConnection relay + passthrough             → relay-and-tls.md
└── TLS                    local CA, leaf minting, opt-in termination            → relay-and-tls.md

TunnelVision (app)
├── Services      tunnel control (M9), live feed reader, history reader          → app-services.md
└── ViewModels/Views  screens, charts, inspector                                 → ../ux/
```

## Dependency direction

`Shared` depends on nothing but Apple frameworks + GRDB. `PacketTunnel` and `TunnelVision`
depend on `Shared`, never on each other. The two processes only ever meet at the App Group
container (SQLite + ring buffer).

```
TunnelVision(app) ─┐                         ┌─ PacketTunnel(ext)
                   ├─▶ Shared ◀──────────────┤
                   └─ reads DB + ring ◀──── writes DB + ring
```

## Threading model

| Component | Isolation |
|-----------|-----------|
| Packet read loop | extension's provider, async loop |
| `FlowTable`, `TCPReassembler` | `actor` (serialized) |
| `PcapWriter` | `actor` (serialized file I/O) |
| `FlowStore` (GRDB write) | `actor`; GRDB uses its own writer queue underneath |
| Ring buffer producer | called from the read loop; lock-free SPSC |
| Ring buffer consumer | app side, background task; lock-free SPSC |
| View models | `@MainActor` |

## The hot path (per packet), at a glance

1. read `Data` + protocol family from `packetFlow`
2. parse IP + L4 → `FlowKey` + `PacketMeta` (pure, [`packet-parsing.md`](packet-parsing.md))
3. update `FlowTable`; if TCP and inspected, feed `TCPReassembler` ([`flow-and-reassembly.md`](flow-and-reassembly.md))
4. route: passthrough (relay) or terminate for inspection ([`relay-and-tls.md`](relay-and-tls.md))
5. append `PacketMeta` to ring buffer (live) and, batched, to `FlowStore` (durable)
6. stream bytes to `PcapWriter` ([`pcap.md`](pcap.md))
7. recycle the buffer

Everything on this path is bounded and allocation-frugal; see the memory rules in
[`../development/02-coding-standards.md`](../development/02-coding-standards.md).
