# Building and running TunnelVision

TunnelVision is not on the App Store ([why](APP-STORE.md)), so running it means building it.
This page takes you from a clone to the app capturing traffic on your own iPhone.

Be aware of the real cost up front: **the packet tunnel requires a paid Apple Developer Program
membership** ($99/year). This is not our choice. The `com.apple.developer.networking.networkextension`
entitlement cannot be provisioned by a free personal team, so a free Apple ID can build and run the
unit tests but cannot run the tunnel on a device. If you only want to read the code or run the test
suite, skip to [Running the tests](#running-the-tests) — that part needs nothing but Xcode.

## What you need

| | |
|---|---|
| macOS with **Xcode 16 or later** | Swift 6 toolchain |
| **An iPhone running iOS 17+** | The tunnel extension does not run in the Simulator |
| **A paid Apple Developer Program account** | Required for the Network Extension entitlement |
| **XcodeGen** | `brew install xcodegen` — the `.xcodeproj` is generated, not committed |

## 1. Set your own identifiers

The bundle identifiers in this repository are registered to the original author's Apple
Developer account. **They will not provision under yours.** Before anything else, replace the
`com.juanmmm21` prefix with your own reverse-DNS prefix.

A script does the whole substitution:

```bash
Tools/set-bundle-prefix.sh com.yourname
```

It rewrites every occurrence outside `docs/` — thirteen files — and prints each one. These are the
six that decide whether the app builds and runs at all, and they must all agree:

| File | What it holds |
|---|---|
| `project.yml` | `bundleIdPrefix` and the bundle ID of each of the four targets |
| `TunnelVision/TunnelVision.entitlements` | App Group and Keychain access group |
| `PacketTunnel/PacketTunnel.entitlements` | The same two, and they must match the app's |
| `Shared/IPC/AppGroup.swift` | The App Group ID read at runtime |
| `TunnelVision/Services/TunnelConfiguration.swift` | The extension's bundle ID, used to find the provider |
| `TunnelVisionTests/Services/TunnelStatePolicyTests.swift` | A test asserting that identifier literally |

The App Group ID is the string that has to match in the most places — both entitlements files and
`AppGroup.swift`. If the app and the extension disagree about it, they get *different* containers,
and the symptom is not an error: the UI simply stays empty forever while the tunnel happily records
into a container nobody reads.

## 2. Register the capabilities

In the [Apple Developer portal](https://developer.apple.com/account/resources/identifiers/list),
create the App IDs and enable the capabilities:

1. **App ID for the app** (`com.yourname.tunnelvision`) with **Network Extensions** and **App Groups**.
2. **App ID for the extension** (`com.yourname.tunnelvision.PacketTunnel`) with the same two.
3. **An App Group** (`group.com.yourname.tunnelvision`), assigned to both App IDs.

Xcode's automatic signing will create the provisioning profiles once the App IDs exist with the
right capabilities. If a build fails complaining that a profile "doesn't include the
com.apple.developer.networking.networkextension entitlement", it means the capability is not
enabled on the App ID — fix it in the portal, then let Xcode refresh.

## 3. Generate the project and build

```bash
export DEVELOPMENT_TEAM=YOURTEAMID      # Membership details in the developer portal
xcodegen generate
open TunnelVision.xcodeproj
```

Select your iPhone as the destination and run. The `.xcodeproj` is deliberately not committed —
it is generated from `project.yml` — so **run `xcodegen generate` again after pulling changes**
that move or add files. A stale project fails with `cannot find <symbol> in scope`, which reads
exactly like a compile error in code that never changed.

On first launch the app explains what it does and asks to install a VPN configuration. That is
iOS's standard Personal VPN prompt; the tunnel terminates on the device.

## 4. Optional: HTTPS inspection

Inspecting your own encrypted traffic is off by default and takes a deliberate step: in
*Settings → set up secure traffic inspection*, the app generates a local CA, hands you a profile,
and walks you through installing it and enabling full trust in **Settings → General → VPN & Device
Management** and then **Certificate Trust Settings**. The app tells you in advance which warnings
iOS will show, and the whole thing is reversible from the same screen.

Apps that pin their certificates will not be inspectable, and TunnelVision does not try to make
them so — it passes them through untouched and labels them. That is a deliberate limit, not a bug.

## Running the tests

The unit tests run on the Simulator and need no device and no paid account:

```bash
xcodegen generate
xcodebuild test -scheme TunnelVision \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:TunnelVisionTests
```

1710 tests currently pass. Two things about this command are load-bearing:

- **Do not add `CODE_SIGNING_ALLOWED=NO`.** It looks harmless for a Simulator run, and it makes the
  TLS session tests fail. The test bundle runs *inside the app* (`TEST_HOST` in `project.yml`) so
  that tests inherit its Keychain entitlements; disabling signing takes those away, `SecItemAdd`
  returns `errSecMissingEntitlement` (-34018), and without the Keychain there is no `SecIdentity`
  for a TLS server to present.
- **`-only-testing:TunnelVisionTests`** keeps the run to the unit tests. The packet tunnel provider
  itself is device-only and is excluded from the bundle on purpose; it is validated by compiling.

### Filling the Simulator with data

A Simulator launch is empty, because the extension — the only writer of history, captures, and the
live ring buffer — does not run there. Launch with `-TVSeedFixture` to write a synthetic capture
into the shared container so the timeline, the flow inspector, and the packet screen have something
to show:

```bash
xcrun simctl launch --console booted com.yourname.tunnelvision -TVSeedFixture
```

## Where things are

| Path | What lives there |
|---|---|
| `TunnelVision/` | The SwiftUI app: views, view models, services |
| `PacketTunnel/` | The `NEPacketTunnelProvider` extension: flow table, TCP reassembly, TLS termination, relay |
| `Shared/` | Framework linked by both: models, persistence (GRDB), IPC ring buffer, pcap, IP parsing, TLS primitives |
| `CTVAtomics/`, `CTVResolv/` | Small C shims — C11 atomics for the ring buffer, `<resolv.h>` for the system's DNS servers. Both exist because Swift cannot reach those APIs on iOS |
| `TunnelVisionTests/` | The unit tests |
| `Tools/` | The screenshot driver and the app icon renderer |
| `docs/` | Architecture, module specs, UX specs, and the decision records |

Start with [`ARCHITECTURE.md`](ARCHITECTURE.md) for how the pieces fit, and
[`decisions/`](decisions/) for why they are the way they are.
