# TunnelVision (app target)

The SwiftUI app: UI, tunnel lifecycle control, and history browsing. MVVM, `@MainActor` view
models, `async/await`. Links `Shared` and embeds the `PacketTunnel` and `AuditControls` extensions.

- `App/` — entry point · `Models/` — UI types · `ViewModels/` — state · `Views/` — screens ·
  `Services/` — tunnel control + live-feed reader · `Intents/` — the App Intent that places an audit
  marker from outside the app (also compiled into the `AuditControls` extension)

**UX specs:** [`../docs/ux/`](../docs/ux/) · **Milestones:** M9–M11
