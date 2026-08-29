# 0003 — Never bypass third-party SSL pinning

- Status: Accepted
- Date: 2026-07-14

## Context

TunnelVision can decrypt HTTPS by presenting a leaf certificate signed by a user-installed local
CA. Apps that **pin** their certificates will reject that CA and their handshake against us
fails. There is a temptation (and the original product sketch floated it) to "bypass pinning
automatically" so those apps become inspectable too. Doing that would require defeating another
app's security control — hooking it, stripping its pinning, or otherwise subverting protections
its developers deliberately added.

## Decision

**We never bypass third-party SSL pinning.** When a client rejects our CA, we mark the flow
`notInspectable`, tear down the interception attempt, and **relay the flow untouched**. We do
not hook other processes, strip pinning, force trust, or retry to break it. This is a hard,
non-negotiable boundary. See [`../spec/relay-and-tls.md`](../spec/relay-and-tls.md).

## Consequences

- **Ethical/legal integrity:** the app inspects only what the device owner's own trust decision
  (installing the CA) permits, and respects other apps' security posture. This keeps TunnelVision
  in the same legitimate category as Charles/Proxyman/Wireshark.
- **Product honesty:** the UI turns the limitation into a trust signal — "this app pins its
  certificate; its content stays private." Users understand why some flows aren't readable.
- **App Store viability:** a tool that defeats other apps' security would be both unshippable and
  indefensible; respecting pinning keeps review and distribution plausible.
- **Scope guard:** any future task that asks to "make pinned apps inspectable" is out of scope
  and must be refused. Pinning working against us is the security system working as intended.

## Alternatives considered

- **Automatic pinning bypass:** rejected outright — it means attacking other software's
  protections; unethical, likely illegal to ship, and unshippable.
- **Silently dropping pinned flows:** rejected — breaks the user's connectivity; passthrough
  keeps those apps working while honestly labelling them.
