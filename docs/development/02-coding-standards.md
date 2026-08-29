# 02 — Coding standards

These are binding for all code in this repo. They exist so that work from different sessions
looks like it came from one engineer.

## Language and concurrency

- **Swift 6, strict concurrency complete.** No data races that the compiler can catch. Types
  crossing concurrency boundaries are `Sendable`; if a type cannot be `Sendable`, it does not
  cross a boundary.
- **`async/await` and actors for all I/O.** Networking, disk, and database access never run
  on the main thread. UI state is updated on `@MainActor`.
- **Actors own mutable state.** The flow table, the pcap writer, and the GRDB writer are
  actors (or serialized through one). Callers `await` them; they never expose their internals.
- **No blocking.** No semaphores or `DispatchSemaphore.wait()` on the main thread; no
  `Thread.sleep`. The packet read loop is an async loop, not a busy-wait.

## Types first, then logic

This is the house rhythm and it is not optional:

1. Define the data types (`struct`/`enum`, `Sendable`, `Codable` where needed).
2. Define the protocol / function signatures, with documented error behaviour.
3. Only then implement the bodies.

The `spec/` documents already give you step 1 and 2 for every module. Follow them; if you
must deviate, update the spec in the same commit.

## Error handling

- **Typed errors per domain.** Each module defines its own `Error` enum
  (`PacketParseError`, `ReassemblyError`, `StoreError`, `IPCError`, `TLSInterceptError`,
  `TunnelError`). No throwing of `NSError` soup.
- **No silent failure.** No empty `catch {}`, no `try?` on a critical path. If a packet is
  malformed, it is counted and dropped explicitly, never swallowed.
- **Resources are closed explicitly.** File handles, the mmap region, `NWConnection`s, and
  database connections are closed in `defer` or in a lifecycle method — never left to
  finalizers.
- **Back-pressure is a first-class outcome, not an error.** When a bounded buffer is full,
  the code drops and increments a counter that the UI can surface; it does not grow memory
  and it does not crash.

## Naming and comments

- **Identifiers in English**, descriptive, no abbreviations that aren't domain-standard
  (`seq`, `ack`, `sni`, `mtu` are fine).
- **Comments in Spanish, and only for the *why*** — an architecture decision, a workaround
  for an OS quirk, a performance trade-off. Never comment the *what*; the code says that.
- Public types and non-obvious functions get a `///` doc comment describing contract and
  error behaviour.

## Product copy (M11 onwards)

Every string a user can read or hear goes through `String(localized:defaultValue:comment:)`.
There is no `L10n` helper and there must not be one: Xcode extracts the copy into
`TunnelVision/Resources/Localizable.xcstrings` by reading these calls at build time, and it only
sees them when the key, the default value and the comment are **literals at the call site**. A
wrapper function would compile fine and silently extract nothing.

- **The English lives in the code**, as `defaultValue`, next to the Spanish comment that
  justifies it. The catalog's `en` values are a *record* of that extraction, written by the
  tool and never edited by hand: edit the Swift and re-sync
  ([`01-environment-and-project-setup.md`](01-environment-and-project-setup.md)). Everything
  else in the catalog — the other languages — is a translator's to write. This is what keeps
  the copy the tests assert and the copy the app shows from drifting apart.
- **Keys are stable and structural**, `screen.element.role`
  (`intro.card.yourPrivacy.message`, `intro.cardAction.lastCard`). They are named after where
  the copy sits, never after what it says, so rewording never renames a key.
- **The `comment:` is for translators and is written in English**, like the rest of the public
  documentation. When a word is load-bearing, say why: the intro's *Skip* and its "go to the
  last step" must not collapse into the same word in any language.
- **Copy is composed inside the string, never around it.** Interpolate into the
  `defaultValue` (`"Step \(step) of \(stepCount)"`) instead of concatenating localized
  fragments — the order of the pieces is a property of the language.
- **Views do not compose copy.** A SwiftUI view that builds `"\(title). \(message)"` has taken
  a translation decision where no translator can reach it. That belongs in the pure layer
  (`TunnelVision/Models`), which is also where it can be tested.
- **Copy is composed once per decision, never once per frame.** The rule above says *where*;
  this one says *when*. A `body` that calls into the pure layer recomposes on every evaluation,
  and a list row's body runs for every visible row of every frame of a scroll — where each of
  those strings is now also a catalog lookup, and one of them is the long sentence only
  VoiceOver ever hears. The composed value is published by the view model, which is what knows
  when the data changed, and the view only receives it: a row travels with its copy
  (`TimelineRow`, `PacketListRow`), the activity graph with everything it says of itself
  (`ScrubAxisPresentation`). The cache is invalidated by **the very value the copy derives
  from** — `TimelineViewModel` recomposes when the flows are unequal, not when their ids change
  — because anything narrower leaves a drawn row showing the copy of a flow that has since been
  reloaded; where a list is loaded whole and never paginated (`FlowInspectorViewModel`) there is
  nothing to compare and the composition simply happens once per load. Only what is *composed*
  travels: an icon or a colour picked by a `switch` over an enum neither allocates nor looks
  anything up, and stays in the view. And a value that **identifies** — one pushed by a
  `NavigationLink`, or a dictionary key — never grows a copy-composing property, because that is
  a standing invitation to call it from a `body` again. What genuinely depends on the finger
  stays in the view, and there the sibling rule applies: **do not write view state with the
  value it already holds**, since an equal write invalidates the view anyway (`ScrubBar` rounds
  a drag to whole bars, so most frames of a sweep produce the stretch that is already on
  screen).
- **What identifies is not what is shown.** `Identifiable.id` and dictionary keys never derive
  from a localized string; identity must not change with the language. The cost is not always
  a redraw: `FlowFact.id` *was* its own label, and the packet screen concatenates two lists of
  facts into one `ForEach`, so two labels a language happens to word alike would collide and
  one of the two would stop being drawn.
- **Two sentences that may appear alone or together need a third key to join them.** Pinning
  them together in Swift (`joined(separator: " ")`) decides the order and the separator outside
  the catalog, which is the same mistake as a view composing copy — the join key takes both
  resolved sentences as placeholders (`PacketBytesPresentation.truncationNote`,
  `ScrubAccessibility.cursorValue`). **Three sentences use the same key twice**, applied in
  cascade so the first placeholder may itself be a pair already joined
  (`SettingsPresentation.joined`): a translator still owns every separator, and one key beats a
  family of near-identical ones for every arity.
- **Plurals are the one exception, and they are hand-rolled on purpose.** A count that varies a
  noun (`1 connection` / `1,204 connections`) is written as **two sibling keys** picked by a
  pure function, not with automatic grammar agreement. The markup (`^[\(n) connection](inflect:
  true)`) is **not resolved when there is no catalog**, and the test bundle has none: it would
  reach the assertions — and any unlocalized fallback — as raw markup, which is exactly the
  drift the rule above exists to prevent. Two keys are correct for English and Spanish and no
  more: the first language with additional plural forms must merge each pair into one key with
  plural variations authored in the catalog, and for those keys the English stops living only
  in the code. Say so where it happens (`DashboardPresentation.connectionsSummary` is the
  worked example) rather than leaving it to be discovered. **A sentence carrying two counts
  needs the four combinations**, not two keys and not a pair of noun phrases interpolated into
  a third: each half picks its own form, and a bare `3 captures` handed to a translator is a
  fragment, not a sentence (`SettingsPresentation.clearedText`).
- **A screen's migration ships with the two tests that catch what content assertions cannot.**
  A call that loses its `defaultValue` returns **the key**, and a structural key reads
  innocently in a diff and then goes on screen. Re-flowing a multi-line literal moves the `\`
  continuations, and one in the wrong place leaves a double space or a trailing one while the
  text still says the same thing. Both are cheap to assert over every string of a screen at
  once (`CertificateSetupPresentationTests` is the worked example) and neither is caught by
  asserting what the copy says. Copy that shares one key across several places should share it
  *structurally* — one property both callers read — so that sharing survives an edit.
- **What the whole app repeats lives in `CommonCopy`, and the bar to get in is high.** Only words
  that mean the same wherever they appear (*Cancel*, *Done*, the hint on a dismissible notice)
  qualify; anything whose meaning depends on what is left behind belongs to its screen — the
  certificate flow's four ways out are the worked counter-example, and its screen title stays its
  own key even though the Settings row leading there says the same words today. *Try again* is
  the decided counter-example on the other side: **six** screens say it and it stays six keys,
  because behind each one is a different act — re-list a folder, re-open the history, repeat one
  packet query, read the keychain again, bring the tunnel up — and what failed is said by the
  card's own message, which the button only repeats. Six keys let a translator word them alike
  or apart; one key takes that away. That they coincide today is **asserted**
  (`CommonCopyTests`), so rewording one is a decision taken again rather than a drift.
- **Copy that names a control reads that control's key.** An instruction like "Tap *Install
  certificate* below" duplicates a button's label, and a translation can move one and not the
  other: the sentence still reads perfectly and sends the user looking for something the screen
  calls by another name. Interpolate the button's own property into the instruction
  (`CertificateSetupPresentation.installSteps` is the worked example) so the two cannot drift.
- **Not everything a user reads is copy.** A protocol's name on the wire (`TCP`, `ICMPv6`), a
  formatted figure and a unit are the same in every language, and putting them through the
  catalog only creates a translation unit somebody can get wrong —
  `IPProtocolNumber.displayName` is the worked example, where the four acronyms stay verbatim
  and only *Other*, which is a word of ours, has a key. Where the same word says two different
  things it gets two keys anyway: the Timeline's *Other* checkbox is a bucket that includes
  ICMP, a row's *Other* means "we cannot name this one". A **figure with its unit** is the same
  call: Settings' three capture size caps (`256 MB`, `1 GB`, `4 GB`) stay verbatim in
  `SettingsPresentation.label(for:)` and only *No limit*, a word of ours, has a key — twice,
  because the age picker's and the size picker's say different things about different policies.
- **A number that identifies is interpolated as a `String`, never as an integer.** Interpolating
  an integer into `String(localized:)` **formats it with the process locale**, thousands
  separator included, which is wrong for a port, a sequence, an offset or a position in a list:
  they are names, not amounts (`8080`, never `8,080`; `Capture 20000`, never `Capture 20.000`).
  Wrap it — `"port \(String(port))"` — which selects the verbatim `%@` path. A count in the same
  sentence stays grouped, through `DisplayFormat.count`, because that one *is* an amount
  (`Interval 12000 of 12000. Selecting 12,000 intervals.`). Assert it — and what makes the
  assertion real is that **the test bundle's locale is pinned to English** (below), not the size
  of the fixture. That is exactly how this was found, three screens late:
  `FlowDisplay.service`, `ScrubAccessibility.reading`,
  `CertificateSetupStep.accessibilityLabel` and `CapturesPresentation.title(forSequence:)` all
  had it, and two of them had a test that said otherwise and passed anyway.
- **What is not copy must not reach the catalog by accident.** SwiftUI and Swift Charts read a
  **string literal** at the call site as a `LocalizedStringKey`, so `Text("42")` and
  `.value("Packets", …)` become translation units even when nothing about them is a word: the
  catalog collected `"%lld"`, `" – "`, `" %@"`, `From`, `To` and `Packets` this way. Passing a
  `String` (a constant, or copy already resolved by the pure layer) selects the non-localizing
  overload, and `Text(verbatim:)` says it outright. Use whichever reads better where it sits —
  `ScrubBar` names its three chart dimensions as private constants, `SetupStepList` uses
  `Text(verbatim:)` — but never leave punctuation, a format fragment or an axis name in the
  catalog: a translator will see it, and there is no right thing for them to do with it.
- **System names and paths are copied, not translated.** iOS's own wording (*Save to Files*,
  *Profile Downloaded*, *Not Signed*, `Settings → General → About`) has to match what the
  device shows in that language, or the user searches Settings for something that is not
  there. Say so in the `comment:`; a translator cannot know which words are ours.

`TunnelVision/Models` is compiled into the test bundle by source membership, and the test
bundle has no catalog: in tests every lookup falls back to `defaultValue`, so the existing
assertions on literal English keep meaning exactly what they meant.

**The test bundle runs in English, and that is a setting, not luck.** The scheme pins it
(`project.yml`, `schemes.TunnelVision.test.language`/`region` → `en`/`US`), so Xcode, the
terminal and CI all agree. It matters because a lookup falling back to its `defaultValue` is
language-independent but its *placeholders* are not: an integer is formatted with the process
locale, so without the pin every assertion about a number said whatever the machine running it
happened to say. Two things follow:

- **`en_US`, not `en_US_POSIX`.** POSIX never groups, so pinning there would hide exactly the
  same bug from the other side — a dropped `String(…)` wrapper would read `port 8080` and pass.
  POSIX stays correct where the format is for a machine rather than a person (`CaptureFileName`,
  `FlowExport`'s ISO stamps), and those pin it themselves.
- **The pin is asserted** (`CopyLocaleTests`), because the `.xcodeproj` is git-ignored and
  regenerated: losing the pin would break no test, it would only quietly empty the ones that
  watch numbers. The same file asserts the other leg the copy suite stands on — that no catalog
  has appeared in the test bundle, which would silently move every assertion off the code.

## Memory discipline (the extension is the hard part)

The extension runs under a small memory budget and the OS kills it if exceeded. Therefore:

- Bounded buffers everywhere (flow table size, per-flow reassembly window, ring buffer).
- Stream to disk; never accumulate a whole capture in memory.
- Recycle packet buffers immediately after parse+forward; do not retain payload beyond an
  in-flight inspected flow.
- Prefer value types and stack allocation; avoid unbounded collections and per-packet heap
  churn on the hot path.

See [`../spec/ipc.md`](../spec/ipc.md) and [`../ARCHITECTURE.md`](../ARCHITECTURE.md).

## Dependencies

Native Apple frameworks first (SwiftUI, NetworkExtension, Network, Foundation, Swift Charts,
CryptoKit, Security). The **only** third-party dependency is **GRDB.swift**, justified in
[`../decisions/0002-grdb-over-swiftdata.md`](../decisions/0002-grdb-over-swiftdata.md). Adding
any other package requires a new ADR.

## Testing

Every module with non-trivial logic ships with tests, and tests run green before every push.
Details and fixtures in [`04-testing-strategy.md`](04-testing-strategy.md).

## Git and authorship

- **Conventional Commits, lowercase**, scoped by module:
  `feat(flow):`, `fix(parser):`, `refactor(ipc):`, `docs(spec):`, `test(pcap):`, `chore(project):`.
- **One logical milestone per commit.** Structure, then models, then core logic, then tests,
  then docs — not one giant dump.
- **Author and committer are always** `juanmmm21 <martoscuevasjuan@gmail.com>`:

  ```bash
  git commit --author="juanmmm21 <martoscuevasjuan@gmail.com>" -m "feat(flow): add 5-tuple flow table"
  ```

- **No AI co-author trailers.** After each commit verify:

  ```bash
  git log -1 --format=%B | grep -c 'Co-authored-by'   # must be 0
  ```

  and before every push run `scripts/verify-author.sh` from the templates.
- **`AGENTS.md`, `CLAUDE.md`, `START_HERE.md` are git-ignored** and must never be tracked.
- **Never push to the public repo** (`TunnelVision`). This repo (`TunnelVisionDev`) is where
  development happens.

## Definition of done for a unit of work

- Types and signatures match (or update) the relevant `spec/` doc.
- Errors are typed and handled; resources are closed.
- Tests exist and pass on the Simulator.
- SwiftLint is clean.
- Commit(s) are atomic and focused on one logical change.
