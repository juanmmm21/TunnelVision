# UX — Audit

The screens that turn a capture into evidence about one app: an **audit project** (the app, and the
domains it is expected to contact), its **sessions** (named recordings, one per version and build,
plus a baseline) and the **markers** placed inside a session. The model underneath is
[`../spec/audit.md`](../spec/audit.md); the scope and the attribution method are
[ADR 0008](../decisions/0008-tr03161-audit-workflow-scope.md).

```
Audit (tab) ──▶ Project ──▶ Session ──▶ Evidence bundle (sheet, once the session has ended)
   │              │  └─ Start session (sheet)
   │              └─ Edit project (sheet)
   └─ New project (sheet)

Dashboard ──(strip, only while a session records)──▶ Session

Control Center · Action Button · Shortcuts · Siri ──▶ a marker in the open session (no screen)
```

## Why a tab

Audit is the fifth tab, between Captures and Settings. It is what the tool is used *for* once an
assessment is under way — opened every session, with the audited app waiting in the background — so
it does not belong two levels down in Settings beside preferences, nor inside Captures, whose screen
is an inventory of files. Five is also the most a tab bar shows without a *More* item: there is no
room for a sixth, and that is a constraint on what comes next, not an accident.

## What the three screens decide

None of it is drawing. The decisions live in `AuditPresentation` and `AuditForms`
(`TunnelVision/Models`), pure and tested; one `AuditViewModel` feeds all three screens **and** the
Dashboard, because what they show is the same fact — which projects exist and which session is
recording — and a view model per screen would leave the list behind a session saying it still records
after it was ended.

### Projects

A short grouped list, like Captures: name and how many sessions. **No leading rail and no icon** —
the rule of the capture row: a mark on every row would say *this is a project* in a list of projects.
The one exception gets its badge: the project whose session is **recording**. With no projects the
screen teaches what the feature is for in one sentence and offers *New project*; it names no
standard.

### A project

- **Sessions**, newest first, each named after what it observed — `Version 2.4.0 (187)` or
  `Baseline`. Version and build **identify** a binary, so they are shown exactly as typed and never
  grouped or reformatted. The recording one carries the badge.
- **Start session** is the last row of that card. It is disabled, not hidden, while **any** session
  is open — only one can be, across all projects ([`../spec/audit.md`](../spec/audit.md)) — and the
  footer says why, naming the other project when the open session is not this one's: from here it
  cannot be seen. With no sessions at all the footer says to begin with a baseline instead.
- **Allowed domains**: the pattern in the `literal` role (it is read character by character) with its
  note under it. The footer states the two accepted forms and the rule people get wrong — a wildcard
  does not cover the name itself.
- **Audited app**: the bundle identifier, only when one was written. Its footer exists to prevent one
  reading: the identifier does **not** filter traffic. The tunnel sees packets, not apps; what
  separates this app's traffic is the baseline.

### A session

Ordered by what the screen is opened for:

1. **Status** — *Recording* or *Ended*, how many connections it holds, when it started and ended.
   The footer says the thing that matters in each state: while recording, that **every** connection
   the device makes is tagged, whichever app makes it; once ended, that its connections and captures
   are kept as evidence outside the storage limits until the session is deleted.
2. **Mark now** (only while recording) — *Consent given*, *Logged in*, *Logged out* and *Other…*.
   Above the list of markers already placed, because while recording this is what the screen is
   opened to do. A marker is stamped with the instant of the **tap**.
   Once the session has ended this place is taken by **Evidence bundle**, for the same reason: it is
   what the screen is opened for in that state (§ *Exporting a session*).
3. **Markers** — as they happened, to the second. A closed session takes no more and says why: a
   marker placed after looking at the traffic is no longer an observation.
4. **Certificate pinning** — what this session can say about it, decided by `PinningEvidence`
   (pure, no default): *Can be assessed* only when inspection was on **and** the device trusted the
   certificate; otherwise *Not assessed*, with a different sentence for each of the two reasons,
   because each has its own way out. It is never *passed* or *failed*: nothing was observed. And the
   readable case says how it is read — an app either refused the user-installed certificate or
   accepted it — and that nothing was bypassed to find out
   ([ADR 0003](../decisions/0003-no-third-party-pinning-bypass.md)).
5. **Recorded on** — device model, iOS, TunnelVision version.
6. **Notes**, only if any were written.
7. **End session** (while recording) and **Delete session**, both confirmed. Ending is irreversible in the two ways
   the prompt names: tagging stops and no marker can be added. Deleting says what is *not* lost —
   the connections stay in the history — and what changes for them: they stop being evidence and
   expire with the storage limits.

## Exporting a session

A session that has **ended** offers one row, *Export evidence*, under its status. A recording one
does not: a bundle is closed evidence ([`../spec/audit.md`](../spec/audit.md) § *Evidence bundle*).

Tapping the row **shares nothing**. It writes the bundle — the row shows progress and every other
row that writes is disabled meanwhile — and then opens a sheet that says what was written. Sharing
is the button at the bottom of that sheet. The order is the one the connections export already has
in Captures, and it matters more here: what leaves the device is a capture.

The sheet, top to bottom, and why each line is there:

1. **What it is**: *Evidence bundle ready to share*, its size, `ZIP`, how many files — eight, the
   report among them. The count is of the names the exporter returns, not a number of the screen's.
2. **What the bundle says of itself**, in the bundle's own words (`session.json`'s `contents`):
   connection metadata, what it shows against a requirement catalogue, a capture — and that
   decrypted content is not part of it.
3. **Connections** and **Findings**, as counts, and under them what `findings.json` says of its
   verdicts, again in its own words: a verdict is not a test result, and none states that a
   requirement is met.
4. **Capture** — the part nobody can see by opening the archive. Decided by
   `EvidenceCaptureStanding` (pure, no default), which has three cases and not a tally with three
   zeroes:
   - every recorded packet is in the capture — one neutral sentence;
   - some are missing — a warning headline, *4,842 of 4,895 recorded packets are in the capture*,
     and **one sentence per reason that has packets**: never written to a capture file, in a
     capture file that is no longer on this device, could not be read back;
   - the session recorded no packets — said as that, not as a complete capture.

   Then, if any, the packets that *are* in the capture but fall outside the session's time window,
   with why they are there (their connection was also active during the session): without the
   sentence they read as traffic that should not be in the file. And always, last: **anything that
   was sent unencrypted can be read in the capture**. "No decrypted content" is easily read as "no
   content", and from a medical app what travelled in the clear can be health data.
5. The **file name**, in the `literal` role, and **Share**.

**The bundle's own sentences are quoted, not reworded.** Items 2 and 3 show
`EvidenceSessionDocument.contentsNote` and `EvidenceWording.verdictsNote` as they are written into
the files. They are limits that were costly to settle, and a second wording on the screen would
sooner or later say something else than the file the user is about to send. The cost is visible: the
verdict note names `toolCoverage`, a key of `findings.json`. The sentences about the capture are the
screen's own, from the string catalog, because they carry this export's numbers; each reason is
worded as `capture.json` defines it.

**An export that fails is a notice at the top of the session screen**, never a sheet, and each of
the eight ways it can fail has a sentence of its own (`AuditPresentation.evidenceExportFailed`). A
catalogue this version does not include is **named**, and the sentence says no other was used
instead; a history that changed under the export says to export again; a failed write says nothing
was left behind and names the one cause a user can act on, free space. The section sits second on
the screen so that the notice appears where the row was tapped.

Closing the sheet does not delete the archive: the system share sheet may still be reading it. The
next export does — there is at most one bundle on disk, in the app's temporary directory.

## The two forms

- **Project**: name, bundle identifier (optional) and the allowlist, one line per domain with an
  optional note. What is wrong is decided in `AuditProjectForm.draft()` and shown **on the line that
  has it** — an allowlist of twenty entries with one loose warning on top would make the user hunt
  for it — one issue at a time, top to bottom. Every rejection of a pattern has a sentence of its
  own; a pasted URL is told which character cannot be there. Blank lines are ignored; a note without
  a domain is not, because whoever wrote it believed they were allowing something.
- **Session**: *Audit* or *Baseline*, then version and build (which disappear for a baseline rather
  than being disabled: a baseline has no release), then notes. The form proposes the **baseline**
  while the project has none. Under the type control sits the method itself, said at the only moment
  it is useful: use only the audited app while this records; record the baseline before installing
  it.

**What is not asked.** Device model, system version, tool version and the state of HTTPS inspection
are read from the device when the session starts (`AuditRecordingConditions`). The form does show,
**before** recording, whether pinning will be assessable — in the future tense, with its own copy —
because a session recorded without inspection cannot be fixed afterwards. The conditions are read
again at the instant recording starts: between opening the form and confirming it, the user may have
been to Settings.

## The open session, where the tunnel is watched

A session left open keeps tagging every connection until someone ends it. So the Dashboard shows a
strip directly under the monitoring control for as long as one is open — *Audit session recording*,
whose project it is, and *Open*, which lands on that session with its project behind it in the stack.
It has the shape of the monitoring strip on purpose: both are things happening right now. It is
absent the rest of the time, so the Dashboard of someone who never audits is unchanged.

## Marking without coming back

*Mark now* needs TunnelVision in front, and the moment that matters most — accepting the audited
app's consent screen — happens with the audited app in front. So the three fixed markers can also be
placed from outside ([`../spec/audit.md`](../spec/audit.md) § *Marking from outside the app*):

- **A control** (iOS 18+) for Control Center, the Action Button and the Lock Screen. Its title is the
  marker it places and its second line is where it would place it: the project that is recording, or
  *No session recording*. It is configurable, so there can be one per marker; untouched, it marks
  *Consent given*.
- **An App Shortcut**, *Place Audit Marker*, which Shortcuts shows with one tile per marker, and
  which Siri and Spotlight offer without anyone building it.

What they say afterwards is the whole design. Placed: `“Consent given” marked at 21:58:34 in Example
Health.` — the name, the time to the second, the project. Not placed: an error that begins *No marker
was placed*, and then why (no session is recording, or the history could not be written). There is no
third, quiet outcome.

Neither opens the app. Coming back later, the session screen already lists what was placed from
outside: the tab re-reads when the app returns to the foreground.

The free-form marker (*Other…*) is not offered outside the app. It has to be typed, and by the time
it is typed the instant is no longer the one being marked.

## Measured, not eyeballed

From `idb ui describe-all` on an iPhone 17, and what each measurement changed:

- **A pushed screen with a large title and an opaque bar had no title at all.** Both pushed screens
  use the inline title, like every other pushed screen in the app; the bar is opaque with the canvas
  colour because their rows slide under it ([`design-system.md`](design-system.md)).
- **A button row measured 74 pt.** A list row is already taller than `TouchTarget.minimum`; adding
  the minimum to the label stacked the two. The label keeps only the full width.
- **A `Label` inside a list row sends its icon to the row's icon column**, leaving *Recording* 28 pt
  from its symbol and a form's warning indented under a field that is not. The badge and the form
  issue are an `HStack`.
- **A disabled row kept its symbol in the brand tint**, which reads as active beside a dimmed word.
  The label takes `neutral` while disabled.
- At the largest accessibility size, in dark, every fact row stacks its label over its value and
  nothing truncates.
- **The export row measures 51 pt** at the default size and 155 pt at the largest, where its label
  wraps instead of truncating.
- **The evidence sheet ends at 681 pt of an 874 pt screen at the default size** — it fits with
  *Share* in view, which is why it opens at the large detent and not the medium one of the
  connections export: at medium the capture's sentences would sit under the fold with the button
  above them. **At the largest accessibility size it is about 3,800 pt**, over four screens, of
  which the quoted verdict note alone takes 937 pt. Nothing truncates and the bar stays opaque over
  what slides under it, but *Share* is a long way down. That is the price of quoting the bundle in
  full, and it is the one thing here that was measured and left as it is.
