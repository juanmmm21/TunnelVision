# 0009 — Development happens in the public repository

- Status: Accepted
- Date: 2026-10-03
- Supersedes: decision (2) of [0008](0008-tr03161-audit-workflow-scope.md) (publication)

## Context

Until now the project had two repositories with a promotion step between them: a private one where
all development happened, and this public one, which received a copy of the source tree — not the
history — whenever something was finished. ADR 0008 kept that arrangement for the TR-03161 audit
workflow and added a rule to it: each finished increment could be promoted, but only after telling
Juan before each copy.

That step stopped earning its keep on 2026-08-29, when the full source was published under MIT. From
then on the two trees were meant to be identical, so the promotion was a copy of files that were
already public in kind, guarded by a confirmation that had nothing left to protect. The first
increment of the audit workflow made it concrete: it was pushed to the private repository, then
copied here by hand the same day, and the only difference between the two results was a link.

## Decision

**All code is developed, tested, committed and pushed directly in this repository.** There is no
promotion step and no confirmation before a push: a finished increment is pushed when it is finished,
like in any other repository of Juan's.

**The private repository stays as a private notebook, and nothing else.** It keeps the documents that
describe unfinished work — the progress log, the roadmap and the plans — which do not belong in a
public repository. Its copy of the source is frozen as of 2026-10-03 and is no longer maintained.

Everything else in ADR 0008 stands: the scope of the audit workflow (1) and attribution by a
controlled session against a baseline (3).

## Consequences

- **Every push here is public the moment it lands.** The rule that an increment stands on its own,
  complete and green, was already how this project works; it is now the only thing between a
  half-finished change and the public history. Nothing is pushed mid-increment.
- **The history here is now the real development history**, in atomic commits, instead of a curated
  snapshot per promotion.
- **Documents about unfinished work still never land here.** What used to be kept out by not copying
  it is now kept out by not writing it here in the first place: no roadmap, no progress log, no plan
  with open steps.
- **Two repositories are touched at the end of a session** instead of one plus an occasional copy:
  the code here, the notebook there. They no longer share any file, so they cannot drift apart.
- **The frozen source in the private repository will fall behind** and must not be read as current,
  built, or compared against.
- **What ADR 0008 said about the requirement catalogue binds harder still**: its identifiers are
  verified against the official document *before* the commit that adds them, because there is no
  longer a private stage where an unverified one could sit.

## Alternatives considered

- **Keep developing privately and promote per increment (ADR 0008 as written):** rejected. It costs a
  manual copy and a confirmation per increment to maintain two trees whose intended difference is
  zero.
- **Keep the notebook documents here, untracked** (ignored by git, next to the code): rejected. One
  working directory is convenient, but those files would have no remote copy and no history, and the
  progress log is the one document a new session cannot work without.
- **Move the notebook out of git entirely**, into the project's page in the notes tool: rejected. The
  roadmap and the plans are long, versioned documents that are edited alongside the code they
  describe; they would lose their history and their diffability.
- **Retire the private repository:** rejected for the same reason — it is where the notebook lives.
