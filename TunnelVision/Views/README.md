# TunnelVision/Views

SwiftUI screens and reusable components (`MonitoringToggle`, `ThroughputChart`, `FlowRow`,
`PacketRow`, `HexDumpRow`, `CaptureFileRow`, `TLSStatusBadge`, `ConsentSheet`, `PlaceholderCard`,
`SetupStepList`, `CertificateProfileSheet`, `ValueRow`, `FactGrid`, `ConversationTurnCard`,
empty/error states). Swift Charts for visualizations; full Dynamic Type + VoiceOver.

`Theme.swift` is where a design token becomes SwiftUI — the type roles, the surfaces
(`.cardSurface()`, `.screenCanvas()`, `.listCanvas()`, `.sunkenSurface()`), `.cardRow()` and
`SectionHeader`. No view writes a colour, a font size or a radius of its own.

**Refs:** [`../../docs/ux/screens.md`](../../docs/ux/screens.md),
[`../../docs/ux/design-system.md`](../../docs/ux/design-system.md)
