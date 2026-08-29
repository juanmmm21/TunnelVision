# 0002 — Use GRDB/SQLite for history instead of SwiftData/Core Data

- Status: Accepted
- Date: 2026-07-14

## Context

History is a high-rate, append-heavy workload: potentially thousands of small packet-metadata
rows per second, written by the **extension** and read by the **app** — two processes sharing
an App Group container. The stack default for iOS is SwiftData (or Core Data).

## Decision

Use **GRDB.swift over SQLite** with WAL mode. It is the single third-party dependency
(justified here), used from a `FlowStore` actor. See [`../spec/persistence.md`](../spec/persistence.md).

## Consequences

- **Throughput:** direct, batched SQLite inserts in explicit transactions handle the write rate
  predictably, with tight control over memory — critical given the extension's budget.
- **Cross-process:** SQLite + WAL gives safe app-reads-while-extension-writes over the shared
  container. Core Data/SwiftData cross-process sharing is awkward and not designed for this
  write rate.
- **Explicit schema & migrations:** we own the DDL, indexes, and `DatabaseMigrator` versions —
  easy to reason about and test on a temp DB.
- **Cost:** we write our own mapping between records and rows (no free object graph); acceptable
  for a small, well-specified schema.
- Adds one SPM dependency; any further dependency needs its own ADR.

## Alternatives considered

- **SwiftData:** great for app-local model graphs, but immature for high-rate cross-process
  writes from an extension; less control over batching and memory.
- **Core Data (+ App Group store):** possible but heavyweight, with fragile multi-process
  coordination and worse write throughput for this pattern.
- **Raw SQLite C API:** maximal control but verbose and error-prone; GRDB gives us the same
  engine with a safe Swift surface.
