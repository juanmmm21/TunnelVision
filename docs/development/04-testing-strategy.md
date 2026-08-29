# 04 — Testing strategy

The design goal is that **almost everything is testable on the Simulator**, and only the two
device-only surfaces (the `packetFlow` read/write loop and the live TLS handshake against a
real server) require hardware. Structure code so the untestable part is a thin adapter over
tested logic.

## The pyramid

```
     device smoke tests   (M7/M8, manual + minimal automated, on hardware)
   ────────────────────────────────────────────────────────
     integration tests    (store + IPC + parser wired together, Simulator)
   ────────────────────────────────────────────────────────
     unit tests           (parsers, reassembly, pcap, models, store — Simulator)
```

## What each layer covers

### Unit tests (the bulk)
- **Parsers** — golden-file tests: feed bytes from `.pcap` fixtures, assert the extracted
  `FlowKey`, protocol, ports, flags. Include malformed/truncated inputs that must be rejected
  with a typed error, and a fuzz loop that must never crash.
- **Reassembly** — synthetic segment sequences: in-order, out-of-order, duplicate/retransmit,
  gaps, and window overflow (must downgrade to metadata, not grow).
- **pcap writer** — write known packets, then read the file back with a minimal reader (and,
  in CI, open with `tcpdump -r` if available) to confirm byte-exact framing and `LINKTYPE_RAW`.
- **Models** — `Equatable`/`Hashable` laws, `Codable` round-trips, `FlowKey` canonicalization.
- **Store (GRDB)** — run against an in-memory or temp-file DB: migrations apply, insert/query
  work, pruning respects retention, indexes exist.
- **IPC ring buffer** — back the mmap with a temp file; single-producer/single-consumer
  round-trip, overflow drop counting, no torn records under a stress loop.

### Integration tests
- Parser → flow table → store: replay a fixture capture end-to-end and assert the resulting
  flow rows and counters.
- Extension IPC → app reader: producer writes N records, consumer drains exactly N minus drops.

### Looking at the app on the Simulator (M11)
Unit tests are not the only thing that has to run without hardware — Dynamic Type, VoiceOver and
Instruments all need a person driving a *populated* app. And a Simulator launch is empty: the
extension is the only writer of the history database, the capture directory and the live ring, and
it does not run there. So the screens worth looking at (Timeline and its scrub bar, Flow Inspector,
the packet screen, Captures, the Dashboard's history) do not exist until something puts data in the
shared container.

`Shared/Fixtures` does that — a Debug-only, seed-deterministic synthetic capture, scripted to cover
every screen state rather than sampled — and `FixtureSeeder` writes it into the shared container.
Launch the app with `-TVSeedFixture` (Xcode scheme arguments, or
`xcrun simctl launch --console-pty <device> com.juanmmm21.tunnelvision -TVSeedFixture`) and it prints
what it wrote. Seeding replaces rather than accumulates, so it can be repeated, and the fixed seed is
what makes a before/after with Instruments measure the same work. See
[`../../Shared/Fixtures/README.md`](../../Shared/Fixtures/README.md).

The **live feed stays flat** regardless: the ring is an SPSC channel whose single producer is the
extension, and faking it from the app would mean writing from the producer end of a contract that
says there is only one. That half waits for hardware.

### Device smoke tests (M7/M8)
Cannot run on Simulator. Documented, semi-automated:
- Start the tunnel, generate known traffic (`curl` a known host from Safari), confirm the flow
  appears with correct 5-tuple and byte counts.
- With the CA installed, confirm the app's own HTTPS is decoded; confirm a pinned third-party
  app stays `notInspectable`.
- Sustained-load memory check: run a 30-minute capture, confirm the extension is not killed and
  memory stays within budget.

## Fixtures

Store captured packet fixtures under `TunnelVisionTests/Fixtures/` as small `.pcap` files, one
concern per file (e.g. `ipv4-tcp-syn.pcap`, `ipv6-udp.pcap`, `tcp-out-of-order.pcap`). Generate
them with `tcpdump`/Wireshark and keep them tiny. Never commit real personal traffic —
synthesize or scrub fixtures.

## Determinism and time

- No wall-clock or randomness on a tested path without injection. Timestamps come from an
  injected clock; the ring buffer and store take the clock as a dependency so tests are
  deterministic.
- Tests must not touch the network or the real App Group container; use temp directories.
- **The process locale is an injected input too, and it is pinned to `en`/`US` in the scheme.**
  The copy tests assert the exact English the app shows, and a number interpolated into
  `String(localized:)` is formatted with the process locale — unpinned, an assertion about a
  figure said whatever the machine running it happened to say, which is how `port 8,080` survived
  three screens with two tests watching it. `CopyLocaleTests` asserts the pin is still in place,
  because a lost pin breaks nothing: it only empties the assertions that depend on it. The
  reasoning, including why `en_US_POSIX` would be the wrong pin, is in
  [`02-coding-standards.md`](02-coding-standards.md).

## Performance and memory as tests

- A `measure {}` benchmark for the parser hot path (target: parse well above line rate for
  typical Wi-Fi throughput).
- A bounded-memory assertion for a 10k-flow storm and a long capture (peak resident stays under
  the extension budget). Treat a regression here as a failing test, not a nice-to-have.

## Running

```bash
xcodebuild test -scheme TunnelVision \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

Run them through the scheme, which is what carries the pinned locale. `-testLanguage`/
`-testRegion` override it, and `CopyLocaleTests` will say so rather than let the run look clean.

Tests are green before every push — this is enforced by the coding standards and CI.
