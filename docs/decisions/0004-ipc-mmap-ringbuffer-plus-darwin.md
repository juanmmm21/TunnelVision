# 0004 — Live IPC via mmap ring buffer + Darwin signal

- Status: Accepted
- Date: 2026-07-14

## Context

The extension (producer) must stream a high rate of packet metadata to the app (consumer) for
the live UI, across a process boundary, without saturating the system and without adding latency
or memory pressure to the packet loop. Durable history already goes to SQLite, but that is not
the right channel for a real-time, per-packet feed.

## Decision

Use a **fixed-size memory-mapped ring buffer** in the App Group container as a lock-free
single-producer/single-consumer queue, plus a **Darwin notification** posted (coalesced) as a
wakeup only. The notification carries **no data**; the mmap carries the bytes. See
[`../spec/ipc.md`](../spec/ipc.md).

## Consequences

- **Low overhead:** `push` is a bounded write to shared memory with atomic head/tail; no
  syscall per packet, no allocation, no blocking. Back-pressure = drop + increment a counter.
- **Correct roles:** Darwin notifications are a bare cross-process signal; using them only to
  wake the consumer (then it drains the ring) is exactly what they're for. Trying to send packet
  data "through" Darwin notifications is a category error — they have no payload.
- **Bounded memory:** the ring is a fixed allocation; it can never grow to threaten the
  extension budget.
- **Complexity:** we implement the SPSC ring and its memory ordering carefully, and guard the
  header with a magic/version. Worth it for the performance profile.

## Alternatives considered

- **Darwin notifications carrying data:** impossible — no payload. (This was a misconception in
  the original sketch and is explicitly corrected.)
- **`handleAppMessage` / provider messaging for the live feed:** fine for occasional control
  commands, but request/response and not built for a per-packet firehose. We use it only for
  control (start/stop inspection, rotate pcap, stats).
- **Polling the SQLite store for live updates:** too slow, too much I/O, and couples the live UI
  to the durable write path. SQLite stays for history; the ring is for "now".
