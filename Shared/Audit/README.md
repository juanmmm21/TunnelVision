# Shared/Audit

The value types of the TR-03161 network evidence workflow: `AuditProject` (what is audited, with its
domain allowlist of `DomainPattern`s), `AuditSession` (one named recording of it — a `baseline` or an
`audit` of a given `AppRelease`, with the device and the inspection conditions it was made under) and
`SessionMarker` (an instant marked inside a session: consent given, logged in, logged out, custom).
`AuditRecording` and `OpenSessionMarkerOutcome` are what marking *the open session* returns, for
whoever marks without knowing which one it is. All `Sendable`; Foundation-only.

They live in `Shared` because three processes meet them: the app creates and reads them, the
tunnel extension's writes are tagged with the open session, and the controls extension places
markers in it. Their storage is the audit half of `FlowStore`
(`../Persistence/FlowStore+Audit.swift`, schema `v6`).

An *audit* session is not the *capture* session of `FlowStore`: the latter is the instant the store was
opened and only keeps a recycled 5-tuple from merging two connections.

**Spec:** [`../../docs/spec/audit.md`](../../docs/spec/audit.md) ·
**Decision:** [`../../docs/decisions/0008-tr03161-audit-workflow-scope.md`](../../docs/decisions/0008-tr03161-audit-workflow-scope.md)
