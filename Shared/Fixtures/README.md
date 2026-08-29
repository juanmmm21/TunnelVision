# Shared/Fixtures

**Debug-only.** A deterministic generator of a synthetic capture: flows, their packets, and real IP
datagrams (`Shared/IP` emits them, the parser next door reads them back).

It exists because the packet tunnel extension only runs on a device, and it is the only writer of
the history database, the pcap directory and the live ring. On the Simulator the app therefore has
nothing to show — no Timeline rows, no scrub bar, no reachable Flow Inspector or packet screen, no
captures — which is exactly the set of dense screens that M11's remaining work needs someone to look
at, listen to and profile.

The whole file is behind `#if DEBUG`, and not as a convenience: once written into the shared
container, a synthetic capture is indistinguishable from a real one — the history does not record
where a row came from — so the only guarantee that a user never sees invented traffic is that this
code is absent from Release.

Two properties everything else rests on:

- **Reproducible.** Same seed, same bytes. A before/after with Instruments has to measure the same
  work, and a showcase screenshot has to be repeatable — hence a seeded generator of our own, since
  `SystemRandomNumberGenerator` is not reproducible.
- **Covering by construction, not by luck.** The catalogue of scripted flows is written by hand so
  that each screen state that exists is reachable: the four inspection states, the five protocols,
  both address families, a flow with no SNI, a hostname that will not fit a line, a connection cut
  by a reset, packets whose bytes were never written, and one flow above the Flow Inspector's packet
  limit. Bulk flows on top of that only make the list long enough to paginate.

Addresses and hostnames are documentation-reserved (RFC 5737, RFC 3849, RFC 2606) because these
captures end up in the public repo's screenshots.

**Most payloads are reproducible noise, and one flow's are not.** Nobody looks inside a segment of a
synthetic download, so filling it with the seeded generator is right. The port-53 flow is the
exception since roadmap step 10: a dissector reads those datagrams and the packet screen shows what
they say, so `FixtureLookups` writes **real DNS messages** with `DNSMessageFixture` — four
query→reply pairs, one for each reading a reply can have (addresses, a name, records that are not
broken down, and a name that does not exist), by hand for the same reason the flow catalogue is by
hand: a state that depends on the seed cannot be asserted in a test or promised in a screenshot.

## Writing it down

`CaptureFixture.make(spec)` produces the capture without touching disk; `FixtureSeeder` is what puts
it where the app reads — the history database (`FlowStore`) and the capture directory (`PcapWriter`).
Four decisions live there:

- **The store is opened with the fixture's own anchor.** The packet stamps are monotonic and mean
  nothing without it; with `.now()` the whole history would land six hours in the future.
- **It writes through the real `PcapWriter`**, which is why that writer moved to
  [`../Capture`](../Capture). Composing the records here with `PcapFormat` would duplicate the one
  rule the file+offset pair exists to protect, and a capture whose offsets were computed separately
  would validate itself while the packet screen read another connection's bytes.
- **Records go in the order the packets happened, across flows**, because a capture is one file per
  device and not one per connection. Written flow by flow, each connection would be ordered and the
  file as a whole would run backwards.
- **Rotation is by file count, not by a byte cap**, so the Captures screen has more than one row —
  its interesting state — whatever the spec's size. Each file is then renamed and stamped with the
  wall-clock time of its first record: the screen reads that date from the filesystem, so leaving
  them all at "now" would show six hours of history in files claiming to have opened a second ago.

Seeding **replaces** rather than accumulating. Two runs leave one capture, which is what makes the
launch argument repeatable and — the part that matters — what keeps two Instruments runs on the same
seed measuring the same work.

## Using it

The seeder is driven from the app by a launch argument, `-TVSeedFixture` (`FixtureSeeding` in
[`../../TunnelVision/Services`](../../TunnelVision/Services)), handled at startup by a gate that
holds the screens back until the writing is done:

```bash
xcrun simctl launch --console-pty <device> com.juanmmm21.tunnelvision -TVSeedFixture
```

or *Edit Scheme → Run → Arguments* in Xcode. It prints what it wrote when it finishes. The argument
is honoured **only on the Simulator**: on a device the extension is the writer, and seeding would
replace its owner's real capture with invented traffic.

The **live feed stays flat** either way: the ring is an SPSC channel whose single producer is the
extension, and faking it from the app would mean writing from the producer end of a contract that
says there is only one. What fills up is the history.

## The one screen the container could not reach

The same launch argument also seeds **`TunnelStatsFixture`** (2026-08-21), and it does *not* go
through the container: *Session diagnostics* reads its counters off the **control channel**, so a
seeded app still showed nothing but its "nothing to diagnose yet" card and six hundred points of
empty canvas. It was the only screen in the app a Simulator session could not look at, and therefore
the only one whose density and hierarchy had to be judged blind — which is exactly what the second
design pass could not do. `AppEnvironment` builds the diagnostics view model over a seeded channel
when the argument is present; the view model learns one thing from it, that the tunnel's state (never
`.live` on a Simulator) must not tear the screen down.

Its numbers are hand-written constants rather than a generator, and that is what makes them useful:
each has to be believable **and** consistent with the others — decrypted, pinned and failed add up to
the terminations opened, and those plus the abandons and the skips add up to the candidates — because
a table whose figures do not agree with each other is no good for judging how they read. It portrays
a session that works, and what is imperfect in it is not invented either: hosts that refuse the
certificate (ADR 0003), flows with no name because they speak QUIC, and one capture failure, which is
the case the screen's error section exists for.

**Milestone:** M11
