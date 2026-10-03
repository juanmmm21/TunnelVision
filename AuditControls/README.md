# AuditControls (WidgetKit extension, iOS 18+)

The Control Center control that places a marker in the open audit session without leaving the
audited app. It holds only the control and its configuration; the intent it runs and everything it
says live in [`../TunnelVision/Intents`](../TunnelVision/Intents/README.md), compiled here by source
membership, and the write itself is `FlowStore.addMarkerToOpenSession` in `Shared`.

Its only entitlement is the App Group. Running it for real needs a device: the Simulator builds it
and embeds it, but has no Control Center to put it in.

**Spec:** [`../docs/spec/audit.md`](../docs/spec/audit.md) § *Marking from outside the app*
