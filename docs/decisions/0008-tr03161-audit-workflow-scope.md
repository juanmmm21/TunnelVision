# 0008 — TR-03161 audit workflow: scope, publication and attribution

- Status: Accepted — decision (2), publication, superseded by [0009](0009-development-in-the-public-repository.md)
- Date: 2026-10-03

## Context

Since 2026-09-30 the direction of the project is to make TunnelVision produce network evidence for
security assessments against BSI TR-03161 (medical apps / DiGA) — work that is done by hand today
with an intercepting proxy. The plan, the gaps against what exists and the construction order are
kept in the private development repository (`07-tr03161-audit-workflow.md`), like every other list of
unfinished work.

That plan left three questions open on purpose, because none of them is a technical question and all
three shape what gets built:

1. **How much of the plan is in scope.** It lists eleven increments, the last two of which (QUIC SNI
   and a feasibility study of app attribution and a macOS target) are of a different kind from the
   rest.
2. **What reaches the public repository.** Since 2026-08-29 `TunnelVision` carries the full source
   under MIT, so "nothing development-related goes public" no longer answers it.
3. **How traffic is attributed to the audited app.** A packet tunnel sees packets, not processes,
   and a report that does not say how it knows whose traffic it is describing is not evidence.

## Decision

**(1) Scope: the core workflow, increments 1–9 of the plan, with QUIC SNI (10) after them.** That
is: the audit data model and schema `v6`; the session lifecycle screen and the marker control; names
from DNS; TLS metadata; the findings classifier; the release diff; the requirement catalogue and its
mapping; the evidence bundle; and the PDF report. QUIC SNI stays in scope and stays last, as the plan
orders it. **Increment 11 — the written feasibility study of per-app attribution (MDM per-app VPN,
`NEFilterDataProvider`) and of a macOS target — is out of scope.** Nothing is built or studied for
either until a later ADR says otherwise.

**(2) Publication: all of the workflow's code, one finished increment at a time.** An increment that
is complete and green may be promoted to the public repository under MIT like the rest of the source,
by copying the source tree and not the history, and **only after telling Juan before each copy**. The
exclusions that already apply keep applying: `PROGRESS.md`, the roadmap, `00-START-HERE.md`, and the
plan itself (`07-tr03161-audit-workflow.md`) never go public, because they describe unfinished work.

**(3) Attribution: a controlled session against a baseline.** The method is procedural, not
technical: a device with nothing else signed in and background refresh off, a **baseline** session
recorded for the project without the audited app running, and the **audit** session itself. What the
audit session shows beyond the baseline is attributed to the app, and the report **states the
method** instead of implying a per-app capability the tunnel does not have. The project's bundle
identifier is informational: it names what was audited, it is never used to filter traffic.

## Consequences

- **A session has a kind.** `baseline` and `audit` are both sessions of a project, recorded the same
  way; the difference is what the report does with them. This is part of the data model from the
  first increment rather than something bolted on when the report is built.
- **The attribution claim is as strong as the assessor's discipline**, and no stronger. A baseline
  recorded with a chatty device, or an audit session during which another app woke up, yields
  findings that are not the audited app's. The report has to say what the method is and what it
  cannot exclude; it cannot make the method better than it is.
- **Each increment has to be publishable on its own.** No increment may leave the tree in a state
  that only makes sense once a later one lands — which is the rule this repo already works by, now
  with a second reason.
- **The requirement catalogue goes public with the code**, so an unverified ID would be a public
  error about a BSI document. The rule from the plan therefore binds harder: IDs are checked against
  the official text before the catalogue is promoted, and a requirement with no applicable
  observation reads *not assessed by this tool*, never *passed*.
- **iOS-only stays a stated limitation** of the workflow, not a problem being worked on.
- **ADR 0003 and ADR 0007 are untouched.** The pinning check reads what the relay already records;
  decrypted content is not in the evidence bundle unless explicitly chosen.

## Alternatives considered

- **Core plus the feasibility study (increment 11):** not taken. The study is a document about
  things that would each be a project of their own (MDM enrolment, a second extension, a second
  platform), and it does not change any of increments 1–9. It can be commissioned later without
  having cost anything by waiting.
- **A minimum exportable slice (increments 1–5 and 8), deferring the diff, the catalogue and the
  PDF:** not taken. Without the mapping to requirements and a report, the output is a structured
  capture, which is what the app already nearly was; the part that replaces manual work is the part
  this would leave out.
- **Publish only once the whole workflow meets its Definition of Done:** not taken. It would open a
  long stretch in which the public source is behind the private one for no reason other than
  incompleteness, and every increment here is already required to stand on its own.
- **Publish the engine but keep the catalogue private until an assessor reviews it:** not taken as a
  rule, but its concern is kept as a consequence above — the catalogue is verified against the
  official document before it is promoted.
- **No attribution claim at all** (the report describes the whole device's traffic): rejected. It is
  honest but it leaves the assessor to argue attribution on their own, outside the evidence, with no
  baseline to point at. The controlled session costs one extra recording and puts the argument in
  the bundle.
