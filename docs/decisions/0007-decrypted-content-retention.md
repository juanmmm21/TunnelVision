# 0007 — Decrypted content: its own switch, its own (shorter) retention, its own deletion

- Status: Accepted
- Date: 2026-08-13

## Context

TLS inspection produces plaintext: the actual contents of the user's own HTTPS traffic. Piece 2 of
the *Road to v1* inspection plan gave it somewhere to go ([`../spec/plaintext.md`](../spec/plaintext.md)):
its own files, its own directory, bounded per record and per flow/direction. What none of that
answers is **how long any of it stays**, and that is a different kind of question — the most
privacy-sensitive one in the project.

Three things forced a decision before anything could start writing:

1. **Inspection and persistence are not the same act.** Turning inspection on lets the user see
   *who* is being talked to and lets a flow be decoded at all. Writing that decoded content to disk
   is a second, larger commitment: it turns a live view into a durable record of what the user read,
   typed and received.
2. **The existing retention was designed for captures**, whose contents travelled encrypted. One
   week of `.pcap` files is a very different object from one week of plaintext, even though both
   sit in the same container under the same disk encryption.
3. **"Clear everything" in Settings is all-or-nothing today**, so a user who regrets having recorded
   decrypted content has to throw away their whole history to get rid of it.

## Decision

**(1) Persisting plaintext is its own switch**, separate from `tlsInspectionEnabled` and **off by
default**, even when inspection is on. Inspection without it decodes for the live session and keeps
nothing.

**(2) Decrypted content has its own retention, and it is shorter — and it can never be unlimited.**
Its ages are `oneHour` / `oneDay` / `oneWeek`, defaulting to **one day**, against the captures'
one week (and their `unlimited` option, which does not exist here). On top of the user's age there
is a **fixed ceiling the user cannot raise**, applied by the same sweep: decrypted content never
occupies more than a bounded amount of disk regardless of settings.

**(3) Decrypted content can be deleted on its own**, without touching the history or the captures —
a separate action, and the only one of the three that removes what it removes.

Everything above sits *on top of* the bounds already in place: 64 KiB per direction per flow, a
per-record cap, and rotating files.

## Consequences

- **The default is "see, don't record".** A user who turns inspection on gets the decoded view
  while it happens; nothing survives the session unless they ask for it a second time. That is the
  behaviour we would want if we were the user, which is the standard this product is held to.
- **Two switches to explain instead of one.** The CA flow and the Settings screen have to make the
  difference legible ("inspect" vs "keep what was inspected") or the second switch becomes a
  mystery. That cost is accepted: the alternative is a switch whose full consequence is invisible.
- **A default of one day means content can vanish while it is still interesting.** Accepted, and it
  is the right side to err on: the user can raise it to a week, and the loss is recoverable by
  browsing again while the tunnel is up. The opposite mistake is not recoverable.
- **The fixed ceiling can delete content the user's age setting would have kept**, and the screen
  has to say so rather than let it look like a bug — the same honesty `sizeCapUnreachable` already
  applies to captures.
- **A tunnel that never sweeps never prunes.** The sweep runs where the capture retention already
  runs (on rotation, and when Settings is opened), so plaintext written during a session that keeps
  running and never rotates can outlive its age until the next sweep. Same limitation, same reason,
  and it is written down rather than papered over.
- **`unlimited` being absent is a real restriction**, and someone will eventually want it. The
  answer is no: a product that decrypts on the user's behalf should not offer to keep the results
  forever, and a v1 that shipped it would be very hard to take back.

## Alternatives considered

- **Persist implicitly whenever inspection is on** (one switch): rejected. It makes the most
  consequential effect of the feature a side effect of a different, milder decision. The screen
  would have to explain the recording anyway — at which point it may as well be a switch.
- **Inherit the captures' retention wholesale** (one week / size cap / `unlimited`): rejected. It
  reads as tidy but says that a week of `.pcap` and a week of plaintext are the same object, which
  they are not, and it would carry `unlimited` into the one place it must not exist.
- **A size cap exposed as a user setting**, mirroring the captures': rejected for v1. The per-flow
  budget already bounds the *rate*, so the second knob would mostly be a number the user has to
  understand in order to ignore. The fixed ceiling gives the protection without the question.
- **"Delete when the tunnel stops" as a retention option**: attractive and not rejected on merit,
  but left out of v1 because a tunnel that is never stopped never sweeps, and an option whose
  guarantee quietly depends on that is worse than an hour. Reconsider once the sweep has a second
  trigger.
- **Never persist plaintext at all** (live-only inspection): rejected — it would leave the decoded
  half of the Flow Inspector with nothing to show a second after it happened, and the point of the
  screen is to be able to go back and read what an app sent.
