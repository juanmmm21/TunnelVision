# Intents

The App Intent that places an audit marker without opening the app, and what it says.

Compiled into **three** targets by source membership: the app (Shortcuts, Siri), the `AuditControls`
widget extension (the Control Center control) and the unit-test bundle. `AuditShortcuts.swift` is
app-only. Nothing here may depend on the rest of the app: only `Foundation`, `AppIntents` and `Shared`.

**Spec:** [`../../docs/spec/audit.md`](../../docs/spec/audit.md) § *Marking from outside the app*
