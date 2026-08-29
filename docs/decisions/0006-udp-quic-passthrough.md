# 0006 — Pass UDP/QUIC through without termination

- Status: Accepted
- Date: 2026-07-14

## Context

A growing share of traffic is UDP-based: DNS, VoIP, media streaming, and especially **QUIC**
(HTTP/3). QUIC encrypts most of its transport metadata and multiplexes streams inside a single
connection; terminating or deep-inspecting it in the extension would be very expensive and would
hurt latency for exactly the traffic users most notice (calls, video).

## Decision

**Always passthrough UDP and QUIC** with metadata-only logging (5-tuple, byte/packet counts,
SNI when present in a QUIC Initial). We never TLS-terminate QUIC and never buffer whole UDP
flows. See [`../spec/relay-and-tls.md`](../spec/relay-and-tls.md) and
[`../spec/tunnel-provider.md`](../spec/tunnel-provider.md).

## Consequences

- **Battery & latency:** VoIP/streaming stay smooth; no per-packet deep processing on the hot
  UDP path. This is a core part of the battery story we promise users.
- **Memory:** no reassembly buffers for UDP; the extension budget is spent where it matters.
- **Visibility trade-off:** QUIC/HTTP/3 content is not decoded. We still surface useful metadata
  (endpoints, volumes, SNI/hostname) so the user learns *who* is being contacted, if not the
  payload. This is honestly reflected in the flow's status.
- **Future option:** if QUIC inspection is ever wanted, it would be a large, separate effort with
  its own ADR — and still subject to the no-pinning-bypass boundary
  ([0003](0003-no-third-party-pinning-bypass.md)).

## Alternatives considered

- **Terminate QUIC like TCP+TLS:** rejected for now — high complexity and cost, hurts the
  latency-sensitive traffic it targets, for limited additional insight over metadata.
- **Buffer/reassemble UDP flows:** pointless — UDP is message-oriented and often real-time;
  buffering adds latency and memory for no analytical gain.
