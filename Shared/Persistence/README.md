# Shared/Persistence

Durable history in SQLite via GRDB, in the App Group container. `FlowStore` actor +
`DatabaseMigrator` schema (`flows`, `packets`), WAL mode, batched writes, retention/pruning.

The store is the boundary where time becomes absolute (M9): what comes in carries monotonic
`CLOCK_UPTIME_RAW` stamps, what is stored and read back is wall-clock, because a history dated with
uptime stops being datable or sortable the moment the device reboots. Reads therefore return their own
types (`StoredFlow`, `StoredPacket` in `StoredRecords.swift`, both carrying `Date` and a rowid) rather
than `FlowRecord`/`PacketMeta`. Each row also records the capture session it was seen in, which is part
of the flows' unique key: ephemeral ports get recycled, so the same 5-tuple in two sessions is two
connections.

Reads are row-by-row except one: `packetTimeBounds()` and `packetCounts(in:bucketDuration:)` (M9,
schema v4) **aggregate**, and they are what the Timeline's scrub bar is drawn from. They count packets
per interval rather than flows alive per interval — a packet falls in exactly one bucket while a flow
spans many — and they honour no filter at all, because the screen's host filter is resolved in memory
over the displayed host and an axis honouring half the criteria would look filtered without being it.

**Spec:** [`../../docs/spec/persistence.md`](../../docs/spec/persistence.md) · **Milestone:** M2
