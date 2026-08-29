# Shared (framework)

Code linked into **both** the app and the extension, across the App Group. Extension-safe
(`APPLICATION_EXTENSION_API_ONLY = YES`), depends only on Apple frameworks + GRDB.

- `Models/` — domain value types ([spec](../docs/spec/data-model.md))
- `IP/` — IPv4/IPv6 + TCP/UDP parsing and emission ([spec](../docs/spec/packet-parsing.md))
- `Persistence/` — GRDB store, schema, migrations ([spec](../docs/spec/persistence.md))
- `IPC/` — mmap ring buffer layout, Darwin signal names, control-channel codec ([spec](../docs/spec/ipc.md))
- `Capture/` — the libpcap format and its streaming writer ([why here](Capture/README.md))
- `Retention/` — what the storage caps mean, for both processes ([why here](Retention/README.md))
- `TLS/` — the local CA: pure X.509 core + Keychain shell ([spec](../docs/spec/relay-and-tls.md))
- `Fixtures/` — **Debug-only** synthetic capture generator ([why](Fixtures/README.md))

Build order: this framework comes first (milestones M1–M2, M5).

`Capture/` and `Retention/` arrived later, from the extension and from the app respectively, and for
the same reason each time: a rule that stops having one consumer cannot stay in one of them. Their
READMEs say what stopped, and what deliberately stayed behind.
