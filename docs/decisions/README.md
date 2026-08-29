# Architecture Decision Records

Each ADR captures one decision: its context, the choice, and the consequences. They are
immutable once accepted — to change a decision, add a new ADR that supersedes the old one
(note it in both).

## Index

| # | Decision | Status |
|---|----------|--------|
| [0001](0001-networkextension-packet-tunnel.md) | Use `NEPacketTunnelProvider` (NetworkExtension) for on-device capture | Accepted |
| [0002](0002-grdb-over-swiftdata.md) | Use GRDB/SQLite for history instead of SwiftData/Core Data | Accepted |
| [0003](0003-no-third-party-pinning-bypass.md) | Never bypass third-party SSL pinning | Accepted |
| [0004](0004-ipc-mmap-ringbuffer-plus-darwin.md) | Live IPC via mmap ring buffer + Darwin signal | Accepted |
| [0005](0005-userspace-tcp-for-inspection.md) | Userspace TCP termination for TLS inspection | Accepted |
| [0006](0006-udp-quic-passthrough.md) | Pass UDP/QUIC through without termination | Accepted |
| [0007](0007-decrypted-content-retention.md) | Decrypted content: its own switch, its own shorter retention, its own deletion | Accepted |

## Template

```markdown
# NNNN — Title

- Status: Proposed | Accepted | Superseded by NNNN
- Date: YYYY-MM-DD

## Context
What forces are at play; what problem needs deciding.

## Decision
The choice, stated plainly.

## Consequences
What becomes easier, what becomes harder, what we accept.

## Alternatives considered
Each option and why it lost.
```
