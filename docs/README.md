# TunnelVision — Documentation

Everything here describes how TunnelVision is designed and built. It was written for the people
building it, and it is published unchanged rather than rewritten into a brochure.

## Start here

| Document | What it covers |
|---|---|
| [`APP-STORE.md`](APP-STORE.md) | Why TunnelVision is not on the App Store, and what that does and does not say about it |
| [`BUILDING.md`](BUILDING.md) | From a clone to the app capturing traffic on your own iPhone |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Process model, data flow, memory strategy, IPC, security model |

## Reference

| Area | Path | What it covers |
|---|---|---|
| Project setup | [`development/01-environment-and-project-setup.md`](development/01-environment-and-project-setup.md) | Targets, entitlements, App Group, identifiers, XcodeGen |
| Coding standards | [`development/02-coding-standards.md`](development/02-coding-standards.md) | Swift 6 concurrency, error handling, naming |
| Testing | [`development/04-testing-strategy.md`](development/04-testing-strategy.md) | Test pyramid, fixtures, Simulator vs device |
| Glossary | [`development/05-glossary.md`](development/05-glossary.md) | Domain vocabulary |
| Module specs | [`spec/`](spec/) | Each module with its concrete Swift interfaces |
| UX specs | [`ux/`](ux/) | Screens, onboarding, consent, design system |
| Decisions | [`decisions/`](decisions/) | Architecture Decision Records — why the load-bearing choices were made |

## The one rule that overrides everything

TunnelVision analyses **only the device owner's own traffic, with explicit consent**, and **never**
attempts to defeat another app's security controls (no third-party SSL-pinning bypass). This
constraint shapes the whole design; see
[`decisions/0003-no-third-party-pinning-bypass.md`](decisions/0003-no-third-party-pinning-bypass.md).
Any change that erodes it is out of scope — see [`../CONTRIBUTING.md`](../CONTRIBUTING.md).

## How to read it

If you are here to change something, open the [`spec/`](spec/) document for the module first. The
specs carry the actual interfaces and, more usefully, the reasoning: most of what looks surprising
in this codebase is deliberate and explained in one of these files.
