# 0005 — Userspace TCP termination for TLS inspection

- Status: Accepted
- Date: 2026-07-14

## Context

The extension receives **raw IP packets**, not sockets. To read or decrypt a TCP byte stream we
must present ourselves as the TCP peer to the client — i.e. complete the client's TCP handshake
and deliver an ordered byte stream up to a TLS layer. The kernel socket API won't do this for
traffic arriving as packets on the tunnel.

## Decision

For flows selected for inspection, run a **userspace TCP endpoint** inside the extension that
terminates the client connection (ordered stream via our `TCPReassembler`), then a TLS server
presenting a minted leaf, and finally a **separate real `NWConnection`** to the true server
under standard system trust. Non-inspected flows never enter this path — they are relayed at the
IP level. See [`../spec/relay-and-tls.md`](../spec/relay-and-tls.md) and
[`../spec/flow-and-reassembly.md`](../spec/flow-and-reassembly.md).

## Consequences

- **Capability:** we can decrypt the user's own HTTPS (when they've installed the CA) by holding
  plaintext between the two TLS legs.
- **Scope containment:** because it's expensive (memory, CPU), termination is opt-in and applies
  only to port-443 TCP flows we're allowed to inspect. Everything else stays cheap passthrough,
  protecting battery and the memory budget.
- **Complexity/risk:** a userspace TCP implementation must be careful and bounded (sequence
  arithmetic with wraparound, out-of-order handling, hard buffer caps → downgrade on overflow).
  This is the most delicate code in the project; it is heavily unit-tested.
- **Pinning respected:** if the client rejects our leaf, we abandon termination and passthrough
  ([0003](0003-no-third-party-pinning-bypass.md)).

## Alternatives considered

- **Kernel sockets:** not applicable — traffic arrives as packets on the tunnel, not as accepted
  connections.
- **Full third-party TCP/IP stack (e.g. lwIP/gVisor-style) vendored in:** a valid option and may
  be adopted for the termination core, but we keep our own bounded reassembler for the metadata
  path regardless; any vendored stack would need its own ADR and must respect the memory caps.
- **Reassemble-only, never terminate:** we still reassemble for plaintext decoding, but without
  termination we cannot present a cert to the client, so HTTPS inspection would be impossible.
