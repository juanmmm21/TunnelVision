# 0001 — Use `NEPacketTunnelProvider` for on-device capture

- Status: Accepted
- Date: 2026-07-14

## Context

We need to observe all of the device's network traffic on an unmodified iPhone. iOS sandboxes
apps and gives no raw access to other apps' sockets or a promiscuous interface. The only
App-Store-shippable mechanism to see device-wide traffic is Apple's NetworkExtension framework.
Its variants:

- **Packet Tunnel Provider** (`NEPacketTunnelProvider`) — a personal VPN that receives raw IP
  packets and can reinject them.
- **App Proxy Provider** (`NEAppProxyProvider`) — flow-level, TCP/UDP, for MDM-managed per-app
  proxying.
- **Content Filter** (`NEFilterDataProvider`) — allow/deny verdicts on flows, no full capture
  or forwarding control.
- **DNS Proxy** — DNS only.

## Decision

Use **`NEPacketTunnelProvider`**. It is the only option that delivers full raw IP packets for
all traffic, lets us parse at the IP layer, and lets us forward/reinject — exactly what a packet
analyzer needs. The tunnel terminates locally (there is no remote VPN server).

## Consequences

- We get raw IP datagrams and must implement IP/TCP/UDP parsing and, for inspection, a userspace
  TCP path ourselves (see [0005](0005-userspace-tcp-for-inspection.md)). More work, full control.
- The extension runs in a **memory-constrained** process the OS will kill if it overruns; this
  drives the streaming/bounded-buffer design throughout.
- It **cannot run in the Simulator** and needs a paid Developer account with the Packet Tunnel
  Provider capability. We mitigate by keeping all logic testable off-device.
- **Distribution:** App Store VPN apps are governed by Review Guideline 5.4 and likely require an
  **organization** Developer account plus a granted distribution entitlement. End users need
  none of this.
- The user sees the system VPN indicator whenever monitoring is on — which we treat as a trust
  signal, not a problem.

## Alternatives considered

- **App Proxy Provider:** flow-level only and effectively requires supervised/MDM devices for
  general use — wrong tool for a consumer analyzer.
- **Content Filter:** gives verdicts, not capture or forwarding — can't build a pcap or an
  inspector from it.
- **Jailbreak / private APIs:** not shippable, not safe, out of scope.
