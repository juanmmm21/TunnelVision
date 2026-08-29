# Shared/IPC

Cross-process live feed: the mmap ring buffer (`RingBufferProducer`/`RingBufferConsumer`,
`PackedPacketMeta`) and the payload-less Darwin wakeup signal. Also the single source of truth
for `AppGroup.identifier`.

`ControlChannel.swift` holds the *other* cross-process contract: the low-frequency
`ControlCommand`/`ControlResponse` codec (with `PipelineStats`) that the app sends over
`sendProviderMessage` and the extension answers in `handleAppMessage`. It lives here, not in the
extension, because both processes need it and the app cannot link an app-extension.

`SettingsStore.swift` is the **third** cross-process contract, and the only durable one: the user's
`AppSettings` as one JSON blob in the App Group's `UserDefaults`. The app writes it when a setting is
touched and the extension reads it in `startTunnel`, so a choice survives the extension dying; the
control channel above applies a change to a session already running, which is a different job. One blob
and not a key per setting, so no reader can see half a write; decoding is tolerant field by field, so
adding a setting later cannot wipe the ones the user already chose; and a blob that is not even JSON is a
visible `corruptData` rather than a silent reset. The seam (`init(reading:writing:)`) exists because on
the Simulator a defaults suite answers for almost any identifier, so the real "no entitlement" failure
cannot be provoked there.

**Spec:** [`../../docs/spec/ipc.md`](../../docs/spec/ipc.md) · **Milestones:** M5, M7, M9
