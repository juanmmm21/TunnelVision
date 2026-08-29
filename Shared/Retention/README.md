# Shared/Retention

What the storage caps mean, in the two halves that decision has: `RetentionPlanner` decides **who
goes** given a directory listing, the caps and `now`, and `CaptureRetention` **executes** that plan —
deletes the files it names and prunes the history to its cutoff.

Both were the app's until M11. The caps only ever applied with the Settings screen in front of the
user (on appear and on change), so a tunnel capturing all night could sit over its cap until the next
visit — and *while nobody is looking* is exactly when the directory grows. The extension now applies
them too, **on rotation**: the only moment it is already touching the directory, and the only one that
exists with the app closed. That is what moved these two here. A cap cannot mean one thing in front of
the user and another behind their back.

What did **not** move is each side's plumbing, and that is deliberate. Resolving the App Group
container and opening the history are the steps that can fail, and they fail differently for each
caller: the app has a screen to explain it on and opens the store lazily per operation, the extension
resolved both when the session started. So `CaptureRetention.execute` takes the listing its caller
already had and a way to reach the history, holds no state, and never throws — a half-done cleanup is
a result (`RetentionOutcome`), not a fault, because what *was* freed still has to be counted.

The app keeps `StorageManager` ([`../../TunnelVision/Services`](../../TunnelVision/Services)) on top:
how much is used, and clearing everything. Those are gestures of the user's, and the extension has
nobody to report them to — it counts its own sweeps into `PipelineStats` instead, which is how a
failure with nobody watching avoids being swallowed.

There is a **second** pair here, for the decrypted content that TLS inspection produces
(`PlaintextRetentionPlanner` / `PlaintextRetention`, ADR
[0007](../../docs/decisions/0007-decrypted-content-retention.md)). It is deliberately not a case of
the first: the capture caps are the user's and can be removed, while decrypted content **always**
expires and its ceiling is fixed and unraisable, so sharing a method would have tied the sweep to the
`isUnlimited` shortcut that must never apply to it. Its age is measured over **index rows**, not
files — one file mixes conversations hours apart — so the sequence is prune, then ask which files are
still referenced (an orphan is what the prune just left without rows), then delete. Full rationale in
[`../../docs/spec/plaintext.md`](../../docs/spec/plaintext.md) § *The sweep*.

**Spec:** [`../../docs/spec/app-services.md`](../../docs/spec/app-services.md),
[`../../docs/spec/plaintext.md`](../../docs/spec/plaintext.md) · **Milestones:** M9, M11
