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

`FlowStore+Audit.swift` (schema v6) is the audit half: projects with their allowlist, named sessions
and markers. The app writes it; the extension only reads it in passing, inside `upsertFlow`, which tags
each flow with the audit session open at that moment — read from the database in the same statement, so
no message between the processes is needed. Spec: [`../../docs/spec/audit.md`](../../docs/spec/audit.md).

Since schema v7 a flow also carries the name the DNS had given its remote address (`dns_name`,
`dns_other_names`) — its own columns, never `sni`, and the one field where a row that already has a
value keeps it: a flow is named when it is created and is not renamed halfway.

Since schema v8 it carries what the server answered to its ClientHello too (`tls_version`,
`tls_cipher_suite`, `tls_hello_retry`, `tls_alert`): the wire values, with no table behind them. A
record that brings no answer does not erase the row's, and one that brings it replaces it whole.

**Spec:** [`../../docs/spec/persistence.md`](../../docs/spec/persistence.md) · **Milestone:** M2
