# Contributing

TunnelVision is published as source because it cannot be published on the App Store
([why](docs/APP-STORE.md)). Issues and pull requests are welcome, with a few things worth
knowing before you spend time on a change.

## The one rule that overrides everything

TunnelVision analyses **only the device owner's own traffic, with explicit consent**, and
**never** attempts to defeat another app's security controls. No third-party certificate-pinning
bypass, no packet injection, no content rewriting. When a pinned connection fails to handshake
against the local CA, that is the app working correctly: it is passed through untouched and
labelled *not inspectable*.

This is not a placeholder position that a sufficiently clever patch can revisit. It shapes the
architecture — see
[`docs/decisions/0003-no-third-party-pinning-bypass.md`](docs/decisions/0003-no-third-party-pinning-bypass.md)
— and a change that erodes it will be declined regardless of how well it is written.

## Before you open a pull request

- **Read the spec for the module you are touching.** [`docs/spec/`](docs/spec/) describes each
  module with concrete Swift interfaces, and [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
  explains how the pieces fit. Most surprises in this codebase are deliberate and written down.
- **Run the tests.** `xcodebuild test -scheme TunnelVision -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:TunnelVisionTests`.
  All 1710 must pass. Do not add `CODE_SIGNING_ALLOWED=NO` — see
  [`docs/BUILDING.md`](docs/BUILDING.md#running-the-tests) for why it silently breaks the TLS tests.
- **Run `xcodegen generate` first.** The `.xcodeproj` is not committed. A stale one fails with
  `cannot find <symbol> in scope`, which looks like a code regression and is not one.
- **Anything with non-trivial logic comes with tests.** The parsers, the reassembler, the pcap
  writer, the ring buffer and the presentation types are all pure and tested; keep it that way.

## House style

- **Swift 6 with strict concurrency** (`SWIFT_STRICT_CONCURRENCY = complete`). No opting out.
- **Explicit error handling.** No empty `catch {}`, no `try?` on a path where the failure matters.
  Errors are typed per domain.
- **No placeholders.** Nothing lands half-finished with a `TODO` standing in for the rest.
- **Comments explain *why*, not *what*.** The codebase comments decisions, workarounds and API
  limits — the things the code cannot say for itself. Comments are in Spanish; identifiers, and
  everything user-facing, are in English.
- **Views hold no logic.** Networking and persistence live in services and view models; SwiftUI
  views render.

Full details in [`docs/development/02-coding-standards.md`](docs/development/02-coding-standards.md)
and [`docs/development/04-testing-strategy.md`](docs/development/04-testing-strategy.md).

## What is unlikely to be merged

- Anything that circumvents another app's security, as above.
- Anything that sends data off the device. There is no server, and adding one changes what this
  app fundamentally is.
- iPad layouts, unless you have actually run them on an iPad. The app is iPhone-only on purpose:
  every screen was measured at one width, and shipping a layout nobody has looked at is worse
  than not shipping one.
