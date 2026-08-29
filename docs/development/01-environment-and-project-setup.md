# 01 — Environment and project setup

This page takes you from a fresh clone to a project that builds and runs the packet tunnel
on a device. The Xcode project is generated deterministically from
[`project.yml`](../../project.yml) with **XcodeGen**, so the `.xcodeproj` is never committed
and merge conflicts on it never happen.

## Toolchain

| Tool | Version | Notes |
|------|---------|-------|
| Xcode | 16 or later | Swift 6 toolchain, iOS 17 SDK |
| Swift | 6 | strict concurrency (`SWIFT_STRICT_CONCURRENCY = complete`) |
| iOS deployment target | 17.0 | first version we support |
| XcodeGen | 2.40+ | `brew install xcodegen` — generates the project from `project.yml` |
| SwiftLint | 0.55+ | `brew install swiftlint` — run before every commit |
| GRDB.swift | 6.x | SQLite layer, via Swift Package Manager (declared in `project.yml`) |

## Apple account and capabilities

The packet tunnel needs a **paid Apple Developer Program** membership. Two capabilities must
be present and provisioned:

1. **Network Extensions** — entitlement `com.apple.developer.networking.networkextension`
   with the `packet-tunnel-provider` value. Requires the Packet Tunnel Provider capability
   on the App ID.
2. **App Groups** — entitlement `com.apple.security.application-groups` with a shared group
   ID, used for the SQLite store and the mmap ring buffer.

> **Distribution note.** Shipping to the App Store almost certainly requires an **organization**
> Developer account (Review Guideline 5.4 governs VPN apps), plus the Packet Tunnel Provider
> entitlement granted for distribution. End users need none of this — they install from the
> App Store and approve the VPN. See [`../decisions/0001-networkextension-packet-tunnel.md`](../decisions/0001-networkextension-packet-tunnel.md).

### Canonical identifiers

Use these consistently across `project.yml`, entitlements, and code:

| Thing | Value |
|-------|-------|
| App bundle ID | `com.juanmmm21.tunnelvision` |
| Extension bundle ID | `com.juanmmm21.tunnelvision.PacketTunnel` |
| App Group ID | `group.com.juanmmm21.tunnelvision` |
| Keychain access group (CA private key) | `$(AppIdentifierPrefix)com.juanmmm21.tunnelvision` |

The App Group ID is the one string that must match in three places: both `.entitlements`
files and `Shared/IPC` + `Shared/Persistence` at runtime. It is centralised as a constant in
`Shared` (see [`../spec/ipc.md`](../spec/ipc.md)); never hardcode it in more than that one place.

## Generating and opening the project

```bash
# From the repo root:
xcodegen generate          # reads project.yml, writes TunnelVision.xcodeproj
open TunnelVision.xcodeproj
```

Set your Development Team on both targets (or export `DEVELOPMENT_TEAM` and let `project.yml`
pick it up). The `.xcodeproj` and `.xcworkspace` are git-ignored; regenerate any time.

**Run `xcodegen generate` first thing in every session, before building anything.** The project file
is not in git, so whatever is on disk may predate the last time files moved — and a project that has
not caught up with a move fails with `cannot find <symbol> in scope`, which reads exactly like a
regression in code that never changed. Regenerating is a second's work and rules that out.

## Building and running

```bash
# Unit tests — run on Simulator (no device, no paid account needed):
xcodebuild test -scheme TunnelVision \
  -destination 'platform=iOS Simulator,name=iPhone 16'

# Device build — the tunnel extension only works here:
xcodebuild -scheme TunnelVision -destination 'generic/platform=iOS' build

swiftlint --fix
```

**The test bundle runs inside the app** (`TEST_HOST` in `project.yml`), and that is load-bearing, not
cosmetic: a host-less bundle is loaded into the platform's `xctest`, which is signed by Apple, so every
`SecItemAdd` from a test returned `errSecMissingEntitlement` (-34018). Without the Keychain there is no
`SecIdentity`, and a `SecIdentity` is the only thing a TLS server can present in a handshake — so the
TLS termination work could not have been proven on the Simulator at all. The app is *not* linked; the
app sources under test still enter the bundle by source membership as they always did.

### Filling the Simulator with data (Debug only)

A Simulator launch is empty — the extension is the only writer of the history, the captures and the
live ring, and it does not run there — so the Timeline, its scrub bar, the Flow Inspector, the packet
screen and Captures have nothing to show. `-TVSeedFixture` writes a synthetic capture into the shared
container before the screens mount:

```bash
xcodebuild -scheme TunnelVision -destination 'platform=iOS Simulator,name=iPhone 17' build
xcrun simctl install booted <path>/TunnelVision.app
xcrun simctl launch --console-pty booted com.juanmmm21.tunnelvision -TVSeedFixture
```

In Xcode the same thing is *Edit Scheme → Run → Arguments → `-TVSeedFixture`*. It prints what it
wrote (~250 connections, ~7 400 packets, 3 capture files, ~6.5 MB, six hours of history, about a
second), it **replaces** rather than accumulates so it can be repeated, and the seed is fixed so two
runs are the same capture. The argument is ignored off the Simulator, and the code behind it does not
exist in Release. Details and the decisions in
[`../../Shared/Fixtures/README.md`](../../Shared/Fixtures/README.md).

The **live feed stays flat** even seeded: the ring has a single producer by contract and that
producer is the extension. Only hardware fills the Dashboard's chart.

### Looking at a screen without sitting in front of it

The accessibility pass needs two things a terminal does not obviously have: a way to *see* a screen
and a way to *drive* it. Both exist.

```bash
# Text size: standard sizes plus accessibility-medium … accessibility-extra-extra-extra-large (AX5).
xcrun simctl ui booted content_size accessibility-extra-extra-extra-large
xcrun simctl ui booted appearance dark

xcrun simctl io booted screenshot --type=png shot.png
```

`simctl` has no tap or swipe, so driving the app needs `idb`. Homebrew's formula only unpacks a
prebuilt tarball, and its install refuses to run until the Command Line Tools match the OS, so the
same artifact can be fetched directly (verify the checksum against the formula):

```bash
curl -L -o idb.tar.gz \
  https://github.com/facebook/idb/releases/download/v1.1.8/idb-companion.universal.tar.gz
tar xzf idb.tar.gz                       # bin/idb_companion + Frameworks/, runs in place
pipx install --python python3.12 fb-idb  # the client; 1.1.7 does not run on Python 3.13+

./bin/idb_companion --udid <UDID> --grpc-port 10882 &
idb connect localhost 10882
idb ui tap   --udid <UDID> <x> <y>              # points, not pixels: pixels ÷ scale
idb ui swipe --udid <UDID> --duration 0.4 <x1> <y1> <x2> <y2>
```

The companion has been seen to die mid-session; restarting it and re-running `idb connect` is
enough, and nothing on the device is lost. Coordinates are in points, so a 1206×2622 screenshot of
an iPhone 17 divides by 3.

Two things that cost time the first time round. Unpack the tarball somewhere that survives a reboot
(`~/.local/share/idb-companion/` is where it currently lives) — `/tmp` is emptied and the download
has to be repeated. And `idb list-targets` **fails** with `No such file or directory:
/usr/local/bin/idb_companion`: that subcommand spawns its own local companion instead of using the
connection. It is not a broken setup — `idb connect` and `idb ui …` work over the port regardless,
so use the UDID you already know rather than trying to list it.

### Hearing a screen without ears

The third thing the accessibility pass needs is a way to know **what VoiceOver would say**, and it
does not require listening to anything: `idb` reads the same accessibility tree VoiceOver does.

```bash
idb ui describe-all   --udid <UDID>              # every element, in traversal order
idb ui describe-point --udid <UDID> <x> <y>      # one element, by where it sits
```

Each element arrives with the whole contract: `AXLabel` (what is read), `AXValue` (what changes as
the element is operated), `help` (the hint), `custom_actions` (the rotor), `type` and `frame`. That
answers most of what a listening pass is for — whether the phrases read well **in sequence**, whether
an element that should be one element is one, whether off-screen content stays out of the way, and
whether a control's actions appear only in the states that should offer them.

Three limits, all of them found the hard way, and none of them a bug in the app:

- **`describe-all` does not recurse into every container.** The tab bar arrives as a bare
  `Tab Bar` group with no children, which reads like the tabs are unreachable by VoiceOver. They are
  not: `describe-point` on each one returns a `RadioButton` with its label and its selected state.
  Probe by point before believing an absence.
- **Traits are not reported.** An element made adjustable by `accessibilityAdjustableAction` comes
  back as `StaticText` or `Button`, so the *presence* of the adjustable trait cannot be asserted this
  way — only its hint and its actions can.
- **A `NaN` in any frame kills the companion**, with `Invalid number value (NaN) in JSON write` in
  its log and `Connection lost` on the client. Restarting the companion and probing point by point
  isolates which element carries it. That is worth knowing as a *finding* rather than a nuisance: a
  frame that is not a number is an element VoiceOver cannot order, focus or reach by touch
  exploration, and it is exactly how the intro card's traversal was found to be unreachable
  (`.accessibilityElement(children: .combine)` applied to a `ScrollView` rather than to its content).

### Photographing the whole product

The showcase pictures are not taken by hand: `Tools/Screenshots/capture.py` drives the app through
the ten screens and writes them into [`../screenshots/`](../screenshots/) in both appearances.

```bash
python3 Tools/Screenshots/capture.py \
  --app <derivedData>/Build/Products/Debug-iphonesimulator/TunnelVision.app --udid <UDID>
```

Four things it had to learn, and they apply to **any** session driving this app from the terminal:

- **Uninstalling is the only thing that returns the settings to factory** — the seeder does not touch
  them — and the intro only appears on a first launch, so each pass starts from a clean install.
- **The keychain survives uninstalling the app.** A CA created by an earlier session is still there,
  so the certificate flow opens at whatever stage that session left it in.
- **The Timeline's search field lives in the navigation bar's drawer**: it is only mounted with the
  list at its top, and it does not filter until the text is submitted with Return (HID keycode 40 via
  `idb ui key`). iOS capitalises the first letter; the search does not care.
- **A screen with a pinned action bar does not scroll if the drag starts on top of it** — the bar
  takes the gesture and nothing moves, which looks exactly like an element that is not there.

And one thing no Simulator can do: **the Dashboard cannot be photographed**. The very first
`saveToPreferences` is denied here, so its monitoring control falls to *Permission needed* and never
offers anything else — that screen needs a device.

### Measuring a screen without a device

Time Profiler runs against the Simulator from the terminal, which is what makes a before/after
comparison of a draw path possible without hardware. Three things about it are not obvious and cost
an afternoon each:

```bash
# 1. Record. --all-processes on the HOST, not --device <simulator udid>.
xcrun xctrace record --template 'Time Profiler' --all-processes \
  --time-limit 32s --no-prompt --output run.trace

# 2. Export the samples as XML.
xcrun xctrace export --input run.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > run.xml
```

- **`--device <simulator udid> --attach <pid>` hangs.** It prints `Starting recording…` and never
  reaches `Ctrl-C to stop the recording`; neither the time limit nor `SIGINT` gets it out. Recording
  the **host** with `--all-processes` works, and it does see the Simulator's processes — they are
  ordinary host processes. Attaching to the app's pid *without* `--device` does not work either
  (`Cannot find process for provided pid`), so `--all-processes` plus filtering by process name at
  analysis time is the way through. The cost is a ~75 MB export for 32 s and a lot of stderr noise
  about overlapping dylibs, which is harmless.
- **A silent, idle app produces zero samples**, because Time Profiler only samples running threads.
  Zero samples means nobody was driving the app, not that it was cheap — drive it with `idb`
  (above) while the recording runs.
- **The export's shape is easy to parse wrong and get a confident zero.** It uses id/ref tables, and
  the *first* appearance of a process is nested inside its `<thread>` while the row's own
  `<process>` is a `ref` to it — so ids have to be registered from anywhere in the row, not just
  from direct children. The stack hangs off `<tagged-backtrace>/<backtrace>`, not off a
  `<backtrace>` child. Frames carry their module in a `<binary>` child element, **not** in an
  attribute, and their names arrive demangled and without a module prefix (`FlowRow.body.getter`).
  Finally, a symbol and its `specialized` twin are separate frames in the same stack, so summing
  them per symbol double-counts: to attribute a subtree, count each sample **once** if any frame in
  it matches.

What the numbers are worth: the Simulator runs on the Mac's cores, so absolute times mean nothing
about a phone. What survives the change of machine is the **attribution** — which symbols are on the
stack during the gesture, and whether one of them stopped being there. Total CPU for a driven
gesture drifts ±10 % between runs on an otherwise-idle machine, so it cannot settle anything smaller
than that; seed the same fixture and drive the same `idb` gesture in both measurements, which is what
makes the two comparable at all.

## The string catalog

The app's copy is extracted from `String(localized:)` calls (and from SwiftUI's own literal
`Text("…")`) into `TunnelVision/Resources/Localizable.xcstrings`. Xcode does that merge every
time it builds the app **from the IDE**; `xcodebuild` on the command line writes the extracted
data but does not merge it, so a terminal-only session has to run the merge itself:

```bash
# 1. Build the app target — this writes one .stringsdata per source file.
xcodebuild -scheme TunnelVision -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath .build/xcode build

# 2. Merge them into the catalog (`.build/` is git-ignored; the catalog is not).
find .build/xcode/Build/Intermediates.noindex -name '*.stringsdata' \
     -path '*/TunnelVision.build/Objects-normal/*' \
     ! -name 'ExtractedAppShortcutsMetadata.stringsdata' \
     -exec xcrun xcstringstool sync TunnelVision/Resources/Localizable.xcstrings --stringsdata {} +
```

Only the app target has a catalog. `Shared` and `PacketTunnel` have no user-facing copy, and
the unit-test bundle deliberately has none: it compiles `TunnelVision/Models` by source
membership, so every lookup there falls back to the `defaultValue` written in the Swift, which
is what the tests assert. How to write copy so it ends up here at all:
[`02-coding-standards.md`](02-coding-standards.md).

The test scheme also pins the **locale** of that bundle (`schemes.TunnelVision.test.language`
and `region` in `project.yml` → `en`/`US`). Falling back to a `defaultValue` is
language-independent, but the numbers interpolated into it are not, so without the pin every
assertion about a figure asserted the language of whoever ran it. Change it in `project.yml` and
`xcodegen generate`, never in Xcode's scheme editor: the `.xcodeproj` is regenerated and the
edit would vanish. `CopyLocaleTests` fails, with the fix in its message, if the pin goes missing.

## The Info.plist keys that make the extension an extension

The `PacketTunnel` target's `Info.plist` must declare the extension point and principal
class (XcodeGen writes these from `project.yml`, listed here so you can verify):

```xml
<key>NSExtension</key>
<dict>
  <key>NSExtensionPointIdentifier</key>
  <string>com.apple.networkextension.packet-tunnel</string>
  <key>NSExtensionPrincipalClass</key>
  <string>$(PRODUCT_MODULE_NAME).PacketTunnelProvider</string>
</dict>
```

## What runs where (and why it matters for how you build)

| Concern | App target | Extension target | Testable on Simulator? |
|---------|:---------:|:----------------:|:----------------------:|
| SwiftUI UI, tunnel control (`NETunnelProviderManager`) | ✅ | | ✅ (UI/logic; not the real tunnel) |
| Packet capture / reinjection (`packetFlow`) | | ✅ | ❌ device only |
| IP/TCP/UDP parsing | | ✅ (lives in `Shared`/extension) | ✅ pure functions |
| Flow table + TCP reassembly | | ✅ | ✅ pure logic |
| pcap writer | ✅ seeding only | ✅ | ✅ writes to a temp file |
| GRDB store | ✅ read | ✅ write | ✅ in-memory / temp DB |
| mmap ring buffer | ✅ consume | ✅ produce | ✅ backed by a temp file |
| TLS termination / CA | | ✅ | ✅ mostly (minting, **and the live server handshake** against a real client over loopback; only the extension sandbox needs a device) |

**Design implication:** keep the device-only surface (the `packetFlow` read/write loop and
live `NWConnection` relay) as thin adapters, and put all parsing, reassembly, persistence,
and IPC in pure, injected components so they can be exercised without hardware. This is the
main reason the module boundaries in [`../spec/`](../spec/) look the way they do.

## First-run sanity checklist

- [x] `xcodegen generate` succeeds and the project opens (XcodeGen 2.46, Xcode 26.6).
- [ ] Both targets have your Development Team and matching provisioning profiles.
- [ ] App Group ID matches in both `.entitlements` files.
- [x] Unit test scheme runs green on Simulator (`iPhone 17`).
- [ ] On a device: launching the app can install and start the VPN profile (the OS prompt
      appears), and the extension's `startTunnel` logs a line.
