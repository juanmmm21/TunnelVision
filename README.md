# TunnelVision

**On-device network traffic analyzer and local firewall for iOS — inspect, log, and export your own traffic without a jailbreak.**

TunnelVision turns an unmodified iPhone or iPad into a portable packet analyzer. It routes the device's own network traffic through a local, on-device tunnel, parses every IP packet, reconstructs TCP flows, records connections to a queryable history, and renders the whole picture in a native SwiftUI dashboard. Optional, explicitly consented TLS inspection lets an engineer see inside their own HTTPS traffic for debugging and auditing — the same capability desktop tools like Charles, Proxyman, and Wireshark provide, running entirely on the device.

There is no remote server and no companion Mac. Capture, storage, and analysis all happen inside the app sandbox.

---

## What it is and the problem it solves

Debugging mobile networking on iOS is awkward. To see what an app actually sends you normally tether the phone to a desktop proxy, trust a CA, and hope the app routes through it. That workflow is desktop-bound, leaks traffic to another machine, and falls apart in the field.

TunnelVision does the capture on the phone itself. Apple's **NetworkExtension** framework exposes a supported, App-Store-shippable mechanism — `NEPacketTunnelProvider` — for a per-device "personal VPN" that terminates locally instead of forwarding to a VPN server. When the tunnel is active, the system hands the extension the raw IP packets leaving the device. TunnelVision reads those packets, understands them, and forwards them on to the real internet, acting as a transparent local relay that happens to keep a detailed record.

The result is a self-contained tool for engineers who need to answer questions like: *Which hosts is this app really contacting? On what ports? How much data? What does my own API call look like on the wire? Is something phoning home in the background?* — all from the device, with the data never leaving it.

## Scope and responsible use

TunnelVision is a **first-party, consent-based** analyzer. It is built to inspect the traffic of the person holding the device, and its design deliberately refuses the parts of "traffic interception" that cross into attacking other software:

- **Only your own traffic, only with consent.** The tunnel is a user-approved Personal VPN profile. TLS inspection is **opt-in** and additionally requires the user to generate a root CA inside the app and *manually* install and enable full trust for it in iOS Settings — two deliberate steps Apple intentionally makes friction-heavy.
- **No third-party SSL-pinning bypass.** When an app pins its certificates, its TLS handshake against TunnelVision's CA will (correctly) fail. TunnelVision does **not** attempt to defeat that. The connection is passed through untouched and labelled *not inspectable* in the UI. Respecting other apps' security controls is a hard non-goal to circumvent — see [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#security-model-and-non-goals).
- **Read-and-relay, not tamper.** Inspected traffic is logged and forwarded unchanged. The "firewall" is flow-level allow/block, not packet injection or content rewriting.
- **Local only.** Captures and history live in the app's sandbox and App Group container. Nothing is uploaded anywhere.

This makes TunnelVision appropriate for debugging your own apps, auditing your own device, security education, and CTF-style analysis — and unsuitable, by construction, for intercepting anyone else's traffic.

## Engineering focus

The interesting part of this project is doing serious packet processing inside the tight envelope iOS gives a network extension:

- **A userspace TCP/IP path.** The extension only ever sees raw IP datagrams. To read or terminate a TCP stream you have to reassemble it yourself — sequence-number ordering, retransmit and out-of-order handling — in a userspace flow table, then terminate connections in a userspace stack when inspection is enabled.
- **Working under a hard memory ceiling.** Network extensions run in a separate process with a small memory budget (historically ~15 MB; larger but still constrained on current iOS). Buffers are bounded, captures are streamed straight to disk as `pcap`, and back-pressure drops rather than grows.
- **Zero-copy-ish IPC to the UI.** The extension and the app are different processes. High-rate packet metadata reaches the UI through a bounded ring buffer in a memory-mapped file inside the shared App Group container, with a Darwin notification used only as a lightweight "data available" wakeup — never as a data channel.
- **Throughput-first persistence.** History is stored in SQLite (via GRDB) rather than Core Data / SwiftData, because the write pattern is thousands of small append-only rows per second.

## How it works

```
                 ┌──────────────────────────────────────────────┐
                 │                  iPhone / iPad                 │
                 │                                                │
   all device    │   ┌───────────────┐      ┌──────────────────┐ │
   traffic  ────────▶│  utun virtual │─────▶│  PacketTunnel    │ │
                 │   │  interface    │ raw  │  extension        │ │
                 │   └───────────────┘  IP  │                   │ │
                 │                          │  • parse IP/TCP/UDP│ │
                 │   ┌──────────────────┐   │  • flow table +    │ │──▶ real
                 │   │  TunnelVision app │◀──│    TCP reassembly  │ │    internet
                 │   │  (SwiftUI)        │   │  • opt-in TLS      │ │
                 │   │  dashboard /      │   │    termination     │ │
                 │   │  timeline /       │   │  • pcap writer     │ │
                 │   │  flow inspector   │   └─────────┬──────────┘ │
                 │   └────────▲──────────┘             │            │
                 │            │   App Group container  │            │
                 │            └──── ring buffer + ──────┘            │
                 │                 shared SQLite                     │
                 └──────────────────────────────────────────────────┘
```

1. **Activation.** The user approves the Personal VPN profile. The app starts the tunnel via `NETunnelProviderManager`.
2. **Capture.** The extension reads raw IP packets from the tunnel's packet flow, parses headers (IPv4/IPv6, TCP/UDP), and keys each packet into a flow (5-tuple).
3. **Classify and route.** UDP and latency-sensitive traffic (VoIP, streaming) is relayed with metadata-only logging. TCP flows are reassembled; if TLS inspection is on and the peer trusts the local CA, port-443 flows are terminated, decrypted, logged, and re-originated to the real server.
4. **Record.** Flow records and packet metadata are appended to the shared SQLite store; full captures are streamed to `pcap` files on disk.
5. **Visualize.** The app reads the ring buffer for live updates and queries SQLite for history, drawing throughput charts, an interactive timeline, and a per-flow inspector.

## Architecture

Multi-target Xcode project: a SwiftUI app, a `NEPacketTunnelProvider` app extension, and a shared framework used by both across the App Group.

```text
TunnelVision/
├── README.md
├── docs/
│   └── ARCHITECTURE.md          # data flow, memory strategy, security model, formats
├── TunnelVision.xcodeproj
├── TunnelVision/                # main app target (SwiftUI UI + tunnel control)
│   ├── App/                     # @main App struct, scene setup
│   ├── Models/                  # UI-facing view models' data types
│   ├── ViewModels/              # dashboard / timeline / inspector state (async)
│   ├── Views/                   # SwiftUI: charts, timeline, flow inspector, CA setup
│   ├── Services/                # NETunnelProviderManager control, live-feed reader
│   └── Resources/
├── PacketTunnel/                # NEPacketTunnelProvider extension target
│   ├── PacketTunnelProvider.swift
│   ├── IP/                      # IPv4/IPv6 + TCP/UDP header parsing
│   ├── Flow/                    # 5-tuple flow table, TCP reassembly
│   ├── TLS/                     # local CA, leaf minting, opt-in TLS termination
│   ├── Relay/                   # outbound relay, UDP/non-inspected passthrough
│   ├── Capture/                 # streaming pcap writer
│   └── IPC/                     # ring-buffer producer + Darwin signal
├── Shared/                      # framework linked into both targets (App Group)
│   ├── Models/                  # FlowKey, FlowRecord, PacketMeta, ...
│   ├── Persistence/             # GRDB store, schema, migrations
│   └── IPC/                     # ring-buffer layout, Darwin notification names
└── TunnelVisionTests/           # parser, reassembly, pcap, and store unit tests
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the memory strategy, the userspace TCP path, the IPC ring-buffer layout, the `pcap` and SQLite schemas, and the full security model.

## Requirements

- **Xcode 16** or later, **Swift 6**, targeting **iOS 17+**.
- An **Apple Developer account**. Network Extension packet tunnels require the **Packet Tunnel Provider** capability, which needs a provisioning profile with the `com.apple.developer.networking.networkextension` entitlement — this is a paid-account capability and the extension **cannot** run in the iOS Simulator; it must be run on a real device.
- An **App Group** shared between the app and the extension for the SQLite store and ring buffer.
- [GRDB.swift](https://github.com/groue/GRDB.swift) via Swift Package Manager (the only third-party dependency; everything else is Apple-native: SwiftUI, NetworkExtension, Network, Swift Charts).

## Build and run

```bash
# Build the app + extension for a connected device (Simulator can't host the tunnel).
xcodebuild -scheme TunnelVision \
  -destination 'generic/platform=iOS' build

# Unit tests (parsers, reassembly, pcap writer, store) run on Simulator.
xcodebuild test -scheme TunnelVision \
  -destination 'platform=iOS Simulator,name=iPhone 16'

swiftlint --fix
```

On first launch the app guides the user through approving the Personal VPN profile. TLS inspection stays off until the user explicitly generates a CA and installs it.

## Usage

1. **Start capturing.** Open TunnelVision, tap *Start tunnel*, approve the VPN prompt. The dashboard begins showing live throughput and new flows immediately.
2. **Inspect a flow.** Tap any row in the timeline to open the flow inspector: 5-tuple, timing, byte counts, and — for inspected TLS or plaintext — the decoded request/response.
3. **Enable TLS inspection (optional).** Go to *Settings → TLS inspection*, generate the local root CA, then follow the in-app instructions to install it and enable full trust in **iOS Settings → General → VPN & Device Management** and **About → Certificate Trust Settings**. Only flows whose apps trust the CA become inspectable; pinned apps stay marked *not inspectable*.
4. **Export.** Share any capture as a standard `.pcap` file to open later in Wireshark or `tcpdump`, or export a flow list as JSON.

## Data formats

- **Captures:** standard libpcap (`.pcap`) with a global header and per-packet records, written as a stream so a long capture never has to fit in memory.
- **History:** SQLite tables for flows (5-tuple, timestamps, byte/packet counts, TLS-inspection status) and packet metadata, accessed through GRDB with schema migrations.
- **Live IPC:** a fixed-size ring buffer of packet-metadata records in a memory-mapped file in the App Group container; the extension is the single producer, the app the single consumer.

Exact struct layouts and the SQLite schema are documented in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#data-formats).

## Development

- **Language/tooling:** Swift 6, strict concurrency; `async/await` and actors for all I/O; no work on the main thread.
- **Tests:** header parsers, TCP reassembly, the `pcap` writer, and the persistence layer are unit-tested against fixture packet captures. Run them on Simulator with the `xcodebuild test` command above before every push.
- **Style:** SwiftLint; English identifiers; comments (in Spanish, per the author's convention) reserved for the *why*.

## Troubleshooting

- **The tunnel won't start / no VPN prompt.** Confirm the app and extension share the App Group and that the extension target has the Packet Tunnel Provider capability with a matching provisioning profile. Simulator cannot host the tunnel — use a real device.
- **HTTPS flows show as "not inspectable".** Either TLS inspection is off, the local CA isn't installed *and* fully trusted in iOS Settings, or the app pins its certificates. Pinning is expected and not bypassed by design.
- **Capture stops under heavy load.** That is back-pressure protecting the extension's memory budget: it drops metadata rather than growing buffers. Lower the capture detail level or enable UDP passthrough for streaming/VoIP flows.
- **History queries feel slow.** Ensure you're on a build with the flow-table indexes migrated in; very large histories should be pruned or exported and cleared from *Settings → Storage*.

## License

Released under the [MIT License](LICENSE). © 2026 juanmmm21.
