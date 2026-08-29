# TunnelVision/App

App entry point: the `@main App` struct, scene/`TabView` setup, dependency wiring, and
first-run routing into onboarding.

`FixtureSeedGate` (Debug-only, M11) sits between the launch and the screens when `-TVSeedFixture` was
passed. It is a gate and not a background task because seeding **replaces** the history: letting the
screens mount meanwhile would have them read a database that is being emptied, and the emptiness they
drew would already be untrue by the time it appeared. Everything it decides lives in
`Services/FixtureSeeding`; what is here is the drawing and the console line — without which, a capture
of thousands of packets looks like an app that hung. Its copy is `Text(verbatim:)` on purpose: a
developer diagnostic is not product copy and must not reach the string catalog.

**Ref:** [`../../docs/ux/screens.md`](../../docs/ux/screens.md)
