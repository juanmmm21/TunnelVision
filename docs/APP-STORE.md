# Why TunnelVision is not on the App Store

TunnelVision was built to be shipped. It was finished, submitted, and reviewed. It is not on
the App Store, and it is not going to be — for a reason that has nothing to do with the app
itself. This page explains exactly what happened, so you can judge the software on its merits
rather than on its absence from the store.

## What happened

Version 1.0 was submitted to App Review and reviewed on **28 August 2026** on an iPhone 17 Pro
Max. It was rejected under **App Store Review Guideline 5.4 — Legal: VPN Apps**. Apple's
finding, in full:

> Your VPN app was submitted by an Apple Developer Program account registered to an individual.
>
> All VPN apps must be submitted from an Apple Developer Program account registered to a company
> or organization.

That is the entire objection. There was no finding about privacy, data handling, functionality,
crashes, design, metadata, or the app's behaviour on device. The rejection is about **who holds
the developer account**, not about what the software does.

## Why the rule catches TunnelVision

Guideline 5.4 governs "VPN apps". In practice Apple applies it to any app that ships a
**`NEPacketTunnelProvider`** — the NetworkExtension class that receives the device's raw IP
packets. TunnelVision ships one, because on iOS that class is the *only* supported way for an
app to see the traffic leaving the device. There is no alternative API. Capturing packets on
an unmodified iPhone means being, in Apple's classification, a VPN app.

This is worth stating plainly, because TunnelVision is not a VPN in the sense the guideline was
written for. It sells no VPN service, has no subscription, and operates no infrastructure:

- The tunnel **terminates on the device itself**. Packets are read and relayed straight back out
  to the internet from the same phone.
- There is **no server** anywhere in the design. Nothing is uploaded, because there is nowhere
  to upload it to.
- It collects nothing about the user and shares nothing with anyone.

Guideline 5.4 exists to make VPN operators accountable — a VPN carries other people's traffic to
a company's servers, and Apple wants a legal entity behind that. It is a reasonable rule for the
apps it was written for. TunnelVision carries traffic exactly nowhere, and still falls inside the
category, because the category is defined by the API rather than by where the traffic goes.

## Why it was not simply fixed

Two obvious remedies do not apply.

**Transferring the app to an organization account.** Apple's rejection notice suggests app
transfer. App transfer requires the app to have had at least one version released on the App
Store. TunnelVision never shipped, so there is nothing to transfer. That route is closed by the
same rejection that recommends it.

**Re-registering as an organization.** Converting an Apple Developer Program membership from
individual to organization requires a **legal entity** — one that can sign contracts with Apple.
Apple does not accept sole proprietors, trade names, or DBAs for this, and issues a D-U-N-S
requirement on top. Incorporating a company, and carrying its running costs indefinitely, in
order to give away a free developer tool is not a trade worth making.

So the app is here instead, with its source, under the MIT licence. If you want it, you can
build it and run it on your own phone. That takes a paid Apple Developer account of your own —
see [`BUILDING.md`](BUILDING.md) — which is the same barrier, moved to where at least it buys
you the source code as well.

## What this does and does not tell you about the app

It says nothing about the app's quality or its privacy properties. Those claims are checkable
here in a way an App Store listing never allowed: the capture path, the storage, the TLS
handling, and the complete absence of any network client that talks to a server of ours are all
in this repository, and you can read them.

The design constraints that would have applied on the App Store still hold in the source, because
they were never store-driven in the first place:

- TunnelVision inspects **only the device owner's own traffic**, and only after the owner approves
  a Personal VPN profile that iOS shows in the status bar the entire time it is running.
- HTTPS inspection is **opt-in**, off by default, and additionally requires manually installing and
  trusting a locally generated certificate — a deliberate, reversible, friction-heavy step.
- TunnelVision **never attempts to defeat another app's certificate pinning**. A pinned connection
  is passed through untouched and labelled *not inspectable*. This is a hard non-goal, recorded in
  [`decisions/0003-no-third-party-pinning-bypass.md`](decisions/0003-no-third-party-pinning-bypass.md).

## Distribution, honestly

There is no plan to work around the guideline. Specifically:

- **No sideloading service or signing helper** is offered here. Building it yourself from source is
  the supported path.
- **No alternative store listing** is promised. EU alternative marketplaces are a real option for
  software like this, but distributing a binary means signing it, supporting it, and standing behind
  builds on hardware nobody here can test. If that changes it will be announced in the
  [changelog](../CHANGELOG.md).

If you maintain an organization Developer account and think this belongs on the store, the licence
permits it. Do it under your own name and your own accountability — not as a re-upload of someone
else's identity.
